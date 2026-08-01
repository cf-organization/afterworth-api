/**
 * GET /api/invitations/drain_email_outbox — the scheduled RECOVERY backstop.
 *
 * ★ THIS IS NOT THE DELIVERY MECHANISM. The immediate attempt in `create_owner` is the primary
 * path. This exists because that attempt runs in a process that can die, deploy, or time out
 * mid-flight, and a queued row with nobody watching it is the failure mode a daily cron's SILENCE
 * hides best. Exactly the `drain_purge_outbox` rationale, and exactly its authorization: Vercel
 * Cron sends `Authorization: Bearer $CRON_SECRET`, and an unset secret fails CLOSED (a missing
 * secret must never mean "anyone may drain").
 *
 * ★ LAG IS REAL AND STATED. On the current free tier cron frequency is plan-limited to daily, so a
 * row this backstop recovers can be up to roughly a day behind. That is a property of the hosting
 * tier, not a defect, and it is written down here rather than discovered later.
 *
 * ★ THE RESPONSE IS COUNTERS ONLY. No invitation id, no outbox id, no recipient address, no
 * provider message id, no token. A cron log is retained indefinitely by the platform, so anything
 * returned here is effectively permanent.
 */

import { createClient } from "@supabase/supabase-js";
import { claimAndDeliver, emptyCounters, type DeliveryDeps } from "./delivery.js";

/** Bounded so one invocation cannot exceed the function's wall clock and strand claimed rows. */
const BATCH = 25;

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

export async function handle(req: Request, deps: DeliveryDeps = {}): Promise<Response> {
  const cronSecret = process.env.CRON_SECRET;
  const auth = req.headers.get("authorization");
  // Fails closed on an unset secret — same shape as drain_purge_outbox.
  if (!cronSecret || auth !== `Bearer ${cronSecret}`) {
    return jsonResponse(401, { error: "unauthorized" });
  }

  const supabaseUrl = process.env.SUPABASE_URL;
  const serviceKey = process.env.SUPABASE_SECRET_KEY;
  if (!supabaseUrl || !serviceKey) {
    console.error("drain_email_outbox: SUPABASE_URL / SUPABASE_SECRET_KEY not configured");
    return jsonResponse(502, { error: "config_error" });
  }

  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });

  let counters = emptyCounters();
  try {
    counters = await claimAndDeliver(admin, { max: BATCH }, deps);
  } catch (err) {
    // Never surface the cause: it can carry a recipient address from a provider error path.
    console.error("drain_email_outbox: unexpected error", err instanceof Error ? err.name : "unknown");
    return jsonResponse(502, { error: "upstream_error" });
  }

  return jsonResponse(200, counters);
}
