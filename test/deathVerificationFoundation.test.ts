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
    "get_estate_net_worth.sql",
    "list_estate_assets.sql",
    // ★ PHASE 11-E. The safety module reads the lifecycle to gate its own transitions — the one
    // sanctioned NON-disclosure consumer. It is exempt from the only-as-an-argument rule below
    // (it decides transitions, not disclosure) and carries its own dedicated rules in section 6.
    "release_safety.sql",
  ] as const;

  /** Files that legitimately WRITE or gate on the lifecycle rather than disclose from it. */
  const LIFECYCLE_MODULES = ["death_verification.sql", "estate_lifecycle_state.sql", "release_safety.sql"];

  const namesTheReader = (code: string) => /\bpublic\.estate_lifecycle_state\s*\(/.test(code);
  const namesTheTable = (code: string) => /\bpublic\.estate_lifecycle\b(?!_state)/.test(code);

  it("exactly the sanctioned set names the reader", () => {
    const callers = sources.filter((s) => namesTheReader(s.code)).map((s) => s.file).sort();
    expect(callers).toEqual([...SANCTIONED_READER_CALLERS].sort());
  });

  it("only the lifecycle modules touch the TABLE", () => {
    const offenders = sources.filter((s) => !LIFECYCLE_MODULES.includes(s.file) && namesTheTable(s.code));
    expect(offenders.map((o) => o.file)).toEqual([]);
  });

  it("every disclosure consumer uses the reader ONLY as the predicate's lifecycle argument", () => {
    /**
     * For each reader mention in a disclosure evaluator, the enclosing text must be a
     * `release_condition_satisfied(...)` argument list — checked by requiring the predicate call
     * to OPEN, unclosed, within the 200 characters before the mention. A local `if`/`case`
     * comparison has no such unclosed call in front of it.
     */
    const evaluators = SANCTIONED_READER_CALLERS.filter((f) => !LIFECYCLE_MODULES.includes(f));
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
    ["death_verified", "challenge_window"],
    ["death_verification_pending", "challenge_halted"],
    ["death_verified", "challenge_halted"],
    ["challenge_window", "challenge_halted"],
    ["challenge_window", "released"],
  ] as const;

  /** Every (from → to) pair the map actually admits, parsed from the conjunction list. */
  const actualEdges = (): [string, string][] =>
    [...transitionBody.matchAll(/v_from\s*=\s*'(\w+)'\s*and\s+p_to\s*=\s*'(\w+)'/g)].map(
      (m) => [m[1], m[2]] as [string, string]
    );

  it("the map admits exactly the eight 11-E moves, and no others", () => {
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

  it("detection sanity: the edge parser sees a real map and a widened one", () => {
    expect(actualEdges().length).toBe(8);
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

  it("the window-duration configuration ships EMPTY — no seeded product decision", () => {
    const m54 = migrations.find((m) => m.file.startsWith("0054"))!;
    expect(m54.code).toContain("create table if not exists public.release_safety_policy");
    expect(
      /insert\s+into\s+public\.release_safety_policy/i.test(m54.code),
      "the migration seeds a challenge-window duration — that is a product decision, not a default"
    ).toBe(false);
    // No client role may reach the safety clock.
    expect(m54.code).not.toMatch(/grant\s+(select|insert|update|delete|all)[\s\S]{0,120}release_safety_policy/i);
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

  it("release requires a STRICTLY elapsed window and stays client-unreachable", () => {
    const rs = sources.find((s) => s.file === "release_safety.sql")!;
    const body = rs.code.slice(rs.code.indexOf("function public.release_estate"));
    const fn = body.slice(0, body.indexOf("$function$;"));
    // ★ STRICT `>`, NOT `>=`. At the exact boundary instant release must refuse so the owner
    // challenge wins the tie (R14). `>=` is the one-character edit that loses it.
    expect(fn).toMatch(/now\(\)\s*>\s*v_row\.owner_notified_at\s*\+\s*v_duration/);
    expect(fn, "the boundary comparison is non-strict — a tie would go to release, not the owner")
      .not.toMatch(/now\(\)\s*>=\s*v_row\.owner_notified_at/);
    // The three-valued-logic discipline: a NULL comparison must refuse, not pass.
    expect(fn).toContain("coalesce(now() > v_row.owner_notified_at + v_duration, false)");
    // Guards: state, committed notice, verified case, configured duration.
    for (const guard of ["invalid_release_state", "owner_not_notified", "no_verified_case",
                         "release_window_not_configured", "release_window_not_elapsed"]) {
      expect(fn, `release lost its ${guard} guard`).toContain(guard);
    }
    // And no client role may pull the lever — the actor is a deferred product decision.
    expect(rs.code).toMatch(
      /revoke execute on function public\.release_estate\(uuid\)\s+from public, anon, authenticated/
    );
    expect(rs.code, "release_estate was granted to a client role").not.toMatch(
      /grant\s+execute on function public\.release_estate/
    );
  });

  it("the owner safety notice is REQUIRED before a window may open", () => {
    /**
     * ★ THE EMITTER'S USUAL TRADE IS INVERTED HERE, AND THAT IS THE SAFETY PRECONDITION (§9).
     * `emit_lifecycle_notification` deliberately swallows failure so a grant still commits when a
     * heads-up cannot be written. The window-open notice is not a heads-up — it is the owner's one
     * chance to object — so a null return must roll the transition back.
     */
    const rs = sources.find((s) => s.file === "release_safety.sql")!;
    const body = rs.code.slice(rs.code.indexOf("function public.begin_challenge_window"));
    const fn = body.slice(0, body.indexOf("$function$;"));
    expect(fn).toContain("'death_process.window_opened'");
    expect(fn).toMatch(/if v_notice is null then\s*\n\s*raise exception 'owner_notification_failed'/);
    // The notice is emitted BEFORE the transition, so a failure cannot leave a window open.
    expect(fn.indexOf("emit_lifecycle_notification")).toBeLessThan(fn.indexOf("apply_estate_lifecycle_transition"));
    expect(fn).toContain("public.admin_require_gate()");
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
  it("the safety notice is committed in-transaction and never queued to the email outbox (§10)", () => {
    const rs = sources.find((s) => s.file === "release_safety.sql")!;
    for (const term of ["invitation_delivery_outbox", "claim_invitation_delivery_batch",
                        "issue_invitation_delivery_notice", "purge_outbox", "outbox"]) {
      expect(rs.code, `release_safety.sql routes the safety notice through ${term}`).not.toContain(term);
    }
    // It uses the in-app emitter, and the emitter's own transactional contract is what makes the
    // "required to commit" guarantee meaningful.
    expect(rs.code).toContain("public.emit_lifecycle_notification");
    const rpcs = sources.find((s) => s.file === "lifecycle_notification_rpcs.sql")!;
    const emitter = rpcs.code.slice(rpcs.code.indexOf("function public.emit_lifecycle_notification"));
    expect(emitter.slice(0, emitter.indexOf("$function$;"))).not.toContain("outbox");
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
