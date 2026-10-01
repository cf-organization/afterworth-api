/**
 * AAL2 SESSION CURRENCY — the static half of the 0064 security fix.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ WHAT 0064 FIXES, MEASURED RATHER THAN REASONED. On nonprod, 2026-10-01, on a dedicated MFA
 *   account: enrol TOTP, verify, RETAIN the access token, confirm `get_estate_net_worth` answers 200,
 *   then recover (factor deleted, sessions revoked) — and the SAME token was STILL granted the gated
 *   read three seconds later. `require_aal2()` read `auth.jwt() ->> 'aal'`, a stateless claim that
 *   nothing happening after the token was minted can change.
 *
 * ★ WHAT THIS FILE CAN AND CANNOT PROVE. It cannot prove a refusal — only a database can, and
 *   `db/tests/aal2_session_currency_authorization.sql` does, executed by `npm run test:sql-auth`
 *   against a container. What it proves is the part a green SQL run cannot: that the MIGRATION and the
 *   SOURCE OF TRUTH carry the same body, that the gate no longer reads the claim itself, and that the
 *   new parts are actually wired into the suite that executes them. An unregistered part is the exact
 *   shape of the Phase 11-B finding — four of seven release-condition call sites had never executed.
 *
 * ★ COMMENTS ARE STRIPPED BEFORE MATCHING, AND THE STRIPPER HAS ITS OWN POSITIVE CONTROL. Every
 *   docblock here NAMES `auth.jwt()` while explaining why the code must not call it; a matcher run
 *   against the raw file would be satisfied by the prose and could never fail.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 */
import { readFileSync, existsSync, readdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "vitest";
import { SQL_SUITE_PARTS } from "../scripts/lib/sqlSuiteParts.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");

const MIGRATION = "db/migrations/0064_20261001_aal2_session_currency.sql";
const PREDICATE = "db/functions/aal2_is_current.sql";
const GATE = "db/functions/require_aal2.sql";
const SUITE = "db/tests/aal2_session_currency_authorization.sql";
const PREAMBLE = "db/tests/preamble_real_auth.sql";

const read = (rel: string) => readFileSync(join(ROOT, rel), "utf8");

/**
 * Drop whole-line SQL comments and block comments. Line-START only: a `--` inside a string literal
 * (this repository has several) is not a comment, and an earlier stripper elsewhere in the codebase
 * ate a regex literal by being greedier than this.
 */
const stripComments = (src: string): string =>
  src
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .split("\n")
    .filter((l) => !l.trimStart().startsWith("--"))
    .join("\n");

/** The body of one `create or replace function public.<name>`, through its `$function$;` terminator. */
function bodyOf(src: string, name: string): string {
  const re = new RegExp(`create\\s+or\\s+replace\\s+function\\s+public\\.${name}\\s*\\(`, "i");
  const m = re.exec(src);
  if (!m) return "";
  const end = src.indexOf("$function$;", m.index);
  if (end < 0) return "";
  return src.slice(m.index, end + "$function$;".length);
}
const normalise = (s: string) => stripComments(s).replace(/\s+/g, " ").trim();

describe("the scan set is real — asserted before any rule is evaluated", () => {
  test("every file this suite reasons about exists and is non-empty", () => {
    for (const f of [MIGRATION, PREDICATE, GATE, SUITE, PREAMBLE]) {
      expect(existsSync(join(ROOT, f)), `${f} is missing`).toBe(true);
      expect(read(f).trim().length, `${f} is empty`).toBeGreaterThan(200);
    }
  });

  test("★ the comment stripper removes prose and keeps code — its own positive control", () => {
    const stripped = stripComments(read(GATE));
    // Present in the docblock only. If this survives, the stripper is not stripping.
    expect(stripped).not.toContain("Source of truth");
    // Present in the code. If this is gone, the stripper is eating what the rules must see.
    expect(stripped).toContain("aal2_is_current");
    expect(stripped).toContain("mfa_required");
  });
});

describe("★ the gate no longer trusts the claim on its own", () => {
  test("require_aal2 delegates to the predicate", () => {
    expect(normalise(bodyOf(read(GATE), "require_aal2"))).toContain("aal2_is_current");
  });

  test("★ require_aal2 does NOT read auth.jwt() itself — the defect, in one assertion", () => {
    // The docblock says `auth.jwt()` four times; this reads the stripped body, so the prose cannot
    // satisfy it and restoring the old one-liner fails it.
    const code = stripComments(bodyOf(read(GATE), "require_aal2"));
    expect(code).not.toMatch(/auth\.jwt/);
    expect(code).not.toMatch(/'aal1'/);
  });

  test("it still raises the exact sentinel the client already maps", () => {
    const code = stripComments(bodyOf(read(GATE), "require_aal2"));
    expect(code).toContain("mfa_required");
    expect(code).toContain("42501");
  });
});

describe("★ the predicate carries all three legs, and can be read from a policy", () => {
  const code = () => stripComments(bodyOf(read(PREDICATE), "aal2_is_current"));

  test("leg 1 — the aal claim, fail-closed to aal1", () => {
    expect(code()).toMatch(/coalesce\(\s*v_claims\s*->>\s*'aal'\s*,\s*'aal1'\s*\)/);
  });

  test("leg 2 — the session must still exist, belong to the caller, and not be expired", () => {
    const c = code();
    expect(c).toContain("auth.sessions");
    expect(c).toContain("s.user_id = v_uid");
    expect(c).toContain("not_after");
    expect(c).toContain("session_id");
  });

  test("leg 3 — a verified factor must still exist", () => {
    const c = code();
    expect(c).toContain("auth.mfa_factors");
    expect(c).toMatch(/status::text\s*=\s*'verified'/);
  });

  test("★ SECURITY DEFINER with a pinned search_path — without it a policy cannot evaluate it", () => {
    const decl = code();
    expect(decl).toMatch(/security\s+definer/i);
    expect(decl).toMatch(/set\s+search_path\s+to/i);
  });

  test("it takes no arguments, so a caller cannot aim a DEFINER function at anyone else", () => {
    expect(read(PREDICATE)).toMatch(/function\s+public\.aal2_is_current\(\s*\)/i);
  });
});

describe("★ the migration and the source of truth cannot drift", () => {
  test("aal2_is_current is byte-identical (whitespace-normalised) in both files", () => {
    const fromMigration = normalise(bodyOf(read(MIGRATION), "aal2_is_current"));
    const fromSource = normalise(bodyOf(read(PREDICATE), "aal2_is_current"));
    expect(fromSource.length, "the predicate body was not found in db/functions/").toBeGreaterThan(300);
    expect(fromMigration).toBe(fromSource);
  });

  test("require_aal2 is byte-identical (whitespace-normalised) in both files", () => {
    const fromMigration = normalise(bodyOf(read(MIGRATION), "require_aal2"));
    const fromSource = normalise(bodyOf(read(GATE), "require_aal2"));
    expect(fromSource.length).toBeGreaterThan(80);
    expect(fromMigration).toBe(fromSource);
  });
});

describe("★ the two RESTRICTIVE policies stop carrying their own copy of the rule", () => {
  const mig = () => stripComments(read(MIGRATION));

  test.each(["connections_require_aal2", "normalized_assets_require_aal2"])(
    "%s is re-pointed at the predicate",
    (name) => {
      const m = new RegExp(`alter policy ${name} on public\\.\\w+\\s+using[\\s\\S]{0,200}?with check[\\s\\S]{0,120}?;`, "i");
      const stmt = m.exec(mig())?.[0] ?? "";
      expect(stmt, `no ALTER POLICY for ${name}`).not.toBe("");
      // Both expressions, and the scalar-subquery form that makes it one InitPlan per statement
      // rather than one call per row.
      expect((stmt.match(/\(\s*select\s+public\.aal2_is_current\(\)\s*\)/gi) ?? []).length).toBe(2);
      // And no residue of the inlined claim read.
      expect(stmt).not.toContain("aal1");
      expect(stmt).not.toContain("auth.jwt");
    },
  );

  test("the migration ALTERs rather than DROP+CREATEs, so RESTRICTIVE cannot be lost", () => {
    const m = mig();
    expect(m).not.toMatch(/drop policy[\s\S]{0,60}require_aal2/i);
    expect((m.match(/alter policy \w+_require_aal2/gi) ?? []).length).toBe(2);
  });

  test("it refuses to run if either policy is absent, rather than creating one", () => {
    expect(mig()).toContain("PRECONDITION FAILED");
  });
});

describe("★ the new parts are WIRED INTO the suite that executes them", () => {
  test("both are registered in SQL_SUITE_PARTS", () => {
    expect(SQL_SUITE_PARTS).toContain(PREDICATE);
    expect(SQL_SUITE_PARTS).toContain(SUITE);
  });

  test("the predicate loads before the gate and before the suite that creates a policy on it", () => {
    const i = (p: string) => SQL_SUITE_PARTS.indexOf(p);
    expect(i(PREDICATE)).toBeLessThan(i(GATE));
    expect(i(PREDICATE)).toBeLessThan(i(SUITE));
  });

  test("the suite runs after the financial surfaces and before the exit matrix", () => {
    const i = (p: string) => SQL_SUITE_PARTS.indexOf(p);
    expect(i(SUITE)).toBeGreaterThan(i("db/functions/get_estate_net_worth.sql"));
    expect(i(SUITE)).toBeLessThan(i("db/tests/phase10_exit_matrix.sql"));
  });

  test("every registered part exists on disk", () => {
    for (const p of SQL_SUITE_PARTS) expect(existsSync(join(ROOT, p)), `${p}`).toBe(true);
  });
});

describe("★ the SQL suite is bracketed by controls, not a list of refusals", () => {
  const suite = () => read(SUITE);

  test("the loadedness check comes before any authorization assertion is EVALUATED", () => {
    // ★ The boundary is the first CALL, not the first mention. An earlier version of this test
    //   compared against `expect_mfa_required` and matched the helper's own DEFINITION near the top
    //   of the file — so it failed while the suite was correctly ordered.
    const s = suite();
    expect(s.indexOf("CANNOT VERIFY: public.aal2_is_current() is not loaded"))
      .toBeLessThan(s.indexOf("perform harness_a2.expect_mfa_required"));
  });

  test("the positive control precedes the refusals and names an exact total", () => {
    const s = suite();
    expect(s).toContain("21900000");
    expect(s.indexOf("21900000")).toBeLessThan(s.indexOf("2a/session-revoked"));
  });

  test("★ a return-to-green control follows the refusals — a refusal is not evidence without it", () => {
    const s = suite();
    expect(s).toContain("2e/return-to-green");
    expect(s.indexOf("2d/recovery-state")).toBeLessThan(s.indexOf("2e/return-to-green"));
  });

  test("it covers the session leg and the factor leg INDEPENDENTLY, plus the combined state", () => {
    const s = suite();
    for (const label of ["2a/session-revoked", "2b/factor-removed", "2d/recovery-state"]) {
      expect(s, label).toContain(label);
    }
  });

  test("and it exercises the DIRECT-QUERY policy route, not only the RPC route", () => {
    const s = suite();
    expect(s).toContain("4/policy-stale");
    expect(s).toContain("as restrictive for all");
  });

  test("it removes the restrictive policy it creates, so later suites read the same table", () => {
    const s = suite();
    const tail = s.slice(s.indexOf("6 · FIXTURE INTEGRITY"));
    expect(tail).toContain("drop policy if exists normalized_assets_require_aal2");
    expect(tail).toContain("survived teardown");
  });
});

describe("the migration is numbered legitimately", () => {
  test("0064 is above the bootstrap cutoff and unique", () => {
    const files = readdirSync(join(ROOT, "db/migrations")).filter((f) => f.endsWith(".sql"));
    const mine = files.filter((f) => f.startsWith("0064_"));
    expect(mine).toEqual(["0064_20261001_aal2_session_currency.sql"]);
    const seqs = files.map((f) => f.slice(0, 4));
    expect(new Set(seqs).size, "duplicate migration sequence numbers").toBe(seqs.length);
    expect(Number("0064")).toBeGreaterThan(60);
  });
});

describe("the harness models the deployed contract, not a convenient one", () => {
  test("auth.sessions and auth.mfa_factors are modelled in the preamble", () => {
    const p = stripComments(read(PREAMBLE));
    expect(p).toContain("create table if not exists auth.sessions");
    expect(p).toContain("create table if not exists auth.mfa_factors");
  });

  test("★ the normalized_assets grant mirrors the deployed privilege and is not widened to ALL", () => {
    // 100_grants.sql grants SELECT, INSERT, DELETE — NOT UPDATE. A harness that granted ALL would let
    // a future assertion pass on a privilege production withholds.
    const p = stripComments(read(PREAMBLE));
    expect(p).toMatch(/grant select, insert, delete on public\.normalized_assets to authenticated;/);
    expect(p).not.toMatch(/grant all on public\.normalized_assets/);
    const deployed = read("db/bootstrap/100_grants.sql");
    expect(deployed).toMatch(/GRANT SELECT,INSERT,DELETE ON TABLE "public"\."normalized_assets" TO "authenticated"/);
  });

  test("admin fixtures get aal2 currency in ONE place, not sixteen", () => {
    const p = read(PREAMBLE);
    expect(p).toContain("create trigger harness_admin_aal2 after insert on public.admins");
    expect((p.match(/harness_auth\.grant_aal2/g) ?? []).length).toBeGreaterThanOrEqual(2);
  });

  test("★ the shared claim builder is PURE — it must be replayable in a dblink connection", () => {
    const p = read(PREAMBLE);
    const builder = p.slice(p.indexOf("function harness_auth.aal2("));
    const body = builder.slice(0, builder.indexOf("$$;") + 3);
    expect(body).not.toMatch(/insert|update|delete/i);
    expect(body).toContain("harness_auth.session_id");
  });
});
