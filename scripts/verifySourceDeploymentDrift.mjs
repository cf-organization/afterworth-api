#!/usr/bin/env node
/**
 * Reconcile the SOURCE in this repository against the DEPLOYED database, function by function.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ WHY THIS EXISTS. PHASE 10 FOUND DRIFT IN BOTH DIRECTIONS, AND ONLY NOTICED BY ACCIDENT.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * SOURCE AHEAD OF DEPLOYMENT: migration 0049 was believed applied for a week. Every local signal
 * agreed — the file existed, the bundle built, CI was green, the branch was merged. None of those is
 * a statement about a database. `verifyDeployedContracts.mjs` closes that direction.
 *
 * DEPLOYMENT AHEAD OF SOURCE — the direction NOTHING checked: `db/functions/create_asset_grant.sql`
 * did not admit `estate_inventory`. Only the deployed body did, because
 * `estate_discovery_rpcs.sql` adds it by string surgery on `pg_get_functiondef`. Re-applying the
 * source file would have SILENTLY REVERTED Phase 9/10-A grantability, and the deployed-contract
 * verifier would have stayed green throughout — it probes `asset_category_grantable`, which is a
 * different function.
 *
 * That near-miss is the whole reason for this script. A human remembering "careful, 0049 patches
 * that one" is not a control.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ HOW IT COMPARES: IT RUNS THE SOURCE, RATHER THAN DESCRIBING IT.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * The obvious approach — parse the SQL and re-implement each policy in JavaScript — creates a second
 * copy of an authorization rule, which is precisely the failure this repository has already shipped
 * twice (a hand-copied `create_asset_grant` in the test preamble; four role maps that drifted apart).
 * A mirror that drifts silently agrees with itself.
 *
 * So the source is EXECUTED: an ephemeral Postgres is started, the real bundles are applied to it,
 * and the same input matrix is put through both sides. Any disagreement is real disagreement between
 * bytes in this repository and bytes in production — not between production and someone's model of it.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ WHAT IT CAN AND CANNOT REACH, STATED RATHER THAN IMPLIED.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * Reconcilable here: PURE functions — no rows read, no side effects, so the full input space can be
 * enumerated on both sides and compared exactly. These are also the POLICY KNOBS (the disclosure
 * ceiling, the release predicate, the notification catalog), which is where drift actually hurts.
 *
 * NOT reconcilable here: functions that read rows or write. Their answers depend on data that differs
 * between an empty container and production, so equal inputs legitimately produce different outputs
 * and a comparison would be noise. `verifyDeployedContracts.mjs` covers their EXISTENCE and shape,
 * and one behavioural probe of `create_asset_grant`'s category vocabulary lives there because it
 * needs an authenticated owner. Those are reported UNVERIFIABLE-BY-THIS-INSTRUMENT below, by name,
 * rather than omitted — an absent row in a reconciliation table reads as "fine".
 *
 * ★ NO CREDENTIALS, NO WRITES, NO SERVICE ROLE. Every deployed call is a pure function invoked with
 * the publishable key as `anon`. Nothing here can modify production.
 *
 * Usage:  node scripts/verifySourceDeploymentDrift.mjs [--keep]
 * Exit:   0 exact agreement on every reconcilable contract
 *         1 drift detected (direction reported per function)
 *         2 could not verify — never a pass
 */
import { execFileSync, spawnSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createClient } from '@supabase/supabase-js';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const KEEP = process.argv.includes('--keep');
const CONTAINER = 'aw-drift';
const die = (code, msg, extra = []) => {
  console.error(`\n✗ ${msg}`);
  for (const e of extra) console.error(`    ${e}`);
  process.exit(code);
};

/* ── the deployed side ────────────────────────────────────────────────────────────────────────── */
function parseEnvFile(p) {
  const out = new Map();
  if (!existsSync(p)) return out;
  for (const line of readFileSync(p, 'utf8').split('\n')) {
    const m = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/.exec(line.trim());
    if (m) out.set(m[1], m[2].replace(/^["']|["']$/g, ''));
  }
  return out;
}
const env = new Map([...parseEnvFile(join(ROOT, '.env')), ...parseEnvFile(join(ROOT, '.env.local'))]);
const URL_ = env.get('SUPABASE_URL');
const KEY = env.get('SUPABASE_PUBLISHABLE_KEY');
if (!URL_ || !KEY) die(2, 'CANNOT VERIFY — SUPABASE_URL / SUPABASE_PUBLISHABLE_KEY missing from .env(.local)');
if (KEY.startsWith('sb_secret')) {
  die(2, 'REFUSING TO RUN with a secret key — this reconciliation must use the key the product uses.');
}
const deployed = createClient(URL_, KEY, { auth: { persistSession: false } });

/* ── the source side: an ephemeral Postgres with the real bundles applied ──────────────────────── */
const BUNDLES = [
  // ★ FIRST (Phase 11-B). `notification_grant_is_live` is `language sql`, so the lifecycle bundle
  // will not even LOAD against a database that lacks `release_condition_satisfied`.
  'db/bundles/release_conditions_bundle.sql',
  'db/bundles/estate_inventory_and_discovery_bundle.sql',
  'db/bundles/lifecycle_notifications_bundle.sql',
  // ★ LAST (Phase 11-C) — the operator order. Applying it here also proves the artifact loads
  // cleanly onto a database the other three have shaped, which is the paste an operator will do.
  'db/bundles/death_verification_bundle.sql',
];

/**
 * ★ THE BUNDLES ARE REBUILT BEFORE THEY ARE TRUSTED. A stale artifact on disk would make this script
 * reconcile production against a bundle nobody would deploy — comparing the present to a fossil and
 * reporting whatever that happens to say.
 */
for (const builder of ['scripts/buildReleaseConditionBundle.mjs', 'scripts/buildEstateAssetBundle.mjs', 'scripts/buildLifecycleNotificationBundle.mjs', 'scripts/buildDeathVerificationBundle.mjs']) {
  const r = spawnSync('node', [builder], { cwd: ROOT, encoding: 'utf8' });
  if (r.status !== 0) die(2, `CANNOT VERIFY — ${builder} failed:\n${r.stderr || r.stdout}`);
}
for (const b of BUNDLES) if (!existsSync(join(ROOT, b))) die(2, `CANNOT VERIFY — missing bundle ${b}`);

if (spawnSync('docker', ['info'], { stdio: 'ignore' }).status !== 0) {
  die(2, 'CANNOT VERIFY — Docker is not running.',
    ['The source side must be EXECUTED, not described. Without it this script would have to',
     're-implement each policy in JavaScript, which is the second-copy mistake it exists to avoid.']);
}
spawnSync('docker', ['rm', '-f', CONTAINER], { stdio: 'ignore' });
if (spawnSync('docker', ['run', '-d', '--name', CONTAINER, '-e', 'POSTGRES_PASSWORD=pw', 'postgres:16'],
  { encoding: 'utf8' }).status !== 0) die(2, 'CANNOT VERIFY — failed to start postgres');
const cleanup = () => { if (!KEEP) spawnSync('docker', ['rm', '-f', CONTAINER], { stdio: 'ignore' }); };
process.on('exit', cleanup);

let ready = false;
for (let i = 0; i < 60; i += 1) {
  if (spawnSync('docker', ['exec', CONTAINER, 'pg_isready', '-U', 'postgres'], { stdio: 'ignore' }).status === 0) {
    ready = true; break;
  }
  execFileSync('sleep', ['1']);
}
if (!ready) die(2, 'CANNOT VERIFY — postgres never became ready.');

const psql = (sql, extra = []) => spawnSync(
  'docker', ['exec', '-i', CONTAINER, 'psql', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', ...extra, '-f', '-'],
  { input: sql, encoding: 'utf8' }
);

/**
 * ★ THE DEPENDENCY SCHEMA COMES FROM THE MAINTAINED HARNESS, NOT FROM A COPY IN THIS FILE.
 *
 * The bundles need real tables at DDL time — a foreign key to `document_sensitivity`, policies over
 * `documents`, triggers on the taxonomy tables. A hand-written prelude here would be a second copy
 * of that schema, and the first thing it would do is drift: `db/tests/preamble_real_auth.sql` gained
 * `access_grants.approved_by_user_id`, the notifications table and the invitations tables during
 * Phase 10-E alone. `verifySqlAuthorization.mjs` already refuses to run when that file shadows a
 * production body, so it is the audited, single-sourced way to stand up these dependencies.
 *
 * Its stand-ins are irrelevant to this comparison regardless: only PURE functions are reconciled
 * below, and a pure function reads no table.
 */
const PREAMBLE = 'db/tests/preamble_real_auth.sql';
if (!existsSync(join(ROOT, PREAMBLE))) die(2, `CANNOT VERIFY — missing ${PREAMBLE}`);
{
  const r = psql(readFileSync(join(ROOT, PREAMBLE), 'utf8'));
  if (r.status !== 0) die(2, `CANNOT VERIFY — preamble failed:\n${(r.stderr || '').slice(-1200)}`);
}
for (const b of BUNDLES) {
  const r = psql(readFileSync(join(ROOT, b), 'utf8'));
  if (r.status !== 0) die(2, `CANNOT VERIFY — could not apply ${b} to the source container:\n${(r.stderr || '').slice(-1200)}`);
}

/**
 * Run a query on the SOURCE container and return parsed JSON.
 *
 * ★ `-A -t` AS FLAGS, NOT `\pset` IN THE SCRIPT. The meta-command form writes
 * "Output format is unaligned." to STDOUT, which lands in front of the payload and makes every parse
 * fail — the same shape of mistake as the aligned-output `+` continuation markers noted in
 * `verifySqlAuthorization.mjs`. Passing them as arguments configures psql without narrating it.
 */
function sourceJson(sql) {
  const r = psql(sql, ['-A', '-t']);
  if (r.status !== 0) die(2, `CANNOT VERIFY — source query failed:\n${r.stderr}`);
  try {
    return JSON.parse((r.stdout ?? '').trim());
  } catch {
    die(2, `CANNOT VERIFY — source query did not return JSON:\n${(r.stdout ?? '').slice(0, 400)}`);
  }
}

/* ── the reconciliation matrix ─────────────────────────────────────────────────────────────────── */

const RELEASE_CONDITIONS = [
  'never', 'immediately', 'after_owner_approval', 'after_identity_verification',
  'after_access_request_approval', 'after_verified_death_or_incapacity', 'after_claim_case_approval',
  // ★ PHASE 11-B — the split, plus a value that cannot exist. Both sides must refuse all three:
  // DEPLOYED because it has never heard of them, SOURCE because they are dormant by design. That
  // agreement is the point rather than a coincidence — it is what proves the split widened the
  // storable vocabulary WITHOUT widening the satisfiable one.
  'after_verified_death', 'after_verified_incapacity', 'aw_probe_condition_that_cannot_exist',
];
const ROLES = ['beneficiary', 'professional_delegate', 'primary_user', 'aw_probe_unknown_role'];
const CATEGORIES = [
  'account_balances', 'institution_names', 'total_asset_value', 'linked_account_details',
  'estate_inventory', 'estate_documents', 'aw_probe_unknown_category',
];
const TIERS = ['hidden', 'range_only', 'category_summary', 'limited_detail', 'full_detail'];
const EVENTS = [
  'access_request.created', 'access_request.approved', 'access_request.denied',
  'access_grant.created', 'access_grant.revoked',
  'invitation.accepted', 'invitation.declined',
  'aw_probe_event_that_cannot_exist',
];

const results = [];
const record = (name, verdict, detail, cases) => {
  results.push({ name, verdict, detail, cases });
  const mark = verdict === 'EXACT' ? '✓' : verdict === 'UNVERIFIABLE' ? '·' : '✗';
  console.log(`  ${mark} ${name.padEnd(30)} ${verdict.padEnd(18)} ${detail}`);
};

console.log(`source ↔ deployment reconciliation · ${URL_.replace(/^https?:\/\//, '').split('.')[0]}\n`);
console.log('RECONCILABLE (pure functions — full input space compared on both sides)');

/**
 * ★ THE DIRECTION OF DRIFT IS REPORTED, NOT JUST ITS EXISTENCE. "They differ" sends someone reading
 * both files; "deployment accepts a value source refuses" tells them re-applying the bundle would
 * REGRESS production, which is the dangerous case and the one Phase 10 nearly shipped.
 */
function classify(diffs) {
  const srcOnly = diffs.filter((d) => d.source && !d.deployed).length;
  const depOnly = diffs.filter((d) => !d.source && d.deployed).length;
  if (srcOnly && depOnly) return 'DIVERGENT';
  if (depOnly) return 'DEPLOYMENT_NEWER';
  if (srcOnly) return 'SOURCE_NEWER';
  return 'DIFFERENT';
}

/* 1 · asset_category_grantable — THE disclosure ceiling. */
{
  const combos = [];
  for (const r of ROLES) for (const c of CATEGORIES) for (const t of TIERS) combos.push({ r, c, t });
  const src = sourceJson(`select json_agg(x) from (select r,c,t,
      public.asset_category_grantable(r,c,t) as v
    from unnest(array[${ROLES.map((v) => `'${v}'`)}]) r
    cross join unnest(array[${CATEGORIES.map((v) => `'${v}'`)}]) c
    cross join unnest(array[${TIERS.map((v) => `'${v}'`)}]) t) x;`);
  const srcMap = new Map(src.map((row) => [`${row.r}|${row.c}|${row.t}`, row.v]));

  const diffs = [];
  for (const { r, c, t } of combos) {
    const { data, error } = await deployed.rpc('asset_category_grantable', { p_role: r, p_category: c, p_tier: t });
    if (error) die(2, `CANNOT VERIFY — deployed asset_category_grantable failed: ${error.code} ${error.message}`);
    const s = srcMap.get(`${r}|${c}|${t}`);
    if (s !== data) diffs.push({ key: `${r}/${c}/${t}`, source: s, deployed: data });
  }
  // ★ POSITIVE CONTROL. An all-false matrix on both sides would "agree" perfectly and prove nothing.
  const trues = [...srcMap.values()].filter(Boolean).length;
  if (trues === 0) die(2, 'CANNOT VERIFY — the source ceiling returned false for every input; the comparison would be vacuous.');
  record('asset_category_grantable', diffs.length ? classify(diffs) : 'EXACT',
    `${combos.length} combinations, ${trues} grantable in source${diffs.length ? ` · ${diffs.length} mismatch(es)` : ''}`,
    diffs);
}

/* 2 · notification_grant_is_live — the death/claim firewall predicate. */
{
  const cases = [];
  for (const c of RELEASE_CONDITIONS) for (const st of ['active', 'revoked']) for (const ap of [null, 'now()']) cases.push({ c, st, ap });
  // ★ `ap as approved`, NOT `(ap is not null)`. `ap` is already the boolean being varied, so the
  // first version labelled EVERY row `approved=true`, collapsing two distinct cases onto one key.
  // The comparison then reported DEPLOYMENT_NEWER against `undefined` — a fabricated drift finding
  // produced entirely by the instrument. Worth keeping the note: a reconciler that cries drift is
  // as dangerous as one that misses it, because the next person starts editing production policy.
  const src = sourceJson(`select json_agg(x) from (select c, st, ap as approved,
      public.notification_grant_is_live(st, c, case when ap then now() else null end) as v
    from unnest(array[${RELEASE_CONDITIONS.map((v) => `'${v}'`)}]) c
    cross join unnest(array['active','revoked']) st
    cross join unnest(array[true,false]) ap) x;`);
  const srcMap = new Map(src.map((row) => [`${row.st}|${row.c}|${row.approved}`, row.v]));

  const diffs = [];
  for (const { c, st, ap } of cases) {
    const approved = ap !== null;
    const { data, error } = await deployed.rpc('notification_grant_is_live', {
      p_status: st, p_release_condition: c, p_approved_at: approved ? new Date(0).toISOString() : null,
    });
    if (error) die(2, `CANNOT VERIFY — deployed notification_grant_is_live failed: ${error.code} ${error.message}`);
    const s = srcMap.get(`${st}|${c}|${approved}`);
    if (s !== data) diffs.push({ key: `${st}/${c}/approved=${approved}`, source: s, deployed: data });
  }
  const trues = [...srcMap.values()].filter(Boolean).length;
  if (trues === 0) die(2, 'CANNOT VERIFY — the source release predicate was false for every input.');
  // ★ AND THE FIREWALL IS SPOT-CHECKED ON THE DEPLOYED SIDE DIRECTLY, so this row cannot report
  // "exact agreement" about two functions that both wrongly release a death-conditioned grant.
  for (const cond of ['after_verified_death_or_incapacity', 'after_claim_case_approval', 'never',
                      'after_verified_death', 'after_verified_incapacity']) {
    const { data } = await deployed.rpc('notification_grant_is_live', {
      p_status: 'active', p_release_condition: cond, p_approved_at: new Date(0).toISOString(),
    });
    if (data !== false) die(1, `DEPLOYED FIREWALL BREACH — notification_grant_is_live('active','${cond}', <approved>) returned ${data}`);
  }
  /**
   * ★ THIS ROW IS THE PROOF THAT PHASE 11-B PRESERVED BEHAVIOUR.
   *
   * The SOURCE side of this comparison no longer contains the release rule at all — it delegates to
   * `public.release_condition_satisfied`. The DEPLOYED side still spells the rule out inline. An
   * EXACT verdict here therefore is not a formality: it is the refactor being checked against the
   * bytes it replaced, across the whole input space, by executing both rather than by reading them.
   *
   * A `DIVERGENT` or `SOURCE_NEWER` verdict on this row means the centralization changed an answer,
   * which is the one thing this phase was not allowed to do.
   */
  record('notification_grant_is_live', diffs.length ? classify(diffs) : 'EXACT',
    `${cases.length} cases, ${trues} live in source · 5 dormant conditions confirmed on DEPLOYED`, diffs);
}

/* 3 · notification_event_copy — the lifecycle catalog, compared字 for字. */
{
  const src = sourceJson(`select coalesce(json_agg(x), '[]'::json) from (select e as event, c.category, c.title, c.body
    from unnest(array[${EVENTS.map((v) => `'${v}'`)}]) e
    left join lateral public.notification_event_copy(e) c on true) x;`);
  const srcMap = new Map(src.map((row) => [row.event, row.category === null ? null : { category: row.category, title: row.title, body: row.body }]));

  const diffs = [];
  for (const e of EVENTS) {
    const { data, error } = await deployed.rpc('notification_event_copy', { p_event: e });
    if (error) die(2, `CANNOT VERIFY — deployed notification_event_copy failed: ${error.code} ${error.message}`);
    const row = Array.isArray(data) ? data[0] ?? null : data ?? null;
    const dep = row ? { category: row.category, title: row.title, body: row.body } : null;
    const s = srcMap.get(e) ?? null;
    if (JSON.stringify(s) !== JSON.stringify(dep)) diffs.push({ key: e, source: s, deployed: dep });
  }
  const known = [...srcMap.values()].filter(Boolean).length;
  if (known === 0) die(2, 'CANNOT VERIFY — the source catalog produced no entries.');
  // ★ NEGATIVE CONTROL: the impossible event must be unknown on BOTH sides. A catalog that answers
  // everything would compare "equal" while having lost its closed-vocabulary property entirely.
  if (srcMap.get('aw_probe_event_that_cannot_exist') !== null) {
    die(2, 'CANNOT VERIFY — the source catalog answered an impossible event; it is not closed.');
  }
  record('notification_event_copy', diffs.length ? classify(diffs) : 'EXACT',
    `${known} catalog entries compared verbatim · unknown event refused on both sides`, diffs);
}

/* 4 · release_condition_satisfied / release_condition_writable — SOURCE-ONLY UNTIL DEPLOYED. */
{
  /**
   * ★ REPORTED BY NAME RATHER THAN OMITTED, because an absent row in a reconciliation table reads
   * as "fine". These two functions do not exist in production yet: Phase 11-B is a source-and-bundle
   * change, and the release-conditions bundle has not been pasted. Probing them would return
   * PGRST202 (function not found), which is the CORRECT answer for an undeployed function and must
   * not be dressed up as either drift or agreement.
   *
   * What IS reconciled is their observable effect: `notification_grant_is_live` above delegates to
   * them in source and inlines the same rule in deployment, and that row compares EXACT across the
   * full input space. So the new authority is proven equivalent to what production runs, through the
   * contract production actually exposes — which is the strongest statement available before deploy.
   *
   * After the bundle is applied, `deployment_state` flips to DEPLOYED and this becomes a real
   * reconciliation row rather than a declaration. The probe below is what decides that, so the label
   * can never be stale.
   */
  const names = ['release_condition_satisfied', 'release_condition_writable'];
  const probes = await Promise.all(names.map(async (n) => {
    const args = n === 'release_condition_satisfied'
      ? { p_release_condition: 'immediately', p_approved_at: null, p_policy: 'standard' }
      : { p_release_condition: 'immediately' };
    const { data, error } = await deployed.rpc(n, args);
    return { n, data, error };
  }));
  const live = probes.filter((p) => !p.error);
  const absent = probes.filter((p) => p.error);

  if (live.length === names.length) {
    // Deployed. Both must answer `true` for `immediately` — the one input whose answer is not in
    // dispute — or the deployed body is not the one this repository describes.
    const wrong = live.filter((p) => p.data !== true);
    if (wrong.length) {
      die(1, `DEPLOYED release-condition authority disagrees: ${wrong.map((w) => `${w.n}=${JSON.stringify(w.data)}`).join(', ')}`);
    }
    record('release_condition_satisfied', 'EXACT',
      'DEPLOYED · immediately satisfied under standard; full truth table in the SQL suite', []);
  } else if (absent.length === names.length) {
    record('release_condition_authority', 'UNVERIFIABLE',
      'NOT YET DEPLOYED (source + bundle only) — equivalence proven via notification_grant_is_live above', []);
  } else {
    // ★ HALF-DEPLOYED IS THE DANGEROUS STATE AND IT GETS ITS OWN VERDICT. One function present and
    // the other missing means a partial paste: callers would resolve one and raise on the other.
    die(1, `PARTIAL DEPLOYMENT — present: ${live.map((p) => p.n).join(', ') || '(none)'}; `
      + `absent: ${absent.map((p) => p.n).join(', ')}. Re-apply db/bundles/release_conditions_bundle.sql in full.`);
  }
}

/* 5 · the death-verification foundation — SOURCE-ONLY UNTIL DEPLOYED (Phase 11-C). */
{
  /**
   * ★ SAME DISCIPLINE AS BLOCK 4: named, never omitted. The 11-C routines are stateful, so they can
   * never join the reconciliation table — but their DEPLOYMENT STATE is still a fact this script
   * must own, because the half-deployed state (some functions pasted, some not) is exactly the
   * failure the bundle exists to prevent. The probes run as `anon`, which holds EXECUTE on none of
   * them: a deployed function answers with a refusal (auth_required / permission denied), an
   * undeployed one with PGRST202 — so the probe cannot mutate anything on either answer.
   */
  const names = [
    'initiate_death_verification_case',
    'admin_decide_death_verification_case',
    'estate_lifecycle_state',
  ];
  const probes = await Promise.all(names.map(async (n) => {
    const arg = n === 'admin_decide_death_verification_case'
      ? { p_case: '00000000-0000-4000-8000-000000000000', p_decision: 'reject' }
      : n === 'initiate_death_verification_case'
        ? { p_estate: '00000000-0000-4000-8000-000000000000' }
        : { p_estate: '00000000-0000-4000-8000-000000000000' };
    const { error } = await deployed.rpc(n, arg);
    return { n, missing: error?.code === 'PGRST202' };
  }));
  const absent = probes.filter((p) => p.missing);

  if (absent.length === names.length) {
    record('death_verification_authority', 'UNVERIFIABLE',
      'NOT YET DEPLOYED (source + bundle only) — apply db/bundles/death_verification_bundle.sql LAST', []);
  } else if (absent.length === 0) {
    record('death_verification_authority', 'UNVERIFIABLE',
      'DEPLOYED · stateful — behaviour covered by db/tests/death_verification_authorization.sql', []);
  } else {
    die(1, `PARTIAL DEPLOYMENT — absent: ${absent.map((p) => p.n).join(', ')}. `
      + 'Re-apply db/bundles/death_verification_bundle.sql in full.');
  }
}

/* ── what this instrument deliberately does not reconcile ──────────────────────────────────────── */
console.log('\nNOT RECONCILABLE BY THIS INSTRUMENT (stateful — equal inputs legitimately differ)');
for (const [name, why] of [
  ['create_asset_grant', 'writes; category vocabulary probed by verifyDeployedContracts (raise-before-insert)'],
  ['get_estate_discovery', 'reads estate rows; compared by SQL suite against its own fixture'],
  ['inventory_disclosure_tier', 'reads grants; SQL suite'],
  ['get_estate_readiness', 'reads documents/assets; SQL suite + deployed shape check'],
  ['get_professional_workspace', 'reads memberships/grants; SQL suite + deployed existence check'],
  ['estate_release_state', 'reads claim rows; deployed existence check'],
  ['emit_lifecycle_notification', 'writes; EXECUTE revoked, so it is LOCKED-checked instead'],
]) {
  record(name, 'UNVERIFIABLE', why, []);
}

/* ── verdict ───────────────────────────────────────────────────────────────────────────────────── */
const drifted = results.filter((r) => !['EXACT', 'UNVERIFIABLE'].includes(r.verdict));
const exact = results.filter((r) => r.verdict === 'EXACT').length;
console.log('\n' + '─'.repeat(78));
if (drifted.length > 0) {
  console.error(`✗ DRIFT DETECTED in ${drifted.length} contract(s):\n`);
  for (const d of drifted) {
    console.error(`  ${d.name} — ${d.verdict}`);
    for (const c of d.cases.slice(0, 12)) {
      console.error(`      ${c.key}: source=${JSON.stringify(c.source)} deployed=${JSON.stringify(c.deployed)}`);
    }
    if (d.cases.length > 12) console.error(`      … and ${d.cases.length - 12} more`);
    if (d.verdict === 'DEPLOYMENT_NEWER') {
      console.error('      ★ DEPLOYMENT IS AHEAD. Re-applying the bundle would REGRESS production.');
      console.error('        Fix the SOURCE first; do not paste until this row reads EXACT.');
    }
    if (d.verdict === 'SOURCE_NEWER') {
      console.error('      → source is ahead; the bundle has not been applied (or not fully).');
    }
  }
  process.exit(1);
}
console.log(`✓ SOURCE AND DEPLOYMENT AGREE EXACTLY on all ${exact} reconcilable contract(s).`);
console.log('  Compared by EXECUTING the source in an ephemeral Postgres and putting the same input');
console.log('  matrix through both sides — no hand-written mirror of any policy exists in this script.');
console.log(`  ${results.length - exact} stateful contract(s) are listed above as unreconcilable by name,`);
console.log('  each with the instrument that does cover it.');
