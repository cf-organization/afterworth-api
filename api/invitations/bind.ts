import { enforce } from "../../lib/rateLimit.js";
import {
  verifyJwt,
  getAuthedSupabaseClient,
  AuthError,
} from "../../lib/auth.js";

interface BindRequestBody {
  token: string;
}

interface BindRpcRow {
  membership_id: string;
  estate_id: string;
  estate_display_name: string;
  role: string;
  status: string;
}

const TOKEN_MIN_LEN = 16;
const TOKEN_MAX_LEN = 512;

function parseBody(raw: unknown): BindRequestBody | null {
  if (raw === null || typeof raw !== "object") return null;
  const obj = raw as Record<string, unknown>;
  if (typeof obj.token !== "string") return null;
  const token = obj.token.trim();
  if (token.length < TOKEN_MIN_LEN || token.length > TOKEN_MAX_LEN) {
    return null;
  }
  return { token };
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
    case "P0001":
      return errorResponse(400, "invalid_token");
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
    default:
      return null;
  }
}

export async function POST(req: Request): Promise<Response> {
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

  let body: BindRequestBody | null;
  try {
    const raw = await req.json();
    body = parseBody(raw);
  } catch {
    return errorResponse(400, "invalid_request");
  }
  if (!body) {
    return errorResponse(400, "invalid_request");
  }

  const rateLimitResponse = await enforce(req, "bind");
  if (rateLimitResponse) {
    return rateLimitResponse;
  }

  const supabase = getAuthedSupabaseClient(user.jwt);

  const { data, error } = await supabase.rpc("bind_invitation_token", {
    p_token: body.token,
  });

  if (error) {
    const mapped = rpcErrorResponse(error.code);
    if (mapped) {
      console.error("bind_invitation_token raised:", error.code, error.message);
      return mapped;
    }
    console.error("Supabase RPC error (unmapped):", error);
    return errorResponse(502, "upstream_error");
  }

  if (!Array.isArray(data) || data.length === 0) {
    console.error("bind_invitation_token returned unexpected shape:", data);
    return errorResponse(502, "upstream_unexpected_shape");
  }

  const row = data[0] as Partial<BindRpcRow>;
  if (
    typeof row.membership_id !== "string" ||
    typeof row.estate_id !== "string" ||
    typeof row.estate_display_name !== "string" ||
    typeof row.role !== "string" ||
    typeof row.status !== "string"
  ) {
    console.error("bind_invitation_token row missing fields:", row);
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