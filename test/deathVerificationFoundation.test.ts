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
  ] as const;

  const namesTheReader = (code: string) => /\bpublic\.estate_lifecycle_state\s*\(/.test(code);
  const namesTheTable = (code: string) => /\bpublic\.estate_lifecycle\b(?!_state)/.test(code);

  it("exactly the sanctioned set names the reader", () => {
    const callers = sources.filter((s) => namesTheReader(s.code)).map((s) => s.file).sort();
    expect(callers).toEqual([...SANCTIONED_READER_CALLERS].sort());
  });

  it("only the reader and the transition writer touch the TABLE", () => {
    const offenders = sources.filter(
      (s) => !["death_verification.sql", "estate_lifecycle_state.sql"].includes(s.file) && namesTheTable(s.code)
    );
    expect(offenders.map((o) => o.file)).toEqual([]);
  });

  it("every disclosure consumer uses the reader ONLY as the predicate's lifecycle argument", () => {
    /**
     * For each reader mention in a disclosure evaluator, the enclosing text must be a
     * `release_condition_satisfied(...)` argument list — checked by requiring the predicate call
     * to OPEN, unclosed, within the 200 characters before the mention. A local `if`/`case`
     * comparison has no such unclosed call in front of it.
     */
    const evaluators = SANCTIONED_READER_CALLERS.filter(
      (f) => f !== "death_verification.sql" && f !== "estate_lifecycle_state.sql"
    );
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

  it("the map admits exactly the three 11-C moves", () => {
    expect(transitionBody).toContain("(v_from = 'active'                     and p_to = 'death_verification_pending')");
    expect(transitionBody).toContain("(v_from = 'death_verification_pending' and p_to = 'active')");
    expect(transitionBody).toContain("(v_from = 'death_verification_pending' and p_to = 'death_verified')");
    expect(transitionBody).not.toContain("'released'");
    expect(transitionBody).not.toContain("'frozen'");
  });

  it("the lifecycle CHECK in 0052 admits no release-shaped state", () => {
    const m52 = migrations.find((m) => m.file.startsWith("0052"))!;
    const check = m52.code.slice(
      m52.code.indexOf("create table if not exists public.estate_lifecycle"),
      m52.code.indexOf("alter table public.estate_lifecycle")
    );
    expect(check).toContain("'death_verification_pending'");
    expect(check).toContain("'death_verified'");
    expect(check).not.toContain("'released'");
    expect(check).not.toContain("'frozen'");
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
