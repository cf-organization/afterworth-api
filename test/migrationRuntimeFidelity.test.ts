/**
 * MIGRATIONS MUST NOT DEPEND ON THE TEST HARNESS'S FAKE OF A SUPABASE-MANAGED TABLE.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ THIS SUITE EXISTS BECAUSE A DEPLOYMENT ABORTED IN PRODUCTION.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * Migration 0060's behavioural self-check created its fixture with:
 *
 *     insert into auth.users default values returning id into v_owner;
 *
 * That passed every local replay and failed the first production paste:
 *
 *     0060 FAILED: the behavioural self-check could not run:
 *     null value in column "id" of relation "users" violates not-null constraint (23502)
 *
 * `db/tests/preamble_real_auth.sql` defines a SIMPLIFIED `auth.users` — `id uuid primary key default
 * gen_random_uuid()` — because the suite needs somewhere to hang synthetic identities. Real Supabase
 * has NO default on that column; GoTrue supplies the id. So the statement was only ever exercised
 * against a fake boundary, and the fake was more permissive than the real thing.
 *
 * ★ THE FAILURE CLASS IS ALREADY NAMED IN AGENTS.md, TWICE. "A dependency-injection seam is not
 * tested if every test replaces the production default", and "the type checker is not a runtime".
 * This is the same shape with the substitution one layer down: the SCHEMA under test was the
 * harness's, not the product's, and nothing compared them.
 *
 * ★ WHY A STATIC RULE RATHER THAN A BETTER FIXTURE. The suite cannot instantiate the real
 * `auth.users`; that is the whole reason the fake exists. When the harness cannot faithfully model
 * the boundary, the honest move is to forbid migrations from depending on it at all — a migration
 * that never writes to a Supabase-managed table cannot be wrong about its defaults.
 *
 * ★ THE SUITE FILES ARE DELIBERATELY OUT OF SCOPE. `db/tests/*.sql` runs ONLY against the harness,
 * where fabricating an `auth.users` row is legitimate and necessary — §12 of the release-safety
 * suite builds interleaved episodes that way. The rule governs artifacts an operator PASTES.
 */
import { describe, expect, it } from "vitest";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const MIGRATIONS = path.join(ROOT, "db/migrations");
const BUNDLES = path.join(ROOT, "db/bundles");

/**
 * ★ COMMENTS ARE STRIPPED BEFORE MATCHING, AND STRINGS ARE NOT.
 *
 * Migration 0060 documents the defect in prose — quoting the offending statement in order to explain
 * why it is gone. A matcher that read comments would flag the file that fixed the problem, which is
 * the phantom-debt direction of the same mistake this programme has now hit in both directions.
 * String literals stay: a `raise exception` message is code, and a future violation could hide in an
 * `execute format(...)`.
 */
const stripComments = (sql: string): string =>
  sql.replace(/\/\*[\s\S]*?\*\//g, "").replace(/--[^\n]*/g, "");

const sqlFiles = (dir: string): string[] =>
  fs.readdirSync(dir).filter((f) => f.endsWith(".sql")).sort();

/**
 * Tables Supabase owns and the harness only pretends to model. A write to any of these from a pasted
 * artifact is a bet on a schema this repository does not control.
 */
const MANAGED_TABLES = ["auth.users", "auth.identities", "auth.sessions", "auth.mfa_factors"];
const WRITE = "(insert\\s+into|update|delete\\s+from)";

describe("0 · the scan set is real and non-empty", () => {
  it("resolves a migrations directory containing files", () => {
    // ★ THE DASHBOARD NEAR-MISS. An audit that resolved its root one directory short ran 63
    // assertions against an empty file list and passed. Assert the set BEFORE evaluating any rule.
    expect(fs.existsSync(MIGRATIONS)).toBe(true);
    expect(sqlFiles(MIGRATIONS).length).toBeGreaterThan(50);
  });

  it("resolves a bundles directory containing files", () => {
    expect(fs.existsSync(BUNDLES)).toBe(true);
    expect(sqlFiles(BUNDLES).length).toBeGreaterThan(10);
  });

  it("★ POSITIVE CONTROL — the matcher finds a write when one is present", () => {
    // Without this, a broken regex would report every file clean and the suite would be a decoration.
    const planted = stripComments("do $$ begin\n  insert into auth.users default values;\nend $$;");
    expect(new RegExp(`${WRITE}\\s+auth\\.users`, "i").test(planted)).toBe(true);
  });

  it("★ POSITIVE CONTROL — the stripper removes comments but keeps code strings", () => {
    const probe = stripComments(
      "-- insert into auth.users default values\nraise exception 'keep_me';"
    );
    expect(probe).not.toContain("insert into auth.users");
    expect(probe).toContain("'keep_me'");
  });
});

describe("1 · no pasted artifact writes to a Supabase-managed table", () => {
  const targets: Array<[string, string]> = [
    ...sqlFiles(MIGRATIONS).map((f) => [`db/migrations/${f}`, path.join(MIGRATIONS, f)] as [string, string]),
    ...sqlFiles(BUNDLES).map((f) => [`db/bundles/${f}`, path.join(BUNDLES, f)] as [string, string]),
  ];

  it.each(targets)("%s writes to no managed table", (_label, file) => {
    const code = stripComments(fs.readFileSync(file, "utf8"));
    for (const table of MANAGED_TABLES) {
      const re = new RegExp(`${WRITE}\\s+${table.replace(".", "\\.")}`, "i");
      expect(
        re.test(code),
        `${_label} writes to ${table}. The harness's fake of that table is more permissive than ` +
          `Supabase's real one — 0060 aborted a production paste on exactly this, because ` +
          `auth.users.id has no default outside db/tests/preamble_real_auth.sql. A pasted artifact ` +
          `must not depend on a schema this repository does not control.`
      ).toBe(false);
    }
  });
});

describe("2 · the harness fake is acknowledged, not forgotten", () => {
  it("the preamble's auth.users is MORE permissive than Supabase's — recorded here as the reason", () => {
    const preamble = fs.readFileSync(path.join(ROOT, "db/tests/preamble_real_auth.sql"), "utf8");
    // ★ THIS IS THE FACT THE RULE ABOVE EXISTS FOR. If the harness ever stopped defaulting `id`,
    // the divergence would close and this test would tell the next reader why the rule is here.
    expect(preamble).toMatch(/create table if not exists auth\.users[\s\S]{0,200}default gen_random_uuid\(\)/);
  });

  it("db/tests MAY write to auth.users — the rule governs pasted artifacts only", () => {
    // A positive control on the SCOPE of the rule. The release-safety suite fabricates identities on
    // purpose; if it ever stopped, §12's interleaved-episode fixtures would have quietly vanished.
    const suite = stripComments(
      fs.readFileSync(path.join(ROOT, "db/tests/release_safety_authorization.sql"), "utf8")
    );
    expect(/insert\s+into\s+auth\.users/i.test(suite)).toBe(true);
  });
});
