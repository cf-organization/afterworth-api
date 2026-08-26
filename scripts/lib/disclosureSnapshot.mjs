/**
 * PHASE 11-Q · THE CANONICAL DISCLOSURE SNAPSHOT — schema, strict decoder, and the paired verifier.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ WHY THIS EXISTS: THE ORACLE WAS CORRECT AND UNRUNNABLE.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * `evaluateDisclosureEquivalence` has held the real rule since Phase 11-OB PREP — release reveals
 * EXACTLY the sanctioned payload and nothing else moves in either direction — but it is a pure
 * function with no collector, and its `pre` and `ownerPre` arguments are observations that exist
 * only while the lifecycle is `challenge_window`.
 *
 * Branch B crossed the irreversible boundary having captured TWO of its four documents, through a
 * sentinel that was never meant to be a disclosure verifier. The estate is now `released`. The
 * pre-image cannot be taken, cannot be reconstructed, and must never be invented — so Branch B's
 * disclosure gap is permanent, and `docs/phase11p11-*` records it as such.
 *
 * ★ THIS MODULE'S JOB IS TO MAKE THAT UNREPEATABLE, AND THE MECHANISM IS REFUSAL, NOT DILIGENCE.
 *   A future drill either has a complete, phase-tagged, digest-bound pre-image or it gets no
 *   canonical verdict at all. `REFUSE_INCOMPLETE_PRE` is a first-class outcome, distinct from FAIL,
 *   because "the release was wrong" and "we cannot say whether the release was wrong" are different
 *   facts that need different responses.
 *
 * ★ THE ORACLE'S SEMANTICS ARE REUSED UNCHANGED. This module collects, validates and adapts; it does
 *   NOT re-implement the rule. A second copy of a disclosure policy is the drift this repository has
 *   already shipped twice. Everything below either feeds `evaluateDisclosureEquivalence` or checks a
 *   property the oracle deliberately does not cover.
 *
 * PURE. No clock, no network, no filesystem. The CLI collects; this decides.
 */
import { canonicalDigest } from './canonicalJson.mjs';
import { evaluateDisclosureEquivalence, ORACLE } from './disclosureOracle.mjs';

export const SNAPSHOT_SCHEMA_VERSION = 1;

/**
 * ★ THE PHASE IS A FIELD, NOT A FILENAME. A snapshot that only knew which phase it was by where it
 *   was saved could be renamed into the other role — which is exactly the reconstruction this whole
 *   module exists to forbid. It is carried in the payload, covered by the digest, and checked.
 */
export const SNAPSHOT_PHASE = Object.freeze({
  PRE_RELEASE: 'PRE_RELEASE',
  POST_RELEASE: 'POST_RELEASE',
});

/** Sensitivity vocabulary, mirroring the server catalog values this rule cares about. */
export const VISIBILITY = Object.freeze({
  LOW: 'low',
  MEDIUM: 'medium',
  SEALED: 'sealed',
});

export const EQUIVALENCE = Object.freeze({
  PASS: 'DISCLOSURE_EQUIVALENCE_HELD',
  FAIL: 'DISCLOSURE_EQUIVALENCE_VIOLATED',
  REFUSE_INCOMPLETE_PRE: 'REFUSE_INCOMPLETE_PRE',
  REFUSE_IDENTITY_MISMATCH: 'REFUSE_IDENTITY_MISMATCH',
  REFUSE_WRONG_LIFECYCLE: 'REFUSE_WRONG_LIFECYCLE',
  REFUSE_PROVENANCE_FAILURE: 'REFUSE_PROVENANCE_FAILURE',
});

/** The lifecycle each phase is the ONLY legitimate observation window for. */
export const PHASE_LIFECYCLE = Object.freeze({
  [SNAPSHOT_PHASE.PRE_RELEASE]: 'challenge_window',
  [SNAPSHOT_PHASE.POST_RELEASE]: 'released',
});

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const SHA256_RE = /^[0-9a-f]{64}$/;
const isInstant = (v) => typeof v === 'string' && /^\d{4}-\d{2}-\d{2}T/.test(v) && !Number.isNaN(Date.parse(v));
const isIdList = (v) => Array.isArray(v) && v.length > 0 && v.every((x) => UUID_RE.test(String(x)));

const TOP_FIELDS = Object.freeze([
  'schema_version', 'phase', 'estate_id', 'case_id', 'lifecycle', 'observed_at_utc',
  'actor_uid', 'actor_role', 'owner_uid', 'sanctioned_document_ids', 'expected_universe_ids',
  'documents', 'owner_documents', 'grant', 'provenance',
]);

const DOC_FIELDS = Object.freeze(['document_id', 'sensitivity', 'can_access_document', 'rls_visible']);

function checkDocs(list, label, errors) {
  if (!Array.isArray(list) || list.length === 0) {
    errors.push(`${label}: must be a non-empty array`);
    return;
  }
  const seen = new Set();
  for (const d of list) {
    if (d === null || typeof d !== 'object' || Array.isArray(d)) {
      errors.push(`${label}: each entry must be an object`);
      continue;
    }
    for (const k of Object.keys(d)) {
      if (!DOC_FIELDS.includes(k)) errors.push(`${label}: unknown field: ${k}`);
    }
    for (const k of DOC_FIELDS) {
      if (!(k in d)) errors.push(`${label}: missing field: ${k}`);
    }
    if (!UUID_RE.test(String(d.document_id))) errors.push(`${label}.document_id: must be a lowercase uuid`);
    if (!Object.values(VISIBILITY).includes(d.sensitivity)) {
      errors.push(`${label}.sensitivity: must be one of ${Object.values(VISIBILITY).join('|')} (got ${JSON.stringify(d.sensitivity)})`);
    }
    // ★ BOOLEAN, STRICTLY. A string "false" is truthy, and an unknown classification must never be
    //   coerced into a visibility answer — that is how a leak becomes a pass.
    if (typeof d.can_access_document !== 'boolean') {
      errors.push(`${label}.can_access_document: must be a boolean (got ${JSON.stringify(d.can_access_document)})`);
    }
    if (typeof d.rls_visible !== 'boolean') {
      errors.push(`${label}.rls_visible: must be a boolean (got ${JSON.stringify(d.rls_visible)})`);
    }
    // ★ A DUPLICATE ID IS REFUSED, because a doubled row can silently stand in for a missing one and
    //   make an incomplete universe look complete by count.
    if (seen.has(String(d.document_id))) errors.push(`${label}: duplicate document_id: ${d.document_id}`);
    seen.add(String(d.document_id));
  }
}

/** Strict decode. A MISSING field fails and an UNKNOWN field fails. Never partially succeeds. */
export function decodeSnapshot(raw) {
  const errors = [];
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
    return { ok: false, errors: ['snapshot must be a JSON object'] };
  }
  for (const k of Object.keys(raw)) {
    if (!TOP_FIELDS.includes(k)) errors.push(`unknown field: ${k}`);
  }
  for (const k of TOP_FIELDS) {
    if (!(k in raw)) errors.push(`missing field: ${k}`);
  }
  if (errors.length) return { ok: false, errors: errors.sort() };

  if (raw.schema_version !== SNAPSHOT_SCHEMA_VERSION) {
    errors.push(`schema_version: must be ${SNAPSHOT_SCHEMA_VERSION}`);
  }
  if (!Object.values(SNAPSHOT_PHASE).includes(raw.phase)) {
    errors.push(`phase: must be one of ${Object.values(SNAPSHOT_PHASE).join('|')}`);
  }
  for (const k of ['estate_id', 'case_id', 'actor_uid', 'owner_uid']) {
    if (!UUID_RE.test(String(raw[k]))) errors.push(`${k}: must be a lowercase uuid`);
  }
  if (typeof raw.lifecycle !== 'string' || raw.lifecycle === '') errors.push('lifecycle: must be a non-empty string');
  if (!isInstant(raw.observed_at_utc)) errors.push('observed_at_utc: must be an ISO-8601 instant');
  if (typeof raw.actor_role !== 'string' || raw.actor_role === '') errors.push('actor_role: must be a non-empty string');
  if (typeof raw.provenance !== 'string' || raw.provenance === '') errors.push('provenance: must be a non-empty string');
  if (!isIdList(raw.sanctioned_document_ids)) errors.push('sanctioned_document_ids: must be a non-empty uuid array');
  if (!isIdList(raw.expected_universe_ids)) errors.push('expected_universe_ids: must be a non-empty uuid array');

  checkDocs(raw.documents, 'documents', errors);
  checkDocs(raw.owner_documents, 'owner_documents', errors);

  if (raw.grant === null || typeof raw.grant !== 'object' || Array.isArray(raw.grant)) {
    errors.push('grant: must be an object');
  }

  // ★ THE PHASE AND THE LIFECYCLE MUST AGREE INSIDE THE ARTIFACT ITSELF. A `PRE_RELEASE` snapshot
  //   stamped `released` is the reconstruction hazard in its purest form, and it is refused at
  //   decode rather than later, so such a file cannot exist as valid evidence at all.
  const expectedLifecycle = PHASE_LIFECYCLE[raw.phase];
  if (expectedLifecycle !== undefined && raw.lifecycle !== expectedLifecycle) {
    errors.push(`lifecycle: a ${raw.phase} snapshot must be observed at '${expectedLifecycle}', got '${raw.lifecycle}'`);
  }

  if (errors.length) return { ok: false, errors: errors.sort() };
  return { ok: true, snapshot: Object.freeze({ ...raw }) };
}

/** Canonical SHA-256 over the snapshot, key-order independent. */
export function snapshotDigest(snapshot) {
  return canonicalDigest(snapshot);
}

const visibleIds = (docs) => docs.filter((d) => d.can_access_document === true || d.rls_visible === true).map((d) => d.document_id);

/**
 * THE PAIRED VERIFIER.
 *
 * ★ IT REFUSES BEFORE IT EVALUATES. Identity, phase, lifecycle, completeness and provenance are
 *   settled first, and each produces its OWN refusal code — because "I cannot verify this" and
 *   "this release was wrong" must never share a verdict. Only once the inputs are known-good does
 *   the canonical oracle run, unchanged.
 *
 * @param {object}      input
 * @param {object|null} input.pre                 a decoded-or-raw PRE_RELEASE snapshot
 * @param {object|null} input.post                a decoded-or-raw POST_RELEASE snapshot
 * @param {string|null} [input.expectedPreDigest] pin the pre-image's digest if one was recorded
 */
export function verifyDisclosureEquivalence({ pre, post, expectedPreDigest = null }) {
  const findings = [];
  const refuse = (verdict, code, detail) =>
    Object.freeze({ verdict, findings: Object.freeze([{ code, detail }]), oracle: null });

  /* ── 1 · THE PRE-IMAGE MUST EXIST AND DECODE. NO FALLBACK, EVER. ────────────────────────────── */
  if (pre === null || pre === undefined) {
    return refuse(
      EQUIVALENCE.REFUSE_INCOMPLETE_PRE,
      'pre_snapshot_absent',
      'no pre-release disclosure snapshot was supplied — it cannot be reconstructed from the post state'
    );
  }
  // ★ THE TWO REFUSALS ARE NAMED APART, AND THIS ORDERING IS WHY. A `PRE_RELEASE` snapshot stamped
  //   `released` is refused by the decoder's phase/lifecycle invariant — but reporting that as
  //   `pre_snapshot_malformed` under REFUSE_INCOMPLETE_PRE would tell an operator to go and collect
  //   more documents, when the actual problem is that the capture happened after the boundary and no
  //   amount of collecting can fix it. "Your pre-image is short" and "your pre-image is not a
  //   pre-image" need opposite responses, so they get opposite codes.
  const declaredPhaseLifecycle = PHASE_LIFECYCLE[pre?.phase];
  if (declaredPhaseLifecycle !== undefined && typeof pre?.lifecycle === 'string'
      && pre.lifecycle !== declaredPhaseLifecycle) {
    return refuse(
      EQUIVALENCE.REFUSE_WRONG_LIFECYCLE,
      'pre_snapshot_observed_outside_its_window',
      `a ${pre.phase} snapshot must be observed at '${declaredPhaseLifecycle}', got '${pre.lifecycle}'`
    );
  }
  const preD = decodeSnapshot(pre);
  if (!preD.ok) {
    return refuse(EQUIVALENCE.REFUSE_INCOMPLETE_PRE, 'pre_snapshot_malformed', preD.errors.join('; '));
  }
  if (post === null || post === undefined) {
    return refuse(EQUIVALENCE.REFUSE_INCOMPLETE_PRE, 'post_snapshot_absent', 'no post-release snapshot supplied');
  }
  const postD = decodeSnapshot(post);
  if (!postD.ok) {
    return refuse(EQUIVALENCE.REFUSE_WRONG_LIFECYCLE, 'post_snapshot_malformed', postD.errors.join('; '));
  }
  const P = preD.snapshot;
  const Q = postD.snapshot;

  /* ── 2 · PHASE AND LIFECYCLE ────────────────────────────────────────────────────────────────── */
  if (P.phase !== SNAPSHOT_PHASE.PRE_RELEASE) {
    return refuse(EQUIVALENCE.REFUSE_WRONG_LIFECYCLE, 'pre_snapshot_wrong_phase', `pre is ${P.phase}`);
  }
  if (Q.phase !== SNAPSHOT_PHASE.POST_RELEASE) {
    return refuse(EQUIVALENCE.REFUSE_WRONG_LIFECYCLE, 'post_snapshot_wrong_phase', `post is ${Q.phase}`);
  }

  /* ── 3 · PROVENANCE ─────────────────────────────────────────────────────────────────────────── */
  if (expectedPreDigest !== null) {
    if (!SHA256_RE.test(String(expectedPreDigest))) {
      return refuse(EQUIVALENCE.REFUSE_PROVENANCE_FAILURE, 'expected_pre_digest_malformed', String(expectedPreDigest));
    }
    const actual = snapshotDigest(P);
    if (actual !== expectedPreDigest) {
      return refuse(EQUIVALENCE.REFUSE_PROVENANCE_FAILURE, 'pre_snapshot_digest_mismatch', `${actual} != ${expectedPreDigest}`);
    }
  }

  /* ── 4 · THE TWO HALVES MUST DESCRIBE THE SAME DRILL AND THE SAME VIEWER ────────────────────── */
  for (const k of ['estate_id', 'case_id', 'actor_uid', 'owner_uid']) {
    if (P[k] !== Q[k]) {
      return refuse(EQUIVALENCE.REFUSE_IDENTITY_MISMATCH, `${k}_mismatch`, `pre=${P[k]} post=${Q[k]}`);
    }
  }
  if (canonicalDigest(P.sanctioned_document_ids.slice().sort()) !== canonicalDigest(Q.sanctioned_document_ids.slice().sort())) {
    return refuse(EQUIVALENCE.REFUSE_IDENTITY_MISMATCH, 'sanctioned_set_mismatch', 'the two halves sanction different payloads');
  }
  if (canonicalDigest(P.expected_universe_ids.slice().sort()) !== canonicalDigest(Q.expected_universe_ids.slice().sort())) {
    return refuse(EQUIVALENCE.REFUSE_IDENTITY_MISMATCH, 'universe_declaration_mismatch', 'the two halves declare different universes');
  }

  /* ── 5 · COMPLETENESS, PROVED PER SNAPSHOT ──────────────────────────────────────────────────── */
  // ★ THE HISTORICAL BRANCH B FAILURE MODE LIVES HERE. Two of four documents were observed, and
  //   nothing said so. A subset must never be silently evaluable.
  const declared = new Set(P.expected_universe_ids.map(String));
  for (const [label, snap] of [['pre', P], ['post', Q]]) {
    const observed = new Set(snap.documents.map((d) => String(d.document_id)));
    const missing = [...declared].filter((id) => !observed.has(id));
    const unexpected = [...observed].filter((id) => !declared.has(id));
    if (missing.length > 0) {
      return refuse(
        EQUIVALENCE.REFUSE_INCOMPLETE_PRE,
        `${label}_universe_incomplete`,
        `${missing.length} declared document(s) never observed: ${missing.sort().join(',')}`
      );
    }
    if (unexpected.length > 0) {
      return refuse(
        EQUIVALENCE.REFUSE_INCOMPLETE_PRE,
        `${label}_universe_unexpected_documents`,
        `observed but not declared: ${unexpected.sort().join(',')}`
      );
    }
  }
  const ownerObserved = new Set(P.owner_documents.map((d) => String(d.document_id)));
  if ([...declared].some((id) => !ownerObserved.has(id))) {
    return refuse(EQUIVALENCE.REFUSE_INCOMPLETE_PRE, 'pre_owner_universe_incomplete', 'the owner control does not cover the declared universe');
  }

  /* ── 6 · THE TWO ACCESS SIGNALS MUST AGREE ──────────────────────────────────────────────────── */
  // ★ NEVER RESOLVED IN FAVOUR OF THE NICER ANSWER. `can_access_document` is the policy gate and the
  //   RLS-filtered read is the product path; they answer the same question by different mechanisms.
  //   A disagreement means one of them is wrong, and which one is unknown — so it fails.
  for (const [label, snap] of [['pre', P], ['post', Q]]) {
    for (const d of snap.documents) {
      if (d.can_access_document !== d.rls_visible) {
        findings.push({
          code: 'access_signals_disagree',
          detail: `${label} ${d.document_id}: can_access=${d.can_access_document} rls_visible=${d.rls_visible}`,
        });
      }
    }
  }

  /* ── 7 · THE SEALED INVARIANT — LIFECYCLE-INDEPENDENT, AND NOT THE ORACLE'S JOB ─────────────── */
  // ★ The oracle reasons about SETS: it would catch a sealed document that CHANGED visibility. It
  //   would not object to one that was visible in BOTH phases, because nothing moved. `sealed` is
  //   never grantable under any role at any lifecycle, so that case is caught here by sensitivity.
  for (const [label, snap] of [['pre', P], ['post', Q]]) {
    for (const d of snap.documents) {
      if (d.sensitivity === VISIBILITY.SEALED && (d.can_access_document === true || d.rls_visible === true)) {
        findings.push({
          code: 'sealed_document_disclosed',
          detail: `${label} ${d.document_id}: sealed is never grantable under any role, at any lifecycle`,
        });
      }
    }
  }

  /* ── 8 · THE CANONICAL ORACLE, UNCHANGED ────────────────────────────────────────────────────── */
  const oracle = evaluateDisclosureEquivalence({
    sanctionedIds: P.sanctioned_document_ids,
    universeIds: P.expected_universe_ids,
    pre: { visibleIds: visibleIds(P.documents), grant: P.grant },
    post: { visibleIds: visibleIds(Q.documents), grant: Q.grant },
    ownerPre: { visibleIds: visibleIds(P.owner_documents) },
  });
  for (const f of oracle.findings) findings.push(f);

  // ★ The oracle's own UNVERIFIABLE is preserved as a refusal, never downgraded into a FAIL and
  //   never rounded up into a PASS: it means the FIXTURE could not discriminate, which is a
  //   different problem from a bad release.
  if (oracle.verdict === ORACLE.UNVERIFIABLE) {
    return Object.freeze({
      verdict: EQUIVALENCE.REFUSE_INCOMPLETE_PRE,
      findings: Object.freeze(findings),
      oracle: Object.freeze({ verdict: oracle.verdict, discriminating_world: oracle.discriminating_world }),
    });
  }

  return Object.freeze({
    verdict: findings.length === 0 ? EQUIVALENCE.PASS : EQUIVALENCE.FAIL,
    findings: Object.freeze(findings),
    oracle: Object.freeze({
      verdict: oracle.verdict,
      discriminating_world: oracle.discriminating_world,
      grant_fingerprint: oracle.grant_fingerprint,
      unrelated_hidden_digest: oracle.unrelated_hidden_digest,
    }),
  });
}

/** 0 = equivalence held · 1 = violated · 2 = refused / could not verify. Never a bare pass. */
export function equivalenceExitCode(verdict) {
  if (verdict === EQUIVALENCE.PASS) return 0;
  if (verdict === EQUIVALENCE.FAIL) return 1;
  return 2;
}
