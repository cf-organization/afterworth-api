/**
 * SCHEMA AUTHORITY CONTRACT — mechanically enforced.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ WHY THIS FILE EXISTS. The Model C implementation left three directories able to answer the same
 *   question: db/bootstrap, db/tables and db/functions all carried `base` authority, and the
 *   reconciler reported 160 DUPLICATE_BASE objects. Nothing prevented them from diverging, and
 *   nothing decided which one won. A comment saying "db/bootstrap is canonical" is not a contract;
 *   db/AUTHORITY.json plus these tests are.
 *
 * ★ IT FAILS CLOSED ON THE UNKNOWN. A new schema-bearing directory under db/ that nobody classified
 *   is a REFUSAL, not a default. That behaviour already earned its keep once: committing
 *   db/bootstrap/ made the reconciliation suite fail precisely because a new db/ subdirectory had
 *   appeared unclassified.
 */
import { readFileSync, existsSync, readdirSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { execSync } from "node:child_process";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "vitest";
import { inventory } from "../scripts/lib/schemaInventory.mjs";
import { SOURCE_ROLES, AUTHORITY_CONTRACT, roleOf, repositoryObjects, reconcile } from "../scripts/lib/schemaReconcile.mjs";
import { classifyMigrations, validateVersion, VERDICT, FIXTURE_MARKERS } from "../scripts/lib/migrationAuthority.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const A = AUTHORITY_CONTRACT;
const sqlFiles = (dir: string) =>
  existsSync(join(ROOT, dir)) ? readdirSync(join(ROOT, dir)).filter((f) => f.endsWith(".sql")) : [];

describe("the authority contract is present, complete and machine-readable", () => {
  test("db/AUTHORITY.json exists and declares every level", () => {
    expect(existsSync(join(ROOT, "db/AUTHORITY.json"))).toBe(true);
    expect(A.bootstrap_authority.path).toBe("db/bootstrap");
    expect(A.bootstrap_authority.through_version).toBe("0060");
    expect(A.future_migration_authority.starts_at).toBe("0061");
    expect(A.historical_migrations.immutable).toBe(true);
    expect(A.historical_migrations.virgin_bootstrap).toBe(false);
  });
  test("every non-authoritative entry carries the fields a reviewer needs", () => {
    expect(A.non_authoritative_paths.length).toBeGreaterThan(0);
    for (const e of A.non_authoritative_paths) {
      expect(typeof e.reason).toBe("string");
      expect(e.reason.length).toBeGreaterThan(20);
      expect(typeof e.generated).toBe("boolean");
      expect(Array.isArray(e.consumers)).toBe(true);
      expect(typeof e.drift_tolerated).toBe("boolean");
      expect(typeof e.exact_equivalence_required).toBe("boolean");
      expect(typeof e.drift_rationale).toBe("string");
      expect(typeof e.removal_prerequisite).toBe("string");
    }
  });
  test("★ MUTATION 3: exactly ONE path carries bootstrap base authority", () => {
    expect(SOURCE_ROLES.filter((r) => r.role === "base")).toHaveLength(1);
    expect(roleOf("db/bootstrap/30_tables.sql").role).toBe("base");
  });
  test("★ MUTATIONS 1+2: db/tables and db/functions are NOT canonical", () => {
    expect(roleOf("db/tables/estates.sql").role).not.toBe("base");
    expect(roleOf("db/functions/is_estate_owner.sql").role).not.toBe("base");
    expect(roleOf("db/tables/estates.sql").role).toBe("legacy-compat");
    expect(roleOf("db/functions/is_estate_owner.sql").role).toBe("legacy-compat");
  });
  test("the shim is test-only and is matched BEFORE the bootstrap rule", () => {
    expect(roleOf("db/bootstrap/testing/PLATFORM_SHIM_NOT_PRODUCTION.sql").role).toBe("test-only");
  });
});

describe("PHASE D — an unclassified schema-bearing path fails closed", () => {
  /** Does this path bear CREATE-TABLE-class schema material? */
  const bearsSchema = (sql: string) => {
    const inv = inventory(sql);
    return inv.tables.length + inv.functions.length + inv.policies.length + inv.types.length > 0;
  };

  test("every tracked db/ SQL file resolves to a declared role", () => {
    const paths = execSync("git ls-files db/", { cwd: ROOT, encoding: "utf8" }).trim().split("\n").filter((p) => p.endsWith(".sql"));
    expect(paths.length).toBeGreaterThan(200);
    expect(paths.filter((p) => roleOf(p).role === "unknown")).toEqual([]);
  });

  test("★ MUTATION 8: a NEW schema-bearing db/ directory is refused", () => {
    const dir = join(ROOT, "db/new-schema-source");
    try {
      mkdirSync(dir, { recursive: true });
      writeFileSync(join(dir, "rogue.sql"), "create table public.rogue (id uuid primary key);\n");
      const rel = "db/new-schema-source/rogue.sql";
      expect(bearsSchema(readFileSync(join(dir, "rogue.sql"), "utf8"))).toBe(true);   // it IS schema
      expect(roleOf(rel).role).toBe("unknown");                                       // and it is UNCLASSIFIED
      const repo = repositoryObjects([{ path: rel, sql: readFileSync(join(dir, "rogue.sql"), "utf8") }]);
      expect(repo.unknownPaths).toContain(rel);                                       // surfaced, not absorbed
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  test("the refusal is about classification, not about the name", () => {
    expect(roleOf("db/anything-at-all/x.sql").role).toBe("unknown");
    expect(roleOf("db/bootstrap-copy/x.sql").role).toBe("unknown");
  });

  test("an unclassified path can never be treated as bootstrap authority", () => {
    const repo = repositoryObjects([{ path: "db/mystery/x.sql", sql: "create table public.estates (id uuid);" }]);
    const live = inventory('CREATE TABLE IF NOT EXISTS "public"."estates" ("id" "uuid");');
    const rows = reconcile({ live, repo });
    expect(rows[0].disposition).not.toBe("COVERED");
  });
});

describe("PHASE E — legacy artifacts cannot supply what the bootstrap lacks", () => {
  const boot = readFileSync(join(ROOT, "db/bootstrap/30_tables.sql"), "utf8")
    + readFileSync(join(ROOT, "db/bootstrap/60_functions.sql"), "utf8");
  const bootInv = inventory(boot);

  test("★ MUTATION 6: a table present ONLY in db/tables does not count as covered", () => {
    const live = inventory('CREATE TABLE IF NOT EXISTS "public"."ghost_table" ("id" "uuid");');
    const repo = repositoryObjects([{ path: "db/tables/ghost_table.sql", sql: "create table public.ghost_table (id uuid);" }]);
    expect(reconcile({ live, repo })[0].disposition).not.toBe("COVERED");
  });
  test("★ MUTATION 6b: the test preamble cannot fill a bootstrap gap", () => {
    const live = inventory('CREATE TABLE IF NOT EXISTS "public"."ghost_table" ("id" "uuid");');
    const repo = repositoryObjects([{ path: "db/tests/preamble_real_auth.sql", sql: "create table public.ghost_table (id uuid);" }]);
    expect(reconcile({ live, repo })[0].disposition).toBe("TEST_ONLY_DEFINITION");
  });
  test("★ MUTATION 7: a bundle cannot supply a canonical function", () => {
    const live = inventory('CREATE OR REPLACE FUNCTION "public"."ghost_fn"() RETURNS void LANGUAGE "sql" AS $$ select 1 $$;');
    const repo = repositoryObjects([{ path: "db/bundles/x_bundle.sql", sql: "create or replace function public.ghost_fn() returns void language sql as $$ select 1 $$;" }]);
    expect(reconcile({ live, repo })[0].disposition).not.toBe("COVERED");
  });
  test("db/functions cannot make reconciliation appear complete", () => {
    const live = inventory('CREATE OR REPLACE FUNCTION "public"."ghost_fn"() RETURNS void LANGUAGE "sql" AS $$ select 1 $$;');
    const repo = repositoryObjects([{ path: "db/functions/ghost_fn.sql", sql: "create or replace function public.ghost_fn() returns void language sql as $$ select 1 $$;" }]);
    expect(reconcile({ live, repo })[0].disposition).not.toBe("COVERED");
  });

  test("every table db/tables defines is also in the canonical bootstrap — the one-way rule", () => {
    const legacy = sqlFiles("db/tables").flatMap((f) => inventory(readFileSync(join(ROOT, "db/tables", f), "utf8")).tables.map((t) => t.name));
    expect(legacy.length).toBeGreaterThan(10);                         // the scan set is real
    const bootTables = new Set(bootInv.tables.map((t) => t.name));
    expect(legacy.filter((t) => !bootTables.has(t))).toEqual([]);
  });
  test("every function db/functions defines is also in the canonical bootstrap", () => {
    const legacy = sqlFiles("db/functions").flatMap((f) => inventory(readFileSync(join(ROOT, "db/functions", f), "utf8")).functions.map((x) => x.name));
    expect(legacy.length).toBeGreaterThan(50);
    const bootFns = new Set(bootInv.functions.map((f) => f.name));
    expect(legacy.filter((f) => !bootFns.has(f))).toEqual([]);
  });
  test("drift IS tolerated in the other direction, and that is recorded, not assumed", () => {
    for (const p of ["db/tables", "db/functions"]) {
      const e = A.non_authoritative_paths.find((x) => x.path === p);
      expect(e.exact_equivalence_required).toBe(false);
      expect(e.drift_rationale.length).toBeGreaterThan(40);
    }
  });
});

describe("PHASE G — VERSION semantics are machine-enforced", () => {
  const VERSION = readFileSync(join(ROOT, "db/bootstrap/VERSION"), "utf8").trim();
  const CUTOFF = Number(VERSION);
  const FUTURE_START = Number(A.future_migration_authority.starts_at);
  const names = readdirSync(join(ROOT, "db/migrations")).filter((f) => f.endsWith(".sql"));
  // * SYNTHETIC SETS ARE BUILT FROM THE HISTORICAL SUBSET. Building them from whatever is on disk
  //   meant a temporary probe 0061 collided with the synthetic 0061 these fixtures append, so six
  //   tests failed on a duplicate-number problem they never meant to exercise. The fixtures are
  //   about the RULE, so their input must be the stable historical range.
  const historicalNames = names.filter((n) => Number(n.slice(0, 4)) <= Number(readFileSync(join(ROOT, "db/bootstrap/VERSION"), "utf8").trim()));
  const gitChanged = () =>
    execSync("git status --porcelain db/migrations/", { cwd: ROOT, encoding: "utf8" })
      .trim().split("\n").filter(Boolean).map((l) => l.slice(3).trim());

  test("VERSION is exactly four digits and equals the declared cutoff", () => {
    expect(VERSION).toMatch(/^\d{4}$/);
    expect(VERSION).toBe(A.bootstrap_authority.through_version);
  });

  test("★ VERSION means 'produces schema through 0060', NOT 'no migration may exceed 0060'", () => {
    // The first validator enforced the second reading and rejected a legitimate 0061 — nine
    // failures across three suites, every one a bug in the guard. VERSION is validated against the
    // HISTORICAL range only, so authoring a future migration can never invalidate the bootstrap
    // it is layered on.
    const withFuture = [...historicalNames, "0061_20260901_real.sql", "0099_20261231_much_later.sql"];
    const historicalOf = (set: string[]) => set.filter((n) => Number(n.slice(0, 4)) <= CUTOFF);

    // The historical subset is what VERSION is validated against, and future migrations do not
    // enter it. That is the whole mechanism: authoring 0061 or 0099 leaves the cutoff untouched.
    expect(historicalOf(withFuture)).toEqual(historicalNames);
    expect(validateVersion(VERSION, historicalNames).ok).toBe(true);
    expect(validateVersion(VERSION, historicalOf(withFuture)).ok).toBe(true);

    // And the set as a whole stays valid with those future migrations present.
    expect(classifyMigrations(withFuture, CUTOFF, FUTURE_START).verdict).toBe(VERDICT.OK);
  });

  test.each([
    ["60", "malformed — not four digits"],
    ["garbage", "not numeric"],
    ["0059", "below the highest historical migration"],
    ["", "empty"],
  ])("★ VERSION %s is refused (%s)", (v) => {
    const historical = names.filter((n) => Number(n.slice(0, 4)) <= CUTOFF);
    expect(validateVersion(v, historical).ok).toBe(false);
  });

  test("the live migration set is valid under the authority contract", () => {
    const r = classifyMigrations(names, CUTOFF, FUTURE_START, { addedOrModified: gitChanged() });
    expect(r.problems).toEqual([]);
    expect(r.verdict).toBe(VERDICT.OK);
    expect(r.historical).toHaveLength(60);
  });

  test("★ POSITIVE CONTROL: a legitimate future 0061 is ACCEPTED", () => {
    const r = classifyMigrations([...historicalNames, "0061_20260901_real_feature.sql"], CUTOFF, FUTURE_START);
    expect(r.verdict).toBe(VERDICT.OK);
    expect(r.future).toEqual(["0061_20260901_real_feature.sql"]);
    expect(r.historical).toHaveLength(60);
  });

  test("★ POSITIVE CONTROL: 0062 following 0061 is accepted, and 0061 alone is not required forever", () => {
    expect(classifyMigrations([...historicalNames, "0061_20260901_a.sql", "0062_20260902_b.sql"], CUTOFF, FUTURE_START).verdict).toBe(VERDICT.OK);
    expect(classifyMigrations([...historicalNames, "0062_20260902_b.sql"], CUTOFF, FUTURE_START).verdict).toBe(VERDICT.OK);
  });

  test.each([
    ["a NEW file inside the historical range", ["0042_20260901_renumbered.sql"], { addedOrModified: ["0042_20260901_renumbered.sql"] }],
    ["a MODIFIED historical file", [], { addedOrModified: ["db/migrations/0030_20260719_claim_evidence_storage_rls.sql"] }],
  ])("★ MUTATION: %s is refused", (_label, extra, opts) => {
    const r = classifyMigrations([...historicalNames, ...extra], CUTOFF, FUTURE_START, opts);
    expect(r.verdict).toBe(VERDICT.INVALID);
    expect(r.problems.join(" ")).toMatch(/historical range is immutable|duplicate migration number/);
  });

  test("★ MUTATION: a duplicate future number is refused", () => {
    const r = classifyMigrations([...historicalNames, "0061_20260901_a.sql", "0061_20260902_b.sql"], CUTOFF, FUTURE_START);
    expect(r.verdict).toBe(VERDICT.INVALID);
    expect(r.problems.join(" ")).toMatch(/duplicate migration number 0061/);
  });

  test("★ MUTATION: a malformed future migration name is refused", () => {
    expect(classifyMigrations([...historicalNames, "61_20260901_x.sql"], CUTOFF, FUTURE_START).verdict).toBe(VERDICT.INVALID);
    expect(classifyMigrations([...historicalNames, "0061-20260901-x.sql"], CUTOFF, FUTURE_START).verdict).toBe(VERDICT.INVALID);
  });

  test("★ MUTATION: a future migration at or below the cutoff is refused", () => {
    const below = classifyMigrations([...historicalNames, "0058_20260901_x.sql"], CUTOFF, FUTURE_START, { addedOrModified: ["0058_20260901_x.sql"] });
    expect(below.verdict).toBe(VERDICT.INVALID);
  });

  test("★ MUTATION: test-fixture content is refused for BEING A FIXTURE, not for its number", () => {
    const fixture = classifyMigrations([...historicalNames, "0061_20260901_x.sql"], CUTOFF, FUTURE_START, {
      contents: { "0061_20260901_x.sql": "-- TEST FIXTURE ONLY — NEVER A REAL MIGRATION\nselect 1;" },
    });
    expect(fixture.verdict).toBe(VERDICT.INVALID);
    expect(fixture.problems.join(" ")).toMatch(/test-fixture content may not live in db\/migrations/);
    // ...and the SAME number with real content is fine. The number was never the problem.
    expect(classifyMigrations([...historicalNames, "0061_20260901_x.sql"], CUTOFF, FUTURE_START, {
      contents: { "0061_20260901_x.sql": "alter table public.estates add column if not exists x text;" },
    }).verdict).toBe(VERDICT.OK);
  });

  test("the synthetic fixture lives outside db/migrations and is marked as a fixture", () => {
    expect(names.filter((n) => /synthetic/i.test(n))).toEqual([]);
    const fx = readFileSync(join(ROOT, "test/fixtures/synthetic_future_migration.sql"), "utf8");
    expect(FIXTURE_MARKERS.some((m) => fx.includes(m))).toBe(true);
  });

  test("no COMMITTED future migration exists today", () => {
    // * COMMITTED state, not the working tree. A temporary probe 0061 on disk is exactly what the
    //   positive control needs to create; forbidding it on disk would forbid testing the contract.
    const tracked = execSync("git ls-files db/migrations/", { cwd: ROOT, encoding: "utf8" })
      .trim().split("\n").map((n) => n.replace(/^.*\//, "")).filter((n) => n.endsWith(".sql"));
    expect(tracked.filter((n) => Number(n.slice(0, 4)) > CUTOFF)).toEqual([]);
    expect(tracked).toHaveLength(60);
  });

  test("★ CONTRADICTION GUARD: the contract's declared future start must be accepted by the validator", () => {
    // If AUTHORITY.json says future migrations begin at 0061 but the validator rejects a
    // structurally valid 0061, that is a structural contradiction and this suite must fail.
    const probe = `${String(FUTURE_START).padStart(4, "0")}_20260901_contract_probe.sql`;
    const r = classifyMigrations([...historicalNames, probe], CUTOFF, FUTURE_START);
    expect(r.verdict).toBe(VERDICT.OK);
    expect(r.future).toContain(probe);
    expect(FUTURE_START).toBe(CUTOFF + 1);
  });

  test("★ the documented rule matches the enforced rule", () => {
    const readme = readFileSync(join(ROOT, "db/bootstrap/README.md"), "utf8");
    // The corrected phrasing must be present...
    expect(readme).toMatch(/No future migration may be numbered at or below the bootstrap cutoff/i);
    expect(readme).toMatch(/Legitimate future migrations begin at 0061/i);
    // ...and the phrasing that expressed the contradiction must not return.
    expect(readme).not.toMatch(/no production migration numbered above the cutoff/i);
    expect(A.future_migration_authority.rule).toMatch(/never a ceiling on migration numbers/i);
    expect(A.future_migration_authority.adding_a_future_migration.requires_bootstrap_regeneration).toBe(false);
    expect(A.future_migration_authority.adding_a_future_migration.does_not_change).toContain("db/bootstrap/VERSION");
  });
  test("★ positive control: the guard CAN see the contradictory phrasing", () => {
    expect(/no production migration numbered above the cutoff/i.test("no production migration numbered above the cutoff")).toBe(true);
  });

  test("historical migrations: exactly 60, none modified", () => {
    expect(names.filter((n) => Number(n.slice(0, 4)) <= CUTOFF)).toHaveLength(60);
    const changed = gitChanged().filter((n) => {
      const seq = Number(n.replace(/^.*\//, "").slice(0, 4));
      return Number.isFinite(seq) && seq <= CUTOFF;
    });
    expect(changed).toEqual([]);
  });
});

describe("PHASE F — the bootstrap is a FIXED cutover base, not a rolling snapshot", () => {
  test("the contract says so explicitly, with a reason", () => {
    expect(A.bootstrap_authority.rolling).toBe(false);
    expect(A.bootstrap_authority.rolling_rationale).toMatch(/fixed cutover base/i);
  });
  test("★ MUTATION 5: historical migrations are never part of a virgin bootstrap", () => {
    expect(A.historical_migrations.virgin_bootstrap).toBe(false);
    const readme = readFileSync(join(ROOT, "db/bootstrap/README.md"), "utf8");
    expect(readme).toMatch(/never executed during a virgin bootstrap/i);
  });
  test("no bootstrap file instructs running 0001-0060 after the bootstrap", () => {
    for (const f of sqlFiles("db/bootstrap")) {
      const src = readFileSync(join(ROOT, "db/bootstrap", f), "utf8");
      expect(src).not.toMatch(/then run migrations 0001|apply migrations 0001/i);
    }
  });
});

describe("legacy compatibility surface and hosted proof are structurally recorded", () => {
  test("★ MUTATION 9: public.assets is in the canonical bootstrap", () => {
    expect(readFileSync(join(ROOT, "db/bootstrap/30_tables.sql"), "utf8")).toMatch(/CREATE TABLE IF NOT EXISTS "public"\."assets"/);
  });
  test("★ MUTATION 10: hosted compatibility cannot be marked proven without evidence", () => {
    expect(A.hosted_compatibility.proven).toBe(false);
    expect(A.hosted_compatibility.blocked_by).toMatch(/R-02/);
    expect(A.hosted_compatibility.requires_proof.length).toBeGreaterThanOrEqual(3);
    const m = JSON.parse(readFileSync(join(ROOT, "db/bootstrap/manifest.json"), "utf8"));
    expect(m.event_triggers.hosted_compatibility_proven).toBe(false);
    // Both records must agree — one flipped alone is a contradiction, not an upgrade.
    expect(m.event_triggers.hosted_compatibility_proven).toBe(A.hosted_compatibility.proven);
  });
  test("no claim of production evidence — the snapshot came from afterworth-dev", () => {
    // * THE EVIDENCE SOURCE IS afterworth-dev. Nothing in this programme has observed production,
    //   and an accurate observation about the DUMP FORMAT ("the schema-only dump omits platform
    //   schemas and event triggers") must not be restated as an observation about production. The
    //   guard covers the Model C scripts as well as the docs, because the phrasing first appeared
    //   in a comment.
    const files = ["db/bootstrap/README.md", "db/AUTHORITY.json",
      "scripts/bootstrapCutoverProof.mjs", "scripts/generateBootstrap.mjs", "scripts/bootstrapFreshRun.mjs"];
    for (const f of files) {
      const src = readFileSync(join(ROOT, f), "utf8");
      expect(src).not.toMatch(/less complete than production/i);
      expect(src).not.toMatch(/upgraded production shape/i);
    }
  });
  test("★ positive control: the guard CAN see the forbidden phrasing", () => {
    const offending = "the raw dump is strictly less complete than production";
    expect(/less complete than production/i.test(offending)).toBe(true);
  });
  test("the afterworth-dev provenance is stated where the claim is made", () => {
    expect(readFileSync(join(ROOT, "db/bootstrap/README.md"), "utf8")).toMatch(/afterworth-dev/);
    expect(readFileSync(join(ROOT, "scripts/bootstrapCutoverProof.mjs"), "utf8")).toMatch(/afterworth-dev/);
  });
});
