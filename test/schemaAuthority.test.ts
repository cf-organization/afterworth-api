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
  const migrationNumbers = readdirSync(join(ROOT, "db/migrations"))
    .filter((f) => /^\d{4}_/.test(f)).map((f) => Number(f.slice(0, 4)));

  test("VERSION is exactly four digits", () => {
    expect(VERSION).toMatch(/^\d{4}$/);
    expect(VERSION).toBe("0060");
  });
  test("★ MUTATION 4: a malformed or lower VERSION is rejected", () => {
    const valid = (v: string, maxHistorical: number) => /^\d{4}$/.test(v) && Number(v) >= maxHistorical;
    const maxHistorical = Math.max(...migrationNumbers);
    expect(valid(VERSION, maxHistorical)).toBe(true);
    expect(valid("60", maxHistorical)).toBe(false);        // malformed
    expect(valid("garbage", maxHistorical)).toBe(false);   // garbage
    expect(valid("0059", maxHistorical)).toBe(false);      // lower than the historical cutoff
  });
  test("VERSION is >= every historical migration number", () => {
    expect(Number(VERSION)).toBeGreaterThanOrEqual(Math.max(...migrationNumbers));
  });
  test("★ MUTATION 11: no production migration may be numbered <= the cutoff after cutover", () => {
    // Existing 0001-0060 are historical and legitimate; the rule binds NEW files only.
    expect(migrationNumbers.filter((n) => n > Number(VERSION))).toEqual([]);
    const wouldBeRejected = (n: number) => n <= Number(VERSION);
    expect(wouldBeRejected(60)).toBe(true);
    expect(wouldBeRejected(61)).toBe(false);
  });
  test("★ MUTATION 12: the synthetic fixture is not in the real migrations directory", () => {
    const names = readdirSync(join(ROOT, "db/migrations"));
    expect(names.filter((n) => /synthetic/i.test(n))).toEqual([]);
    expect(names.filter((n) => /^0061/.test(n))).toEqual([]);
    expect(existsSync(join(ROOT, "test/fixtures/synthetic_future_migration.sql"))).toBe(true);
  });
  test("historical migrations count exactly 60 and none was modified", () => {
    expect(migrationNumbers.length).toBe(60);
    expect(execSync("git status --porcelain db/migrations/", { cwd: ROOT, encoding: "utf8" }).trim()).toBe("");
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
