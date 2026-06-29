/**
 * POST /api/vault/members
 *
 * Owner-only: list an estate's NON-OWNER members (the grantable / request-eligible set —
 * beneficiary + professional_delegate). Thin wrapper over the SECURITY DEFINER rpc
 * `list_estate_members` (owner-gated, reads estate_memberships x profiles across the
 * profiles RLS boundary — see db/functions/list_estate_members.sql + Appendix A). The RPC
 * is the security boundary; this forwards the caller's JWT (auth.uid() = the caller).
 *
 * Two owner-side consumers: (a) resolve a request's requester to a display label in
 * owner-review; (b) populate the grant UI grantee picker with professionals/beneficiaries.
 *
 * Display: `fullName` (profiles.full_name, populated by the handle_new_user trigger from the
 * name captured at signup) when present; iOS prefers it, falling back to email, then a
 * uid-prefix. fullName is null for users seeded without that metadata (SQL fixtures) → email
 * fallback. professional_type is NOT returned — it is not on estate_memberships; the owner
 * chooses it at grant time.
 *
 * Request:  Authorization: Bearer <JWT>; body { estateId }
 * Response (200): { members: MemberWire[] }   MemberWire = { userId, email, role, status, fullName }
 * Errors: 401 auth, 400 bad body, 403 not-owner / non-member (gate), 405 method, 502 upstream.
 */

import { enforce } from "../../lib/rateLimit.js";
import { verifyJwt, getAuthedSupabaseClient, AuthError } from "../../lib/auth.js";

interface MembersRequestBody {
  estateId: string;
}

// Row shape returned by list_estate_members (snake_case columns).
interface MemberRow {
  user_id: string;
  role: string;
  status: string;
  email: string | null;
  full_name: string | null;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

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
    case "missing": return errorResponse(401, "missing_token");
    case "malformed": return errorResponse(401, "malformed_token");
    case "expired": return errorResponse(401, "expired_token");
    case "invalid": return errorResponse(401, "invalid_token");
  }
}

function parseBody(raw: unknown): MembersRequestBody | null {
  if (raw === null || typeof raw !== "object") return null;
  const o = raw as Record<string, unknown>;
  const estateId = typeof o.estateId === "string" ? o.estateId.trim() : "";
  if (!UUID_RE.test(estateId)) return null;
  return { estateId };
}

// Reshape a raw member row into the camelCase wire the iOS decoder expects (literal
// camelCase keys — JSONDecoder.afterworthAPI does NOT convert from snake_case). email may
// be null (iOS falls back to a uid-prefix label).
function toWire(r: MemberRow): Record<string, unknown> {
  return {
    userId: r.user_id,
    email: r.email,
    role: r.role,
    status: r.status,
    fullName: r.full_name,
  };
}

export async function POST(req: Request): Promise<Response> {
  if (req.method !== "POST") {
    return errorResponse(405, "method_not_allowed");
  }

  let user;
  try {
    user = await verifyJwt(req);
  } catch (err) {
    if (err instanceof AuthError) return authErrorResponse(err);
    console.error("Unexpected auth error:", err);
    return errorResponse(502, "auth_upstream_error");
  }

  let body: MembersRequestBody | null;
  try {
    body = parseBody(await req.json());
  } catch {
    return errorResponse(400, "invalid_request");
  }
  if (!body) {
    return errorResponse(400, "invalid_request");
  }

  const rateLimitResponse = await enforce(req, "vault_members");
  if (rateLimitResponse) {
    return rateLimitResponse;
  }

  const supabase = getAuthedSupabaseClient(user.jwt);
  const { data, error } = await supabase.rpc("list_estate_members", {
    p_estate_id: body.estateId,
  });

  if (error) {
    // The owner-gate raises 42501 for a non-owner / non-member caller -> 403 (the endpoint
    // reveals nothing, not even emptiness). The message is passed through for parity with
    // the grant endpoints' forbidden responses.
    if (error.code === "42501") {
      console.error("list_estate_members forbidden:", error.message);
      return jsonResponse(403, { error: "forbidden", message: error.message });
    }
    console.error("list_estate_members error:", error);
    return errorResponse(502, "upstream_error");
  }

  const members = ((data ?? []) as unknown as MemberRow[]).map(toWire);
  return jsonResponse(200, { members });
}
