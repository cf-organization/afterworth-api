/**
 * GUARDED NON-PRODUCTION SEED / RESET — the guard contract.
 *
 * ★ THE SHARPEST TEST IN THIS FILE IS NOT A REFUSAL, IT IS GROUP 1. A production denylist that
 * pins the WRONG ref denies a project that does not exist and leaves production wide open, while
 * every refusal test below still passes — because they all feed it the same wrong value. So the pin
 * is checked against committed repository content, exactly as `noProductionMutation.test.ts` checks
 * its forbidden-RPC list against `db/functions/`: a typo must not be able to retire the rule.
 *
 * This is the same class of defect as a scanner that inspects nothing. A guard whose denylist names
 * a fiction reports "clean" forever.
 */
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  DECISION,
  DEFAULT_GUARD_POLICY,
  ENVIRONMENT_LABELS,
  GUARD_IDS,
  OPERATIONS,
  PRODUCTION_PROJECT_REFS,
  REFUSAL_REASONS,
  PROTECTED_PROJECT_REFS,
  RESET_FK_ORDER,
  classifySeedRequest,
  isApprovedSyntheticIdentity,
} from "../scripts/lib/nonProdSeedGuard.mjs";
import { stripComments } from "../scripts/lib/readOnlyAudit.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const MODULE = "scripts/lib/nonProdSeedGuard.mjs";
const read = (p: string) => readFileSync(join(ROOT, p), "utf8");
/**
 * ★ CODE, NOT PROSE. The module's header deliberately NAMES the APIs it refuses to use — "a
 * classifier that could read `process.env`…" — so a raw match reports the documentation as the
 * violation it is documenting. This reuses `readOnlyAudit`'s stripper, which is already proven in
 * both directions (it removes a comment; it does NOT remove a string literal) and is regression-
 * tested against a quote-containing regex.
 */
const code = (p: string) => stripComments(read(p));

/** A syntactically valid, non-production ref. 20 lowercase letters, deliberately not the pin. */
const NONPROD = "aaaabbbbccccddddeeee";
const OTHER_NONPROD = "zzzzyyyyxxxxwwwwvvvv";
const PROD = PRODUCTION_PROJECT_REFS[0];

type Req = Parameters<typeof classifySeedRequest>[0];

/** A request that passes every guard — the baseline each test perturbs by exactly one field. */
const okSeed = (over: Partial<Req> = {}): Req => ({
  targetRef: NONPROD,
  declaredEnvironment: "development",
  operation: "seed",
  identities: [`owner+p1@${DEFAULT_GUARD_POLICY.syntheticEmailDomain}`],
  ...over,
});
const okReset = (over: Partial<Req> = {}): Req =>
  okSeed({ operation: "reset", confirmDestructiveTarget: NONPROD, ...over });

const run = (r: Req, policy?: unknown) => classifySeedRequest(r, policy as never);
const reasons = (r: Req, policy?: unknown) => [...run(r, policy).reasons];

describe("★ 0 · the harness is real and the baseline is genuinely permitted", () => {
  it("the module exists and is non-trivial", () => {
    expect(read(MODULE).length).toBeGreaterThan(2000);
  });

  it("★ the baseline seed and reset are BOTH authorized — otherwise every refusal below is vacuous", () => {
    // If the baseline refused, a test asserting "refuses when X is removed" would pass for the
    // wrong reason and prove nothing about X.
    expect(run(okSeed()).decision).toBe(DECISION.DRY_RUN_AUTHORIZED);
    expect(run(okReset()).decision).toBe(DECISION.DRY_RUN_AUTHORIZED);
    expect(run(okSeed()).reasons).toEqual([]);
    expect(run(okReset()).reasons).toEqual([]);
  });

  it("every guard id is present on every verdict, so none can silently vanish", () => {
    for (const r of [run(okSeed()), run(okReset()), run({} as Req)]) {
      expect(r.guards.map((g: { id: string }) => g.id)).toEqual([...GUARD_IDS]);
    }
    expect(GUARD_IDS).toHaveLength(6);
  });
});

describe("★ 1 · THE PRODUCTION PIN NAMES THE REAL PRODUCTION PROJECT", () => {
  it("★ the pinned ref is the one committed in README.md — a typo here would deny a fiction", () => {
    const committed = [...new Set([...read("README.md").matchAll(/https:\/\/([a-z0-9]+)\.supabase\.co/g)].map((m) => m[1]))];
    expect(committed).toHaveLength(1);
    expect(PRODUCTION_PROJECT_REFS).toContain(committed[0]);
  });

  it("★ the same ref is corroborated by the proof docs, not by README alone", () => {
    const docs = ["docs/upload-contract-proof.md", "docs/orphan-sweeper-proof.md", "docs/purge-outbox-health-proof.md"];
    for (const d of docs) {
      const found = [...new Set([...read(d).matchAll(/https:\/\/([a-z0-9]+)\.supabase\.co/g)].map((m) => m[1]))];
      expect(found, d).toContain(PROD);
    }
  });

  it("★ the control can fail — a ref that is NOT production is not on the denylist", () => {
    expect(PRODUCTION_PROJECT_REFS).not.toContain(NONPROD);
    expect(PRODUCTION_PROJECT_REFS.every((r: string) => /^[a-z]{20}$/.test(r))).toBe(true);
  });

  it("the pin satisfies the very shape the target guard enforces", () => {
    // A pin that could never be typed as a valid target would be unreachable and therefore inert.
    expect(run(okSeed({ targetRef: PROD })).reasons).toContain("production_target_forbidden");
    expect(run(okSeed({ targetRef: PROD })).reasons).not.toContain("target_malformed");
  });
});

describe("★ 2 · G1 · the target is explicit — there is no default, ever", () => {
  it("missing target refuses", () => {
    expect(reasons(okSeed({ targetRef: undefined }))).toContain("target_missing");
  });
  it("empty target refuses", () => {
    expect(reasons(okSeed({ targetRef: "" }))).toContain("target_missing");
  });
  it("whitespace-only target refuses", () => {
    expect(reasons(okSeed({ targetRef: "   \t \n " }))).toContain("target_missing");
  });
  it("a malformed target refuses, and says MALFORMED rather than MISSING", () => {
    for (const bad of ["https://x.supabase.co", "SHOUTING", "too-short", "a".repeat(21), "has space here", "digits123456789012345"]) {
      const rs = reasons(okSeed({ targetRef: bad }));
      expect(rs, bad).toContain("target_malformed");
      expect(rs, bad).not.toContain("target_missing");
    }
  });
  it("a non-string target is refused, not coerced", () => {
    for (const bad of [null, 42, {}, [], true]) {
      expect(reasons(okSeed({ targetRef: bad as never }))).toContain("target_missing");
    }
  });
  it("★ no source path defaults the target to anything", () => {
    const src = read(MODULE);
    expect(src).not.toMatch(/targetRef\s*\|\|/);
    expect(src).not.toMatch(/targetRef\s*\?\?/);
  });
});

describe("★ 3 · G2 · the production pin cannot be argued down", () => {
  it("production ref refuses on a plain seed", () => {
    expect(reasons(okSeed({ targetRef: PROD }))).toContain("production_target_forbidden");
  });

  it("★ production ref + declaredEnvironment 'development' STILL refuses", () => {
    const r = run(okSeed({ targetRef: PROD, declaredEnvironment: "development" }));
    expect(r.decision).toBe(DECISION.REFUSED);
    expect(r.reasons).toContain("production_target_forbidden");
  });

  it("★ production ref + a correct destructive confirmation STILL refuses", () => {
    const r = run(okReset({ targetRef: PROD, confirmDestructiveTarget: PROD }));
    expect(r.decision).toBe(DECISION.REFUSED);
    expect(r.reasons).toContain("production_target_forbidden");
    // and the confirmation guard itself passed — proving the refusal came from G2 alone
    expect(r.guards.find((g: { id: string }) => g.id === "G4_destructive_confirmation")?.pass).toBe(true);
  });

  it("★ EVERY combination involving the production ref refuses", () => {
    for (const env of [...ENVIRONMENT_LABELS, "", "nonsense"]) {
      for (const op of [...OPERATIONS, "", "nonsense"]) {
        const r = run({
          targetRef: PROD,
          declaredEnvironment: env,
          operation: op,
          confirmDestructiveTarget: PROD,
          identities: [`owner+p1@${DEFAULT_GUARD_POLICY.syntheticEmailDomain}`],
        });
        expect(r.decision, `${env}/${op}`).toBe(DECISION.REFUSED);
        expect(r.reasons, `${env}/${op}`).toContain("production_target_forbidden");
        expect(r.targetRef).toBeNull();
      }
    }
  });

  it("★ G2 consults the target and the pin ONLY — no label, flag or operation is in its scope", () => {
    // Behavioural proof of independence: holding the target at production, nothing else moves G2.
    const g2 = (over: Partial<Req>) =>
      run(okSeed({ targetRef: PROD, ...over })).guards.find((g: { id: string }) => g.id === "G2_production_pin");
    for (const over of [
      { declaredEnvironment: "development" },
      { declaredEnvironment: "staging" },
      { declaredEnvironment: "test" },
      { operation: "reset", confirmDestructiveTarget: PROD },
      { identities: [] },
    ] as Partial<Req>[]) {
      expect(g2(over)?.pass, JSON.stringify(over)).toBe(false);
      expect(g2(over)?.reason).toBe("production_target_forbidden");
    }
  });

  it("an unresolvable policy denies everything rather than passing G2 vacuously", () => {
    for (const bad of [{}, { productionProjectRefs: [] }, { productionProjectRefs: ["x"], syntheticEmailDomain: "" }, null]) {
      const r = run(okSeed(), bad);
      expect(r.decision, JSON.stringify(bad)).toBe(DECISION.REFUSED);
      expect(r.reasons, JSON.stringify(bad)).toContain("guard_policy_unresolved");
    }
  });
});

describe("★ 4 · G3 · non-production intent is explicit and never inferred", () => {
  it("missing intent refuses even for a valid non-production ref", () => {
    expect(reasons(okSeed({ declaredEnvironment: undefined }))).toContain("environment_intent_missing");
    expect(reasons(okSeed({ declaredEnvironment: "  " }))).toContain("environment_intent_missing");
  });

  it("★ an unrecognized label refuses — a typo must never become permission", () => {
    for (const bad of ["dev", "Development", "prod", "nonprod", "staging2", "локально"]) {
      const rs = reasons(okSeed({ declaredEnvironment: bad }));
      expect(rs, bad).toContain("environment_intent_unrecognized");
    }
  });

  it("★ 'production' is RECOGNIZED and REFUSED — a distinct reason from a typo", () => {
    const rs = reasons(okSeed({ declaredEnvironment: "production" }));
    expect(rs).toContain("environment_intent_is_production");
    expect(rs).not.toContain("environment_intent_unrecognized");
  });

  it("each non-production label is accepted", () => {
    for (const env of ["development", "staging", "test"]) {
      expect(run(okSeed({ declaredEnvironment: env })).decision, env).toBe(DECISION.DRY_RUN_AUTHORIZED);
    }
  });
});

describe("★ 5 · operation vocabulary", () => {
  it("a missing operation refuses", () => {
    expect(reasons(okSeed({ operation: undefined }))).toContain("operation_missing");
  });
  it("★ an unknown operation refuses rather than degrading to the least destructive reading", () => {
    for (const bad of ["drop", "truncate", "SEED", "reset-all", "migrate"]) {
      expect(reasons(okSeed({ operation: bad })), bad).toContain("operation_unrecognized");
    }
  });
  it("only seed and reset exist", () => {
    expect([...OPERATIONS]).toEqual(["seed", "reset"]);
  });
});

describe("★ 6 · G4 · reset demands strictly more than seed", () => {
  it("★ seed needs no destructive confirmation; reset does — the asymmetry is the contract", () => {
    expect(run(okSeed()).decision).toBe(DECISION.DRY_RUN_AUTHORIZED);
    const noConfirm = run(okSeed({ operation: "reset" }));
    expect(noConfirm.decision).toBe(DECISION.REFUSED);
    expect(noConfirm.reasons).toContain("destructive_confirmation_missing");
  });

  it("★ a confirmation naming a DIFFERENT project refuses", () => {
    const rs = reasons(okReset({ confirmDestructiveTarget: OTHER_NONPROD }));
    expect(rs).toContain("destructive_confirmation_target_mismatch");
  });

  it("★ the production ref as a confirmation for a non-production target refuses", () => {
    // The two-terminals mistake, in its most dangerous direction.
    expect(reasons(okReset({ confirmDestructiveTarget: PROD }))).toContain(
      "destructive_confirmation_target_mismatch"
    );
  });

  it("a confirmation matching the exact target permits the dry run", () => {
    const r = run(okReset({ confirmDestructiveTarget: NONPROD }));
    expect(r.decision).toBe(DECISION.DRY_RUN_AUTHORIZED);
    expect(r.operation).toBe("reset");
  });

  it("★ a boolean-ish STRING is not a target name — it refuses as a mismatch", () => {
    // `--yes` muscle memory is the thing G4 exists to defeat, so these must not be treated as
    // "nothing supplied" — the operator DID supply something, and it was not the project.
    for (const bad of ["yes", "true", "y", "1", "YES"]) {
      expect(reasons(okReset({ confirmDestructiveTarget: bad })), bad).toContain(
        "destructive_confirmation_target_mismatch"
      );
    }
  });

  it("a non-string confirmation is refused as MISSING — nothing usable was supplied", () => {
    for (const bad of [true, 1, null, {}, []]) {
      expect(reasons(okReset({ confirmDestructiveTarget: bad as never })), String(bad)).toContain(
        "destructive_confirmation_missing"
      );
    }
  });

  it("G4 is marked not-applicable on seed rather than omitted", () => {
    const g4 = run(okSeed()).guards.find((g: { id: string }) => g.id === "G4_destructive_confirmation");
    expect(g4).toMatchObject({ pass: true, notApplicable: true });
    const g4r = run(okReset()).guards.find((g: { id: string }) => g.id === "G4_destructive_confirmation");
    expect(g4r).not.toHaveProperty("notApplicable");
  });
});

describe("★ 7 · G5 · synthetic identity (plan guard 3)", () => {
  const D = DEFAULT_GUARD_POLICY.syntheticEmailDomain;

  it("plus-addressed on the approved domain is accepted", () => {
    expect(isApprovedSyntheticIdentity(`owner+seed1@${D}`, D)).toBe(true);
    expect(isApprovedSyntheticIdentity(`OWNER+Seed1@${D.toUpperCase()}`, D)).toBe(true);
  });

  it("★ a non-plus-addressed identity on the approved domain is REFUSED", () => {
    expect(isApprovedSyntheticIdentity(`owner@${D}`, D)).toBe(false);
    expect(reasons(okSeed({ identities: [`owner@${D}`] }))).toContain("synthetic_identity_required");
  });

  it("★ a plus-addressed identity on a FOREIGN domain is refused — this is the real-person case", () => {
    expect(isApprovedSyntheticIdentity("someone+tag@gmail.com", D)).toBe(false);
    expect(reasons(okSeed({ identities: ["someone+tag@gmail.com"] }))).toContain("synthetic_identity_required");
  });

  it("degenerate shapes are refused, never coerced", () => {
    for (const bad of ["", "   ", "no-at-sign", `@${D}`, `+tag@${D}`, `owner+@${D}`, `owner+tag@sub.${D}`, null, 7]) {
      expect(isApprovedSyntheticIdentity(bad as never, D), String(bad)).toBe(false);
    }
  });

  it("★ ONE bad identity in a list of good ones refuses the whole request", () => {
    const rs = reasons(okSeed({ identities: [`a+1@${D}`, `b+2@${D}`, "real.person@example.com"] }));
    expect(rs).toContain("synthetic_identity_required");
  });

  it("an empty identity list is permitted — a reset need name none", () => {
    expect(run(okSeed({ identities: [] })).decision).toBe(DECISION.DRY_RUN_AUTHORIZED);
  });

  it("★ the guard applies to reset too — a reset naming identities is naming who it deletes", () => {
    expect(reasons(okReset({ identities: ["real.person@example.com"] }))).toContain("synthetic_identity_required");
  });
});

describe("★ 8 · G6 · estate manifest allowlist (plan guard 2)", () => {
  it("an estate absent from the manifest refuses", () => {
    expect(reasons(okReset({ estateIds: ["estate-a"], estateManifest: ["estate-b"] }))).toContain(
      "estate_not_in_manifest"
    );
  });

  it("★ named estates with an EMPTY manifest refuse — never 'nothing to check'", () => {
    expect(reasons(okReset({ estateIds: ["estate-a"], estateManifest: [] }))).toContain("estate_not_in_manifest");
    expect(reasons(okReset({ estateIds: ["estate-a"] }))).toContain("estate_not_in_manifest");
  });

  it("one unlisted estate among listed ones refuses the whole request", () => {
    expect(
      reasons(okReset({ estateIds: ["a", "b", "c"], estateManifest: ["a", "b"] }))
    ).toContain("estate_not_in_manifest");
  });

  it("estates fully covered by the manifest are permitted", () => {
    expect(run(okReset({ estateIds: ["a", "b"], estateManifest: ["a", "b", "c"] })).decision).toBe(
      DECISION.DRY_RUN_AUTHORIZED
    );
  });

  it("naming no estates is permitted", () => {
    expect(run(okReset({ estateIds: [] })).decision).toBe(DECISION.DRY_RUN_AUTHORIZED);
  });
});

describe("★ 9 · cross-guard composition", () => {
  it("★ removing ANY single guard's satisfaction refuses — each is independently load-bearing", () => {
    const perturbations: [string, Partial<Req>][] = [
      ["G1", { targetRef: "" }],
      ["G2", { targetRef: PROD }],
      ["G3", { declaredEnvironment: "" }],
      ["G4", { confirmDestructiveTarget: "" }],
      ["G5", { identities: ["real.person@example.com"] }],
      ["G6", { estateIds: ["unlisted"], estateManifest: [] }],
    ];
    for (const [label, over] of perturbations) {
      const r = run(okReset(over));
      expect(r.decision, label).toBe(DECISION.REFUSED);
    }
  });

  it("★ composition is AND — satisfying five guards while failing one still refuses", () => {
    // G4 is deliberately satisfied against the production target, so G2 is the ONLY failure.
    const r = run(okReset({ targetRef: PROD, confirmDestructiveTarget: PROD }));
    const failed = r.guards.filter((g: { pass: boolean }) => !g.pass);
    expect(failed.map((g: { id: string }) => g.id)).toEqual(["G2_production_pin"]);
    expect(r.guards.filter((g: { pass: boolean }) => g.pass)).toHaveLength(5);
    expect(r.decision).toBe(DECISION.REFUSED);
  });

  it("★ every failing guard is reported, not just the first", () => {
    const r = run({ operation: "reset" } as Req);
    expect(r.reasons).toEqual(
      expect.arrayContaining([
        "target_missing",
        "environment_intent_missing",
        "destructive_confirmation_missing",
      ])
    );
    expect(r.reasons.length).toBeGreaterThanOrEqual(3);
  });

  it("all guards satisfied → DRY_RUN_AUTHORIZED, and nothing stronger exists", () => {
    expect(Object.values(DECISION)).toEqual(["DRY_RUN_AUTHORIZED", "REFUSED"]);
    expect(run(okReset()).decision).toBe(DECISION.DRY_RUN_AUTHORIZED);
  });

  it("a refused verdict echoes no target or operation back to the caller", () => {
    const r = run(okSeed({ targetRef: PROD }));
    expect(r.targetRef).toBeNull();
    expect(r.operation).toBeNull();
  });

  it("★ every emitted reason is in the closed vocabulary, and the vocabulary has no dead entries", () => {
    const emitted = new Set<string>();
    const cases: Req[] = [
      okSeed(), okReset(),
      okSeed({ targetRef: "" }), okSeed({ targetRef: "bad" }), okSeed({ targetRef: PROD }),
      // An existing real project whose operational role is unestablished — refused on uncertainty,
      // distinct from the evidenced production pin. Added when PROTECTED_PROJECT_REFS was introduced;
      // the vocabulary test caught the new reason as unexercised, which is exactly its job.
      okSeed({ targetRef: PROTECTED_PROJECT_REFS[0] }),
      okSeed({ declaredEnvironment: "" }), okSeed({ declaredEnvironment: "dev" }), okSeed({ declaredEnvironment: "production" }),
      okSeed({ operation: "" }), okSeed({ operation: "drop" }),
      okSeed({ operation: "reset" }), okReset({ confirmDestructiveTarget: OTHER_NONPROD }),
      okSeed({ identities: ["x@y.test"] }),
      okReset({ estateIds: ["a"], estateManifest: [] }),
    ];
    for (const c of cases) for (const r of run(c).reasons) emitted.add(r);
    for (const r of emitted) expect(REFUSAL_REASONS, `${r} is not in the closed vocabulary`).toContain(r);
    // guard_policy_unresolved is exercised in group 3; everything else must be reachable here.
    const unreachable = REFUSAL_REASONS.filter((r: string) => r !== "guard_policy_unresolved" && !emitted.has(r));
    expect(unreachable, "dead refusal reasons").toEqual([]);
  });
});

describe("★ 10 · determinism, immutability and the absence of I/O", () => {
  it("★ the same input twice in one process gives an identical verdict", () => {
    for (const c of [okSeed(), okReset(), okSeed({ targetRef: PROD }), {} as Req]) {
      expect(JSON.stringify(run(c))).toBe(JSON.stringify(run(c)));
    }
  });

  it("the classifier does not mutate its input", () => {
    const req = okReset({ identities: ["a+1@after-worth.com"], estateIds: ["e1"], estateManifest: ["e1"] });
    const snapshot = JSON.stringify(req);
    run(req);
    run(req);
    expect(JSON.stringify(req)).toBe(snapshot);
  });

  it("the verdict is frozen, so a caller cannot edit a refusal into an approval", () => {
    const r = run(okSeed({ targetRef: PROD }));
    expect(Object.isFrozen(r)).toBe(true);
    expect(Object.isFrozen(r.reasons)).toBe(true);
    expect(Object.isFrozen(r.guards)).toBe(true);
  });

  it("a hostile input shape is refused, never thrown on", () => {
    for (const bad of [undefined, null, 0, "", [], "string", { targetRef: { toString: () => PROD } }]) {
      expect(() => run(bad as never)).not.toThrow();
      expect(run(bad as never).decision).toBe(DECISION.REFUSED);
    }
  });

  it("★ THE MODULE HAS NO IMPORTS AT ALL — it cannot reach env, disk or network", () => {
    const src = read(MODULE);
    expect(src).not.toMatch(/^\s*import\s/m);
    expect(src).not.toMatch(/\brequire\s*\(/);
  });

  it("★ POSITIVE CONTROL — the stripper removes this module's prose but keeps its strings", () => {
    // Without this, every absence assertion below could be passing because the stripper erased
    // the whole file. It must remove a term that appears ONLY in a comment...
    expect(read(MODULE)).toContain("process.env");
    expect(code(MODULE)).not.toContain("process.env");
    // ...and keep a term that appears only as a string literal.
    expect(code(MODULE)).toContain("'DRY_RUN_AUTHORIZED'");
    expect(code(MODULE).length).toBeGreaterThan(1500);
    expect(code(MODULE).length).toBeLessThan(read(MODULE).length);
  });

  it("★ no network, subprocess, filesystem or SQL surface in the module", () => {
    const src = code(MODULE);
    for (const forbidden of [
      "fetch(", "XMLHttpRequest", "axios", "node-fetch", "undici",
      "child_process", "spawnSync", "execSync", "execFileSync", "spawn(",
      "node:fs", "readFileSync", "writeFileSync", "node:net", "node:http",
      "createClient", "supabase", "psql", "pg.Client", "process.env",
      "SELECT ", "INSERT ", "UPDATE ", "DELETE ", "TRUNCATE ", "DROP ",
    ]) {
      expect(src, `module names ${forbidden}`).not.toContain(forbidden);
    }
  });

  it("★ the module reaches no execution path — DRY_RUN_AUTHORIZED is the strongest verdict", () => {
    const src = code(MODULE);
    for (const verb of ["async ", "await ", "Promise"]) expect(src).not.toContain(verb);
  });

  it("RESET_FK_ORDER is inert data and matches the plan's committed order", () => {
    expect([...RESET_FK_ORDER]).toEqual([
      "grants", "access_requests", "notifications", "claim_packets", "claims",
      "documents", "designations", "memberships", "estates", "users",
    ]);
    // Nothing reads it — it is carried for the future adapter, not consumed here. Counted on
    // STRIPPED code, so the header sentence explaining that it is inert does not read as a use.
    const uses = code(MODULE).split("RESET_FK_ORDER").length - 1;
    expect(uses).toBe(1); // the declaration only
  });
});
