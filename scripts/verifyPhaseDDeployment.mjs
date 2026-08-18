#!/usr/bin/env node
/**
 * PHASE 11-OC · PHASE D DEPLOYMENT VERIFICATION — read-only.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ THE ONE QUESTION THIS EXISTS TO ANSWER, AND WHY "IT PASTED WITHOUT ERROR" DOES NOT ANSWER IT.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 *      IS THE PRODUCTION RELEASE DOOR RUNNING PHASE D SEMANTICS, OR IS IT STILL PHASE C?
 *
 * Those two states are indistinguishable from the outside on every estate that happens to have an
 * accepted notice, and they differ on exactly the population that matters. So the script's whole job
 * is to DISTINGUISH them — `PHASE_D_DEPLOYED` from `PHASE_C_STILL_ACTIVE` — and to refuse to guess.
 *
 * ★ IT PROVES THE CONTRACT IS DEPLOYED. IT DOES NOT PROVE A RELEASE WORKS.
 *
 * Those are two different claims and this repository has conflated them before. Calling
 * `authorize_release` in production would IRREVERSIBLY DISCLOSE AN ESTATE. There is no "harmless
 * probe" of that routine: a nil uuid still enters it, and a future edit that moved a side effect
 * above a guard would make this script the thing that fired it. So:
 *
 *      DEPLOYED CONTRACT PROOF   ← this script
 *      LIVE RELEASE PROOF        ← never, as a side effect of a check. Branch B, separately
 *                                  authorized, against a synthetic estate, after a real seven days.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ HOW IT SEES THE DOOR WITHOUT TOUCHING IT.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * PostgREST exposes no SQL, so `authorize_release`'s body cannot be read from here. What CAN be read
 * is the projection the door shares its policy with. Phase D's central architectural property is
 * that `admin_get_death_verification_case` and `authorize_release` consume the SAME function —
 * `owner_notice_release_authority` — so the projection is not a proxy for the door's rule, it IS the
 * door's rule, evaluated on the same row.
 *
 * That gives four independent, read-only signals:
 *
 *   1 · the `release_authority` key EXISTS in the case file      → the authority is deployed
 *   2 · its refusal vocabulary is the PHASE D set                → not a Phase C shape wearing a new
 *                                                                  name
 *   3 · `window.release_eligible_at` is NULL exactly when there  → the CLOCK moved, not just the
 *       is no acceptance fact, and equals acceptance + duration     qualification
 *       when there is
 *   4 · Phase C's remedy is still deployed and still gated       → the cutover did not orphan the
 *                                                                  population it blocks
 *
 * Signal 3 is the one that cannot be faked by a rename: a Phase C server computes that field from
 * `owner_notified_at`, which is NEVER null on a dispatched case — so a NULL there, on a case whose
 * lifecycle carries a dispatch timestamp, is arithmetic proof that the anchor changed.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ WHY IT CANNOT MUTATE, STATED AS PROPERTIES A READER CAN CHECK.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 *   · It calls exactly THREE remote routines — `admin_list_death_verification_cases`,
 *     `admin_get_death_verification_case` and `owner_notice_release_readiness_census` — all three
 *     declared `stable` in source, and a `stable` function cannot write.
 *   · It NEVER names `authorize_release`, `reissue_owner_safety_notice`, `begin_challenge_window`,
 *     `challenge_death_process`, `dispatch_owner_safety_notice` or `record_owner_notice_outcome`.
 *     `test/noProductionMutation.test.ts` enumerates the RPCs a read-only script may name and FAILS
 *     if a mutation RPC appears — so this property is enforced, not promised.
 *   · It never reads CRON_SECRET and never requests the drain route.
 *   · It refuses a secret/service-role key outright. An operator assertion may never run as
 *     service_role — that would BYPASS `admin_require_gate()`, which is part of what is under test,
 *     and a verifier that skips the gate it is verifying is the vacuous-audit failure again.
 *
 * ★ IT PRINTS NO IDENTITY. The case-file projection is per-case by construction and carries an
 * initiator email, so this script reads it for SHAPE and prints nothing from it but booleans, key
 * names and refusal codes. Every payload is scanned for an address before anything is printed.
 *
 * ★ ZERO IS NOT THE SAME AS BROKEN, AND NEITHER IS "NO CASES". A production estate count of zero at
 * the release door is a legitimate result — it is exactly what the August census reported. What is
 * NOT legitimate is a green verdict produced by an empty scan set, so §0 asserts the queue is
 * non-empty BEFORE any conclusion is drawn from it, and downgrades to CANNOT_VERIFY otherwise.
 *
 * Usage:  node scripts/verifyPhaseDDeployment.mjs [--json]
 * Exit:   0 Phase D verified · 1 a Phase D assertion failed · 2 could not verify (never a pass)
 */
import crypto from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
// ★ THE SCOPE SUMMARY LIVES IN A TESTABLE MODULE, NOT INLINE HERE. `main()` cannot run without a
// live AAL2 session, so prose built in it is unreachable from every test and every mutation — which
// is precisely how this script once shipped claiming a deployment on a PHASE_C_STILL_ACTIVE run.
// See scripts/lib/phaseDVerdictProse.mjs and test/phaseDVerdictProse.test.ts.
import { PHASE_C_STILL_ACTIVE, PHASE_D_DEPLOYED, scopeReport } from './lib/phaseDVerdictProse.mjs';

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
  lines.push(`  ${pass ? '✓' : '✗'} ${label.padEnd(60)} ${detail}`);
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

/**
 * ★ THE PHASE D REFUSAL VOCABULARY, SINGLE-SOURCED WITH THE SERVER BY SHAPE RATHER THAN BY HOPE.
 * A Phase C server cannot produce any of these, because it has no authority to produce them from.
 */
const PHASE_D_CODES = new Set([
  'case_not_found', 'no_verified_case', 'notice_episode_mismatch', 'invalid_release_state',
  'no_current_notice', 'notice_never_accepted', 'release_window_not_configured',
  'release_window_not_elapsed',
]);
const AUTHORITY_KEYS = ['ready', 'refusal_code', 'case_id', 'case_is_current', 'lifecycle_state',
  'notice_id', 'generation', 'notice_kind', 'notice_accepted_at', 'accepted', 'window_duration',
  'window_configured', 'release_eligible_at', 'elapsed'];

const main = async () => {
  console.log(`Phase 11-OC · PHASE D DEPLOYMENT VERIFICATION · ${URL_.replace(/^https?:\/\//, '').split('.')[0]}`);
  console.log(`UTC ${new Date().toISOString()}\n`);

  const s = await aal2Session('AW_ADMIN_TEST_A');
  if (s.error) {
    console.error(`✗ CANNOT VERIFY — ${s.error}`);
    process.exit(2);
  }
  note('OPERATOR SESSION');
  ok('reached aal2 through a real TOTP factor', s.aal === 'aal2', `aal=${s.aal}`);

  /* ══ 0 · THE SCAN SET, ASSERTED BEFORE ANY RULE IS EVALUATED ═══════════════════════════════ */
  //
  // ★ THE DASHBOARD NEAR-MISS, APPLIED HERE. An audit that resolved its root one directory short
  // ran 63 assertions against an empty file list and passed. The equivalent here is a queue that
  // returns nothing: every §1-§3 assertion would be skipped and the script would print a clean
  // verdict having inspected no case at all. So the set is asserted first, and an empty one is
  // CANNOT_VERIFY (exit 2) rather than a pass.
  note('\n0 · THE SCAN SET (asserted before any conclusion is drawn from it)');
  const queue = await rpc(s.aal2, 'admin_list_death_verification_cases');
  ok('the operator queue is reachable', queue.verdict === 'SUCCEEDED', queue.verdict);
  const rows = Array.isArray(queue.data) ? queue.data : [];
  if (rows.length === 0) {
    console.log(lines.join('\n'));
    console.error('\n✗ CANNOT VERIFY — the operator queue returned ZERO cases, so every assertion');
    console.error('  below would be evaluated against nothing and report green. This is reported as');
    console.error('  a failure to verify, never as a clean result.');
    process.exit(2);
  }
  ok('the queue returned a non-empty case set', rows.length > 0, `${rows.length} case(s)`);

  /* ══ 1 · IS THE AUTHORITY DEPLOYED AT ALL — PHASE_D vs PHASE_C ═════════════════════════════ */
  note('\n1 · THE RELEASE AUTHORITY (the signal that distinguishes Phase D from Phase C)');
  const probe = rows[0]?.case_id;
  const caseFile = await rpc(s.aal2, 'admin_get_death_verification_case', { p_case: probe });
  ok('the case-file projection is reachable', caseFile.verdict === 'SUCCEEDED', caseFile.verdict);
  const cf = caseFile.data ?? {};
  const authority = cf.release_authority ?? null;

  const phase = authority === null ? PHASE_C_STILL_ACTIVE : PHASE_D_DEPLOYED;
  ok('the case file carries `release_authority`', authority !== null,
    authority === null
      ? 'ABSENT — the release door is still on Phase C semantics'
      : 'present');

  if (authority) {
    for (const k of AUTHORITY_KEYS) {
      ok(`  authority key present: ${k}`, Object.prototype.hasOwnProperty.call(authority, k));
    }
    ok('  `ready` is a boolean, never a string or null',
      typeof authority.ready === 'boolean', String(authority.ready));
    ok('  the refusal code is from the PHASE D vocabulary',
      authority.refusal_code === null || PHASE_D_CODES.has(authority.refusal_code),
      String(authority.refusal_code));
    ok('  the authority carries NO address', !ADDRESS.test(JSON.stringify(authority)));
    // ★ NOT A DELIVERY CLAIM, AT THE WIRE. If a future edit renamed the fact into something that
    // asserts delivery, it would reach a console label and then an operator. Caught here.
    ok('  no field claims delivery/receipt/opening',
      !/deliver|received|opened|read_at/i.test(JSON.stringify(Object.keys(authority))));
  }

  /* ══ 2 · DID THE CLOCK MOVE — the signal a rename cannot fake ══════════════════════════════ */
  //
  // ★ THIS IS THE ARITHMETIC PROOF, AND IT IS THE POINT OF THE WHOLE SCRIPT. A Phase C server
  // computes `release_eligible_at` from `owner_notified_at`, which is NON-NULL on every dispatched
  // case. So on a case with a dispatch timestamp and NO acceptance fact:
  //
  //     Phase C  →  release_eligible_at is a DATE   (owner_notified_at + duration)
  //     Phase D  →  release_eligible_at is NULL     (there is nothing to anchor on)
  //
  // and where an acceptance fact DOES exist, Phase D's value must equal acceptance + duration. Both
  // directions are checked; either alone could be satisfied by an unrelated bug.
  note('\n2 · DID THE CLOCK MOVE (checked arithmetically, in both directions)');
  const win = cf.window ?? {};
  const notifiedAt = cf.lifecycle?.owner_notified_at ?? null;
  let clockChecked = false;

  if (authority && win.configured) {
    if (authority.notice_accepted_at === null) {
      ok('  no acceptance fact ⇒ release_eligible_at is NULL',
        win.release_eligible_at === null,
        win.release_eligible_at === null
          ? 'NULL (Phase D)'
          : `${win.release_eligible_at} — a date derived from provenance (Phase C)`);
      ok('  …and the lifecycle DOES carry a dispatch timestamp, so the NULL is meaningful',
        notifiedAt !== null,
        notifiedAt === null ? 'no dispatch timestamp — this case cannot distinguish the two' : 'yes');
      clockChecked = notifiedAt !== null;
    } else {
      const expected = new Date(
        Date.parse(authority.notice_accepted_at) + durationMs(authority.window_duration)
      ).toISOString();
      ok('  acceptance fact present ⇒ eligible_at = acceptance + duration',
        win.release_eligible_at !== null &&
          Math.abs(Date.parse(win.release_eligible_at) - Date.parse(expected)) < 1000,
        `${win.release_eligible_at} vs ${expected}`);
      ok('  …and it is NOT owner_notified_at + duration',
        notifiedAt === null ||
          Math.abs(Date.parse(win.release_eligible_at) - Date.parse(notifiedAt) -
            durationMs(authority.window_duration)) > 1000,
        'anchor is the acceptance fact');
      clockChecked = true;
    }
  }
  ok('the clock anchor was actually observed on this case', clockChecked,
    clockChecked ? '' : 'INDETERMINATE — this case could not distinguish the anchors');

  /* ══ 3 · THE REMEDY SURVIVED THE CUTOVER ═══════════════════════════════════════════════════ */
  //
  // ★ PHASE D WITHOUT PHASE C IS A TRAP. Phase D creates new legitimate refusal states a running
  // system reaches on its own, and the drain never re-sends a terminal row. Without the re-notice
  // remedy the first post-cutover provider failure produces a permanently unreleasable estate whose
  // only recovery is hand-written SQL against a safety table.
  note('\n3 · THE PHASE C REMEDY IS STILL DEPLOYED AND STILL GATED');
  ok('the case file still carries `owner_notice_reissue`',
    (cf.owner_notice_reissue ?? null) !== null);
  const anon = await rpc(null, 'owner_notice_release_readiness_census');
  ok('anon is refused by the shared gate',
    anon.verdict === 'auth_required' || anon.verdict === 'permission_denied', anon.verdict);
  const aal1 = await rpc(s.aal1, 'owner_notice_release_readiness_census');
  ok('a real admin at AAL1 is refused with mfa_required', aal1.verdict === 'mfa_required',
    aal1.verdict);

  /* ══ 4 · THE POPULATION AT THE DOOR, AS COUNTS ═════════════════════════════════════════════ */
  note('\n4 · THE POPULATION AT THE RELEASE DOOR (counts only)');
  const census = await rpc(s.aal2, 'owner_notice_release_readiness_census');
  ok('the readiness census is reachable', census.verdict === 'SUCCEEDED', census.verdict);
  const c = census.data ?? {};
  assertCountsOnly('the readiness census', c);
  const num = (v) => Number(v ?? 0);
  note(`     estates at the release door ........ ${num(c.estates_at_door)}`);
  note(`     would be ADMITTED by Phase D ....... ${num(c.would_be_admitted_by_phase_d)}`);
  note(`     would be REFUSED by Phase D ........ ${num(c.would_be_refused_by_phase_d)}`);
  ok('admitted + refused = estates at the door',
    num(c.would_be_admitted_by_phase_d) + num(c.would_be_refused_by_phase_d)
      === num(c.estates_at_door));
  if (num(c.would_be_refused_by_phase_d) > 0) {
    note(`     → ${num(c.would_be_refused_by_phase_d)} estate(s) are the Phase C queue. An operator`);
    note('       re-notice PRODUCES the missing fact. No manual SQL repair is required, or permitted.');
  }

  /* ══ 5 · SCOPE — stated so no reader takes this for more than it is ════════════════════════ */
  //
  // ★ VERDICT, EXIT CODE AND PROSE ALL DERIVE FROM ONE CALL, so they cannot disagree. The first
  // draft built this inline and unconditionally, and printed "PROVED: the Phase D release authority
  // is deployed" three lines above its own `PHASE_C_STILL_ACTIVE` verdict. The checks were right;
  // the summary contradicted them, and the summary is what a human carries away.
  const scope = scopeReport(phase, failures);
  note('\n5 · SCOPE');
  for (const line of scope.lines) note(line);

  console.log(lines.join('\n'));
  if (JSON_OUT) {
    console.log('\n' + JSON.stringify({
      failures,
      phase,
      release_authority_present: authority !== null,
      clock_anchor_observed: clockChecked,
      estates_at_door: num(c.estates_at_door),
      would_be_admitted: num(c.would_be_admitted_by_phase_d),
      would_be_refused: num(c.would_be_refused_by_phase_d),
      runtime_proof: 'PRODUCTION_RUNTIME_PROOF_PENDING',
    }, null, 2));
  }

  // ★ ONE SOURCE FOR THE EXIT CODE TOO. Observing Phase C IS a failure to verify Phase D even when
  // no individual assertion errored, so the code comes from the same evaluation as the prose.
  if (scope.exitCode !== 0) {
    console.error(`\n✗ PHASE D NOT VERIFIED — ${failures} assertion(s) failed. Deployment state: ${phase}.`);
    process.exit(1);
  }
  console.log(`\n✓ ${phase} (contract only; runtime proof pending).`);
};

/**
 * Postgres prints an interval as `7 days`, `7 days 00:00:00`, or `1 day 02:03:04`. Parsed rather
 * than assumed, and an unparseable value returns NaN so the comparison FAILS loudly instead of
 * silently matching everything.
 */
function durationMs(text) {
  if (typeof text !== 'string') return NaN;
  let ms = 0;
  const days = /(-?\d+)\s+days?/.exec(text);
  if (days) ms += Number(days[1]) * 86400000;
  const hms = /(\d+):(\d{2}):(\d{2})/.exec(text);
  if (hms) ms += (Number(hms[1]) * 3600 + Number(hms[2]) * 60 + Number(hms[3])) * 1000;
  return days || hms ? ms : NaN;
}

main().catch((e) => {
  console.error(`✗ CANNOT VERIFY — ${e?.message ?? e}`);
  process.exit(2);
});
