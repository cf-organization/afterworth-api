/**
 * CURRENT AUTHORITATIVE SCHEMA ↔ REPOSITORY RECONCILIATION — the controls.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ THIS FILE EXISTS BECAUSE THE RECONCILER WAS WRONG THREE TIMES BEFORE IT WAS RIGHT.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * 1. It reported 201/201 repository files unparseable and a 293-object bootstrap gap, because the
 *    Supabase CLI strips `--` comments from its dump and every file in db/ carries a comment header.
 *    The parser matched `^CREATE` and the repo statements began with a comment.
 * 2. It reported all 36 live policies as role `public`, because `${QN}` was embedded in a REGEX
 *    LITERAL where it never interpolates — a security-relevant field that failed OPEN.
 * 3. It reported `verification_level` and `audit_logs_id_seq` as having no repository definition.
 *    Both were false: the first is created inside a `do $$ ... $$` guard, the second implicitly by
 *    `id bigserial`. Same objects, different spellings.
 *
 * Every one of those was found by a positive control, never by reading the output and believing it.
 * A reconciliation that reports "clean" and a reconciliation that inspects nothing look identical.
 */
import { readFileSync } from "node:fs";
import { execSync } from "node:child_process";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "vitest";
import {
  inventory, splitStatements, stripComments, parseQualified, parseRoles, doBlockCreates,
  maskLiterals, policyCommand, functionHeader,
} from "../scripts/lib/schemaInventory.mjs";
import { repositoryObjects, reconcile, roleOf, parseHealth, SOURCE_ROLES } from "../scripts/lib/schemaReconcile.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");

/** The repository side is always available; the live snapshot is untracked evidence. */
const repoPaths = execSync("git ls-files db/", { cwd: ROOT, encoding: "utf8" })
  .trim().split("\n").filter((p) => p.endsWith(".sql"));
const repoFiles = repoPaths.map((p) => ({ path: p, sql: readFileSync(join(ROOT, p), "utf8") }));

describe("scan set is asserted before any rule is evaluated", () => {
  test("the repository scan set is non-empty", () => {
    expect(repoFiles.length).toBeGreaterThan(100);
  });
  test("every scanned path resolves to a known source role — a new db/ subdir cannot become invisible", () => {
    const unknown = repoPaths.filter((p) => roleOf(p).role === "unknown");
    expect(unknown).toEqual([]);
  });
  test("SOURCE_ROLES never grants bootstrap authority to db/tests", () => {
    expect(roleOf("db/tests/preamble_real_auth.sql").role).toBe("test-only");
    expect(SOURCE_ROLES.some((r) => r.match.test("db/tests/x.sql") && r.role === "base")).toBe(false);
  });
  test("★ exactly one path carries base authority — no duplicate-base is expressible", () => {
    expect(SOURCE_ROLES.filter((r) => r.role === "base")).toHaveLength(1);
  });
});

describe("comment stripping — the defect that made 201 files look unparseable", () => {
  test("a leading comment does not hide the statement that follows it", () => {
    const inv = inventory("-- public.estates — CAPTURED FROM LIVE\ncreate table if not exists public.estates (id uuid);");
    expect(inv.tables.map((t) => t.name)).toEqual(["estates"]);
    expect(inv.unclassified).toEqual([]);
  });
  test("MUTATION: without stripping, the same input yields nothing — proving the control bites", () => {
    const notStripped = "-- header\ncreate table public.x (id uuid);";
    expect(/^CREATE\s+TABLE/i.test(notStripped.trim())).toBe(false);   // the old, broken predicate
    expect(inventory(notStripped).tables.map((t) => t.name)).toEqual(["x"]); // the fixed one
  });
  test("a table named only INSIDE a comment is not a definition", () => {
    const inv = inventory("-- create table public.ghost (id uuid);\nselect 1;");
    expect(inv.tables).toEqual([]);
  });
  test("string literals survive stripping — they are real SQL, unlike comments", () => {
    expect(stripComments("select 'a -- not a comment';")).toContain("-- not a comment");
  });
});

describe("policy roles — the field that failed open", () => {
  test.each([
    ['FOR SELECT TO "authenticated" USING (true)', ["authenticated"]],
    ['FOR ALL TO "anon", "authenticated" USING (true)', ["anon", "authenticated"]],
    ["FOR SELECT USING (true)", ["public"]],
  ])("parses %s", (input, want) => {
    expect(parseRoles(input)).toEqual(want);
  });
  test("★ a TO clause present but unreadable is ?unparsed, never a silent 'public'", () => {
    expect(parseRoles("FOR SELECT TO 99999 USING (true)")).toEqual(["?unparsed"]);
  });
  test("MUTATION: the old broken regex would have returned public for an authenticated policy", () => {
    const broken = (/\bTO\s+((?:${QN}|\w+))/i.exec('FOR SELECT TO "authenticated" USING (true)') || [])[1] ?? "public";
    expect(broken).toBe("public");                       // what shipped
    expect(parseRoles('FOR SELECT TO "authenticated" USING (true)')).toEqual(["authenticated"]); // what is correct
  });
});

describe("quoted identifiers — the dump uses --quote-all-identifiers", () => {
  test.each([
    ['"public"."estates"', { schema: "public", name: "estates" }],
    ["public.estates", { schema: "public", name: "estates" }],
    ['"estates"', { schema: null, name: "estates" }],
  ])("parses %s", (input, want) => {
    expect(parseQualified(input)).toEqual(want);
  });
  test("a quoted CREATE TABLE is found", () => {
    expect(inventory('CREATE TABLE IF NOT EXISTS "public"."x" ("id" "uuid");').tables[0]).toMatchObject({ schema: "public", name: "x" });
  });
});

describe("guarded and implicit creation paths", () => {
  test("DDL inside a do-block is a real definition", () => {
    const sql = `do $$ begin if not exists (select 1 from pg_type where typname='vl') then create type public.vl as enum ('a'); end if; end $$;`;
    expect(doBlockCreates(sql).map((d) => `${d.kind}:${d.name}`)).toContain("type:vl");
    expect(inventory(sql).types.map((t) => t.name)).toContain("vl");
  });
  test("bigserial implicitly creates <table>_<col>_seq", () => {
    const inv = inventory("create table public.audit_logs (id bigserial primary key);");
    expect(inv.sequences.map((s) => s.name)).toContain("audit_logs_id_seq");
  });
  test("★ both were reported as NO_REPO_DEFINITION before this — false gaps", () => {
    const guarded = inventory(readFileSync(join(ROOT, "db/tables/jurisdiction_policy.sql"), "utf8"));
    expect(guarded.types.map((t) => t.name)).toContain("verification_level");
  });
});

describe("parser honesty — unclassified must mean 'not understood', never 'ignored'", () => {
  test("every repository file parses with zero unclassified statements", () => {
    const bad = repoFiles
      .map((f) => ({ path: f.path, n: inventory(f.sql).unclassified.length }))
      .filter((x) => x.n > 0);
    expect(bad).toEqual([]);
  });
  test("non-DDL is categorized, not discarded", () => {
    const inv = inventory("commit;\n\\echo 'hi'\ninsert into public.t values (1);");
    expect(inv.transactionControl.length).toBe(1);
    expect(inv.psqlMeta.length).toBe(1);
    expect(inv.dml.length).toBe(1);
    expect(inv.unclassified).toEqual([]);
  });
  test("★ a genuinely unknown statement IS surfaced — the instrument can still fail", () => {
    expect(inventory("FLURB TABLE public.x;").unclassified.length).toBe(1);
  });
});

describe("reconciliation detects mutation of the live side", () => {
  const baseLive = inventory(`
    CREATE TABLE IF NOT EXISTS "public"."estates" ("id" "uuid");
    CREATE OR REPLACE FUNCTION "public"."is_estate_owner"("e" "uuid") RETURNS boolean LANGUAGE "sql" AS $$ select true $$;
    CREATE POLICY "estates_owner_all" ON "public"."estates" FOR ALL TO "authenticated" USING (true);
    ALTER TABLE "public"."estates" ENABLE ROW LEVEL SECURITY;
  `);
  const repo = repositoryObjects([
    { path: "db/bootstrap/30_tables.sql", sql: `create table if not exists public.estates (id uuid);
       create policy estates_owner_all on public.estates for all using (true);
       alter table public.estates enable row level security;` },
    { path: "db/bootstrap/60_functions.sql", sql: `create or replace function public.is_estate_owner(e uuid) returns boolean language sql as $$ select true $$;` },
  ]);

  test("a fully covered schema reports no gap — the baseline", () => {
    const rows = reconcile({ live: baseLive, repo });
    expect(rows.filter((r) => r.disposition !== "COVERED")).toEqual([]);
    expect(rows.length).toBeGreaterThan(0);   // ★ never let an empty row set read as clean
  });

  test("MUTATION: removing the table from the repo is detected", () => {
    const r2 = repositoryObjects([{ path: "db/bootstrap/60_functions.sql", sql: `create or replace function public.is_estate_owner(e uuid) returns boolean language sql as $$ select true $$;` }]);
    const rows = reconcile({ live: baseLive, repo: r2 });
    expect(rows.find((r) => r.kind === "table" && r.name === "estates")?.disposition).toBe("NO_REPO_DEFINITION");
  });

  test("MUTATION: removing the function is detected", () => {
    const r2 = repositoryObjects([{ path: "db/bootstrap/30_tables.sql", sql: `create table if not exists public.estates (id uuid);
      create policy estates_owner_all on public.estates for all using (true);
      alter table public.estates enable row level security;` }]);
    const rows = reconcile({ live: baseLive, repo: r2 });
    expect(rows.find((r) => r.kind === "function" && r.name === "is_estate_owner")?.disposition).toBe("NO_REPO_DEFINITION");
  });

  test("MUTATION: an RLS enable-state present live but absent in repo is detected", () => {
    const r2 = repositoryObjects([
      { path: "db/bootstrap/30_tables.sql", sql: `create table if not exists public.estates (id uuid);
        create policy estates_owner_all on public.estates for all using (true);` },
      { path: "db/bootstrap/60_functions.sql", sql: `create or replace function public.is_estate_owner(e uuid) returns boolean language sql as $$ select true $$;` },
    ]);
    const rows = reconcile({ live: baseLive, repo: r2 });
    expect(rows.find((r) => r.kind === "rls" && r.name === "estates")?.disposition).toBe("NO_REPO_DEFINITION");
  });

  test("MUTATION: a policy defined ONLY in db/tests is not bootstrap coverage", () => {
    const r2 = repositoryObjects([
      { path: "db/tests/preamble_real_auth.sql", sql: `create table if not exists public.estates (id uuid);
        create policy estates_owner_all on public.estates for all using (true);
        alter table public.estates enable row level security;` },
      { path: "db/bootstrap/60_functions.sql", sql: `create or replace function public.is_estate_owner(e uuid) returns boolean language sql as $$ select true $$;` },
    ]);
    const rows = reconcile({ live: baseLive, repo: r2 });
    expect(rows.find((r) => r.kind === "table" && r.name === "estates")?.disposition).toBe("TEST_ONLY_DEFINITION");
  });

  test("MUTATION: a migration-only CREATE is DELTA_ONLY_NO_BASE, never COVERED", () => {
    const r2 = repositoryObjects([
      { path: "db/migrations/0011_20260707_x.sql", sql: `create table if not exists public.estates (id uuid);
        create policy estates_owner_all on public.estates for all using (true);
        alter table public.estates enable row level security;` },
      { path: "db/bootstrap/60_functions.sql", sql: `create or replace function public.is_estate_owner(e uuid) returns boolean language sql as $$ select true $$;` },
    ]);
    const rows = reconcile({ live: baseLive, repo: r2 });
    expect(rows.find((r) => r.kind === "table" && r.name === "estates")?.disposition).toBe("DELTA_ONLY_NO_BASE");
  });

  test("★ a repository-only object does NOT appear as live coverage — reconciliation is live-anchored", () => {
    const r2 = repositoryObjects([
      ...[{ path: "db/bootstrap/30_tables.sql", sql: `create table if not exists public.estates (id uuid);
        create policy estates_owner_all on public.estates for all using (true);
        alter table public.estates enable row level security;` },
      { path: "db/bootstrap/60_functions.sql", sql: `create or replace function public.is_estate_owner(e uuid) returns boolean language sql as $$ select true $$;` }],
      { path: "db/bootstrap/30_phantom.sql", sql: `create table if not exists public.phantom (id uuid);` },
    ]);
    const rows = reconcile({ live: baseLive, repo: r2 });
    expect(rows.some((r) => r.name === "phantom")).toBe(false);
  });

  test("current-state and historical-delta roles cannot collapse", () => {
    // Re-anchored on db/bootstrap. When this was written db/tables carried base authority; the
    // authority consolidation deliberately removed that (see db/AUTHORITY.json), so the fixture
    // moved to the path that carries it now. The property under test is unchanged: base and delta
    // must remain distinct roles, and no legacy path may hold base authority.
    expect(roleOf("db/bootstrap/30_tables.sql").role).toBe("base");
    expect(roleOf("db/migrations/0001_x.sql").role).toBe("delta");
    expect(roleOf("db/bootstrap/30_tables.sql").role).not.toBe(roleOf("db/migrations/0001_x.sql").role);
    expect(roleOf("db/tables/x.sql").role).toBe("legacy-compat");
    expect(roleOf("db/functions/x.sql").role).toBe("legacy-compat");
  });
});

describe("determinism — the guard against stateful matchers", () => {
  // CPU-bound, not slow-by-defect: it parses all 215 db/ SQL files TWICE, which is the whole point.
  // 0.4-1.1s alone, but up to ~8s when 35 suites run in parallel on a loaded machine. The default
  // 5s timeout was measuring contention rather than the property. Raised deliberately, with the
  // measurement recorded, rather than quietly retried until green.
  test("two runs in one process produce identical results", () => {
    const a = JSON.stringify(reconcile({ live: inventory(repoFiles[0].sql), repo: repositoryObjects(repoFiles) }));
    const b = JSON.stringify(reconcile({ live: inventory(repoFiles[0].sql), repo: repositoryObjects(repoFiles) }));
    expect(a).toBe(b);
  }, 30_000);
  test("splitStatements is stable across repeated calls", () => {
    const sql = readFileSync(join(ROOT, "db/tables/estates.sql"), "utf8");
    expect(splitStatements(sql).length).toBe(splitStatements(sql).length);
    expect(splitStatements(sql)).toEqual(splitStatements(sql));
  });
});


/* ══════════════════════════════════════════════════════════════════════════════════════════════
 * MODEL C RATIFICATION GATE — the fail-closed proofs.
 *
 * ★ parseRoles FAILED OPEN THROUGH THREE SUCCESSIVE "FIXES". First it never matched at all (every
 *   policy read as PUBLIC). Then it distinguished absent from unreadable but still accepted a
 *   PREFIX, so `TO "authenticated", 99999` silently dropped a role it could not read. Then the
 *   rewrite truncated every identifier by one character. Each version had a comment asserting the
 *   property it did not have. These tests exist because the comments were not evidence.
 * ══════════════════════════════════════════════════════════════════════════════════════════════ */

describe("A2/A4 · role parsing fails CLOSED for every malformed form", () => {
  test.each([
    ['TO "authenticated"', ["authenticated"], "quoted single"],
    ['TO "anon", "authenticated"', ["anon", "authenticated"], "quoted multiple"],
    ["TO service_role, anon USING (true)", ["service_role", "anon"], "unquoted multiple"],
    ["TO PUBLIC USING (true)", ["public"], "explicit PUBLIC"],
    ["TO CURRENT_USER USING (true)", ["current_user"], "CURRENT_USER"],
    ["USING (true)", ["public"], "omitted TO is legal and means PUBLIC"],
    ['TO "authenticated" WITH CHECK (true)', ["authenticated"], "WITH CHECK terminator"],
    ['TO "authenticated" AS RESTRICTIVE USING (true)', ["authenticated"], "AS terminator"],
  ])("%s parses", (input, want) => {
    expect(parseRoles(input)).toEqual(want);
  });

  test.each([
    ["TO 99999 USING (true)", "unexpected role token"],
    ['TO "authenticated", 99999 USING (true)', "★ PARTIAL parse must not silently drop a role"],
    ['TO "authenticated", USING (true)', "★ trailing comma must not yield a role named 'using'"],
    ['TO , "authenticated" USING (true)', "leading comma"],
    ['TO "a",, "b" USING (true)', "double comma"],
    ["", "empty input"],
  ])("%s => ?unparsed (%s)", (input) => {
    expect(parseRoles(input)).toEqual(["?unparsed"]);
  });

  test("null/undefined never assert a role", () => {
    expect(parseRoles(null as unknown as string)).toEqual(["?unparsed"]);
    expect(parseRoles(undefined as unknown as string)).toEqual(["?unparsed"]);
  });

  test("★ TO inside a STRING LITERAL is not a TO clause", () => {
    expect(parseRoles("FOR SELECT USING (note = 'TO PUBLIC')")).toEqual(["public"]);
    expect(parseRoles(`TO "authenticated" USING (n = 'TO anon')`)).toEqual(["authenticated"]);
  });

  test("MUTATION: a prefix-matching grammar would pass the valid cases and fail the partial one", () => {
    const prefixOnly = (rest: string) => (/\bTO\s+("(?:[^"]|"")*")/i.exec(rest) || [])[1]?.replace(/"/g, "") ?? "public";
    expect(prefixOnly('TO "authenticated", 99999 USING (true)')).toBe("authenticated");   // the defect
    expect(parseRoles('TO "authenticated", 99999 USING (true)')).toEqual(["?unparsed"]);  // the fix
  });

  test("MUTATION: identifiers are not truncated — the one-char-short regression", () => {
    expect(parseRoles("TO PUBLIC USING (true)")).toEqual(["public"]);      // once returned "publi"
    expect(parseRoles("TO service_role, anon USING (true)")).toEqual(["service_role", "anon"]); // once "ano"
  });
});

describe("A4 · policy command fails closed", () => {
  test("absent FOR means ALL — Postgres semantics, not a guess", () => {
    expect(policyCommand("TO \"anon\" USING (true)")).toBe("ALL");
  });
  test.each(["ALL", "SELECT", "INSERT", "UPDATE", "DELETE"])("FOR %s", (c) => {
    expect(policyCommand(`FOR ${c} TO "anon" USING (true)`)).toBe(c);
  });
  test("★ an unreadable FOR does NOT become the most permissive value", () => {
    expect(policyCommand('FOR FLURB TO "anon" USING (true)')).toBe("?unparsed");
  });
});

describe("A4 · function attributes come from the header, never the body", () => {
  const mk = (tail: string) => inventory(`CREATE FUNCTION "public"."f"() RETURNS void ${tail}`).functions[0];
  test("real header attributes are read", () => {
    const f = mk(`LANGUAGE "plpgsql" SECURITY DEFINER SET "search_path" TO 'pg_catalog' AS $$ BEGIN END $$;`);
    expect(f).toMatchObject({ language: "plpgsql", securityDefiner: true, setsSearchPath: true });
  });
  test("★ SECURITY DEFINER inside the body is not an attribute", () => {
    expect(mk(`LANGUAGE "sql" AS $$ select 'SECURITY DEFINER' $$;`).securityDefiner).toBe(false);
  });
  test("★ a body mentioning search_path does NOT satisfy the search_path check", () => {
    const f = mk(`LANGUAGE "plpgsql" SECURITY DEFINER AS $$ BEGIN /* set search_path to x */ END $$;`);
    expect(f.securityDefiner).toBe(true);
    expect(f.setsSearchPath).toBe(false);
  });
  test("functionHeader stops at the body delimiter", () => {
    expect(functionHeader(` void LANGUAGE "sql" AS $$ SECURITY DEFINER $$`)).not.toMatch(/SECURITY/i);
  });
});

describe("A4 · dollar-quoted bodies and complex expressions do not confuse the parser", () => {
  test("a body containing CREATE TABLE and INSERT and semicolons yields ONE function and no phantom objects", () => {
    const inv = inventory(`CREATE FUNCTION "public"."f"() RETURNS void LANGUAGE "plpgsql" AS $$ BEGIN CREATE TABLE ghost(); INSERT INTO ghost VALUES(1); END $$;`);
    expect(inv.functions).toHaveLength(1);
    expect(inv.tables).toEqual([]);
    expect(inv.dml).toEqual([]);
    expect(inv.unclassified).toEqual([]);
  });
  test("policy expressions with commas and nested parens parse", () => {
    const p = inventory(`CREATE POLICY "p" ON "public"."t" FOR SELECT TO "authenticated" USING ((a=1) AND f(b,c,(d,e)));`).policies[0];
    expect(p.roles).toEqual(["authenticated"]);
    expect(p.command).toBe("SELECT");
  });
  test("CREATE OR REPLACE is recognised for functions and triggers", () => {
    expect(inventory(`CREATE OR REPLACE FUNCTION "public"."f"() RETURNS void LANGUAGE "sql" AS $$ select 1 $$;`).functions).toHaveLength(1);
    expect(inventory(`CREATE OR REPLACE TRIGGER "t" BEFORE INSERT ON "public"."x" FOR EACH ROW EXECUTE FUNCTION "public"."f"();`).triggers).toHaveLength(1);
  });
  test("multiline CREATE TABLE parses every column", () => {
    expect(inventory(`CREATE TABLE "public"."t" (\n "a" "uuid",\n "b" "text" NOT NULL,\n "c" integer DEFAULT 1\n);`).columns).toHaveLength(3);
  });
  test("maskLiterals preserves length so indices stay aligned", () => {
    const src = `TO "x" USING (n = 'hello')`;
    expect(maskLiterals(src)).toHaveLength(src.length);
  });
});

describe("A5 · the two historical false results cannot recur", () => {
  test("★ comment-prefixed valid files are NOT reported unparseable (the '201/201' regression)", () => {
    const bad = repoFiles.map((f) => ({ path: f.path, n: inventory(f.sql).unclassified.length })).filter((x) => x.n > 0);
    expect(bad).toEqual([]);
    expect(repoFiles.length).toBeGreaterThan(100);
  });
  test("★ a comment header before CREATE TABLE and CREATE FUNCTION does not hide either", () => {
    expect(inventory("-- header\n-- more\ncreate table public.t (id uuid);").tables.map((t) => t.name)).toEqual(["t"]);
    expect(inventory("-- header\ncreate function public.f() returns void language sql as $$ select 1 $$;").functions.map((f) => f.name)).toEqual(["f"]);
  });
  test("★ the synthetic giant gap cannot recur: a fully-covered pair reports zero gaps", () => {
    const live = inventory(`CREATE TABLE IF NOT EXISTS "public"."t" ("id" "uuid");`);
    const repo = repositoryObjects([{ path: "db/bootstrap/30_tables.sql", sql: "-- a comment header\ncreate table if not exists public.t (id uuid);" }]);
    const rows = reconcile({ live, repo });
    expect(rows).toHaveLength(1);
    expect(rows[0].disposition).toBe("COVERED");
  });
});

describe("A6 · a degraded parse can never report clean", () => {
  const okLive = inventory(`CREATE TABLE IF NOT EXISTS "public"."t" ("id" "uuid");
    CREATE POLICY "p" ON "public"."t" FOR SELECT TO "authenticated" USING (true);`);
  const okRepo = repositoryObjects([{ path: "db/bootstrap/30_tables.sql", sql: "create table if not exists public.t (id uuid);\ncreate policy p on public.t for select to authenticated using (true);" }]);

  test("a healthy pair passes the gate", () => {
    expect(parseHealth({ live: okLive, repo: okRepo })).toEqual({ ok: true, problems: [] });
  });
  test("MUTATION: an unparsed policy role fails the gate", () => {
    const live = inventory(`CREATE TABLE IF NOT EXISTS "public"."t" ("id" "uuid");
      CREATE POLICY "p" ON "public"."t" FOR SELECT TO "authenticated", 99999 USING (true);`);
    const h = parseHealth({ live, repo: okRepo });
    expect(h.ok).toBe(false);
    expect(h.problems.join(" ")).toMatch(/role list\(s\) unparsed/);
  });
  test("MUTATION: an unparsed policy command fails the gate", () => {
    const live = inventory(`CREATE TABLE IF NOT EXISTS "public"."t" ("id" "uuid");
      CREATE POLICY "p" ON "public"."t" FOR FLURB TO "authenticated" USING (true);`);
    expect(parseHealth({ live, repo: okRepo }).ok).toBe(false);
  });
  test("MUTATION: an unclassified statement fails the gate", () => {
    expect(parseHealth({ live: inventory(`CREATE TABLE "public"."t" ("id" "uuid"); FLURB TABLE "public"."x";`), repo: okRepo }).ok).toBe(false);
  });
  test("MUTATION: a data-bearing snapshot fails the gate", () => {
    expect(parseHealth({ live: inventory(`CREATE TABLE "public"."t" ("id" "uuid"); INSERT INTO "public"."t" VALUES (1);`), repo: okRepo }).ok).toBe(false);
  });
  test("MUTATION: an empty snapshot fails the gate — never 'clean'", () => {
    const h = parseHealth({ live: inventory(""), repo: okRepo });
    expect(h.ok).toBe(false);
    expect(h.problems.join(" ")).toMatch(/zero tables|empty scan set/);
  });
  test("MUTATION: an unknown repository source path fails the gate", () => {
    const repo = repositoryObjects([{ path: "db/mystery/x.sql", sql: "create table public.t (id uuid);" }]);
    expect(parseHealth({ live: okLive, repo }).ok).toBe(false);
  });
});
