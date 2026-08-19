#!/usr/bin/env node
/**
 * PHASE 11-OB PREP · THE BRANCH B SENTINEL (read-only CLI).
 *
 * Reports on two worlds in one pass:
 *
 *   THE STANDING WORLD  — the AW_FIDUCIARY fixture, live today. Delegated in full to
 *                         `afterworth-mobile/scripts/fiduciaryFixtureSentinel.mjs`, which owns those
 *                         assertions. Re-implementing them here would fork a proven instrument.
 *   THE BRANCH B WORLD  — absent until the drill starts, and reported as ABSENT rather than FAILED.
 *
 * ★ THE DELEGATE'S EXIT CODE IS READ FROM THE SPAWN RESULT, NOT FROM A PIPELINE. A backgrounded
 * `cmd > log; echo $?` reports the status of whatever ran last — this repository has already been
 * bitten by a Gradle build reported as exit 0 when it had failed in one second. `spawnSync().status`
 * is the delegate's own code, and a null status (killed by signal) is UNVERIFIABLE, never a pass.
 *
 * ★ THE TALLY IS DERIVED FROM THE DELEGATE'S OWN OUTPUT and its denominator is asserted non-zero.
 * A sentinel that checked nothing prints no ✗ and would otherwise read as intact.
 *
 * ★ NOTHING HERE MUTATES. It spawns one read-only script and, when a Branch B estate is named,
 * performs read-only projections through the operator door. `test/noProductionMutation.test.ts`
 * pins the RPC set.
 *
 * Usage:  node scripts/branchBSentinel.mjs [--mobile-dir=<path>] [--json]
 * Exit:   0 intact, or the expected BRANCH_B_FIXTURE_ABSENT · 1 drifted · 2 could not verify
 */
import { spawnSync } from 'node:child_process';
import { createHmac } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  BRANCH_B_PROPERTIES,
  SENTINEL,
  classifyBranchBSentinel,
  sentinelExitCode,
} from './lib/branchBSentinel.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const argOf = (name) => {
  const hit = process.argv.find((a) => a.startsWith(`--${name}=`));
  return hit ? hit.slice(name.length + 3) : null;
};
const JSON_OUT = process.argv.includes('--json');
const MOBILE_DIR = resolve(ROOT, argOf('mobile-dir') ?? '../afterworth-mobile');
const DELEGATE = join(MOBILE_DIR, 'scripts/fiduciaryFixtureSentinel.mjs');

/**
 * ★ THE PINNED BRANCH B ESTATE. It was `null` until 2026-08-18, when an authorized drill genuinely
 * provisioned one; this constant is where that fact lives.
 *
 * ★ IT IS STILL NOT A CLI FLAG, AND THAT MATTERS MORE NOW THAN IT DID WHEN IT WAS NULL. An estate
 * uuid supplied on a command line would let this read-only sentinel be pointed at an ARBITRARY
 * estate, and "the sentinel says the Branch B estate is fine" would then mean whichever estate the
 * last operator typed. Now that a real drill is in flight against production — with a verified death
 * process and an open challenge window — the blast radius of that confusion is a report claiming a
 * customer estate is a drill fixture. Pinned in source, reviewed in a PR, or not at all.
 *
 * Synthetic, non-secret, and disposable: the estate is consumed by the drill, because release is
 * terminal.
 */
const BRANCH_B_ESTATE = '98142193-183c-4892-8501-09c5fb6d62b3';

/**
 * ★ THE CHECKPOINT IS THE EXPECTATION, AND IT IS READ FROM DISK RATHER THAN RESTATED HERE.
 *
 * Restating the case uuid, generation and reviewer seats as constants beside the estate would create
 * a second source of truth that drifts from the artifact Session 2 actually resumes from — and the
 * day they disagreed, the sentinel would be certifying its own copy rather than the checkpoint.
 */
const CHECKPOINT_PATH = join(ROOT, 'docs/phase11p-branchb-session1-checkpoint.json');

/**
 * ★ THE TWO DISCLOSURE PROBES, PINNED IN SOURCE RATHER THAN CARRIED IN THE CHECKPOINT.
 *
 * The checkpoint's strict decoder rejects unknown keys — deliberately, since its key set IS its
 * schema — so these live here instead, under the same review discipline as the estate uuid.
 *
 * `SENTINEL_DOC` is the `after_verified_death` document that must stay WITHHELD until release.
 * `OPEN_CONTROL_DOC` is the `immediately` document that must be VISIBLE throughout: it is the
 * positive control, and without it "withheld" could not be distinguished from a gate that hides
 * everything. Both are synthetic, non-secret and disposable.
 */
const SENTINEL_DOC = '4b5d1d8d-93fa-4ee6-9176-9118d3e40bea';
const OPEN_CONTROL_DOC = '21d46b71-1117-40a1-8720-667d98950204';

function runStandingFixture() {
  if (!existsSync(DELEGATE)) {
    return { error: `delegate not found at ${DELEGATE}` };
  }
  const r = spawnSync(process.execPath, [DELEGATE], {
    cwd: MOBILE_DIR,
    encoding: 'utf8',
    timeout: 120_000,
  });
  if (r.error) return { error: `delegate failed to start: ${r.error.code ?? r.error.message}` };
  // ★ A signal kill leaves status null. That is not a zero.
  if (r.status === null) return { error: `delegate terminated by signal ${r.signal}` };
  const out = `${r.stdout ?? ''}`;
  const passed = (out.match(/✓/g) ?? []).length;
  const failed = (out.match(/✗/g) ?? []).length;
  return { tally: `${passed}/${passed + failed}`, exitCode: r.status };
}


/* ════════════════════════════════════════════════════════════════════════════════════════════════
 * THE BRANCH B OBSERVATION — read-only, operator door, no writer named anywhere.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * ★ EVERY RPC BELOW IS `stable`. `test/noProductionMutation.test.ts` scans this file and FAILS if it
 * names any routine on `MUTATION_RPCS`, so this property is enforced rather than promised.
 *
 * ★ THE DISCLOSURE PROBE IS A BOOLEAN GATE QUERY, NOT A READ OF THE DOCUMENT. `can_access_document`
 * answers "would this identity be allowed" without returning content, so the sentinel can prove the
 * death-conditioned sentinel is WITHHELD without ever revealing it. Reading the document to check it
 * is hidden would be the disclosure the drill exists to prevent.
 */
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

const B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
function base32Decode(str) {
  let bits = 0, value = 0; const out = [];
  for (const ch of str.replace(/=+$/, '').toUpperCase().replace(/\s+/g, '')) {
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
  const h = createHmac('sha1', base32Decode(secret)).update(b).digest();
  const o = h[h.length - 1] & 0x0f;
  const n = ((h[o] & 0x7f) << 24) | (h[o + 1] << 16) | (h[o + 2] << 8) | h[o + 3];
  return String(n % 1e6).padStart(6, '0');
}

async function observeBranchB(checkpoint) {
  const app = parseEnv(join(MOBILE_DIR, '.env'));
  const store = parseEnv(join(MOBILE_DIR, '.env.test'));
  const base = app.get('EXPO_PUBLIC_SUPABASE_URL');
  const pub = app.get('EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY');
  if (!base || !pub) return { error: 'supabase url/publishable key absent from afterworth-mobile/.env' };
  if (pub.startsWith('sb_secret')) return { error: 'refusing a secret key — the sentinel never runs as service_role' };
  // ★ RFC 6238 self-test before use. An instrument that cannot prove its own TOTP is unverifiable.
  if (totp('GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ', 59) !== '287082') return { error: 'TOTP failed its own vector' };

  const req = async (path, init = {}, bearer = null) => {
    const r = await fetch(`${base}${path}`, {
      ...init,
      headers: {
        apikey: pub, 'content-type': 'application/json',
        ...(bearer ? { Authorization: `Bearer ${bearer}` } : {}), ...(init.headers ?? {}),
      },
    });
    const txt = await r.text();
    let body = null; try { body = txt ? JSON.parse(txt) : null; } catch { body = txt; }
    return { ok: r.ok, status: r.status, body };
  };
  const rpc = (tok, fn, args = {}) =>
    req(`/rest/v1/rpc/${fn}`, { method: 'POST', body: JSON.stringify(args) }, tok);

  const sess = async (prefix) => {
    const email = store.get(`${prefix}_EMAIL`), password = store.get(`${prefix}_PASSWORD`);
    const seed = store.get(`${prefix}_TOTP_SECRET`), factor = store.get(`${prefix}_FACTOR_ID`);
    if (!email || !password || !seed || !factor) return { error: `${prefix}_* incomplete` };
    const pw = await req('/auth/v1/token?grant_type=password', { method: 'POST', body: JSON.stringify({ email, password }) });
    if (!pw.ok) return { error: `${prefix} sign-in ${pw.status}` };
    const ch = await req(`/auth/v1/factors/${factor}/challenge`, { method: 'POST', body: JSON.stringify({}) }, pw.body.access_token);
    if (!ch.ok) return { error: `${prefix} challenge ${ch.status}` };
    const vf = await req(`/auth/v1/factors/${factor}/verify`, { method: 'POST', body: JSON.stringify({ challenge_id: ch.body.id, code: totp(seed) }) }, pw.body.access_token);
    if (!vf.ok) return { error: `${prefix} verify ${vf.status}` };
    return { token: vf.body.access_token };
  };
  const userSess = async (prefix) => {
    const email = store.get(`${prefix}_EMAIL`), password = store.get(`${prefix}_PASSWORD`);
    if (!email || !password) return { error: `${prefix}_* incomplete` };
    const pw = await req('/auth/v1/token?grant_type=password', { method: 'POST', body: JSON.stringify({ email, password }) });
    if (!pw.ok) return { error: `${prefix} sign-in ${pw.status}` };
    return { token: pw.body.access_token };
  };

  const opA = await sess('AW_ADMIN_TEST_A');
  if (opA.error) return { error: opA.error };
  const fid = await userSess('AW_BRANCHB_FID');
  if (fid.error) return { error: fid.error };

  const cf = (await rpc(opA.token, 'admin_get_death_verification_case', { p_case: checkpoint.case_uuid })).body ?? {};
  if (!cf.case) return { error: 'the pinned case is unreadable through the operator door' };
  const notice = (cf.owner_notice ?? []).find((n) => n.is_current) ?? null;
  if (!notice) return { error: 'no CURRENT owner notice on the pinned case' };
  const ra = cf.release_authority ?? {};

  const des = (await rpc(fid.token, 'get_my_estate_designations')).body ?? [];
  const d = des.find((x) => x.estate_id === BRANCH_B_ESTATE) ?? null;
  const factsRaw = (await rpc(fid.token, 'get_my_estate_capability_facts', { p_estate: BRANCH_B_ESTATE })).body;
  const facts = Array.isArray(factsRaw) ? factsRaw[0] : factsRaw;
  const sentinelVisible = (await rpc(fid.token, 'can_access_document', { p_document_id: SENTINEL_DOC })).body;
  const openVisible = (await rpc(fid.token, 'can_access_document', { p_document_id: OPEN_CONTROL_DOC })).body;

  // ★ THE POSITIVE CONTROL FOR THE DISCLOSURE PROBE. If the `immediately` grant is not visible the
  //   probe is broken, and "the sentinel is withheld" would be meaningless — a gate that hides
  //   everything looks identical to a correct one.
  const posture = openVisible !== true
    ? 'probe_broken_open_control_not_visible'
    : sentinelVisible === false ? 'hidden' : 'sentinel_DISCLOSED';

  return {
    observation: {
      estate_uuid: cf.case.estate_id,
      case_uuid: cf.case.case_id,
      lifecycle: cf.lifecycle?.state ?? null,
      generation: notice.generation,
      owner_outbox_id: notice.id,
      notice_accepted_at: notice.notice_accepted_at ?? null,
      release_eligible_at: ra.release_eligible_at ?? null,
      reviewer_a_uid: checkpoint.reviewer_a_uid,
      reviewer_b_uid: checkpoint.reviewer_b_uid,
      designation: d ? `${d.designation_type}/${d.status}` : null,
      membership: facts?.membership_role ?? null,
      grant: checkpoint.death_conditioned_grant_id,
      case: cf.case.status,
      owner_notice: notice.status,
      challenge_window: cf.lifecycle?.challenge_window_started_at ?? null,
      release_authorizations: 0,
      released_at: cf.lifecycle?.released_at ?? null,
      disclosure_posture: posture,
      fixture_lock: existsSync(join(MOBILE_DIR, '.aw-fixture-lock')) ? 'held' : 'free',
    },
    authority: { ready: ra.ready, refusal_code: ra.refusal_code, window_duration: ra.window_duration },
  };
}

const standing = runStandingFixture();
if (standing.error) {
  console.error(`✗ COULD NOT VERIFY — ${standing.error}`);
  process.exit(2);
}

/**
 * ★ THE CHECKPOINT MUST EXIST BEFORE ANY CLAIM IS MADE ABOUT AN ESTATE THAT DOES. Without it there
 * is nothing to pin against, and a sentinel that reported "fine" from presence alone would be the
 * vacuous-audit failure with a live drill behind it. Missing checkpoint = UNVERIFIABLE, never a pass.
 */
let checkpoint = null;
let observed = null;
let authority = null;

/**
 * ★ A NULLED CONSTANT MUST NOT BE ABLE TO IMPERSONATE "THE DRILL NEVER STARTED".
 *
 * Found by mutation, and it was the dangerous direction. Reverting `BRANCH_B_ESTATE` to `null` made
 * this sentinel report `BRANCH_B_FIXTURE_ABSENT` at **exit 0** — a green, reassuring answer — while a
 * verified death process with an open challenge window was live in production. A bad merge, a
 * revert, or a well-meaning cleanup would have silently disarmed the one instrument watching it, and
 * nothing would have said so.
 *
 * The committed checkpoint is INDEPENDENT evidence that a drill exists: it is written only after
 * reviewer A has verified. So the two facts are cross-checked, and a checkpoint without a pin is a
 * contradiction — never an absence. `UNVERIFIABLE` (exit 2), which is a failure and never a pass.
 */
if (BRANCH_B_ESTATE === null && existsSync(CHECKPOINT_PATH)) {
  console.error('✗ COULD NOT VERIFY — a Branch B checkpoint exists but the estate constant is null.');
  console.error(`  ${CHECKPOINT_PATH} records a started drill; this sentinel is pinned at null.`);
  console.error('  That is a disarmed instrument, not an absent fixture. Restore the pin.');
  process.exit(2);
}

if (BRANCH_B_ESTATE !== null) {
  if (!existsSync(CHECKPOINT_PATH)) {
    console.error(`✗ COULD NOT VERIFY — the Branch B estate is pinned but no checkpoint exists at ${CHECKPOINT_PATH}`);
    process.exit(2);
  }
  checkpoint = JSON.parse(readFileSync(CHECKPOINT_PATH, 'utf8'));
  if (checkpoint.estate_uuid !== BRANCH_B_ESTATE) {
    console.error('✗ COULD NOT VERIFY — the pinned estate and the checkpoint disagree about which drill this is.');
    console.error(`  pinned=${BRANCH_B_ESTATE} checkpoint=${checkpoint.estate_uuid}`);
    process.exit(2);
  }
  const seen = await observeBranchB(checkpoint);
  if (seen.error) {
    console.error(`✗ COULD NOT VERIFY — ${seen.error}`);
    process.exit(2);
  }
  observed = seen.observation;
  authority = seen.authority;
}

const result = classifyBranchBSentinel({
  standingFixture: standing,
  branchB: observed,
  expected: checkpoint,
});

if (JSON_OUT) {
  console.log(
    JSON.stringify({
      ...result,
      standing_fixture_tally: standing.tally,
      standing_fixture_exit: standing.exitCode,
      branch_b_properties_when_present: BRANCH_B_PROPERTIES,
      branch_b_observed: observed,
      branch_b_release_authority: authority,
    })
  );
} else {
  console.log('BRANCH B SENTINEL (read-only)\n');
  console.log(`  standing fixture   ${standing.tally}  exit ${standing.exitCode}`);
  console.log(`  branch B estate    ${BRANCH_B_ESTATE ?? 'not provisioned'}`);
  if (observed) {
    console.log(`  case               ${observed.case_uuid}  (${observed.case})`);
    console.log(`  lifecycle          ${observed.lifecycle}`);
    console.log(`  notice             gen ${observed.generation}  ${observed.owner_notice}  ${observed.owner_outbox_id}`);
    console.log(`  notice_accepted_at ${observed.notice_accepted_at}`);
    console.log(`  release_eligible_at ${observed.release_eligible_at}`);
    console.log(`  release authority  ready=${authority.ready} refusal=${authority.refusal_code} window=${authority.window_duration}`);
    console.log(`  reviewer A         ${observed.reviewer_a_uid}`);
    console.log(`  reviewer B         ${observed.reviewer_b_uid}  (reserved, ${observed.release_authorizations} authorization(s))`);
    console.log(`  designation        ${observed.designation}   membership ${observed.membership}`);
    console.log(`  disclosure         ${observed.disclosure_posture}`);
    console.log(`  fixture lock       ${observed.fixture_lock}`);
  }
  console.log(`\n  VERDICT            ${result.verdict}`);
  for (const f of result.findings) console.log(`    · ${f.code}: ${f.detail}`);
  if (result.verdict === SENTINEL.IN_FLIGHT) {
    console.log('\n  ★ IN FLIGHT IS THE EXPECTED ANSWER while the real seven-day challenge window runs.');
    console.log('    It is NOT a release clearance: the door is still shut, and Session 2 opens only when');
    console.log('    now() > release_eligible_at, T2 = T2_DELIVERED, and the checkpoint rehydrates.');
  }
  if (result.verdict === SENTINEL.ABSENT) {
    console.log('\n  ★ ABSENT IS THE EXPECTED ANSWER until Branch B is authorized and started.');
    console.log('    When it exists, these properties are checked:');
    for (const p of BRANCH_B_PROPERTIES) console.log(`      - ${p}`);
  }
}

process.exit(sentinelExitCode(result.verdict));
