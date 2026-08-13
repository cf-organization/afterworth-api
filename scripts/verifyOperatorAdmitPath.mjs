#!/usr/bin/env node
/**
 * Phase 11-K — the ADMIT half: prove the operator doors OPEN for a real AAL2 admin, and separate
 * ADMIN AUTHORIZATION from MFA ASSURANCE by showing the two axes fail differently.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ WHY THIS IS A SEPARATE SCRIPT FROM verifyOperatorDoorRefusal.mjs.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * That one proves the REFUSE half and needs no credential. This one needs two synthetic AAL2 admin
 * identities and cannot run without them, so folding the two together would make the refuse half —
 * which is most of the security property — unrunnable on a machine without the credential store.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ THE GATE ORDER IS THE POINT, AND IT IS OBSERVABLE.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * `admin_require_gate()` checks auth → is_admin → aal2 → 15-minute freshness, IN THAT ORDER. So the
 * sentinel a caller receives names WHICH axis rejected them:
 *
 *   non-admin, aal1  → admin_required   (is_admin refused; the aal check was never reached)
 *   non-admin, aal2  → admin_required   (MFA assurance buys NOTHING without authorization)
 *   admin,     aal1  → mfa_required     (authorized, insufficiently assured)
 *   admin,     aal2  → SUCCEEDS
 *
 * Rows 2 and 3 are the whole demonstration. A test that only ever saw "it failed" could not tell
 * them apart, and the two mean opposite things: one is an unauthorized person with strong
 * authentication, the other an authorized person with weak authentication.
 *
 * ★ IT DOES NOT INFER AAL2 FROM FACTOR EXISTENCE. The session's own `aal` claim is decoded AND the
 * server is asked to act. An enrolled factor proves an account COULD reach aal2; only a token
 * carrying `aal=aal2` that a gate accepts proves a session DID.
 *
 * ★ NO SECRET IS PRINTED — no password, TOTP seed, access token or refresh token. The uids ARE
 * printed: `public.admins` membership can only be granted by a human running SQL (db/seed_admin.sql),
 * so the uid is a required deliverable, and it is not a credential.
 *
 * ★ READ-ONLY. Three STABLE reads and a sign-in. It advances no death process, dispatches no notice,
 * opens no window and authorizes no release.
 *
 * ★ CLASSIFICATION: TWO-PERSON CONTROL — SINGLE-OPERATOR TEST MODE. Two accounts held by one person
 * prove the mechanism distinguishes two identities. They prove nothing about independent human
 * judgement. Production release requires two distinct humans; that is a launch requirement.
 *
 * Usage:  node scripts/verifyOperatorAdmitPath.mjs
 * Exit:   0 the full matrix held
 *         1 an assertion failed
 *         2 could not verify — never a pass (includes "the admins rows are not inserted yet")
 */
import crypto from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const MOBILE = resolve(ROOT, '../afterworth-mobile');

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
if (!URL_ || !PUB) { console.error('✗ CANNOT VERIFY — supabase url/publishable key absent from afterworth-mobile/.env'); process.exit(2); }
if (PUB.startsWith('sb_secret')) { console.error('✗ REFUSING — that is a secret key. An operator assertion may never use service_role.'); process.exit(2); }

const NIL = '00000000-0000-0000-0000-000000000000';
let failures = 0;
const ok = (label, pass, detail = '') => {
  if (!pass) failures += 1;
  console.log(`  ${pass ? '✓' : '✗'} ${label.padEnd(54)} ${detail}`);
};

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
  return { verdict: classify(r.status, text), data, status: r.status };
}

const decode = (t) => JSON.parse(Buffer.from(t.split('.')[1], 'base64').toString('utf8'));

/** Password grant → aal1. Then factor challenge + verify → aal2. Two DISTINCT tokens are returned. */
async function sessions(prefix) {
  const email = store.get(`${prefix}_EMAIL`);
  const password = store.get(`${prefix}_PASSWORD`);
  const seed = store.get(`${prefix}_TOTP_SECRET`);
  const factorId = store.get(`${prefix}_FACTOR_ID`);
  if (!email || !password || !seed || !factorId) return { error: `${prefix}_* incomplete in .env.test` };

  const pw = await req('/auth/v1/token?grant_type=password', { method: 'POST', body: JSON.stringify({ email, password }) });
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

  return { aal1: s1.access_token, aal2: s2.access_token, uid: decode(s1.access_token).sub };
}

console.log(`operator ADMIT-path verification · ${URL_.replace(/^https?:\/\//, '').split('.')[0]}`);
console.log('TWO-PERSON CONTROL: SINGLE-OPERATOR TEST MODE — two synthetic accounts, one holder.\n');

/* ── CONTROLS ─────────────────────────────────────────────────────────────────────────────────── */
console.log('CONTROLS');
{
  const v = totp('GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ', 59);
  ok('RFC 6238 test vector → 287082', v === '287082', v);
  if (v !== '287082') { console.error('\n✗ CANNOT VERIFY — the TOTP generator is wrong; every step-up would look like a server refusal.'); process.exit(2); }
  const neg = await rpc('not-a-token', 'owner_notice_census');
  ok('a garbage token is refused', neg.verdict !== 'SUCCEEDED', neg.verdict);
}

/* ── ESTABLISH BOTH IDENTITIES ────────────────────────────────────────────────────────────────── */
const A = await sessions('AW_ADMIN_TEST_A');
const B = await sessions('AW_ADMIN_TEST_B');
for (const [label, s] of [['A', A], ['B', B]]) {
  if (s.error) { console.error(`\n✗ CANNOT VERIFY — admin test ${label}: ${s.error}`); process.exit(2); }
}

console.log('\nIDENTITIES');
ok('A and B have DISTINCT auth.uid()', A.uid !== B.uid, `${A.uid} / ${B.uid}`);
ok('A aal1 session is genuinely aal1', decode(A.aal1).aal === 'aal1', decode(A.aal1).aal);
ok('A aal2 session is genuinely aal2', decode(A.aal2).aal === 'aal2', decode(A.aal2).aal);
ok('B aal2 session is genuinely aal2', decode(B.aal2).aal === 'aal2', decode(B.aal2).aal);

/* ── THE TWO AXES ─────────────────────────────────────────────────────────────────────────────── */
console.log('\nAXIS SEPARATION — admin authorization vs MFA assurance');
const a1 = await rpc(A.aal1, 'owner_notice_census');
const a2 = await rpc(A.aal2, 'owner_notice_census');
console.log(`  A @ aal1 → ${a1.verdict}`);
console.log(`  A @ aal2 → ${a2.verdict}`);

const isAdmin = a1.verdict === 'mfa_required' || a2.verdict === 'SUCCEEDED';
if (!isAdmin) {
  ok('aal2 alone confers NOTHING without authorization', a2.verdict === 'admin_required', a2.verdict);
  ok('aal1 non-admin refused on the authorization axis', a1.verdict === 'admin_required', a1.verdict);
  console.log('\n' + '─'.repeat(78));
  console.log('⊘ CANNOT VERIFY THE ADMIT HALF — these identities are not in public.admins yet.');
  console.log('');
  console.log('  PROVEN ANYWAY, and it is worth stating: a session with FULL MFA assurance (aal2,');
  console.log('  freshly stepped up through a real TOTP factor) is refused `admin_required`. MFA');
  console.log('  assurance and admin authorization are genuinely independent axes — strong');
  console.log('  authentication buys no operator authority at all.');
  console.log('');
  console.log('  `public.admins` has ZERO grants to ANY role, service_role included, so no automated');
  console.log('  path can insert these rows. That is deliberate — the admins row is the root of all');
  console.log('  operator authority. Per db/seed_admin.sql a human runs it. Then re-run this script.');
  console.log('');
  console.log('  SQL for Christ (Supabase SQL Editor):');
  console.log('');
  console.log('    insert into public.admins (user_id, note) values');
  console.log(`      ('${A.uid}', 'Phase 11 test admin A — SINGLE-OPERATOR TEST MODE'),`);
  console.log(`      ('${B.uid}', 'Phase 11 test admin B — SINGLE-OPERATOR TEST MODE')`);
  console.log('    on conflict do nothing;');
  console.log('');
  process.exit(2);
}

ok('A @ aal1 is refused on the ASSURANCE axis (mfa_required)', a1.verdict === 'mfa_required', a1.verdict);
ok('A @ aal2 SUCCEEDS', a2.verdict === 'SUCCEEDED', a2.verdict);
const b2 = await rpc(B.aal2, 'owner_notice_census');
ok('B @ aal2 SUCCEEDS (a second, independent identity)', b2.verdict === 'SUCCEEDED', b2.verdict);

/* ── THE CENSUS PAYLOAD ───────────────────────────────────────────────────────────────────────── */
console.log('\nCENSUS PAYLOAD');
const census = a2.data;
ok('payload is an object', census && typeof census === 'object', Array.isArray(census) ? 'array' : typeof census);
for (const k of ['total', 'by_status', 'age_gate', 'actionable', 'stale', 'uncertain', 'purgeable']) {
  ok(`key present: ${k}`, census && Object.prototype.hasOwnProperty.call(census, k), k === 'uncertain' ? '← the 11-K bucket' : '');
}
ok('total is a number', typeof census?.total === 'number', String(census?.total));
// ★ THE SPLITS MUST RECONCILE. A nameless gap between total and the named buckets is the number
// someone eventually explains away — which is exactly why `uncertain` was added in 11-K.
const splitSum = (census?.actionable ?? 0) + (census?.stale ?? 0) + (census?.uncertain ?? 0) + (census?.purgeable ?? 0);
ok('actionable+stale+uncertain+purgeable ≤ total', splitSum <= (census?.total ?? -1), `${splitSum} ≤ ${census?.total}`);

// ★ DISCLOSURE. Scan the WHOLE serialized payload, not a field list — a future added field would
// escape a per-field check, and this is a routine whose entire point is that it carries no address.
const blob = JSON.stringify(census ?? {});
ok('no @ character anywhere in the payload', !blob.includes('@'), 'no address shape');
ok('no `recipient` key anywhere', !/recipient/i.test(blob), '');
ok('no `email` key anywhere', !/email/i.test(blob), '');

/* ── THE TWO PROJECTIONS ──────────────────────────────────────────────────────────────────────── */
console.log('\nOPERATOR READ PROJECTIONS (read-only)');
const queue = await rpc(A.aal2, 'admin_list_death_verification_cases', { p_status: null, p_limit: 50 });
ok('queue SUCCEEDS for an AAL2 admin', queue.verdict === 'SUCCEEDED', queue.verdict);
ok('queue returns an array', Array.isArray(queue.data), Array.isArray(queue.data) ? `${queue.data.length} row(s)` : typeof queue.data);
const qBlob = JSON.stringify(queue.data ?? []);
ok('queue discloses no address shape', !qBlob.includes('@'), '');
ok('queue discloses no recipient field', !/recipient/i.test(qBlob), '');
if (Array.isArray(queue.data) && queue.data.length > 0) {
  ok('queue answers owner_channel_resolvable (a boolean, not an address)',
    Object.prototype.hasOwnProperty.call(queue.data[0], 'owner_channel_resolvable'),
    typeof queue.data[0].owner_channel_resolvable);
} else {
  console.log('  · queue is EMPTY — a correct result; no death-verification case has ever been created.');
  console.log('    So the per-row disclosure assertions above are VACUOUSLY true and prove nothing');
  console.log('    about a populated row. The SQL suite covers that against a furnished fixture.');
}

const caseFile = await rpc(A.aal2, 'admin_get_death_verification_case', { p_case: NIL });
// An id belonging to nobody: the gate passes, then the routine reports not-found. That is the
// correct answer and it still proves the door OPENED for this caller.
ok('case file is reachable for an AAL2 admin (not gate-refused)',
  !['admin_required', 'mfa_required', 'auth_required', 'permission_denied', 'NOT_DEPLOYED'].includes(caseFile.verdict),
  caseFile.verdict);

/* ── REVIEWER-A DERIVATION IS SERVER-SIDE ─────────────────────────────────────────────────────── */
console.log('\nTWO-IDENTITY RELEASE CONTROL — what is provable without a death process');
const rel = await rpc(A.aal2, 'authorize_release', { p_estate: NIL, p_reason: 'read-only signature probe' });
ok('authorize_release is reachable and admin-gated, NOT open',
  !['admin_required', 'mfa_required', 'permission_denied', 'NOT_DEPLOYED'].includes(rel.verdict), rel.verdict);
const relWithReviewer = await rpc(A.aal2, 'authorize_release', { p_estate: NIL, p_reason: 'x', p_reviewer_a: A.uid });
ok('a caller CANNOT supply reviewer_a (no such parameter exists)',
  relWithReviewer.verdict === 'NOT_DEPLOYED' || relWithReviewer.status === 404,
  `${relWithReviewer.verdict} — signature rejects the extra argument`);
console.log('  · reviewer A is derived inside the routine from the verified case\'s decider, and');
console.log('    reviewer B is auth.uid(). Same-account replay refusal needs a case in a');
console.log('    release-eligible state, i.e. a death process — deliberately NOT started here.');
console.log('    db/tests/release_safety_authorization.sql covers it against real Postgres.');

console.log('\n' + '═'.repeat(78));
if (failures === 0) {
  console.log('✓ ADMIT HALF VERIFIED THROUGH THE PRODUCT PATH.');
  console.log('  Both identities reached aal2 through a real TOTP factor, both were admitted, they');
  console.log('  hold distinct auth.uid() values, and the same identity is refused `mfa_required` at');
  console.log('  aal1 — so authorization and assurance were each observed rejecting independently.');
  console.log('');
  console.log('  CLASSIFICATION: TWO-PERSON CONTROL — SINGLE-OPERATOR TEST MODE.');
  console.log('  Two accounts, one holder. Production release requires two distinct humans.');
} else {
  console.log(`✗ ${failures} assertion(s) failed.`);
}
process.exit(failures === 0 ? 0 : 1);
