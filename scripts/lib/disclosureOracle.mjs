/**
 * PHASE 11-OB PREP · THE RELEASE DISCLOSURE ORACLE — what release is allowed to change, and nothing else.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ THE PROPERTY BRANCH B ACTUALLY HAS TO PROVE.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * `release_condition_satisfied` says `after_verified_death` is satisfied ONLY at lifecycle
 * `released`, under the `standard` policy. So a correct release does exactly one thing to what a
 * fiduciary can see:
 *
 *   BEFORE  the grant EXISTS, is well-formed, and discloses NOTHING;
 *   AFTER   the SAME grant, unchanged in identity and scope, discloses EXACTLY the sanctioned payload;
 *   NEITHER anything else in the estate changes visibility, in either direction.
 *
 * The third line is the one an eyeball check misses. "The document appeared" is easy to confirm and
 * is satisfied just as well by a release that also exposed six unrelated documents.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ WHY AN EMPTY ESTATE IS BANNED AS A FIXTURE, IN CODE RATHER THAN IN A COMMENT.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * Against an estate holding one document and nothing else, a gate that HIDES EVERYTHING and a gate
 * that EXPOSES EVERYTHING produce the same observation as the correct gate for at least one of the
 * two phases — there is no unrelated world for the wrong answer to be wrong about. This is the
 * all-refused-payload trap the fiduciary sentinel already documents.
 *
 * So `evaluateDisclosureEquivalence` REFUSES a world that cannot discriminate: it requires at least
 * one sanctioned item AND at least one unrelated item that stays hidden throughout, and answers
 * `UNVERIFIABLE` otherwise rather than `PASS`.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ THE OWNER CONTROL IS NOT DECORATION EITHER.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * If the owner cannot see the synthetic content BEFORE release, then "the fiduciary cannot see it"
 * is a statement about the content not existing, not about the gate. The owner arm is a positive
 * control on the fixture; the fiduciary arm is the negative control on the gate. Both are required,
 * and their failures are reported differently.
 *
 * PURE. Set arithmetic and digests over caller-supplied observations. No clock, no network.
 */
import { canonicalDigest } from './canonicalJson.mjs';

export const ORACLE = Object.freeze({
  PASS: 'DISCLOSURE_EQUIVALENCE_HELD',
  FAIL: 'DISCLOSURE_EQUIVALENCE_VIOLATED',
  UNVERIFIABLE: 'DISCLOSURE_EQUIVALENCE_UNVERIFIABLE',
});

const asSet = (xs) => new Set(Array.isArray(xs) ? xs.map(String) : []);
const sorted = (s) => [...s].sort();
const minus = (a, b) => new Set([...a].filter((x) => !b.has(x)));
const intersect = (a, b) => new Set([...a].filter((x) => b.has(x)));

/**
 * The grant's identity and scope, canonicalized. Deliberately a CLOSED field list: a release that
 * quietly widened `visibility_tier` or re-pointed `grantee_user_id` would be a different grant
 * wearing the same id, and a digest over "whatever the payload happened to contain" could not say so.
 */
export function grantFingerprint(grant) {
  if (!grant || typeof grant !== 'object') return null;
  const required = [
    'id',
    'estate_id',
    'grantee_user_id',
    'grantee_role',
    'document_id',
    'category',
    'visibility_tier',
    'release_condition',
  ];
  const out = {};
  for (const k of required) {
    if (!(k in grant)) return null; // a missing field is refused, never defaulted
    out[k] = grant[k] ?? null;
  }
  return canonicalDigest(out);
}

/**
 * @param {object} input
 * @param {string[]} input.sanctionedIds        what release IS allowed to reveal
 * @param {string[]} input.universeIds          every item in the fixture world (must exceed sanctioned)
 * @param {object}   input.pre                  { visibleIds, grant }  — fiduciary, at challenge_window
 * @param {object}   input.post                 { visibleIds, grant }  — fiduciary, at released
 * @param {object}   input.ownerPre             { visibleIds }         — owner, at challenge_window
 */
export function evaluateDisclosureEquivalence({ sanctionedIds, universeIds, pre, post, ownerPre }) {
  const findings = [];
  const fail = (code, detail) => findings.push({ code, detail });

  const sanctioned = asSet(sanctionedIds);
  const universe = asSet(universeIds);
  const preVisible = asSet(pre?.visibleIds);
  const postVisible = asSet(post?.visibleIds);
  const ownerVisible = asSet(ownerPre?.visibleIds);

  /* ── 0 · THE FIXTURE MUST BE ABLE TO DISCRIMINATE ────────────────────────────────────────────── */
  const unsanctioned = minus(universe, sanctioned);
  if (sanctioned.size === 0) {
    return refuse('no_sanctioned_payload', 'the oracle would pass against a release that revealed nothing');
  }
  if (unsanctioned.size === 0) {
    return refuse(
      'universe_has_no_unrelated_items',
      'an expose-everything gate is indistinguishable from a correct one in this world'
    );
  }
  if ([...sanctioned].some((id) => !universe.has(id))) {
    return refuse('sanctioned_item_outside_universe', 'the fixture does not contain what it sanctions');
  }
  if ([...preVisible, ...postVisible, ...ownerVisible].some((id) => !universe.has(id))) {
    return refuse('observation_outside_universe', 'an observed id is not part of the declared world');
  }

  /* ── 1 · POSITIVE CONTROL — the owner can see the content BEFORE release ─────────────────────── */
  const ownerBlind = minus(sanctioned, ownerVisible);
  if (ownerBlind.size > 0) {
    return refuse(
      'owner_cannot_see_sanctioned_content_pre_release',
      `the fixture, not the gate, is the problem: ${sorted(ownerBlind).join(',')}`
    );
  }

  /* ── 2 · NEGATIVE CONTROL — the fiduciary cannot, before release ─────────────────────────────── */
  const leakedEarly = intersect(preVisible, sanctioned);
  if (leakedEarly.size > 0) {
    fail('pre_release_disclosure', `visible before release: ${sorted(leakedEarly).join(',')}`);
  }

  /* ── 3 · RELEASE REVEALS THE SANCTIONED PAYLOAD ──────────────────────────────────────────────── */
  const stillHidden = minus(sanctioned, postVisible);
  if (stillHidden.size > 0) {
    fail('sanctioned_payload_not_revealed', `still hidden after release: ${sorted(stillHidden).join(',')}`);
  }

  /* ── 4 · AND NOTHING ELSE MOVES, IN EITHER DIRECTION ─────────────────────────────────────────── */
  const appeared = minus(postVisible, preVisible);
  const overExposed = minus(appeared, sanctioned);
  if (overExposed.size > 0) {
    fail('unsanctioned_disclosure_expansion', `newly visible and not sanctioned: ${sorted(overExposed).join(',')}`);
  }
  const vanished = minus(preVisible, postVisible);
  if (vanished.size > 0) {
    fail('disclosure_regression', `no longer visible after release: ${sorted(vanished).join(',')}`);
  }

  /* ── 5 · THE UNRELATED HIDDEN WORLD IS BYTE-IDENTICAL ────────────────────────────────────────── */
  // Computed as a digest over the canonical sorted id set, so the comparison is one value rather
  // than a per-item loop that could quietly skip an item.
  const hiddenPre = canonicalDigest(sorted(minus(unsanctioned, preVisible)));
  const hiddenPost = canonicalDigest(sorted(minus(unsanctioned, postVisible)));
  if (hiddenPre !== hiddenPost) {
    fail('unrelated_hidden_world_changed', `${hiddenPre.slice(0, 12)} → ${hiddenPost.slice(0, 12)}`);
  }

  /* ── 6 · SAME GRANT, SAME SCOPE ──────────────────────────────────────────────────────────────── */
  const fpPre = grantFingerprint(pre?.grant);
  const fpPost = grantFingerprint(post?.grant);
  if (fpPre === null || fpPost === null) {
    return refuse('grant_fingerprint_incomplete', 'a grant observation is missing a scope field');
  }
  if (fpPre !== fpPost) {
    fail('grant_identity_or_scope_changed', `${fpPre.slice(0, 12)} → ${fpPost.slice(0, 12)}`);
  }
  if (pre?.grant?.release_condition !== 'after_verified_death') {
    fail('grant_is_not_death_conditioned', String(pre?.grant?.release_condition));
  }

  return Object.freeze({
    verdict: findings.length === 0 ? ORACLE.PASS : ORACLE.FAIL,
    findings: Object.freeze(findings),
    discriminating_world: Object.freeze({
      sanctioned: sanctioned.size,
      unrelated: unsanctioned.size,
      universe: universe.size,
    }),
    grant_fingerprint: fpPre,
    unrelated_hidden_digest: hiddenPre,
  });

  function refuse(code, detail) {
    return Object.freeze({
      verdict: ORACLE.UNVERIFIABLE,
      findings: Object.freeze([{ code, detail }]),
      discriminating_world: Object.freeze({
        sanctioned: sanctioned.size,
        unrelated: unsanctioned.size,
        universe: universe.size,
      }),
      grant_fingerprint: null,
      unrelated_hidden_digest: null,
    });
  }
}
