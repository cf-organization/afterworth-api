/**
 * R-02 TARGET GUARD — which Supabase project may receive a Model C hosted-compatibility test.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ ALLOWLIST, NOT DENYLIST. An unknown project ref is REFUSED, not permitted-by-default. The
 *   existing seed guard is a denylist (it names production and lets everything else through at
 *   dry-run), which is right for its job and wrong for this one: R-02 will eventually run
 *   destructive bootstrap operations, and "we forgot to add it to the deny list" must not be the
 *   thing standing between a test and a real database.
 *
 * ★ NAMES ARE NOT IDENTITY — THIS MODULE EXISTS BECAUSE THAT NEARLY WENT WRONG.
 *
 *   `supabase projects list` reports two projects:
 *     afterworth-prod   rpjjwkoezuihpobotbjh
 *     afterworth-dev    yiaavvkulrpqkkbqhwit
 *
 *   The project NAMED "dev" is the one the deployed application actually connects to — README.md
 *   pins `SUPABASE_URL=https://yiaavvkulrpqkkbqhwit.supabase.co` for Vercel, and ten proof documents
 *   corroborate it. The project NAMED "prod" appears nowhere in the repository.
 *
 *   Reading the CLI's names at face value, this session briefly "corrected" the seed guard's
 *   production pin to the name-only project — which would have REMOVED protection from the database
 *   that actually serves users. The existing test caught it by corroborating the ref against README
 *   and the proof docs. Classification here is therefore by ROLE, evidenced, never by name.
 *
 * ★ NO FORCE FLAG, NO ENV ESCAPE HATCH. There is deliberately no argument, environment variable or
 *   policy override that turns a refusal into an approval. PURE — no filesystem, no network.
 */

/** Refusal vocabulary. Closed set; a reason outside it is a bug, not a new policy. */
export const R02_REFUSAL = Object.freeze({
  MANIFEST_MISSING: 'manifest_missing',
  MANIFEST_MALFORMED: 'manifest_malformed',
  TARGET_MISSING: 'target_missing',
  TARGET_MALFORMED: 'target_malformed',
  APPLICATION_FACING_TARGET: 'application_facing_existing_database_forbidden',
  ROLE_UNESTABLISHED_TARGET: 'existing_project_role_unestablished_forbidden',
  TARGET_NOT_ALLOWLISTED: 'target_not_allowlisted',
  CLASSIFICATION_MISSING: 'environment_classification_missing',
  CLASSIFICATION_PRODUCTION: 'environment_classification_is_production',
  CLASSIFICATION_UNRECOGNIZED: 'environment_classification_unrecognized',
  OPERATION_MISSING: 'operation_missing',
  OPERATION_UNRECOGNIZED: 'operation_unrecognized',
  MUTATION_NOT_AUTHORIZED: 'bootstrap_mutation_not_authorized',
  DESTRUCTIVE_NOT_AUTHORIZED: 'destructive_reset_not_authorized',
  HOSTED_SQL_READ_NOT_AUTHORIZED: 'hosted_sql_read_not_authorized',
  MUTATION_TEST_NOT_AUTHORIZED: 'mutation_test_not_authorized',
  PROBE_ALREADY_CONSUMED: 'probe_authorization_already_consumed',
  BOOTSTRAP_MANIFEST_MISMATCH: 'bootstrap_manifest_hash_mismatch',
  MODEL_C_BOOTSTRAP_NOT_AUTHORIZED: 'model_c_bootstrap_0060_not_authorized',
  TARGET_NOT_REGISTERED: 'target_not_a_registered_r02_candidate',
  PROBE_VERSION_MISMATCH: 'probe_version_mismatch',
  MIGRATION_METADATA_WRITE_NOT_AUTHORIZED: 'migration_metadata_write_not_authorized',
  DEPLOY_NOT_AUTHORIZED: 'deployment_not_authorized',
  BOOTSTRAP_VERSION_MISMATCH: 'bootstrap_version_mismatch',
  SECRET_IN_MANIFEST: 'secret_material_in_manifest',
});

export const R02_DECISION = Object.freeze({
  /** Local planning only. Touches no database. */
  READ_ONLY_AUTHORIZED: 'READ_ONLY_AUTHORIZED',
  /**
   * A hosted SELECT against the target.
   * ★ DISTINCT FROM MUTATION_AUTHORIZED ON PURPOSE. Reporting an authorized read as
   *   "MUTATION_AUTHORIZED" would tell anyone auditing the decision log that a write was permitted
   *   when none was. The verdict vocabulary has to be able to say what actually happened.
   */
  HOSTED_READ_AUTHORIZED: 'HOSTED_READ_AUTHORIZED',
  /** A hosted operation that changes state. */
  MUTATION_AUTHORIZED: 'MUTATION_AUTHORIZED',
  REFUSED: 'REFUSED',
});

export const R02_OPERATIONS = Object.freeze({
  /** Local planning against the manifest. Touches no database. */
  READ_ONLY_PLANNING: 'read_only_planning',
  /** Alias retained for callers written before the registry existed. */
  READ_ONLY_PREFLIGHT: 'read_only_preflight',
  /** Executing the SELECT-only capability pack against the hosted target. */
  HOSTED_SQL_READ: 'hosted_sql_read',
  /**
   * The isolated event-trigger privilege probe.
   * ★ ITS OWN OPERATION AND ITS OWN FLAG. It is narrower than a bootstrap and must not be reachable
   *   through bootstrap_authorized — the two answer different questions and carry different risk.
   */
  EVENT_TRIGGER_PROBE: 'event_trigger_probe',
  /** The fixed Model C bootstrap at VERSION 0060. Its own operation and its own flag. */
  MODEL_C_BOOTSTRAP_0060: 'model_c_bootstrap_0060',
  BOOTSTRAP_APPLY: 'bootstrap_apply',
  DESTRUCTIVE_RESET: 'destructive_reset',
  MIGRATION_METADATA_WRITE: 'migration_metadata_write',
  DEPLOY: 'deploy',
});

/**
 * Operations that touch nothing remote. Everything else needs its own explicit authorization flag.
 * ★ THE DEFAULT SIDE OF THIS LINE IS "NEEDS AUTHORIZATION". A new operation added to the union
 *   without a flag lands in the authorized-required set, not the free set.
 */
export const LOCAL_ONLY_OPERATIONS = Object.freeze([
  'read_only_planning', 'read_only_preflight',
]);

/** operation -> the manifest flag that must be exactly true. */
export const OPERATION_AUTHORIZATION_FLAG = Object.freeze({
  hosted_sql_read: 'hosted_sql_read_authorized',
  event_trigger_probe: 'mutation_test_authorized',
  // ★ ITS OWN FLAG, NOT bootstrap_authorized. Sharing the generic flag would mean a broad
  //   "bootstrap" approval silently authorized this specific hash-pinned 921-statement run — the
  //   exact flag-collapsing this model exists to prevent. It also violated the distinctness rule,
  //   which a test caught immediately.
  model_c_bootstrap_0060: 'model_c_bootstrap_0060_authorized',
  bootstrap_apply: 'bootstrap_authorized',
  destructive_reset: 'destructive_reset_authorized',
  migration_metadata_write: 'migration_metadata_write_authorized',
  deploy: 'deployment_authorized',
});

export const R02_CLASSIFICATIONS = Object.freeze(['nonproduction', 'production']);

/**
 * Refs that may never be an R-02 target, with the EVIDENCE for each classification.
 * ★ Recorded as data with a reason, so a future reader cannot mistake either for a name judgement.
 */
export const FORBIDDEN_TARGETS = Object.freeze([
  Object.freeze({
    ref: 'yiaavvkulrpqkkbqhwit',
    supabaseName: 'afterworth-dev',
    protectedReason: 'APPLICATION_FACING_EXISTING_DATABASE',
    reason: R02_REFUSAL.APPLICATION_FACING_TARGET,
    evidence: 'README.md pins SUPABASE_URL=https://yiaavvkulrpqkkbqhwit.supabase.co for the deployed Vercel app; corroborated by ten docs/*-proof.md. Despite its Supabase name, this is the database serving users, and it is also the source of the authoritative Model C snapshot.',
  }),
  Object.freeze({
    ref: 'rpjjwkoezuihpobotbjh',
    supabaseName: 'afterworth-prod',
    protectedReason: 'EXISTING_PAUSED_FUTURE_PRODUCTION_CANDIDATE',
    reason: R02_REFUSAL.ROLE_UNESTABLISHED_TARGET,
    observedStatus: 'INACTIVE',
    region: 'us-east-1',
    // ★ PROTECTED BY UNCERTAINTY, WHICH IS NOT THE SAME AS PROTECTED BY EVIDENCE.
    //   This project is listed by the API and referenced nowhere in the repository. "Appears unused"
    //   is an absence of information, and an absence of information is not a licence: unknown real
    //   infrastructure is not disposable infrastructure. It is refused until somebody establishes
    //   what it is — and establishing that is a separate unit, not a side effect of needing a target.
    evidence: 'Listed by `supabase projects list` as afterworth-prod, region us-east-1, API-reported status INACTIVE (paused) — which corroborates the owner\'s report rather than resting on it. Referenced nowhere in this repository, and RETAINED by explicit decision as a candidate for future production use. Refused on uncertainty and on retention, never on evidence of unimportance.',
  }),
]);

/**
 * ★ DISPLAY NAMES ARE NEVER AN INPUT TO A SAFETY DECISION.
 *
 * The Supabase project named "dev" is the application's database and the one named "prod" is
 * unreferenced. Any rule keyed on the strings prod/dev/staging would therefore get BOTH projects
 * exactly backwards. Classification is by project ref plus an adjudicated, evidenced role — and a
 * test greps this module to prove no name-based branch exists.
 */
export const NAME_BASED_CLASSIFICATION_FORBIDDEN = true;

/**
 * Retention decision, recorded so a future reader does not mistake "paused" for "disposable".
 * ★ NEITHER EXISTING PROJECT MAY BE DELETED BY ANY R-02 WORKFLOW. Deletion is not among this
 *   module's concerns and no code path performs it; this constant exists to make the intent
 *   explicit and testable rather than implied by silence.
 */
export const EXISTING_PROJECT_DISPOSITION = Object.freeze({
  yiaavvkulrpqkkbqhwit: Object.freeze({ retained: true, deletable: false, r02_target: false, note: 'application-facing database' }),
  rpjjwkoezuihpobotbjh: Object.freeze({ retained: true, deletable: false, r02_target: false, note: 'paused; retained as future production candidate' }),
});

/**
 * ★ MIGRATION EXECUTION MODEL — ADJUDICATED, NOT ASSUMED.
 *
 * The Supabase CLI migration workflow is NOT adopted for R-02 hosted bootstrap. AfterWorth keeps its
 * migrations in `db/migrations/` with `NNNN_YYYYMMDD_` names and has no `supabase/` directory, so
 * `supabase migration up` would today see no local migrations at all.
 *
 * Writing `supabase_migrations.schema_migrations` before an execution model exists would manufacture
 * history with no operational meaning — recording that 0001-0060 "ran" on a database where they
 * demonstrably did not. Model C's whole value is refusing to pretend that. Metadata and cutover are
 * a separate proof stage, after hosted compatibility is established.
 *
 * This concerns EXECUTION TOOLING ONLY. The schema contract is untouched: bootstrap@0060 + 0061+.
 */
export const MIGRATION_EXECUTION_MODEL = Object.freeze({
  current: 'MANUAL_MODEL_C_HOSTED_COMPATIBILITY',
  supabase_cli_workflow_adopted: false,
  schema_migrations_preseed_authorized: false,
  migration_repair_authorized: false,
  rationale: 'Repository migrations live in db/migrations/; no supabase/migrations/ exists; no CLI migration workflow has been adopted. Remote migration metadata will not be written before an execution model is adjudicated.',
  unchanged_schema_contract: 'bootstrap@0060 + future migrations 0061+',
});

/**
 * The registered R-02 candidate target — control-plane identity only.
 *
 * ★ REGISTERED DOES NOT MEAN AUTHORIZED. Being in this registry makes a ref ELIGIBLE to be named in
 *   a manifest; every hosted operation still needs its own explicit flag, all of which are false.
 *   `afterworth-nonprod` was created by the operator in the Supabase Dashboard, never by this code.
 *
 * ★ THIS IS CONTROL-PLANE IDENTITY, NOT DATABASE IDENTITY. The management API tells us which project
 *   was created; it does not tell us that a future session actually connects to that database under
 *   the expected execution identity. Proving that is a separate, separately-authorized read-only
 *   step — which is exactly why R-02 stops at R02_1_NONPROD_IDENTIFIED here and not at R02_2.
 */
export const CANDIDATE_R02_TARGETS = Object.freeze([
  Object.freeze({
    ref: 'qxzeougbaarecaiiqsay',
    projectName: 'afterworth-nonprod',
    organization: 'rvudommjwqgtluhvfgcw',
    region: 'us-west-2',
    classification: 'CANDIDATE_R02_NONPROD',
    observedStatus: 'ACTIVE_HEALTHY',
    createdAt: '2026-08-28T21:25:53.48028Z',
    creationMethod: 'USER_SUPABASE_DASHBOARD',
    evidence: 'Discovered via `supabase projects list` (control plane, credential-safe). Distinct from both protected refs, in the expected organization and region, and the sole project bearing this name.',
  }),
]);

/**
 * ★ EXPLICIT, REF-SCOPED, ONE-OPERATION AUTHORIZATION GRANT.
 *
 * This is the reviewable record of what a human authorized, kept in source rather than left implicit
 * in a local manifest — so the grant appears in a diff, in review, and in `git log`, and cannot be
 * widened by editing an untracked file.
 *
 * It authorizes EXACTLY ONE operation (`hosted_sql_read`) against EXACTLY ONE ref. It confers
 * nothing else: bootstrap, destructive reset, migration-metadata write and deploy all remain
 * unauthorized, and no entry here can grant them.
 *
 * ★ IT CANNOT REACH A PROTECTED REF. The forbidden-target rule (R4) runs before authorization is
 *   even consulted, so adding a protected ref to this list would change nothing — and a test proves
 *   exactly that rather than trusting the ordering to stay as it is.
 */
export const HOSTED_READ_AUTHORIZATION = Object.freeze([
  Object.freeze({
    ref: 'qxzeougbaarecaiiqsay',
    projectName: 'afterworth-nonprod',
    operation: 'hosted_sql_read',
    authorizedBy: 'operator, R-02 Phase 2B',
    scope: 'SELECT-only capability pack (docs/r02/capability-check.sql) executed manually in the Supabase SQL Editor',
    grants: Object.freeze(['hosted_sql_read']),
    withholds: Object.freeze(['bootstrap_apply', 'destructive_reset', 'migration_metadata_write', 'deploy']),
  }),
]);

/**
 * ★ EXPLICIT MUTATION AUTHORIZATION — ONE PROBE, ONE VERSION, ONE REF, ONE OPERATION.
 *
 * The first authorization in this programme that permits a hosted WRITE. It is deliberately the
 * narrowest possible grant: a single disposable event trigger and its single disposable function,
 * on one project, under one reviewed probe version.
 *
 * ★ IT AUTHORIZES A QUESTION, NOT AN OUTCOME. The probe is EXPECTED to be refused — the hosted
 *   execution role has rolsuper = false, and local validation reproduced
 *   "Must be superuser to create an event trigger" for exactly that shape of role. A refusal is the
 *   measurement succeeding, not the probe failing, and no escalation is authorized in response.
 *
 * ★ IT CONFERS NOTHING ELSE. Not a bootstrap, not a reset, not a metadata write, not a deploy, not
 *   the canonical ensure_rls / rls_auto_enable objects, not a second probe version. Widening it
 *   requires a new reviewed entry, which shows up in a diff.
 */
export const MUTATION_TEST_AUTHORIZATION = Object.freeze([
  Object.freeze({
    ref: 'qxzeougbaarecaiiqsay',
    projectName: 'afterworth-nonprod',
    operation: 'event_trigger_probe',
    probeVersion: 'v1',
    probeFunction: 'r02_probe_event_fn_v1',
    probeTrigger: 'r02_probe_event_trigger_v1',
    probeSqlSha256: '38481de565e71df9cc5b1472cd80abfe2015b81a733379e2d39e4429b1c191dc',
    authorizedBy: 'operator, R-02 Phase 3B',
    /**
     * ★ CONSUMED. The probe ran on 2026-08-30 and was cleaned up
     *   (EVENT_TRIGGER_CREATION_SUCCEEDED_AND_CLEANED). A one-question authorization that stays
     *   live after the question is answered is a standing licence to mutate a hosted database for
     *   no remaining reason. Re-running v1 requires a new grant.
     */
    consumed: true,
    consumedAt: '2026-08-30',
    outcome: 'EVENT_TRIGGER_CREATION_SUCCEEDED_AND_CLEANED',
    grants: Object.freeze(['event_trigger_probe']),
    withholds: Object.freeze(['bootstrap_apply', 'destructive_reset', 'migration_metadata_write', 'deploy']),
    forbidsCanonicalObjects: Object.freeze(['ensure_rls', 'rls_auto_enable']),
    executedBy: 'operator, manually, in the Supabase SQL Editor — never by automation',
  }),
]);

/**
 * ★ THE BOOTSTRAP GRANT — 921 STATEMENTS, ONE PROJECT, ONE VERSION, ONE MANIFEST HASH.
 *
 * The largest authorization in this programme. Recorded in source so it appears in a diff, in
 * review and in `git log`, and pinned to the CUMULATIVE MANIFEST HASH computed from merged main —
 * so a bootstrap edited by even one byte cannot inherit this approval.
 *
 * ★ IT DOES NOT AUTHORIZE RECOVERY. There is deliberately no accompanying reset or cleanup grant.
 *   If a phase fails after mutation the environment is PARTIAL_BOOTSTRAP and the operator stops —
 *   because the alternative, letting a bootstrap approval imply "and undo it if it goes wrong",
 *   turns one decision into two and the second one is destructive.
 *
 * ★ IT DOES NOT AUTHORIZE MIGRATION METADATA. Nothing may write supabase_migrations, and no history
 *   for 0001-0060 may be fabricated. Those migrations are not replayed and must not be recorded as
 *   though they were.
 */
export const MODEL_C_BOOTSTRAP_AUTHORIZATION = Object.freeze([
  Object.freeze({
    ref: 'qxzeougbaarecaiiqsay',
    projectName: 'afterworth-nonprod',
    operation: 'model_c_bootstrap_0060',
    bootstrapVersion: '0060',
    manifestSha256: '69ec3a15fa3ad9380fae401b46d715b4259a74a4517b79ac63ba12e58f16ad67',
    phaseCount: 13,
    executableStatements: 921,
    setPreambleStatements: 28,
    authorizedBy: 'operator, R-02 Phase 4B',
    grants: Object.freeze(['model_c_bootstrap_0060']),
    withholds: Object.freeze(['event_trigger_probe', 'destructive_reset', 'migration_metadata_write', 'deploy', 'bootstrap_apply']),
    executedBy: 'operator, manually, phase-by-phase in the Supabase SQL Editor — never by automation',
    recoveryAuthorized: false,
    partialFailurePolicy: 'HALT and classify PARTIAL_BOOTSTRAP; destructive reset requires separate authorization',
  }),
]);

/** A Supabase project ref: exactly 20 lowercase letters. */
const REF = /^[a-z]{20}$/;

/** Keys whose presence in a manifest means a secret was stored where it must never be. */
export const SECRET_KEY_PATTERN = /(password|passwd|secret|service_role|access_token|api_?key|anon_key|connection_string|db_url|dsn)/i;

const str = (v) => (typeof v === 'string' ? v.trim() : '');

/**
 * Decide what, if anything, may be done against a target.
 *
 * @param manifest  the local non-secret environment manifest
 * @param request   { operation, bootstrapVersion }
 */
export function classifyR02Target(manifest, request = {}) {
  const reasons = [];
  const guards = [];
  const fail = (id, reason) => { guards.push({ id, pass: false, reason }); if (!reasons.includes(reason)) reasons.push(reason); };
  const pass = (id) => guards.push({ id, pass: true, reason: null });

  /* ── R1 · A MANIFEST MUST EXIST AND BE AN OBJECT ─────────────────────────────────────────── */
  if (!manifest || typeof manifest !== 'object' || Array.isArray(manifest)) {
    return { decision: R02_DECISION.REFUSED, reasons: [R02_REFUSAL.MANIFEST_MISSING], guards: [{ id: 'R1_manifest_present', pass: false, reason: R02_REFUSAL.MANIFEST_MISSING }] };
  }
  pass('R1_manifest_present');

  /* ── R2 · NO SECRET MATERIAL, ANYWHERE IN THE MANIFEST ───────────────────────────────────── */
  const secretKeys = [];
  const walk = (node, path) => {
    if (!node || typeof node !== 'object') return;
    for (const [k, v] of Object.entries(node)) {
      if (SECRET_KEY_PATTERN.test(k)) secretKeys.push([...path, k].join('.'));
      walk(v, [...path, k]);
    }
  };
  walk(manifest, []);
  if (secretKeys.length) fail('R2_no_secrets', R02_REFUSAL.SECRET_IN_MANIFEST); else pass('R2_no_secrets');

  /* ── R3 · EXPLICIT, WELL-FORMED TARGET ───────────────────────────────────────────────────── */
  const ref = str(manifest?.supabase?.project_ref);
  if (ref === '') fail('R3_explicit_target', R02_REFUSAL.TARGET_MISSING);
  else if (!REF.test(ref)) fail('R3_explicit_target', R02_REFUSAL.TARGET_MALFORMED);
  else pass('R3_explicit_target');

  /* ── R4 · FORBIDDEN TARGETS, BY EVIDENCED ROLE ───────────────────────────────────────────── */
  // Matched on REF ONLY. `supabaseName` is carried for human readers and asserted by tests; it is
  // never consulted here, so a project rename cannot change what this guard decides.
  const forbidden = FORBIDDEN_TARGETS.find((f) => f.ref === ref);
  if (forbidden) fail('R4_forbidden_target', forbidden.reason); else pass('R4_forbidden_target');

  /* ── R5 · ALLOWLIST — UNKNOWN IS REFUSED ─────────────────────────────────────────────────── */
  const allow = Array.isArray(manifest?.safety?.allowlisted_refs) ? manifest.safety.allowlisted_refs.filter((r) => typeof r === 'string') : [];
  if (ref === '' || !allow.includes(ref)) fail('R5_allowlisted', R02_REFUSAL.TARGET_NOT_ALLOWLISTED); else pass('R5_allowlisted');

  /* ── R6 · EXPLICIT NON-PRODUCTION CLASSIFICATION ─────────────────────────────────────────── */
  const cls = str(manifest?.environment?.classification);
  if (cls === '') fail('R6_classification', R02_REFUSAL.CLASSIFICATION_MISSING);
  else if (!R02_CLASSIFICATIONS.includes(cls)) fail('R6_classification', R02_REFUSAL.CLASSIFICATION_UNRECOGNIZED);
  else if (cls === 'production') fail('R6_classification', R02_REFUSAL.CLASSIFICATION_PRODUCTION);
  else pass('R6_classification');
  if (manifest?.safety?.production === true) fail('R6_classification', R02_REFUSAL.CLASSIFICATION_PRODUCTION);

  /* ── R7 · OPERATION FROM A CLOSED SET ────────────────────────────────────────────────────── */
  const op = str(request?.operation);
  if (op === '') fail('R7_operation', R02_REFUSAL.OPERATION_MISSING);
  else if (!Object.values(R02_OPERATIONS).includes(op)) fail('R7_operation', R02_REFUSAL.OPERATION_UNRECOGNIZED);
  else pass('R7_operation');

  /* ── R8 · EVERY REMOTE OPERATION NEEDS ITS OWN EXPLICIT FLAG ─────────────────────────────────
   * ★ ONE FLAG PER OPERATION, NEVER A SHARED "MUTATION" FLAG. Authorizing a bootstrap must not
   *   incidentally authorize a reset, a metadata write, or a deploy — each is a different decision
   *   with a different blast radius, and collapsing them is how one approval becomes five. */
  const flagFor = { ...OPERATION_AUTHORIZATION_FLAG };
  const reasonFor = {
    hosted_sql_read: R02_REFUSAL.HOSTED_SQL_READ_NOT_AUTHORIZED,
    event_trigger_probe: R02_REFUSAL.MUTATION_TEST_NOT_AUTHORIZED,
    model_c_bootstrap_0060: R02_REFUSAL.MODEL_C_BOOTSTRAP_NOT_AUTHORIZED,
    bootstrap_apply: R02_REFUSAL.MUTATION_NOT_AUTHORIZED,
    destructive_reset: R02_REFUSAL.DESTRUCTIVE_NOT_AUTHORIZED,
    migration_metadata_write: R02_REFUSAL.MIGRATION_METADATA_WRITE_NOT_AUTHORIZED,
    deploy: R02_REFUSAL.DEPLOY_NOT_AUTHORIZED,
  };
  if (Object.prototype.hasOwnProperty.call(flagFor, op)) {
    if (manifest?.safety?.[flagFor[op]] !== true) fail('R8_operation_authorized', reasonFor[op]);
    else if (op === R02_OPERATIONS.EVENT_TRIGGER_PROBE
             && MUTATION_TEST_AUTHORIZATION.some((g) => g.ref === ref && g.consumed === true)) {
      // ★ A CONSUMED GRANT CANNOT RE-AUTHORIZE. The manifest flag alone is not enough once the
      //   question has been answered — otherwise the flag becomes a standing mutation licence.
      fail('R8_operation_authorized', R02_REFUSAL.PROBE_ALREADY_CONSUMED);
    } else pass('R8_operation_authorized');
  } else if (LOCAL_ONLY_OPERATIONS.includes(op)) {
    pass('R8_operation_authorized');
  } else {
    // Unrecognized operation already failed R7; refuse here too rather than fall through to a pass.
    fail('R8_operation_authorized', R02_REFUSAL.OPERATION_UNRECOGNIZED);
  }

  /* ── R8b · THE PROBE VERSION IS PINNED ───────────────────────────────────────────────────────
   * ★ An authorization is for ONE reviewed probe, not for "whatever the probe file says today".
   *   Requiring the caller to name the version means a later edit to the probe cannot inherit an
   *   approval granted to a different one. */
  if (op === R02_OPERATIONS.EVENT_TRIGGER_PROBE) {
    const want = str(request?.probeVersion);
    if (want === '' || want !== str(manifest?.expected_model?.probe_version)) {
      fail('R8b_probe_version', R02_REFUSAL.PROBE_VERSION_MISMATCH);
    } else pass('R8b_probe_version');
  } else pass('R8b_probe_version');

  /* ── R8c · THE BOOTSTRAP IS AUTHORIZED BY HASH, NOT BY INSPECTION ────────────────────────────
   * ★ Verb-level inspection cannot make a 921-statement bootstrap safe — one substituted statement
   *   in 921 would pass any plausible allowlist. The caller must name the cumulative manifest hash,
   *   so an altered phase file cannot inherit an approval granted to a different bootstrap. */
  if (op === R02_OPERATIONS.MODEL_C_BOOTSTRAP_0060) {
    const want = str(request?.bootstrapManifestSha256);
    if (want === '' || want !== str(manifest?.expected_model?.bootstrap_manifest_sha256)) {
      fail('R8c_bootstrap_manifest', R02_REFUSAL.BOOTSTRAP_MANIFEST_MISMATCH);
    } else if (!CANDIDATE_R02_TARGETS.some((t) => t.ref === ref)) {
      // ★ THE BOOTSTRAP IS PINNED TO THE REGISTERED TARGET, NOT MERELY TO THE ALLOWLIST.
      //   The allowlist is operator-declared and is the right mechanism for a read: it proves the
      //   operator named the ref deliberately. It is NOT sufficient for a 921-statement mutation,
      //   where a mistyped-but-allowlisted ref would be authorized. A test caught exactly that:
      //   an unknown well-formed ref, self-allowlisted, was returned MUTATION_AUTHORIZED.
      fail('R8c_bootstrap_manifest', R02_REFUSAL.TARGET_NOT_REGISTERED);
    } else pass('R8c_bootstrap_manifest');
  } else pass('R8c_bootstrap_manifest');

  /* ── R9 · THE MANIFEST MUST AGREE WITH THE REPOSITORY'S BOOTSTRAP VERSION ─────────────────── */
  const want = str(request?.bootstrapVersion);
  const have = str(manifest?.expected_model?.bootstrap_version);
  if (want !== '' && have !== want) fail('R9_bootstrap_version', R02_REFUSAL.BOOTSTRAP_VERSION_MISMATCH); else pass('R9_bootstrap_version');

  if (reasons.length) return { decision: R02_DECISION.REFUSED, reasons, guards };
  return {
    decision: LOCAL_ONLY_OPERATIONS.includes(op) ? R02_DECISION.READ_ONLY_AUTHORIZED
      : op === R02_OPERATIONS.HOSTED_SQL_READ ? R02_DECISION.HOSTED_READ_AUTHORIZED
      : R02_DECISION.MUTATION_AUTHORIZED,
    reasons: [], guards,
  };
}

/**
 * PURE. Static refusal of any command string that would mutate a remote database.
 * ★ Complements the manifest guard: even an authorized target may only receive commands from the
 *   read-only set during preflight.
 */
export const FORBIDDEN_REMOTE_COMMANDS = Object.freeze([
  'db push', 'db reset', 'migration up', 'migration repair', 'migration down',
  'db dump --data-only', 'projects create', 'projects delete', 'db remote commit',
  // Any write to the migration history table is refused while the execution model is unadjudicated.
  'insert into supabase_migrations', 'update supabase_migrations', 'delete from supabase_migrations',
]);

export function isRemoteMutationCommand(cmd) {
  const c = String(cmd ?? '').toLowerCase().replace(/\s+/g, ' ').trim();
  if (c === '') return false;
  if (FORBIDDEN_REMOTE_COMMANDS.some((f) => c.includes(f))) return true;
  return /^\s*(create|alter|drop|insert|update|delete|truncate|grant|revoke)\b/i.test(c);
}
