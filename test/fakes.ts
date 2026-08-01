/**
 * Test doubles.
 *
 * ★ WHAT THE FAKE DATABASE DOES AND DOES NOT PROVE. `makeFakeAdmin` models the 0043 state machine
 * — the claim predicate, the generation guard, the retry cap, the terminal-invitation skip — so the
 * ORCHESTRATOR can be tested against it. It does not prove the SQL itself: only Postgres can prove
 * `for update skip locked`, the CHECK constraints, the grants, and the RLS posture. Those live in
 * db/verification/0043_invitation_delivery_verification.sql and are run against a database.
 *
 * Where a test's subject is really the SQL, its name says so. Nothing here is named in a way that
 * implies a database property was proven when it was not.
 *
 * ★ NO NETWORK, EVER. The transport double is the only thing `send()` can reach in these tests, and
 * it holds no API key — the provider adds the Authorization header itself, so a double can never
 * leak a credential it was never given.
 */

import type { SupabaseClient } from "@supabase/supabase-js";

export const MAX_ATTEMPTS = 5;

export interface FakeInvitation {
  id: string;
  status: string;
  expires_at: string;
  invitee_email: string | null;
  estate_display_name: string | null;
  inviter_display_name: string | null;
  preview_visibility: Record<string, unknown>;
  token_hash: string;
}

export interface FakeOutboxRow {
  id: string;
  invitation_id: string;
  estate_id: string;
  status: string;
  attempts: number;
  delivery_generation: number;
  idempotency_key: string | null;
  provider_message_id: string | null;
  failure_class: string | null;
  next_attempt_at: string | null;
  requested_at: string;
  issued_at: string | null;
}

export interface FakeDb {
  outbox: FakeOutboxRow[];
  invitations: FakeInvitation[];
  /** Every raw token this fake ever minted — so a test can grep artifacts for all of them. */
  mintedTokens: string[];
  /** Rows currently held by an in-flight claim, mirroring `for update skip locked`. */
  locked: Set<string>;
}

const ACTIONABLE = new Set(["pending", "matched"]);

function effectiveStatus(inv: FakeInvitation, now: Date): string {
  if (ACTIONABLE.has(inv.status) && new Date(inv.expires_at) <= now) return "expired";
  return inv.status;
}

export function makeDb(overrides: Partial<FakeDb> = {}): FakeDb {
  const invitation: FakeInvitation = {
    id: "11111111-1111-4111-8111-111111111111",
    status: "pending",
    expires_at: new Date(Date.now() + 14 * 864e5).toISOString(),
    invitee_email: "recipient@example.test",
    estate_display_name: "The Example Estate",
    inviter_display_name: "Alex Example",
    preview_visibility: { showEstateName: true, showInviterName: true },
    token_hash: "0".repeat(64),
  };
  const row: FakeOutboxRow = {
    id: "22222222-2222-4222-8222-222222222222",
    invitation_id: invitation.id,
    estate_id: "33333333-3333-4333-8333-333333333333",
    status: "queued",
    attempts: 0,
    delivery_generation: 0,
    idempotency_key: null,
    provider_message_id: null,
    failure_class: null,
    next_attempt_at: null,
    requested_at: new Date().toISOString(),
    issued_at: null,
  };
  return {
    outbox: overrides.outbox ?? [row],
    invitations: overrides.invitations ?? [invitation],
    mintedTokens: [],
    locked: new Set(),
  };
}

/** Mirrors 0043's claim predicate exactly. */
function isClaimable(r: FakeOutboxRow, now: Date): boolean {
  if (r.status === "queued") return true;
  if (r.status === "retryPending") {
    return new Date(r.next_attempt_at ?? r.requested_at) <= now;
  }
  return false;
}

let tokenCounter = 0;

export function makeFakeAdmin(db: FakeDb): SupabaseClient {
  const rpc = async (name: string, args: Record<string, unknown>) => {
    const now = new Date();

    if (name === "claim_invitation_deliveries") {
      const targeted = args.p_outbox_id as string | null;
      const max = targeted ? 1 : Number(args.p_max ?? 25);
      const claimed: Array<Record<string, unknown>> = [];

      for (const r of [...db.outbox].sort((a, b) => a.requested_at.localeCompare(b.requested_at))) {
        if (claimed.length >= max) break;
        if (targeted && r.id !== targeted) continue;
        if (!isClaimable(r, now)) continue;
        if (db.locked.has(r.id)) continue; // ← the SKIP LOCKED analogue
        const inv = db.invitations.find((i) => i.id === r.invitation_id);
        if (!inv || !ACTIONABLE.has(effectiveStatus(inv, now))) {
          r.status = "cancelled";
          continue;
        }
        db.locked.add(r.id);
        r.status = "processing";
        r.attempts += 1;
        claimed.push({
          outbox_id: r.id,
          invitation_id: r.invitation_id,
          delivery_generation: r.delivery_generation,
          attempts: r.attempts,
        });
      }
      return { data: claimed, error: null };
    }

    if (name === "issue_invitation_delivery_token") {
      const r = db.outbox.find((x) => x.id === args.p_outbox_id);
      if (!r || r.status !== "processing") {
        return { data: null, error: { code: "P0002", message: "outbox_entry_not_claimed" } };
      }
      const inv = db.invitations.find((i) => i.id === r.invitation_id)!;
      if (!ACTIONABLE.has(effectiveStatus(inv, now))) {
        r.status = "cancelled";
        return { data: null, error: { code: "P0005", message: "invitation_not_actionable" } };
      }
      r.delivery_generation += 1;
      r.idempotency_key = `afterworth/invitation/${r.id}/${r.delivery_generation}`;
      r.provider_message_id = null;
      r.failure_class = null;

      const rawToken = `tok_${++tokenCounter}_${"f".repeat(56)}`;
      db.mintedTokens.push(rawToken);
      inv.token_hash = `hash-of-${rawToken}`; // only the hash is stored, as in SQL

      return {
        data: [{
          invitation_id: inv.id,
          raw_token: rawToken,
          delivery_generation: r.delivery_generation,
          idempotency_key: r.idempotency_key,
          invitee_email: inv.invitee_email,
          estate_display_name: inv.estate_display_name,
          inviter_display_name: inv.inviter_display_name,
          preview_visibility: inv.preview_visibility,
          expires_at: inv.expires_at,
        }],
        error: null,
      };
    }

    if (name === "record_invitation_delivery_outcome") {
      const r = db.outbox.find((x) => x.id === args.p_outbox_id);
      if (!r) return { data: null, error: { code: "P0002", message: "outbox_entry_not_found" } };
      db.locked.delete(r.id);

      // Generation guard + already-settled guard, exactly as in SQL.
      if (r.delivery_generation !== Number(args.p_delivery_generation)) {
        return { data: [{ outbox_id: r.id, status: r.status, attempts: r.attempts }], error: null };
      }
      if (r.status === "providerAccepted" || r.status === "cancelled") {
        return { data: [{ outbox_id: r.id, status: r.status, attempts: r.attempts }], error: null };
      }

      const outcome = String(args.p_outcome);
      let status = outcome;
      if (outcome === "retryPending" && r.attempts >= MAX_ATTEMPTS) status = "failedPermanent";

      r.status = status;
      r.failure_class = outcome === "retryPending" || outcome === "failedPermanent"
        ? ((args.p_failure_class as string) ?? null) : null;
      if (outcome === "providerAccepted") {
        r.provider_message_id = (args.p_provider_message_id as string) ?? null;
        r.issued_at = now.toISOString();
      }
      r.next_attempt_at = status === "retryPending" ? new Date(Date.now() + 36e5).toISOString() : null;
      return { data: [{ outbox_id: r.id, status, attempts: r.attempts }], error: null };
    }

    throw new Error(`unexpected rpc: ${name}`);
  };

  return { rpc } as unknown as SupabaseClient;
}

export interface RecordedRequest {
  url: string;
  headers: Record<string, string>;
  body: Record<string, unknown>;
}

/** A transport double. Returns whatever the test queues; records every request for assertions. */
export function makeTransport(responses: Array<Response | Error>) {
  const requests: RecordedRequest[] = [];
  let i = 0;
  const transport = async (url: string, init: RequestInit): Promise<Response> => {
    const headers = init.headers as Record<string, string>;
    requests.push({ url, headers, body: JSON.parse(String(init.body)) });
    const next = responses[Math.min(i++, responses.length - 1)];
    if (next instanceof Error) throw next;
    return next;
  };
  return { transport, requests };
}

export function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

/** Captures console output so a test can prove a secret never reaches a log. */
export function captureConsole() {
  const lines: string[] = [];
  const originalError = console.error;
  const originalLog = console.log;
  const push = (...args: unknown[]) => { lines.push(args.map((a) => JSON.stringify(a) ?? String(a)).join(" ")); };
  console.error = push;
  console.log = push;
  return {
    lines,
    restore() { console.error = originalError; console.log = originalLog; },
  };
}
