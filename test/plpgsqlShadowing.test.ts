/**
 * PL/pgSQL OUT-variable shadowing audit.
 *
 * ★ THIS DEFECT CLASS HAS SHIPPED TWICE, BOTH TIMES UNDETECTABLE UNTIL RUNTIME.
 *
 * A `RETURNS TABLE(...)` column is an implicit OUT variable in scope for the ENTIRE PL/pgSQL body.
 * Where such a name also exists as a real column on a table the function touches, PostgreSQL cannot
 * resolve a BARE reference and raises `42702` — but only when the statement actually executes.
 * `check_function_bodies` does not catch it, so both defects reached production:
 *
 *   0042 create_estate_invitation — bare `expires_at` in an UPDATE predicate → fixed by 0045
 *   0042 revoke_estate_invitation — bare `invitation_id`/`status` in an UPDATE predicate → 0046
 *
 * ★ THE RULE IS POSITIONAL, WHICH IS WHY THIS IS AUDITABLE AT ALL. A bare OUT name is only
 * ambiguous where the parser must choose between a variable and a column:
 *
 *   AMBIGUOUS  — WHERE / AND predicates, and general expression contexts
 *   SAFE       — `INSERT INTO t (col, …)` column lists   → resolved positionally as target columns
 *   SAFE       — `UPDATE t SET col = …` assignment targets → left-hand side is always a column
 *
 * A blanket grep for the identifier would flag all three and be useless — every function here uses
 * its OUT names legitimately in the safe positions. This audit encodes the distinction instead.
 */
import * as fs from "node:fs";
import * as path from "node:path";
import { describe, expect, it } from "vitest";

const ROOT = path.resolve(__dirname, "..");
const MIGRATIONS = path.join(ROOT, "db", "migrations");

interface Fn {
  readonly file: string;
  readonly name: string;
  readonly outs: readonly string[];
  /** Comment- and literal-scrubbed: used for AMBIGUITY detection, where literals are noise. */
  readonly body: string;
  /** Raw body: used for LITERAL-shape assertions, where the scrubber would erase the evidence. */
  readonly raw: string;
}

/** Strip `--` comments and single-quoted literals so neither can produce a false hit. */
function scrub(sql: string): string {
  return sql.replace(/--.*$/gm, " ").replace(/'(?:[^']|'')*'/g, "''");
}

/** Every `create or replace function` with a RETURNS TABLE, across the invitation migrations. */
function collectFunctions(): Fn[] {
  const out: Fn[] = [];
  for (const file of fs.readdirSync(MIGRATIONS).filter((f) => /^00(4[2-9]|[5-9]\d)_.*\.sql$/.test(f))) {
    const src = fs.readFileSync(path.join(MIGRATIONS, file), "utf8");
    const re = /create or replace function (public\.\w+)\s*\(([\s\S]*?)\)\s*\n\s*returns ([\s\S]*?)\n([\s\S]*?)^\$function\$;/gm;
    for (const m of src.matchAll(re)) {
      const table = /table\s*\(([\s\S]*?)\)\s*$/i.exec(m[3].trim());
      if (!table) continue; // scalar return — no implicit OUT variables
      const outs = table[1]
        .split(",")
        .map((p) => p.trim().split(/\s+/)[0])
        .filter(Boolean);
      // Body from `begin` onward: the declare block legitimately names things.
      const raw = m[4];
      const begin = raw.indexOf("\nbegin");
      const sliced = begin >= 0 ? raw.slice(begin) : raw;
      out.push({ file, name: m[1], outs, body: scrub(sliced), raw: sliced });
    }
  }
  return out;
}

/**
 * Bare OUT-name references in an AMBIGUOUS position.
 *
 * Only `WHERE` / `AND` / `OR` predicate lines are inspected. `INSERT` column lists and `SET`
 * assignment targets are skipped because the parser resolves those positionally — including them
 * would flag every correct function and make the audit worthless.
 */
function ambiguousHits(fn: Fn): string[] {
  const hits: string[] = [];
  for (const line of fn.body.split("\n")) {
    const t = line.trim();
    if (!/^(where|and|or)\b/i.test(t)) continue;
    for (const name of fn.outs) {
      // Bare = not alias-qualified (`ob.invitation_id`) and not part of a longer identifier.
      const bare = new RegExp(`(?<![\\w.])${name}(?![\\w])`);
      if (bare.test(t)) hits.push(`${fn.file} ${fn.name}: ${t}`);
    }
  }
  return hits;
}

const FUNCTIONS = collectFunctions();

describe("★ the scan is not vacuous", () => {
  it("finds the RETURNS TABLE functions it is meant to guard", () => {
    const names = FUNCTIONS.map((f) => f.name);
    for (const required of [
      "public.create_estate_invitation",
      "public.revoke_estate_invitation",
      "public.extend_estate_invitation",
      "public.request_invitation_redelivery",
    ]) {
      expect(names).toContain(required);
    }
  });

  it("extracts OUT names from the RETURNS TABLE clause", () => {
    const revoke = FUNCTIONS.filter((f) => f.name === "public.revoke_estate_invitation").pop();
    expect(revoke?.outs).toEqual(["invitation_id", "status", "revoked_at"]);
  });
});

describe("★ no bare OUT-variable reference survives in an ambiguous position", () => {
  it("every RETURNS TABLE function is clean in its FINAL definition", () => {
    // A function replaced by a later migration is judged on the LAST definition wins — that is what
    // is actually deployed. 0042's original bodies are historical and must not be edited.
    const latest = new Map<string, Fn>();
    for (const f of FUNCTIONS) latest.set(f.name, f); // readdir is sorted, so later files overwrite

    const offenders = [...latest.values()].flatMap(ambiguousHits);
    // Joined so a failure prints every offending statement, not just a count.
    expect(offenders.join("\n")).toBe("");
  });
});

describe("★ detection sanity — the matcher would catch both real defects", () => {
  const fake = (outs: string[], body: string): Fn => ({ file: "x.sql", name: "public.f", outs, body, raw: body });

  it("catches the 0045 defect shape (bare expires_at in a predicate)", () => {
    const hits = ambiguousHits(
      fake(["invitation_id", "expires_at"], "  where estate_id = p_estate and expires_at <= now();")
    );
    expect(hits).toHaveLength(1);
  });

  it("catches the 0046 defect shape (bare invitation_id and status in a predicate)", () => {
    const hits = ambiguousHits(
      fake(["invitation_id", "status"], "  where invitation_id = v_inv.id and status = 'pending';")
    );
    expect(hits.length).toBeGreaterThanOrEqual(1);
  });

  it("does NOT flag an alias-qualified predicate — that is the fix", () => {
    expect(
      ambiguousHits(
        fake(["invitation_id", "status"], "  where ob.invitation_id = v_inv.id and ob.status = 'pending';")
      )
    ).toEqual([]);
  });

  it("does NOT flag an INSERT column list — resolved positionally", () => {
    expect(
      ambiguousHits(fake(["invitation_id"], "  insert into public.o (invitation_id, estate_id) values (a, b);"))
    ).toEqual([]);
  });

  it("does NOT flag a SET assignment target — left-hand side is always a column", () => {
    expect(
      ambiguousHits(fake(["status", "revoked_at"], "     set status = 'revoked', revoked_at = now()"))
    ).toEqual([]);
  });

  it("does not mistake a longer identifier for the OUT name", () => {
    expect(ambiguousHits(fake(["status"], "  where status_code = 1;"))).toEqual([]);
  });
});

describe("★ the two known fixes are pinned by shape, not by hope", () => {
  const finalBody = (name: string): string => {
    const all = FUNCTIONS.filter((f) => f.name === name);
    return all[all.length - 1]?.body ?? "";
  };
  const finalRaw = (name: string): string => {
    const all = FUNCTIONS.filter((f) => f.name === name);
    return all[all.length - 1]?.raw ?? "";
  };

  it("create_estate_invitation qualifies its expiry predicate (0045)", () => {
    const b = finalBody("public.create_estate_invitation");
    expect(b).toMatch(/inv\.expires_at\s*<=\s*now\(\)/);
  });

  it("revoke_estate_invitation qualifies its outbox predicate (0046)", () => {
    const b = finalBody("public.revoke_estate_invitation");
    // The property is ALIAS-QUALIFICATION, not the operator. 0047 changed the status comparison
    // from `= 'pending'` to `in ('queued','retryPending')` to match the vocabulary 0043 introduced;
    // pinning `=` would have failed on a correct fix.
    expect(b).toMatch(/ob\.invitation_id\s*=/);
    expect(b).toMatch(/ob\.status\s*(=|in)\b/);
  });

  it("revoke cancels the DELIVERABLE outbox set using 0043's vocabulary (0047)", () => {
    // RAW body: `scrub()` blanks quoted literals for the ambiguity scan, which would erase exactly
    // the status names this assertion exists to check.
    const b = finalRaw("public.revoke_estate_invitation");
    // 'pending' and 'failed' ceased to exist in 0043; using either makes the cancellation a
    // silent no-op, which is exactly how this shipped.
    expect(b).toMatch(/status\s*=\s*'cancelled'/);
    expect(b).toMatch(/'queued'/);
    expect(b).toMatch(/'retryPending'/);
    expect(b).not.toMatch(/ob\.status\s*=\s*'pending'/);
    expect(b).not.toMatch(/set status\s*=\s*'failed'/);
  });

  it("extend and redelivery use their OUT names only in safe positions", () => {
    // Both were audited mechanically and are clean: the only occurrences are a SET target and an
    // INSERT column list respectively. Both also succeeded against the live database.
    for (const n of ["public.extend_estate_invitation", "public.request_invitation_redelivery"]) {
      const f = FUNCTIONS.filter((x) => x.name === n).pop();
      expect(f).toBeDefined();
      expect(ambiguousHits(f as Fn)).toEqual([]);
    }
  });
});
