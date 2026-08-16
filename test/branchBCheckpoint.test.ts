/**
 * PHASE 11-OB PREP · CHECKPOINT AND RESUME-GATE CONTROLS.
 *
 * ★ THE SHAPE OF EVERY TEST BELOW IS: start from a fixture that PASSES, break exactly one thing,
 * and require the named gate — and only meaningfully that gate — to fail. A negative assertion made
 * against an object that was already failing for an unrelated reason proves nothing about the rule
 * it is named for, which is the same defect as an `@ts-expect-error` on an incomplete object.
 *
 * ★ THE ALL-PASS FIXTURE IS ITSELF A CONTROL. If it ever stops returning RESUME, every "and now it
 * refuses" assertion below becomes vacuous. It is asserted first.
 */
import { describe, expect, it } from "vitest";
import {
  CHECKPOINT_FIELDS,
  CHECKPOINT_VERSION,
  RESUME,
  RESUME_GATE_IDS,
  RESUME_SAFETY_MARGIN_SECONDS,
  SEVEN_DAYS_SECONDS,
  decodeCheckpoint,
  deriveWindowInstants,
  evaluateResume,
} from "../scripts/lib/branchBCheckpoint.mjs";

const OWNER_NOTIFIED = "2026-09-01T10:00:00.000Z";
const WINDOW = deriveWindowInstants(OWNER_NOTIFIED, SEVEN_DAYS_SECONDS)!;

const uid = (n: number) => `0000000${n}-0000-4000-8000-00000000000${n}`;

const CHECKPOINT = Object.freeze({
  checkpoint_version: CHECKPOINT_VERSION,
  estate_uuid: uid(1),
  estate_designator: "AW_BRANCHB",
  case_uuid: uid(2),
  owner_uid: uid(3),
  fiduciary_uid: uid(4),
  reviewer_a_uid: uid(5),
  reviewer_b_uid: uid(6),
  verification_admin: "AW_ADMIN_TEST_A",
  required_release_admin: "AW_ADMIN_TEST_B",
  lifecycle: "challenge_window",
  case_status: "verified",
  owner_notified_at: OWNER_NOTIFIED,
  challenge_window_started_at: OWNER_NOTIFIED,
  challenge_window_duration_seconds: SEVEN_DAYS_SECONDS,
  release_eligible_at: WINDOW.release_eligible_at,
  recommended_resume_after: WINDOW.recommended_resume_after,
  owner_outbox_id: uid(7),
  owner_notification_id: uid(8),
  B0: "2026-09-01T09:00:00.000Z",
  B1: "2026-09-01T09:30:00.000Z",
  B2: OWNER_NOTIFIED,
  B3: null,
  death_conditioned_grant_id: uid(9),
  pre_release_payload_sha256: "a".repeat(64),
  release_authorizations_count: 0,
  standing_fixture_sentinel: "23/23",
  api_sha: "e17f2140254821cabb29bc6645cf55b0437da5b3",
  mobile_sha: "b7d86052d7fbc9af807c8d9686b69ddc308092eb",
  admin_sha: "fd7ef03587d06b4c4a182575c5e7717412d82e2a",
});

/**
 * ★ NO MODULE-LEVEL `throw`, AND THAT IS A MUTATION-TESTING REQUIREMENT RATHER THAN A STYLE CHOICE.
 *
 * The first version threw here when the fixture failed to decode. The mutation "drop `case_uuid`
 * from the schema" then made the whole FILE unloadable, and the mutation runner reported
 * HARNESS_FAILURE instead of a detection. A suite that cannot load cannot distinguish "the rule I
 * deleted was load-bearing" from "I broke the build", and letting the second stand in for the first
 * is how a mutation gets scored as caught when nothing caught it.
 *
 * So the fixture falls back to the undecoded object and its decodability is an ASSERTION below.
 * Measured: with this shape the mutation fails 10 assertions; with the `throw`, it fails none,
 * because the suite never runs.
 */
const decoded = decodeCheckpoint({ ...CHECKPOINT });
const CP = (decoded.ok ? decoded.checkpoint : CHECKPOINT) as typeof CHECKPOINT;

const OBSERVED = Object.freeze({
  estate_uuid: CP.estate_uuid,
  case_uuid: CP.case_uuid,
  lifecycle: "challenge_window",
  case_status: "verified",
  released_at: null,
  halted_at: null,
  release_authorizations_count: 0,
  t2_verdict: "T2_DELIVERED",
  case_decided_by: CP.reviewer_a_uid,
  acting_release_admin_uid: CP.reviewer_b_uid,
  acting_admin_aal: "aal2",
  standing_fixture_sentinel: "23/23",
  source_deployment_drift_clean: true,
  deployed_contracts_clean: true,
  api_sha: CP.api_sha,
  mobile_sha: CP.mobile_sha,
  admin_sha: CP.admin_sha,
});

/** One millisecond past the door — the smallest clock that can legitimately resume. */
const READY_NOW = new Date(Date.parse(CP.release_eligible_at) + 1).toISOString();

const resume = (over: Record<string, unknown> = {}, now: string = READY_NOW) =>
  evaluateResume({ checkpoint: CP, observed: { ...OBSERVED, ...over }, now });

describe("★ 0 · the fixtures are controls, not decoration", () => {
  it("★ the fixture decodes — asserted, not thrown, so a schema mutation is a detection", () => {
    expect(decoded.ok, JSON.stringify((decoded as { errors?: string[] }).errors)).toBe(true);
  });

  it("the all-pass fixture resumes — every refusal below depends on this", () => {
    const r = resume();
    expect(r.failed).toEqual([]);
    expect(r.decision).toBe(RESUME.ALLOWED);
  });

  it("every declared gate id is actually emitted, and no extra one is", () => {
    // A gate that silently stopped being evaluated would make its "and now it refuses" test the
    // only thing keeping it alive — and that test would then be asserting nothing.
    expect(resume().gates.map((g: { id: string }) => g.id).sort()).toEqual([...RESUME_GATE_IDS].sort());
  });

  it("the result always carries the single-operator classification, in both directions", () => {
    expect(resume().two_person_control).toMatch(/SINGLE-OPERATOR TEST MODE/);
    expect(resume({ lifecycle: "released" }).two_person_control).toMatch(/SINGLE-OPERATOR TEST MODE/);
  });
});

describe("★ 1 · the decoder is strict in BOTH directions", () => {
  it("a well-formed checkpoint decodes", () => {
    expect(decodeCheckpoint({ ...CHECKPOINT }).ok).toBe(true);
  });

  it("★ an UNKNOWN field is rejected", () => {
    const r = decodeCheckpoint({ ...CHECKPOINT, resumed_by: "someone" });
    expect(r.ok).toBe(false);
    expect(r.errors).toContain("unknown field: resumed_by");
  });

  it("★ a MISSING required field is rejected — every one of them", () => {
    for (const field of CHECKPOINT_FIELDS) {
      const partial: Record<string, unknown> = { ...CHECKPOINT };
      delete partial[field];
      const r = decodeCheckpoint(partial);
      expect(r.ok, `omitting ${field} decoded cleanly`).toBe(false);
      expect(r.errors).toContain(`missing field: ${field}`);
    }
  });

  it("★ omitting case_uuid specifically is rejected", () => {
    const partial: Record<string, unknown> = { ...CHECKPOINT };
    delete partial.case_uuid;
    expect(decodeCheckpoint(partial).errors).toContain("missing field: case_uuid");
  });

  it("the schema is non-trivial and covers the named contract", () => {
    expect(CHECKPOINT_FIELDS.length).toBeGreaterThanOrEqual(30);
    for (const required of [
      "checkpoint_version", "estate_uuid", "estate_designator", "case_uuid", "owner_uid",
      "fiduciary_uid", "reviewer_a_uid", "reviewer_b_uid", "verification_admin",
      "required_release_admin", "lifecycle", "case_status", "owner_notified_at",
      "challenge_window_started_at", "challenge_window_duration_seconds", "release_eligible_at",
      "recommended_resume_after", "owner_outbox_id", "owner_notification_id", "B0", "B1", "B2",
      "B3", "death_conditioned_grant_id", "pre_release_payload_sha256",
      "release_authorizations_count", "standing_fixture_sentinel", "api_sha", "mobile_sha",
      "admin_sha",
    ]) {
      expect(CHECKPOINT_FIELDS).toContain(required);
    }
  });

  it.each([
    ["estate_uuid", "not-a-uuid"],
    ["case_uuid", "12345"],
    ["api_sha", "e17f214"],
    ["mobile_sha", "zzzz"],
    ["pre_release_payload_sha256", "a".repeat(63)],
    ["owner_notified_at", "yesterday"],
    ["challenge_window_duration_seconds", 0],
    ["challenge_window_duration_seconds", 604800.5],
    ["release_authorizations_count", -1],
    ["standing_fixture_sentinel", "23 of 23"],
    ["verification_admin", "someone@example.test"],
    ["lifecycle", "released"],
    ["case_status", "open"],
    ["checkpoint_version", 2],
    ["B1", "soon"],
  ])("a malformed %s is rejected", (field, value) => {
    expect(decodeCheckpoint({ ...CHECKPOINT, [field]: value }).ok).toBe(false);
  });

  it("a non-object is rejected", () => {
    for (const bad of [null, [], "{}", 7]) expect(decodeCheckpoint(bad as never).ok).toBe(false);
  });
});

describe("★ 2 · cross-field invariants", () => {
  it("release_eligible_at must be derived, not asserted", () => {
    const r = decodeCheckpoint({ ...CHECKPOINT, release_eligible_at: "2026-09-05T10:00:00.000Z" });
    expect(r.ok).toBe(false);
    expect(r.errors.join(" ")).toMatch(/release_eligible_at must equal/);
  });

  it("★ recommended_resume_after must keep the safety margin", () => {
    const tooEarly = new Date(
      Date.parse(CP.release_eligible_at) + RESUME_SAFETY_MARGIN_SECONDS * 1000 - 1
    ).toISOString();
    expect(decodeCheckpoint({ ...CHECKPOINT, recommended_resume_after: tooEarly }).ok).toBe(false);
    const exactly = new Date(
      Date.parse(CP.release_eligible_at) + RESUME_SAFETY_MARGIN_SECONDS * 1000
    ).toISOString();
    expect(decodeCheckpoint({ ...CHECKPOINT, recommended_resume_after: exactly }).ok).toBe(true);
  });

  it("★ reviewer A and reviewer B may not be the same uid", () => {
    const r = decodeCheckpoint({ ...CHECKPOINT, reviewer_b_uid: CHECKPOINT.reviewer_a_uid });
    expect(r.ok).toBe(false);
    expect(r.errors.join(" ")).toMatch(/must be distinct/);
  });

  it("the two operator PERSONAS may not be the same either", () => {
    expect(decodeCheckpoint({ ...CHECKPOINT, required_release_admin: "AW_ADMIN_TEST_A" }).ok).toBe(false);
  });

  it("stage markers must be gapless and ordered", () => {
    expect(decodeCheckpoint({ ...CHECKPOINT, B1: null }).ok).toBe(false); // B2 set, B1 null
    expect(decodeCheckpoint({ ...CHECKPOINT, B2: "2026-09-01T08:00:00.000Z" }).ok).toBe(false); // B2 < B1
    expect(decodeCheckpoint({ ...CHECKPOINT, B2: null }).ok).toBe(true); // trailing nulls are fine
  });

  it("★ a completed drill (B3 set) is not resumable", () => {
    const r = decodeCheckpoint({ ...CHECKPOINT, B3: "2026-09-08T10:10:00.000Z" });
    expect(r.ok).toBe(false);
    expect(r.errors.join(" ")).toMatch(/already complete/);
  });

  it("★ a checkpoint carrying a release authorization is not resumable", () => {
    expect(decodeCheckpoint({ ...CHECKPOINT, release_authorizations_count: 1 }).ok).toBe(false);
  });
});

describe("★ 3 · the checkpoint cannot carry a secret", () => {
  const serialized = JSON.stringify(CHECKPOINT);

  it("no address-shaped string", () => {
    expect(serialized).not.toMatch(/[\w.+-]+@[\w-]+\.[\w-]+/);
  });

  it("no secret-shaped string", () => {
    expect(serialized).not.toMatch(/sb_secret|service_role|eyJ[A-Za-z0-9_-]{10,}|PASSWORD|TOTP/i);
  });

  it("the operator fields hold PREFIXES, which is what makes the above true by shape", () => {
    expect(CP.verification_admin).toBe("AW_ADMIN_TEST_A");
    expect(decodeCheckpoint({ ...CHECKPOINT, verification_admin: "sb_secret_abc" }).ok).toBe(false);
  });
});

describe("★ 4 · the strict > window boundary", () => {
  it("★ now EXACTLY EQUAL to release_eligible_at is NOT ready", () => {
    const r = resume({}, CP.release_eligible_at);
    expect(r.failed).toEqual(["release_window_strictly_elapsed"]);
    expect(r.decision).toBe(RESUME.REFUSED);
  });

  it("★ now = release_eligible_at + 1ms IS ready", () => {
    const r = resume({}, new Date(Date.parse(CP.release_eligible_at) + 1).toISOString());
    expect(r.failed).toEqual([]);
    expect(r.decision).toBe(RESUME.ALLOWED);
  });

  it("one millisecond before is not ready", () => {
    const r = resume({}, new Date(Date.parse(CP.release_eligible_at) - 1).toISOString());
    expect(r.failed).toEqual(["release_window_strictly_elapsed"]);
  });

  it("the boundary pair genuinely straddles the door — the fixture precondition", () => {
    const eligible = Date.parse(CP.release_eligible_at);
    expect(Date.parse(READY_NOW)).toBe(eligible + 1);
    expect(eligible).toBe(Date.parse(OWNER_NOTIFIED) + SEVEN_DAYS_SECONDS * 1000);
  });

  it("recommended_resume_after sits safely past the door, and is harness-only", () => {
    expect(Date.parse(CP.recommended_resume_after)).toBe(
      Date.parse(CP.release_eligible_at) + RESUME_SAFETY_MARGIN_SECONDS * 1000
    );
    // The production duration is untouched by the margin.
    expect(CP.challenge_window_duration_seconds).toBe(SEVEN_DAYS_SECONDS);
  });

  it("an unusable clock refuses rather than passing", () => {
    expect(resume({}, "not-a-time").failed).toContain("clock_supplied");
  });
});

describe("★ 5 · production state must still match the checkpoint", () => {
  it.each([
    [{ estate_uuid: uid(2) }, "estate_matches"],
    [{ case_uuid: uid(1) }, "case_matches"],
    [{ case_status: "open" }, "case_status_is_verified"],
    [{ released_at: "2026-09-08T10:00:00.000Z" }, "not_released"],
    [{ release_authorizations_count: 1 }, "no_release_authorization_exists"],
    [{ halted_at: "2026-09-03T10:00:00.000Z" }, "owner_challenge_not_exercised"],
    [{ t2_verdict: "T2_PROVIDER_ACCEPTED_ONLY" }, "owner_email_delivery_established"],
    [{ t2_verdict: "T2_PENDING" }, "owner_email_delivery_established"],
    [{ standing_fixture_sentinel: "22/23" }, "standing_fixture_intact"],
    [{ source_deployment_drift_clean: false }, "source_deployment_drift_clean"],
    [{ deployed_contracts_clean: false }, "deployed_contracts_clean"],
    [{ api_sha: "0".repeat(40) }, "api_sha_unchanged"],
    [{ mobile_sha: "0".repeat(40) }, "mobile_sha_unchanged"],
    [{ admin_sha: "0".repeat(40) }, "admin_sha_unchanged"],
  ])("%o refuses, naming %s", (over, gateId) => {
    const r = resume(over as Record<string, unknown>);
    expect(r.decision).toBe(RESUME.REFUSED);
    expect(r.failed).toContain(gateId);
  });

  it("★ a halted lifecycle fails BOTH the state gate and the challenge gate", () => {
    const r = resume({ lifecycle: "challenge_halted", halted_at: "2026-09-03T10:00:00.000Z" });
    expect(r.failed).toContain("lifecycle_is_challenge_window");
    expect(r.failed).toContain("owner_challenge_not_exercised");
  });

  it("★ an UNOBSERVED fact is a failed gate, never a skipped one", () => {
    const r = evaluateResume({ checkpoint: CP, observed: {}, now: READY_NOW });
    expect(r.decision).toBe(RESUME.REFUSED);
    // Everything except the clock, the checkpoint-internal distinctness, and the strict window
    // (which read the checkpoint, not the world) must fail on an empty observation.
    expect(r.failed.length).toBeGreaterThanOrEqual(RESUME_GATE_IDS.length - 4);
  });

  it("★ a T2 verdict short of DELIVERED never clears the email gate", () => {
    for (const v of [
      "T2_PROVIDER_ACCEPTED_ONLY", "T2_DELIVERY_FAILED", "T2_DRAIN_DID_NOT_RUN",
      "T2_PENDING", "T2_UNVERIFIABLE", undefined, null, "delivered",
    ]) {
      expect(resume({ t2_verdict: v }).failed).toContain("owner_email_delivery_established");
    }
  });

  it("a sentinel that is internally short refuses even if it matches the checkpoint", () => {
    const short = decodeCheckpoint({ ...CHECKPOINT, standing_fixture_sentinel: "22/23" });
    expect(short.ok).toBe(true); // well-formed…
    const r = evaluateResume({
      checkpoint: short.checkpoint,
      observed: { ...OBSERVED, standing_fixture_sentinel: "22/23" },
      now: READY_NOW,
    });
    expect(r.failed).toContain("standing_fixture_intact"); // …but not intact
  });
});

describe("★ 6 · the two-person guard — TWO-PERSON CONTROL: SINGLE-OPERATOR TEST MODE", () => {
  it("★ the same uid in both seats refuses", () => {
    const r = resume({ case_decided_by: CP.reviewer_b_uid, acting_release_admin_uid: CP.reviewer_b_uid });
    expect(r.failed).toContain("observed_reviewers_distinct");
    expect(r.failed).toContain("reviewer_a_still_is_the_case_decider");
    expect(r.decision).toBe(RESUME.REFUSED);
  });

  it("★ SWAPPED identities refuse, and the swap is named as such", () => {
    const r = resume({ case_decided_by: CP.reviewer_b_uid, acting_release_admin_uid: CP.reviewer_a_uid });
    expect(r.failed).toContain("reviewer_identities_not_swapped");
    // Distinctness alone would have passed — which is exactly why the swap needs its own gate.
    expect(r.gates.find((g: { id: string }) => g.id === "observed_reviewers_distinct")!.pass).toBe(true);
  });

  it("★ an unexpected case decider refuses", () => {
    const r = resume({ case_decided_by: uid(9) });
    expect(r.failed).toContain("reviewer_a_still_is_the_case_decider");
  });

  it("★ an acting admin who is not reviewer B refuses", () => {
    const r = resume({ acting_release_admin_uid: uid(9) });
    expect(r.failed).toContain("acting_admin_is_reviewer_b");
  });

  it("★ a missing or insufficient AAL refuses", () => {
    for (const aal of ["aal1", undefined, null, ""]) {
      expect(resume({ acting_admin_aal: aal }).failed).toContain("acting_admin_has_aal2");
    }
  });

  it("a non-string identity cannot satisfy distinctness by being unequal to another non-string", () => {
    const r = resume({ case_decided_by: undefined, acting_release_admin_uid: null });
    expect(r.failed).toContain("observed_reviewers_distinct");
  });
});

describe("7 · deriveWindowInstants", () => {
  it("derives both instants from the dispatch fact", () => {
    expect(WINDOW.release_eligible_at).toBe("2026-09-08T10:00:00.000Z");
    expect(WINDOW.recommended_resume_after).toBe("2026-09-08T10:05:00.000Z");
  });
  it("refuses nonsense rather than returning a plausible instant", () => {
    expect(deriveWindowInstants("nope", SEVEN_DAYS_SECONDS)).toBeNull();
    expect(deriveWindowInstants(OWNER_NOTIFIED, 0)).toBeNull();
    expect(deriveWindowInstants(OWNER_NOTIFIED, -1)).toBeNull();
  });
});
