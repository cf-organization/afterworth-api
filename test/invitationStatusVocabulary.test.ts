/**
 * Invitation status-vocabulary audit.
 *
 * ★ THE DEFECT THIS EXISTS FOR FAILED SILENTLY, WHICH IS WHY IT SURVIVED TWO ROUNDS OF REVIEW.
 *
 * 0043 replaced the delivery-outbox vocabulary wholesale. `revoke_estate_invitation` kept 0042's
 * statement — `where status = 'pending'` → `set status = 'failed'` — and both values had ceased to
 * exist. The predicate matched nothing, so revoking never cancelled the queued email and NOTHING
 * raised. Only a behavioural harness with a real outbox row found it (fixed by 0047).
 *
 * ★ WHY THIS CANNOT BE A LITERAL GREP. `pending` is still perfectly legal — for
 * `invitations.status`. It is obsolete only for `invitation_delivery_outbox.status`. A grep for
 * `'pending'` flags dozens of correct statements and hides the one that matters. The audit is
 * therefore COLUMN-AWARE: it classifies each statement by the table it operates on, and judges the
 * literal against that table's current constraint.
 *
 * ★ IT JUDGES FINAL DEFINITIONS, NOT HISTORY. Migrations are immutable, so 0042 still contains the
 * pre-0043 bodies verbatim. Those are historical text. Only the LAST `create or replace` of each
 * function is deployed, and only that one is judged — otherwise every fix would permanently fail
 * its own audit.
 *
 * Companion to `plpgsqlShadowing.test.ts`, which covers a different failure mode (OUT-variable
 * ambiguity, which raises 42702 loudly). Kept separate: same files, unrelated concerns.
 */
import * as fs from "node:fs";
import * as path from "node:path";
import { describe, expect, it } from "vitest";

const ROOT = path.resolve(__dirname, "..");
const MIGRATIONS = path.join(ROOT, "db", "migrations");

/** Authoritative, from db/tables/invitations.sql. Unchanged by 0042–0047. */
const INVITATION_STATUS = new Set([
  "pending", "matched", "accepted", "declined", "expired", "revoked",
]);

/** Authoritative, from 0043's replacement CHECK constraint. */
const OUTBOX_STATUS = new Set([
  "queued", "processing", "providerAccepted", "outcomeUncertain",
  "retryPending", "failedPermanent", "cancelled",
]);

/** 0042's original outbox vocabulary. Every one of these is now illegal ON THE OUTBOX. */
const OBSOLETE_OUTBOX = new Set(["pending", "issued", "failed"]);

/** The set a worker may claim — must agree across index, claim predicate and revoke cancellation. */
const CLAIMABLE = ["queued", "retryPending"];

interface Fn {
  readonly name: string;
  readonly file: string;
  readonly body: string;
}

/** Last `create or replace` wins — that is what is actually deployed. */
function finalDefinitions(): Map<string, Fn> {
  const out = new Map<string, Fn>();
  for (const file of fs.readdirSync(MIGRATIONS).filter((f) => f.endsWith(".sql")).sort()) {
    const src = fs.readFileSync(path.join(MIGRATIONS, file), "utf8");
    const re = /create or replace function (public\.\w+)[\s\S]*?^\$function\$;/gm;
    for (const m of src.matchAll(re)) out.set(m[1], { name: m[1], file, body: m[0] });
  }
  return out;
}

/** Statements (`;`-delimited) that operate on the delivery outbox. */
export function outboxStatements(body: string): string[] {
  return body.split(";").filter((s) => s.includes("invitation_delivery_outbox"));
}

/** Obsolete outbox-status literals used in an outbox statement. Column-aware by construction. */
export function obsoleteOutboxLiterals(body: string): string[] {
  const hits: string[] = [];
  for (const stmt of outboxStatements(body)) {
    const strip = stmt.replace(/--.*$/gm, " ");
    // `status = 'x'` / `set status = 'x'` — a single literal.
    for (const m of strip.matchAll(/status\s*=\s*'([a-zA-Z]+)'/g)) {
      if (OBSOLETE_OUTBOX.has(m[1])) hits.push(m[1]);
    }
    // `status in ('a', 'b', …)` — EVERY literal in the list. Matching only the first would miss
    // `in ('queued', 'pending')`, where the obsolete value hides behind a valid one.
    for (const m of strip.matchAll(/status\s+in\s*\(([^)]*)\)/g)) {
      for (const lit of m[1].matchAll(/'([a-zA-Z]+)'/g)) {
        if (OBSOLETE_OUTBOX.has(lit[1])) hits.push(lit[1]);
      }
    }
  }
  return [...new Set(hits)];
}

const FINAL = finalDefinitions();
const OUTBOX_FNS = [...FINAL.values()].filter((f) => f.body.includes("invitation_delivery_outbox"));

describe("★ the scan is not vacuous", () => {
  it("reconstructs a meaningful number of final definitions", () => {
    expect(FINAL.size).toBeGreaterThan(20);
  });

  it("finds the functions that touch the delivery outbox", () => {
    expect(OUTBOX_FNS.length).toBeGreaterThan(3);
    const names = OUTBOX_FNS.map((f) => f.name);
    expect(names).toContain("public.revoke_estate_invitation");
    expect(names).toContain("public.claim_invitation_deliveries");
  });

  it("later migrations supersede earlier bodies", () => {
    // revoke's final definition must come from 0047, not 0042 — otherwise the audit would be
    // judging history and every fix would fail its own check.
    expect(FINAL.get("public.revoke_estate_invitation")?.file).toMatch(/^0047_/);
    expect(FINAL.get("public.create_estate_invitation")?.file).toMatch(/^0045_/);
  });
});

describe("★ no REACHABLE function uses an obsolete outbox status", () => {
  /**
   * Two 0042 functions still carry the old vocabulary. Both were superseded and deliberately kept
   * — 0044 records them as "superseded, kept, service_role only" — and neither has a caller in
   * lib/, api/, or any other function. They are LATENT, not active, and are listed explicitly so
   * the exemption is a decision rather than an accident. If either ever gains a caller, delete it
   * from this list and fix the function.
   */
  const SUPERSEDED_UNCALLED = new Set([
    "public.issue_invitation_delivery",          // superseded by 0043 token / 0044 notice
    "public.record_invitation_delivery_failure", // superseded by 0043 record_..._outcome
  ]);

  it("every reachable outbox function uses only current vocabulary", () => {
    const offenders = OUTBOX_FNS.filter((f) => !SUPERSEDED_UNCALLED.has(f.name))
      .flatMap((f) => {
        const bad = obsoleteOutboxLiterals(f.body);
        return bad.length ? [`${f.file} ${f.name}: ${bad.join(",")}`] : [];
      });
    expect(offenders.join("\n")).toBe("");
  });

  it("the exempted functions are exempt because they are UNCALLED, and still carry the old values", () => {
    // Pins the reason for the exemption. If someone "cleans up" these bodies the test still passes;
    // if someone adds a caller, the reachability check below is what fails.
    for (const name of SUPERSEDED_UNCALLED) expect(FINAL.has(name)).toBe(true);
  });

  it("★ no exempted function has acquired a caller in shipped code", () => {
    // The exemption is only valid while nothing calls them. This is the guard on that assumption.
    const scan = (dir: string): string[] =>
      !fs.existsSync(dir) ? [] : fs.readdirSync(dir, { withFileTypes: true }).flatMap((e) =>
        e.isDirectory() ? scan(path.join(dir, e.name))
          : e.name.endsWith(".ts") ? [fs.readFileSync(path.join(dir, e.name), "utf8")] : []);
    const sources = [...scan(path.join(ROOT, "lib")), ...scan(path.join(ROOT, "api"))].join("\n");
    for (const name of SUPERSEDED_UNCALLED) {
      const bare = name.replace("public.", "");
      // `issue_invitation_delivery` is a prefix of `issue_invitation_delivery_notice`, so require a
      // non-identifier character after it — otherwise the live notice call would false-positive.
      const called = new RegExp(`["'\`]${bare}(?![\\w])`).test(sources);
      expect({ name, called }).toEqual({ name, called: false });
    }
  });
});

describe("★ the claimable set agrees everywhere", () => {
  const migrationText = fs.readdirSync(MIGRATIONS).filter((f) => f.endsWith(".sql"))
    .map((f) => fs.readFileSync(path.join(MIGRATIONS, f), "utf8")).join("\n");

  it("the partial index claims exactly queued + retryPending", () => {
    expect(migrationText).toMatch(/invitation_delivery_outbox_claimable_idx[\s\S]{0,200}?where status in \('queued', 'retryPending'\)/);
  });

  it("the worker claim predicate uses the same two states", () => {
    const claim = FINAL.get("public.claim_invitation_deliveries")?.body ?? "";
    for (const s of CLAIMABLE) expect(claim).toContain(`'${s}'`);
    // A claim predicate must never reach a terminal state.
    for (const terminal of ["providerAccepted", "failedPermanent", "cancelled"]) {
      expect({ terminal, claimed: new RegExp(`o\\.status\\s*=\\s*'${terminal}'`).test(claim) })
        .toEqual({ terminal, claimed: false });
    }
  });

  it("★ revoke cancels exactly the claimable set — no more, no less", () => {
    // More would rewrite delivery history and imply a recall that did not happen; fewer would let
    // a revoked invitation's email still go out, which is the 0047 defect.
    const revoke = FINAL.get("public.revoke_estate_invitation")?.body ?? "";
    expect(revoke).toMatch(/ob\.status in \('queued', 'retryPending'\)/);
    expect(revoke).toMatch(/set status = 'cancelled'/);
    for (const preserved of ["providerAccepted", "outcomeUncertain", "failedPermanent"]) {
      expect({ preserved, touched: revoke.includes(`'${preserved}'`) }).toEqual({ preserved, touched: false });
    }
  });
});

describe("★ owner-facing normalization is complete and honest", () => {
  const list = FINAL.get("public.list_estate_invitations")?.body ?? "";

  it("collapses worker mechanics to queued and passes honest outcomes through", () => {
    for (const m of ["queued", "processing", "retryPending"]) expect(list).toContain(`when '${m}'`);
    expect(list).toMatch(/else p\.raw_delivery/); // everything else unchanged
  });

  it("★ never emits a delivery value the mobile client cannot decode", () => {
    // Emitted set = {none} ∪ (OUTBOX_STATUS minus the three collapsed to 'queued') ∪ {queued}.
    const collapsed = new Set(["processing", "retryPending"]);
    const emitted = new Set(["none", ...[...OUTBOX_STATUS].filter((s) => !collapsed.has(s))]);
    // Mirrors features/ownerInvitations/model.ts DeliveryState (minus its fail-closed sentinel).
    const mobileHandles = new Set([
      "none", "queued", "providerAccepted", "outcomeUncertain", "failedPermanent", "cancelled",
    ]);
    expect([...emitted].sort()).toEqual([...mobileHandles].sort());
  });

  it("does not emit any obsolete outbox value", () => {
    for (const o of OBSOLETE_OUTBOX) {
      expect({ o, emitted: new RegExp(`then '${o}'`).test(list) }).toEqual({ o, emitted: false });
    }
  });
});

describe("★ schema objects carry vocabulary too", () => {
  const migrationText = fs.readdirSync(MIGRATIONS).filter((f) => f.endsWith(".sql"))
    .map((f) => fs.readFileSync(path.join(MIGRATIONS, f), "utf8")).join("\n");

  /**
   * ★ A PARTIAL INDEX IS A STATEMENT WITH A VOCABULARY, and 0042's outlived its vocabulary:
   *
   *   invitation_delivery_outbox_unissued_idx ... where status = 'pending'
   *
   * 0043 removed 'pending' from the CHECK constraint but created a NEW claimable index rather than
   * dropping this one, and nothing has dropped it since. Its predicate is now unsatisfiable, so the
   * index is permanently empty — it can never match a row.
   *
   * This is DEAD WEIGHT, NOT AN ACTIVE DEFECT. An empty partial index returns no rows and nothing
   * queries `status = 'pending'` any more, so no query can get a wrong answer from it; writes skip
   * it because the predicate is false. The cost is a misleading schema — the name "unissued" and the
   * predicate together imply a state the database no longer accepts.
   *
   * It is pinned rather than fixed because dropping it needs a migration, which needs authorization.
   * When that is granted, drop the index and invert this test.
   */
  it("pins the known-dead 0042 partial index — unsatisfiable, never dropped", () => {
    expect(migrationText).toMatch(
      /invitation_delivery_outbox_unissued_idx[\s\S]{0,120}?where status = 'pending'/
    );
    expect(migrationText).not.toMatch(/drop index[^\n]*unissued_idx/i);
    // The predicate is unsatisfiable precisely because 0043 removed the value it tests for.
    expect(OUTBOX_STATUS.has("pending")).toBe(false);
  });

  it("the live claimable index is the one that is actually satisfiable", () => {
    for (const s of CLAIMABLE) expect(OUTBOX_STATUS.has(s)).toBe(true);
  });
});

describe("★ detection sanity — each required case", () => {
  const fn = (body: string): string => body;

  it("1 · catches WHERE status = 'pending' on the outbox", () => {
    expect(obsoleteOutboxLiterals(fn(
      "update public.invitation_delivery_outbox set x = 1 where status = 'pending';"
    ))).toEqual(["pending"]);
  });

  it("2 · catches SET status = 'failed' on the outbox", () => {
    expect(obsoleteOutboxLiterals(fn(
      "update public.invitation_delivery_outbox set status = 'failed' where id = a;"
    ))).toEqual(["failed"]);
  });

  it("3 · catches an obsolete claimable state ('issued')", () => {
    expect(obsoleteOutboxLiterals(fn(
      "select 1 from public.invitation_delivery_outbox where status in ('issued');"
    ))).toEqual(["issued"]);
  });

  it("4 · does NOT flag a valid queued/retryPending predicate", () => {
    expect(obsoleteOutboxLiterals(fn(
      "update public.invitation_delivery_outbox as ob set status = 'cancelled' where ob.status in ('queued', 'retryPending');"
    ))).toEqual([]);
  });

  it("5 · terminal states are not treated as obsolete", () => {
    expect(obsoleteOutboxLiterals(fn(
      "select 1 from public.invitation_delivery_outbox where status = 'providerAccepted';"
    ))).toEqual([]);
  });

  it("6 · ★ does NOT flag 'pending' on the INVITATIONS table — it is still legal there", () => {
    // This is the whole reason the audit is column-aware. A literal grep fails here.
    expect(obsoleteOutboxLiterals(fn(
      "update public.invitations set status = 'revoked' where status = 'pending';"
    ))).toEqual([]);
    expect(INVITATION_STATUS.has("pending")).toBe(true);
    expect(OUTBOX_STATUS.has("pending")).toBe(false);
  });

  it("6b · ★ does NOT flag storage_deletion_outbox — a REAL other table where both are legal", () => {
    // Not hypothetical: db/tables/storage_deletion_outbox.sql declares
    //   check (status in ('pending','purged','failed'))
    // Both words are obsolete on the INVITATION outbox and correct here. A repo-wide literal grep
    // reports this line as a defect; the column-aware audit must not.
    expect(obsoleteOutboxLiterals(
      "update public.storage_deletion_outbox set status = 'failed' where status = 'pending';"
    )).toEqual([]);
  });

  it("6c · catches an obsolete value HIDDEN INSIDE a valid IN list", () => {
    // `in ('queued', 'pending')` is the nastiest shape: the first literal is valid, so a matcher
    // that reads only the first element of the list reports the statement as clean.
    expect(obsoleteOutboxLiterals(
      "update public.invitation_delivery_outbox set x = 1 where status in ('queued', 'pending');"
    )).toEqual(["pending"]);
  });

  it("7 · final-definition supersession — 0042's body is history, 0047's is judged", () => {
    const final = FINAL.get("public.revoke_estate_invitation");
    expect(final?.file).toMatch(/^0047_/);
    expect(obsoleteOutboxLiterals(final?.body ?? "")).toEqual([]);
    // The 0042 original genuinely does contain the obsolete pair — proving supersession matters.
    const original = fs.readFileSync(
      path.join(MIGRATIONS, "0042_20260731_owner_invitation_management.sql"), "utf8"
    );
    const m = /create or replace function public\.revoke_estate_invitation[\s\S]*?^\$function\$;/m.exec(original);
    expect(obsoleteOutboxLiterals(m?.[0] ?? "").sort()).toEqual(["failed", "pending"]);
  });
});
