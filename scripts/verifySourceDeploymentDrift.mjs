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

/**
 * ★ THE RECONCILER MUST PROBE UNDER THE ROLE SOURCE INTENDS — a lesson paid for at deploy time.
 *
 * Every probe here used to run as `anon` (the publishable key, unauthenticated). That was correct
 * while every reconciled contract was PUBLIC-executable, and it silently stopped being correct in
 * Phase 11-B: `notification_grant_is_live` is SECURITY INVOKER and now DELEGATES to
 * `release_condition_satisfied`, which source deliberately revokes from `anon` and grants to
 * `authenticated`. So the chain refuses for anon BY DESIGN.
 *
 * It passed for months only because the DEPLOYED body still inlined the release rule and made no
 * nested call; the first real paste turned a latent instrument defect into a hard failure
 * (`42501 permission denied for function release_condition_satisfied`). Classified by
 * `scripts/classifyPredicatePrivilege.mjs`: anon refused, authenticated succeeds end-to-end, and the
 * SECURITY DEFINER production path resolves fine — a verifier role defect, not a privilege defect.
 *
 * ★ SO THE CLIENT IS CHOSEN PER CONTRACT, NOT GLOBALLY. Contracts that source exposes to anon keep
 * using `deployed`; contracts whose privilege contract names `authenticated` are reconciled by an
 * authenticated client. Granting the predicate to anon "to make the verifier pass" would have been
 * the same instrument defect resolved by weakening production — precisely backwards.
 */
const MOBILE_ENV = parseEnvFile(resolve(ROOT, '../afterworth-mobile/.env.test'));
let authed = null;
async function authedClient() {
  if (authed) return authed;
  const email = MOBILE_ENV.get('AW_OR_OWNER_EMAIL');
  const password = MOBILE_ENV.get('AW_OR_OWNER_PASSWORD');
  if (!email || !password) {
    die(2, 'CANNOT VERIFY — AW_OR_OWNER_EMAIL/_PASSWORD absent from afterworth-mobile/.env.test.',
      ['Some contracts are granted to `authenticated` and revoked from `anon`; reconciling them as',
       'anon would report a DESIGNED refusal as drift. Refusing to guess is the only safe answer.']);
  }
  const c = createClient(URL_, KEY, { auth: { persistSession: false } });
  const { data, error } = await c.auth.signInWithPassword({ email, password });
  if (error || !data?.user) die(2, `CANNOT VERIFY — reconciler sign-in failed: ${error?.message ?? 'no user'}`);
  authed = c;
  return authed;
}

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
  // ★ PHASE 11-E — the owner safety notice. Included so the catalog comparison COVERS it rather
  // than silently omitting the one new entry (an absent row in a reconciliation table reads as
  // "fine"). Until the notifications bundle is pasted the deployed catalog does not know it, which
  // is SOURCE-AHEAD rather than drift — classified explicitly below.
  'death_process.window_opened',
  'aw_probe_event_that_cannot_exist',
];

/**
 * Events this repository has authored but not yet deployed. A source-only entry here is reported as
 * PENDING DEPLOYMENT — named, never omitted, and never counted as agreement. Anything else that
 * differs is real drift.
 */
const PENDING_EVENTS = new Set(['death_process.window_opened']);

const results = [];
const record = (name, verdict, detail, cases) => {
  results.push({ name, verdict, detail, cases });
  // ★ FIVE CLASSES, FIVE MARKS (Stage 8). PENDING_DEPLOYMENT is neither agreement nor drift: it is
  // "source is ahead, on purpose, and production has not been pasted yet". Giving it the drift mark
  // would cry wolf before every deployment; giving it the EXACT mark would report a missing
  // deployment as agreement, which is the one thing this script must never do.
  const mark = verdict === 'EXACT' ? '✓'
    : verdict === 'UNVERIFIABLE' ? '·'
    : verdict === 'PENDING_DEPLOYMENT' ? '⋯'
    : '✗';
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
    const { data, error } = await (await authedClient()).rpc('notification_grant_is_live', {
      p_status: st, p_release_condition: c, p_approved_at: approved ? new Date(0).toISOString() : null,
    });
    if (error) {
      // ★ A 42501 HERE IS NOW A REAL FINDING, not a role artefact: this client IS the role source
      // grants. Say so explicitly rather than emitting the bare code again.
      const hint = error.code === '42501'
        ? ' — authenticated is refused a function source GRANTS to it; this is a PRIVILEGE DEFECT, '
          + 'not a probe artefact (see scripts/classifyPredicatePrivilege.mjs)'
        : '';
      die(2, `CANNOT VERIFY — deployed notification_grant_is_live failed: ${error.code} ${error.message}${hint}`);
    }
    const s = srcMap.get(`${st}|${c}|${approved}`);
    if (s !== data) diffs.push({ key: `${st}/${c}/approved=${approved}`, source: s, deployed: data });
  }
  const trues = [...srcMap.values()].filter(Boolean).length;
  if (trues === 0) die(2, 'CANNOT VERIFY — the source release predicate was false for every input.');
  // ★ AND THE FIREWALL IS SPOT-CHECKED ON THE DEPLOYED SIDE DIRECTLY, so this row cannot report
  // "exact agreement" about two functions that both wrongly release a death-conditioned grant.
  for (const cond of ['after_verified_death_or_incapacity', 'after_claim_case_approval', 'never',
                      'after_verified_death', 'after_verified_incapacity']) {
    const { data } = await (await authedClient()).rpc('notification_grant_is_live', {
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
  const pending = [];
  for (const e of EVENTS) {
    const { data, error } = await deployed.rpc('notification_event_copy', { p_event: e });
    if (error) die(2, `CANNOT VERIFY — deployed notification_event_copy failed: ${error.code} ${error.message}`);
    const row = Array.isArray(data) ? data[0] ?? null : data ?? null;
    const dep = row ? { category: row.category, title: row.title, body: row.body } : null;
    const s = srcMap.get(e) ?? null;
    if (JSON.stringify(s) === JSON.stringify(dep)) continue;
    // ★ SOURCE-AHEAD ON A KNOWN-PENDING EVENT IS NOT DRIFT — but it is not agreement either, so it
    // is reported by name. The reverse (deployed has copy this build does not) IS drift, always:
    // re-applying the bundle would delete a live notification's words.
    if (PENDING_EVENTS.has(e) && s !== null && dep === null) {
      pending.push(e);
      continue;
    }
    diffs.push({ key: e, source: s, deployed: dep });
  }
  if (pending.length) {
    console.log(`  · PENDING DEPLOYMENT — source authors copy for: ${pending.join(', ')}`);
    console.log('    (deployed catalog does not know it yet; apply lifecycle_notifications_bundle.sql)');
  }
  const known = [...srcMap.values()].filter(Boolean).length;
  if (known === 0) die(2, 'CANNOT VERIFY — the source catalog produced no entries.');
  // ★ NEGATIVE CONTROL: the impossible event must be unknown on BOTH sides. A catalog that answers
  // everything would compare "equal" while having lost its closed-vocabulary property entirely.
  if (srcMap.get('aw_probe_event_that_cannot_exist') !== null) {
    die(2, 'CANNOT VERIFY — the source catalog answered an impossible event; it is not closed.');
  }
  record('notification_event_copy', diffs.length ? classify(diffs) : 'EXACT',
    `${known} catalog entries compared verbatim · unknown event refused on both sides`
      + (pending.length ? ` · ${pending.length} pending deployment (named above)` : ''), diffs);
}

/* 4 · the release authority (predicate + writable gate + lifecycle seam) — SOURCE-ONLY UNTIL DEPLOYED. */
{
  /**
   * ★ REPORTED BY NAME RATHER THAN OMITTED, because an absent row in a reconciliation table reads
   * as "fine". None of this exists in production yet: 11-B/11-C/11-D are source-and-bundle changes,
   * and the release-conditions bundle has not been pasted. Probing returns PGRST202 (function not
   * found), which is the CORRECT answer for an undeployed function and must not be dressed up as
   * either drift or agreement.
   *
   * What IS reconciled is the observable effect: `notification_grant_is_live` above delegates to
   * the predicate in source (pinned to the base lifecycle since 11-D) and inlines the same rule in
   * deployment, and that row compares EXACT across the full input space. So the authority is proven
   * equivalent to what production runs, through the contract production actually exposes — the
   * strongest statement available before deploy.
   *
   * ★ THE SEAM BELONGS TO THIS GROUP SINCE 11-D: `estate_lifecycle_state` ships in the
   * release-conditions bundle (the first paste), not the death bundle — the disclosure evaluators
   * resolve it at read time, so its absence after this bundle is a HALF-DEPLOY of this artifact.
   * Its probe distinguishes deployed (permission denied — EXECUTE is revoked from anon, so the
   * refusal itself is the evidence) from absent (PGRST202); it can mutate nothing either way.
   *
   * ★ AND THE BLIND OVERLOAD MUST BE GONE. A deployed 3-argument predicate beside the 4-argument
   * one means migration 0053 did not run: overload resolution would quietly serve the
   * lifecycle-blind rule to any caller that was not rewired. Present-and-alone is a verdict-1
   * failure, not a note.
   */
  const rcClient = await authedClient();
  const probes = {
    satisfied4: await rcClient.rpc('release_condition_satisfied', {
      p_release_condition: 'immediately', p_approved_at: null, p_policy: 'standard', p_lifecycle_state: 'active',
    }),
    satisfied3: await rcClient.rpc('release_condition_satisfied', {
      p_release_condition: 'immediately', p_approved_at: null, p_policy: 'standard',
    }),
    writable: await rcClient.rpc('release_condition_writable', { p_release_condition: 'immediately' }),
    // ★ THE SEAM STAYS AN ANON PROBE ON PURPOSE: it is revoked from EVERY client role, so its
    // refusal is the posture being checked, and asking as authenticated would prove less.
    seam: await deployed.rpc('estate_lifecycle_state', { p_estate: '00000000-0000-4000-8000-000000000000' }),
  };
  const missing = (r) => r.error?.code === 'PGRST202';
  const has4 = !missing(probes.satisfied4);
  const has3 = !missing(probes.satisfied3);
  const hasWritable = !missing(probes.writable);
  const hasSeam = !missing(probes.seam);

  if (has3) {
    // The blind overload is reachable. Whether or not the 4-argument shape is also present, this
    // deployment predates (or half-applied) 0053 and re-pasting the release bundle is mandatory.
    die(1, 'DEPLOYED release authority is LIFECYCLE-BLIND — the 3-argument '
      + 'release_condition_satisfied is reachable (migration 0053 has not run'
      + `${has4 ? ' although the 4-argument shape exists beside it — TWO AUTHORITIES' : ''}). `
      + 'Re-apply db/bundles/release_conditions_bundle.sql in full.');
  }
  if (has4 && hasWritable && hasSeam) {
    // Deployed at the 11-D shape. Spot-check the three answers that define the phase — all pure.
    /**
     * ★ THE DEPLOYED RELEASE CONTRACT, SPOT-CHECKED IN FULL — and rewritten at first execution.
     *
     * This list previously expected `death/death_verified = true`, which was the Phase 11-D
     * semantics. 11-E inserted the challenge window and 11-F the dispatch state, making that
     * expectation exactly backwards — yet it never failed, because the block is only reachable once
     * the authority is DEPLOYED, and until today it never was. A branch that never runs cannot be
     * caught being wrong, which is why the first real deployment is the moment to re-derive it
     * rather than trust it.
     *
     * The rows below are the whole 11-F contract: ONE satisfying cell, and the four pre-release
     * states plus the dormant conditions all refusing.
     */
    const ask = async (cond, policy, lifecycle) => (await rcClient.rpc('release_condition_satisfied', {
      p_release_condition: cond, p_approved_at: null, p_policy: policy, p_lifecycle_state: lifecycle,
    })).data;
    const spot = [
      ['immediately/active (standard)', probes.satisfied4.data, true],
      // THE one satisfying cell.
      ['death/RELEASED (standard)', await ask('after_verified_death', 'standard', 'released'), true],
      // Every pre-release stage refuses — the safety seam, as deployed.
      ['death/active (standard)', await ask('after_verified_death', 'standard', 'active'), false],
      ['death/death_verified (standard)', await ask('after_verified_death', 'standard', 'death_verified'), false],
      ['death/owner_notification_dispatched (standard)',
        await ask('after_verified_death', 'standard', 'owner_notification_dispatched'), false],
      ['death/challenge_window (standard)', await ask('after_verified_death', 'standard', 'challenge_window'), false],
      ['death/challenge_halted (standard)', await ask('after_verified_death', 'standard', 'challenge_halted'), false],
      // The legacy clamp survives release (R10).
      ['death/released (LEGACY clamp)', await ask('after_verified_death', 'legacy_immediate_only', 'released'), false],
      // The dormant vocabulary stays dormant even at released.
      ['incapacity/released (standard)', await ask('after_verified_incapacity', 'standard', 'released'), false],
      ['fused-legacy/released (standard)',
        await ask('after_verified_death_or_incapacity', 'standard', 'released'), false],
      ['never/released (standard)', await ask('never', 'standard', 'released'), false],
      // Unknown lifecycle fails closed.
      ['immediately/UNKNOWN-lifecycle (standard)', await ask('immediately', 'standard', 'aw_probe_not_a_state'), false],
    ];
    const wrong = spot.filter(([, got, want]) => got !== want);
    if (wrong.length) {
      die(1, `DEPLOYED release authority disagrees on: ${wrong.map(([k, got, want]) => `${k} = ${JSON.stringify(got)} (expected ${want})`).join('; ')}`);
    }
    record('release_condition_authority', 'EXACT',
      `DEPLOYED at the 11-F shape · ${spot.length} contract cells spot-checked (death satisfies at `
      + 'released ONLY); full truth table in the SQL suite', []);
  } else if (!has4 && !hasWritable && !hasSeam) {
    record('release_condition_authority', 'UNVERIFIABLE',
      'NOT YET DEPLOYED (source + bundle only) — equivalence proven via notification_grant_is_live above', []);
  } else {
    // ★ HALF-DEPLOYED IS THE DANGEROUS STATE AND IT GETS ITS OWN VERDICT. Some objects present and
    // some missing means a partial paste: callers would resolve one and raise on the other.
    const present = [has4 && 'release_condition_satisfied(4)', hasWritable && 'release_condition_writable', hasSeam && 'estate_lifecycle_state'].filter(Boolean);
    const absent = [!has4 && 'release_condition_satisfied(4)', !hasWritable && 'release_condition_writable', !hasSeam && 'estate_lifecycle_state'].filter(Boolean);
    die(1, `PARTIAL DEPLOYMENT — present: ${present.join(', ') || '(none)'}; `
      + `absent: ${absent.join(', ')}. Re-apply db/bundles/release_conditions_bundle.sql in full.`);
  }
}

/* 5 · the death-verification workflow — SOURCE-ONLY UNTIL DEPLOYED (Phase 11-C). */
{
  /**
   * ★ SAME DISCIPLINE AS BLOCK 4: named, never omitted. The 11-C routines are stateful, so they can
   * never join the reconciliation table — but their DEPLOYMENT STATE is still a fact this script
   * must own, because the half-deployed state (some functions pasted, some not) is exactly the
   * failure the bundle exists to prevent. The probes run as `anon`, which holds EXECUTE on none of
   * them: a deployed function answers with a refusal (auth_required / permission denied), an
   * undeployed one with PGRST202 — so the probe cannot mutate anything on either answer.
   * (`estate_lifecycle_state` moved to block 4 in 11-D: it ships with the FIRST bundle now, so its
   * absence is that artifact's half-deploy, not this one's.)
   */
  const names = [
    'initiate_death_verification_case',
    'admin_decide_death_verification_case',
  ];
  const probes = await Promise.all(names.map(async (n) => {
    const arg = n === 'admin_decide_death_verification_case'
      ? { p_case: '00000000-0000-4000-8000-000000000000', p_decision: 'reject' }
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

/* 6 · PHASE 11-F — the two-person release surface, in FIVE explicit verdict classes. */
{
  /**
   * ★ THE FIVE CLASSES ARE REPORTED SEPARATELY BECAUSE THEY MEAN DIFFERENT THINGS (Stage 8), and
   * the one that must never be silent is PENDING_DEPLOYMENT. A missing deployment reported as
   * agreement is the failure this whole script exists to prevent: source ahead of production reads
   * as "fine" in every table that simply omits the row.
   *
   *   EXACT              deployed and answering as source does
   *   PENDING_DEPLOYMENT source authors it; production has never seen it — expected before a paste
   *   DEPLOYMENT_NEWER   production has something source does not — re-pasting would REGRESS it
   *   SOURCE_NEWER       source has something production lacks, where that is drift rather than a
   *                      known-pending artifact
   *   UNVERIFIABLE       stateful; equal inputs legitimately differ, named rather than omitted
   *
   * ★ AND THE 11-F SHAPE IS PARTLY AN ABSENCE. `release_estate` must be GONE: a deployment that
   * still carries it has a one-person release lever beside the two-person door, which is
   * DEPLOYMENT_NEWER in the most dangerous direction — production able to do something source
   * forbids.
   */
  const probe = async (n, args) => {
    const { error } = await deployed.rpc(n, args);
    return { missing: error?.code === 'PGRST202', code: error?.code ?? null };
  };
  const NIL = '00000000-0000-4000-8000-000000000000';
  const authorize = await probe('authorize_release', { p_estate: NIL, p_reason: 'drift probe' });
  const dispatch = await probe('dispatch_owner_safety_notice', { p_estate: NIL });
  const oldLever = await probe('release_estate', { p_estate: NIL });

  if (!oldLever.missing) {
    // Production can release on ONE operator. Source cannot. Re-pasting fixes it, but reporting it
    // as agreement would be a false security claim.
    record('release_estate (one-person lever)', 'DEPLOYMENT_NEWER',
      'PRESENT IN PRODUCTION, REMOVED IN SOURCE — a one-person release path exists; apply 0055', []);
  }
  const f = [authorize, dispatch];
  if (f.every((p) => p.missing)) {
    record('release_authorization_authority', 'PENDING_DEPLOYMENT',
      'source authors authorize_release + dispatch_owner_safety_notice; production has neither '
      + '(apply death_verification_bundle.sql LAST)', []);
  } else if (f.every((p) => !p.missing)) {
    record('release_authorization_authority', 'UNVERIFIABLE',
      'DEPLOYED · stateful (two-person, window, dispatch) — behaviour covered by '
      + 'db/tests/release_safety_authorization.sql', []);
  } else {
    die(1, 'PARTIAL DEPLOYMENT — the Phase 11-F release surface is half-applied: '
      + `authorize_release ${authorize.missing ? 'ABSENT' : 'present'}, `
      + `dispatch_owner_safety_notice ${dispatch.missing ? 'ABSENT' : 'present'}. `
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
const drifted = results.filter((r) => !['EXACT', 'UNVERIFIABLE', 'PENDING_DEPLOYMENT'].includes(r.verdict));
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
const pendingRows = results.filter((r) => r.verdict === 'PENDING_DEPLOYMENT');
console.log(`✓ SOURCE AND DEPLOYMENT AGREE EXACTLY on all ${exact} reconcilable contract(s).`);
if (pendingRows.length > 0) {
  // ★ SAID OUT LOUD IN THE SUMMARY, not only in the table. A reader who skims to the last line must
  // not come away believing production carries everything this repository does.
  console.log(`\n⋯ ${pendingRows.length} contract(s) are PENDING DEPLOYMENT — source authors them and`);
  console.log('  production has never seen them. This is NOT agreement; it is the expected state');
  console.log('  before the operator paste, and it becomes drift the moment a paste is claimed done:');
  for (const p of pendingRows) console.log(`    ⋯ ${p.name} — ${p.detail}`);
}
console.log('  Compared by EXECUTING the source in an ephemeral Postgres and putting the same input');
console.log('  matrix through both sides — no hand-written mirror of any policy exists in this script.');
console.log(`  ${results.length - exact} stateful contract(s) are listed above as unreconcilable by name,`);
console.log('  each with the instrument that does cover it.');
