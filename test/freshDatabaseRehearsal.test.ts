/**
 * FRESH-DATABASE MIGRATION REHEARSAL — the pins.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ WHAT THESE TESTS GUARD, AND WHY THEY ARE NOT THE REHEARSAL ITSELF.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * The rehearsal's real proof is Postgres executing sixty files. That takes a container and ninety
 * seconds, so the rules that decide WHAT gets executed — discovery, ordering, emptiness, duplicate
 * detection — are pure functions pinned here, where they can be mutation-tested cheaply and re-run
 * on every commit.
 *
 * ★ THE SET IS COMPARED AGAINST THE REAL DIRECTORY, not a hand-written list. A second copy of the
 *   migration inventory would drift the first time somebody added a migration, and the audit would
 *   go on reporting green about a set that no longer exists.
 */
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "vitest";
import {
  MIGRATION_FILENAME,
  REHEARSAL,
  discoverMigrations,
  rehearsalExitCode,
  tableOperations,
  tablesTouched,
  unsatisfiedTableReferences,
} from "../scripts/lib/freshDatabaseRehearsal.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const MIGRATIONS_DIR = join(ROOT, "db/migrations");
const RUNNER = join(ROOT, "scripts/rehearseFreshDatabase.mjs");

/**
 * ★ THE HISTORICAL RANGE, READ FROM db/bootstrap/VERSION — NOT HARD-CODED.
 *
 * This suite pins a finding about the RECORDED HISTORY: it cannot build a database from zero.
 * Under the ratified Model C contract, migrations 0061+ are never expected to build from zero —
 * they layer on db/bootstrap@0060. Scanning the whole directory let a legitimate future migration
 * perturb a pinned historical fact: a real 0061 that ALTERs `estates` turned "exactly 5 unsatisfied
 * tables" into 6 and failed two tests that are describing 0001-0060.
 */
const BOOTSTRAP_CUTOFF = Number(readFileSync(join(ROOT, "db/bootstrap/VERSION"), "utf8").trim());
const historicalOnly = (names: string[]) =>
  names.filter((n) => { const q = Number(String(n).slice(0, 4)); return Number.isFinite(q) && q <= BOOTSTRAP_CUTOFF; });

describe("0 · the scan set is real before any rule is believed", () => {
  test("the migration directory exists and is non-empty", () => {
    expect(existsSync(MIGRATIONS_DIR)).toBe(true);
    expect(readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith(".sql")).length).toBeGreaterThan(0);
  });

  test("★ discovery equals the files actually on disk — no hand-written second inventory", () => {
    const onDisk = readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith(".sql")).sort();
    const found = discoverMigrations(readdirSync(MIGRATIONS_DIR));
    expect(found.ok).toBe(true);
    expect(found.ordered).toEqual(onDisk);
  });

  test("every real migration filename matches the declared convention", () => {
    for (const f of readdirSync(MIGRATIONS_DIR).filter((f) => f.endsWith(".sql"))) {
      expect(MIGRATION_FILENAME.test(f), `${f} does not match the convention`).toBe(true);
    }
  });

  test("★ repeated discovery is identical — no stateful matcher", () => {
    const a = discoverMigrations(readdirSync(MIGRATIONS_DIR));
    const b = discoverMigrations(readdirSync(MIGRATIONS_DIR));
    expect(a).toEqual(b);
  });
});

describe("★ 1 · an empty or unusable set FAILS, never passes", () => {
  test("★ zero migrations is a failure, not a clean rehearsal", () => {
    const r = discoverMigrations([]);
    expect(r.ok).toBe(false);
    expect(r.problems.join(" ")).toContain("empty");
  });

  test("a directory holding no .sql is the same failure", () => {
    expect(discoverMigrations(["README.md", "notes.txt"]).ok).toBe(false);
  });

  test("★ an unparseable filename is refused, not silently skipped", () => {
    const r = discoverMigrations(["0001_20260616_a.sql", "banana.sql"]);
    expect(r.ok).toBe(false);
    expect(r.problems.join(" ")).toContain("banana.sql");
  });
});

describe("★ 2 · ordering is asserted, not assumed", () => {
  test("canonical order is lexical while widths are equal", () => {
    const r = discoverMigrations(["0010_20260101_b.sql", "0002_20260101_a.sql", "0001_20260101_c.sql"]);
    expect(r.ok).toBe(true);
    expect(r.ordered).toEqual(["0001_20260101_c.sql", "0002_20260101_a.sql", "0010_20260101_b.sql"]);
  });

  test("★ a duplicate sequence number is refused — the order would be ambiguous", () => {
    const r = discoverMigrations(["0001_20260101_a.sql", "0001_20260102_b.sql"]);
    expect(r.ok).toBe(false);
    expect(r.problems.join(" ")).toContain("duplicate migration sequence 0001");
  });

  /**
   * ★ MIXED WIDTHS ARE REFUSED BY THE FILENAME RULE, AND THAT IS THE WHOLE MECHANISM. An explicit
   * width comparison was written first and removed when mutation testing proved it unreachable:
   * `MIGRATION_FILENAME` admits exactly four digits, so a three-digit prefix never survives to be
   * compared. This asserts the behaviour at the layer that actually produces it.
   */
  test("★ a mixed-width prefix is refused — lexical order could otherwise stop equalling numeric", () => {
    const r = discoverMigrations(["999_20260101_a.sql", "1000_20260101_b.sql"]);
    expect(r.ok).toBe(false);
    expect(r.problems.join(" ")).toContain("999_20260101_a.sql");
  });

  test("the real set has one width and no duplicates", () => {
    const seqs = readdirSync(MIGRATIONS_DIR)
      .filter((f) => MIGRATION_FILENAME.test(f))
      .map((f) => MIGRATION_FILENAME.exec(f)![1]);
    expect(new Set(seqs.map((s) => s.length)).size).toBe(1);
    expect(new Set(seqs).size).toBe(seqs.length);
  });
});

describe("★ 3 · the dependency pre-flight sees what the SQL really does", () => {
  test("create and alter are both recognised", () => {
    const t = tablesTouched("create table if not exists public.a (id int);\nalter table public.b add column x int;");
    expect([...t.created]).toEqual(["a"]);
    expect([...t.altered]).toEqual(["b"]);
  });

  test("★ preprocessing control — a table named only in a COMMENT is not touched", () => {
    expect([...tablesTouched("-- alter table public.ghost add column x int;").altered]).toEqual([]);
    expect([...tablesTouched("/* create table public.ghost (id int); */").created]).toEqual([]);
  });

  test("★ preprocessing control — a table named in a STRING literal IS still seen", () => {
    // Every policy body and raise message in this repo is a string; erasing them would blind the rule.
    expect([...tablesTouched("do $$ begin execute 'alter table public.real add column x int'; end $$;").altered])
      .toEqual(["real"]);
  });

  test("a table created earlier satisfies a later alter", () => {
    const gaps = unsatisfiedTableReferences([
      { name: "0001_a.sql", sql: "create table public.t (id int);" },
      { name: "0002_b.sql", sql: "alter table public.t add column x int;" },
    ]);
    expect(gaps).toEqual([]);
  });

  test("★ detection — altering a table nothing created is reported, with its migration named", () => {
    const gaps = unsatisfiedTableReferences([{ name: "0001_a.sql", sql: "alter table public.missing add column x int;" }]);
    expect(gaps).toEqual([{ migration: "0001_a.sql", table: "missing" }]);
  });

  test("★ order matters — the same two files reversed become a gap", () => {
    const gaps = unsatisfiedTableReferences([
      { name: "0002_b.sql", sql: "alter table public.t add column x int;" },
      { name: "0001_a.sql", sql: "create table public.t (id int);" },
    ]);
    expect(gaps).toEqual([{ migration: "0002_b.sql", table: "t" }]);
  });
});

describe("★ 3b · REGRESSION — the within-file ordering defect", () => {
  /**
   * ★ THIS PINS A DEFECT THAT SHIPPED. The first pre-flight held `created` and `altered` as two
   * SETS and checked every alter before recording any creation from the same file, so a migration
   * that creates a table and then alters it accused itself of a missing dependency. It inflated the
   * published finding from 5 real gaps to 36 — 31 of them files complaining about their own tables.
   */
  test("★ a table CREATED then ALTERED in the same file is NOT a missing dependency", () => {
    const gaps = unsatisfiedTableReferences([
      { name: "0001_a.sql", sql: "create table public.foo (id int);\nalter table public.foo add column x int;" },
    ]);
    expect(gaps).toEqual([]);
  });

  test("★ POSITIVE CONTROL — a genuinely missing table is still detected", () => {
    const gaps = unsatisfiedTableReferences([{ name: "0001_a.sql", sql: "alter table public.bar add column x int;" }]);
    expect(gaps).toEqual([{ migration: "0001_a.sql", table: "bar" }]);
  });

  test("★ order WITHIN a file is respected — alter before create in one file IS a gap", () => {
    const gaps = unsatisfiedTableReferences([
      { name: "0001_a.sql", sql: "alter table public.baz add column x int;\ncreate table public.baz (id int);" },
    ]);
    expect(gaps).toEqual([{ migration: "0001_a.sql", table: "baz" }]);
  });

  test("tableOperations reports operations in source order", () => {
    const ops = tableOperations("alter table public.b add column x int; create table public.a (id int);");
    expect(ops.map((o) => `${o.op}:${o.table}`)).toEqual(["alter:b", "create:a"]);
  });

  test("★ the real set has exactly 5 distinct unsatisfied tables — the corrected figure", () => {
    const names = historicalOnly(discoverMigrations(readdirSync(MIGRATIONS_DIR)).ordered);
    const files = names.map((name) => ({ name, sql: readFileSync(join(MIGRATIONS_DIR, name), "utf8") }));
    const distinct = [...new Set(unsatisfiedTableReferences(files).map((g) => g.table))].sort();
    expect(distinct).toEqual(["beneficiaries", "claim_packets", "documents", "invitations", "notifications"]);
  });
});

describe("★ 4 · no remote target is expressible", () => {
  const src = readFileSync(RUNNER, "utf8");
  const code = src.replace(/\/\*[\s\S]*?\*\//g, " ").replace(/^\s*\/\/.*$/gm, " ");

  test("★ the runner reads no Supabase URL, project ref or service key", () => {
    for (const forbidden of ["SUPABASE_URL", "SERVICE_ROLE", "ANON_KEY", "supabase.co"]) {
      expect(code, `${forbidden} must not appear in executable code`).not.toContain(forbidden);
    }
  });

  test("★ it reads no .env and no process.env database configuration", () => {
    expect(code).not.toMatch(/\.env\b/);
    expect(code).not.toMatch(/process\.env\.[A-Z_]*(URL|KEY|PASSWORD|DSN|HOST)/);
  });

  /**
   * ★ BEHAVIOURAL, BECAUSE THE SOURCE-STRING VERSION SURVIVED A MUTATION. The first form asserted
   * `code.toContain("FORBIDDEN_ARGS")`, which a rename to `FORBIDDEN_ARGS_DISABLED` satisfied
   * happily while the refusal was switched off. Running the binary is the only form that cannot be
   * satisfied by a rename.
   */
  test("★ every remote-target flag is REFUSED by the running instrument, not merely absent", () => {
    for (const flag of ["--database-url=x", "--project-ref=x", "--remote", "--production", "--host=x", "--dsn=x"]) {
      const r = spawnSync(process.execPath, [RUNNER, flag], { encoding: "utf8" });
      expect(r.status, `${flag} was not refused`).toBe(2);
      expect(`${r.stderr}${r.stdout}`).toContain("REFUSED");
    }
  });

  test("the container name is derived by the runner and scoped to this process", () => {
    expect(code).toMatch(/aw-fresh-db-rehearsal-\$\{process\.pid\}/);
  });

  test("★ cleanup runs on both the success and the failure path", () => {
    expect(code).toContain("finally");
    expect(code).toContain("removeContainer()");
  });

  test("★ POSITIVE CONTROL — these string rules can see a term that IS present", () => {
    expect(code).toContain("docker");
  });
});

describe("★ 5 · verdict vocabulary is closed and never a bare pass", () => {
  test("exit codes: built 0 · failed 1 · unverifiable 2", () => {
    expect(rehearsalExitCode(REHEARSAL.BUILT)).toBe(0);
    expect(rehearsalExitCode(REHEARSAL.FAILED)).toBe(1);
    expect(rehearsalExitCode(REHEARSAL.UNVERIFIABLE)).toBe(2);
  });

  test("★ an unknown verdict is NOT a pass", () => {
    expect(rehearsalExitCode("SOMETHING_ELSE")).toBe(2);
  });
});

describe("★ 6 · the recorded finding — this history does not build from zero", () => {
  /**
   * ★ THIS TEST PINS A FINDING, NOT A DESIRED STATE. The real migration set ALTERs tables no
   *   migration creates, so `db/migrations/` alone cannot construct the schema. It is asserted here
   *   so that the day somebody repairs the history, this test fails and forces the docs, the risk
   *   register and the CI wiring to be updated in the same change — rather than the repair landing
   *   quietly and the finding outliving it.
   */
  test("★ the real migration set still has unsatisfied table references", () => {
    const names = historicalOnly(discoverMigrations(readdirSync(MIGRATIONS_DIR)).ordered);
    const files = names.map((name) => ({ name, sql: readFileSync(join(MIGRATIONS_DIR, name), "utf8") }));
    const gaps = unsatisfiedTableReferences(files);
    expect(gaps.length).toBeGreaterThan(0);
    expect(gaps[0].migration).toBe(names[0]);
    expect(gaps[0].table).toBe("beneficiaries");
    // Corrected figure: 5 distinct tables, not the 36 the defective pre-flight reported.
    expect(new Set(gaps.map((g) => g.table)).size).toBe(5);
  });

  test("the base schema those migrations assume is not in db/tables or db/migrations", () => {
    const inTables = existsSync(join(ROOT, "db/tables/beneficiaries.sql"));
    expect(inTables).toBe(false);
  });
});
