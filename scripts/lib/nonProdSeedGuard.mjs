/**
 * GUARDED NON-PRODUCTION SEED / RESET — THE GUARD LAYER, AND ONLY THE GUARD LAYER.
 *
 * ★ THERE IS NO EXECUTION HERE, AND THAT IS THE POINT OF THE SLICE. This module decides whether a
 * seed or reset would be PERMITTED to proceed. It never seeds, never resets, never connects, never
 * reads an environment variable and never touches a filesystem. The most permissive verdict it can
 * return is `DRY_RUN_AUTHORIZED`, which authorizes nothing but the printing of that word.
 *
 * ★ IT IS PURE, WITH NO IMPORTS AT ALL. A classifier that could read `process.env` would let a
 * stale or attacker-shaped environment participate in the decision, and a classifier that could
 * reach the filesystem could be pointed at a different policy file than the one under review. The
 * absence of imports is load-bearing and is asserted by `test/nonProdSeedGuard.test.ts`.
 *
 * ★ THE THREAT IT EXISTS FOR: an operator who intends to reset NON-PRODUCTION and points the tool
 * at PRODUCTION. Every design choice below follows from that one sentence — most of all the rule
 * that the production pin is checked against the TARGET REF and cannot be talked out of it by any
 * label, flag, confirmation or operation the caller supplies.
 *
 * ────────────────────────────────────────────────────────────────────────────────────────────────
 * THE COMMITTED CONTRACT THIS IMPLEMENTS, AND WHERE IT CAME FROM
 *
 * `afterworth-mobile/docs/testing/environment-and-seeding-plan.md` § "Guarded seed/reset tooling
 * (must exist before seeding)" is the authority. It commits to FIVE guards, not four:
 *
 *   plan 1 · project-ref guard      → G1 (explicit target) + G2 (production pin). The plan states
 *                                     both halves in one sentence — "reads the target project ref
 *                                     and refuses to run if it matches the production ref … fail
 *                                     closed on an unreadable ref" — and they are SEPARATED here,
 *                                     because "no target supplied" and "the target is production"
 *                                     are different operator mistakes needing different words.
 *   plan 2 · estate-id allowlist    → G6 (manifest allowlist)
 *   plan 3 · synthetic-identity     → G5 (plus-addressed on the approved domain)
 *   plan 4 · idempotent seed+reset  → NOT IMPLEMENTED. It is an execution-layer property (delete in
 *                                     FK order), and this slice ships no execution layer. The
 *                                     declared order is carried as DATA in `RESET_FK_ORDER` so the
 *                                     future adapter cannot invent its own, and nothing here acts
 *                                     on it.
 *   plan 5 · no secrets in the repo → enforced OUTSIDE this module, by registering it in
 *                                     `noProductionMutation.test.ts`'s READ_ONLY_FILES, which fails
 *                                     on any forbidden secret token appearing in code.
 *
 * G3 (environment intent) and G4 (destructive confirmation) are NOT in the plan. They are added
 * deliberately and the decision is recorded here rather than left implicit: the plan's project-ref
 * guard is a single point of failure — it protects only against refs it already knows. G3 forces
 * the operator to state non-production intent for a ref the pin has never heard of, and G4 makes
 * a destructive operation name its own target. Neither weakens a committed guard; both are extra
 * locks on the same door.
 *
 * ★ THE GUARDS ARE INDEPENDENT BY CONSTRUCTION. Every guard is evaluated on every call — there is
 * no short-circuit — and each contributes its own refusal reason. That is what makes "delete any
 * one guard" a detectable mutation: a short-circuiting chain would mask later guards behind an
 * earlier failure, and a deleted guard would then be invisible whenever another one happened to
 * fire first.
 */

/* ────────────────────────────────────────────────────────────────────────────────────────────────
 * POLICY
 * ──────────────────────────────────────────────────────────────────────────────────────────────*/

/**
 * ★ THE PRODUCTION PIN IS COMMITTED SOURCE, NOT CONFIGURATION, AND THE DISTINCTION IS THE CONTROL.
 *
 * A production ref resolved from the operator's environment protects nothing when that environment
 * is the thing that is wrong — and "stale environment variables" is the second entry on this
 * tool's threat list. Pinned in source, the denylist cannot be changed by a shell, a CI variable,
 * a `.env` file or a flag; changing it requires a reviewed commit that a human reads.
 *
 * This value is NOT a secret and introduces no disclosure: the same project ref is already
 * committed in `README.md` and in ten `docs/*-proof.md` files. A project ref is an identifier, not
 * a credential — it authorizes nothing on its own, which is precisely why it is safe to write down
 * and useful to deny.
 */
export const PRODUCTION_PROJECT_REFS = Object.freeze(['yiaavvkulrpqkkbqhwit']);

/**
 * A Supabase project ref: exactly 20 lowercase letters. Shape is checked so a URL, a connection
 * string, an empty-ish value or a pasted fragment cannot be mistaken for an identity — an
 * "ambiguous project identity" is on the threat list, and the honest response to one is refusal
 * rather than a best guess.
 */
const PROJECT_REF_PATTERN = /^[a-z]{20}$/;

/**
 * The environment labels a destructive tool may act under. `production` is present ON PURPOSE: it
 * must be a RECOGNIZED value that is REFUSED, not an unrecognized one. Dropping it would make
 * `declaredEnvironment: 'production'` fail as a typo, which reports the wrong problem to the
 * operator and would let a future edit "fix" the typo by adding it to the permitted set.
 */
export const ENVIRONMENT_LABELS = Object.freeze(['development', 'staging', 'test', 'production']);
const NON_PRODUCTION_LABELS = Object.freeze(['development', 'staging', 'test']);

export const OPERATIONS = Object.freeze(['seed', 'reset']);
/** Reset destroys data; seed does not. Only this set demands G4. */
const DESTRUCTIVE_OPERATIONS = Object.freeze(['reset']);

/**
 * The approved domain for synthetic seed identities, and the requirement that they be
 * plus-addressed (`someone+tag@domain`). Both come from plan guard 3.
 *
 * ★ NO SYNTHETIC IDENTITY IS COMMITTED HERE. This is a DOMAIN and a SHAPE — never an address,
 * never a local part, never a password. The repository rule is that synthetic account values never
 * reach source, and a rule that required naming one to enforce it would defeat itself.
 */
export const DEFAULT_GUARD_POLICY = Object.freeze({
  productionProjectRefs: PRODUCTION_PROJECT_REFS,
  syntheticEmailDomain: 'after-worth.com',
});

/**
 * The order in which a future reset must delete, copied verbatim from the plan so the execution
 * layer cannot invent one. DATA ONLY — nothing in this module reads it, and no code path acts on
 * it. It lives here so the eventual adapter has a single reviewed source rather than a fresh guess.
 */
export const RESET_FK_ORDER = Object.freeze([
  'grants',
  'access_requests',
  'notifications',
  'claim_packets',
  'claims',
  'documents',
  'designations',
  'memberships',
  'estates',
  'users',
]);

/**
 * The CLOSED refusal vocabulary. A caller may switch on these; a generic "invalid configuration"
 * is never returned, because an operator who is told only that something is wrong will retry with
 * a different guess — and one of those guesses is production.
 */
export const REFUSAL_REASONS = Object.freeze([
  'guard_policy_unresolved',
  'target_missing',
  'target_malformed',
  'production_target_forbidden',
  'environment_intent_missing',
  'environment_intent_unrecognized',
  'environment_intent_is_production',
  'operation_missing',
  'operation_unrecognized',
  'destructive_confirmation_missing',
  'destructive_confirmation_target_mismatch',
  'synthetic_identity_required',
  'estate_not_in_manifest',
]);

export const DECISION = Object.freeze({
  DRY_RUN_AUTHORIZED: 'DRY_RUN_AUTHORIZED',
  REFUSED: 'REFUSED',
});

/** Guard ids, in evaluation order. Exported so a test can assert none has silently vanished. */
export const GUARD_IDS = Object.freeze([
  'G1_explicit_target',
  'G2_production_pin',
  'G3_environment_intent',
  'G4_destructive_confirmation',
  'G5_synthetic_identity',
  'G6_estate_manifest',
]);

/* ────────────────────────────────────────────────────────────────────────────────────────────────
 * HELPERS — total, and never throwing on a hostile input shape
 * ──────────────────────────────────────────────────────────────────────────────────────────────*/

/** A string, trimmed; anything else (number, null, object, array) becomes ''. */
function str(v) {
  return typeof v === 'string' ? v.trim() : '';
}
function arr(v) {
  return Array.isArray(v) ? v : [];
}

/* ────────────────────────────────────────────────────────────────────────────────────────────────
 * THE CLASSIFIER
 * ──────────────────────────────────────────────────────────────────────────────────────────────*/

/**
 * Decide whether a seed or reset would be permitted. Pure: same input → same output, no I/O, no
 * mutation of the argument.
 *
 * @param {object} request
 * @param {string} request.targetRef            the project ref to act on. NO DEFAULT, ever.
 * @param {string} request.declaredEnvironment  an ENVIRONMENT_LABELS value. Never inferred.
 * @param {string} request.operation            an OPERATIONS value.
 * @param {string} [request.confirmDestructiveTarget] for `reset`: must equal `targetRef`.
 * @param {string[]} [request.identities]       seed identities (emails) to be created.
 * @param {string[]} [request.estateIds]        estates a reset would touch.
 * @param {string[]} [request.estateManifest]   estates this tool previously created.
 * @param {object} [policy]                     defaults to DEFAULT_GUARD_POLICY.
 * @returns {{decision: string, reasons: readonly string[], guards: readonly object[], targetRef: string|null, operation: string|null}}
 */
export function classifySeedRequest(request, policy = DEFAULT_GUARD_POLICY) {
  const req = request && typeof request === 'object' ? request : {};
  const reasons = [];
  const guards = [];
  const fail = (id, reason) => {
    guards.push({ id, pass: false, reason });
    if (!reasons.includes(reason)) reasons.push(reason);
  };
  const pass = (id) => guards.push({ id, pass: true, reason: null });

  /**
   * ★ AN UNRESOLVED POLICY REFUSES EVERYTHING. The plan says "fail closed on an unreadable ref";
   * this is that sentence generalized. A policy whose production list is missing or empty cannot
   * deny anything, so the guard that depends on it would silently pass — the exact shape of a
   * scanner that inspects nothing and reports clean.
   */
  const prodRefs = arr(policy?.productionProjectRefs).filter((r) => typeof r === 'string' && r.length > 0);
  const syntheticDomain = str(policy?.syntheticEmailDomain);
  const policyUsable = prodRefs.length > 0 && syntheticDomain !== '';
  if (!policyUsable) reasons.push('guard_policy_unresolved');

  const targetRef = str(req.targetRef);
  const declared = str(req.declaredEnvironment);
  const operation = str(req.operation);

  /* ── G1 · EXPLICIT TARGET ────────────────────────────────────────────────────────────────────
   * No default, no "current project", no fallback. Missing, empty and whitespace-only are the
   * same mistake and produce the same refusal; a malformed value is a DIFFERENT mistake, because
   * telling an operator "missing" when they pasted a URL sends them looking in the wrong place. */
  if (targetRef === '') fail('G1_explicit_target', 'target_missing');
  else if (!PROJECT_REF_PATTERN.test(targetRef)) fail('G1_explicit_target', 'target_malformed');
  else pass('G1_explicit_target');

  /* ── G2 · PRODUCTION PIN ─────────────────────────────────────────────────────────────────────
   * ★ THIS GUARD CONSULTS THE TARGET AND THE PIN, AND NOTHING ELSE. It does not look at
   * `declaredEnvironment`, at the confirmation, or at the operation — so no label and no flag can
   * argue it down. That independence IS the guard; a version that skipped the check when the
   * operator declared "development" would be exactly the accident this tool exists to prevent. */
  if (policyUsable && targetRef !== '' && prodRefs.includes(targetRef)) {
    fail('G2_production_pin', 'production_target_forbidden');
  } else if (!policyUsable) {
    fail('G2_production_pin', 'guard_policy_unresolved');
  } else {
    pass('G2_production_pin');
  }

  /* ── G3 · ENVIRONMENT INTENT ─────────────────────────────────────────────────────────────────
   * Explicit, from a closed set, and never inferred from absence. An unrecognized label is refused
   * rather than treated as non-production, because a typo must not become permission. */
  if (declared === '') fail('G3_environment_intent', 'environment_intent_missing');
  else if (!ENVIRONMENT_LABELS.includes(declared)) fail('G3_environment_intent', 'environment_intent_unrecognized');
  else if (!NON_PRODUCTION_LABELS.includes(declared)) fail('G3_environment_intent', 'environment_intent_is_production');
  else pass('G3_environment_intent');

  /* ── OPERATION ───────────────────────────────────────────────────────────────────────────────
   * Not a guard in its own right — it selects which guards apply — but an unrecognized operation
   * must refuse rather than fall through to the least destructive interpretation. */
  if (operation === '') reasons.push('operation_missing');
  else if (!OPERATIONS.includes(operation)) reasons.push('operation_unrecognized');

  /* ── G4 · DESTRUCTIVE CONFIRMATION ───────────────────────────────────────────────────────────
   * ★ RESET DEMANDS STRICTLY MORE THAN SEED. The confirmation must NAME the target, so an operator
   * who has two terminals open cannot confirm one project while pointed at another. A boolean
   * `--yes` would be satisfied by muscle memory; retyping the ref cannot be. */
  if (DESTRUCTIVE_OPERATIONS.includes(operation)) {
    const confirmation = str(req.confirmDestructiveTarget);
    if (confirmation === '') fail('G4_destructive_confirmation', 'destructive_confirmation_missing');
    else if (targetRef === '' || confirmation !== targetRef) {
      fail('G4_destructive_confirmation', 'destructive_confirmation_target_mismatch');
    } else pass('G4_destructive_confirmation');
  } else {
    // Not applicable to `seed`, and recorded as such rather than silently omitted — a guard list
    // with a hole in it reads like a guard that was forgotten.
    guards.push({ id: 'G4_destructive_confirmation', pass: true, reason: null, notApplicable: true });
  }

  /* ── G5 · SYNTHETIC IDENTITY (plan guard 3) ──────────────────────────────────────────────────
   * Every identity a seed would create must be plus-addressed on the approved domain. Checked for
   * BOTH operations: a reset that names identities is still naming who it will delete. */
  const identities = arr(req.identities);
  if (policyUsable && identities.some((e) => !isApprovedSyntheticIdentity(e, syntheticDomain))) {
    fail('G5_synthetic_identity', 'synthetic_identity_required');
  } else if (!policyUsable) {
    fail('G5_synthetic_identity', 'guard_policy_unresolved');
  } else {
    pass('G5_synthetic_identity');
  }

  /* ── G6 · ESTATE MANIFEST ALLOWLIST (plan guard 2) ───────────────────────────────────────────
   * "Writes are permitted only to estates created by the tool and recorded in its manifest." An
   * estate absent from the manifest is one this tool did not create, and therefore one whose loss
   * it cannot justify. An empty manifest with named estates refuses — never "nothing to check". */
  const estateIds = arr(req.estateIds).map(str).filter((s) => s !== '');
  const manifest = arr(req.estateManifest).map(str).filter((s) => s !== '');
  if (estateIds.some((id) => !manifest.includes(id))) fail('G6_estate_manifest', 'estate_not_in_manifest');
  else pass('G6_estate_manifest');

  const decision = reasons.length === 0 ? DECISION.DRY_RUN_AUTHORIZED : DECISION.REFUSED;
  return Object.freeze({
    decision,
    reasons: Object.freeze([...reasons]),
    guards: Object.freeze(guards.map((g) => Object.freeze(g))),
    // Echoed only on a permitted request. Echoing a refused target invites a caller to use the
    // value it was just refused for.
    targetRef: decision === DECISION.DRY_RUN_AUTHORIZED ? targetRef : null,
    operation: decision === DECISION.DRY_RUN_AUTHORIZED ? operation : null,
  });
}

/**
 * Plus-addressed on the approved domain: `local+tag@domain`, with a non-empty local part and a
 * non-empty tag. Case-insensitive on the domain, since mail domains are.
 */
export function isApprovedSyntheticIdentity(email, domain) {
  const e = str(email).toLowerCase();
  const d = str(domain).toLowerCase();
  if (e === '' || d === '') return false;
  const at = e.lastIndexOf('@');
  if (at <= 0 || e.slice(at + 1) !== d) return false;
  const local = e.slice(0, at);
  const plus = local.indexOf('+');
  return plus > 0 && plus < local.length - 1;
}
