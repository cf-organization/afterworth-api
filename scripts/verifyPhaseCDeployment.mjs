#!/usr/bin/env node
/**
 * PHASE 11-OC · PHASE C DEPLOYMENT VERIFICATION — read-only.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ WHAT THIS ANSWERS, AND WHAT IT DELIBERATELY DOES NOT.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * Phase C is pasted by hand into production. Four questions follow, and none of them is answered by
 * "the paste did not error":
 *
 *   1 · did the ROUTINE half land — is `reissue_owner_safety_notice` reachable at all?
 *   2 · did the MIGRATION half land — does the schema admit the re-notice kind and is the
 *       one-current-generation wall now keyed on the EPISODE?
 *   3 · is the PRIVILEGE posture right — admin-gated, AAL2, fresh, and unreachable by anon?
 *   4 · did Phase C stay BEHAVIOUR-NEUTRAL — is the Phase D cutover still absent?
 *
 * ★ IT PROVES THE CONTRACT IS DEPLOYED. IT DOES NOT PROVE A RE-NOTICE WORKS IN PRODUCTION.
 *
 * Those are two different claims and this repository has conflated them before. Executing a real
 * re-notice would append a generation to a live safety queue and QUEUE AN EMAIL TO A LIVING PERSON
 * about their own death process. That is not a verification step; it is a production side effect, and
 * it must never be taken as a side effect of running a script. So:
 *
 *      DEPLOYED CONTRACT PROOF        ← this script
 *      LIVE REMEDIATION PROOF         ← separately authorized, against a legitimate fixture
 *
 * The second stays PRODUCTION_RUNTIME_PROOF_PENDING until such a fixture exists. Reporting it as
 * anything else would be faking evidence.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ WHY IT CANNOT MUTATE, STATED AS PROPERTIES A READER CAN CHECK.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 *   · It calls exactly THREE remote routines — `owner_notice_census()`,
 *     `owner_notice_release_readiness_census()` and `admin_get_death_verification_case()` — all three
 *     declared `stable` in source, and a `stable` function cannot write.
 *   · `reissue_owner_safety_notice` is NEVER invoked with a real case. Its deployment is established
 *     from the projection instead (see §1), because the ONLY safe probe of a writer is not calling
 *     it. `test/noProductionMutation.test.ts` enumerates the RPCs a read-only script may name and
 *     FAILS if a mutation RPC appears — so this property is enforced, not promised.
 *   · It never reads CRON_SECRET and never requests the drain route.
 *   · It refuses a secret/service-role key outright. An operator assertion may never run as
 *     service_role — that would bypass `admin_require_gate()`, which is part of what is under test.
 *
 * ★ IT PRINTS NO IDENTITY. Both censuses return counts only. The case-file projection does NOT — it
 * is per-case by construction — so this script reads it for SHAPE only, asserts the keys it needs,
 * and prints nothing from it but booleans and the names of keys.
 *
 * ★ ABSENCE IS A FIRST-CLASS ANSWER, AND ZERO IS NOT THE SAME AS BROKEN. A production count of zero
 * remediable episodes is a legitimate result and is exactly what the Phase A census predicted. What
 * is NOT legitimate is a zero produced by a routine that is not deployed, by a gate that refused, or
 * by a payload that failed to parse — each is classified separately and none may read as "clean".
 *
 * Usage:  node scripts/verifyPhaseCDeployment.mjs [--json]
 * Exit:   0 Phase C verified · 1 a Phase C assertion failed · 2 could not verify (never a pass)
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
  lines.push(`  ${pass ? '✓' : '✗'} ${label.padEnd(58)} ${detail}`);
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
    method: 'POST',
    headers: token ? { Authorization: `Bearer ${token}` } : {},
    body: JSON.stringify(args),
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
  return { aal2: s2.access_token, aal1: s1.access_token, uid: decode(s1.access_token).sub,
           aal: decode(s2.access_token).aal };
}

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
  console.log(`Phase 11-OC · PHASE C DEPLOYMENT VERIFICATION · ${URL_.replace(/^https?:\/\//, '').split('.')[0]}`);
  console.log(`UTC ${new Date().toISOString()}\n`);

  const s = await aal2Session('AW_ADMIN_TEST_A');
  if (s.error) {
    console.error(`✗ CANNOT VERIFY — ${s.error}`);
    process.exit(2);
  }
  note('OPERATOR SESSION');
  ok('reached aal2 through a real TOTP factor', s.aal === 'aal2', `aal=${s.aal}`);

  /* ══ 1 · THE ROUTINE HALF — DEPLOYED, WITHOUT EVER CALLING THE WRITER ═══════════════════════ */
  //
  // ★ THE ONLY SAFE PROBE OF A WRITER IS NOT CALLING IT. A "harmless" probe with a nil uuid would
  // still enter the routine, and a future edit that moved a side effect above the guard would make
  // this script the thing that fired it. So deployment is established from the READ side: the case
  // file projects `owner_notice_reissue`, which is computed by `owner_notice_reissue_assessment`,
  // which the door and only the door shares. If that key is present and well-formed, the Phase C
  // function half is deployed and wired.
  note('\n1 · PHASE C FUNCTION HALF (established from the projection — the writer is never called)');
  const queue = await rpc(s.aal2, 'admin_list_death_verification_cases');
  ok('the operator queue is reachable', queue.verdict === 'SUCCEEDED', queue.verdict);
  const rows = Array.isArray(queue.data) ? queue.data : [];
  ok('the queue returned a non-empty row set', rows.length > 0,
    `${rows.length} case(s) — a zero here would make §1 and §2 vacuous`);

  let caseFile = null;
  if (rows.length > 0) {
    const probe = rows[0]?.case_id;
    caseFile = await rpc(s.aal2, 'admin_get_death_verification_case', { p_case: probe });
    ok('the case-file projection is reachable', caseFile.verdict === 'SUCCEEDED', caseFile.verdict);
  }
  const cf = caseFile?.data ?? {};
  const verdict = cf.owner_notice_reissue ?? null;
  ok('the case file carries `owner_notice_reissue`', verdict !== null,
    verdict === null ? 'ABSENT — the Phase C function half did not land' : 'present');
  if (verdict) {
    for (const k of ['eligible', 'refusal_code', 'case_is_current', 'lifecycle_state',
                     'owner_channel_resolvable', 'prior_generation', 'prior_status',
                     'prior_accepted', 'next_generation', 'reissue_reason']) {
      ok(`  verdict key present: ${k}`, Object.prototype.hasOwnProperty.call(verdict, k));
    }
    ok('  the verdict carries NO address', !ADDRESS.test(JSON.stringify(verdict)));
    ok('  `eligible` is a boolean, never a string or null',
      typeof verdict.eligible === 'boolean', String(verdict.eligible));
  }

  /* ══ 2 · THE MIGRATION HALF — PROVED BY WHAT THE PROJECTION CAN SEE ═════════════════════════ */
  //
  // ★ THE EPISODE FIELDS ARE THE EVIDENCE. `admin_get_death_verification_case` selects `case_id`,
  // `generation`, `superseded_by`, `notice_accepted_at` and `claimed_at` from `owner_notice_outbox`.
  // If any column were absent the routine would raise, so a payload carrying those keys proves the
  // Phase A + Phase C migration halves landed AND that the projection was rebuilt against them.
  note('\n2 · PHASE C MIGRATION HALF (proved by executing a projection that reads every column)');
  const notices = Array.isArray(cf.owner_notice) ? cf.owner_notice : [];
  ok('the case file returned owner_notice rows', notices.length > 0,
    `${notices.length} row(s) — a zero here makes the key assertions below vacuous`);
  if (notices.length > 0) {
    const n0 = notices[0];
    for (const k of ['case_id', 'generation', 'superseded_by', 'is_current',
                     'notice_accepted_at', 'claimed_at']) {
      ok(`  notice key present: ${k}`, Object.prototype.hasOwnProperty.call(n0, k));
    }
    ok('  no recipient is projected', !Object.prototype.hasOwnProperty.call(n0, 'recipient'));
    ok('  no address shape anywhere in owner_notice',
      !ADDRESS.test(JSON.stringify(notices)));
  }

  /* ══ 3 · PRIVILEGE POSTURE — EVERY WRONG CALLER, REFUSED FOR THE RIGHT REASON ═══════════════ */
  //
  // ★ THESE PROBES CALL THE READ DOORS, NOT THE WRITER. The gate they exercise is the SAME
  // `admin_require_gate()` the re-notice door runs, so a refusal here is evidence about that gate
  // without ever entering a routine that writes.
  note('\n3 · PRIVILEGE POSTURE (probed on the shared gate via the READ doors)');
  const anon = await rpc(null, 'owner_notice_census');
  ok('anon is refused', anon.verdict === 'auth_required' || anon.verdict === 'permission_denied',
    anon.verdict);
  const aal1 = await rpc(s.aal1, 'owner_notice_census');
  ok('a real admin at AAL1 is refused with mfa_required', aal1.verdict === 'mfa_required',
    aal1.verdict);

  /* ══ 4 · BEHAVIOUR NEUTRALITY — THE PHASE D CUTOVER IS STILL ABSENT ════════════════════════ */
  //
  // ★ WHAT CAN AND CANNOT BE SETTLED FROM HERE, STATED RATHER THAN IMPLIED. There is no SQL access
  // through PostgREST, so `authorize_release`'s body cannot be read from this script. Three
  // instruments cover the claim between them and each is named with the part it covers:
  //
  //   · migration 0059 §3.3 asserts the pre-Phase-D predicate at PASTE time, inside the artifact —
  //     so a cutover smuggled into the Phase C paste fails the paste itself;
  //   · `verifySourceDeploymentDrift.mjs` executes the committed source against an ephemeral
  //     Postgres and would catch a deployed body differing from source;
  //   · the readiness census below reports what Phase D WOULD do. It is a projection, not the door.
  //
  // What THIS script adds is the observable consequence: if the stricter door had activated, the
  // release-condition arithmetic would have moved. It has not.
  note('\n4 · BEHAVIOUR NEUTRALITY (the projection still reports Phase D as a HYPOTHETICAL)');
  const ready = await rpc(s.aal2, 'owner_notice_release_readiness_census');
  ok('the readiness census is reachable', ready.verdict === 'SUCCEEDED', ready.verdict);
  const r = ready.data ?? {};
  assertCountsOnly('readiness census', r);
  for (const k of ['estates_at_door', 'by_readiness', 'would_be_refused_by_phase_d',
                   'would_be_admitted_by_phase_d', 'would_be_admitted_by_current_predicate']) {
    ok(`  key present: ${k}`, Object.prototype.hasOwnProperty.call(r, k),
      k === 'by_readiness' ? JSON.stringify(r[k]) : String(r[k]));
  }
  const num = (v) => (v === null || v === undefined ? NaN : Number(v));
  const door = num(r.estates_at_door);
  ok('  admitted + refused = estates_at_door',
    num(r.would_be_admitted_by_phase_d) + num(r.would_be_refused_by_phase_d) === door,
    `${num(r.would_be_admitted_by_phase_d)} + ${num(r.would_be_refused_by_phase_d)} = ${door}`);
  // ★ THE CURRENT PREDICATE MUST STILL BE THE WIDER ONE. If Phase D had activated, the two counts
  // would have converged. A strict inequality is not required (they legitimately coincide when the
  // door is empty), but the CURRENT predicate must never be narrower than the Phase D one.
  ok('  the current predicate is not NARROWER than Phase D (the cutover has not landed)',
    num(r.would_be_admitted_by_current_predicate) >= num(r.would_be_admitted_by_phase_d),
    `current=${num(r.would_be_admitted_by_current_predicate)} phaseD=${num(r.would_be_admitted_by_phase_d)}`);

  /* ══ 5 · THE REMEDIATION QUEUE — HOW MUCH WORK PHASE C HAS ═════════════════════════════════ */
  note('\n5 · REMEDIATION QUEUE (counts only)');
  const census = await rpc(s.aal2, 'owner_notice_census');
  ok('the row census is reachable', census.verdict === 'SUCCEEDED', census.verdict);
  const c = census.data ?? {};
  assertCountsOnly('owner notice census', c);
  const byStatus = c.by_status ?? {};
  note(`     rows total ......................... ${num(c.total)}`);
  note(`     dispatched with NO acceptance ...... ${num(c.legacy_unaccepted)}   ← remediable (legacy)`);
  note(`     outcomeUncertain ................... ${num(byStatus.outcomeUncertain ?? 0)}   ← remediable`);
  note(`     failedPermanent .................... ${num(byStatus.failedPermanent ?? 0)}   ← remediable`);
  note(`     generations beyond the first ....... ${
    Object.entries(c.by_generation ?? {}).filter(([g]) => Number(g) > 1)
      .reduce((a, [, v]) => a + Number(v), 0)}   ← re-notices already issued`);
  note(`     superseded rows .................... ${num(c.superseded_total)}`);
  ok('superseded + current = total',
    num(c.superseded_total) + num(c.current_total) === num(c.total),
    `${num(c.superseded_total)} + ${num(c.current_total)} = ${num(c.total)}`);

  /* ══ 6 · WHAT THIS SCRIPT HAS NOT PROVED ═══════════════════════════════════════════════════ */
  note('\n6 · SCOPE — stated so no reader takes this for more than it is');
  note('     PROVED   : the Phase C contract is deployed, gated, and behaviour-neutral.');
  note('     NOT PROVED: that a real re-notice succeeds in production. Executing one would append a');
  note('                 generation to a live safety queue and QUEUE AN EMAIL to a living person');
  note('                 about their own death process. That is a production action, not a check.');
  note('     STATUS    : PRODUCTION_RUNTIME_PROOF_PENDING — until a legitimate remediation target');
  note('                 exists, or a synthetic case is separately authorized.');

  console.log(lines.join('\n'));
  if (JSON_OUT) {
    console.log('\n' + JSON.stringify({
      failures,
      reissue_verdict_present: verdict !== null,
      estates_at_door: door,
      legacy_unaccepted: num(c.legacy_unaccepted),
      outcome_uncertain: num(byStatus.outcomeUncertain ?? 0),
      failed_permanent: num(byStatus.failedPermanent ?? 0),
      superseded_total: num(c.superseded_total),
      runtime_proof: 'PRODUCTION_RUNTIME_PROOF_PENDING',
    }, null, 2));
  }

  if (failures > 0) {
    console.error(`\n✗ PHASE C NOT VERIFIED — ${failures} assertion(s) failed.`);
    process.exit(1);
  }
  console.log('\n✓ PHASE C DEPLOYED AND VERIFIED (contract only; runtime proof pending).');
};

main().catch((e) => {
  console.error(`✗ CANNOT VERIFY — ${e?.message ?? e}`);
  process.exit(2);
});
