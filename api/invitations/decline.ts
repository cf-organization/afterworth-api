import { enforce } from "../../lib/rateLimit.js";
import {
  verifyJwt,
  getAuthedSupabaseClient,
  AuthError,
} from "../../lib/auth.js";

interface DeclineRequestBody {
  invitationId: string;
}

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function parseBody(raw: unknown): DeclineRequestBody | null {
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

  let body: DeclineRequestBody | null;
  try {
    const raw = await req.json();
    body = parseBody(raw);
  } catch {
    return errorResponse(400, "invalid_request");
  }
  if (!body) {
    return errorResponse(400, "invalid_request");
  }

  const rateLimitResponse = await enforce(req, "decline");
  if (rateLimitResponse) {
    return rateLimitResponse;
  }

  const supabase = getAuthedSupabaseClient(user.jwt);

  const { error } = await supabase.rpc("decline_invitation", {
    p_invitation_id: body.invitationId,
  });

  if (error) {
    const mapped = rpcErrorResponse(error.code);
    if (mapped) {
      console.error("decline_invitation raised:", error.code, error.message);
      return mapped;
    }
    console.error("Supabase RPC error (unmapped):", error);
    return errorResponse(502, "upstream_error");
  }

  // decline_invitation returns void; success is a 200 with a small ack body.
  return jsonResponse(200, { declined: true });
}
