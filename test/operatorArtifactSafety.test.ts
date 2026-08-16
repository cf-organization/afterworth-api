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
    // ★ 8 SINCE PHASE 11-L: halt_notification_bundle.sql joins operator_console_bundle.sql (11-K),
    // executor_workspace_bundle.sql (11-I) and estate_release_state_lockdown_bundle.sql (the
    // security lockdown, kept as its own artifact so a one-line privilege withdrawal does not
    // require re-pasting the 14-part estate bundle).
    // The count is asserted rather than derived so that a new operator artifact cannot appear
    // without a human deciding it should — every one of these is pasted into production by hand,
    // and this assertion firing is the intended way for that decision to be forced.
    //
    // ★ 11-L IS A DELIBERATE 8th ARTIFACT rather than an edit to an existing one. Its two inputs
    // live in the lifecycle and death bundles, and re-pasting either of those to ship one catalog
    // row and one `perform` would put 140KB+ of unrelated DDL back through a hand-paste. A small
    // artifact is the cheaper thing to review and the cheaper thing to roll back.
    //
    // ★ 11-MB IS THE 9th, AND ITS SIZE IS THE ARGUMENT FOR IT. One read-only routine, one part, no
    // migration — because the PROVISIONING correction it enables must NOT ship in the same paste. The
    // corrected provisioning would leave a newly designated fiduciary with no membership and an estate
    // the mobile selector cannot find, so discovery has to be deployed and consumed FIRST. Keeping the
    // two in separate artifacts is what makes that ordering enforceable rather than remembered.
    // ★ 11-MC IS THE 10th. It replaces four function bodies and adds no object, so it could in
    // principle have been folded into an existing bundle — but the four inputs span the invitation
    // module, and re-pasting the 17-part lifecycle bundle to ship one branch would put ~140KB of
    // unrelated DDL back through a hand-paste. A small artifact stays the cheaper thing to review and
    // the cheaper thing to roll back.
    //
    // ★ 11-NR IS THE 11th, AND IT IS ONE PART. It remediates FINDING 4 from the Branch A production
    // fire drill: `challenge_death_process` settled the case only from `status = 'open'`, which is
    // the status at ONE of the four lifecycle states the owner challenge is reachable from — so on
    // every operator-driven process the case row stayed `verified`, the halt notification was never
    // emitted to anybody, and the settled case stayed in the operator's `verified` work queue.
    //
    // `halt_notification_bundle.sql` already carries the changed file, so this artifact could have
    // been skipped entirely. It exists because that bundle ALSO re-pastes
    // `lifecycle_notification_rpcs.sql`, and nothing in the notification catalog changed here.
    // Shipping only the file that changed keeps the deployment diff and the blast radius the same
    // set — re-pasting an unrelated DEFINER body is exactly what the `create_asset_grant` near-miss
    // (Phase 10-E) cost. It adds no object, no migration and no grant: `'halted'` has been in the
    // case-status CHECK since migration 0054, added for this very transition.
    //
    // ★ 11-OBR IS THE 12th, AND IT CARRIES A MIGRATION — the first artifact since 11-K to change a
    // table. It closes OB-1/OB-4: `owner_notice_outbox` gains `claimed_at` so an abandoned claim can
    // be timed out and reclaimed, and `audit_logs_source_check` finally admits the `'worker'` source
    // that `record_owner_notice_outcome` has written since 11-K — a value the constraint never
    // allowed, so EVERY settle raised check_violation and every claimed owner notice stranded in
    // `processing`. That is the measured Branch A state.
    //
    // The two ship together deliberately: a reclaim without the audit fix turns one silently lost
    // notice into a daily resend loop that still cannot settle, which is strictly worse than either
    // defect alone.
    expect(artifacts.length).toBe(12);
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
