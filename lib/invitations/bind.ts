import { enforce } from "../rateLimit.js";
import {
  verifyJwt,
  getAuthedSupabaseClient,
  AuthError,
} from "../auth.js";

interface BindRequestBody {
  token: string;
}

/**
 * ★ PHASE 11-MC — THREE OF THESE FIVE BECAME NULLABLE, AND ACCEPTING THAT IS WHY THIS SHIPS FIRST.
 *
 * A fiduciary (executor/trustee) invitation no longer provisions an `estate_memberships` row, so a
 * recipient who holds no independent access class has no membership id, no role and no status. The RPC
 * now reports all three as NULL together rather than asserting an approved beneficiary membership that
 * does not exist.
 *
 * The previous validator required all five to be `string` and returned 502 `upstream_unexpected_shape`
 * otherwise — so deploying the SQL correction before this route would have made every executor
 * acceptance look like a server fault to the invitee, while the designation had in fact committed.
 * That is the ordering constraint for this phase: THIS ROUTE FIRST (it deploys with the Vercel build on
 * merge), THEN the SQL paste. Reversed, acceptance breaks for exactly the people the phase is for.
 */
interface BindRpcRow {
  membership_id: string | null;
  estate_id: string;
  estate_display_name: string;
  role: string | null;
  status: string | null;
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
  /**
   * ★ ESTATE IDENTITY IS STILL REQUIRED; MEMBERSHIP FACTS ARE NOT.
   *
   * `estate_id` and `estate_display_name` describe WHICH estate was joined and are present for every
   * acceptance. The three membership fields are absent exactly when no membership was created, which is
   * now a legitimate outcome rather than a malformed payload. Keeping the estate fields strict means a
   * genuinely broken response still fails closed.
   */
  if (typeof row.estate_id !== "string" || typeof row.estate_display_name !== "string") {
    console.error("bind_invitation_token row missing estate fields:", row);
    return errorResponse(502, "upstream_unexpected_shape");
  }
  /**
   * ★ THE THREE MEMBERSHIP FIELDS MUST AGREE WITH EACH OTHER. Either all three are present (a
   * membership was created or already existed) or all three are null (fiduciary-only). A mixture means
   * the RPC contract broke, and accepting it would let a future regression report a role with no
   * membership — a disclosure claim with nothing behind it.
   */
  const membershipPresent =
    typeof row.membership_id === "string" &&
    typeof row.role === "string" &&
    typeof row.status === "string";
  const membershipAbsent =
    (row.membership_id ?? null) === null && (row.role ?? null) === null && (row.status ?? null) === null;
  if (!membershipPresent && !membershipAbsent) {
    console.error("bind_invitation_token row has a partial membership:", row);
    return errorResponse(502, "upstream_unexpected_shape");
  }

  return jsonResponse(200, {
    // Null when the acceptance conferred fiduciary capacity and no access class. The recipient's
    // fiduciary authority is reported by `get_my_fiduciary_estates`, which is the surface that owns it.
    membership: membershipPresent
      ? {
          id: row.membership_id,
          estateId: row.estate_id,
          estateDisplayName: row.estate_display_name,
          role: row.role,
          status: row.status,
        }
      : null,
    estate: { id: row.estate_id, displayName: row.estate_display_name },
  });
}