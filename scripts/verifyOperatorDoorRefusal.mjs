#!/usr/bin/env node
/**
 * Phase 11-K — prove the three OPERATOR doors are deployed and REFUSING, without an admin account.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ WHY THIS EXISTS. TWO VERIFIERS EXIST AND NEITHER TOUCHES THESE DOORS.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * `afterworth-mobile/scripts/verifyDeployedContracts.mjs` probes the contracts the APP consumes; the
 * operator console is not the app, so `owner_notice_census`, `admin_list_death_verification_cases`
 * and `admin_get_death_verification_case` appear in neither its required list nor its posture checks.
 * `verifySourceDeploymentDrift.mjs` reconciles PURE functions by executing both sides; all three of
 * these read rows, so it correctly lists their neighbours as UNVERIFIABLE-BY-THIS-INSTRUMENT and
 * never opens the operator bundle at all.
 *
 * The result after the 11-K paste was that the ONLY evidence about the three new doors was six
 * hand-run SQL-Editor queries against the catalog. Those prove the objects and grants exist. They do
 * not prove the DOORS BEHAVE — that a real caller arriving over PostgREST with a real JWT is refused
 * by the gate rather than by a missing grant, or worse, admitted.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ WHAT IT CAN PROVE WITHOUT AN ADMIN ACCOUNT, AND WHAT IT DELIBERATELY CANNOT.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * PROVABLE HERE — the REFUSE half. Everything a NON-admin must be denied. That is most of the
 * security property, and it needs no privileged credential: an ordinary estate owner's session is a
 * stronger negative subject than a stranger's, because an owner has a real relationship to a real
 * estate and must STILL be refused an operator view of it.
 *
 * NOT PROVABLE HERE — the ADMIT half. That a real AAL2 admin SUCCEEDS, that the census payload is
 * structurally valid, that the `uncertain` bucket is populated. Those require an authenticated AAL2
 * operator identity with a live TOTP factor. This script reports that gap by name at the end rather
 * than omitting it, because a verifier that lists only what it checked reads as complete coverage.
 *
 * ★ NO SERVICE ROLE, NO WRITES, NO ELEVATION. The publishable key plus one ordinary user's own JWT —
 * byte-for-byte the transport `afterworth-admin/lib/rpc.ts` uses. A service-role read could reach
 * these rows trivially and would prove NOTHING about an operator's authority, which is the entire
 * question. Authority is decided by SOURCE, never by whether a caller could obtain the values.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ A REFUSAL IS ONLY EVIDENCE IF THE SENTINEL IS CHECKED.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 *   admin_required     the caller PASSED the EXECUTE grant and the in-body gate refused.  ← deployed
 *   permission denied  the EXECUTE grant refused. Correct for anon, and for the worker pair only.
 *   auth_required      no identity reached the routine at all (this is the SQL-Editor result).
 *   PGRST202 / 42883   THE ROUTINE IS NOT DEPLOYED.
 *
 * The last one is why every expectation below names its sentinel. A test that accepts "the call
 * failed" passes identically against a correctly-gated door and against an empty database — and
 * would have reported this phase as verified had the paste never happened.
 *
 * ★ NO CREDENTIAL, ADDRESS, ESTATE ID OR CASE ID IS PRINTED. Credentials are read in-process from
 * the gitignored `.env.test` and never reach output, argv or a log line.
 *
 * Usage:  node scripts/verifyOperatorDoorRefusal.mjs
 * Exit:   0 every door refused with the correct sentinel
 *         1 a door refused for the WRONG reason, or did not refuse
 *         2 could not verify — never a pass
 */
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createClient } from '@supabase/supabase-js';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const MOBILE = resolve(ROOT, '../afterworth-mobile');

const die = (code, msg, extra = []) => {
  console.error(`\n✗ ${msg}`);
  for (const e of extra) console.error(`    ${e}`);
  process.exit(code);
};

function parseEnvFile(p) {
  const out = new Map();
  if (!existsSync(p)) return out;
  for (const line of readFileSync(p, 'utf8').split('\n')) {
    const m = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/.exec(line.trim());
    if (m) out.set(m[1], m[2].replace(/^["']|["']$/g, ''));
  }
  return out;
}

// ★ The URL/key come from the MOBILE app env deliberately — the same pair the product ships with, so
// this cannot accidentally reconcile against a different project than the app talks to.
const appEnv = parseEnvFile(join(MOBILE, '.env'));
const testEnv = parseEnvFile(join(MOBILE, '.env.test'));
const URL_ = appEnv.get('EXPO_PUBLIC_SUPABASE_URL');
const KEY = appEnv.get('EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY');
if (!URL_ || !KEY) {
  die(2, 'CANNOT VERIFY — EXPO_PUBLIC_SUPABASE_URL / _PUBLISHABLE_KEY missing from afterworth-mobile/.env');
}
if (KEY.startsWith('sb_secret')) {
  die(2, 'REFUSING TO RUN with a secret key — a service-role read proves nothing about operator authority.');
}

/** A uuid that belongs to nobody. Satisfies the type, names no real row. */
const NIL = '00000000-0000-0000-0000-000000000000';
let failures = 0;

function classify(err) {
  const m = `${err?.message ?? ''} ${err?.code ?? ''}`;
  if (/PGRST202|42883|Could not find the function|does not exist/i.test(m)) return 'NOT_DEPLOYED';
  if (/auth_required/.test(m)) return 'auth_required';
  if (/admin_required/.test(m)) return 'admin_required';
  if (/mfa_required/.test(m)) return 'mfa_required';
  if (/stale_token_reauth_required/.test(m)) return 'stale_token';
  if (/permission denied/i.test(m)) return 'permission_denied';
  if (/JWT|No API key|Invalid API key|invalid claim/i.test(m)) return 'no_identity';
  return `other(${err?.code ?? '?'})`;
}

// ★ A SUCCESSFUL CALL GETS A NAMED VERDICT, NOT `undefined`. The worst outcome this script can
// observe is a door that ADMITS a non-admin, and the first draft printed that as `undefined` — the
// single most important failure rendered as the least legible line in the output. `ADMITTED` is
// never in any `allowed` list below, so it always fails, and now it says what it found.
const call = async (client, fn, args) => {
  const { data, error } = await client.rpc(fn, args);
  return error ? { ok: false, verdict: classify(error) } : { ok: true, verdict: 'ADMITTED', data };
};

const expect = (label, verdict, allowed) => {
  const pass = allowed.includes(verdict);
  if (!pass) failures += 1;
  console.log(`  ${pass ? '✓' : '✗'} ${label.padEnd(52)} ${verdict}`);
  if (!pass) console.log(`      EXPECTED one of: ${allowed.join(' | ')}`);
};

console.log(`operator-door refusal probe · ${URL_.replace(/^https?:\/\//, '').split('.')[0]}\n`);

/* ── CONTROLS FIRST. Without them a refusal and an empty database look identical. ───────────── */
const anon = createClient(URL_, KEY, { auth: { persistSession: false } });

console.log('CONTROLS');
const pos = await call(anon, 'notification_event_copy', { p_event: 'invitation_accepted' });
console.log(`  ${pos.ok ? '✓' : '✗'} positive  a deployed anon-callable routine is reachable  ${pos.ok ? 'PRESENT' : pos.verdict}`);
if (!pos.ok) {
  die(2, 'FAILED POSITIVE CONTROL — cannot reach a routine known to be deployed.',
    ['A failed positive control means the INSTRUMENT is broken, never that the doors are absent.',
     'No refusal or absence claim below would be valid. Investigate before concluding anything.']);
}
const neg = await call(anon, 'aw_probe_routine_that_cannot_exist', {});
console.log(`  ${neg.verdict === 'NOT_DEPLOYED' ? '✓' : '✗'} negative  an UNDEPLOYED routine is detected as absent   ${neg.verdict}`);
if (neg.verdict !== 'NOT_DEPLOYED') die(2, 'FAILED NEGATIVE CONTROL — cannot distinguish deployed from absent.');
console.log('  → a refusal below therefore proves the routine EXISTS; absence would read NOT_DEPLOYED.\n');

/* ── ANON. Execute is revoked from anon on all three doors, so the GRANT must refuse. ───────── */
console.log('ANON — no identity. EXECUTE is revoked from anon on all three doors.');
expect('owner_notice_census()',
  (await call(anon, 'owner_notice_census', {})).verdict, ['permission_denied', 'no_identity']);
expect('admin_list_death_verification_cases()',
  (await call(anon, 'admin_list_death_verification_cases', { p_status: null, p_limit: 1 })).verdict,
  ['permission_denied', 'no_identity']);
expect('admin_get_death_verification_case()',
  (await call(anon, 'admin_get_death_verification_case', { p_case: NIL })).verdict,
  ['permission_denied', 'no_identity']);

/* ── AN AUTHENTICATED, NON-ADMIN ESTATE OWNER — the strong negative subject. ────────────────── */
const email = testEnv.get('AW_OR_OWNER_EMAIL');
const password = testEnv.get('AW_OR_OWNER_PASSWORD');
if (!email || !password) {
  die(2, 'CANNOT VERIFY — AW_OR_OWNER_EMAIL/_PASSWORD absent from afterworth-mobile/.env.test.',
    ['The refuse half needs a REAL authenticated non-admin identity. Anon alone cannot show that a',
     'caller who passes the EXECUTE grant is then refused by the gate — the property that matters.']);
}
const owner = createClient(URL_, KEY, { auth: { persistSession: false } });
const { data: signedIn, error: signInErr } = await owner.auth.signInWithPassword({ email, password });
if (signInErr || !signedIn?.session) die(2, `CANNOT VERIFY — sign-in failed: ${signInErr?.message ?? 'no session'}`);

// Assert the SUBJECT before trusting the refusals: a session that is secretly admin, or secretly
// aal2, would make every `admin_required` below mean something entirely different.
const claims = JSON.parse(Buffer.from(signedIn.session.access_token.split('.')[1], 'base64').toString('utf8'));
const aal = claims.aal ?? 'aal1';
console.log(`\nAUTHENTICATED NON-ADMIN OWNER — aal=${aal} · role=${claims.role}`);
if (aal !== 'aal1') {
  die(2, `CANNOT VERIFY — the probe subject is ${aal}, not aal1.`,
    ['This leg must be an aal1 non-admin for `admin_required` to mean "the admin check refused".']);
}
// ★ THE SIGNATURE MATTERS. Called with no argument this returns PGRST202, which classifies as
// NOT_DEPLOYED and halted an early run of this probe — an instrument defect, not a deployment one.
const ownCtl = await call(owner, 'get_my_estate_capability_facts', { p_estate: NIL });
console.log(`  ${ownCtl.ok ? '✓' : '✗'} control   this session can reach its OWN product surface  ${ownCtl.ok ? 'OK' : ownCtl.verdict}`);
if (!ownCtl.ok) {
  die(2, 'FAILED POSITIVE CONTROL — the owner session is not functional.',
    ['A refusal from a broken session is not evidence of a working gate.']);
}

console.log('\n  the three operator doors — the GRANT passes, the GATE must refuse');
expect('owner_notice_census()',
  (await call(owner, 'owner_notice_census', {})).verdict, ['admin_required']);
expect('admin_list_death_verification_cases()',
  (await call(owner, 'admin_list_death_verification_cases', { p_status: null, p_limit: 1 })).verdict,
  ['admin_required']);
expect('admin_get_death_verification_case()',
  (await call(owner, 'admin_get_death_verification_case', { p_case: NIL })).verdict, ['admin_required']);

/* ── THE WORKER PAIR. No client role may hold EXECUTE at all — not even an operator's. ──────── */
// ★ SAFE TO CALL, AND ARRANGED SO RATHER THAN HOPED. Claiming MUTATES (rows move to `processing`),
// so this is only defensible because the grant is refused before any body runs. Two independent
// reasons it cannot write: deployment verifier #2 already proved `authenticated` holds no EXECUTE on
// either routine, and `record_owner_notice_outcome` is passed an id belonging to nobody, so even an
// open grant would raise not-found. If this leg ever reports anything OTHER than permission_denied,
// the grant has been widened and that is a HIGH finding, not a probe failure.
console.log('\n  the WORKER pair — a console click must never be able to strand a live notice');
expect('claim_owner_notices()',
  (await call(owner, 'claim_owner_notices', { p_max: 1 })).verdict, ['permission_denied']);
expect('record_owner_notice_outcome()',
  (await call(owner, 'record_owner_notice_outcome', { p_id: NIL, p_outcome: 'providerAccepted', p_failure_class: null })).verdict,
  ['permission_denied']);

/* ── AN ESTATE RELATIONSHIP IS NOT OPERATOR AUTHORITY. ─────────────────────────────────────── */
// This owner OWNS a real estate. If ownership leaked an operator view, it would leak here.
console.log('\n  an estate relationship must not become operator authority');
expect('ownership does not grant the case queue',
  (await call(owner, 'admin_list_death_verification_cases', { p_status: 'submitted', p_limit: 50 })).verdict,
  ['admin_required']);

await owner.auth.signOut();

console.log('\n' + '─'.repeat(78));
if (failures === 0) {
  console.log('✓ ALL THREE OPERATOR DOORS ARE DEPLOYED AND REFUSED A NON-ADMIN WITH THE CORRECT SENTINEL.');
  console.log('  `admin_required` (not permission_denied, not PGRST202) proves three things at once:');
  console.log('  the routine exists at that exact signature, the `authenticated` grant is in place,');
  console.log('  and `admin_require_gate()` runs INSIDE the body and refused.');
  console.log('');
  console.log('  NOT PROVEN BY THIS INSTRUMENT — the ADMIT half:');
  console.log('    · that a real AAL2 admin SUCCEEDS on all three doors');
  console.log('    · that the census payload is structurally valid and carries `uncertain`');
  console.log('    · that an AAL1 ADMIN is refused with `mfa_required` (this subject is a non-admin,');
  console.log('      so it is refused one check EARLIER, at `admin_required`)');
  console.log('  Each needs an authenticated AAL2 operator identity with a live TOTP factor.');
} else {
  console.log(`✗ ${failures} door(s) did not refuse, or refused for the WRONG reason.`);
  console.log('  A door answering NOT_DEPLOYED is an undeployed bundle. A door answering OK is open.');
}
process.exit(failures === 0 ? 0 : 1);
