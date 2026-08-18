/**
 * PHASE 11-OC / PHASE D · THE VERIFIER'S SUMMARY MAY NOT CONTRADICT ITS OWN VERDICT.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ THIS SUITE EXISTS BECAUSE THE DEFECT SHIPPED, AND SHIPPED GREEN.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * Run against production before the Phase D paste, `verifyPhaseDDeployment.mjs` printed:
 *
 *     PROVED   : the Phase D release authority is deployed, shared by the projection and the
 *                door, gated, and anchored on the acceptance fact rather than on provenance.
 *     …
 *     ✗ PHASE D NOT VERIFIED — 2 assertion(s) failed. Deployment state: PHASE_C_STILL_ACTIVE.
 *
 * Every CHECK was correct. The SUMMARY asserted the opposite, three lines above the verdict, on the
 * screen an operator reads immediately after a deployment — the one moment when telling
 * PHASE_D_DEPLOYED from PHASE_C_STILL_ACTIVE is the entire job of the instrument.
 *
 * ★ IT WAS UNTESTABLE BY CONSTRUCTION, WHICH IS THE REAL FINDING. The wording lived inline in
 * `main()`, which cannot run without a live AAL2 session, so no unit test and no mutation could ever
 * reach it. Extracting it into `scripts/lib/phaseDVerdictProse.mjs` is what makes the assertions
 * below possible at all — the fix is not only the conditional, it is the seam.
 *
 * ★ THE INVARIANT UNDER TEST IS ONE PROPERTY, NOT THREE:
 *
 *        VERDICT   ⟷   EXIT CODE   ⟷   PROSE      — all agree, always.
 */
import { describe, expect, it } from "vitest";
import {
  DEPLOYMENT_PROOF_SENTENCE,
  PHASE_C_STILL_ACTIVE,
  PHASE_D_DEPLOYED,
  scopeReport,
} from "../scripts/lib/phaseDVerdictProse.mjs";

const text = (phase: string, failures: number) => scopeReport(phase, failures).lines.join("\n");

describe("0 · the instrument is inspecting something", () => {
  it("the exported proof sentence is non-trivial, so the absence assertions below can fail", () => {
    // ★ POSITIVE CONTROL FOR THE MATCHER ITSELF. If this sentence were empty or absent, every
    // `not.toContain` below would pass vacuously and this file would be a decoration.
    expect(DEPLOYMENT_PROOF_SENTENCE.length).toBeGreaterThan(30);
    expect(DEPLOYMENT_PROOF_SENTENCE).toContain("deployed");
    // And it must genuinely appear on the clean branch — proving the matcher CAN find it.
    expect(text(PHASE_D_DEPLOYED, 0)).toContain(DEPLOYMENT_PROOF_SENTENCE);
  });
});

describe("1 · PHASE_C_STILL_ACTIVE — the state that shipped wrong", () => {
  it("NO line claims Phase D is deployed", () => {
    const out = text(PHASE_C_STILL_ACTIVE, 2);
    expect(out).not.toContain(DEPLOYMENT_PROOF_SENTENCE);
    expect(scopeReport(PHASE_C_STILL_ACTIVE, 2).claimsDeployment).toBe(false);
  });

  it("states plainly that Phase D is NOT deployed", () => {
    const out = text(PHASE_C_STILL_ACTIVE, 2);
    expect(out).toContain("NOT deployed");
    expect(out).toMatch(/PROVED\s*:\s*NOTHING about Phase D/);
  });

  it("says it is the EXPECTED pre-paste result AND a failure to verify — both, not either", () => {
    // Dropping "expected" turns an honest not-yet into a false alarm; dropping "failure to verify"
    // turns it into a false reassurance. The operator needs both readings at once.
    const out = text(PHASE_C_STILL_ACTIVE, 2);
    expect(out).toContain("EXPECTED result before the artifact is pasted");
    expect(out).toContain("failure to verify Phase D rather than a clean bill of health");
  });

  it("exits non-zero, matching the existing contract", () => {
    expect(scopeReport(PHASE_C_STILL_ACTIVE, 2).exitCode).toBe(1);
    // ★ AND EVEN WITH ZERO INDIVIDUAL FAILURES. Observing Phase C IS a failure to verify Phase D;
    // a run that errored on nothing has still not established the thing it was asked to establish.
    expect(scopeReport(PHASE_C_STILL_ACTIVE, 0).exitCode).toBe(1);
    expect(scopeReport(PHASE_C_STILL_ACTIVE, 0).claimsDeployment).toBe(false);
  });
});

describe("2 · PHASE_D_DEPLOYED — only a clean run may assert a deployment", () => {
  it("a clean run claims the deployment and exits 0", () => {
    const r = scopeReport(PHASE_D_DEPLOYED, 0);
    expect(r.claimsDeployment).toBe(true);
    expect(r.exitCode).toBe(0);
    expect(r.lines.join("\n")).toContain(DEPLOYMENT_PROOF_SENTENCE);
  });

  it("a run WITH failures reports PARTIAL and never claims a clean cutover", () => {
    const r = scopeReport(PHASE_D_DEPLOYED, 1);
    expect(r.claimsDeployment).toBe(false);
    expect(r.exitCode).toBe(1);
    expect(r.lines.join("\n")).toContain("PARTIAL");
    expect(r.lines.join("\n")).not.toContain(DEPLOYMENT_PROOF_SENTENCE);
  });

  it("a deployed run does NOT print the Phase-C-only wording", () => {
    // The mirror of §1: prose specific to "not deployed" must not appear on a deployed run, or the
    // instrument contradicts itself in the other direction.
    const out = text(PHASE_D_DEPLOYED, 0);
    expect(out).not.toContain("NOTHING about Phase D");
    expect(out).not.toContain("still on PHASE C semantics");
  });
});

describe("3 · the three outputs can never disagree", () => {
  const CASES: ReadonlyArray<readonly [string, number]> = [
    [PHASE_D_DEPLOYED, 0],
    [PHASE_D_DEPLOYED, 1],
    [PHASE_D_DEPLOYED, 7],
    [PHASE_C_STILL_ACTIVE, 0],
    [PHASE_C_STILL_ACTIVE, 1],
    [PHASE_C_STILL_ACTIVE, 9],
  ];

  it.each(CASES)("%s with %i failure(s): prose claims deployment IFF verdict is clean", (phase, failures) => {
    const r = scopeReport(phase as string, failures as number);
    const clean = phase === PHASE_D_DEPLOYED && failures === 0;
    // The whole contract, as one biconditional.
    expect(r.claimsDeployment).toBe(clean);
    expect(r.exitCode).toBe(clean ? 0 : 1);
    expect(r.lines.join("\n").includes(DEPLOYMENT_PROOF_SENTENCE)).toBe(clean);
  });

  it("every branch still carries the non-delivery and runtime-proof caveats", () => {
    for (const [phase, failures] of CASES) {
      const out = text(phase as string, failures as number);
      // These are unconditional ON PURPOSE and must survive every branch: the acceptance/delivery
      // distinction is true regardless of deployment state, and a branch that dropped it would let
      // "accepted" read as "delivered" on exactly one code path.
      expect(out).toContain("PROVIDER ACCEPTANCE");
      expect(out).toContain("not delivery");
      expect(out).toContain("PRODUCTION_RUNTIME_PROOF_PENDING");
      expect(out).toContain("IRREVERSIBLY DISCLOSE AN ESTATE");
    }
  });
});

describe("4 · unknown inputs fail loudly rather than defaulting", () => {
  it("an unrecognised phase throws instead of silently choosing a branch", () => {
    // Fail closed: a typo'd or future phase must not fall through to the branch that claims a
    // deployment. Choosing a default here is how a third state would silently read as a success.
    expect(() => scopeReport("PHASE_E", 0)).toThrow(/unknown phase/);
    expect(() => scopeReport("", 0)).toThrow(/unknown phase/);
  });

  it("a non-integer or negative failure count throws", () => {
    expect(() => scopeReport(PHASE_D_DEPLOYED, -1)).toThrow(/non-negative integer/);
    expect(() => scopeReport(PHASE_D_DEPLOYED, 1.5)).toThrow(/non-negative integer/);
  });
});

describe("5 · the deployed script consumes this module rather than restating it", () => {
  it("verifyPhaseDDeployment.mjs imports scopeReport and prints no inline PROVED line", async () => {
    const fs = await import("node:fs");
    const path = await import("node:path");
    const { fileURLToPath } = await import("node:url");
    const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
    const src = fs.readFileSync(path.join(root, "scripts/verifyPhaseDDeployment.mjs"), "utf8");

    expect(src).toContain("phaseDVerdictProse.mjs");
    expect(src).toMatch(/scopeReport\s*\(/);
    // ★ NO SECOND COPY. A restated PROVED line in the script would drift from the tested module and
    // reintroduce the defect somewhere this suite cannot see — the same two-literals-two-opinions
    // failure the module's own header warns about.
    expect(src).not.toContain(DEPLOYMENT_PROOF_SENTENCE);
  });
});
