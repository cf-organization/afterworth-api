#!/usr/bin/env node
/**
 * PHASE 11-OB PREP · THE BRANCH A T2 OBSERVER — read-only, and structurally unable to be anything else.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ WHAT T2 ASKS, AND WHY IT NEEDS AN INSTRUMENT RATHER THAN A LOOK.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * T2 is the owner-email-delivery gate: did the living owner actually receive the notice that a
 * process to release their estate had begun? Branch B must not start until that is classified,
 * because Branch B's whole safety argument rests on the owner having a real chance to object.
 *
 * The tempting shortcut is to read `status` and stop. `dispatched` looks like the answer. It is not
 * the answer, and this instrument's main job is to refuse to say that it is — see
 * `scripts/lib/t2Classification.mjs`, which holds the rule and the reasoning.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ WHY IT CANNOT MUTATE, STATED AS PROPERTIES A READER CAN CHECK.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 *   · It calls exactly ONE remote routine: `admin_get_death_verification_case`, which is declared
 *     `stable` in `db/functions/operator_console.sql` and therefore cannot write.
 *   · It never touches `claim_owner_notices`, `record_owner_notice_outcome`, `purge_outbox_rows`,
 *     or any lifecycle routine. `test/noProductionMutation.test.ts` enumerates the RPCs this file is
 *     permitted to name and FAILS if a new one appears.
 *   · It never reads CRON_SECRET and never requests the drain route. Triggering the drain is the one
 *     action that would destroy the very observation being made.
 *   · It refuses a service-role key outright, the same refusal `verifyOperatorAdmitPath.mjs` makes.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ IT PRINTS NO RECIPIENT, AND PROVES THAT RATHER THAN PROMISING IT.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * The operator projection deliberately omits `recipient` — `operator_console.sql` says so in a
 * comment beside the omission. This script does not take that on trust: before printing anything it
 * scans the payload it is about to emit for an address-shaped string and aborts if it finds one. The
 * queue's rows are about living people who may be the target of a false claim, and a terminal
 * scrollback is retained for as long as the terminal is.
 *
 * Usage:
 *   node scripts/observeOwnerNoticeDelivery.mjs --case=<uuid> [--outbox=<uuid>]
 *                                               [--operator=A|B] [--grace-minutes=60]
 *                                               [--delivery-observed=<iso8601>] [--json]
 *                                               [--env-dir=<path to afterworth-mobile>]
 *
 * `--delivery-observed` is the ONLY route to T2_DELIVERED and is a human attestation that the
 * message arrived in the owner mailbox, made out of band. It is corroborated against backend state
 * and refused if the backend disagrees.
 *
 * Exit:  0  T2_DELIVERED — the owner-email-delivery gate CLEARS
 *        1  a definite verdict that does NOT clear the gate (pending / accepted-only / failed /
 *           drain-did-not-run). Never read exit 1 as an error in the instrument.
 *        2  COULD NOT VERIFY — including T2_UNVERIFIABLE. A failure, never a pass.
 */
import crypto from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  T2,
  T2_DELIVERY_CAVEAT,
  classifyT2,
  drainScheduleFromManifest,
  nextDrainOpportunityAfter,
} from './lib/t2Classification.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EMAIL_SHAPED = /[\w.+-]+@[\w-]+\.[\w-]+/;

const argOf = (name) => {
  const hit = process.argv.find((a) => a.startsWith(`--${name}=`));
  return hit ? hit.slice(name.length + 3) : null;
};
const JSON_OUT = process.argv.includes('--json');

const die = (code, message) => {
  console.error(`✗ ${message}`);
  process.exit(code);
};

/* ── INPUT: NON-SECRET IDENTIFIERS ONLY ───────────────────────────────────────────────────────── */
const CASE_ID = argOf('case');
const OUTBOX_ID = argOf('outbox');
const OPERATOR = (argOf('operator') ?? 'A').toUpperCase();
const DELIVERY_OBSERVED = argOf('delivery-observed');
const GRACE_MINUTES = Number(argOf('grace-minutes') ?? 60);
const ENV_DIR = resolve(ROOT, argOf('env-dir') ?? '../afterworth-mobile');

if (!CASE_ID || !UUID_RE.test(CASE_ID)) {
  die(2, 'COULD NOT VERIFY — --case=<uuid> is required and must be a UUID.');
}
if (OUTBOX_ID && !UUID_RE.test(OUTBOX_ID)) {
  die(2, 'COULD NOT VERIFY — --outbox must be a UUID when supplied.');
}
if (!['A', 'B'].includes(OPERATOR)) {
  die(2, 'COULD NOT VERIFY — --operator must be A or B.');
}
if (!Number.isFinite(GRACE_MINUTES) || GRACE_MINUTES < 0) {
  die(2, 'COULD NOT VERIFY — --grace-minutes must be a non-negative number.');
}

/* ── THE DRAIN SCHEDULE, FROM THE DEPLOYMENT MANIFEST ─────────────────────────────────────────── */
let SCHEDULE = null;
try {
  SCHEDULE = drainScheduleFromManifest(JSON.parse(readFileSync(join(ROOT, 'vercel.json'), 'utf8')));
} catch {
  SCHEDULE = null;
}
if (!SCHEDULE) {
  die(2, 'COULD NOT VERIFY — vercel.json does not schedule a parseable daily claims drain.');
}

/* ── CREDENTIALS: KEY NAMES ONLY EVER LEAVE THIS BLOCK ────────────────────────────────────────── */
const parseEnv = (p) => {
  const out = new Map();
  if (!existsSync(p)) return out;
  for (const line of readFileSync(p, 'utf8').split('\n')) {
    const t = line.trim();
    if (!t || t.startsWith('#')) continue;
    const i = t.indexOf('=');
    if (i > 0) out.set(t.slice(0, i).trim(), t.slice(i + 1).trim().replace(/^["']|["']$/g, ''));
  }
  return out;
};

const app = parseEnv(join(ENV_DIR, '.env'));
const store = parseEnv(join(ENV_DIR, '.env.test'));
const URL_ = app.get('EXPO_PUBLIC_SUPABASE_URL');
const PUB = app.get('EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY');
if (!URL_ || !PUB) {
  die(2, `COULD NOT VERIFY — supabase url/publishable key absent from ${ENV_DIR}/.env`);
}
// ★ The same refusal the admit-path verifier makes. A read-only observer that ran as service_role
//   would be one typo away from bypassing every gate it exists to observe through.
if (PUB.startsWith('sb_secret') || /service_role/.test(PUB)) {
  die(2, 'REFUSING — that is a secret key. A T2 observation may never use service_role.');
}

/* ── RFC 6238, self-tested before use ─────────────────────────────────────────────────────────── */
const B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
function base32Decode(s) {
  let bits = 0;
  let value = 0;
  const out = [];
  for (const ch of s.replace(/=+$/, '').toUpperCase().replace(/\s+/g, '')) {
    const i = B32.indexOf(ch);
    if (i === -1) throw new Error('bad base32');
    value = (value << 5) | i;
    bits += 5;
    if (bits >= 8) {
      out.push((value >>> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  return Buffer.from(out);
}
function totp(secret, at = Math.floor(Date.now() / 1000)) {
  const c = Math.floor(at / 30);
  const b = Buffer.alloc(8);
  b.writeUInt32BE(Math.floor(c / 2 ** 32), 0);
  b.writeUInt32BE(c % 2 ** 32, 4);
  const h = crypto.createHmac('sha1', base32Decode(secret)).update(b).digest();
  const o = h[h.length - 1] & 0x0f;
  const n = ((h[o] & 0x7f) << 24) | (h[o + 1] << 16) | (h[o + 2] << 8) | h[o + 3];
  return String(n % 1e6).padStart(6, '0');
}
if (totp('GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ', 59) !== '287082') {
  die(2, 'COULD NOT VERIFY — the TOTP generator is wrong; a step-up failure would look like a server refusal.');
}

const req = (path, opts = {}) =>
  fetch(`${URL_}${path}`, {
    ...opts,
    headers: { apikey: PUB, 'Content-Type': 'application/json', ...(opts.headers ?? {}) },
  });

/** Password grant → aal1, then TOTP factor challenge/verify → aal2. */
async function aal2Session(prefix) {
  const email = store.get(`${prefix}_EMAIL`);
  const password = store.get(`${prefix}_PASSWORD`);
  const seed = store.get(`${prefix}_TOTP_SECRET`);
  const factorId = store.get(`${prefix}_FACTOR_ID`);
  if (!email || !password || !seed || !factorId) return { error: `${prefix}_* incomplete in .env.test` };

  const pw = await req('/auth/v1/token?grant_type=password', {
    method: 'POST',
    body: JSON.stringify({ email, password }),
  });
  if (!pw.ok) return { error: `sign-in failed (${pw.status})` };
  const s1 = await pw.json();

  const ch = await req(`/auth/v1/factors/${factorId}/challenge`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${s1.access_token}` },
    body: JSON.stringify({}),
  });
  if (!ch.ok) return { error: `challenge failed (${ch.status})` };
  const challenge = await ch.json();

  const ver = await req(`/auth/v1/factors/${factorId}/verify`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${s1.access_token}` },
    body: JSON.stringify({ challenge_id: challenge.id, code: totp(seed) }),
  });
  if (!ver.ok) return { error: `step-up failed (${ver.status})` };
  const s2 = await ver.json();
  const claims = JSON.parse(Buffer.from(s2.access_token.split('.')[1], 'base64').toString('utf8'));
  if (claims.aal !== 'aal2') return { error: `step-up produced ${claims.aal}, not aal2` };
  return { token: s2.access_token, uid: claims.sub };
}

/**
 * ★ THE ONLY REMOTE ROUTINE THIS FILE NAMES. `stable`, admin+AAL2 gated, and its projection
 *   deliberately carries no recipient address.
 */
const READ_ONLY_RPC = 'admin_get_death_verification_case';

async function readCaseFile(token, caseId) {
  const r = await req(`/rest/v1/rpc/${READ_ONLY_RPC}`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${token}` },
    body: JSON.stringify({ p_case: caseId }),
  });
  const text = await r.text();
  let data = null;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = null;
  }
  return { ok: r.ok, status: r.status, data, raw: text };
}

/* ── OBSERVE ──────────────────────────────────────────────────────────────────────────────────── */
const session = await aal2Session(`AW_ADMIN_TEST_${OPERATOR}`);
if (session.error) die(2, `COULD NOT VERIFY — operator ${OPERATOR}: ${session.error}`);

const caseFile = await readCaseFile(session.token, CASE_ID);
if (!caseFile.ok || !caseFile.data) {
  // The sentinel is not echoed verbatim — a PostgREST error body can carry row values.
  const sentinel = /case_not_found/.test(caseFile.raw)
    ? 'case_not_found'
    : /admin_required|mfa_required|stale_token/.test(caseFile.raw)
      ? 'operator_gate_refused'
      : `http_${caseFile.status}`;
  die(2, `COULD NOT VERIFY — the case file could not be read (${sentinel}).`);
}

const payload = caseFile.data;
const notices = Array.isArray(payload.owner_notice) ? payload.owner_notice : [];
const emailNotices = notices.filter((n) => n && n.channel === 'email');

let selected = null;
let selectionNote = '';
if (OUTBOX_ID) {
  selected = emailNotices.find((n) => String(n.id).toLowerCase() === OUTBOX_ID.toLowerCase()) ?? null;
  selectionNote = selected ? 'selected by --outbox' : 'the named --outbox id is not on this case';
} else if (emailNotices.length === 1) {
  selected = emailNotices[0];
  selectionNote = 'the single email notice on this case';
} else if (emailNotices.length > 1) {
  // ★ AMBIGUITY IS NOT RESOLVED BY GUESSING. Picking "the newest" would silently classify a
  //   different message than the one T2 is about.
  selectionNote = `${emailNotices.length} email notices on this case — name one with --outbox`;
} else {
  selectionNote = 'no email notice exists on this case';
}

const nowAt = new Date();
const classification = selected
  ? classifyT2({
      notice: selected,
      now: nowAt,
      schedule: SCHEDULE,
      graceMs: GRACE_MINUTES * 60 * 1000,
      deliveryObservedAt: DELIVERY_OBSERVED,
    })
  : { verdict: T2.UNVERIFIABLE, reason: selected === null && OUTBOX_ID ? 'named_outbox_not_on_case' : 'no_single_email_notice' };

const lifecycle = payload.lifecycle ?? {};
const report = {
  observed_at: nowAt.toISOString(),
  case_id: CASE_ID,
  operator: `AW_ADMIN_TEST_${OPERATOR}`,
  drain_schedule: SCHEDULE.expression,
  drain_schedule_source: 'vercel.json crons[/api/claims/drain_outboxes]',
  selection: selectionNote,
  verdict: classification.verdict,
  reason: classification.reason,
  notice: selected
    ? {
        outbox_id: selected.id,
        channel: selected.channel,
        notice_kind: selected.notice_kind,
        status: selected.status,
        attempts: selected.attempts,
        requested_at: selected.requested_at,
        // ★ NOT AVAILABLE, AND SAID SO. `claim_owner_notices` stamps no claim timestamp; there is no
        //   column. Substituting a nearby value would fabricate a fact about when a safety message
        //   was picked up.
        claimed_at: null,
        claimed_at_note: 'owner_notice_outbox records no claim timestamp — the schema has no column',
        dispatched_at: selected.dispatched_at ?? null,
        failure_class: selected.failure_class ?? null,
        provider_result: selected.status === 'dispatched' ? 'providerAccepted' : null,
        provider_message_id: null,
        // The routine is named in this file's header, not in this string: a read-only instrument
        // may not spell a write routine's name in code, and `noProductionMutation.test.ts` enforces
        // exactly that by stripping comments and scanning what is left.
        provider_message_id_note:
          'never stored — the write-back routine deliberately persists no provider handle',
        first_drain_opportunity_at:
          nextDrainOpportunityAfter(selected.requested_at, SCHEDULE)?.toISOString() ?? null,
      }
    : null,
  lifecycle: {
    state: lifecycle.state ?? null,
    owner_notified_at: lifecycle.owner_notified_at ?? null,
    challenge_window_started_at: lifecycle.challenge_window_started_at ?? null,
    halted_at: lifecycle.halted_at ?? null,
    released_at: lifecycle.released_at ?? null,
  },
  inbox_delivery_provable_from_backend_state: false,
  caveat: T2_DELIVERY_CAVEAT,
};
if (classification.delivery_observed_at) report.delivery_observed_at = classification.delivery_observed_at;
if (classification.first_opportunity_at) report.first_opportunity_at = classification.first_opportunity_at;

/* ── CONTAINMENT: PROVE THE OUTPUT CARRIES NO ADDRESS BEFORE EMITTING IT ──────────────────────── */
const serialized = JSON.stringify(report);
if (EMAIL_SHAPED.test(serialized)) {
  die(2, 'REFUSING TO PRINT — the assembled report contains an address-shaped string.');
}

if (JSON_OUT) {
  console.log(serialized);
} else {
  console.log('BRANCH A · T2 OWNER-NOTICE DELIVERY OBSERVATION (read-only)\n');
  console.log(`  case              ${report.case_id}`);
  console.log(`  observed at       ${report.observed_at}`);
  console.log(`  drain schedule    ${report.drain_schedule}  (${report.drain_schedule_source})`);
  console.log(`  selection         ${report.selection}`);
  if (report.notice) {
    const n = report.notice;
    console.log('\n  OUTBOX ROW');
    console.log(`    id              ${n.outbox_id}`);
    console.log(`    status          ${n.status}`);
    console.log(`    attempts        ${n.attempts}`);
    console.log(`    requested_at    ${n.requested_at}`);
    console.log(`    claimed_at      ${n.claimed_at}  (${n.claimed_at_note})`);
    console.log(`    dispatched_at   ${n.dispatched_at}`);
    console.log(`    failure_class   ${n.failure_class}`);
    console.log(`    provider_result ${n.provider_result}`);
    console.log(`    first drain op  ${n.first_drain_opportunity_at}`);
  }
  console.log('\n  LIFECYCLE');
  for (const [k, v] of Object.entries(report.lifecycle)) console.log(`    ${k.padEnd(28)}${v}`);
  console.log(`\n  VERDICT           ${report.verdict}`);
  console.log(`  reason            ${report.reason}`);
  console.log(`\n  ★ ${report.caveat}`);
}

if (report.verdict === T2.DELIVERED) process.exit(0);
if (report.verdict === T2.UNVERIFIABLE) process.exit(2);
process.exit(1);
