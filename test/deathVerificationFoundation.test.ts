/**
 * PHASE 11-C — the death-verification foundation, pinned as a TRIPWIRE.
 *
 * ★ WHAT THIS FILE IS FOR. 11-C created a second seam beside the claim projection: the
 * authoritative estate lifecycle (`estate_lifecycle`, read through `estate_lifecycle_state`). The
 * SQL suite proves its BEHAVIOUR — creating, evidencing, reviewing and verifying a death case
 * changes no viewer's composed payload by one byte. What a runtime test cannot see is STRUCTURE:
 * that no disclosure path so much as names the new seam, that the case module touches no
 * disclosure surface, and that the H2 enforcement consults the LIVE policy engine rather than a
 * snapshot or a local copy. Those are source facts, pinned here so crossing them is deliberate.
 *
 * The companion boundary — `is_estate_executor` callers, claim-release dormancy, the predicate
 * signature — stays pinned by `phase11Firewall.test.ts` / `releaseConditionCentralization.test.ts`.
 */
import * as fs from "node:fs";
import * as path from "node:path";
import { describe, expect, it } from "vitest";

const ROOT = path.resolve(__dirname, "..");
const FUNCTIONS = path.join(ROOT, "db/functions");
const MIGRATIONS = path.join(ROOT, "db/migrations");

const stripSql = (raw: string): string =>
  raw
    .split("\n")
    .filter((l) => !/^\s*--/.test(l))
    .map((l) => l.replace(/\s--.*$/, ""))
    .join("\n");

const sources = fs
  .readdirSync(FUNCTIONS)
  .filter((f) => f.endsWith(".sql"))
  .map((f) => ({ file: f, code: stripSql(fs.readFileSync(path.join(FUNCTIONS, f), "utf8")) }));

const migrations = fs
  .readdirSync(MIGRATIONS)
  .filter((f) => f.endsWith(".sql"))
  .map((f) => ({ file: f, code: stripSql(fs.readFileSync(path.join(MIGRATIONS, f), "utf8")) }));

const dv = sources.find((s) => s.file === "death_verification.sql");

describe("0 · the audit is reading something", () => {
  it("finds the module and a substantial scan set", () => {
    expect(sources.length).toBeGreaterThan(30);
    expect(migrations.length).toBeGreaterThan(40);
    expect(dv).toBeDefined();
    expect(dv!.code).toContain("initiate_death_verification_case");
  });

  it("comment stripping kept code and removed prose", () => {
    expect(dv!.code).toContain("estate_lifecycle_state");
    expect(dv!.code).not.toContain("RELEASES NOTHING"); // header prose
  });
});

describe("1 · the seam is consulted by the SANCTIONED set, and only as the predicate's argument", () => {
  /**
   * ★ REWRITTEN DELIBERATELY IN PHASE 11-D — the 11-C version pinned "consulted by NOBODY" and
   * fired when the widening arrived, which is what it was for. The 11-D discipline it becomes:
   *
   *   · a CLOSED SET of consumers may name the reader — the death module (runtime callers), the
   *     reader's own source file, and the disclosure evaluators that pass it INTO the canonical
   *     predicate. A new consumer must change this list, loudly.
   *   · outside the death module and the reader's own file, `estate_lifecycle_state` may appear
   *     ONLY as an argument inside a `release_condition_satisfied` call. A local comparison —
   *     `if estate_lifecycle_state(e) = 'death_verified' then …` — is release policy leaking back
   *     out of the canonical module one `if` at a time, and it is the single most likely 11-E
   *     accident. (`lifecycle_notification_rpcs.sql` is deliberately NOT here: emission pins the
   *     base state and never consults the seam at all.)
   *   · the TABLE (`estate_lifecycle`) is still named by nobody outside the death module and the
   *     reader — consumers go through the reader, never around it.
   */
  const SANCTIONED_READER_CALLERS = [
    "can_access_document.sql",
    "death_verification.sql",
    "estate_discovery_rpcs.sql",
    "estate_lifecycle_state.sql",
    // ★ PHASE 11-I. The fiduciary workflow read consults the lifecycle to report PROCESS state —
    // challenge window open, halted, release completed — to the executor running that process. It
    // is a non-disclosure consumer like release_safety.sql: it reports where the workflow stands,
    // never what the estate contains, which §3/§4 of executor_workspace_authorization.sql assert
    // by execution. It is therefore exempt from the only-as-a-predicate-argument rule below.
    "executor_workspace.sql",
    "get_estate_net_worth.sql",
    "list_estate_assets.sql",
    // ★ PHASE 11-E. The safety module reads the lifecycle to gate its own transitions — the one
    // sanctioned NON-disclosure consumer. It is exempt from the only-as-an-argument rule below
    // (it decides transitions, not disclosure) and carries its own dedicated rules in section 6.
    "release_safety.sql",
  ] as const;

  /** Files that legitimately WRITE or gate on the lifecycle rather than disclose from it. */
  const LIFECYCLE_MODULES = ["death_verification.sql", "estate_lifecycle_state.sql", "release_safety.sql"];

  /**
   * ★ PHASE 11-K. A THIRD LIST, FOR THE THIRD PRIVILEGE — and separate for exactly the reason the
   * 11-I note below records. Adding `operator_console.sql` to `LIFECYCLE_MODULES` would have been
   * the one-word fix and would ALSO have granted it permission to WRITE the lifecycle table, which
   * it must never have. These are different privileges and they get different lists.
   *
   * A lifecycle TABLE READER reads process TIMESTAMPS that the reader function does not return —
   * `owner_notified_at`, `challenge_window_started_at`, `halted_at`, `released_at`. The operator
   * case file needs them to answer "when does release become possible" and "has this already
   * halted"; `estate_lifecycle_state()` returns only the state word, so going through the reader
   * genuinely cannot answer them. That is why this list exists rather than a fourth entry above.
   *
   * ★ MEMBERSHIP CARRIES A PROOF OBLIGATION THE OTHER LISTS DO NOT: the very next test asserts
   * every member is READ-ONLY against the table. A file may read process facts here; it may not
   * quietly acquire the ability to move the machine.
   */
  const LIFECYCLE_TABLE_READERS = ["operator_console.sql"];

  const namesTheReader = (code: string) => /\bpublic\.estate_lifecycle_state\s*\(/.test(code);
  const namesTheTable = (code: string) => /\bpublic\.estate_lifecycle\b(?!_state)/.test(code);

  it("exactly the sanctioned set names the reader", () => {
    const callers = sources.filter((s) => namesTheReader(s.code)).map((s) => s.file).sort();
    expect(callers).toEqual([...SANCTIONED_READER_CALLERS].sort());
  });

  it("only the lifecycle modules and the sanctioned table readers touch the TABLE", () => {
    const permitted = [...LIFECYCLE_MODULES, ...LIFECYCLE_TABLE_READERS];
    const offenders = sources.filter((s) => !permitted.includes(s.file) && namesTheTable(s.code));
    expect(offenders.map((o) => o.file)).toEqual([]);
  });

  it("every sanctioned table reader is READ-ONLY against the lifecycle", () => {
    // ★ POSITIVE CONTROL FIRST. If the file cannot be found the write matchers below would each
    // run against an empty string and report a clean read-only result about nothing.
    for (const file of LIFECYCLE_TABLE_READERS) {
      const src = sources.find((s) => s.file === file);
      expect(src, `${file} is listed as a lifecycle table reader but was not found`).toBeDefined();
      expect(namesTheTable(src!.code), `${file} does not name the table at all`).toBe(true);

      // The three ways to move the machine, plus the only sanctioned writer. None may appear.
      expect(src!.code).not.toMatch(/insert\s+into\s+public\.estate_lifecycle\b(?!_state)/i);
      expect(src!.code).not.toMatch(/update\s+public\.estate_lifecycle\b(?!_state)/i);
      expect(src!.code).not.toMatch(/delete\s+from\s+public\.estate_lifecycle\b(?!_state)/i);
      expect(src!.code).not.toContain("apply_estate_lifecycle_transition");
    }
  });

  it("every disclosure consumer uses the reader ONLY as the predicate's lifecycle argument", () => {
    /**
     * For each reader mention in a disclosure evaluator, the enclosing text must be a
     * `release_condition_satisfied(...)` argument list — checked by requiring the predicate call
     * to OPEN, unclosed, within the 200 characters before the mention. A local `if`/`case`
     * comparison has no such unclosed call in front of it.
     */
    /**
     * ★ THE EXEMPTION IS ITS OWN LIST, NOT `LIFECYCLE_MODULES`. Adding `executor_workspace.sql` to
     * that array would have been the one-word fix and would ALSO have granted it permission to
     * touch the `estate_lifecycle` TABLE directly, which it neither does nor needs — silently
     * widening a second audit to satisfy this one. These are two different privileges and they get
     * two different lists.
     *
     * A non-disclosure reader consults the lifecycle to report or gate PROCESS state. Phase 11-I's
     * workflow projection reports "challenge window open / halted / release completed" to the
     * fiduciary running that process, and discloses nothing about the estate — asserted by
     * execution in db/tests/executor_workspace_authorization.sql §3 and §4.
     */
    const NON_DISCLOSURE_READERS = [...LIFECYCLE_MODULES, "executor_workspace.sql"];
    const evaluators = SANCTIONED_READER_CALLERS.filter((f) => !NON_DISCLOSURE_READERS.includes(f));
    for (const f of evaluators) {
      const code = sources.find((s) => s.file === f)!.code;
      for (const m of code.matchAll(/public\.estate_lifecycle_state\s*\(/g)) {
        const before = code.slice(Math.max(0, m.index! - 200), m.index!);
        const call = before.lastIndexOf("release_condition_satisfied");
        expect(call, `${f}: the reader is used outside the canonical predicate's argument list`).toBeGreaterThan(-1);
        const between = before.slice(call);
        const opens = (between.match(/\(/g) ?? []).length;
        const closes = (between.match(/\)/g) ?? []).length;
        expect(opens, `${f}: the reader mention is not INSIDE the predicate call`).toBeGreaterThan(closes);
      }
    }
  });

  it("no migration before 0052 names the seam (it did not exist)", () => {
    const offenders = migrations.filter(
      (m) => m.file < "0052" && (namesTheReader(m.code) || namesTheTable(m.code))
    );
    expect(offenders.map((o) => o.file)).toEqual([]);
  });

  it("detection sanity: a local lifecycle comparison and a table bypass WOULD be caught", () => {
    // The 11-E accident: comparing the seam locally instead of passing it in.
    const local = "  if public.estate_lifecycle_state(p_estate) = 'death_verified' then v_tier := 'full_detail'; end if;";
    const before = local.slice(0, local.indexOf("public.estate_lifecycle_state"));
    expect(before.lastIndexOf("release_condition_satisfied")).toBe(-1);
    // A consumer reading the table around the reader.
    expect(namesTheTable("select state from public.estate_lifecycle where estate_id = e")).toBe(true);
    expect(namesTheTable("public.estate_lifecycle_state(v_estate)")).toBe(false);
    // And the sanctioned shape passes: an unclosed predicate call precedes the mention.
    const sanctioned = "return public.release_condition_satisfied(g.release_condition, g.approved_at, 'standard', public.estate_lifecycle_state(v_estate));";
    const b2 = sanctioned.slice(0, sanctioned.indexOf("public.estate_lifecycle_state"));
    const call = b2.lastIndexOf("release_condition_satisfied");
    expect(call).toBeGreaterThan(-1);
    const between = b2.slice(call);
    expect((between.match(/\(/g) ?? []).length).toBeGreaterThan((between.match(/\)/g) ?? []).length);
  });
});

describe("2 · the case module touches no disclosure surface", () => {
  /**
   * The module records facts; it must be UNABLE to hand anyone anything. No grant table, no
   * visibility tier, no sealed-instruction store, no claim row, no notification emitter, no
   * release predicate — reading OR writing.
   */
  const FORBIDDEN = [
    "access_grants",
    "visibility_tier",
    "encrypted_instructions",
    "claim_packets",
    "release_condition_satisfied",
    "release_condition_writable",
    "estate_release_state",
    "emit_notification",
    "emit_lifecycle_notification",
    "can_access_document",
    "inventory_disclosure_tier",
    "document_grantable",
    "asset_category_grantable",
  ] as const;

  it.each(FORBIDDEN)("death_verification.sql never names %s", (term) => {
    expect(dv!.code).not.toContain(term);
  });

  it("migration 0052 grants nothing to a client role", () => {
    const m52 = migrations.find((m) => m.file.startsWith("0052"))!;
    expect(m52).toBeDefined();
    expect(m52.code).not.toMatch(/grant\s+(select|insert|update|delete|all)[\s\S]{0,120}to\s+(anon|authenticated)/i);
  });
});

describe("3 · the transition map is closed and release-shaped states are unwritable", () => {
  const transitionBody = (() => {
    const start = dv!.code.indexOf("function public.apply_estate_lifecycle_transition");
    const rest = dv!.code.slice(start);
    return rest.slice(0, rest.indexOf("$function$;"));
  })();

  /**
   * ★ RE-ANCHORED IN 11-E, AND THE TWO ABSENCES ARE NOW THE POINT. The 11-C version pinned three
   * moves and the unwritability of `released`; 11-E adds the safety seam, so the map admits eight
   * moves — and what this rule protects becomes the shape of the machine rather than its size:
   *
   *   · nothing leaves `challenge_halted` (the owner said no; no resume, no admin override);
   *   · nothing leaves `released` (disclosure cannot be undone, R15);
   *   · `released` is entered from `challenge_window` ALONE — never from `death_verified`, which
   *     would skip the owner's window entirely.
   */
  const EXPECTED_EDGES = [
    ["active", "death_verification_pending"],
    ["death_verification_pending", "active"],
    ["death_verification_pending", "death_verified"],
    // ★ PHASE 11-F (D2/D4): the owner is TOLD before any clock starts, and the edge that skipped
    // that step — death_verified -> challenge_window — is GONE. A routine that forgets to dispatch
    // cannot open a window by accident; it raises.
    ["death_verified", "owner_notification_dispatched"],
    ["owner_notification_dispatched", "challenge_window"],
    ["death_verification_pending", "challenge_halted"],
    ["death_verified", "challenge_halted"],
    ["owner_notification_dispatched", "challenge_halted"],
    ["challenge_window", "challenge_halted"],
    ["challenge_window", "released"],
  ] as const;

  /** Every (from → to) pair the map actually admits, parsed from the conjunction list. */
  const actualEdges = (): [string, string][] =>
    [...transitionBody.matchAll(/v_from\s*=\s*'(\w+)'\s*and\s+p_to\s*=\s*'(\w+)'/g)].map(
      (m) => [m[1], m[2]] as [string, string]
    );

  it("the map admits exactly the ten 11-F moves, and no others", () => {
    const got = actualEdges().map(([f, t]) => `${f}->${t}`).sort();
    const want = EXPECTED_EDGES.map(([f, t]) => `${f}->${t}`).sort();
    expect(got).toEqual(want);
  });

  it("challenge_halted and released are TERMINAL — no edge leaves either", () => {
    const leaving = actualEdges().filter(([from]) => from === "challenge_halted" || from === "released");
    expect(
      leaving.map(([f, t]) => `${f}->${t}`),
      "a halted or released process can be moved on — 11-E forbids both (no resume, no un-disclosure)"
    ).toEqual([]);
  });

  it("released is entered ONLY from challenge_window", () => {
    const into = actualEdges().filter(([, to]) => to === "released").map(([from]) => from);
    expect(into, "release must pass through the owner-challenge window").toEqual(["challenge_window"]);
  });

  it("the challenge window is entered ONLY from owner_notification_dispatched (D2/D4)", () => {
    const into = actualEdges().filter(([, to]) => to === "challenge_window").map(([from]) => from);
    expect(
      into,
      "a window can open on an owner who was never told — the release clock would start in silence"
    ).toEqual(["owner_notification_dispatched"]);
  });

  it("detection sanity: the edge parser sees a real map and a widened one", () => {
    expect(actualEdges().length).toBe(10);
    const widened = "or (v_from = 'death_verified'             and p_to = 'released')";
    expect([...widened.matchAll(/v_from\s*=\s*'(\w+)'\s*and\s+p_to\s*=\s*'(\w+)'/g)].map((m) => [m[1], m[2]]))
      .toEqual([["death_verified", "released"]]);
  });

  it("the lifecycle CHECK admits exactly the six approved states, and nothing invented", () => {
    // ★ THE VOCABULARY MOVED TO 0054 IN 11-E: 0052 creates the table with the foundation states,
    // 0054 widens it to the safety machine. The rule follows the vocabulary rather than the file.
    const m54 = migrations.find((m) => m.file.startsWith("0054"));
    expect(m54, "migration 0054 is missing — the safety vocabulary has no source").toBeDefined();
    const check = m54!.code.slice(
      m54!.code.indexOf("add constraint estate_lifecycle_state_check"),
      m54!.code.indexOf("end $$;")
    );
    for (const s of ["active", "death_verification_pending", "death_verified",
                     "challenge_window", "challenge_halted", "released"]) {
      expect(check, `the lifecycle CHECK is missing ${s}`).toContain(`'${s}'`);
    }
    expect((check.match(/'[a-z_]+'/g) ?? []).length, "the vocabulary is not exactly six states").toBe(6);
    expect(check).not.toContain("'frozen'");
    // And the migration carries its own apply-time guard, so a CHECK that silently failed to move
    // raises at paste time rather than reading as success.
    expect(m54!.code).toContain("0054 FAILED");
  });

  /**
   * ★ WHICH MIGRATION OWNS THE DURATION IS THE POINT, AND IT MOVED IN 11-F. 0054 CREATED the table
   * and deliberately seeded nothing, because in 11-E the length was undecided and the fail-closed
   * posture was "no window can ever elapse". D2 decides 7 x 24h, so 0055 records it — in a
   * migration, reviewably, once — rather than in a console session nobody can reconstruct. Both
   * halves are pinned so neither can drift: 0054 still must not seed, and 0055 must seed exactly
   * the approved value.
   */
  it("0054 creates the duration table and seeds NOTHING; 0055 seeds the APPROVED 7 days", () => {
    const m54 = migrations.find((m) => m.file.startsWith("0054"))!;
    expect(m54.code).toContain("create table if not exists public.release_safety_policy");
    expect(
      /insert\s+into\s+public\.release_safety_policy/i.test(m54.code),
      "0054 seeds a duration — in 11-E that was an undecided product decision"
    ).toBe(false);
    const m55 = migrations.find((m) => m.file.startsWith("0055"))!;
    expect(m55.code).toMatch(/insert into public\.release_safety_policy[\s\S]{0,120}interval '7 days'/);
    // Re-applying must RE-ASSERT the approved value, so a hand-edited production row is corrected
    // by the next paste rather than silently kept.
    expect(m55.code).toMatch(/on conflict \(id\) do update set challenge_window = excluded\.challenge_window/);
    // No client role may reach the safety clock, in either migration.
    for (const m of [m54, m55]) {
      expect(m.code).not.toMatch(/grant\s+(select|insert|update|delete|all)[\s\S]{0,120}release_safety_policy/i);
    }
  });

  it("0055 widens the lifecycle vocabulary to exactly seven approved states", () => {
    const m55 = migrations.find((m) => m.file.startsWith("0055"))!;
    const check = m55.code.slice(
      m55.code.indexOf("add constraint estate_lifecycle_state_check"),
      m55.code.indexOf("end $$;")
    );
    for (const st of ["active", "death_verification_pending", "death_verified",
                      "owner_notification_dispatched", "challenge_window", "challenge_halted", "released"]) {
      expect(check, `the 11-F lifecycle CHECK is missing ${st}`).toContain(`'${st}'`);
    }
    expect((check.match(/'[a-z_]+'/g) ?? []).length, "the vocabulary is not exactly seven states").toBe(7);
    expect(check).not.toContain("'frozen'");
    expect(m55.code).toContain("0055 FAILED");
  });

  it("event_type is 'death' alone — incapacity unrepresentable for new rows", () => {
    const m52 = migrations.find((m) => m.file.startsWith("0052"))!;
    expect(m52.code).toContain("check (event_type in ('death'))");
    expect(m52.code).not.toMatch(/event_type in \([^)]*incapacity/);
  });

  it("detection sanity: a widened map or CHECK WOULD be caught", () => {
    expect((transitionBody + "or (v_from = 'death_verified' and p_to = 'released')").includes("'released'")).toBe(true);
    expect("check (event_type in ('death', 'death_or_incapacity'))").toMatch(/event_type in \([^)]*incapacity/);
  });
});

describe("4 · H2 — the decision consults the LIVE central policy, fail-closed", () => {
  const decideBody = (() => {
    const start = dv!.code.indexOf("function public.admin_decide_death_verification_case");
    const rest = dv!.code.slice(start);
    return rest.slice(0, rest.indexOf("$function$;"));
  })();

  it("verify re-derives the requirement from the central engine", () => {
    expect(decideBody).toContain("public.required_verification_level(v_estate)");
    // And never from the snapshot column — the snapshot is a record, not a gate.
    expect(decideBody).not.toContain("required_level_at_initiation");
  });

  it("the comparison coalesces to refusal (NULL attained can never verify)", () => {
    expect(decideBody).toContain("coalesce(v_attained >= v_required, false)");
    expect(decideBody).toContain("verification_level_insufficient");
  });

  it("no local verification-policy copy exists beside the central engine", () => {
    /**
     * ★ THE 11-B LESSON APPLIED FORWARD. A module that assigned a level from a literal would be a
     * second policy copy — right today, drifting tomorrow. The only level literals allowed in this
     * module are none at all: levels arrive from the engine or from the typed admin parameter.
     */
    expect(dv!.code).not.toMatch(/v_required\s*:=\s*'(attestation|kyc|enhanced_kyc)'/);
    expect(dv!.code).not.toMatch(/greatest\s*\(/i);
    expect(dv!.code).not.toMatch(/balance_cents|jurisdiction_policy|floor_level/);
  });

  it("detection sanity: a snapshot-consulting or local-policy decision WOULD be caught", () => {
    expect("if not coalesce(v_attained >= c.required_level_at_initiation, false)").toContain(
      "required_level_at_initiation"
    );
    expect("v_required := 'attestation';").toMatch(/v_required\s*:=\s*'(attestation|kyc|enhanced_kyc)'/);
  });
});

describe("5 · attained level — one writer, typed to the engine's enum", () => {
  it("exactly one routine assigns attained_level", () => {
    const writes = dv!.code.match(/set\s+attained_level\s*=/g) ?? [];
    expect(writes.length).toBe(1);
    // And the INSERT column list never names it: initiation cannot seed an attained level.
    const insertBlock = dv!.code.slice(
      dv!.code.indexOf("insert into public.death_verification_cases"),
      dv!.code.indexOf("returning id into v_case")
    );
    expect(insertBlock).not.toContain("attained_level");
  });

  it("the setter takes public.verification_level, not text", () => {
    expect(dv!.code).toContain("p_level public.verification_level");
  });

  it("the safety module touches no disclosure surface either (Phase 11-E)", () => {
    /**
     * ★ THE SAME FORBIDDEN SET THE CASE MODULE CARRIES, APPLIED TO THE ROUTINES THAT MOVE THE
     * LIFECYCLE. Release is EVALUATIVE: the state moves and the canonical predicate answers
     * differently. A safety routine that wrote a grant, raised a tier, or called the predicate
     * itself would be manufacturing disclosure at the exact moment the product is least able to
     * take it back.
     */
    const rs = sources.find((s) => s.file === "release_safety.sql");
    expect(rs, "release_safety.sql is missing — the 11-E safety module has no source").toBeDefined();
    for (const term of [
      "access_grants", "visibility_tier", "encrypted_instructions", "claim_packets",
      "release_condition_satisfied", "release_condition_writable", "estate_release_state",
      "can_access_document", "inventory_disclosure_tier", "document_grantable",
      "asset_category_grantable", "estate_memberships", "estate_designations",
    ]) {
      expect(rs!.code, `release_safety.sql names ${term}`).not.toContain(term);
    }
  });

  it("the challenge is owner-gated, evidence-free and takes ONE argument (R13)", () => {
    const rs = sources.find((s) => s.file === "release_safety.sql")!;
    const body = rs.code.slice(rs.code.indexOf("function public.challenge_death_process"));
    const fn = body.slice(0, body.indexOf("$function$;"));
    // One argument: an estate. A second parameter would be somewhere to put an evidence
    // requirement, a reason code, or a review token — none of which the owner should owe anyone.
    expect(rs.code).toMatch(/function public\.challenge_death_process\(p_estate uuid\)/);
    expect(fn).toContain("public.is_estate_owner(p_estate)");
    // The gate precedes any state or existence lookup, so a nonexistent estate and a foreign one
    // refuse with the same bytes.
    expect(fn.indexOf("is_estate_owner")).toBeLessThan(fn.indexOf("from public.estate_lifecycle"));
    // Nothing about designations, evidence, review, admin gates or waiting.
    for (const term of ["is_estate_executor", "estate_designations", "death_verification_evidence",
                        "admin_require_gate", "required_verification_level", "attained_level",
                        "challenge_window_duration"]) {
      expect(fn, `the challenge consults ${term} — it must be cheaper than the claim (R13)`).not.toContain(term);
    }
  });

  it("release requires a STRICTLY elapsed window, two distinct reviewers, and a reason (D1/D3)", () => {
    const rs = sources.find((s) => s.file === "release_safety.sql")!;
    const body = rs.code.slice(rs.code.indexOf("function public.authorize_release"));
    const fn = body.slice(0, body.indexOf("$function$;"));
    // ★ STRICT `>`, NOT `>=`. At the exact boundary instant release must refuse so the owner
    // challenge wins the tie (R14). `>=` is the one-character edit that loses it.
    expect(fn).toMatch(/now\(\)\s*>\s*v_row\.owner_notified_at\s*\+\s*v_duration/);
    expect(fn, "the boundary comparison is non-strict — a tie would go to release, not the owner")
      .not.toMatch(/now\(\)\s*>=\s*v_row\.owner_notified_at/);
    // The three-valued-logic discipline: a NULL comparison must refuse, not pass.
    expect(fn).toContain("coalesce(now() > v_row.owner_notified_at + v_duration, false)");
    // Guards: state, committed notice, reachable channel, verified case, duration, two-person, reason.
    for (const guard of ["invalid_release_state", "owner_not_notified", "owner_channel_unreachable",
                         "no_verified_case", "release_window_not_configured",
                         "release_window_not_elapsed", "two_person_rule_violated",
                         "audit_reason_required"]) {
      expect(fn, `release lost its ${guard} guard`).toContain(guard);
    }
    /**
     * ★ D1 — reviewer_a IS DERIVED, NEVER SUPPLIED. A parameter would let the caller nominate a
     * "first reviewer" who never reviewed anything and satisfy the rule against a stranger. It is
     * read from the verified case's decider, and the caller is compared against THAT.
     */
    expect(fn).toMatch(/select c\.id, c\.decided_by, c\.decided_at into v_case, v_reviewer_a/);
    expect(fn).toMatch(/if v_uid = v_reviewer_a then/);
    expect(
      /function public\.authorize_release\(p_estate uuid, p_reason text\)/.test(rs.code),
      "authorize_release accepts a reviewer parameter — reviewer_a must be derived, not supplied"
    ).toBe(true);
    // The admin gate is the door; the table CHECK is the wall behind it.
    expect(fn).toContain("public.admin_require_gate()");
    // ★ THE ONE-PERSON LEVER IS GONE FROM SOURCE. Source deletion and the 0055 drop are BOTH
    // required: deleting only the source leaves it alive in every database that applied 11-E,
    // and dropping only in the migration lets the next paste recreate it.
    expect(
      /create or replace function public\.release_estate/.test(rs.code),
      "release_estate is still defined — a one-person release path beside the two-person door"
    ).toBe(false);
    const m55 = migrations.find((m) => m.file.startsWith("0055"));
    expect(m55, "migration 0055 is missing").toBeDefined();
    expect(m55!.code).toContain("drop function if exists public.release_estate(uuid);");
  });

  it("the two-person rule is a TABLE CONSTRAINT, not only routine logic (D1)", () => {
    const m55 = migrations.find((m) => m.file.startsWith("0055"))!;
    expect(m55.code).toContain("constraint release_authorizations_two_person check (reviewer_a <> reviewer_b)");
    // The record is its own model — never overloaded onto claims, memberships or designations.
    expect(m55.code).toContain("create table if not exists public.release_authorizations");
    for (const field of ["estate_id", "reviewer_a", "reviewer_b", "verified_at", "authorized_at",
                         "released_at", "audit_reason"]) {
      expect(m55.code, `the release authorization record is missing ${field}`).toContain(field);
    }
    // And no client role may read it.
    expect(m55.code).not.toMatch(/grant\s+(select|insert|update|delete|all)[\s\S]{0,120}release_authorizations/i);
  });

  it("the owner safety notice is REQUIRED before a window may open", () => {
    /**
     * ★ THE EMITTER'S USUAL TRADE IS INVERTED HERE, AND THAT IS THE SAFETY PRECONDITION (§9).
     * `emit_lifecycle_notification` deliberately swallows failure so a grant still commits when a
     * heads-up cannot be written. The window-open notice is not a heads-up — it is the owner's one
     * chance to object — so a null return must roll the transition back.
     */
    const rs = sources.find((s) => s.file === "release_safety.sql")!;
    const body = rs.code.slice(rs.code.indexOf("function public.dispatch_owner_safety_notice"));
    const fn = body.slice(0, body.indexOf("$function$;"));
    expect(fn).toContain("'death_process.window_opened'");
    expect(fn).toMatch(/if v_notice is null then\s*\n\s*raise exception 'owner_notification_failed'/);
    /**
     * ★ D4 — EMAIL IS THE MINIMUM, AND AN UNRESOLVABLE ADDRESS IS A HARD FAILURE. An in-app row
     * alone is insufficient: the person a false death process targets successfully is exactly the
     * person who has stopped opening the app. The address comes from `auth.users` — the one a
     * claimant cannot repoint — and a missing one refuses the whole transition rather than queueing
     * a row nobody can deliver.
     */
    expect(fn).toContain("public.owner_notice_outbox");
    expect(fn).toMatch(/select u\.email into v_recipient from auth\.users u/);
    expect(fn).toContain("owner_channel_unreachable");
    // Both channels are committed BEFORE the transition, so a failure cannot leave a clock running.
    expect(fn.indexOf("insert into public.owner_notice_outbox")).toBeLessThan(fn.indexOf("apply_estate_lifecycle_transition"));
    expect(fn.indexOf("emit_lifecycle_notification")).toBeLessThan(fn.indexOf("apply_estate_lifecycle_transition"));
    // D2: the clock is stamped here — at dispatch — not at verification.
    expect(fn).toMatch(/set owner_notified_at = now\(\)/);
    expect(fn).toContain("public.admin_require_gate()");
    // ★ THE AUDIT RECORDS THE CHANNEL CLASS, NEVER THE ADDRESS (§17 discipline, applied to email).
    const audit = fn.slice(fn.indexOf("insert into public.audit_logs"));
    expect(audit).toContain("'channel', 'email'");
    expect(audit, "the dispatch audit carries the owner's address").not.toContain("v_recipient");
  });

  /**
   * ★ THE SAFETY NOTICE DOES NOT TRAVEL THE OUTBOX, AND THAT IS A DELIVERY-CLASS DECISION (§10).
   *
   * The invitation email outbox is an at-least-once, eventually-delivered queue drained by a DAILY
   * cron — so a row it carries can be up to roughly a day behind, and its claim predicate has NO
   * age gate (any `queued` row is claimable whenever the drain next runs). That is the right class
   * for an invitation email and the wrong one for the notice that starts a release clock: a window
   * that opened today on a notice delivered tomorrow has spent a day of the owner's protection
   * before they could read it.
   *
   * So `begin_challenge_window` writes an in-app notification in its OWN transaction and REQUIRES
   * it to commit. This rule keeps the two paths from merging quietly — routing the safety notice
   * through the outbox would be a silent downgrade from "committed before the window opens" to
   * "queued, probably delivered", which is exactly the substitution §10 forbids.
   */
  /**
   * ★ REWRITTEN IN 11-F, AND THE DISTINCTION SHARPENED RATHER THAN DROPPED. 11-E's rule was "the
   * safety notice never touches an outbox", because the only outbox was the invitation one: an
   * at-least-once queue drained by a daily cron whose claim predicate has NO age bound. D4 requires
   * an independently reachable channel, so 11-F gives the notice its OWN outbox with its own age
   * gate — and the thing that must stay true is the one that always mattered: the safety notice
   * must never inherit the INVITATION queue's delivery class.
   */
  it("the safety notice uses its OWN outbox, never the invitation delivery queue (§10)", () => {
    const rs = sources.find((s) => s.file === "release_safety.sql")!;
    for (const term of ["invitation_delivery_outbox", "claim_invitation_delivery_batch",
                        "issue_invitation_delivery_notice"]) {
      expect(rs.code, `release_safety.sql routes the safety notice through ${term}`).not.toContain(term);
    }
    expect(rs.code).toContain("public.owner_notice_outbox");
    expect(rs.code).toContain("public.emit_lifecycle_notification");
    const rpcs = sources.find((s) => s.file === "lifecycle_notification_rpcs.sql")!;
    const emitter = rpcs.code.slice(rpcs.code.indexOf("function public.emit_lifecycle_notification"));
    expect(emitter.slice(0, emitter.indexOf("$function$;"))).not.toContain("outbox");
  });

  it("the owner-notice queue has an age gate, and it is DERIVED from the window (Stage 3)", () => {
    const ob = sources.find((s) => s.file === "outbox_safety.sql");
    expect(ob, "outbox_safety.sql is missing — the age gate has no source").toBeDefined();
    // Derived, not separately configured: two tunable numbers drift, and the failure mode of that
    // drift is a notice sent after its own window closed.
    expect(ob!.code).toMatch(/public\.challenge_window_duration\(\)\s*\+\s*interval '1 day'/);
    // Stale rows settle explicitly; they are never sent and never deleted.
    expect(ob!.code).toContain("'stale_beyond_age_gate'");
    expect(ob!.code).toContain("owner_notice_age_gate_unconfigured");
    // ★ THE PURGE AUDIT IS WRITTEN BEFORE THE DELETE. Afterwards is an audit a failure can skip,
    // leaving rows gone and no record of who removed them.
    const purge = ob!.code.slice(ob!.code.indexOf("function public.purge_outbox_rows"));
    const fn = purge.slice(0, purge.indexOf("$function$;"));
    expect(fn.indexOf("insert into public.outbox_purge_audit")).toBeLessThan(fn.indexOf("delete from public.owner_notice_outbox"));
    expect(fn).toContain("purge_reason_required");
    expect(fn).toContain("unknown_outbox");
    // In-flight safety messages are not purgeable.
    expect(fn).toContain("status in ('dispatched', 'failedPermanent', 'cancelled')");
  });

  it("the safety notice copy asserts no death and names no claimant (§18)", () => {
    /**
     * ★ THE EVENT KEY IS NOT COPY, AND CONFLATING THEM IS HOW THIS RULE FIRST FAILED. The catalog
     * row's first string is `death_process.window_opened` — a server-side identifier that never
     * reaches a screen, and which SHOULD name the process it belongs to. The three strings after
     * it are the category, title and body, and those are what a person reads. Scanning the whole
     * row condemned the key for containing "death"; scanning the rendered strings tests the thing
     * the rule is named for.
     */
    const rpcs = sources.find((s) => s.file === "lifecycle_notification_rpcs.sql")!;
    const catalog = rpcs.code.slice(rpcs.code.indexOf("function public.notification_event_copy"));
    const row = catalog.slice(catalog.indexOf("('death_process.window_opened'"));
    const strings = [...row.slice(0, 400).matchAll(/'([^']*)'/g)].map((m) => m[1]);
    expect(strings.length, "could not extract the catalog row's strings").toBeGreaterThanOrEqual(4);
    expect(strings[0], "the event key moved — this rule is reading the wrong row").toBe("death_process.window_opened");
    const rendered = strings.slice(1, 4); // category, title, body — everything a person sees
    expect(rendered[1]).toBe("A release process is waiting");
    for (const forbidden of ["died", "death", "deceased", "passed away", "executor", "claimant",
                             "fraud", "probate", "estate of"]) {
      for (const s of rendered) {
        expect(s.toLowerCase(), `rendered copy "${s}" contains "${forbidden}"`).not.toContain(forbidden);
      }
    }
    // Pure ASCII, like every other catalog entry (the Hermes-bundle extraction rule).
    for (const s of rendered) {
      expect(/^[\x20-\x7E]*$/.test(s), `rendered copy "${s}" contains a non-ASCII character`).toBe(true);
    }
    // Detection sanity: the matcher WOULD catch a death assertion in the body.
    expect("Your loved one has died.".toLowerCase()).toContain("died");
  });

  it("the internal routines are revoked from every client role", () => {
    // ★ THE READER MOVED IN 11-D: it ships with the release-conditions bundle now, from its own
    // source file — same revoke, held there. Its callers are DEFINER routines; a client that can
    // execute it holds a death-status oracle for arbitrary estates.
    const reader = sources.find((s) => s.file === "estate_lifecycle_state.sql");
    expect(reader, "estate_lifecycle_state.sql is missing — the seam has no source file").toBeDefined();
    expect(reader!.code).toMatch(
      /revoke execute on function public\.estate_lifecycle_state\(uuid\)\s+from public, anon, authenticated/
    );
    expect(reader!.code, "the reader must be SECURITY DEFINER (its callers gate; it must reach the table)")
      .toContain("security definer");
    expect(dv!.code).toMatch(
      /revoke execute on function public\.apply_estate_lifecycle_transition\(uuid, text, uuid, text\)\s*\n?\s*from public, anon, authenticated/
    );
  });
});
