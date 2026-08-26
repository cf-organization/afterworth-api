/**
 * PHASE 11-Q · THE SENTINEL MUST TELL A SUCCESSFUL RELEASE FROM GENERIC DRIFT.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ THE DEFECT THIS FILE PINS, FOUND BY RUNNING THE SENTINEL AFTER A REAL RELEASE.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * `classifyBranchBSentinel` is pinned to a checkpoint written at `challenge_window`. After a
 * legitimate release THREE separate expectations flip at once — `released_at` becomes non-null, the
 * pinned `lifecycle` moves to `released`, and the death-conditioned document becomes DISCLOSED — and
 * each one produced a finding. Any finding forced `BRANCH_B_SENTINEL_DRIFTED` at exit 1.
 *
 * ★ SO THE `SENTINEL.OK` BRANCH WAS UNREACHABLE. The classifier ends with
 *   `released_at === null ? IN_FLIGHT : OK`, and its comment describes OK as "the drill finished
 *   cleanly" — but the findings list can never be empty once a release exists, so OK could not be
 *   returned. A verdict that no input can produce is not a verdict.
 *
 * ★ AND THE FIX MUST NOT BECOME AN UNCONDITIONAL POST-RELEASE PASS. The whole value of the
 *   instrument is that it can contradict you. `released_at` present with a `challenge_window`
 *   lifecycle, a `released` lifecycle with no `released_at`, a release that did NOT disclose the
 *   sanctioned document, a moved reviewer seat — all of those must still fail after release.
 *
 * The observed Branch B release (2026-08-26T07:04:28Z) is the motivating case and is NOT re-verified
 * here; this file is about the classifier, which is pure.
 */
import { describe, expect, it } from "vitest";
import {
  BRANCH_B_PROPERTIES,
  SENTINEL,
  classifyBranchBSentinel,
  sentinelExitCode,
} from "../scripts/lib/branchBSentinel.mjs";

const uid = (n: number) => `${String(n).repeat(8)}-${String(n).repeat(4)}-${String(n).repeat(4)}-${String(n).repeat(4)}-${String(n).repeat(12)}`;
const INTACT = Object.freeze({ tally: "23/23", exitCode: 0 });

const PINS = Object.freeze({
  estate_uuid: uid(1),
  case_uuid: uid(2),
  lifecycle: "challenge_window",
  owner_outbox_id: uid(3),
  notice_accepted_at: "2026-08-19T04:22:12.450Z",
  release_eligible_at: "2026-08-26T04:22:12.450Z",
  reviewer_a_uid: uid(4),
  reviewer_b_uid: uid(5),
});

/** A healthy in-flight world: window open, nothing disclosed. */
const IN_FLIGHT_WORLD = Object.freeze({
  ...PINS,
  designation: "executor/active",
  membership: "none",
  grant: uid(6),
  case: "verified",
  owner_notice: "dispatched",
  challenge_window: "2026-08-18T05:26:49.939Z",
  released_at: null,
  disclosure_posture: "hidden",
  fixture_lock: "free",
});

/**
 * The SAME drill after a correct release. Exactly three facts move, and every one of them is the
 * intended consequence of `authorize_release` succeeding.
 */
const RELEASED_WORLD = Object.freeze({
  ...IN_FLIGHT_WORLD,
  lifecycle: "released",
  released_at: "2026-08-26T07:04:28.572954+00:00",
  disclosure_posture: "sentinel_DISCLOSED",
});

const codes = (r: { findings: readonly { code: string }[] }) => r.findings.map((f) => f.code);

describe("★ 1 · a correct release is its own verdict, not generic drift", () => {
  it("★ THE DEFECT: a legitimate release must not be BRANCH_B_SENTINEL_DRIFTED", () => {
    const r = classifyBranchBSentinel({
      standingFixture: INTACT,
      branchB: { ...RELEASED_WORLD },
      expected: { ...PINS },
    });
    expect(r.verdict).not.toBe(SENTINEL.DRIFTED);
    expect(r.verdict).toBe(SENTINEL.OK);
    expect(r.findings).toEqual([]);
  });

  it("the released verdict is a clean exit — a finished drill is not a failure", () => {
    expect(sentinelExitCode(SENTINEL.OK)).toBe(0);
  });

  it("★ the SENTINEL.OK branch is genuinely reachable — it was dead code before", () => {
    const reached = classifyBranchBSentinel({
      standingFixture: INTACT,
      branchB: { ...RELEASED_WORLD },
      expected: { ...PINS },
    });
    expect(reached.verdict).toBe(SENTINEL.OK);
  });
});

describe("★ 2 · pre-release drift detection is NOT weakened", () => {
  it("a healthy in-flight world is still IN_FLIGHT", () => {
    const r = classifyBranchBSentinel({
      standingFixture: INTACT,
      branchB: { ...IN_FLIGHT_WORLD },
      expected: { ...PINS },
    });
    expect(r.verdict).toBe(SENTINEL.IN_FLIGHT);
    expect(r.findings).toEqual([]);
  });

  it("★ every pinned fact still drifts field by field, before release", () => {
    for (const field of Object.keys(PINS)) {
      const mutated = {
        ...IN_FLIGHT_WORLD,
        [field]: field.endsWith("_at") ? "2001-01-01T00:00:00.000Z" : uid(9),
      };
      const r = classifyBranchBSentinel({ standingFixture: INTACT, branchB: mutated, expected: { ...PINS } });
      expect(r.verdict, `drifting ${field} pre-release was not caught`).not.toBe(SENTINEL.IN_FLIGHT);
      expect(r.verdict, `drifting ${field} pre-release was not caught`).not.toBe(SENTINEL.OK);
    }
  });

  it("★ a pre-release LEAK is still drift — disclosure before release is the whole hazard", () => {
    const r = classifyBranchBSentinel({
      standingFixture: INTACT,
      branchB: { ...IN_FLIGHT_WORLD, disclosure_posture: "sentinel_DISCLOSED" },
      expected: { ...PINS },
    });
    expect(r.verdict).toBe(SENTINEL.DRIFTED);
    expect(codes(r)).toContain("branch_b_disclosure_posture_wrong");
  });

  it("a halted challenge is still drift against a checkpoint expecting an open window", () => {
    const r = classifyBranchBSentinel({
      standingFixture: INTACT,
      branchB: { ...IN_FLIGHT_WORLD, lifecycle: "challenge_halted" },
      expected: { ...PINS },
    });
    expect(r.verdict).toBe(SENTINEL.DRIFTED);
  });
});

describe("★ 3 · an INCONSISTENT release still fails — the fix is not a post-release amnesty", () => {
  it("★ released_at present but the lifecycle never moved", () => {
    const r = classifyBranchBSentinel({
      standingFixture: INTACT,
      branchB: { ...IN_FLIGHT_WORLD, released_at: "2026-08-26T07:04:28Z" },
      expected: { ...PINS },
    });
    expect(r.verdict).toBe(SENTINEL.RELEASED_INCONSISTENT);
    expect(sentinelExitCode(r.verdict)).toBe(1);
  });

  it("★ a released lifecycle with NO released_at", () => {
    const r = classifyBranchBSentinel({
      standingFixture: INTACT,
      branchB: { ...IN_FLIGHT_WORLD, lifecycle: "released", released_at: null },
      expected: { ...PINS },
    });
    expect(r.verdict).toBe(SENTINEL.RELEASED_INCONSISTENT);
  });

  it("★ a release that did NOT disclose the sanctioned document is a FAILED release", () => {
    const r = classifyBranchBSentinel({
      standingFixture: INTACT,
      branchB: { ...RELEASED_WORLD, disclosure_posture: "hidden" },
      expected: { ...PINS },
    });
    expect(r.verdict).not.toBe(SENTINEL.OK);
    expect(codes(r)).toContain("branch_b_release_did_not_disclose");
  });

  it("★ a broken disclosure probe post-release is never a pass", () => {
    const r = classifyBranchBSentinel({
      standingFixture: INTACT,
      branchB: { ...RELEASED_WORLD, disclosure_posture: "probe_broken_open_control_not_visible" },
      expected: { ...PINS },
    });
    expect(r.verdict).not.toBe(SENTINEL.OK);
  });

  it("★ an UNKNOWN disclosure posture fails closed in both phases", () => {
    for (const world of [IN_FLIGHT_WORLD, RELEASED_WORLD]) {
      const r = classifyBranchBSentinel({
        standingFixture: INTACT,
        branchB: { ...world, disclosure_posture: "something_nobody_taught_it" },
        expected: { ...PINS },
      });
      expect(r.verdict, "an unknown posture went green").not.toBe(SENTINEL.OK);
      expect(r.verdict, "an unknown posture went green").not.toBe(SENTINEL.IN_FLIGHT);
    }
  });

  it("★ identity must NOT move across a release — only lifecycle and disclosure may", () => {
    for (const field of ["estate_uuid", "case_uuid", "owner_outbox_id", "reviewer_a_uid", "reviewer_b_uid"]) {
      const r = classifyBranchBSentinel({
        standingFixture: INTACT,
        branchB: { ...RELEASED_WORLD, [field]: uid(9) },
        expected: { ...PINS },
      });
      expect(r.verdict, `${field} moved across the release and was not caught`).not.toBe(SENTINEL.OK);
    }
  });

  it("a released world with a broken standing fixture is not OK either", () => {
    const r = classifyBranchBSentinel({
      standingFixture: { tally: "22/23", exitCode: 1 },
      branchB: { ...RELEASED_WORLD },
      expected: { ...PINS },
    });
    expect(r.verdict).not.toBe(SENTINEL.OK);
  });

  it("a released observation with NO checkpoint is refused, never certified", () => {
    const r = classifyBranchBSentinel({ standingFixture: INTACT, branchB: { ...RELEASED_WORLD } });
    expect(r.verdict).not.toBe(SENTINEL.OK);
  });
});

describe("★ 4 · the fabricated authorization count is gone", () => {
  it("★ release_authorizations is no longer a claimed observable property", () => {
    expect(BRANCH_B_PROPERTIES).not.toContain("release_authorizations");
  });

  it("★ a world without the field is still fully classifiable — nothing depended on the fiction", () => {
    const world: Record<string, unknown> = { ...RELEASED_WORLD };
    delete world.release_authorizations;
    const r = classifyBranchBSentinel({ standingFixture: INTACT, branchB: world, expected: { ...PINS } });
    expect(r.verdict).toBe(SENTINEL.OK);
  });

  it("★ STATIC: the collector must not hardcode an authorization count", async () => {
    const { readFileSync } = await import("node:fs");
    const src = readFileSync(new URL("../scripts/branchBSentinel.mjs", import.meta.url), "utf8");
    // Strip block comments and line comments: prose about the defect is not the defect.
    const code = src.replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "");
    expect(code).not.toMatch(/release_authorizations\s*:\s*\d/);
    expect(code).not.toMatch(/authorization\(s\)/);
  });

  it("★ POSITIVE CONTROL for that static rule — it can see the pattern it forbids", () => {
    const planted = "  release_authorizations: 0,\n";
    expect(planted).toMatch(/release_authorizations\s*:\s*\d/);
  });
});
