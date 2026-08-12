/**
 * The Phase 11 firewall, pinned as a TRIPWIRE — not as a description.
 *
 * ★ WHAT THIS FILE IS FOR. Phase 11 will connect death verification to disclosure. The single most
 * likely way to get that wrong is not a missing check; it is wiring the release state into an
 * authorization path that already exists, one call site at a time, and discovering afterwards that
 * the six places which independently evaluate a release condition did not all move together.
 *
 * This file records the CURRENT boundary in a form that fails loudly the moment someone crosses it
 * without deciding to. It asserts no policy about what Phase 11 should do — only what is true today,
 * so that changing it has to be deliberate.
 *
 * ★ IT IS A SOURCE-TEXT AUDIT, DELIBERATELY. The runtime suite already proves the BEHAVIOUR (an
 * approved claim discloses nothing — `db/tests/phase10_exit_matrix.sql`). What a runtime test cannot
 * see is *structure*: that no authorization path so much as consults the release seam. A behavioural
 * test would still pass on the day someone wires `estate_release_state` into
 * `inventory_disclosure_tier` behind a condition that happens to be false in the fixture.
 */
import * as fs from "node:fs";
import * as path from "node:path";
import { describe, expect, it } from "vitest";

const ROOT = path.resolve(__dirname, "..");
const FUNCTIONS = path.join(ROOT, "db/functions");

/** Every function source, comments stripped, so prose ABOUT the seam never satisfies a rule. */
const sources = fs
  .readdirSync(FUNCTIONS)
  .filter((f) => f.endsWith(".sql"))
  .map((f) => ({
    file: f,
    // Line comments only: SQL string literals must survive, since a condition literal IS the evidence.
    code: fs
      .readFileSync(path.join(FUNCTIONS, f), "utf8")
      .split("\n")
      .filter((l) => !/^\s*--/.test(l))
      .map((l) => l.replace(/\s--.*$/, ""))
      .join("\n"),
  }));

describe("0 · the audit is reading something", () => {
  it("finds a substantial set of function sources", () => {
    expect(sources.length).toBeGreaterThan(30);
    expect(sources.some((s) => s.file === "estate_discovery_rpcs.sql")).toBe(true);
  });

  it("comment stripping kept the code and removed the prose", () => {
    const disco = sources.find((s) => s.file === "estate_discovery_rpcs.sql")!.code;
    expect(disco).toContain("estate_release_state");
    expect(disco).not.toContain("THE SEAM");
  });
});

describe("1 · the release seam is REPORTED, never CONSULTED", () => {
  /**
   * ★ THE INVARIANT THAT MAKES THE FIREWALL STRUCTURAL RATHER THAN CAREFUL.
   *
   * `estate_release_state` is a projection of `claim_packets.status`. Today exactly one production
   * function calls it — `get_estate_discovery` — and it does so to place a LABEL in the payload. No
   * authorization decision anywhere reads it.
   *
   * That is why an approved claim cannot disclose anything: not because each read path checks the
   * state and refuses, but because no read path knows the state exists. Phase 11 changes this on
   * purpose; until then, a new caller is an accident.
   */
  const callers = sources.filter(
    (s) =>
      s.file !== "estate_discovery_rpcs.sql" &&
      /\bpublic\.estate_release_state\s*\(/.test(s.code)
  );

  it("no function other than get_estate_discovery calls estate_release_state", () => {
    expect(callers.map((c) => c.file)).toEqual([]);
  });

  it("get_estate_discovery uses it only to build a payload field", () => {
    const disco = sources.find((s) => s.file === "estate_discovery_rpcs.sql")!.code;
    /**
     * ★ CALL SITES ONLY — the DEFINITION is not a use. The first version matched
     * `public.estate_release_state(` anywhere, which includes
     * `create or replace function public.estate_release_state(p_estate uuid)` — the function lives
     * in this same file. It failed on its own declaration, which is the "a token match is not a
     * usage match" trap seen from the other side.
     */
    const uses = [...disco.matchAll(/(?<!function\s)public\.estate_release_state\s*\(/g)];
    expect(uses.length).toBeGreaterThan(0);
    // Every call site is an argument to jsonb_build_object, never the subject of a comparison.
    for (const m of uses) {
      const window = disco.slice(Math.max(0, m.index! - 120), m.index! + 60);
      expect(window).toContain("'release_state'");
      expect(window).not.toMatch(/if\s|when\s|=\s*public\.estate_release_state/);
    }
  });

  it("detection sanity: the matcher finds a real call", () => {
    expect(/\bpublic\.estate_release_state\s*\(/.test("x := public.estate_release_state(e);")).toBe(true);
    expect(/\bpublic\.estate_release_state\s*\(/.test("-- mentions estate_release_state")).toBe(false);
  });
});

describe("2 · death- and claim-conditioned grants are dormant at EVERY evaluation site", () => {
  /**
   * ★ SIX SITES, TWO RULES, ONE INVARIANT — and the count is the point.
   *
   * Release conditions are evaluated independently in `can_access_document`,
   * `inventory_disclosure_tier`, `notification_grant_is_live`, `list_estate_assets` (twice) and
   * `get_estate_net_worth` (twice). Documents/inventory/notifications additionally honour the two
   * approval-conditioned states; assets and net worth accept `immediately` alone.
   *
   * No site accepts a death- or claim-conditioned grant. Because the rule is DUPLICATED rather than
   * centralized, Phase 11 cannot activate death conditions in one place — and this test is what
   * turns "we remembered all six" into something the suite checks.
   */
  const DORMANT = [
    "after_verified_death_or_incapacity",
    "after_claim_case_approval",
    "after_identity_verification",
    "never",
  ] as const;

  const evaluators = sources.filter((s) => /release_condition/.test(s.code));

  it("the evaluator set is non-empty and includes the known read paths", () => {
    const files = evaluators.map((e) => e.file);
    for (const f of [
      "estate_discovery_rpcs.sql",
      "list_estate_assets.sql",
      "get_estate_net_worth.sql",
      "lifecycle_notification_rpcs.sql",
    ]) {
      expect(files).toContain(f);
    }
  });

  /**
   * ★ THE SUBJECT OF THE COMPARISON IS OFTEN A LOCAL VARIABLE, NOT THE COLUMN.
   *
   * The first version of this rule matched `release_condition <op> '<dormant>'` and a mutation
   * admitting a death condition SURVIVED it — because `inventory_disclosure_tier` selects the column
   * into `v_cond` and compares the VARIABLE. The most important evaluator in the codebase was
   * invisible to a rule written for the column name.
   *
   * So the subject is any of the spellings a release condition actually travels under here.
   */
  const SUBJECT = String.raw`(release_condition|v_cond|p_release_condition)`;
  const admits = (code: string, condition: string) =>
    new RegExp(`${SUBJECT}\\s*(=|in\\s*\\()[^;]{0,160}${condition}`, "i").test(code);

  /**
   * ★ UPDATED DELIBERATELY IN PHASE 11-B — THIS TRIPWIRE FIRED, WHICH IS WHAT IT IS FOR.
   *
   * The release rule now lives in ONE module, `release_conditions.sql`, and that module contains two
   * functions with different relationships to this invariant:
   *
   *   · `release_condition_satisfied` — the EVALUATOR. The dormancy rule applies with full force,
   *     and its body is inspected below exactly like every other evaluator.
   *   · `release_condition_writable` — a WRITE-TIME VOCABULARY list. It compares the condition to
   *     every legal value INCLUDING the dormant ones, because "an owner may STORE this" and "a
   *     reader may SEE under this" are different questions. Listing `never` as storable is not
   *     admitting `never` as satisfied — a matcher that cannot tell those apart would force the
   *     vocabulary out of the canonical module, which is the opposite of what this file protects.
   *
   * So the writable gate's body is excised before the admission scan, ON THAT ONE FILE, and the
   * excision is verified rather than assumed: the satisfied-evaluator's body must still be present
   * and still be scanned. Everything else is scanned whole, exactly as before.
   */
  const scannable = (file: string, code: string): string => {
    if (file !== "release_conditions.sql") return code;
    const start = code.indexOf("function public.release_condition_writable");
    expect(start, "the writable gate moved — update the excision").toBeGreaterThan(-1);
    const end = code.indexOf("$function$;", start);
    expect(end, "could not find the end of the writable gate body").toBeGreaterThan(start);
    const remainder = code.slice(0, start) + code.slice(end);
    // The evaluator must survive the excision, or this carve-out just blinded the tripwire.
    expect(remainder).toContain("function public.release_condition_satisfied");
    expect(remainder).toContain("'immediately'");
    return remainder;
  };

  it.each(DORMANT)("no evaluator admits %s as a released condition", (condition) => {
    for (const { file, code } of evaluators) {
      // A dormant condition may be NAMED (a catalog, a CHECK list) but never COMPARED as accepted.
      expect(admits(scannable(file, code), condition), `${file} appears to admit ${condition}`).toBe(false);
    }
  });

  it.each(["after_verified_death", "after_verified_incapacity"] as const)(
    "the split condition %s is admitted by NO evaluator either",
    (condition) => {
      // The 11-B vocabulary widened; the set of SATISFIABLE conditions did not. The split values
      // join the dormant list the moment they exist, not in some later phase.
      for (const { file, code } of evaluators) {
        expect(admits(scannable(file, code), condition), `${file} appears to admit ${condition}`).toBe(false);
      }
    }
  );

  it("detection sanity: both the column and the variable spelling are caught", () => {
    expect(admits("and g.release_condition = 'after_verified_death_or_incapacity'", "after_verified_death_or_incapacity")).toBe(true);
    expect(admits("if not (v_cond = 'after_verified_death_or_incapacity' or v_cond = 'immediately')", "after_verified_death_or_incapacity")).toBe(true);
    expect(admits("v_cond in ('after_owner_approval','after_claim_case_approval')", "after_claim_case_approval")).toBe(true);
    // And a bare mention is NOT an admission.
    expect(admits("raise notice 'after_verified_death_or_incapacity stays dormant';", "after_verified_death_or_incapacity")).toBe(false);
  });
});

describe("3 · nothing can write a released state", () => {
  /**
   * ★ THE STRONGEST FORM THE FIREWALL TAKES TODAY: the transition is not implemented.
   *
   * `claim_packets.status` permits `'released'` and `encrypted_instructions.released` is a real
   * column, but no routine assigns either. `admin_decide_claim_packet` accepts only approve/reject.
   * "We check carefully before releasing" is a weaker guarantee than "there is no code that
   * releases", and this pins the stronger one until Phase 11 replaces it deliberately.
   */
  it("no function sets claim_packets.status to released", () => {
    const offenders = sources.filter((s) =>
      /update\s+public\.claim_packets[\s\S]{0,200}status\s*=\s*'released'/i.test(s.code)
    );
    expect(offenders.map((o) => o.file)).toEqual([]);
  });

  it("admin_decide_claim_packet accepts only approve and reject", () => {
    const src = sources.find((s) => s.file === "admin_decide_claim_packet.sql");
    expect(src).toBeDefined();
    expect(src!.code).toMatch(/p_decision not in \('approve', 'reject'\)/);
    expect(src!.code).not.toContain("'released'");
  });

  it("no function sets encrypted_instructions.released", () => {
    const offenders = sources.filter((s) =>
      /update\s+public\.encrypted_instructions[\s\S]{0,200}released\s*=\s*true/i.test(s.code)
    );
    expect(offenders.map((o) => o.file)).toEqual([]);
  });

  it("detection sanity: a release-writing update WOULD be caught", () => {
    const bad = "update public.claim_packets set status = 'released' where id = p_id;";
    expect(/update\s+public\.claim_packets[\s\S]{0,200}status\s*=\s*'released'/i.test(bad)).toBe(true);
  });
});

describe("4 · a fiduciary designation confers capacity, never disclosure", () => {
  /**
   * ★ THE PHASE 10 INVARIANT MOST AT RISK IN PHASE 11. The pull to say "the executor is handling the
   * estate, so show them the estate" is the whole reason this is written down. Today
   * `is_estate_executor` gates exactly three things, none of which is a disclosure tier.
   */
  const executorGated = sources.filter(
    (s) =>
      s.file !== "is_estate_executor.sql" &&
      /\bpublic\.is_estate_executor\s*\(/.test(s.code)
  );

  it("is_estate_executor gates only claim submission, the verification preview, and case initiation", () => {
    /**
     * ★ WIDENED IN PHASE 11-C, DELIBERATELY AND ONCE. `death_verification.sql` joined the list: the
     * D2 decision routes case initiation, evidence attachment and cancellation through the same
     * canonical fiduciary predicate that has always gated claim submission. It remains a CAPACITY
     * gate — the file is separately pinned (deathVerificationFoundation.test.ts) to touch no
     * disclosure surface, and the disclosure projections below still may not consult it.
     */
    expect(executorGated.map((e) => e.file).sort()).toEqual(
      [
        "death_verification.sql",
        "preview_required_verification_level.sql",
        "submit_claim_packet.sql",
        "submit_claim_with_evidence.sql",
      ].sort()
    );
  });

  it("no disclosure projection consults a designation", () => {
    for (const f of ["estate_discovery_rpcs.sql", "list_estate_assets.sql", "get_estate_net_worth.sql"]) {
      const src = sources.find((s) => s.file === f)!;
      expect(src.code, `${f} consults is_estate_executor`).not.toMatch(/\bpublic\.is_estate_executor\s*\(/);
    }
  });

  it("inventory_disclosure_tier derives a tier from the GRANT alone", () => {
    const disco = sources.find((s) => s.file === "estate_discovery_rpcs.sql")!.code;
    const fn = disco.slice(disco.indexOf("function public.inventory_disclosure_tier"));
    const body = fn.slice(0, fn.indexOf("$function$;"));
    expect(body).toContain("access_grants");
    expect(body).not.toMatch(/is_estate_executor|estate_designations|display_role/);
  });
});
