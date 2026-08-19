/**
 * PHASE 11-P.5 · THE BRANCH B SESSION-2 SHA PROVENANCE ADDENDUM.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ WHY THE LEGACY SHA GATES HAD TO BE SUPERSEDED RATHER THAN REPAIRED.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * `evaluateResume` compares three observed SHAs against three checkpoint SHAs with a uniform `===`,
 * under the header "THE CODE UNDER TEST HAS NOT MOVED". Nothing in the code, the tests or the docs
 * ever said WHERE an observed SHA is read from — and the three repositories have three different
 * deployment models, so one uniform comparison cannot be right for all of them. Two defects follow,
 * and they point in OPPOSITE directions, which is why widening or tightening the same rule fixes
 * neither.
 *
 * ★ DEFECT 1 — THE API AND MOBILE PINS ARE STRUCTURALLY UNSATISFIABLE.
 *
 * `docs/phase11p-branchb-session1-checkpoint.json` was added by API commit `9f06a86`, and pins
 * `api_sha = 18ef102` — which is `9f06a86^`. The artifact could not contain its own commit's SHA, so
 * the act of committing it advanced main past its own pin. The same holds for mobile: the pinned
 * `8584324` is `58268bf^`. The only tree in which `api_sha_unchanged` is satisfiable is one that
 * DOES NOT CONTAIN THE CHECKPOINT BEING EVALUATED. Under every honest observation source available —
 * local HEAD, origin/main, deployed revision — both gates refuse, permanently, on evidence-only
 * movement. That is a false refusal that no observation can clear.
 *
 * ★ DEFECT 2 — THE ADMIN PIN WAS STALE AT BIRTH, AND IT FAILS OPEN.
 *
 * `admin_sha = fd7ef03` is the deliberately-stale FOREIGN LOCAL CHECKOUT. `fd7ef03` stopped being the
 * deployed admin revision on 2026-08-18T00:15Z, roughly 28 hours BEFORE the checkpoint was authored.
 * Admin production is `cd044fe`, and the two commits in between are exactly
 * `Phase 11-OC / Phase C — the console can tell an accepted notice from a legacy one` and
 * `Phase 11-OC / Phase D — the console reads the server's release authority instead of keeping its
 * own clock`. So an operator who observes the obvious thing — `git rev-parse HEAD` — gets a GREEN
 * `admin_sha_unchanged` over a console two production deployments behind the one reviewer B will
 * actually use, with its release-authority surface rewritten in between.
 *
 * ★ THE COMMON CAUSE: A VALUE WITHOUT A SOURCE IS NOT PROVENANCE.
 *
 * A SHA proves nothing on its own; what it proves depends entirely on where it was read from. So
 * this module makes the SOURCE load-bearing and typed, exactly as the identity-authority rule
 * requires: the expectation names its source kind, the observation carries the source kind it was
 * actually collected from, and BOTH must agree before a SHA is even compared. A local checkout can
 * therefore never be laundered into production provenance, because `local_checkout` is a kind the
 * schema refuses to accept as an EXPECTATION at all.
 *
 * ★ THE FROZEN CHECKPOINT IS NEVER REWRITTEN. It is historical evidence, and evidence edited to
 * agree with a later outcome proves nothing about the outcome. The addendum is ADDITIVE and BOUND to
 * the checkpoint by SHA-256: if one byte of the checkpoint changes, every Session-2 gate refuses.
 */
import { createHash } from 'node:crypto';

export const PROVENANCE_SCHEMA_VERSION = 1;

/** The operator ruling this artifact encodes. Versioned, so a later ruling cannot be mistaken for it. */
export const OPERATOR_RULING_ID = 'PHASE_11P5_SHA_PROVENANCE_ADDENDUM_V1';

/** The only status the legacy gates may carry. A closed vocabulary, so "superseded" cannot be spelled loosely. */
export const LEGACY_SHA_GATE_STATUS = 'superseded_for_session2';

/**
 * ★ THE EXACT THREE LEGACY GATE IDS THIS ADDENDUM SUPERSEDES — NAMED, NEVER PATTERN-MATCHED.
 *
 * A wildcard such as `/_sha_/` would today select the same three ids and would silently swallow any
 * future gate whose name happens to contain "sha" — including one added precisely to close a hole.
 * Supersession is the one operation in this file that REMOVES a refusal, so it is the one that must
 * be spelled out in full.
 */
export const SUPERSEDED_LEGACY_GATE_IDS = Object.freeze([
  'api_sha_unchanged',
  'mobile_sha_unchanged',
  'admin_sha_unchanged',
]);

/**
 * ★ THE CLOSED SOURCE-KIND VOCABULARY. THIS IS THE CONTAINMENT MECHANISM.
 *
 * `reviewed_revision`     — an IMMUTABLE reviewed commit, required to exist in the named repository
 *                           and to lie in the lineage of its named branch. It does not move when the
 *                           branch advances.
 * `source_revision`       — a named repository at a named REF, resolved from git metadata. The ref
 *                           is a moving target, so this kind asserts "the tip is exactly X".
 * `production_deployment` — a SUCCESSFUL deployment to the Production environment.
 * `local_checkout`        — a working-tree HEAD. Collectable, and NEVER expectable: see below.
 *
 * ★ PHASE 11-P.5b — WHY `reviewed_revision` HAD TO EXIST, PROVEN BY THIS FILE'S OWN MERGE.
 *
 * The first cut of this addendum pinned the reviewed Branch-B baseline `9f06a86` with source kind
 * `source_revision` against `refs/heads/main`. Merging THIS REMEDIATION advanced main to `7c7c25c`,
 * and the gate went red — not because provenance had drifted, but because a REVIEWED BASELINE had
 * been tied to a MOVING REF. That is the same shape as the defect being remediated, one level up,
 * and the architecture surfaced it rather than hiding it.
 *
 * A reviewed baseline is a claim about a COMMIT, not about a branch tip. What must stay true is that
 * the commit still EXISTS and is still IN THE LINEAGE — it was not force-pushed away, rewritten, or
 * left behind on an abandoned branch. What must NOT be required is that nothing else ever merges.
 * A deployed runtime is the opposite: there the tip IS the fact, which is why
 * `admin_console_production` keeps demanding the current successful Production deployment.
 */
export const SOURCE_KINDS = Object.freeze({
  REVIEWED_REVISION: 'reviewed_revision',
  SOURCE_REVISION: 'source_revision',
  PRODUCTION_DEPLOYMENT: 'production_deployment',
  LOCAL_CHECKOUT: 'local_checkout',
});

/**
 * ★ WHAT AN OBSERVATION MAY CLAIM TO BE. Includes `local_checkout` deliberately: a mis-wired
 * collector that reads a working tree must be able to SAY SO, so the mismatch is detected here
 * rather than disguised as a source revision. Removing it would not make local reads impossible, it
 * would make them unlabelable — and an unlabelable read is one that gets labelled something else.
 */
export const OBSERVABLE_SOURCE_KINDS = Object.freeze([
  SOURCE_KINDS.REVIEWED_REVISION,
  SOURCE_KINDS.SOURCE_REVISION,
  SOURCE_KINDS.PRODUCTION_DEPLOYMENT,
  SOURCE_KINDS.LOCAL_CHECKOUT,
]);

/**
 * ★ WHAT THE ADDENDUM MAY DEMAND. `local_checkout` is ABSENT, and that absence is the fix for
 * defect 2. There is no way to write an expectation that a working-tree HEAD satisfies, so
 * `fd7ef03` cannot be restored as authority by editing a value — it would require editing this
 * vocabulary, which is a visible change to a safety control rather than a data edit.
 */
export const EXPECTABLE_SOURCE_KINDS = Object.freeze([
  SOURCE_KINDS.REVIEWED_REVISION,
  SOURCE_KINDS.SOURCE_REVISION,
  SOURCE_KINDS.PRODUCTION_DEPLOYMENT,
]);

/** The three provenance components, named for what they ARE rather than for their repository. */
export const PROVENANCE_COMPONENTS = Object.freeze([
  'api_branch_b_source',
  'mobile_branch_b_source',
  'admin_console_production',
]);

const SHA1_RE = /^[0-9a-f]{40}$/;
const SHA256_RE = /^[0-9a-f]{64}$/;
const REPO_RE = /^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/;
const REF_RE = /^refs\/[A-Za-z0-9._\/-]{1,100}$/;
const ENVIRONMENT_RE = /^[A-Za-z][A-Za-z0-9_-]{0,31}$/;
/** Printable ASCII prose only — no control characters, and short enough that no payload fits. */
const SEMANTIC_RE = /^[ -~]{8,200}$/;
const isInstant = (v) =>
  typeof v === 'string' && /^\d{4}-\d{2}-\d{2}T/.test(v) && !Number.isNaN(Date.parse(v));

/** Canonical SHA-256 of the frozen checkpoint BYTES — never of a re-serialized object. */
export function sha256Bytes(buf) {
  return createHash('sha256').update(buf).digest('hex');
}

/**
 * Per-source-kind required shape. This is what makes `source_kind` load-bearing rather than a label:
 * a `production_deployment` expectation MUST name its environment, so it cannot be satisfied by
 * anything that never looked at a deployment.
 */
const COMPONENT_FIELDS_BY_KIND = Object.freeze({
  [SOURCE_KINDS.REVIEWED_REVISION]: Object.freeze([
    'sha', 'source_kind', 'repo', 'ancestor_of', 'semantic',
  ]),
  [SOURCE_KINDS.SOURCE_REVISION]: Object.freeze(['sha', 'source_kind', 'repo', 'ref', 'semantic']),
  [SOURCE_KINDS.PRODUCTION_DEPLOYMENT]: Object.freeze([
    'sha', 'source_kind', 'repo', 'environment', 'semantic',
  ]),
});

function checkComponent(name, c, errors) {
  const p = `session2_provenance.${name}`;
  if (c === null || typeof c !== 'object' || Array.isArray(c)) {
    errors.push(`${p}: must be an object`);
    return;
  }
  if (!EXPECTABLE_SOURCE_KINDS.includes(c.source_kind)) {
    // ★ Named explicitly, because `local_checkout` is the one a well-meaning edit would reach for.
    errors.push(
      `${p}.source_kind: must be one of ${EXPECTABLE_SOURCE_KINDS.join('|')} `
      + `(got ${JSON.stringify(c.source_kind)}) — a working-tree HEAD is never provenance`
    );
    return;
  }
  const required = COMPONENT_FIELDS_BY_KIND[c.source_kind];
  for (const key of Object.keys(c)) {
    if (!required.includes(key)) errors.push(`${p}: unknown field: ${key}`);
  }
  for (const key of required) {
    if (!(key in c)) errors.push(`${p}: missing field: ${key}`);
  }
  if (!SHA1_RE.test(String(c.sha))) errors.push(`${p}.sha: must be a full 40-hex commit sha`);
  if (!REPO_RE.test(String(c.repo))) errors.push(`${p}.repo: must be 'owner/name'`);
  if (!SEMANTIC_RE.test(String(c.semantic))) errors.push(`${p}.semantic: must be 8-200 printable ASCII`);
  if (c.source_kind === SOURCE_KINDS.SOURCE_REVISION && !REF_RE.test(String(c.ref))) {
    errors.push(`${p}.ref: must be a full ref such as refs/heads/main`);
  }
  if (c.source_kind === SOURCE_KINDS.REVIEWED_REVISION && !REF_RE.test(String(c.ancestor_of))) {
    errors.push(`${p}.ancestor_of: must be a full ref such as refs/heads/main`);
  }
  if (c.source_kind === SOURCE_KINDS.PRODUCTION_DEPLOYMENT) {
    if (!ENVIRONMENT_RE.test(String(c.environment))) errors.push(`${p}.environment: malformed`);
    else if (c.environment !== 'Production') {
      errors.push(`${p}.environment: a production_deployment expectation must name 'Production'`);
    }
  }
}

const TOP_FIELDS = Object.freeze([
  'schema_version',
  'created_at',
  'operator_ruling',
  'branch_b_checkpoint_sha256',
  'legacy_checkpoint_provenance',
  'legacy_sha_gate_status',
  'superseded_gate_ids',
  'session2_provenance',
  'resume_instrument',
]);

/**
 * Strict decode of the addendum. Same discipline as the checkpoint decoder: a MISSING field fails,
 * and an UNKNOWN field fails. Never partially succeeds, never fills a default.
 */
export function decodeProvenanceAddendum(raw) {
  const errors = [];
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
    return { ok: false, errors: ['addendum must be a JSON object'] };
  }
  for (const key of Object.keys(raw)) {
    if (!TOP_FIELDS.includes(key)) errors.push(`unknown field: ${key}`);
  }
  for (const key of TOP_FIELDS) {
    if (!(key in raw)) errors.push(`missing field: ${key}`);
  }
  if (errors.length) return { ok: false, errors: errors.sort() };

  if (raw.schema_version !== PROVENANCE_SCHEMA_VERSION) {
    errors.push(`schema_version: must be ${PROVENANCE_SCHEMA_VERSION}`);
  }
  if (!isInstant(raw.created_at)) errors.push('created_at: must be an ISO-8601 instant');
  if (raw.operator_ruling !== OPERATOR_RULING_ID) {
    errors.push(`operator_ruling: must be ${OPERATOR_RULING_ID}`);
  }
  if (!SHA256_RE.test(String(raw.branch_b_checkpoint_sha256))) {
    errors.push('branch_b_checkpoint_sha256: must be a 64-hex digest');
  }
  if (raw.legacy_sha_gate_status !== LEGACY_SHA_GATE_STATUS) {
    errors.push(`legacy_sha_gate_status: must be '${LEGACY_SHA_GATE_STATUS}'`);
  }

  const lp = raw.legacy_checkpoint_provenance;
  if (lp === null || typeof lp !== 'object' || Array.isArray(lp)) {
    errors.push('legacy_checkpoint_provenance: must be an object');
  } else {
    const legacyKeys = ['api_sha', 'mobile_sha', 'admin_sha'];
    for (const key of Object.keys(lp)) {
      if (!legacyKeys.includes(key)) errors.push(`legacy_checkpoint_provenance: unknown field: ${key}`);
    }
    for (const key of legacyKeys) {
      if (!(key in lp)) errors.push(`legacy_checkpoint_provenance: missing field: ${key}`);
      else if (!SHA1_RE.test(String(lp[key]))) {
        errors.push(`legacy_checkpoint_provenance.${key}: must be a full 40-hex commit sha`);
      }
    }
  }

  // ★ The superseded list is pinned in the ARTIFACT as well as in code, and the two must agree
  //   exactly and in order. A file that quietly widened the list would otherwise disable a gate.
  if (!Array.isArray(raw.superseded_gate_ids)
      || raw.superseded_gate_ids.length !== SUPERSEDED_LEGACY_GATE_IDS.length
      || raw.superseded_gate_ids.some((id, i) => id !== SUPERSEDED_LEGACY_GATE_IDS[i])) {
    errors.push(
      `superseded_gate_ids: must be exactly ${JSON.stringify(SUPERSEDED_LEGACY_GATE_IDS)}`
    );
  }

  const sp = raw.session2_provenance;
  if (sp === null || typeof sp !== 'object' || Array.isArray(sp)) {
    errors.push('session2_provenance: must be an object');
  } else {
    for (const key of Object.keys(sp)) {
      if (!PROVENANCE_COMPONENTS.includes(key)) errors.push(`session2_provenance: unknown field: ${key}`);
    }
    for (const name of PROVENANCE_COMPONENTS) {
      if (!(name in sp)) errors.push(`session2_provenance: missing field: ${name}`);
      else checkComponent(name, sp[name], errors);
    }
  }

  // ★ PHASE 11-P.5 / STAGE 19 — THE INSTRUMENT REVISION IS A SEPARATE FACT, AND NULLABLE.
  //
  // The source revision Branch B was EVIDENCED at and the source revision the Session-2 RESUME
  // INSTRUMENT runs from are two different things, and overloading one field with both is how the
  // checkpoint's `api_sha` came to mean neither. It is NULL here for an honest reason: the commit
  // that carries this evaluator does not exist while this artifact is being written, and inventing a
  // value would reproduce the exact self-referential defect being remediated. NULL is refused by
  // `resume_instrument_pinned`, so the follow-up pin is mandatory rather than optional.
  if (raw.resume_instrument !== null) {
    checkComponent('resume_instrument', raw.resume_instrument, errors);
  }

  if (errors.length) return { ok: false, errors: errors.sort() };
  return { ok: true, addendum: Object.freeze({ ...raw }) };
}

/** Every gate id `evaluateSession2Resume` can add on top of the legacy set. */
export const SESSION2_GATE_IDS = Object.freeze([
  'addendum_decoded',
  'checkpoint_hash_bound',
  'supersession_targets_exist',
  'provenance_api_branch_b_source',
  'provenance_mobile_branch_b_source',
  'provenance_admin_console_production',
  'resume_instrument_pinned',
]);

export const SESSION2 = Object.freeze({ ALLOWED: 'RESUME', REFUSED: 'REFUSE_RESUME' });

/**
 * Compare ONE observed provenance record against ONE expectation.
 *
 * ★ SOURCE KIND IS CHECKED BEFORE THE SHA, AND A MISMATCH IS FATAL EVEN IF THE SHA AGREES. That
 *   ordering is the whole point: `cd044fe` read from a working tree is not the same fact as
 *   `cd044fe` read from a successful Production deployment, and only the second is provenance.
 */
export function compareProvenance(observed, expected) {
  if (observed === null || typeof observed !== 'object' || Array.isArray(observed)) {
    return { pass: false, code: 'observation_missing', detail: 'no observation supplied' };
  }
  if (!OBSERVABLE_SOURCE_KINDS.includes(observed.source_kind)) {
    return {
      pass: false,
      code: 'observation_source_kind_unknown',
      detail: `source_kind=${JSON.stringify(observed.source_kind)}`,
    };
  }
  if (observed.source_kind !== expected.source_kind) {
    return {
      pass: false,
      code: 'observation_source_kind_wrong',
      detail: `expected ${expected.source_kind}, observed ${observed.source_kind}`,
    };
  }
  if (observed.repo !== expected.repo) {
    return { pass: false, code: 'observation_repo_wrong', detail: `observed repo=${observed.repo}` };
  }
  if (expected.source_kind === SOURCE_KINDS.SOURCE_REVISION && observed.ref !== expected.ref) {
    return { pass: false, code: 'observation_ref_wrong', detail: `observed ref=${observed.ref}` };
  }
  if (expected.source_kind === SOURCE_KINDS.REVIEWED_REVISION) {
    // ★ The lineage claim is checked as its own fact. A commit that exists but has been abandoned —
    //   force-pushed away, or living only on a parked branch — is NOT a reviewed baseline of this
    //   line of development, and `in_lineage` is the only thing that can tell the two apart.
    if (observed.ancestor_of !== expected.ancestor_of) {
      return {
        pass: false,
        code: 'observation_lineage_target_wrong',
        detail: `observed ancestor_of=${observed.ancestor_of}`,
      };
    }
    if (observed.in_lineage !== true) {
      return {
        pass: false,
        code: 'revision_not_in_lineage',
        detail: `in_lineage=${observed.in_lineage} of ${expected.ancestor_of}`,
      };
    }
  }
  if (expected.source_kind === SOURCE_KINDS.PRODUCTION_DEPLOYMENT) {
    // ★ Three independent facts, all required. An unsuccessful deployment to Production and a
    //   successful one to Preview are different mistakes and both must refuse.
    if (observed.environment !== expected.environment) {
      return {
        pass: false,
        code: 'deployment_environment_wrong',
        detail: `observed environment=${observed.environment}`,
      };
    }
    if (observed.state !== 'success') {
      return { pass: false, code: 'deployment_not_successful', detail: `observed state=${observed.state}` };
    }
  }
  if (!SHA1_RE.test(String(observed.sha))) {
    return { pass: false, code: 'observation_sha_malformed', detail: `observed sha=${observed.sha}` };
  }
  if (observed.sha !== expected.sha) {
    return { pass: false, code: 'provenance_sha_changed', detail: `observed sha=${observed.sha}` };
  }
  return { pass: true, code: 'ok', detail: `${observed.source_kind} ${observed.sha}` };
}

/**
 * THE SESSION-2 RESUME GATE.
 *
 * ★ IT DELEGATES TO THE LEGACY EVALUATOR RATHER THAN REIMPLEMENTING IT. Every non-SHA gate keeps its
 *   exact legacy behaviour because it IS the legacy behaviour — there is no second copy to drift.
 *   The only edit is the removal of three gates, BY NAME, and the addition of typed replacements.
 *
 * @param {object}   input
 * @param {Function} input.legacyEvaluateResume  the untouched `evaluateResume`
 * @param {object}   input.checkpoint            a DECODED frozen checkpoint
 * @param {Buffer|Uint8Array|string} input.checkpointBytes  the checkpoint file's RAW bytes
 * @param {object}   input.addendumRaw           the undecoded addendum (decoded here, strictly)
 * @param {object}   input.observed              freshly read production/source state
 * @param {object}   input.observedProvenance    per-component provenance observations
 * @param {Date|string} input.now                INJECTED clock
 */
export function evaluateSession2Resume({
  legacyEvaluateResume,
  checkpoint,
  checkpointBytes,
  addendumRaw,
  observed,
  observedProvenance,
  now,
}) {
  const gates = [];
  const gate = (id, pass, detail) => gates.push({ id, pass: pass === true, detail });

  const decoded = decodeProvenanceAddendum(addendumRaw);
  gate('addendum_decoded', decoded.ok, decoded.ok ? 'strict decode ok' : decoded.errors.join('; '));

  // ★ THE BINDING. Without it the addendum is a free-floating opinion about a file it never read,
  //   and a rewritten checkpoint would sail through Session 2 wearing corrected provenance.
  const observedHash =
    checkpointBytes === undefined || checkpointBytes === null ? null : sha256Bytes(checkpointBytes);
  gate(
    'checkpoint_hash_bound',
    decoded.ok && observedHash !== null && observedHash === decoded.addendum.branch_b_checkpoint_sha256,
    `observed=${observedHash} addendum=${decoded.ok ? decoded.addendum.branch_b_checkpoint_sha256 : 'n/a'}`
  );

  const legacy = legacyEvaluateResume({ checkpoint, observed, now });
  const supersededSet = new Set(SUPERSEDED_LEGACY_GATE_IDS);
  const legacyIds = new Set(legacy.gates.map((g) => g.id));

  // ★ A SUPERSESSION THAT NAMES A GATE THAT DOES NOT EXIST IS A CONTRACT BREAK, NOT A NO-OP. If the
  //   legacy evaluator is refactored and a gate is renamed, this refuses rather than silently
  //   dropping nothing (or, worse, retaining a gate everyone believes was replaced).
  const missingTargets = SUPERSEDED_LEGACY_GATE_IDS.filter((id) => !legacyIds.has(id));
  gate(
    'supersession_targets_exist',
    missingTargets.length === 0,
    missingTargets.length ? `absent from legacy result: ${missingTargets.join(', ')}` : 'all 3 present'
  );

  const retained = legacy.gates.filter((g) => !supersededSet.has(g.id));
  const superseded = legacy.gates.filter((g) => supersededSet.has(g.id));

  const op = observedProvenance ?? {};
  for (const name of PROVENANCE_COMPONENTS) {
    const expected = decoded.ok ? decoded.addendum.session2_provenance[name] : null;
    if (expected === null) {
      gate(`provenance_${name}`, false, 'addendum did not decode — no expectation to compare');
      continue;
    }
    const r = compareProvenance(op[name], expected);
    gate(`provenance_${name}`, r.pass, `${r.code}: ${r.detail}`);
  }

  // ★ STAGE 19. NULL refuses. See the decoder note above for why it is null rather than invented.
  const ri = decoded.ok ? decoded.addendum.resume_instrument : null;
  if (ri === null) {
    gate(
      'resume_instrument_pinned',
      false,
      'resume_instrument is null — pin it to the merged remediation revision before Session 2'
    );
  } else {
    const r = compareProvenance(op.resume_instrument, ri);
    gate('resume_instrument_pinned', r.pass, `${r.code}: ${r.detail}`);
  }

  const all = [...retained, ...gates];
  const failed = all.filter((g) => !g.pass).map((g) => g.id);
  return Object.freeze({
    decision: failed.length === 0 ? SESSION2.ALLOWED : SESSION2.REFUSED,
    gates: Object.freeze(all),
    failed: Object.freeze(failed),
    retained_legacy_gates: Object.freeze(retained.map((g) => g.id)),
    superseded_legacy_gates: Object.freeze(superseded.map((g) => g.id)),
    legacy_decision: legacy.decision,
    two_person_control: legacy.two_person_control,
  });
}
