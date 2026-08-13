/**
 * THE OPERATOR ARTIFACT IS PURE SQL AND ATOMIC — pinned so it cannot regress.
 *
 * ★ WHY THIS FILE EXISTS. These four bundles are pasted BY A HUMAN into the Supabase Web SQL Editor
 * against production. Two properties decide whether a bad paste is recoverable:
 *
 *   1 · PURE SQL. The sources begin `\set ON_ERROR_STOP on` — a psql CLIENT directive. The editor
 *       sends text to the server, so the line either errors or, far worse, is ignored while the
 *       operator believes ON_ERROR_STOP is in force. Both were live risks: every migration actually
 *       deployed (0042-0050) has zero meta-commands, and only the never-deployed 0051-0055
 *       introduced the convention — so no bundle anyone has pasted ever carried one.
 *
 *   2 · EXACTLY ONE TRANSACTION. Forty legacy migrations carry their own `begin; … commit;`. A
 *       part-level `commit;` CLOSES the artifact's wrapper early: everything before it commits and
 *       everything after runs unprotected. The estate bundle was exactly that shape, and it was
 *       found by EXECUTING the artifact with an injected error — not by reading it.
 *
 * The run-time proof lives in `scripts/verifyBundleAtomicity.mjs`, which executes each artifact
 * against a real Postgres. This file pins the source-level guarantees that make that proof
 * repeatable, and the bundler behaviour that produces them.
 */
import * as fs from "node:fs";
import * as path from "node:path";
import { describe, expect, it } from "vitest";

const ROOT = path.resolve(__dirname, "..");
const BUNDLES = "db/bundles";
const read = (rel: string) => fs.readFileSync(path.join(ROOT, rel), "utf8");

const artifacts = fs
  .readdirSync(path.join(ROOT, BUNDLES))
  .filter((f) => f.endsWith(".sql"))
  .map((f) => `${BUNDLES}/${f}`);

describe("0 · the audit is reading something", () => {
  it("finds every generated operator artifact", () => {
    expect(artifacts.length).toBe(4);
    for (const a of artifacts) expect(read(a).length).toBeGreaterThan(1000);
  });
});

describe("1 · PURE SQL — no psql meta-command survives into an artifact", () => {
  const metaLines = (sql: string) =>
    sql.split("\n").filter((l) => /^\s*\\[a-zA-Z]/.test(l));

  it.each(artifacts)("%s contains no meta-command", (a) => {
    expect(metaLines(read(a))).toEqual([]);
  });

  /**
   * ★ THE CONTROL THAT KEEPS THIS HONEST. If the SOURCES ever stopped carrying the directive, the
   * assertion above would pass while testing nothing — the stripper would be unexercised. The
   * sources must still have it, because the psql-driven SQL suite applies them directly.
   */
  it("the SOURCE migrations still carry the directive, so the stripper is exercised", () => {
    const src = read("db/migrations/0055_20260812_release_authorization.sql");
    expect(metaLines(src).length).toBeGreaterThan(0);
  });

  it("the removal is recorded in the artifact rather than silently dropped", () => {
    const rc = read("db/bundles/release_conditions_bundle.sql");
    expect(rc).toContain("[psql meta-command removed for the SQL editor]");
  });
});

describe("2 · EXACTLY ONE TRANSACTION per artifact", () => {
  it.each(artifacts)("%s has exactly one begin; and one commit;", (a) => {
    const sql = read(a);
    expect((sql.match(/^begin;$/gm) ?? []).length).toBe(1);
    expect((sql.match(/^commit;$/gm) ?? []).length).toBe(1);
  });

  it.each(artifacts)("%s opens with begin; before any DDL and ends with commit;", (a) => {
    const sql = read(a);
    const begin = sql.indexOf("\nbegin;");
    const commit = sql.lastIndexOf("\ncommit;");
    expect(begin).toBeGreaterThan(-1);
    expect(commit).toBeGreaterThan(begin);
    const firstDdl = sql.search(/^(create|alter|drop|insert|revoke|grant)\s/im);
    expect(firstDdl, "DDL appears before the transaction opens").toBeGreaterThan(begin);
  });

  /**
   * ★ THE PART-LEVEL CONTROL IS NEUTRALISED, AND THE EVIDENCE IS LEFT IN PLACE. The estate bundle
   * carries 0048 and 0049, which each wrap themselves; their `commit;` must appear only as a
   * comment, never as a statement that would close the wrapper early.
   */
  it("part-level transaction control is commented out, not executed", () => {
    const estate = read("db/bundles/estate_inventory_and_discovery_bundle.sql");
    expect(estate).toContain("[part-level transaction control removed; the artifact owns one]");
    // …and the sources it came from genuinely had it, or this proves nothing.
    expect(read("db/migrations/0049_20260811_estate_discovery.sql")).toMatch(/^commit;$/m);
  });

  it("no artifact contains a statement Postgres forbids inside a transaction", () => {
    const FORBIDDEN: [RegExp, string][] = [
      [/\bCONCURRENTLY\b/i, "CREATE/DROP INDEX CONCURRENTLY"],
      [/^\s*VACUUM\b/im, "VACUUM"],
      [/\bCREATE\s+DATABASE\b/i, "CREATE DATABASE"],
      [/\bCREATE\s+TABLESPACE\b/i, "CREATE TABLESPACE"],
      [/\bALTER\s+SYSTEM\b/i, "ALTER SYSTEM"],
      [/\bALTER\s+TYPE\b[\s\S]{0,80}?\bADD\s+VALUE\b/i, "ALTER TYPE ... ADD VALUE"],
    ];
    for (const a of artifacts) {
      const sql = read(a);
      const hits = FORBIDDEN.filter(([re]) => re.test(sql)).map(([, label]) => label);
      expect(hits, `${a} cannot be wrapped in a transaction`).toEqual([]);
    }
  });
});

describe("3 · the bundler's guarantees are structural, not incidental", () => {
  const bundler = read("scripts/lib/sqlBundle.mjs");

  it("the stripper is dollar-quote aware", () => {
    /**
     * A naive line filter would either miss top-level control or maim a plpgsql body — those bodies
     * are full of `begin`/`end` inside `$function$ … $function$`. The scanner must track quoting.
     */
    expect(bundler).toMatch(/DOLLAR/);
    expect(bundler).toMatch(/depth === 0|atTopLevel/);
  });

  it("plpgsql block-starts are distinguishable from transaction control by shape", () => {
    // plpgsql writes `begin` with NO semicolon; transaction control writes `begin;`.
    const dv = read("db/functions/death_verification.sql");
    expect(dv).toMatch(/^begin$/m);
    expect(dv).not.toMatch(/^begin;$/m);
    // And the neutralising pattern requires the semicolon.
    expect(bundler).toMatch(/\(begin\|commit\|rollback\)\\s\*;/);
  });

  it("the build FAILS rather than emitting an artifact that lies about atomicity", () => {
    expect(bundler).toMatch(/CANNOT WRAP IN A TRANSACTION/);
    expect(bundler).toMatch(/expected exactly one/);
    expect(bundler).toMatch(/process\.exit\(3\)/);
  });

  it("the run-time proof exists and is executable, not merely described", () => {
    const proof = read("scripts/verifyBundleAtomicity.mjs");
    expect(proof).toMatch(/rollback/i);
    // It must inject at a top-level boundary — an arbitrary offset can land inside a function body,
    // where the injected statement becomes inert text and the check measures nothing.
    expect(proof).toMatch(/-- ==== /);
    expect(proof).toMatch(/boundaries/);
    // And it must judge on DATABASE STATE, not on the client's exit code.
    expect(proof).toMatch(/witnessTrue/);
  });
});
