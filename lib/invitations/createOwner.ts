/**
 * POST /api/invitations/create_owner
 *
 * The owner-facing invitation creation door. Two layers, in the storage-deletion-outbox shape:
 *
 *   1. AUTHORIZED MUTATION (the security boundary) — `create_estate_invitation`, called with the
 *      OWNER'S JWT. Its `estate_owner_gate` is ownership-only; platform admin confers nothing here.
 *      The invitation row and its outbox row are inserted in that function's single transaction, so
 *      they commit together or not at all. Nothing in this file can widen that gate: a caller who
 *      hits the RPC directly through PostgREST meets the identical check.
 *
 *   2. IMMEDIATE ATTEMPT (mechanics only) — AFTER the mutation has committed, one bounded delivery
 *      attempt runs under the service role. It is best-effort: whatever happens to it, the
 *      invitation already exists and the outbox row is already durable, so the daily drain will
 *      pick the row up if this attempt does not settle it.
 *
 * ★ NO RAW TOKEN LEAVES THIS ENDPOINT. The create RPC does not mint a usable token at all (it
 * stores the hash of a discarded value); the real secret is minted later, inside the worker, and
 * lives only in that call's local scope. The response carries a 12-character fingerprint of the
 * HASH — an identifier, useless as a credential.
 *
 * ★ THE RESPONSE NEVER CLAIMS DELIVERY. `deliveryState` is `queued` or `providerAccepted`, and
 * `providerAccepted` means a provider took the message, not that anyone received, opened, or read
 * it. There is no state in this system that means delivered.
 */

import { createClient } from "@supabase/supabase-js";
import { enforce } from "../rateLimit.js";
import { verifyJwt, getAuthedSupabaseClient, AuthError } from "../auth.js";
import { claimAndDeliver, type DeliveryDeps } from "./delivery.js";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Exactly the vocabulary `create_estate_invitation` accepts. Ownership and fiduciary roles are
 *  unrepresentable here AND at the schema level, so an invitation can never grant them. */
const ROLES = new Set(["beneficiary", "professional_delegate"]);

/** Closed set. An unmatched sentinel becomes a generic 400 rather than echoing database text. */
const CREATE_SENTINELS = new Set([
  "invitee_contact_required",
  "role_not_supported",
  "invalid_expiry",
  "cannot_invite_self",
  "already_member",
  "active_invitation_exists",
  "pending_invitation_cap",
]);

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
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

function sentinelFrom(message: string): string {
  for (const s of CREATE_SENTINELS) if (message.includes(s)) return s;
  return "invalid_request";
}

export async function handle(req: Request, deps: DeliveryDeps = {}): Promise<Response> {
  let user;
  try {
    user = await verifyJwt(req);
  } catch (err) {
    if (err instanceof AuthError) return authErrorResponse(err);
    console.error("create_owner: unexpected auth error:", err);
    return errorResponse(502, "auth_upstream_error");
  }

  const rl = await enforce(req, "invitations_create_owner");
  if (rl) return rl;

  let raw: unknown;
  try {
    raw = await req.json();
  } catch {
    return errorResponse(400, "invalid_request");
  }
  if (raw === null || typeof raw !== "object") return errorResponse(400, "invalid_request");
  const o = raw as Record<string, unknown>;

  const estateId = typeof o.estateId === "string" ? o.estateId.trim() : "";
  const proposedRole = typeof o.proposedRole === "string" ? o.proposedRole.trim() : "";
  if (!UUID_RE.test(estateId) || !ROLES.has(proposedRole)) return errorResponse(400, "invalid_request");

  const inviteeEmail = typeof o.inviteeEmail === "string" ? o.inviteeEmail.trim() : "";
  const inviteePhone = typeof o.inviteePhone === "string" ? o.inviteePhone.trim() : "";
  if (!inviteeEmail && !inviteePhone) return errorResponse(400, "invitee_contact_required");

  const expiresInDays =
    typeof o.expiresInDays === "number" && Number.isFinite(o.expiresInDays) ? Math.floor(o.expiresInDays) : 14;

  // ---- 1. AUTHORIZED MUTATION, as the owner. Invitation + outbox commit atomically inside. ----
  const authed = getAuthedSupabaseClient(user.jwt);
  const { data, error } = await authed.rpc("create_estate_invitation", {
    p_estate: estateId,
    p_proposed_role: proposedRole,
    p_invitee_email: inviteeEmail || null,
    p_invitee_phone: inviteePhone || null,
    p_show_estate_name: o.showEstateName === true,
    p_show_inviter_name: o.showInviterName === true,
    p_expires_in_days: expiresInDays,
  });
  if (error) {
    if (error.code === "42501") return errorResponse(403, "owner_required");
    if (error.code === "P0001") return errorResponse(400, sentinelFrom(error.message ?? ""));
    console.error("create_estate_invitation error:", error.code);
    return errorResponse(502, "upstream_error");
  }

  const row = (Array.isArray(data) ? data[0] : data) as Record<string, unknown> | undefined;
  if (!row) return errorResponse(502, "upstream_error");

  const invitationId = String(row.invitation_id);
  const tokenFingerprint = String(row.token_fingerprint ?? "");
  const expiresAt = String(row.expires_at ?? "");

  // ---- 2. ONE bounded immediate attempt. The row is already durable; this is a fast path, not a
  //         guarantee. Any failure here leaves the row for the daily drain. ----
  let deliveryState = "queued";
  const supabaseUrl = process.env.SUPABASE_URL;
  const serviceKey = process.env.SUPABASE_SECRET_KEY;
  if (!supabaseUrl || !serviceKey) {
    console.error("create_owner: SUPABASE_URL / SUPABASE_SECRET_KEY not configured");
  } else {
    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    });
    // The outbox id is not returned by the create RPC, so target by invitation. Service-role read of
    // a row this caller demonstrably owns (the gate above already passed).
    const { data: outbox } = await admin
      .from("invitation_delivery_outbox")
      .select("id")
      .eq("invitation_id", invitationId)
      .order("requested_at", { ascending: false })
      .limit(1);
    const outboxId = Array.isArray(outbox) && outbox[0] ? String(outbox[0].id) : null;

    if (outboxId) {
      const counters = await claimAndDeliver(admin, { outboxId }, deps);
      if (counters.providerAccepted > 0) deliveryState = "providerAccepted";
      else if (counters.outcomeUncertain > 0) deliveryState = "outcomeUncertain";
      else if (counters.failedPermanent > 0) deliveryState = "failedPermanent";
      // retryPending / cancelled / nothing-claimed all read as `queued` to the owner: the drain owns
      // it from here, and worker mechanics are not the owner's concern.
    }
  }

  // Fingerprint, not token. No recipient address, no outbox id, no provider handle.
  return jsonResponse(200, { invitationId, tokenFingerprint, expiresAt, deliveryState });
}
