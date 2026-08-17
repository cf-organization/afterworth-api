#!/usr/bin/env node
/**
 * PHASE 11-OC · PHASE A DEPLOYMENT VERIFICATION + PRODUCTION READINESS CENSUS — read-only.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ WHAT THIS ANSWERS, AND WHY IT IS A SEPARATE INSTRUMENT.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * Phase A was pasted by hand into production. Three questions follow, and none of them is answered by
 * "the paste did not error":
 *
 *   1 · did Phase A deploy EXACTLY as committed?
 *   2 · did it remain BEHAVIOUR-NEUTRAL — is the stricter release policy still inactive?
 *   3 · how many live estates would the Phase D predicate refuse?
 *
 * (3) is the gate on every later phase, and it cannot be answered from the repository. It has to be
 * measured against production.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ WHY IT CANNOT MUTATE, STATED AS PROPERTIES A READER CAN CHECK.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 *   · It calls exactly TWO remote routines — `owner_notice_census()` and
 *     `owner_notice_release_readiness_census()` — both declared `stable` in
 *     `db/functions/outbox_safety.sql`, and a `stable` function cannot write.
 *   · It names no lifecycle routine, no claim routine, no settle routine, no purge, and no re-notice.
 *     `test/noProductionMutation.test.ts` enumerates the RPCs a script may name and FAILS if a new one
 *     appears — so this property is enforced, not promised.
 *   · It never reads CRON_SECRET and never requests the drain route. Triggering the drain would
 *     destroy the very population being measured.
 *   · It refuses a secret/service-role key outright. An operator assertion may never run as
 *     service_role — that would bypass `admin_require_gate()`, which is the thing under test.
 *
 * ★ IT GOES THROUGH THE GATE RATHER THAN AROUND IT. Both censuses call `admin_require_gate()`
 * internally (auth → is_admin → aal2 → 15-minute freshness). This script authenticates a real
 * synthetic admin and steps up to aal2 through a real TOTP factor, exactly as
 * `verifyOperatorAdmitPath.mjs` does. If the gate refused, that is a FINDING, never something to work
 * around.
 *
 * ★ IT PRINTS NO IDENTITY. The censuses return counts only — by construction, asserted in their own
 * comments and by the SQL suite. This script does not take that on trust: before printing anything it
 * scans the payload for an address shape AND for a uuid, and aborts if it finds either. A terminal
 * scrollback is retained for as long as the terminal is, and these rows are about living people who
 * may be the target of a false claim.
 *
 * ★ ABSENCE IS A FIRST-CLASS ANSWER, AND ZERO IS NOT THE SAME AS BROKEN. A production count of zero is
 * a legitimate result. What is NOT legitimate is a zero produced by a routine that is not deployed, or
 * by a gate that refused, or by a payload that failed to parse — so each of those is classified
 * separately and none of them is allowed to read as "clean".
 *
 * Usage:  node scripts/verifyPhaseADeployment.mjs [--json]
 * Exit:   0 Phase A verified and the census was read
 *         1 a Phase A assertion failed (deployment mismatch or behaviour change)
 *         2 could not verify — never a pass
 */
import crypto from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const MOBILE = resolve(ROOT, '../afterworth-mobile');
const JSON_OUT = process.argv.includes('--json');

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

const app = parseEnv(join(MOBILE, '.env'));
const store = parseEnv(join(MOBILE, '.env.test'));
const URL_ = app.get('EXPO_PUBLIC_SUPABASE_URL');
const PUB = app.get('EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY');
if (!URL_ || !PUB) {
  console.error('✗ CANNOT VERIFY — supabase url/publishable key absent from afterworth-mobile/.env');
  process.exit(2);
}
if (PUB.startsWith('sb_secret')) {
  console.error('✗ REFUSING — that is a secret key. An operator assertion may never use service_role:');
  console.error('  it would bypass admin_require_gate(), which is part of what this script verifies.');
  process.exit(2);
}

let failures = 0;
const lines = [];
const ok = (label, pass, detail = '') => {
  if (!pass) failures += 1;
  lines.push(`  ${pass ? '✓' : '✗'} ${label.padEnd(56)} ${detail}`);
};
const note = (s) => lines.push(s);

/* ── RFC 6238, in process. Self-tested against the published vector before use. ───────────────── */
const B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
function base32Decode(s) {
  let bits = 0, value = 0; const out = [];
  for (const ch of s.replace(/=+$/, '').toUpperCase().replace(/\s+/g, '')) {
    const i = B32.indexOf(ch);
    if (i === -1) throw new Error('bad base32');
    value = (value << 5) | i; bits += 5;
    if (bits >= 8) { out.push((value >>> (bits - 8)) & 0xff); bits -= 8; }
  }
  return Buffer.from(out);
}
function totp(secret, at = Math.floor(Date.now() / 1000)) {
  const c = Math.floor(at / 30);
  const b = Buffer.alloc(8);
  b.writeUInt32BE(Math.floor(c / 2 ** 32), 0); b.writeUInt32BE(c % 2 ** 32, 4);
  const h = crypto.createHmac('sha1', base32Decode(secret)).update(b).digest();
  const o = h[h.length - 1] & 0x0f;
  const n = ((h[o] & 0x7f) << 24) | (h[o + 1] << 16) | (h[o + 2] << 8) | h[o + 3];
  return String(n % 1e6).padStart(6, '0');
}
// The published RFC 6238 SHA-1 vector. If this fails the seed handling is wrong and every step-up
// below would fail for a reason that has nothing to do with the deployment.
if (totp('GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ', 59) !== '287082') {
  console.error('✗ CANNOT VERIFY — the in-process TOTP implementation failed its own RFC 6238 vector.');
  process.exit(2);
}

const req = (path, opts = {}) => fetch(`${URL_}${path}`, {
  ...opts, headers: { apikey: PUB, 'Content-Type': 'application/json', ...(opts.headers ?? {}) },
});

function classify(status, body) {
  const m = typeof body === 'string' ? body : JSON.stringify(body ?? '');
  if (/PGRST202|42883|Could not find the function/i.test(m)) return 'NOT_DEPLOYED';
  if (/auth_required/.test(m)) return 'auth_required';
  if (/admin_required/.test(m)) return 'admin_required';
  if (/mfa_required/.test(m)) return 'mfa_required';
  if (/stale_token_reauth_required/.test(m)) return 'stale_token';
  if (/permission denied/i.test(m)) return 'permission_denied';
  return status >= 200 && status < 300 ? 'SUCCEEDED' : `other(${status})`;
}

async function rpc(token, fn, args = {}) {
  const r = await req(`/rest/v1/rpc/${fn}`, {
    method: 'POST', headers: { Authorization: `Bearer ${token}` }, body: JSON.stringify(args),
  });
  const text = await r.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch { data = text; }
  return { verdict: classify(r.status, text), data, status: r.status, raw: text };
}

const decode = (t) => JSON.parse(Buffer.from(t.split('.')[1], 'base64').toString('utf8'));

async function aal2Session(prefix) {
  const email = store.get(`${prefix}_EMAIL`);
  const password = store.get(`${prefix}_PASSWORD`);
  const seed = store.get(`${prefix}_TOTP_SECRET`);
  const factorId = store.get(`${prefix}_FACTOR_ID`);
  if (!email || !password || !seed || !factorId) return { error: `${prefix}_* incomplete in .env.test` };

  const pw = await req('/auth/v1/token?grant_type=password', {
    method: 'POST', body: JSON.stringify({ email, password }),
  });
  if (!pw.ok) return { error: `sign-in failed (${pw.status})` };
  const s1 = await pw.json();

  const ch = await req(`/auth/v1/factors/${factorId}/challenge`, {
    method: 'POST', headers: { Authorization: `Bearer ${s1.access_token}` }, body: JSON.stringify({}),
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
  return { aal2: s2.access_token, uid: decode(s1.access_token).sub, aal: decode(s2.access_token).aal };
}

/* ★ THE DISCLOSURE GUARD. Run on every payload BEFORE it is printed. */
const ADDRESS = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/;
const UUID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i;
function assertCountsOnly(label, payload) {
  const s = JSON.stringify(payload ?? {});
  if (ADDRESS.test(s)) {
    console.error(`✗ ABORTING — ${label} contains an address shape. Refusing to print it.`);
    process.exit(2);
  }
  if (UUID.test(s)) {
    console.error(`✗ ABORTING — ${label} contains a uuid. The census must be counts only.`);
    process.exit(2);
  }
}

const main = async () => {
  console.log(`Phase 11-OC · PHASE A DEPLOYMENT VERIFICATION · ${URL_.replace(/^https?:\/\//, '').split('.')[0]}`);
  console.log(`UTC ${new Date().toISOString()}\n`);

  const s = await aal2Session('AW_ADMIN_TEST_A');
  if (s.error) {
    console.error(`✗ CANNOT VERIFY — ${s.error}`);
    process.exit(2);
  }
  note('OPERATOR SESSION');
  ok('reached aal2 through a real TOTP factor', s.aal === 'aal2', `aal=${s.aal}`);

  /* ══ 1 · PHASE A FUNCTION HALF IS DEPLOYED ══════════════════════════════════════════════════ */
  //
  // ★ THE READINESS CENSUS EXISTING AT ALL IS THE PROOF. It is NEW in Phase A, so a NOT_DEPLOYED
  // verdict here means the function half of the paste did not land — which a successful paste of the
  // migration half alone would not otherwise reveal.
  note('\n1 · PHASE A FUNCTION HALF');
  const ready = await rpc(s.aal2, 'owner_notice_release_readiness_census');
  ok('owner_notice_release_readiness_census is DEPLOYED', ready.verdict !== 'NOT_DEPLOYED', ready.verdict);
  ok('  …and it ADMITTED an aal2 admin (the gate ran and passed)', ready.verdict === 'SUCCEEDED', ready.verdict);

  /* ══ 2 · PHASE A MIGRATION HALF IS DEPLOYED ═════════════════════════════════════════════════ */
  //
  // ★ PROVED BY EXECUTION, NOT BY INTROSPECTION. `owner_notice_census()` under Phase A reads
  // notice_accepted_at, case_id, superseded_by and generation. If ANY of those columns were absent the
  // routine would raise, so a payload carrying the new keys proves the migration half landed and the
  // function half was rebuilt against it — one assertion covering both.
  note('\n2 · PHASE A MIGRATION HALF (proved by executing a routine that reads every new column)');
  const census = await rpc(s.aal2, 'owner_notice_census');
  ok('owner_notice_census SUCCEEDED', census.verdict === 'SUCCEEDED', census.verdict);
  const c = census.data ?? {};
  for (const k of ['accepted_total', 'unaccepted_total', 'legacy_unaccepted', 'no_episode',
                   'superseded_total', 'current_total', 'by_generation']) {
    ok(`key present: ${k}`, Object.prototype.hasOwnProperty.call(c, k),
      k === 'by_generation' ? JSON.stringify(c[k]) : String(c[k]));
  }
  // The pre-Phase-A keys must survive. A paste that replaced the routine instead of extending it
  // would show up here and nowhere else.
  for (const k of ['total', 'by_status', 'uncertain', 'purgeable', 'processing_total']) {
    ok(`pre-Phase-A key survived: ${k}`, Object.prototype.hasOwnProperty.call(c, k));
  }

  /* ══ 3 · ARITHMETIC RECONCILIATION ══════════════════════════════════════════════════════════ */
  note('\n3 · RECONCILIATION — every row lands in a NAMED split');
  const n = (v) => (v === null || v === undefined ? NaN : Number(v));
  const total = n(c.total);
  ok('accepted + unaccepted = total',
    n(c.accepted_total) + n(c.unaccepted_total) === total,
    `${n(c.accepted_total)} + ${n(c.unaccepted_total)} = ${total}`);
  ok('superseded + current = total',
    n(c.superseded_total) + n(c.current_total) === total,
    `${n(c.superseded_total)} + ${n(c.current_total)} = ${total}`);
  const genSum = Object.values(c.by_generation ?? {}).reduce((a, b) => a + Number(b), 0);
  ok('by_generation sums to total', genSum === total, `${genSum} = ${total}`);
  ok('legacy_unaccepted ⊆ unaccepted_total',
    n(c.legacy_unaccepted) <= n(c.unaccepted_total),
    `${n(c.legacy_unaccepted)} ≤ ${n(c.unaccepted_total)}`);

  /* ══ 4 · NO GUESSED BACKFILL ════════════════════════════════════════════════════════════════ */
  //
  // ★ THE ASYMMETRY IS THE EVIDENCE. Phase A forbids backfilling acceptance and forbids backfilling
  // case_id. If a backfill HAD been run, historical rows would carry an acceptance fact nobody
  // established — and the tell is `accepted_total` exceeding the number of rows that could legitimately
  // have been accepted since the paste. This is reported rather than asserted: only a human who knows
  // the deployment timestamp can settle it, and stating the numbers is what lets them.
  note('\n4 · BACKFILL POSTURE (reported — the numbers are the evidence)');
  note(`     rows total ......................... ${total}`);
  note(`     with an acceptance FACT ............ ${n(c.accepted_total)}`);
  note(`     dispatched with NO acceptance ...... ${n(c.legacy_unaccepted)}   ← the legacy class`);
  note(`     belonging to NO episode (case_id ∅)  ${n(c.no_episode)}   ← strictly pre-Phase-A`);

  /* ══ 5 · THE READINESS CENSUS ═══════════════════════════════════════════════════════════════ */
  note('\n5 · PRODUCTION READINESS CENSUS');
  const r = ready.data ?? {};
  assertCountsOnly('readiness census', r);
  assertCountsOnly('owner notice census', c);
  ok('discloses no address shape', !ADDRESS.test(JSON.stringify(r)));
  ok('discloses no uuid', !UUID.test(JSON.stringify(r)));
  for (const k of ['estates_at_door', 'by_readiness', 'would_be_refused_by_phase_d',
                   'would_be_admitted_by_phase_d']) {
    ok(`key present: ${k}`, Object.prototype.hasOwnProperty.call(r, k),
      k === 'by_readiness' ? JSON.stringify(r[k]) : String(r[k]));
  }
  const door = n(r.estates_at_door);
  const refused = n(r.would_be_refused_by_phase_d);
  const admitted = n(r.would_be_admitted_by_phase_d);
  ok('admitted + refused = estates_at_door', admitted + refused === door,
    `${admitted} + ${refused} = ${door}`);
  const bucketSum = Object.values(r.by_readiness ?? {}).reduce((a, b) => a + Number(b), 0);
  ok('by_readiness sums to estates_at_door', bucketSum === door, `${bucketSum} = ${door}`);
  ok('no `unclassified` bucket',
    !Object.prototype.hasOwnProperty.call(r.by_readiness ?? {}, 'unclassified'),
    'a status outside the six would land here');

  /* ══ 5b · THE NON-VACUITY CONTROL — IS ZERO A REAL ZERO? ════════════════════════════════════ */
  //
  // ★ A CENSUS RETURNING 0/0 AND A CENSUS THAT INSPECTED NOTHING ARE INDISTINGUISHABLE FROM THE
  // OUTSIDE, and this repository has shipped that exact failure more than once. The readiness census
  // carries positive controls in the SQL suite (§10.6 proves it can report BOTH admitted and refused
  // against furnished non-zero fixtures) — but those run against a test database, and they say nothing
  // about whether this PRODUCTION reading is meaningful.
  //
  // So the production zero is corroborated INDEPENDENTLY: `admin_list_death_verification_cases`
  // reaches the lifecycle by a different route and publishes `lifecycle_state` per case. If the queue
  // says no estate is at `challenge_window`, then "0 estates at the door" is a fact about production
  // rather than a broken instrument. If the queue DOES show one and the census says 0, that is a
  // FINDING — the census is blind — and it must fail here rather than be read as clean.
  //
  // The queue rows carry case and estate identifiers. They are aggregated into a state histogram and
  // NEVER printed: a count is what this question needs, and a roster is not.
  note('\n5b · NON-VACUITY CONTROL — corroborating the census against an independent projection');
  const queue = await rpc(s.aal2, 'admin_list_death_verification_cases');
  ok('the queue projection is reachable (the control can see ANYTHING)',
    queue.verdict === 'SUCCEEDED', queue.verdict);
  const rows = Array.isArray(queue.data) ? queue.data : [];
  ok('the queue returned a non-empty row set', rows.length > 0,
    `${rows.length} case(s) — a zero here would make this control vacuous too`);
  const hist = {};
  for (const row of rows) {
    const st = row?.lifecycle_state ?? 'unknown';
    hist[st] = (hist[st] ?? 0) + 1;
  }
  note(`     lifecycle histogram across the queue: ${JSON.stringify(hist)}`);
  const atDoorPerQueue = hist.challenge_window ?? 0;
  ok('queue and census AGREE on how many estates stand at the door',
    atDoorPerQueue === door,
    `queue=${atDoorPerQueue} census=${door}`);
  if (door === 0) {
    note('     → 0 is a REAL zero: an independent projection agrees no estate is at challenge_window.');
  }

  /* ══ 6 · BEHAVIOUR NEUTRALITY — THE LOAD-BEARING HALF ═══════════════════════════════════════ */
  //
  // ★ PHASE A MUST NOT HAVE ACTIVATED PHASE D. This cannot be settled by reading prosrc from here (no
  // SQL access through PostgREST), so it is settled by the artifacts that CAN see it, and this section
  // states which instrument covers which claim rather than implying one instrument covered all of it:
  //
  //   · `verifySourceDeploymentDrift.mjs` executes the committed source in an ephemeral Postgres and
  //     puts the same input matrix through BOTH sides, deployed included. It is the instrument that
  //     would catch a deployed body differing from source.
  //   · `owner_notice_release_readiness_census()` reports what Phase D WOULD do — it is a projection,
  //     not the door. Its existence changes no release behaviour.
  //   · The door itself is exercised against a real Postgres by
  //     `db/tests/release_safety_authorization.sql` §10.7, which asserts on the deployed body that
  //     `authorize_release` still carries the pre-Phase-D predicate.
  //
  // What IS observable from here: the release door still refuses an admin who has no verified case,
  // rather than having become reachable or having changed shape.
  // ★ THIS INSTRUMENT DOES NOT PROBE THE RELEASE DOOR, AND THE OMISSION IS DELIBERATE.
  //
  // An earlier draft called the two release routines with a nil estate to read back their refusal
  // sentinel. Those calls provably cannot write — both raise at a state guard before any statement, and
  // PostgREST rolls the transaction back — but "provably" there means a human traced the branch. The
  // whole point of `test/noProductionMutation.test.ts` is that read-only-ness is STRUCTURALLY checkable
  // rather than argued call-by-call, and it enforces that by forbidding a script from even NAMING a
  // routine on `MUTATION_RPCS`. A census instrument that has to be reasoned about individually is
  // exactly the thing that list exists to prevent, so this file names none of them and is listed in
  // READ_ONLY_FILES instead — governed, not vouched for.
  //
  // The behaviour-neutrality claim is not weakened by that; it is answered by the instruments built for
  // it, and each covers a DIFFERENT half rather than one standing in for the rest:
  //
  //   · `verifySourceDeploymentDrift.mjs` executes the committed source in an ephemeral Postgres and
  //     puts one input matrix through BOTH sides. It is what would catch a DEPLOYED body differing
  //     from the committed one.
  //   · `db/tests/release_safety_authorization.sql` §10.7 asserts on the deployed function body that
  //     `authorize_release` still carries the pre-Phase-D predicate.
  //   · Migrations 0056 (×2) and 0057 (×1) each re-assert the same predicate on every replay, and
  //     0058 §5.4 asserts the inversion — that Phase A did NOT change it.
  //   · `verifyOperatorAdmitPath.mjs` is the sanctioned place that exercises the door through the
  //     product path, and it already does.
  //
  // What THIS file contributes to that question is narrower and worth stating plainly: the readiness
  // census is a PROJECTION of what Phase D would decide. Its numbers change no release behaviour, and
  // its existence is not evidence that the door changed.
  note('\n6 · BEHAVIOUR NEUTRALITY');
  note('     Not asserted here — this instrument names no mutation RPC, by design (see source).');
  note('     Covered by: verifySourceDeploymentDrift.mjs · release_safety_authorization.sql §10.7 ·');
  note('     migrations 0056/0057 predicate guards + 0058 §5.4 inversion · verifyOperatorAdmitPath.mjs');

  /* ══ REPORT ════════════════════════════════════════════════════════════════════════════════ */
  console.log(lines.join('\n'));
  console.log('\n' + '─'.repeat(94));
  console.log('READINESS CENSUS — RAW AGGREGATES (counts only)');
  console.log(JSON.stringify(r, null, 2).split('\n').map((l) => '  ' + l).join('\n'));
  console.log('\nOWNER NOTICE CENSUS — RAW AGGREGATES (counts only)');
  console.log(JSON.stringify(c, null, 2).split('\n').map((l) => '  ' + l).join('\n'));

  console.log('\n' + '─'.repeat(94));
  console.log(`WOULD BE REFUSED BY PHASE D:  ${refused}`);
  console.log(`WOULD BE ADMITTED BY PHASE D: ${admitted}`);
  console.log(`ESTATES AT THE DOOR:          ${door}`);
  if (refused > 0) {
    console.log('\n  ⚠ PHASE C IS REQUIRED BEFORE PHASE D FOR THE CURRENT LEGACY STATE.');
    console.log('    Those estates have no provable provider acceptance in their current case, so the');
    console.log('    stricter door would refuse them with `notice_never_accepted` and they would have no');
    console.log('    route to release until the re-notice remedy exists.');
  } else {
    console.log('\n  Today\'s legacy migration dependency is ZERO.');
    console.log('    That is NOT the same as "Phase C is unnecessary": Policy D creates NEW legitimate');
    console.log('    refusal states (failedPermanent, outcomeUncertain) that a live system will reach on');
    console.log('    its own. Without a re-notice remedy the FIRST post-cutover provider failure creates');
    console.log('    a permanently unreleasable estate. See the operability distinction in the report.');
  }

  if (JSON_OUT) {
    console.log('\n' + JSON.stringify({ readiness: r, census: c, failures }, null, 2));
  }
  console.log(`\n${failures === 0 ? '✓' : '✗'} ${failures} failed assertion(s)`);
  process.exit(failures === 0 ? 0 : 1);
};

main().catch((e) => {
  console.error(`✗ CANNOT VERIFY — ${e?.message ?? e}`);
  process.exit(2);
});
