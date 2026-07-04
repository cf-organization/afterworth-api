import { enforce } from "../rateLimit.js";
import {
  verifyJwt,
  getAuthedSupabaseClient,
  AuthError,
} from "../auth.js";

interface AcceptRequestBody {
  invitationId: string;
}

interface AcceptRpcRow {
  membership_id: string;
  estate_id: string;
  estate_display_name: string;
  role: string;
  status: string;
}

// RFC 4122 UUID (any version). Mirrors the strict shape the RPC expects.
const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function parseBody(raw: unknown): AcceptRequestBody | null {
  if (raw === null || typeof raw !== "object") return null;
  const obj = raw as Record<string, unknown>;
  if (typeof obj.invitationId !== "string") return null;
  const invitationId = obj.invitationId.trim();
  if (!UUID_RE.test(invitationId)) return null;
  return { invitationId };
}

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function errorResponse(status: number, code: string): Response {
  return jsonResponse(status, { error: code });
}

function authErrorResponse(err: AuthError): Response {
  switch (err.kind) {
    case "missing":
      return errorResponse(401, "missing_token");
    case "malformed":
      return errorResponse(401, "malformed_token");
    case "expired":
      return errorResponse(401, "expired_token");
    case "invalid":
      return errorResponse(401, "invalid_token");
  }
}

function rpcErrorResponse(code: string | undefined): Response | null {
  switch (code) {
    case "42501":
      return errorResponse(401, "unauthenticated_at_db");
    case "P0002":
      return errorResponse(404, "invitation_not_found");
    case "P0003":
      return errorResponse(410, "invitation_expired");
    case "P0004":
      return errorResponse(403, "invitation_revoked");
    case "P0005":
      return errorResponse(409, "invitation_already_accepted");
    case "P0006":
      return errorResponse(404, "invitation_not_found");
    case "P0007":
      return errorResponse(409, "invitation_declined");
    default:
      return null;
  }
}

export async function handle(req: Request): Promise<Response> {
  if (req.method !== "POST") {
    return errorResponse(405, "method_not_allowed");
  }

  let user;
  try {
    user = await verifyJwt(req);
  } catch (err) {
    if (err instanceof AuthError) {
      return authErrorResponse(err);
    }
    console.error("Unexpected auth error:", err);
    return errorResponse(502, "auth_upstream_error");
  }

  let body: AcceptRequestBody | null;
  try {
    const raw = await req.json();
    body = parseBody(raw);
  } catch {
    return errorResponse(400, "invalid_request");
  }
  if (!body) {
    return errorResponse(400, "invalid_request");
  }

  const rateLimitResponse = await enforce(req, "accept");
  if (rateLimitResponse) {
    return rateLimitResponse;
  }

  const supabase = getAuthedSupabaseClient(user.jwt);

  const { data, error } = await supabase.rpc("accept_invitation", {
    p_invitation_id: body.invitationId,
  });

  if (error) {
    const mapped = rpcErrorResponse(error.code);
    if (mapped) {
      console.error("accept_invitation raised:", error.code, error.message);
      return mapped;
    }
    console.error("Supabase RPC error (unmapped):", error);
    return errorResponse(502, "upstream_error");
  }

  if (!Array.isArray(data) || data.length === 0) {
    console.error("accept_invitation returned unexpected shape:", data);
    return errorResponse(502, "upstream_unexpected_shape");
  }

  const row = data[0] as Partial<AcceptRpcRow>;
  if (
    typeof row.membership_id !== "string" ||
    typeof row.estate_id !== "string" ||
    typeof row.estate_display_name !== "string" ||
    typeof row.role !== "string" ||
    typeof row.status !== "string"
  ) {
    console.error("accept_invitation row missing fields:", row);
    return errorResponse(502, "upstream_unexpected_shape");
  }

  return jsonResponse(200, {
    membership: {
      id: row.membership_id,
      estateId: row.estate_id,
      estateDisplayName: row.estate_display_name,
      role: row.role,
      status: row.status,
    },
  });
}
