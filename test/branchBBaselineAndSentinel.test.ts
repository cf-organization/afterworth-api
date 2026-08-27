/**
 * PHASE 11-OB PREP · BASELINE-GENERATOR AND SENTINEL CONTROLS.
 *
 * ★ Both instruments are tested against LOCAL FIXTURES ONLY. Neither opens a socket, and the
 * baseline builder is pure by construction — there is no code path from this suite to production.
 */
import { describe, expect, it } from "vitest";
import {
  BASELINE_FIELDS,
  BASELINE_VERSION,
  baselineFilename,
  buildBaseline,
  findForbiddenStrings,
  verifyBaseline,
} from "../scripts/lib/branchBBaseline.mjs";
import {
  BRANCH_B_PROPERTIES,
  SENTINEL,
  classifyBranchBSentinel,
  sentinelExitCode,
} from "../scripts/lib/branchBSentinel.mjs";

const uid = (n: number) => `0000000${n}-0000-4000-8000-00000000000${n}`;

const RECORD = Object.freeze({
  baseline_version: BASELINE_VERSION,
  captured_at: "2026-09-01T09:00:00.000Z",
  api_sha: "e17f2140254821cabb29bc6645cf55b0437da5b3",
  mobile_sha: "b7d86052d7fbc9af807c8d9686b69ddc308092eb",
  admin_sha: "fd7ef03587d06b4c4a182575c5e7717412d82e2a",
  estate_designator: "AW_BRANCHB",
  estate_uuid: uid(1),
  owner_uid: uid(2),
  fiduciary_uid: uid(3),
  operator_a_uid: uid(4),
  operator_b_uid: uid(5),
  designation_role: "executor",
  designation_status: "active",
  membership_posture: "none",
  grant_id: uid(6),
  grant_fingerprint: "b".repeat(64),
  release_condition: "after_verified_death",
  disclosure_hash: "c".repeat(64),
  lifecycle: "challenge_window",
  case_uuid: uid(7),
  case_status: "verified",
  outbox_census: { queued: 1, dispatched: 0, failedPermanent: 0 },
  notification_census: { death_process_initiated: 1 },
  release_authorizations_count: 0,
  standing_fixture_sentinel: "23/23",
  fixture_lock: "free",
});

describe("★ 0 · the baseline fixture is a control", () => {
  it("the well-formed record builds — every refusal below depends on it", () => {
    const r = buildBaseline({ ...RECORD });
    expect(r.ok, JSON.stringify((r as { errors?: string[] }).errors)).toBe(true);
  });

  it("the field set is closed, non-trivial, and covers the named contract", () => {
    expect(BASELINE_FIELDS.length).toBe(26);
    for (const required of [
      "api_sha", "mobile_sha", "admin_sha", "estate_designator", "estate_uuid", "owner_uid",
      "fiduciary_uid", "operator_a_uid", "operator_b_uid", "designation_role", "designation_status",
      "membership_posture", "grant_id", "grant_fingerprint", "release_condition", "disclosure_hash",
      "lifecycle", "case_uuid", "case_status", "outbox_census", "notification_census",
      "release_authorizations_count", "standing_fixture_sentinel", "fixture_lock",
    ]) {
      expect(BASELINE_FIELDS).toContain(required);
    }
  });
});

describe("★ 1 · the allowlist is closed in both directions", () => {
  it("an unknown field is refused", () => {
    const r = buildBaseline({ ...RECORD, owner_email: "x" });
    expect(r.ok).toBe(false);
    expect((r as { errors: string[] }).errors).toContain("unknown field: owner_email");
  });

  it("every required field is genuinely required", () => {
    for (const field of BASELINE_FIELDS) {
      const partial: Record<string, unknown> = { ...RECORD };
      delete partial[field];
      expect(buildBaseline(partial).ok, `omitting ${field} built cleanly`).toBe(false);
    }
  });

  it.each([
    ["api_sha", "e17f214"],
    ["estate_uuid", "nope"],
    ["designation_role", "beneficiary"],
    ["membership_posture", "executor"],
    ["lifecycle", "pending"],
    ["case_status", "decided"],
    ["release_condition", "after_verified_death_or_incapacity"],
    ["disclosure_hash", "short"],
    ["standing_fixture_sentinel", "twenty-three"],
    ["fixture_lock", "unknown"],
    ["release_authorizations_count", -1],
    ["outbox_census", { queued: "one" }],
    ["notification_census", { a: -1 }],
    ["outbox_census", [1, 2]],
  ])("a malformed %s is refused", (field, value) => {
    expect(buildBaseline({ ...RECORD, [field]: value }).ok).toBe(false);
  });
});

describe("★ 2 · credentials and addresses cannot enter an artifact", () => {
  it("★ an address-shaped value in an allowlisted field is still refused", () => {
    // The allowlist alone would have accepted this — the designator field is a string.
    const r = buildBaseline({ ...RECORD, estate_designator: "OWNER@EXAMPLE.TEST" });
    expect(r.ok).toBe(false);
    expect((r as { errors: string[] }).errors.join(" ")).toMatch(/forbidden content|estate_designator/);
  });

  it("★ a secret-shaped value anywhere is refused", () => {
    for (const bad of ["sb_secret_abcdef", "service_role", `eyJ${"a".repeat(25)}`]) {
      const r = buildBaseline({ ...RECORD, estate_designator: bad });
      expect(r.ok, `${bad} was accepted`).toBe(false);
    }
  });

  it("the deep scanner finds nested and key-position violations", () => {
    expect(findForbiddenStrings({ a: { b: ["x@y.zz"] } })).toEqual(["$.a.b[0]: address-shaped"]);
    expect(findForbiddenStrings({ "a@b.cc": 1 })[0]).toMatch(/key/);
    // POSITIVE CONTROL for the scanner: it finds what is present…
    expect(findForbiddenStrings({ t: "sb_secret_x" }).length).toBe(1);
    // …and stays silent on a clean record, so silence means something.
    expect(findForbiddenStrings(RECORD)).toEqual([]);
  });
});

describe("★ 3 · the digest is what makes the baseline immutable", () => {
  it("the artifact carries its own digest, computed over the record without it", () => {
    const r = buildBaseline({ ...RECORD });
    expect(r.ok).toBe(true);
    expect(r.artifact.baseline_sha256).toMatch(/^[0-9a-f]{64}$/);
    expect(verifyBaseline(r.artifact).ok).toBe(true);
  });

  it("★ tampering with any field breaks verification", () => {
    const r = buildBaseline({ ...RECORD });
    const tampered = { ...r.artifact, release_authorizations_count: 1 };
    const v = verifyBaseline(tampered);
    expect(v.ok).toBe(false);
    expect((v as { errors: string[] }).errors.join(" ")).toMatch(/digest mismatch/);
  });

  it("key order does not change the digest — the same world hashes the same", () => {
    const reordered = Object.fromEntries(Object.entries(RECORD).reverse());
    expect(buildBaseline(reordered).digest).toBe(buildBaseline({ ...RECORD }).digest);
  });

  it("an artifact with no digest is refused, not assumed valid", () => {
    expect(verifyBaseline({ ...RECORD } as never).ok).toBe(false);
  });

  it("repeated builds in one process agree", () => {
    expect(buildBaseline({ ...RECORD }).digest).toBe(buildBaseline({ ...RECORD }).digest);
  });
});

describe("4 · the filename is derived from an injected instant", () => {
  it("names the artifact deterministically", () => {
    expect(baselineFilename("2026-09-01T09:00:00.000Z")).toBe(
      "phase11ob-baseline-2026-09-01T09-00-00-000Z.json"
    );
  });
  it("refuses a bad instant rather than naming a file after one", () => {
    expect(baselineFilename("sometime")).toBeNull();
    expect(baselineFilename(null as never)).toBeNull();
  });
});

/* ════════════════════════════════════════════════════════════════════════════════════════════════ */

const INTACT = { tally: "23/23", exitCode: 0 };

describe("★ 5 · the sentinel reports ABSENT, never FAILED, before Branch B exists", () => {
  it("★ standing fixture intact + no Branch B estate → BRANCH_B_FIXTURE_ABSENT", () => {
    const r = classifyBranchBSentinel({ standingFixture: INTACT, branchB: null });
    expect(r.verdict).toBe(SENTINEL.ABSENT);
    expect(sentinelExitCode(r.verdict)).toBe(0);
  });

  it("absent still names the standing result — it is not a skipped check", () => {
    const r = classifyBranchBSentinel({ standingFixture: INTACT, branchB: null });
    expect(r.findings.map((f: { code: string }) => f.code)).toContain("branch_b_fixture_absent");
  });

  it("★ a BROKEN standing fixture is DRIFTED even while Branch B is absent", () => {
    const r = classifyBranchBSentinel({ standingFixture: { tally: "22/23", exitCode: 1 }, branchB: null });
    expect(r.verdict).toBe(SENTINEL.DRIFTED);
    expect(sentinelExitCode(r.verdict)).toBe(1);
  });
});

describe("★ 6 · the sentinel refuses to believe an instrument that checked nothing", () => {
  it("★ a 0/0 tally is UNVERIFIABLE, not intact", () => {
    const r = classifyBranchBSentinel({ standingFixture: { tally: "0/0", exitCode: 0 }, branchB: null });
    expect(r.verdict).toBe(SENTINEL.UNVERIFIABLE);
    expect(sentinelExitCode(r.verdict)).toBe(2);
  });

  it("an unparseable tally is UNVERIFIABLE", () => {
    for (const tally of ["", "ok", "23", undefined]) {
      expect(classifyBranchBSentinel({ standingFixture: { tally, exitCode: 0 }, branchB: null }).verdict).toBe(
        SENTINEL.UNVERIFIABLE
      );
    }
  });

  it("a delegate that was never run is UNVERIFIABLE", () => {
    expect(classifyBranchBSentinel({ standingFixture: null, branchB: null }).verdict).toBe(
      SENTINEL.UNVERIFIABLE
    );
  });

  it("a nonzero exit with a full tally is still drift — both signals are read", () => {
    const r = classifyBranchBSentinel({ standingFixture: { tally: "23/23", exitCode: 1 }, branchB: null });
    expect(r.verdict).toBe(SENTINEL.DRIFTED);
  });
});

describe("★ 7 · once Branch B exists, missing is never synthesized into state", () => {
  const PRESENT = Object.freeze({
    estate_uuid: uid(1),
    designation: "executor/active",
    membership: "none",
    grant: uid(6),
    lifecycle: "challenge_window",
    case: "verified",
    owner_notice: "queued",
    challenge_window: "open",
    release_authorizations: 0,
    released_at: null,
    disclosure_posture: "hidden",
    fixture_lock: "free",
  });

  /**
   * ★ PHASE 11-P — A HEALTHY OBSERVATION IS NOT SELF-CERTIFYING. It must be pinned against the
   * committed checkpoint, because once a drill is in flight "is it intact" means "is it still the
   * SAME drill", and presence alone cannot answer that.
   */
  const EXPECTED = Object.freeze({
    estate_uuid: PRESENT.estate_uuid,
    case_uuid: uid(2),
    lifecycle: "challenge_window",
    owner_outbox_id: uid(3),
    notice_accepted_at: null,
    release_eligible_at: null,
    reviewer_a_uid: uid(4),
    reviewer_b_uid: uid(5),
  });
  const OBSERVED = Object.freeze({ ...PRESENT, ...EXPECTED });

  it("a complete, healthy, PINNED observation is IN FLIGHT while the window runs", () => {
    const r = classifyBranchBSentinel({
      standingFixture: INTACT,
      branchB: { ...OBSERVED },
      expected: { ...EXPECTED },
    });
    expect(r.findings).toEqual([]);
    expect(r.verdict).toBe(SENTINEL.IN_FLIGHT);
  });

  it("★ an observation with NO checkpoint to pin against is refused, never certified", () => {
    const r = classifyBranchBSentinel({ standingFixture: INTACT, branchB: { ...OBSERVED } });
    expect(r.verdict).toBe(SENTINEL.DRIFTED);
    expect(r.findings.map((f: { code: string }) => f.code)).toContain("branch_b_expectations_absent");
  });

  it("★ a drifted pin is caught field by field", () => {
    for (const field of Object.keys(EXPECTED)) {
      const mutated = { ...OBSERVED, [field]: field.endsWith("_at") ? "2026-01-01T00:00:00.000Z" : uid(9) };
      const r = classifyBranchBSentinel({
        standingFixture: INTACT,
        branchB: mutated,
        expected: { ...EXPECTED },
      });
      expect(r.verdict, `drifting ${field} was not caught`).toBe(SENTINEL.DRIFTED);
    }
  });

  it("★ a PARTIAL observation is UNVERIFIABLE — a hole is not a null", () => {
    for (const prop of BRANCH_B_PROPERTIES) {
      const partial: Record<string, unknown> = { ...PRESENT };
      delete partial[prop];
      const r = classifyBranchBSentinel({ standingFixture: INTACT, branchB: partial });
      expect(r.verdict, `omitting ${prop} did not refuse`).toBe(SENTINEL.UNVERIFIABLE);
      expect(r.findings[r.findings.length - 1].detail).toContain(prop);
    }
  });

  /**
   * ★ PHASE 11-Q — NARROWED, NOT WEAKENED, AND THE SECOND HALF WAS DELETED BECAUSE IT WAS FICTION.
   *
   * This case used to assert two things. The first is still true and is now stated more precisely:
   * a `released_at` on a `challenge_window` lifecycle is not generic drift, it is a HALF-RELEASED
   * estate — `authorize_release` writes both in one transaction, so they cannot honestly disagree.
   * `RELEASED_INCONSISTENT` names that, and still exits 1.
   *
   * The second half asserted that `release_authorizations: 1` is drift. That assertion could never
   * have failed: the collector hardcoded the field to `0` and never read a database, so the
   * consumer check was dead code and this test was pinning a value no observation could produce.
   * The field is gone, so the assertion goes with it — see `branchBSentinelReleasedState.test.ts`,
   * which pins its absence and forbids the literal returning.
   */
  it("★ a half-released estate is INCONSISTENT — a stronger claim than generic drift", () => {
    const r = classifyBranchBSentinel({
      standingFixture: INTACT,
      branchB: { ...PRESENT, released_at: "2026-09-08T00:00:00Z" },
    });
    expect(r.verdict).toBe(SENTINEL.RELEASED_INCONSISTENT);
    expect(r.findings.map((f: { code: string }) => f.code)).toContain("branch_b_release_state_inconsistent");
  });

  it("the property list is non-trivial and covers the named contract", () => {
    for (const p of [
      "estate_uuid", "designation", "membership", "grant", "lifecycle", "case", "owner_notice",
      "challenge_window", "released_at", "disclosure_posture", "fixture_lock",
    ]) {
      expect(BRANCH_B_PROPERTIES).toContain(p);
    }
    // ★ The removed field must stay removed: a count nothing observes is not part of the contract.
    expect(BRANCH_B_PROPERTIES).not.toContain("release_authorizations");
  });
});
