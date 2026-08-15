/**
 * PHASE 11-OB PREP · DISCLOSURE-ORACLE CONTROLS.
 *
 * ★ THE FIXTURE IS A REAL, NON-EMPTY ESTATE. One sanctioned document plus five unrelated items that
 * must never move: two documents the fiduciary can already see (an ordinary `immediately` grant),
 * and three that stay hidden throughout. Against an EMPTY estate a hide-everything gate and an
 * expose-everything gate both look correct, so the fixture is chosen to make each wrong answer
 * observably wrong — and the oracle refuses worlds that cannot do that.
 */
import { describe, expect, it } from "vitest";
import {
  ORACLE,
  evaluateDisclosureEquivalence,
  grantFingerprint,
} from "../scripts/lib/disclosureOracle.mjs";
import { canonicalDigest, canonicalize } from "../scripts/lib/canonicalJson.mjs";

const SANCTIONED = "doc-sanctioned-letter";
const ALREADY_VISIBLE = ["doc-open-1", "doc-open-2"];
const ALWAYS_HIDDEN = ["doc-sealed-1", "doc-sealed-2", "asset-hidden-1"];
const UNIVERSE = [SANCTIONED, ...ALREADY_VISIBLE, ...ALWAYS_HIDDEN];

const GRANT = Object.freeze({
  id: "9f1c2d3e-4a5b-4c6d-8e9f-0a1b2c3d4e5f",
  estate_id: "11111111-2222-4333-8444-555555555555",
  grantee_user_id: "66666666-7777-4888-8999-aaaaaaaaaaaa",
  grantee_role: "beneficiary",
  document_id: SANCTIONED,
  category: null,
  visibility_tier: "full",
  release_condition: "after_verified_death",
});

const WORLD = {
  sanctionedIds: [SANCTIONED],
  universeIds: UNIVERSE,
  ownerPre: { visibleIds: UNIVERSE }, // the owner sees their own estate
  pre: { visibleIds: [...ALREADY_VISIBLE], grant: GRANT },
  post: { visibleIds: [...ALREADY_VISIBLE, SANCTIONED], grant: GRANT },
};

const run = (over: Record<string, unknown> = {}) =>
  evaluateDisclosureEquivalence({ ...WORLD, ...over } as never);

describe("★ 0 · the fixture is a control", () => {
  it("the correct world PASSES — every failure below depends on it", () => {
    const r = run();
    expect(r.findings).toEqual([]);
    expect(r.verdict).toBe(ORACLE.PASS);
  });

  it("★ the world genuinely discriminates: sanctioned ⊂ universe, and unrelated items exist", () => {
    const r = run();
    expect(r.discriminating_world.sanctioned).toBe(1);
    expect(r.discriminating_world.unrelated).toBe(5);
    expect(r.discriminating_world.universe).toBe(6);
  });

  it("the pre-release fixture really does hide the sanctioned item", () => {
    // Precondition: if it were already visible, "release revealed it" could not be observed.
    expect(WORLD.pre.visibleIds).not.toContain(SANCTIONED);
    expect(WORLD.post.visibleIds).toContain(SANCTIONED);
  });
});

describe("★ 1 · a gate that always HIDES fails", () => {
  it("nothing revealed after release → FAIL", () => {
    const r = run({ post: { visibleIds: [...ALREADY_VISIBLE], grant: GRANT } });
    expect(r.verdict).toBe(ORACLE.FAIL);
    expect(r.findings.map((f: { code: string }) => f.code)).toContain("sanctioned_payload_not_revealed");
  });

  it("a gate that hides EVERYTHING, both phases, fails on regression too", () => {
    const r = run({
      pre: { visibleIds: [], grant: GRANT },
      post: { visibleIds: [], grant: GRANT },
    });
    expect(r.verdict).toBe(ORACLE.FAIL);
    expect(r.findings.map((f: { code: string }) => f.code)).toContain("sanctioned_payload_not_revealed");
  });
});

describe("★ 2 · a gate that EXPOSES EVERYTHING fails", () => {
  it("release that also reveals unrelated items → FAIL", () => {
    const r = run({ post: { visibleIds: UNIVERSE, grant: GRANT } });
    expect(r.verdict).toBe(ORACLE.FAIL);
    const codes = r.findings.map((f: { code: string }) => f.code);
    expect(codes).toContain("unsanctioned_disclosure_expansion");
    expect(codes).toContain("unrelated_hidden_world_changed");
  });

  it("★ exposing exactly ONE extra unrelated item is caught — not just a wholesale blowout", () => {
    const r = run({
      post: { visibleIds: [...ALREADY_VISIBLE, SANCTIONED, "doc-sealed-1"], grant: GRANT },
    });
    expect(r.verdict).toBe(ORACLE.FAIL);
    expect(r.findings.find((f: { code: string }) => f.code === "unsanctioned_disclosure_expansion")!.detail)
      .toContain("doc-sealed-1");
  });
});

describe("★ 3 · the required controls", () => {
  it("★ NEGATIVE CONTROL — sanctioned content visible to the fiduciary BEFORE release → FAIL", () => {
    const r = run({ pre: { visibleIds: [...ALREADY_VISIBLE, SANCTIONED], grant: GRANT } });
    expect(r.verdict).toBe(ORACLE.FAIL);
    expect(r.findings.map((f: { code: string }) => f.code)).toContain("pre_release_disclosure");
  });

  it("★ POSITIVE CONTROL — an owner who cannot see the content is a broken FIXTURE, not a pass", () => {
    const r = run({ ownerPre: { visibleIds: [...ALREADY_VISIBLE, ...ALWAYS_HIDDEN] } });
    expect(r.verdict).toBe(ORACLE.UNVERIFIABLE);
    expect(r.findings[0].code).toBe("owner_cannot_see_sanctioned_content_pre_release");
  });

  it("the owner control failing is reported as UNVERIFIABLE, never as a gate violation", () => {
    const r = run({ ownerPre: { visibleIds: [] } });
    expect(r.verdict).not.toBe(ORACLE.FAIL);
    expect(r.verdict).toBe(ORACLE.UNVERIFIABLE);
  });
});

describe("★ 4 · a world that cannot discriminate is refused, never passed", () => {
  it("★ an EMPTY estate is refused", () => {
    const r = evaluateDisclosureEquivalence({
      sanctionedIds: [],
      universeIds: [],
      ownerPre: { visibleIds: [] },
      pre: { visibleIds: [], grant: GRANT },
      post: { visibleIds: [], grant: GRANT },
    } as never);
    expect(r.verdict).toBe(ORACLE.UNVERIFIABLE);
    expect(r.findings[0].code).toBe("no_sanctioned_payload");
  });

  it("★ a one-document estate is refused — expose-everything would look correct", () => {
    const r = evaluateDisclosureEquivalence({
      sanctionedIds: [SANCTIONED],
      universeIds: [SANCTIONED],
      ownerPre: { visibleIds: [SANCTIONED] },
      pre: { visibleIds: [], grant: GRANT },
      post: { visibleIds: [SANCTIONED], grant: GRANT },
    } as never);
    expect(r.verdict).toBe(ORACLE.UNVERIFIABLE);
    expect(r.findings[0].code).toBe("universe_has_no_unrelated_items");
  });

  it("sanctioning something outside the declared world is refused", () => {
    expect(run({ sanctionedIds: ["doc-ghost"] }).verdict).toBe(ORACLE.UNVERIFIABLE);
  });

  it("observing something outside the declared world is refused", () => {
    expect(run({ post: { visibleIds: [...UNIVERSE, "doc-ghost"], grant: GRANT } }).verdict).toBe(
      ORACLE.UNVERIFIABLE
    );
  });
});

describe("★ 5 · the grant must be the same grant, at the same scope", () => {
  it("a re-pointed grantee is caught", () => {
    const r = run({
      post: { visibleIds: [...ALREADY_VISIBLE, SANCTIONED], grant: { ...GRANT, grantee_user_id: "someone-else" } },
    });
    expect(r.findings.map((f: { code: string }) => f.code)).toContain("grant_identity_or_scope_changed");
  });

  it("a widened visibility tier is caught", () => {
    const r = run({
      post: { visibleIds: [...ALREADY_VISIBLE, SANCTIONED], grant: { ...GRANT, visibility_tier: "full_plus" } },
    });
    expect(r.findings.map((f: { code: string }) => f.code)).toContain("grant_identity_or_scope_changed");
  });

  it("★ a release_condition that is not after_verified_death is caught", () => {
    const immediate = { ...GRANT, release_condition: "immediately" };
    const r = run({
      pre: { visibleIds: [...ALREADY_VISIBLE], grant: immediate },
      post: { visibleIds: [...ALREADY_VISIBLE, SANCTIONED], grant: immediate },
    });
    expect(r.findings.map((f: { code: string }) => f.code)).toContain("grant_is_not_death_conditioned");
  });

  it("an incomplete grant observation is UNVERIFIABLE, not a pass", () => {
    const { visibility_tier, ...partial } = GRANT;
    expect(grantFingerprint(partial)).toBeNull();
    expect(run({ post: { visibleIds: [...ALREADY_VISIBLE, SANCTIONED], grant: partial } }).verdict).toBe(
      ORACLE.UNVERIFIABLE
    );
  });

  it("the fingerprint is stable under key reordering and sensitive to value change", () => {
    const reordered = Object.fromEntries(Object.entries(GRANT).reverse());
    expect(grantFingerprint(reordered)).toBe(grantFingerprint(GRANT));
    expect(grantFingerprint({ ...GRANT, category: "estate_documents" })).not.toBe(grantFingerprint(GRANT));
  });
});

describe("6 · disclosure regression is a violation too", () => {
  it("something that was visible before and is not after → FAIL", () => {
    const r = run({ post: { visibleIds: ["doc-open-1", SANCTIONED], grant: GRANT } });
    expect(r.findings.map((f: { code: string }) => f.code)).toContain("disclosure_regression");
  });
});

describe("7 · canonicalization is what makes the digests mean anything", () => {
  it("key order does not change the canonical form", () => {
    expect(canonicalize({ b: 1, a: 2 })).toBe('{"a":2,"b":1}');
    expect(canonicalDigest({ b: 1, a: 2 })).toBe(canonicalDigest({ a: 2, b: 1 }));
  });

  it("array order DOES — order is data here", () => {
    expect(canonicalDigest([1, 2])).not.toBe(canonicalDigest([2, 1]));
  });

  it("★ undefined is refused rather than silently dropped", () => {
    expect(() => canonicalize({ a: undefined })).toThrow(/undefined/);
    // JSON.stringify would have produced `{}` — a digest describing a smaller world.
    expect(JSON.stringify({ a: undefined })).toBe("{}");
  });

  it("non-finite numbers are refused", () => {
    expect(() => canonicalize({ a: NaN })).toThrow(/non-finite/);
    expect(() => canonicalize({ a: Infinity })).toThrow(/non-finite/);
  });

  it("nested objects are sorted at every level", () => {
    expect(canonicalize({ z: { y: 1, x: 2 }, a: [{ d: 1, c: 2 }] })).toBe(
      '{"a":[{"c":2,"d":1}],"z":{"x":2,"y":1}}'
    );
  });

  it("the digest is a 64-hex sha256 and is repeatable in one process", () => {
    const d = canonicalDigest(WORLD.universeIds);
    expect(d).toMatch(/^[0-9a-f]{64}$/);
    expect(canonicalDigest(WORLD.universeIds)).toBe(d);
  });
});
