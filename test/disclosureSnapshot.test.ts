/**
 * PHASE 11-Q · THE CANONICAL DISCLOSURE SNAPSHOT — no pre-image, no verdict.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ THE GAP THIS CLOSES, AND WHY IT COULD NOT BE CLOSED RETROACTIVELY.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * `evaluateDisclosureEquivalence` has always held the real rule — release reveals EXACTLY the
 * sanctioned payload and nothing else moves in either direction — but it had no CLI, and its `pre`
 * and `ownerPre` inputs are observations that can only be taken while the lifecycle is still
 * `challenge_window`. Branch B reached the irreversible boundary having captured only TWO of its
 * four documents, so the oracle could never be run for it. The estate is now `released` and that
 * observation window is closed permanently.
 *
 * ★ SO THE ONE THING THESE TESTS MUST GUARANTEE IS THAT THE SYSTEM NEVER PRETENDS OTHERWISE.
 *   A missing pre-image must refuse. A partial pre-image must refuse. A pre-image reconstructed
 *   from post-release state must be impossible to express. Fixture expectations must never stand in
 *   for observation. `docs/phase11p11-*` records the historical gap and stays open.
 */
import { describe, expect, it } from "vitest";
import {
  SNAPSHOT_SCHEMA_VERSION,
  SNAPSHOT_PHASE,
  VISIBILITY,
  EQUIVALENCE,
  decodeSnapshot,
  snapshotDigest,
  verifyDisclosureEquivalence,
} from "../scripts/lib/disclosureSnapshot.mjs";

const uid = (n: number) => `${String(n).repeat(8)}-${String(n).repeat(4)}-${String(n).repeat(4)}-${String(n).repeat(4)}-${String(n).repeat(12)}`;

const ESTATE = uid(1);
const CASE = uid(2);
const FID = uid(3);
const OWNER = uid(4);

const DEATH_DOC = uid(5);
const OPEN_DOC = uid(6);
const SEALED_1 = uid(7);
const SEALED_2 = uid(8);

const GRANT = Object.freeze({
  id: uid(9),
  estate_id: ESTATE,
  grantee_user_id: FID,
  grantee_role: "beneficiary",
  document_id: DEATH_DOC,
  category: "document",
  visibility_tier: "full_detail",
  release_condition: "after_verified_death",
});

const doc = (id: string, sensitivity: string, canAccess: boolean, rlsVisible = canAccess) => ({
  document_id: id,
  sensitivity,
  can_access_document: canAccess,
  rls_visible: rlsVisible,
});

/** The complete four-document universe, observed while the window is still open. */
const PRE = Object.freeze({
  schema_version: SNAPSHOT_SCHEMA_VERSION,
  phase: SNAPSHOT_PHASE.PRE_RELEASE,
  estate_id: ESTATE,
  case_id: CASE,
  lifecycle: "challenge_window",
  observed_at_utc: "2026-08-25T00:00:00.000Z",
  actor_uid: FID,
  actor_role: "fiduciary",
  owner_uid: OWNER,
  sanctioned_document_ids: [DEATH_DOC],
  expected_universe_ids: [DEATH_DOC, OPEN_DOC, SEALED_1, SEALED_2],
  documents: [
    doc(DEATH_DOC, "low", false),
    doc(OPEN_DOC, "low", true),
    doc(SEALED_1, "sealed", false),
    doc(SEALED_2, "sealed", false),
  ],
  owner_documents: [
    doc(DEATH_DOC, "low", true),
    doc(OPEN_DOC, "low", true),
    doc(SEALED_1, "sealed", true),
    doc(SEALED_2, "sealed", true),
  ],
  grant: GRANT,
  provenance: "captureDisclosureSnapshot.mjs --phase=pre",
});

/** The same world after a correct release: the death-conditioned doc discloses, nothing else moves. */
const POST = Object.freeze({
  ...PRE,
  phase: SNAPSHOT_PHASE.POST_RELEASE,
  lifecycle: "released",
  observed_at_utc: "2026-08-26T08:00:00.000Z",
  documents: [
    doc(DEATH_DOC, "low", true),
    doc(OPEN_DOC, "low", true),
    doc(SEALED_1, "sealed", false),
    doc(SEALED_2, "sealed", false),
  ],
  provenance: "captureDisclosureSnapshot.mjs --phase=post",
});

const codes = (r: { findings: readonly { code: string }[] }) => r.findings.map((f) => f.code);

describe("★ 0 · the happy path is a control — every refusal below depends on it", () => {
  it("a complete pre/post pair over a discriminating world PASSES", () => {
    const r = verifyDisclosureEquivalence({ pre: PRE, post: POST });
    expect(codes(r)).toEqual([]);
    expect(r.verdict).toBe(EQUIVALENCE.PASS);
  });

  it("both snapshots decode strictly", () => {
    expect(decodeSnapshot(PRE).ok).toBe(true);
    expect(decodeSnapshot(POST).ok).toBe(true);
  });
});

describe("★ 1 · NO PRE-IMAGE → NO CANONICAL VERDICT", () => {
  it("★ a missing pre snapshot refuses — it never falls back to the post state", () => {
    const r = verifyDisclosureEquivalence({ pre: null, post: POST });
    expect(r.verdict).toBe(EQUIVALENCE.REFUSE_INCOMPLETE_PRE);
    expect(r.verdict).not.toBe(EQUIVALENCE.PASS);
  });

  it("★ THE HISTORICAL BRANCH B SHAPE: a pre-image covering only 2 of 4 documents REFUSES", () => {
    const partialPre = {
      ...PRE,
      documents: [doc(DEATH_DOC, "low", false), doc(OPEN_DOC, "low", true)],
    };
    const r = verifyDisclosureEquivalence({ pre: partialPre, post: POST });
    expect(r.verdict).toBe(EQUIVALENCE.REFUSE_INCOMPLETE_PRE);
    expect(codes(r)).toContain("pre_universe_incomplete");
    // ★ The whole point: this must never be rewritten into a pass for the completed drill.
    expect(r.verdict).not.toBe(EQUIVALENCE.PASS);
  });

  it("★ a pre snapshot with a missing owner arm refuses — the positive control is not optional", () => {
    const noOwner: Record<string, unknown> = { ...PRE };
    delete noOwner.owner_documents;
    const r = verifyDisclosureEquivalence({ pre: noOwner, post: POST });
    expect(r.verdict).not.toBe(EQUIVALENCE.PASS);
  });

  it("★ a POST snapshot cannot be passed as the pre-image — the phase field forbids it", () => {
    const r = verifyDisclosureEquivalence({ pre: { ...POST }, post: POST });
    expect(r.verdict).toBe(EQUIVALENCE.REFUSE_WRONG_LIFECYCLE);
    expect(codes(r)).toContain("pre_snapshot_wrong_phase");
  });

  it("★ swapped pre/post snapshots are detected, not silently evaluated backwards", () => {
    const r = verifyDisclosureEquivalence({ pre: POST, post: PRE });
    expect(r.verdict).not.toBe(EQUIVALENCE.PASS);
  });

  it("★ a pre snapshot whose lifecycle is already released refuses", () => {
    const r = verifyDisclosureEquivalence({ pre: { ...PRE, lifecycle: "released" }, post: POST });
    expect(r.verdict).toBe(EQUIVALENCE.REFUSE_WRONG_LIFECYCLE);
  });

  it("★ a post snapshot whose lifecycle is NOT released refuses", () => {
    const r = verifyDisclosureEquivalence({ pre: PRE, post: { ...POST, lifecycle: "challenge_window" } });
    expect(r.verdict).toBe(EQUIVALENCE.REFUSE_WRONG_LIFECYCLE);
  });
});

describe("★ 2 · identity correspondence — the two halves must describe the same drill", () => {
  it("★ a wrong estate refuses", () => {
    const r = verifyDisclosureEquivalence({ pre: PRE, post: { ...POST, estate_id: uid(9) } });
    expect(r.verdict).toBe(EQUIVALENCE.REFUSE_IDENTITY_MISMATCH);
  });

  it("★ a wrong case refuses", () => {
    const r = verifyDisclosureEquivalence({ pre: PRE, post: { ...POST, case_id: uid(9) } });
    expect(r.verdict).toBe(EQUIVALENCE.REFUSE_IDENTITY_MISMATCH);
  });

  it("★ a different observed ACTOR refuses — two people's views are not a before and after", () => {
    const r = verifyDisclosureEquivalence({ pre: PRE, post: { ...POST, actor_uid: uid(9) } });
    expect(r.verdict).toBe(EQUIVALENCE.REFUSE_IDENTITY_MISMATCH);
  });

  it("★ a corrupted pre digest refuses when one is asserted", () => {
    const digest = snapshotDigest(PRE);
    expect(verifyDisclosureEquivalence({ pre: PRE, post: POST, expectedPreDigest: digest }).verdict)
      .toBe(EQUIVALENCE.PASS);
    expect(verifyDisclosureEquivalence({ pre: PRE, post: POST, expectedPreDigest: "0".repeat(64) }).verdict)
      .toBe(EQUIVALENCE.REFUSE_PROVENANCE_FAILURE);
  });

  it("the digest is stable across key order and changes with content", () => {
    const reordered = Object.fromEntries(Object.entries(PRE).reverse());
    expect(snapshotDigest(reordered)).toBe(snapshotDigest(PRE));
    expect(snapshotDigest({ ...PRE, lifecycle: "other" })).not.toBe(snapshotDigest(PRE));
  });
});

describe("★ 3 · completeness is provable, not assumed", () => {
  it("★ a document missing from the declared universe refuses", () => {
    const short = { ...PRE, documents: PRE.documents.slice(0, 3) };
    const r = verifyDisclosureEquivalence({ pre: short, post: POST });
    expect(r.verdict).toBe(EQUIVALENCE.REFUSE_INCOMPLETE_PRE);
    expect(codes(r)).toContain("pre_universe_incomplete");
  });

  it("★ a DUPLICATE document id refuses — a doubled row could mask a missing one", () => {
    const dup = { ...PRE, documents: [...PRE.documents, doc(SEALED_1, "sealed", false)] };
    expect(decodeSnapshot(dup).ok).toBe(false);
    expect(verifyDisclosureEquivalence({ pre: dup, post: POST }).verdict).not.toBe(EQUIVALENCE.PASS);
  });

  it("★ an UNEXPECTED document — one not in the declared universe — refuses", () => {
    const extra = { ...PRE, documents: [...PRE.documents, doc(uid(9), "low", true)] };
    const r = verifyDisclosureEquivalence({ pre: extra, post: POST });
    expect(r.verdict).not.toBe(EQUIVALENCE.PASS);
  });

  it("★ post must cover the same universe as pre", () => {
    const shortPost = { ...POST, documents: POST.documents.slice(0, 2) };
    const r = verifyDisclosureEquivalence({ pre: PRE, post: shortPost });
    expect(r.verdict).not.toBe(EQUIVALENCE.PASS);
  });

  it("★ a world with no unrelated items cannot discriminate and must not PASS", () => {
    const onlySanctioned = {
      ...PRE,
      expected_universe_ids: [DEATH_DOC],
      documents: [doc(DEATH_DOC, "low", false)],
      owner_documents: [doc(DEATH_DOC, "low", true)],
    };
    const onlySanctionedPost = {
      ...POST,
      expected_universe_ids: [DEATH_DOC],
      documents: [doc(DEATH_DOC, "low", true)],
      owner_documents: [doc(DEATH_DOC, "low", true)],
    };
    const r = verifyDisclosureEquivalence({ pre: onlySanctioned, post: onlySanctionedPost });
    expect(r.verdict).not.toBe(EQUIVALENCE.PASS);
  });
});

describe("★ 4 · the sealed invariant survives the lifecycle transition", () => {
  it("★ a sealed document visible BEFORE release fails", () => {
    const leaky = {
      ...PRE,
      documents: [doc(DEATH_DOC, "low", false), doc(OPEN_DOC, "low", true), doc(SEALED_1, "sealed", true), doc(SEALED_2, "sealed", false)],
    };
    const r = verifyDisclosureEquivalence({ pre: leaky, post: POST });
    expect(r.verdict).toBe(EQUIVALENCE.FAIL);
    expect(codes(r)).toContain("sealed_document_disclosed");
  });

  it("★ a sealed document visible AFTER release fails — release must not make sealed grantable", () => {
    const leaky = {
      ...POST,
      documents: [doc(DEATH_DOC, "low", true), doc(OPEN_DOC, "low", true), doc(SEALED_1, "sealed", true), doc(SEALED_2, "sealed", false)],
    };
    const r = verifyDisclosureEquivalence({ pre: PRE, post: leaky });
    expect(r.verdict).toBe(EQUIVALENCE.FAIL);
    expect(codes(r)).toContain("sealed_document_disclosed");
  });

  it("★ a sealed document readable through RLS fails even if the gate says false", () => {
    const leaky = {
      ...POST,
      documents: [doc(DEATH_DOC, "low", true), doc(OPEN_DOC, "low", true), doc(SEALED_1, "sealed", false, true), doc(SEALED_2, "sealed", false)],
    };
    const r = verifyDisclosureEquivalence({ pre: PRE, post: leaky });
    expect(r.verdict).toBe(EQUIVALENCE.FAIL);
  });

  it("★ the gate and the product read must AGREE — a disagreement is never resolved in favour of the nicer one", () => {
    const disagree = {
      ...POST,
      documents: [doc(DEATH_DOC, "low", true, false), doc(OPEN_DOC, "low", true), doc(SEALED_1, "sealed", false), doc(SEALED_2, "sealed", false)],
    };
    const r = verifyDisclosureEquivalence({ pre: PRE, post: disagree });
    expect(r.verdict).not.toBe(EQUIVALENCE.PASS);
    expect(codes(r)).toContain("access_signals_disagree");
  });

  it("★ an unknown visibility classification fails closed", () => {
    const weird = {
      ...POST,
      documents: [{ document_id: DEATH_DOC, sensitivity: "low", can_access_document: "maybe", rls_visible: true },
        doc(OPEN_DOC, "low", true), doc(SEALED_1, "sealed", false), doc(SEALED_2, "sealed", false)],
    };
    expect(decodeSnapshot(weird).ok).toBe(false);
    expect(verifyDisclosureEquivalence({ pre: PRE, post: weird }).verdict).not.toBe(EQUIVALENCE.PASS);
  });
});

describe("★ 5 · positive controls — the verifier must prove it can see the expected transition", () => {
  it("★ the death-conditioned document failing to disclose is a FAILED release, not a pass", () => {
    const undisclosed = {
      ...POST,
      documents: [doc(DEATH_DOC, "low", false), doc(OPEN_DOC, "low", true), doc(SEALED_1, "sealed", false), doc(SEALED_2, "sealed", false)],
    };
    const r = verifyDisclosureEquivalence({ pre: PRE, post: undisclosed });
    expect(r.verdict).toBe(EQUIVALENCE.FAIL);
    expect(codes(r)).toContain("sanctioned_payload_not_revealed");
  });

  it("★ the open control going hidden is a disclosure REGRESSION and fails", () => {
    const regressed = {
      ...POST,
      documents: [doc(DEATH_DOC, "low", true), doc(OPEN_DOC, "low", false), doc(SEALED_1, "sealed", false), doc(SEALED_2, "sealed", false)],
    };
    const r = verifyDisclosureEquivalence({ pre: PRE, post: regressed });
    expect(r.verdict).toBe(EQUIVALENCE.FAIL);
    expect(codes(r)).toContain("disclosure_regression");
  });

  it("★ the OWNER control: content the owner could not see pre-release makes the FIXTURE the problem", () => {
    const ownerBlind = {
      ...PRE,
      owner_documents: [doc(DEATH_DOC, "low", false), doc(OPEN_DOC, "low", true), doc(SEALED_1, "sealed", true), doc(SEALED_2, "sealed", true)],
    };
    const r = verifyDisclosureEquivalence({ pre: ownerBlind, post: POST });
    expect(r.verdict).not.toBe(EQUIVALENCE.PASS);
    expect(codes(r)).toContain("owner_cannot_see_sanctioned_content_pre_release");
  });

  it("★ an unrelated document appearing at release is over-exposure and fails", () => {
    const over = {
      ...POST,
      documents: [doc(DEATH_DOC, "low", true), doc(OPEN_DOC, "low", true), doc(SEALED_1, "sealed", false), doc(SEALED_2, "sealed", true)],
    };
    const r = verifyDisclosureEquivalence({ pre: PRE, post: over });
    expect(r.verdict).toBe(EQUIVALENCE.FAIL);
  });

  it("★ the grant must not change identity or scope across the release", () => {
    const rebound = { ...POST, grant: { ...GRANT, visibility_tier: "summary" } };
    const r = verifyDisclosureEquivalence({ pre: PRE, post: rebound });
    expect(r.verdict).toBe(EQUIVALENCE.FAIL);
    expect(codes(r)).toContain("grant_identity_or_scope_changed");
  });

  it("★ a grant that is not death-conditioned fails", () => {
    const wrongCondition = { ...GRANT, release_condition: "immediately" };
    const r = verifyDisclosureEquivalence({
      pre: { ...PRE, grant: wrongCondition },
      post: { ...POST, grant: wrongCondition },
    });
    expect(r.verdict).toBe(EQUIVALENCE.FAIL);
  });
});

describe("★ 6 · the schema cannot confuse a pre with a post", () => {
  it("the phase vocabulary is closed", () => {
    expect(decodeSnapshot({ ...PRE, phase: "whatever" }).ok).toBe(false);
  });

  it("an unknown top-level field is refused — strict in both directions", () => {
    expect(decodeSnapshot({ ...PRE, extra_key: 1 }).ok).toBe(false);
  });

  it("every required field is genuinely required", () => {
    for (const key of Object.keys(PRE)) {
      const partial: Record<string, unknown> = { ...PRE };
      delete partial[key];
      expect(decodeSnapshot(partial).ok, `${key} was not required`).toBe(false);
    }
  });

  it("the schema is versioned and the version is checked", () => {
    expect(SNAPSHOT_SCHEMA_VERSION).toBeGreaterThanOrEqual(1);
    expect(decodeSnapshot({ ...PRE, schema_version: SNAPSHOT_SCHEMA_VERSION + 1 }).ok).toBe(false);
  });

  it("the visibility vocabulary is exported and closed", () => {
    expect(Object.values(VISIBILITY)).toContain("sealed");
  });

  it("repeated evaluation in one process agrees — no stateful matcher", () => {
    const a = verifyDisclosureEquivalence({ pre: PRE, post: POST });
    const b = verifyDisclosureEquivalence({ pre: PRE, post: POST });
    expect(a.verdict).toBe(b.verdict);
    expect(snapshotDigest(PRE)).toBe(snapshotDigest(PRE));
  });
});
