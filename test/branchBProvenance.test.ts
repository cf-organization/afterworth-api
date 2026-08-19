/**
 * PHASE 11-P.5 · THE SESSION-2 PROVENANCE ADDENDUM — CONTROLS.
 *
 * ★ THE REAL COMMITTED ARTIFACTS ARE THE FIXTURE. `docs/phase11p-branchb-session1-checkpoint.json`
 *   and `docs/phase11p5-branchb-session15-provenance.json` are read from disk, not reconstructed
 *   here. A reconstructed artifact agrees with whatever the test author believed, which is exactly
 *   how an invented vocabulary confirms its own bug — and the binding under test IS the digest of
 *   the real bytes, so a hand-built copy could not exercise it at all.
 *
 * ★ NO SOCKET. Every collector test injects its transport. The two selectors that parse real API
 *   payload shapes are PURE and are executed as the production default, not as a mock.
 */
import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import {
  RESUME,
  RESUME_GATE_IDS,
  decodeCheckpoint,
  evaluateResume,
} from "../scripts/lib/branchBCheckpoint.mjs";
import { findForbiddenStrings } from "../scripts/lib/branchBBaseline.mjs";
import {
  EXPECTABLE_SOURCE_KINDS,
  LEGACY_SHA_GATE_STATUS,
  OBSERVABLE_SOURCE_KINDS,
  OPERATOR_RULING_ID,
  PROVENANCE_COMPONENTS,
  PROVENANCE_SCHEMA_VERSION,
  SESSION2,
  SOURCE_KINDS,
  SUPERSEDED_LEGACY_GATE_IDS,
  compareProvenance,
  decodeProvenanceAddendum,
  evaluateSession2Resume,
  sha256Bytes,
} from "../scripts/lib/branchBProvenance.mjs";
import {
  collectLocalCheckout,
  collectProductionDeployment,
  collectSession2Provenance,
  collectSourceRevision,
  selectRefSha,
  selectSuccessfulProductionDeployment,
} from "../scripts/lib/branchBObservation.mjs";

const CHECKPOINT_URL = new URL("../docs/phase11p-branchb-session1-checkpoint.json", import.meta.url);
const ADDENDUM_URL = new URL("../docs/phase11p5-branchb-session15-provenance.json", import.meta.url);

const CHECKPOINT_BYTES = readFileSync(CHECKPOINT_URL);
const ADDENDUM_RAW = JSON.parse(readFileSync(ADDENDUM_URL, "utf8"));

const cpDecoded = decodeCheckpoint(JSON.parse(CHECKPOINT_BYTES.toString("utf8")));
const CP = (cpDecoded.ok ? cpDecoded.checkpoint : {}) as Record<string, string>;
const addDecoded = decodeProvenanceAddendum(ADDENDUM_RAW);
const ADD = (addDecoded.ok ? addDecoded.addendum : {}) as any;

/** The three reviewed Session-2 revisions, read from the artifact rather than retyped. */
const API_SESSION2 = "9f06a86d4407f0937289fced68213d5ff4443dcc";
const MOBILE_SESSION2 = "58268bfcd9970200cdc0cedca37dac9780db0d87";
const ADMIN_PRODUCTION = "cd044fec7327a180afd589c70690741bafaaff2e";
const ADMIN_FOREIGN_LOCAL = "fd7ef03587d06b4c4a182575c5e7717412d82e2a";

/** A production observation that satisfies every legacy non-SHA gate, so SHA/provenance is isolated. */
const IDEAL_OBSERVED = Object.freeze({
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
});

const HONEST_PROVENANCE = Object.freeze({
  api_branch_b_source: {
    sha: API_SESSION2,
    source_kind: SOURCE_KINDS.SOURCE_REVISION,
    repo: "cf-organization/afterworth-api",
    ref: "refs/heads/main",
  },
  mobile_branch_b_source: {
    sha: MOBILE_SESSION2,
    source_kind: SOURCE_KINDS.SOURCE_REVISION,
    repo: "cf-organization/afterworth-mobile",
    ref: "refs/heads/main",
  },
  admin_console_production: {
    sha: ADMIN_PRODUCTION,
    source_kind: SOURCE_KINDS.PRODUCTION_DEPLOYMENT,
    repo: "cf-organization/afterworth-admin",
    environment: "Production",
    state: "success",
  },
});

const READY_NOW = new Date(Date.parse(CP.release_eligible_at as string) + 1).toISOString();

const session2 = (
  provenanceOver: Record<string, unknown> = {},
  addendumOver: Record<string, unknown> = {},
  observedOver: Record<string, unknown> = {},
  bytes: Buffer | string = CHECKPOINT_BYTES
) =>
  evaluateSession2Resume({
    legacyEvaluateResume: evaluateResume,
    checkpoint: CP,
    checkpointBytes: bytes,
    addendumRaw: { ...ADDENDUM_RAW, ...addendumOver },
    observed: { ...IDEAL_OBSERVED, ...observedOver },
    observedProvenance: { ...HONEST_PROVENANCE, ...provenanceOver },
    now: READY_NOW,
  });

/* ══════════════════════════════════════════════════════════════════════════════════════════════ */

describe("0 · the fixtures are controls, not decoration", () => {
  it("the REAL frozen checkpoint decodes", () => {
    expect(cpDecoded.ok, JSON.stringify((cpDecoded as { errors?: string[] }).errors)).toBe(true);
  });

  it("the REAL committed addendum decodes strictly", () => {
    expect(addDecoded.ok, JSON.stringify((addDecoded as { errors?: string[] }).errors)).toBe(true);
  });

  it("the ideal observation clears every legacy NON-SHA gate — so SHA failures are never incidental", () => {
    const legacy = evaluateResume({
      checkpoint: CP,
      observed: {
        ...IDEAL_OBSERVED,
        api_sha: CP.api_sha,
        mobile_sha: CP.mobile_sha,
        admin_sha: CP.admin_sha,
      },
      now: READY_NOW,
    });
    expect(legacy.decision).toBe(RESUME.ALLOWED);
  });

  it("the addendum carries no address-shaped or secret-shaped string, at any depth", () => {
    expect(findForbiddenStrings(ADDENDUM_RAW)).toEqual([]);
  });
});

describe("1 · the binding to the frozen checkpoint", () => {
  it("the addendum's digest IS the digest of the real checkpoint bytes on disk", () => {
    expect(ADD.branch_b_checkpoint_sha256).toBe(sha256Bytes(CHECKPOINT_BYTES));
  });

  it("the binding gate passes on the real bytes", () => {
    const r = session2();
    expect(r.gates.find((g: any) => g.id === "checkpoint_hash_bound")?.pass).toBe(true);
  });

  it("★ ONE MUTATED BYTE OF THE CHECKPOINT REFUSES — the frozen evidence cannot be rewritten", () => {
    const tampered = CHECKPOINT_BYTES.toString("utf8").replace(
      '"release_authorizations_count": 0',
      '"release_authorizations_count": 1'
    );
    expect(tampered).not.toBe(CHECKPOINT_BYTES.toString("utf8")); // the edit actually landed
    const r = session2({}, {}, {}, tampered);
    expect(r.failed).toContain("checkpoint_hash_bound");
    expect(r.decision).toBe(SESSION2.REFUSED);
  });

  it("an absent checkpoint byte-stream refuses rather than skipping the binding", () => {
    const r = evaluateSession2Resume({
      legacyEvaluateResume: evaluateResume,
      checkpoint: CP,
      checkpointBytes: null,
      addendumRaw: ADDENDUM_RAW,
      observed: IDEAL_OBSERVED,
      observedProvenance: HONEST_PROVENANCE,
      now: READY_NOW,
    });
    expect(r.failed).toContain("checkpoint_hash_bound");
  });
});

describe("2 · the closed source-kind vocabulary is the containment mechanism", () => {
  it("local_checkout is OBSERVABLE but never EXPECTABLE", () => {
    expect(OBSERVABLE_SOURCE_KINDS).toContain(SOURCE_KINDS.LOCAL_CHECKOUT);
    expect(EXPECTABLE_SOURCE_KINDS).not.toContain(SOURCE_KINDS.LOCAL_CHECKOUT);
  });

  it("★ fd7ef03 CANNOT be declared production_deployment — the sha is simply wrong for that source", () => {
    const addendum = structuredClone(ADDENDUM_RAW);
    addendum.session2_provenance.admin_console_production.sha = ADMIN_FOREIGN_LOCAL;
    const r = session2({}, addendum);
    expect(r.failed).toContain("provenance_admin_console_production");
  });

  it("★ nor relabelled local_checkout — the schema refuses the expectation outright", () => {
    const addendum = structuredClone(ADDENDUM_RAW);
    addendum.session2_provenance.admin_console_production.source_kind = SOURCE_KINDS.LOCAL_CHECKOUT;
    addendum.session2_provenance.admin_console_production.sha = ADMIN_FOREIGN_LOCAL;
    const d = decodeProvenanceAddendum(addendum);
    expect(d.ok).toBe(false);
    expect(JSON.stringify(d.errors)).toContain("a working-tree HEAD is never provenance");
  });

  it("an unknown source kind is refused in an expectation and in an observation", () => {
    const addendum = structuredClone(ADDENDUM_RAW);
    addendum.session2_provenance.api_branch_b_source.source_kind = "vibes";
    expect(decodeProvenanceAddendum(addendum).ok).toBe(false);

    const r = session2({
      api_branch_b_source: { ...HONEST_PROVENANCE.api_branch_b_source, source_kind: "vibes" },
    });
    expect(r.failed).toContain("provenance_api_branch_b_source");
  });

  it("a production_deployment expectation must name Production", () => {
    const addendum = structuredClone(ADDENDUM_RAW);
    addendum.session2_provenance.admin_console_production.environment = "Preview";
    expect(decodeProvenanceAddendum(addendum).ok).toBe(false);
  });
});

describe("3 · source kind is load-bearing, checked BEFORE the sha", () => {
  it("★ the RIGHT sha from the WRONG source still refuses", () => {
    const r = session2({
      admin_console_production: {
        sha: ADMIN_PRODUCTION, // correct value
        source_kind: SOURCE_KINDS.LOCAL_CHECKOUT, // wrong source
        repo: "cf-organization/afterworth-admin",
      },
    });
    expect(r.failed).toContain("provenance_admin_console_production");
    const g = r.gates.find((x: any) => x.id === "provenance_admin_console_production");
    expect(g?.detail).toContain("observation_source_kind_wrong");
  });

  it("a source_revision from the wrong ref refuses", () => {
    const r = session2({
      api_branch_b_source: { ...HONEST_PROVENANCE.api_branch_b_source, ref: "refs/heads/release" },
    });
    expect(r.failed).toContain("provenance_api_branch_b_source");
  });

  it("a source_revision from the wrong repo refuses", () => {
    const r = session2({
      api_branch_b_source: { ...HONEST_PROVENANCE.api_branch_b_source, repo: "cf-organization/afterworth-admin" },
    });
    expect(r.failed).toContain("provenance_api_branch_b_source");
  });

  it("a non-Production deployment refuses even when successful", () => {
    const r = session2({
      admin_console_production: { ...HONEST_PROVENANCE.admin_console_production, environment: "Preview" },
    });
    const g = r.gates.find((x: any) => x.id === "provenance_admin_console_production");
    expect(g?.detail).toContain("deployment_environment_wrong");
  });

  it("an unsuccessful Production deployment refuses", () => {
    for (const state of ["failure", "error", "in_progress", "pending", undefined]) {
      const r = session2({
        admin_console_production: { ...HONEST_PROVENANCE.admin_console_production, state },
      });
      const g = r.gates.find((x: any) => x.id === "provenance_admin_console_production");
      expect(g?.pass, `state=${state}`).toBe(false);
      expect(g?.detail).toContain("deployment_not_successful");
    }
  });

  it("★ a MISSING observation refuses by name — unavailable is never 'unchanged'", () => {
    for (const name of PROVENANCE_COMPONENTS) {
      const r = session2({ [name]: null });
      expect(r.failed, name).toContain(`provenance_${name}`);
      expect(r.gates.find((g: any) => g.id === `provenance_${name}`)?.detail).toContain(
        "observation_missing"
      );
    }
  });
});

describe("4 · STAGE 12 — the original impossibility, kept as a regression", () => {
  it("★ the legacy pins and the reviewed Session-2 revisions are DIFFERENT VALUES, by construction", () => {
    // The checkpoint was added by the commit whose parent it pins, so an honest observation of the
    // source that CONTAINS the checkpoint can never equal the pin. This is not drift to be waited
    // out; it is a fixed property of the artifact.
    expect(ADD.legacy_checkpoint_provenance.api_sha).not.toBe(API_SESSION2);
    expect(ADD.legacy_checkpoint_provenance.mobile_sha).not.toBe(MOBILE_SESSION2);
    expect(ADD.legacy_checkpoint_provenance.api_sha).toBe(CP.api_sha);
    expect(ADD.legacy_checkpoint_provenance.mobile_sha).toBe(CP.mobile_sha);
  });

  it("★ legacy strict equality REFUSES the honest observation — do not 'simplify' Session 2 back to it", () => {
    const legacy = evaluateResume({
      checkpoint: CP,
      observed: {
        ...IDEAL_OBSERVED,
        api_sha: API_SESSION2,
        mobile_sha: MOBILE_SESSION2,
        admin_sha: ADMIN_PRODUCTION,
      },
      now: READY_NOW,
    });
    expect(legacy.decision).toBe(RESUME.REFUSED);
    expect(legacy.failed).toEqual(
      expect.arrayContaining(["api_sha_unchanged", "mobile_sha_unchanged", "admin_sha_unchanged"])
    );
  });

  it("★ the Session-2 evaluator ACCEPTS that same honest observation", () => {
    const r = session2();
    for (const name of PROVENANCE_COMPONENTS) {
      expect(r.failed, name).not.toContain(`provenance_${name}`);
    }
  });
});

describe("5 · STAGE 13 — the admin false admission, proven both ways", () => {
  const FALSE_ADMISSION_WORLD = {
    checkpoint_admin: ADMIN_FOREIGN_LOCAL,
    local_checkout: ADMIN_FOREIGN_LOCAL,
    production: ADMIN_PRODUCTION,
  };

  it("★ the LEGACY gate PASSES on the stale foreign checkout — the hazard is real, not hypothetical", () => {
    expect(CP.admin_sha).toBe(FALSE_ADMISSION_WORLD.checkpoint_admin);
    const legacy = evaluateResume({
      checkpoint: CP,
      observed: {
        ...IDEAL_OBSERVED,
        api_sha: CP.api_sha,
        mobile_sha: CP.mobile_sha,
        admin_sha: FALSE_ADMISSION_WORLD.local_checkout,
      },
      now: READY_NOW,
    });
    expect(legacy.gates.find((g: any) => g.id === "admin_sha_unchanged")?.pass).toBe(true);
    expect(legacy.decision).toBe(RESUME.ALLOWED);
  });

  it("★ the SESSION-2 gate REFUSES the same world, and names the source as the reason", () => {
    const r = session2({
      admin_console_production: {
        sha: FALSE_ADMISSION_WORLD.local_checkout,
        source_kind: SOURCE_KINDS.LOCAL_CHECKOUT,
        repo: "cf-organization/afterworth-admin",
      },
    });
    expect(r.failed).toContain("provenance_admin_console_production");
    expect(r.decision).toBe(SESSION2.REFUSED);
  });

  it("★ a collector wired to the working tree is DETECTED, not silently accepted", () => {
    const observed = collectLocalCheckout({
      repoPath: "/anywhere",
      repo: "cf-organization/afterworth-admin",
      git: () => `${ADMIN_FOREIGN_LOCAL}\n`,
    });
    expect(observed?.source_kind).toBe(SOURCE_KINDS.LOCAL_CHECKOUT);
    const verdict = compareProvenance(observed, ADD.session2_provenance.admin_console_production);
    expect(verdict.pass).toBe(false);
    expect(verdict.code).toBe("observation_source_kind_wrong");
  });

  it("the production collector returns cd044fe for this world, never fd7ef03", () => {
    const gh = (args: string[]) => {
      if (args[0].includes("/deployments?")) {
        return JSON.stringify([
          { id: 1, sha: ADMIN_PRODUCTION, environment: "Production", created_at: "2026-08-18T00:15:35Z" },
          { id: 2, sha: ADMIN_FOREIGN_LOCAL, environment: "Production", created_at: "2026-08-13T20:06:28Z" },
        ]);
      }
      return JSON.stringify([{ state: "success", created_at: "2026-08-18T00:16:00Z" }]);
    };
    const o = collectProductionDeployment({
      repo: "cf-organization/afterworth-admin",
      environment: "Production",
      gh,
    });
    expect(o?.sha).toBe(ADMIN_PRODUCTION);
    expect(o?.source_kind).toBe(SOURCE_KINDS.PRODUCTION_DEPLOYMENT);
  });
});

describe("6 · STAGE 14 — the mobile false refusal is cured by pinning a REVIEWED revision", () => {
  it("legacy equality refuses the evidence-only advance", () => {
    const legacy = evaluateResume({
      checkpoint: CP,
      observed: { ...IDEAL_OBSERVED, api_sha: CP.api_sha, mobile_sha: MOBILE_SESSION2, admin_sha: CP.admin_sha },
      now: READY_NOW,
    });
    expect(legacy.failed).toContain("mobile_sha_unchanged");
  });

  it("★ the addendum accepts it because it is PINNED and REVIEWED — not because it looked harmless", () => {
    // The cure is an explicit reviewed pin, never an inference from a commit message. Any OTHER
    // mobile revision — including a later main — still refuses.
    expect(ADD.session2_provenance.mobile_branch_b_source.sha).toBe(MOBILE_SESSION2);
    expect(session2().failed).not.toContain("provenance_mobile_branch_b_source");

    const r = session2({
      mobile_branch_b_source: { ...HONEST_PROVENANCE.mobile_branch_b_source, sha: "c".repeat(40) },
    });
    expect(r.failed).toContain("provenance_mobile_branch_b_source");
    expect(r.gates.find((g: any) => g.id === "provenance_mobile_branch_b_source")?.detail).toContain(
      "provenance_sha_changed"
    );
  });
});

describe("7 · STAGE 11 — every non-SHA gate survives, and exactly three do not", () => {
  it("the supersession list is exactly the three SHA gate ids", () => {
    expect([...SUPERSEDED_LEGACY_GATE_IDS]).toEqual([
      "api_sha_unchanged",
      "mobile_sha_unchanged",
      "admin_sha_unchanged",
    ]);
  });

  it("★ retained = every legacy gate MINUS exactly those three, by id", () => {
    const r = session2();
    const expectedRetained = RESUME_GATE_IDS.filter(
      (id: string) => !SUPERSEDED_LEGACY_GATE_IDS.includes(id)
    );
    expect([...r.retained_legacy_gates].sort()).toEqual([...expectedRetained].sort());
    expect([...r.superseded_legacy_gates].sort()).toEqual([...SUPERSEDED_LEGACY_GATE_IDS].sort());
    expect(r.retained_legacy_gates.length).toBe(RESUME_GATE_IDS.length - 3);
  });

  it("★ every retained gate still REFUSES when its fact goes bad", () => {
    const probes: Array<[Record<string, unknown>, string]> = [
      [{ estate_uuid: "00000000-0000-4000-8000-000000000009" }, "estate_matches"],
      [{ case_status: "open" }, "case_status_is_verified"],
      [{ released_at: "2026-09-08T10:00:00.000Z" }, "not_released"],
      [{ release_authorizations_count: 1 }, "no_release_authorization_exists"],
      [{ halted_at: "2026-09-03T10:00:00.000Z" }, "owner_challenge_not_exercised"],
      [{ t2_verdict: "T2_PENDING" }, "owner_email_delivery_established"],
      [{ standing_fixture_sentinel: "22/23" }, "standing_fixture_intact"],
      [{ source_deployment_drift_clean: false }, "source_deployment_drift_clean"],
      [{ deployed_contracts_clean: false }, "deployed_contracts_clean"],
      [{ acting_admin_aal: "aal1" }, "acting_admin_has_aal2"],
    ];
    for (const [over, gateId] of probes) {
      const r = session2({}, {}, over);
      expect(r.failed, gateId).toContain(gateId);
      expect(r.decision).toBe(SESSION2.REFUSED);
    }
  });

  it("★ a superseded id that no longer exists in the legacy evaluator is a CONTRACT BREAK", () => {
    const renamed = (input: any) => {
      const out = evaluateResume(input);
      return {
        ...out,
        gates: out.gates.filter((g: any) => g.id !== "admin_sha_unchanged"),
      };
    };
    const r = evaluateSession2Resume({
      legacyEvaluateResume: renamed,
      checkpoint: CP,
      checkpointBytes: CHECKPOINT_BYTES,
      addendumRaw: ADDENDUM_RAW,
      observed: IDEAL_OBSERVED,
      observedProvenance: HONEST_PROVENANCE,
      now: READY_NOW,
    });
    expect(r.failed).toContain("supersession_targets_exist");
  });

  /**
   * ★ THE WILDCARD MUTANT IS INVISIBLE WITHOUT THIS CONTROL, AND THAT IS WHY IT NEEDS ONE.
   *
   * `/_sha_/` selects exactly the same three ids as the frozen list does TODAY, so every existing
   * assertion passes with it in place. What it would also swallow is a gate added LATER whose name
   * happens to contain `_sha_` — plausibly one added to close a hole, silently superseded by a
   * pattern written years earlier. So the control introduces exactly such a gate and requires it to
   * SURVIVE.
   */
  it("★ a NEW gate whose id contains '_sha_' is RETAINED — supersession is by exact id, never a pattern", () => {
    const withExtraGate = (input: any) => {
      const out = evaluateResume(input);
      return {
        ...out,
        gates: [...out.gates, { id: "pre_release_payload_sha_verified", pass: true, detail: "control" }],
      };
    };
    const r = evaluateSession2Resume({
      legacyEvaluateResume: withExtraGate,
      checkpoint: CP,
      checkpointBytes: CHECKPOINT_BYTES,
      addendumRaw: ADDENDUM_RAW,
      observed: IDEAL_OBSERVED,
      observedProvenance: HONEST_PROVENANCE,
      now: READY_NOW,
    });
    expect(r.retained_legacy_gates).toContain("pre_release_payload_sha_verified");
    expect(r.superseded_legacy_gates).not.toContain("pre_release_payload_sha_verified");
    expect(r.superseded_legacy_gates.length).toBe(3);
  });

  it("the two-person-control banner is carried through, in both directions", () => {
    expect(session2().two_person_control).toBe("TWO-PERSON CONTROL: SINGLE-OPERATOR TEST MODE");
    expect(session2({ api_branch_b_source: null }).two_person_control).toBe(
      "TWO-PERSON CONTROL: SINGLE-OPERATOR TEST MODE"
    );
  });
});

describe("8 · STAGE 19 — the resume instrument is a separate, fail-closed fact", () => {
  it("★ a NULL instrument refuses rather than defaulting to the branch-b source revision", () => {
    expect(ADD.resume_instrument).toBe(null);
    const r = session2();
    expect(r.failed).toContain("resume_instrument_pinned");
  });

  it("once pinned it is compared like any other provenance fact", () => {
    const addendum = structuredClone(ADDENDUM_RAW);
    addendum.resume_instrument = {
      sha: "d".repeat(40),
      source_kind: SOURCE_KINDS.SOURCE_REVISION,
      repo: "cf-organization/afterworth-api",
      ref: "refs/heads/main",
      semantic: "Session-2 resume instrument revision, pinned after the remediation merged.",
    };
    const ok = session2(
      {
        resume_instrument: {
          sha: "d".repeat(40),
          source_kind: SOURCE_KINDS.SOURCE_REVISION,
          repo: "cf-organization/afterworth-api",
          ref: "refs/heads/main",
        },
      },
      addendum
    );
    expect(ok.failed).not.toContain("resume_instrument_pinned");

    const wrong = session2(
      {
        resume_instrument: {
          sha: "e".repeat(40),
          source_kind: SOURCE_KINDS.SOURCE_REVISION,
          repo: "cf-organization/afterworth-api",
          ref: "refs/heads/main",
        },
      },
      addendum
    );
    expect(wrong.failed).toContain("resume_instrument_pinned");
  });

  it("★ it is NOT overloaded onto api_branch_b_source — the two are distinct fields", () => {
    expect(ADD.session2_provenance.api_branch_b_source.sha).toBe(API_SESSION2);
    expect(Object.keys(ADD.session2_provenance)).not.toContain("resume_instrument");
  });
});

describe("9 · the strict addendum decoder", () => {
  it("an UNKNOWN top-level field fails", () => {
    const d = decodeProvenanceAddendum({ ...ADDENDUM_RAW, extra_note: "harmless" });
    expect(d.ok).toBe(false);
    expect(JSON.stringify(d.errors)).toContain("unknown field: extra_note");
  });

  it("an UNKNOWN component field fails", () => {
    const a = structuredClone(ADDENDUM_RAW);
    a.session2_provenance.api_branch_b_source.deployed_at = "2026-08-19T00:00:00Z";
    expect(decodeProvenanceAddendum(a).ok).toBe(false);
  });

  it.each([
    "schema_version",
    "created_at",
    "operator_ruling",
    "branch_b_checkpoint_sha256",
    "legacy_checkpoint_provenance",
    "legacy_sha_gate_status",
    "superseded_gate_ids",
    "session2_provenance",
    "resume_instrument",
  ])("a MISSING %s fails", (field) => {
    const a = structuredClone(ADDENDUM_RAW);
    delete a[field];
    const d = decodeProvenanceAddendum(a);
    expect(d.ok).toBe(false);
    expect(JSON.stringify(d.errors)).toContain(`missing field: ${field}`);
  });

  it.each([
    ["schema_version", 2],
    ["operator_ruling", "SOME_OTHER_RULING"],
    ["legacy_sha_gate_status", "superseded"],
    ["branch_b_checkpoint_sha256", "abc"],
    ["created_at", "yesterday"],
  ])("a malformed %s fails", (field, value) => {
    expect(decodeProvenanceAddendum({ ...ADDENDUM_RAW, [field]: value }).ok).toBe(false);
  });

  it("★ a WIDENED superseded_gate_ids list fails — supersession cannot be broadened by data", () => {
    for (const bad of [
      ["api_sha_unchanged", "mobile_sha_unchanged", "admin_sha_unchanged", "not_released"],
      ["api_sha_unchanged", "mobile_sha_unchanged"],
      ["admin_sha_unchanged", "mobile_sha_unchanged", "api_sha_unchanged"],
      "api_sha_unchanged",
    ]) {
      expect(decodeProvenanceAddendum({ ...ADDENDUM_RAW, superseded_gate_ids: bad }).ok).toBe(false);
    }
  });

  it("a missing component fails, and a component cannot be dropped to disable its gate", () => {
    const a = structuredClone(ADDENDUM_RAW);
    delete a.session2_provenance.admin_console_production;
    const d = decodeProvenanceAddendum(a);
    expect(d.ok).toBe(false);
    const r = session2({}, a);
    expect(r.failed).toContain("addendum_decoded");
    expect(r.failed).toContain("provenance_admin_console_production");
  });

  it("the constants are what the artifact declares", () => {
    expect(ADD.schema_version).toBe(PROVENANCE_SCHEMA_VERSION);
    expect(ADD.operator_ruling).toBe(OPERATOR_RULING_ID);
    expect(ADD.legacy_sha_gate_status).toBe(LEGACY_SHA_GATE_STATUS);
  });
});

describe("10 · the collector selectors, run as the production default", () => {
  it("selectRefSha accepts a real-shaped ref payload", () => {
    const payload = {
      ref: "refs/heads/main",
      object: { type: "commit", sha: API_SESSION2 },
    };
    expect(selectRefSha(payload, "refs/heads/main")).toBe(API_SESSION2);
  });

  it("★ selectRefSha refuses a ref it did not ask for, and a non-commit object", () => {
    expect(
      selectRefSha({ ref: "refs/heads/main-old", object: { type: "commit", sha: API_SESSION2 } }, "refs/heads/main")
    ).toBe(null);
    expect(
      selectRefSha({ ref: "refs/heads/main", object: { type: "tag", sha: API_SESSION2 } }, "refs/heads/main")
    ).toBe(null);
    expect(selectRefSha(null, "refs/heads/main")).toBe(null);
  });

  /**
   * ★ THE FIXTURE IS DELIBERATELY OUT OF ORDER AND INTERLEAVED. The wanted deployment is neither
   *   first in the list nor the newest overall: a newer successful PREVIEW and a newer FAILED
   *   Production sit above it. A fixture already in the right order would pass with the sort and the
   *   filters deleted, and could not fail when they were.
   */
  const DEPLOYMENTS = [
    { id: 10, sha: "a".repeat(40), environment: "Preview", created_at: "2026-08-19T13:26:52Z" },
    { id: 11, sha: "b".repeat(40), environment: "Production", created_at: "2026-08-19T09:00:00Z" },
    { id: 12, sha: ADMIN_PRODUCTION, environment: "Production", created_at: "2026-08-18T00:15:35Z" },
    { id: 13, sha: ADMIN_FOREIGN_LOCAL, environment: "Production", created_at: "2026-08-13T20:06:28Z" },
  ];
  const STATUSES = {
    "10": [{ state: "success", created_at: "2026-08-19T13:27:00Z" }],
    "11": [{ state: "failure", created_at: "2026-08-19T09:01:00Z" }],
    "12": [{ state: "success", created_at: "2026-08-18T00:16:00Z" }],
    "13": [{ state: "success", created_at: "2026-08-13T20:07:00Z" }],
  };

  it("the fixture precondition holds — the wanted row is NOT first and NOT newest", () => {
    expect(DEPLOYMENTS[0].sha).not.toBe(ADMIN_PRODUCTION);
    const newest = [...DEPLOYMENTS].sort(
      (a, b) => Date.parse(b.created_at) - Date.parse(a.created_at)
    )[0];
    expect(newest.sha).not.toBe(ADMIN_PRODUCTION);
  });

  it("★ it selects the newest SUCCESSFUL PRODUCTION deployment, skipping Preview and failure", () => {
    const r = selectSuccessfulProductionDeployment(DEPLOYMENTS, STATUSES, "Production");
    expect(r?.sha).toBe(ADMIN_PRODUCTION);
    expect(r?.state).toBe("success");
    expect(r?.environment).toBe("Production");
  });

  it("★ a deployment whose status could not be read is SKIPPED, never assumed successful", () => {
    const r = selectSuccessfulProductionDeployment(DEPLOYMENTS, { ...STATUSES, "12": [] }, "Production");
    expect(r?.sha).toBe(ADMIN_FOREIGN_LOCAL); // falls through to the next SUCCESSFUL one, not to 12
    const none = selectSuccessfulProductionDeployment(DEPLOYMENTS, {}, "Production");
    expect(none).toBe(null);
  });

  it("no Production deployment at all returns null, never a Preview", () => {
    const previewOnly = DEPLOYMENTS.filter((d) => d.environment === "Preview");
    expect(selectSuccessfulProductionDeployment(previewOnly, STATUSES, "Production")).toBe(null);
  });

  it("★ a transport failure returns null — the collector never invents a revision", () => {
    const boom = () => {
      throw new Error("gh unavailable");
    };
    expect(collectSourceRevision({ repo: "o/r", ref: "refs/heads/main", gh: boom })).toBe(null);
    expect(collectProductionDeployment({ repo: "o/r", environment: "Production", gh: boom })).toBe(null);
    expect(collectLocalCheckout({ repoPath: "/x", repo: "o/r", git: boom })).toBe(null);
  });

  /**
   * ★ THE ORCHESTRATOR IS WHERE "UNAVAILABLE" WOULD BECOME "UNCHANGED". The individual collectors
   *   are proven to return null above, but a substitution added one level up — filling a failed
   *   component from the expectation it was supposed to verify — would leave all of those green.
   *   So the transport is failed HERE, through the real orchestrator, and the null must survive all
   *   the way into a REFUSAL.
   */
  it("★ a component whose transport fails stays NULL through the orchestrator, and refuses", () => {
    const ghFailsAdmin = (args: string[]) => {
      if (args[0].includes("afterworth-admin")) throw new Error("deployment metadata unavailable");
      if (args[0].includes("/git/ref/")) {
        const ref = `refs/${args[0].split("/git/ref/")[1]}`;
        const sha = args[0].includes("afterworth-api") ? API_SESSION2 : MOBILE_SESSION2;
        return JSON.stringify({ ref, object: { type: "commit", sha } });
      }
      return "[]";
    };
    const collected = collectSession2Provenance({ addendum: ADD, gh: ghFailsAdmin });

    // it must be NULL — not backfilled from the expectation it exists to check
    expect(collected.admin_console_production).toBe(null);
    expect(collected.admin_console_production).not.toMatchObject({ sha: ADMIN_PRODUCTION });
    // the components that DID resolve are still correct, so this is a targeted failure not a total one
    expect(collected.api_branch_b_source?.sha).toBe(API_SESSION2);

    const r = session2(collected as Record<string, unknown>);
    expect(r.failed).toContain("provenance_admin_console_production");
    expect(r.gates.find((g: any) => g.id === "provenance_admin_console_production")?.detail).toContain(
      "observation_missing"
    );
    expect(r.decision).toBe(SESSION2.REFUSED);
  });

  it("★ the expectation chooses the collector — every component is driven by the addendum", () => {
    const calls: string[] = [];
    const gh = (args: string[]) => {
      calls.push(args[0]);
      if (args[0].includes("/git/ref/")) {
        const ref = `refs/${args[0].split("/git/ref/")[1]}`;
        const sha = args[0].includes("afterworth-api") ? API_SESSION2 : MOBILE_SESSION2;
        return JSON.stringify({ ref, object: { type: "commit", sha } });
      }
      if (args[0].includes("/deployments?")) {
        return JSON.stringify([
          { id: 12, sha: ADMIN_PRODUCTION, environment: "Production", created_at: "2026-08-18T00:15:35Z" },
        ]);
      }
      return JSON.stringify([{ state: "success", created_at: "2026-08-18T00:16:00Z" }]);
    };
    const collected = collectSession2Provenance({ addendum: ADD, gh });
    expect(collected.api_branch_b_source?.sha).toBe(API_SESSION2);
    expect(collected.mobile_branch_b_source?.sha).toBe(MOBILE_SESSION2);
    expect(collected.admin_console_production?.sha).toBe(ADMIN_PRODUCTION);
    // the admin component was collected through the DEPLOYMENT path, never a ref lookup
    expect(calls.some((c) => c.includes("afterworth-admin/git/ref/"))).toBe(false);
    expect(calls.some((c) => c.includes("afterworth-admin/deployments?"))).toBe(true);

    const r = session2(collected as Record<string, unknown>);
    for (const name of PROVENANCE_COMPONENTS) expect(r.failed, name).not.toContain(`provenance_${name}`);
  });
});

describe("11 · determinism", () => {
  it("★ two evaluations in one process are identical — the guard against stateful matchers", () => {
    const a = session2();
    const b = session2();
    expect(JSON.stringify(a.gates)).toBe(JSON.stringify(b.gates));
    expect(a.decision).toBe(b.decision);
  });

  it("two strict decodes of the same artifact are identical", () => {
    expect(JSON.stringify(decodeProvenanceAddendum(ADDENDUM_RAW))).toBe(
      JSON.stringify(decodeProvenanceAddendum(ADDENDUM_RAW))
    );
  });
});
