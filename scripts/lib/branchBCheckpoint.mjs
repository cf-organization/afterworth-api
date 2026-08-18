/**
 * PHASE 11-OB PREP · THE BRANCH B CHECKPOINT — schema, strict decoder, and the resume gate.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ WHY A SEVEN-DAY DRILL NEEDS A CHECKPOINT AT ALL.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * Branch B opens a challenge window and then waits seven days. The session that opens it will not be
 * the session that closes it. Everything the closing session needs to know — which estate, which
 * case, who reviewed, when the door opens — has to survive that gap in a form that cannot be
 * misremembered, and the closing session has to be able to prove that the world still matches.
 *
 * ★ SO THE CHECKPOINT IS EVIDENCE, NOT CONFIGURATION. It is never edited to make a resume succeed.
 * `evaluateResume` compares it against freshly OBSERVED production state and refuses on any
 * mismatch; there is no repair path, no override flag, and no "force" argument, because the whole
 * value of the artifact is that it can contradict you.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ THE DECODER IS STRICT IN BOTH DIRECTIONS, AND THAT IS TWO SEPARATE PROPERTIES.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 *   · A MISSING required field fails. Obvious, and the easy half.
 *   · An UNKNOWN field fails. Less obvious and more important: a checkpoint written by a newer
 *     harness, or hand-edited with a plausible-looking extra key, would otherwise decode cleanly
 *     while carrying a fact nothing reads. A seven-day drill has exactly one opportunity to notice.
 *
 * ★ NO SECRETS, ENFORCED BY SHAPE. Every field is a uuid, a hex digest, an ISO instant, a small
 * integer, a persona PREFIX, or a closed-vocabulary string. There is no field an address, token or
 * password could be stored in, and `branchBCheckpoint.test.ts` scans a fully-populated instance for
 * address-shaped and secret-shaped strings.
 */

export const CHECKPOINT_VERSION = 1;

/** The window the release door measures against. `authorize_release` reads it live; this records it. */
export const SEVEN_DAYS_SECONDS = 7 * 24 * 60 * 60;

/**
 * Harness scheduling margin only.
 *
 * ★ IT DOES NOT CHANGE THE POLICY, AND MUST NOT BE CONFUSED WITH IT. Since Phase 11-OC / Phase D
 * the production door is `now() > notice_accepted_at + challenge_window_duration()`, strictly, via
 * `owner_notice_release_authority`. This constant exists so the resuming SESSION does not wake up at
 * the exact boundary instant, race the door, and read a correct refusal as a defect.
 */
export const RESUME_SAFETY_MARGIN_SECONDS = 5 * 60;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const SHA1_RE = /^[0-9a-f]{40}$/;
const SHA256_RE = /^[0-9a-f]{64}$/;
const PREFIX_RE = /^AW_[A-Z0-9_]+$/;
const DESIGNATOR_RE = /^[A-Z][A-Z0-9_-]{2,63}$/;
const SENTINEL_RE = /^(\d{1,4})\/(\d{1,4})$/;

const isInstant = (v) => typeof v === 'string' && !Number.isNaN(Date.parse(v)) && /^\d{4}-\d{2}-\d{2}T/.test(v);
const at = (v) => Date.parse(v);

/**
 * The Branch B stage markers.
 *
 * Each is `null` (not reached) or the ISO instant it completed. They are ordered and gapless —
 * a checkpoint claiming B2 without B1 describes a drill that did not happen.
 */
export const STAGE_MARKERS = Object.freeze({
  B0: 'baseline captured — identities and disposable estate provisioned, immutable baseline hashed',
  B1: 'death verification case initiated and VERIFIED by reviewer A',
  B2: 'owner notified and the challenge window opened',
  B3: 'release authorized by reviewer B — Branch B complete',
});

/** field → validator. The key set IS the schema; anything outside it is rejected. */
const FIELDS = Object.freeze({
  checkpoint_version: (v) => (v === CHECKPOINT_VERSION ? null : `must be ${CHECKPOINT_VERSION}`),

  estate_uuid: (v) => (UUID_RE.test(String(v)) ? null : 'must be a lowercase uuid'),
  estate_designator: (v) => (DESIGNATOR_RE.test(String(v)) ? null : 'must be an uppercase designator'),
  case_uuid: (v) => (UUID_RE.test(String(v)) ? null : 'must be a lowercase uuid'),

  owner_uid: (v) => (UUID_RE.test(String(v)) ? null : 'must be a lowercase uuid'),
  fiduciary_uid: (v) => (UUID_RE.test(String(v)) ? null : 'must be a lowercase uuid'),

  reviewer_a_uid: (v) => (UUID_RE.test(String(v)) ? null : 'must be a lowercase uuid'),
  reviewer_b_uid: (v) => (UUID_RE.test(String(v)) ? null : 'must be a lowercase uuid'),

  verification_admin: (v) => (PREFIX_RE.test(String(v)) ? null : 'must be a persona PREFIX, never a value'),
  required_release_admin: (v) => (PREFIX_RE.test(String(v)) ? null : 'must be a persona PREFIX, never a value'),

  lifecycle: (v) => (v === 'challenge_window' ? null : "a resumable checkpoint is written at 'challenge_window'"),
  case_status: (v) => (v === 'verified' ? null : "a resumable checkpoint is written at 'verified'"),

  // ★ PROVENANCE, AND SINCE PHASE D NOT THE CLOCK. `owner_notified_at` is stamped when the outbox
  // row is QUEUED, before any worker has run. It stays in the checkpoint because an investigator
  // reconstructing the drill needs it; it decides nothing.
  owner_notified_at: (v) => (isInstant(v) ? null : 'must be an ISO-8601 instant'),
  challenge_window_started_at: (v) => (isInstant(v) ? null : 'must be an ISO-8601 instant'),
  challenge_window_duration_seconds: (v) =>
    Number.isInteger(v) && v > 0 ? null : 'must be a positive integer',

  // ★ PHASE 11-OC / PHASE D — THE FACT THE RELEASE CLOCK ACTUALLY RUNS FROM.
  //
  // NULLABLE, and permanently so. NULL is the honest record that the email provider has not accepted
  // the notice, which is a REACHABLE state of a live drill: the initial dispatch is queued and the
  // drain is asynchronous, so a checkpoint written moments after the window opens legitimately has
  // no acceptance yet. A non-nullable field would have forced the writer to invent one, and every
  // value it invented would be a fabricated provider acceptance on a safety notice.
  notice_accepted_at: (v) => (v === null || isInstant(v) ? null : 'must be null or an ISO-8601 instant'),

  // ★ AND SO THIS IS NULLABLE TOO, PAIRED WITH IT. With no acceptance fact there is no instant to
  // anchor on, so there is no eligibility date — NOT a date derived from provenance. The pairing is
  // enforced as an invariant below rather than left to the writer.
  release_eligible_at: (v) => (v === null || isInstant(v) ? null : 'must be null or an ISO-8601 instant'),
  recommended_resume_after: (v) => (v === null || isInstant(v) ? null : 'must be null or an ISO-8601 instant'),

  owner_outbox_id: (v) => (UUID_RE.test(String(v)) ? null : 'must be a lowercase uuid'),
  owner_notification_id: (v) => (UUID_RE.test(String(v)) ? null : 'must be a lowercase uuid'),

  B0: (v) => (v === null || isInstant(v) ? null : 'must be null or an ISO-8601 instant'),
  B1: (v) => (v === null || isInstant(v) ? null : 'must be null or an ISO-8601 instant'),
  B2: (v) => (v === null || isInstant(v) ? null : 'must be null or an ISO-8601 instant'),
  B3: (v) => (v === null || isInstant(v) ? null : 'must be null or an ISO-8601 instant'),

  death_conditioned_grant_id: (v) => (UUID_RE.test(String(v)) ? null : 'must be a lowercase uuid'),
  pre_release_payload_sha256: (v) => (SHA256_RE.test(String(v)) ? null : 'must be a 64-hex digest'),

  release_authorizations_count: (v) =>
    Number.isInteger(v) && v >= 0 ? null : 'must be a non-negative integer',

  standing_fixture_sentinel: (v) => (SENTINEL_RE.test(String(v)) ? null : "must read '<passed>/<total>'"),

  // Full 40-hex only. An abbreviated SHA is ambiguous, and a drill that cannot say exactly which
  // code it ran against cannot be reproduced.
  api_sha: (v) => (SHA1_RE.test(String(v)) ? null : 'must be a full 40-hex commit sha'),
  mobile_sha: (v) => (SHA1_RE.test(String(v)) ? null : 'must be a full 40-hex commit sha'),
  admin_sha: (v) => (SHA1_RE.test(String(v)) ? null : 'must be a full 40-hex commit sha'),
});

export const CHECKPOINT_FIELDS = Object.freeze(Object.keys(FIELDS));

/**
 * Cross-field invariants. Each returns an error string or null. These are the facts that make the
 * checkpoint internally coherent; a value can be individually well-formed and still describe an
 * impossible drill.
 */
const INVARIANTS = Object.freeze([
  // ★ PHASE 11-OC / PHASE D — THE ANCHOR IS THE ACCEPTANCE FACT, AND THERE IS NO FALLBACK.
  //
  // This invariant read `owner_notified_at + duration` until Phase D re-anchored the production
  // door. Leaving it would have made the harness compute a resume time from an instant the door no
  // longer recognises — stamped when the row was QUEUED, potentially days early — and wake a drill
  // at a door it knows is shut, which then reads as a product defect rather than a harness one.
  //
  // A `coalesce(notice_accepted_at, owner_notified_at)` here would be the same defect wearing
  // defensive-null-handling as a disguise, and would silently restore the old clock for exactly the
  // population that has no acceptance. There is no fallback, by construction: the two fields are
  // paired, and NULL propagates.
  (c) => {
    if (c.notice_accepted_at === null) {
      return c.release_eligible_at === null
        ? null
        : 'release_eligible_at must be null when notice_accepted_at is null — with no acceptance '
          + 'fact there is no instant to anchor on, and a date here could only have come from '
          + 'provenance';
    }
    if (c.release_eligible_at === null) {
      return 'release_eligible_at must be set once notice_accepted_at is';
    }
    return at(c.release_eligible_at)
      === at(c.notice_accepted_at) + c.challenge_window_duration_seconds * 1000
      ? null
      : 'release_eligible_at must equal notice_accepted_at + challenge_window_duration_seconds';
  },
  // ★ AND IT MUST NOT ACCIDENTALLY EQUAL THE PROVENANCE ANCHOR. A checkpoint whose acceptance and
  // dispatch instants coincide cannot distinguish the two formulas, so it is refused as EVIDENCE:
  // a resumable checkpoint that could have been produced by either rule proves nothing about which
  // one the harness used. This is the transformation-test rule applied to the artifact itself.
  (c) =>
    c.notice_accepted_at === null || at(c.notice_accepted_at) !== at(c.owner_notified_at)
      ? null
      : 'notice_accepted_at must differ from owner_notified_at — a checkpoint where they coincide '
        + 'cannot distinguish the Phase D clock from the superseded one',
  (c) => {
    // ★ Harness margin, checked as `>=` deliberately: the SESSION may wake later than the minimum,
    //   never earlier. The production door's strictness is a separate rule, tested separately.
    if (c.release_eligible_at === null) {
      return c.recommended_resume_after === null
        ? null
        : 'recommended_resume_after must be null when there is no eligibility instant to follow';
    }
    if (c.recommended_resume_after === null) {
      return 'recommended_resume_after must be set once release_eligible_at is';
    }
    return at(c.recommended_resume_after)
      >= at(c.release_eligible_at) + RESUME_SAFETY_MARGIN_SECONDS * 1000
      ? null
      : `recommended_resume_after must be at least ${RESUME_SAFETY_MARGIN_SECONDS}s after release_eligible_at`;
  },
  (c) =>
    c.reviewer_a_uid !== c.reviewer_b_uid
      ? null
      : 'reviewer_a_uid and reviewer_b_uid must be distinct — a single-reviewer release is unwritable',
  (c) =>
    c.verification_admin !== c.required_release_admin
      ? null
      : 'verification_admin and required_release_admin must be distinct personas',
  (c) =>
    c.owner_uid !== c.fiduciary_uid ? null : 'owner_uid and fiduciary_uid must be distinct',
  (c) =>
    at(c.challenge_window_started_at) >= at(c.owner_notified_at)
      ? null
      : 'challenge_window_started_at cannot precede owner_notified_at',
  (c) => {
    // Ordered and gapless. A claimed B2 with no B1 is a drill that skipped verification.
    const seq = [c.B0, c.B1, c.B2, c.B3];
    let seenNull = false;
    for (let i = 0; i < seq.length; i += 1) {
      if (seq[i] === null) seenNull = true;
      else if (seenNull) return `B${i} is set while an earlier stage marker is null`;
    }
    for (let i = 1; i < seq.length; i += 1) {
      if (seq[i] !== null && seq[i - 1] !== null && at(seq[i]) < at(seq[i - 1])) {
        return `B${i} precedes B${i - 1}`;
      }
    }
    return null;
  },
  (c) =>
    // A checkpoint written for RESUME describes a window that is open and unreleased.
    c.B3 === null ? null : 'B3 is set — this drill is already complete and must not be resumed',
  (c) =>
    c.release_authorizations_count === 0
      ? null
      : 'release_authorizations_count must be 0 in a resumable checkpoint',
]);

/**
 * Strict decode. Returns `{ ok: true, checkpoint }` or `{ ok: false, errors }`.
 * NEVER partially succeeds, never fills a default, never drops an unknown key.
 */
export function decodeCheckpoint(raw) {
  const errors = [];
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
    return { ok: false, errors: ['checkpoint must be a JSON object'] };
  }

  for (const key of Object.keys(raw)) {
    if (!(key in FIELDS)) errors.push(`unknown field: ${key}`);
  }
  for (const [key, check] of Object.entries(FIELDS)) {
    if (!(key in raw)) {
      errors.push(`missing field: ${key}`);
      continue;
    }
    const problem = check(raw[key]);
    if (problem) errors.push(`${key}: ${problem}`);
  }
  if (errors.length) return { ok: false, errors: errors.sort() };

  for (const invariant of INVARIANTS) {
    const problem = invariant(raw);
    if (problem) errors.push(problem);
  }
  if (errors.length) return { ok: false, errors: errors.sort() };

  return { ok: true, checkpoint: Object.freeze({ ...raw }) };
}

/**
 * Derive the two scheduling instants from the ACCEPTANCE fact. Pure; the caller supplies everything.
 *
 * ★ PHASE 11-OC / PHASE D — THE PARAMETER CHANGED, AND THE SIGNATURE IS THE SAFETY PROPERTY.
 * It took `ownerNotifiedAt`. It now takes `noticeAcceptedAt`, and there is deliberately NO second
 * parameter to fall back to: a function that cannot see the provenance instant cannot be talked into
 * anchoring on it. Passing `null` — the honest state of an unaccepted notice — returns `null` rather
 * than a computed date, so a caller cannot obtain an eligibility instant it has no basis for.
 */
export function deriveWindowInstants(noticeAcceptedAt, durationSeconds) {
  if (noticeAcceptedAt === null) return null;
  if (!isInstant(noticeAcceptedAt) || !Number.isInteger(durationSeconds) || durationSeconds <= 0) return null;
  const eligible = new Date(at(noticeAcceptedAt) + durationSeconds * 1000);
  return Object.freeze({
    release_eligible_at: eligible.toISOString(),
    recommended_resume_after: new Date(
      eligible.getTime() + RESUME_SAFETY_MARGIN_SECONDS * 1000
    ).toISOString(),
  });
}

/* ════════════════════════════════════════════════════════════════════════════════════════════════
 * THE RESUME GATE
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * ★ EVERY GATE IS EVALUATED, ALWAYS — no short-circuit. A resume that fails four gates and reports
 * one tells the operator to fix one thing and try again, four times.
 *
 * ★ AN UNOBSERVED FACT IS A FAILED GATE, NOT A SKIPPED ONE. `observed` fields default to `undefined`
 * and every predicate below treats `undefined` as false. The Phase 6 lesson: an empty blocker column
 * is not clearance.
 */

export const RESUME = Object.freeze({ ALLOWED: 'RESUME', REFUSED: 'REFUSE_RESUME' });

/**
 * @param {object} input
 * @param {object} input.checkpoint  a DECODED checkpoint
 * @param {object} input.observed    freshly read production state
 * @param {Date|string} input.now    INJECTED clock
 */
export function evaluateResume({ checkpoint, observed, now }) {
  const o = observed ?? {};
  const nowMs = typeof now === 'string' ? Date.parse(now) : now instanceof Date ? now.getTime() : NaN;
  const gates = [];
  const gate = (id, pass, detail) => gates.push({ id, pass: pass === true, detail });

  gate('clock_supplied', Number.isFinite(nowMs), String(now));

  gate('estate_matches', o.estate_uuid === checkpoint.estate_uuid, `observed=${o.estate_uuid}`);
  gate('case_matches', o.case_uuid === checkpoint.case_uuid, `observed=${o.case_uuid}`);

  gate('lifecycle_is_challenge_window', o.lifecycle === 'challenge_window', `observed=${o.lifecycle}`);
  gate('case_status_is_verified', o.case_status === 'verified', `observed=${o.case_status}`);
  gate('not_released', o.released_at === null, `released_at=${o.released_at}`);
  gate(
    'no_release_authorization_exists',
    o.release_authorizations_count === 0,
    `count=${o.release_authorizations_count}`
  );

  // ★ THE OWNER'S CHALLENGE IS THE POINT OF THE WINDOW. Two independent signals, both required:
  //   the halt timestamp and the terminal state. Either alone could be stale.
  gate(
    'owner_challenge_not_exercised',
    o.halted_at === null && o.lifecycle !== 'challenge_halted',
    `halted_at=${o.halted_at}`
  );

  // ★ THE ACCEPTANCE FACT IS A GATE OF ITS OWN, AND IT COMES FIRST. Phase D refuses a release whose
  //   current generation was never provider-accepted, with `notice_never_accepted`. A checkpoint
  //   carrying NULL acceptance therefore describes a drill that CANNOT be resumed into a release,
  //   and it must say so by name rather than fail obscurely on a null date comparison.
  gate(
    'owner_notice_provider_accepted',
    checkpoint.notice_accepted_at !== null,
    `notice_accepted_at=${checkpoint.notice_accepted_at}`
  );

  // ★ STRICT, AND ANCHORED ON ACCEPTANCE. Since Phase D the door is
  //   `now() > notice_accepted_at + duration`; at the exact boundary instant it refuses and the
  //   owner's challenge still wins. A `>=` here would send the harness to a door it knows is shut,
  //   and an `owner_notified_at` anchor would send it days early.
  //
  //   NULL acceptance fails this gate too — `Date.parse(null)` is NaN and `nowMs > NaN` is false —
  //   so the two gates agree rather than one masking the other.
  gate(
    'release_window_strictly_elapsed',
    Number.isFinite(nowMs)
      && checkpoint.release_eligible_at !== null
      && nowMs > Date.parse(checkpoint.release_eligible_at),
    `now=${Number.isFinite(nowMs) ? new Date(nowMs).toISOString() : String(now)} eligible_at=${checkpoint.release_eligible_at}`
  );

  // ★ THE T2 GATE. Only a T2_DELIVERED verdict clears it — provider acceptance does not.
  gate('owner_email_delivery_established', o.t2_verdict === 'T2_DELIVERED', `t2=${o.t2_verdict}`);

  /* ── TWO-PERSON CONTROL: SINGLE-OPERATOR TEST MODE ─────────────────────────────────────────── */
  gate('reviewer_a_and_b_distinct', checkpoint.reviewer_a_uid !== checkpoint.reviewer_b_uid, 'checkpoint');
  gate(
    'observed_reviewers_distinct',
    typeof o.case_decided_by === 'string' &&
      typeof o.acting_release_admin_uid === 'string' &&
      o.case_decided_by !== o.acting_release_admin_uid,
    `decider=${o.case_decided_by} acting=${o.acting_release_admin_uid}`
  );
  gate(
    'reviewer_a_still_is_the_case_decider',
    o.case_decided_by === checkpoint.reviewer_a_uid,
    `decider=${o.case_decided_by}`
  );
  gate(
    'acting_admin_is_reviewer_b',
    o.acting_release_admin_uid === checkpoint.reviewer_b_uid,
    `acting=${o.acting_release_admin_uid}`
  );
  // ★ THE SWAP, NAMED SEPARATELY. Two identities that are individually valid and in each other's
  //   seats pass distinctness and fail here — and the operator is told it is a swap, not a mismatch.
  gate(
    'reviewer_identities_not_swapped',
    !(o.case_decided_by === checkpoint.reviewer_b_uid && o.acting_release_admin_uid === checkpoint.reviewer_a_uid),
    'reviewer A and B appear to be in each other seats'
  );
  gate('acting_admin_has_aal2', o.acting_admin_aal === 'aal2', `aal=${o.acting_admin_aal}`);

  /* ── STANDING WORLD ────────────────────────────────────────────────────────────────────────── */
  const sentinel = SENTINEL_RE.exec(String(o.standing_fixture_sentinel ?? ''));
  gate(
    'standing_fixture_intact',
    sentinel !== null && sentinel[1] === sentinel[2] && o.standing_fixture_sentinel === checkpoint.standing_fixture_sentinel,
    `observed=${o.standing_fixture_sentinel} checkpoint=${checkpoint.standing_fixture_sentinel}`
  );
  gate('source_deployment_drift_clean', o.source_deployment_drift_clean === true, `${o.source_deployment_drift_clean}`);
  gate('deployed_contracts_clean', o.deployed_contracts_clean === true, `${o.deployed_contracts_clean}`);

  /* ── THE CODE UNDER TEST HAS NOT MOVED ─────────────────────────────────────────────────────── */
  gate('api_sha_unchanged', o.api_sha === checkpoint.api_sha, `observed=${o.api_sha}`);
  gate('mobile_sha_unchanged', o.mobile_sha === checkpoint.mobile_sha, `observed=${o.mobile_sha}`);
  gate('admin_sha_unchanged', o.admin_sha === checkpoint.admin_sha, `observed=${o.admin_sha}`);

  const failed = gates.filter((g) => !g.pass).map((g) => g.id);
  return Object.freeze({
    decision: failed.length === 0 ? RESUME.ALLOWED : RESUME.REFUSED,
    gates: Object.freeze(gates),
    failed: Object.freeze(failed),
    // ★ Kept on every result, in both directions, so a report cannot quote a RESUME without it.
    two_person_control: 'TWO-PERSON CONTROL: SINGLE-OPERATOR TEST MODE',
  });
}

/** Every gate id `evaluateResume` can emit — asserted complete by the test, so none can vanish. */
export const RESUME_GATE_IDS = Object.freeze([
  'clock_supplied',
  'estate_matches',
  'case_matches',
  'lifecycle_is_challenge_window',
  'case_status_is_verified',
  'not_released',
  'no_release_authorization_exists',
  'owner_challenge_not_exercised',
  // ★ PHASE 11-OC / PHASE D. Named separately from the clock gate so a checkpoint that can never be
  // resumed into a release says WHY: "the provider never accepted the notice" and "seven days have
  // not passed" need opposite operator actions, and collapsing them into one date comparison would
  // report the second when the truth is the first.
  'owner_notice_provider_accepted',
  'release_window_strictly_elapsed',
  'owner_email_delivery_established',
  'reviewer_a_and_b_distinct',
  'observed_reviewers_distinct',
  'reviewer_a_still_is_the_case_decider',
  'acting_admin_is_reviewer_b',
  'reviewer_identities_not_swapped',
  'acting_admin_has_aal2',
  'standing_fixture_intact',
  'source_deployment_drift_clean',
  'deployed_contracts_clean',
  'api_sha_unchanged',
  'mobile_sha_unchanged',
  'admin_sha_unchanged',
]);
