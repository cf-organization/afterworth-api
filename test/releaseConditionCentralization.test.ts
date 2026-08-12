/**
 * THERE IS EXACTLY ONE RELEASE-CONDITION AUTHORITY, AND EVERY CONSUMER CALLS IT.
 *
 * ★ WHAT THIS FILE CAN SEE THAT NO RUNTIME TEST CAN. `db/tests/release_condition_authorization.sql`
 * proves the predicate gives the right ANSWERS. It cannot prove there is only one of it. A second
 * copy that happens to agree today passes every behavioural assertion in the suite, and then drifts
 * — which is exactly what happened: the release rule was written out seven times in five routines,
 * gave two different answers, and 160 green assertions never mentioned it.
 *
 * So this is a source-text audit, deliberately, and it is written against the specific ways the
 * duplication came back before:
 *
 *   · the subject of the comparison is often a LOCAL VARIABLE (`v_cond`), not the column — a rule
 *     written for `release_condition` was blind to the most important evaluator in the codebase;
 *   · a condition may legitimately be NAMED (a catalog, a CHECK, a comment) without being COMPARED;
 *   · the shipping artifact is a BUNDLE, and a bundle contains a copy of every source it carries,
 *     so a naive scan double-counts the canonical module and calls it a duplicate.
 *
 * ★ COMMENTS ARE STRIPPED; STRING LITERALS ARE NOT. A release-condition literal IS the evidence
 * class this file exists to find, so stripping strings would erase every rule it evaluates — the
 * preprocessing mistake recorded in AGENTS.md, from the opposite direction. Prose about a condition
 * must not count as policy, and a condition inside quotes must.
 */
import * as fs from "node:fs";
import * as path from "node:path";
import { describe, expect, it } from "vitest";

const ROOT = path.resolve(__dirname, "..");

/** The canonical module — the ONE file permitted to compare a release condition to a literal. */
const CANONICAL = "db/functions/release_conditions.sql";

/** Every release condition the storage vocabulary admits, plus the deprecated fused value. */
const CONDITIONS = [
  "never",
  "immediately",
  "after_owner_approval",
  "after_identity_verification",
  "after_access_request_approval",
  "after_verified_death",
  "after_verified_incapacity",
  "after_verified_death_or_incapacity",
  "after_claim_case_approval",
] as const;

const DEPRECATED_FUSED = "after_verified_death_or_incapacity";

/* ── the scan set ───────────────────────────────────────────────────────────────────────────────
 *
 * ★ CONTENT-DERIVED, AND ASSERTED BEFORE ANY RULE RUNS. A Dashboard audit in this project resolved
 * its root one directory short, every path missed, every rule read an empty string, and 63
 * assertions passed against nothing. The set below is enumerated from disk and its size and
 * membership are checked first.
 *
 * ★ MIGRATIONS ARE OUT OF SCOPE, ON PURPOSE. `db/migrations/` is an append-only history: 0002, 0003
 * and 0004 each carry a superseded `can_access_document` body, complete with the release rule they
 * were correct to contain at the time. Scanning them would report nine-year-old history as present
 * duplication, and the only way to make the audit green would be to rewrite the past. What ships is
 * `db/functions/` (declared source of truth) and `db/bundles/` (the deployable artifact), and both
 * are scanned. Migration 0051's CHECK is asserted separately, as a vocabulary rather than a policy.
 */
const walk = (rel: string, filter: (f: string) => boolean): string[] => {
  const abs = path.join(ROOT, rel);
  if (!fs.existsSync(abs)) return [];
  return fs.readdirSync(abs, { withFileTypes: true }).flatMap((e) =>
    e.isDirectory()
      ? walk(path.join(rel, e.name), filter)
      : filter(e.name)
        ? [path.join(rel, e.name)]
        : []
  );
};

const SQL_SOURCES = walk("db/functions", (f) => f.endsWith(".sql"));
const SQL_BUNDLES = walk("db/bundles", (f) => f.endsWith(".sql"));
const JS_SOURCES = [...walk("api", (f) => f.endsWith(".ts")), ...walk("lib", (f) => f.endsWith(".ts"))];

/**
 * Line comments removed, string literals preserved.
 *
 * SQL: `--` to end of line. TS: `//` to end of line and block comments. In both cases a `--` or `//`
 * INSIDE a string would be mangled — acceptable here because no release-condition literal contains
 * either sequence, and asserted below rather than assumed.
 */
const strip = (text: string, kind: "sql" | "ts"): string =>
  kind === "sql"
    ? text
        .split("\n")
        .map((l) => l.replace(/^\s*--.*$/, "").replace(/\s--.*$/, ""))
        .join("\n")
    : text.replace(/\/\*[\s\S]*?\*\//g, "").split("\n").map((l) => l.replace(/(^|\s)\/\/.*$/, "$1")).join("\n");

const read = (rel: string) => fs.readFileSync(path.join(ROOT, rel), "utf8");
const load = (rel: string) => ({
  file: rel,
  code: strip(read(rel), rel.endsWith(".ts") ? "ts" : "sql"),
});

describe("0 · the audit is reading something", () => {
  it("resolved a real repository root", () => {
    expect(fs.existsSync(path.join(ROOT, "package.json"))).toBe(true);
    expect(fs.existsSync(path.join(ROOT, CANONICAL))).toBe(true);
  });

  it("the scan set is non-empty and contains the files this audit is about", () => {
    expect(SQL_SOURCES.length).toBeGreaterThan(30);
    expect(SQL_BUNDLES.length).toBeGreaterThanOrEqual(3);
    expect(JS_SOURCES.length).toBeGreaterThan(5);
    for (const f of [
      CANONICAL,
      "db/functions/can_access_document.sql",
      "db/functions/estate_discovery_rpcs.sql",
      "db/functions/list_estate_assets.sql",
      "db/functions/get_estate_net_worth.sql",
      "db/functions/lifecycle_notification_rpcs.sql",
    ]) {
      expect(SQL_SOURCES, `${f} is missing from the scan set`).toContain(f);
    }
  });

  it("comment stripping removed the prose and kept the literals", () => {
    const raw = read(CANONICAL);
    const c = load(CANONICAL).code;
    // A string literal survives — it is the evidence class.
    expect(c).toContain("'legacy_immediate_only'");
    /**
     * ★ AND THE STRIPPER'S OWN POSITIVE CONTROL, run on a purpose-built sample rather than on the
     * module's incidental content. The canonical module names the fused condition in `--` comments
     * (stripped) AND in a `comment on function` docstring — which is a SQL STRING LITERAL and is
     * correctly preserved, because strings are the evidence class here. Asserting "absent after
     * stripping" against the whole file therefore tested the docstring, not the stripper.
     */
    expect(raw).toContain(DEPRECATED_FUSED);
    expect(strip(`-- '${DEPRECATED_FUSED}' stays out\nselect 1;`, "sql")).not.toContain(DEPRECATED_FUSED);
    expect(strip(`select 1; -- ${DEPRECATED_FUSED}`, "sql")).not.toContain(DEPRECATED_FUSED);
    // The docstring form survives, and must: a stripper that ate strings would erase every rule.
    expect(strip(`comment on function x is 'refuses ${DEPRECATED_FUSED}';`, "sql")).toContain(DEPRECATED_FUSED);
    // Prose is gone.
    expect(c).not.toContain("THE CANONICAL RELEASE-CONDITION AUTHORITY");
  });

  it("no release-condition literal contains a comment marker (the stripper cannot eat one)", () => {
    for (const c of CONDITIONS) {
      expect(c.includes("--"), `${c} would be mangled by SQL comment stripping`).toBe(false);
      expect(c.includes("//"), `${c} would be mangled by TS comment stripping`).toBe(false);
    }
  });
});

/* ── the matcher ────────────────────────────────────────────────────────────────────────────────
 *
 * ★ THE SUBJECT IS ANY SPELLING A RELEASE CONDITION TRAVELS UNDER, NOT JUST THE COLUMN NAME.
 *
 * This is the Phase 11-A lesson kept: a rule anchored on `release_condition` could not see
 * `inventory_disclosure_tier`, which selects the column into `v_cond` and compares the variable. A
 * mutation admitting a death condition SURVIVED that rule. So the subject is the column, any
 * parameter or local named for it, and any qualified form (`g.release_condition`).
 */
const SUBJECT = String.raw`(?:\w+\.)?(?:release_condition|releaseCondition|v_cond|p_release_condition|p_cond)`;
const CONDITION_ALTERNATION = CONDITIONS.join("|");

/**
 * A COMPARISON of a release-condition subject against a release-condition literal.
 *
 * · The window is `[^;]` — it SPANS NEWLINES, because a multiline IN-list is exactly how the old
 *   inventory rule was formatted, and a matcher that only reads one line governs one spelling.
 * · The lookbehind excludes a CHECK constraint: `check (release_condition in (...))` is a
 *   VOCABULARY (what may be stored), not a POLICY (what is satisfied), and the storage vocabulary
 *   legitimately lives in the 0051 migration and the harness preamble.
 */
const comparisonRe = () =>
  new RegExp(
    `(?<!check\\s*\\(\\s*)${SUBJECT}\\s*(?:=|==|===|<>|!=|\\bin\\s*\\(|\\.has\\s*\\(|\\.includes\\s*\\()[^;]{0,240}?['"\`](?:${CONDITION_ALTERNATION})['"\`]`,
    "i"
  );

/**
 * ★ A FRESH RegExp PER CALL, AND `.test` IS NEVER REUSED ACROSS FILES ON A `g` MATCHER.
 *
 * A private-palette matcher in this project was written `/gm` and used with `.test()`; `lastIndex`
 * persists between calls, consecutive files alternated true/false, and the count silently halved.
 * These matchers carry no `g` flag, and the factory makes accidental sharing impossible.
 */
const comparesAConditionLiteral = (code: string) => comparisonRe().test(code);

describe("1 · the matcher recognises every form the codebase uses", () => {
  /**
   * ★ ONE POSITIVE CONTROL PER SPELLING THIS AUDIT CLAIMS TO GOVERN. A rule named for a concept and
   * written for one spelling silently governs a subset — and this project has shipped exactly that
   * (a private-palette rule that could not see `export const`). Every form below is a form that has
   * actually appeared in this repository or its client.
   */
  it.each([
    ["column, qualified", "and g.release_condition = 'immediately'"],
    ["column, bare", "where release_condition = 'after_owner_approval'"],
    ["local variable", "if not (v_cond = 'after_verified_death' or v_cond = 'immediately') then"],
    ["parameter", "select p_release_condition = 'immediately'"],
    ["IN list", "v_cond in ('after_owner_approval','after_claim_case_approval')"],
    ["inequality", "if release_condition <> 'never' then"],
    ["typescript equality", "if (releaseCondition === 'immediately') return true;"],
    ["typescript set", "RELEASE.has('after_verified_death')".replace("RELEASE", "releaseCondition")],
    ["multiline IN", "p_release_condition in (\n  'after_owner_approval',\n  'immediately')"],
  ])("catches a comparison written as %s", (_form, sample) => {
    expect(comparesAConditionLiteral(sample)).toBe(true);
  });

  it.each([
    ["a bare mention in prose-shaped code", "raise notice 'after_verified_death stays dormant';"],
    ["a CHECK vocabulary list", "check (release_condition in ('never','immediately'))"],
    ["a column being selected", "select g.visibility_tier, g.release_condition, g.approved_at"],
    ["a canonical delegation", "return public.release_condition_satisfied(g.release_condition, g.approved_at, 'standard');"],
    ["a wire field", "releaseCondition: r.release_condition,"],
  ])("does NOT flag %s", (_form, sample) => {
    expect(comparesAConditionLiteral(sample)).toBe(false);
  });

  it("is stateless across repeated calls (the lastIndex trap)", () => {
    const sample = "and g.release_condition = 'immediately'";
    const seen = Array.from({ length: 6 }, () => comparesAConditionLiteral(sample));
    expect(new Set(seen).size, "the matcher gave different answers to identical input").toBe(1);
    expect(seen[0]).toBe(true);
  });
});

describe("2 · exactly ONE production release-condition authority", () => {
  it("only one source file defines the canonical predicate", () => {
    const definers = SQL_SOURCES.filter((f) =>
      /create\s+or\s+replace\s+function\s+public\.release_condition_satisfied\s*\(/i.test(load(f).code)
    );
    expect(definers).toEqual([CANONICAL]);
  });

  it("only one source file defines the write-vocabulary gate", () => {
    const definers = SQL_SOURCES.filter((f) =>
      /create\s+or\s+replace\s+function\s+public\.release_condition_writable\s*\(/i.test(load(f).code)
    );
    expect(definers).toEqual([CANONICAL]);
  });

  it("NO production SQL outside the canonical module compares a condition to a literal", () => {
    const offenders = SQL_SOURCES.filter((f) => f !== CANONICAL).filter((f) =>
      comparesAConditionLiteral(load(f).code)
    );
    expect(
      offenders,
      "these files decide release policy locally instead of calling public.release_condition_satisfied"
    ).toEqual([]);
  });

  it("NO TypeScript re-implements the rule — the client and the API layer pass it through", () => {
    const offenders = JS_SOURCES.filter((f) => comparesAConditionLiteral(load(f).code));
    expect(offenders, "the release rule must live in the database, not in a request handler").toEqual([]);
  });

  it("detection sanity: a re-introduced local rule WOULD be caught in each scan set", () => {
    // The exact edit a contributor would make, in each language, injected into a real file's text.
    const sqlNeighbour = `${load("db/functions/estate_readiness_rpcs.sql").code}\n  and g.release_condition = 'immediately'\n`;
    expect(comparesAConditionLiteral(sqlNeighbour)).toBe(true);
    const tsNeighbour = `${load("lib/grants.ts").code}\nif (r.release_condition === 'after_verified_death') {}\n`;
    expect(comparesAConditionLiteral(tsNeighbour)).toBe(true);
  });
});

describe("3 · every evaluator that reads the column calls the authority", () => {
  /**
   * ★ SELECTING THE COLUMN IS THE TELL, AND DELEGATION IS THE REQUIREMENT.
   *
   * A file that reads `access_grants.release_condition` has, by definition, an opinion about release
   * — otherwise it would not need the column. Rule 2 proves it does not decide locally; this proves
   * it decides at all, rather than reading the column and ignoring it (which is how a gate gets
   * deleted without anything going red).
   */
  // ★ NOT `\brelease_condition\b` — `p_release_condition` has no word boundary before `release`,
  // so that spelling was invisible to the first version of this rule and the notification RPCs
  // (whose predicate receives the condition as a PARAMETER) fell out of the evaluator set silently.
  const READS_COLUMN = SQL_SOURCES.filter((f) => /release_condition/.test(load(f).code));

  it("the evaluator set is non-empty and includes every known read path", () => {
    for (const f of [
      "db/functions/can_access_document.sql",
      "db/functions/estate_discovery_rpcs.sql",
      "db/functions/list_estate_assets.sql",
      "db/functions/get_estate_net_worth.sql",
      "db/functions/lifecycle_notification_rpcs.sql",
    ]) {
      expect(READS_COLUMN, `${f} no longer reads release_condition — did a gate disappear?`).toContain(f);
    }
  });

  it.each([
    "db/functions/can_access_document.sql",
    "db/functions/estate_discovery_rpcs.sql",
    "db/functions/list_estate_assets.sql",
    "db/functions/get_estate_net_worth.sql",
    "db/functions/lifecycle_notification_rpcs.sql",
  ])("%s delegates to public.release_condition_satisfied", (file) => {
    expect(load(file).code).toMatch(/public\.release_condition_satisfied\s*\(/);
  });

  it("every write door validates the vocabulary through the canonical gate", () => {
    for (const f of ["db/functions/create_asset_grant.sql", "db/functions/create_document_grant.sql"]) {
      expect(load(f).code, `${f} stores a release condition without checking it is writable`)
        .toMatch(/public\.release_condition_writable\s*\(/);
    }
  });

  it("the policy argument is always one of the two named policies", () => {
    // ★ `[^)]*` — no call passes a parenthesised argument, so capture to the close paren directly.
    // The first version anchored on what FOLLOWED the call (`then|;`) and silently dropped every
    // call followed by `limit 1;`, undercounting 7 as 5 — the filter-that-filtered-nothing shape.
    // ★ CALL SITES ONLY — the DEFINITION, the `comment on function` and the grant/revoke lines all
    // spell the same name after the keyword `function`, and the first version of this rule flagged
    // the canonical module's own signature as "a call without a policy". The token-match-vs-usage
    // trap, one keyword over.
    const calls = SQL_SOURCES.flatMap((f) =>
      [...load(f).code.matchAll(/(?<!function\s)public\.release_condition_satisfied\s*\(([^)]*)\)/gi)]
        .map((m) => ({ file: f, args: m[1] }))
    );
    expect(calls.length, "fewer call sites than the rewiring created — this rule would be vacuous").toBeGreaterThanOrEqual(7);
    for (const { file, args } of calls) {
      expect(
        /'(standard|legacy_immediate_only)'/.test(args),
        `${file} calls the predicate without naming a known policy: ${args.trim()}`
      ).toBe(true);
    }
  });
});

describe("4 · the death/incapacity split is real for new data and safe for old", () => {
  it("the write gate refuses the deprecated fused condition", () => {
    const canonical = load(CANONICAL).code;
    const gate = canonical.slice(canonical.indexOf("function public.release_condition_writable"));
    expect(gate.length, "could not isolate the write gate").toBeGreaterThan(100);
    expect(gate).toContain("'after_verified_death'");
    expect(gate).toContain("'after_verified_incapacity'");
    expect(
      gate.includes(`'${DEPRECATED_FUSED}'`),
      "the deprecated fused condition is writable again — the split only holds while new data cannot express it"
    ).toBe(false);
  });

  it("storage still ACCEPTS the fused value, so existing rows are neither rewritten nor orphaned", () => {
    const migration = load("db/migrations/0051_20260812_release_condition_engine.sql").code;
    expect(migration).toContain(`'${DEPRECATED_FUSED}'`);
    expect(migration).toContain("'after_verified_death'");
    expect(migration).toContain("'after_verified_incapacity'");
  });

  it("no source maps the fused value onto either split condition", () => {
    /**
     * ★ THE GUESS THIS PHASE REFUSED TO MAKE. Reinterpreting a stored fused row as "death" would
     * activate a grant on an event the owner may never have chosen; as "incapacity", the same guess
     * reversed. Either would be a product decision about someone else's estate, taken silently in a
     * migration. The pattern below catches a compatibility shim written as a rewrite or a coalesce.
     */
    const remap = new RegExp(
      `${DEPRECATED_FUSED}[^;]{0,120}?(?:then|=>|:=|,)\\s*'after_verified_(?:death|incapacity)'`,
      "i"
    );
    const offenders = [...SQL_SOURCES, ...SQL_BUNDLES].filter((f) => remap.test(load(f).code));
    expect(offenders, "a legacy fused row is being reinterpreted as one trigger").toEqual([]);
    // Detection sanity — the shim someone would actually write.
    expect(remap.test(`when release_condition = '${DEPRECATED_FUSED}' then 'after_verified_death'`)).toBe(true);
  });

  it("the death condition is satisfiable ONLY conjoined with death_verified; everything else stays out", () => {
    /**
     * ★ REWRITTEN DELIBERATELY IN PHASE 11-D — the 11-B version asserted the death condition was
     * absent from the satisfying predicate, and it fired when 11-D added it, which is what it was
     * for. The 11-D shape: `after_verified_death` appears in the body EXACTLY ONCE, conjoined with
     * the authoritative lifecycle in one expression, under the standard arm only. Incapacity, the
     * fused value, claim, identity and never remain absent — satisfiable by nothing.
     */
    const canonical = load(CANONICAL).code;
    const fn = canonical.slice(canonical.indexOf("function public.release_condition_satisfied"));
    const body = fn.slice(0, fn.indexOf("$function$;"));
    expect(body.length).toBeGreaterThan(100);
    for (const c of ["after_verified_incapacity", DEPRECATED_FUSED,
                     "after_claim_case_approval", "after_identity_verification", "never"]) {
      expect(body, `${c} appears in the SATISFYING predicate`).not.toContain(`'${c}'`);
    }
    const deathMentions = body.match(/'after_verified_death'/g) ?? [];
    expect(deathMentions.length, "the death condition must appear exactly once in the satisfying body").toBe(1);
    expect(body).toMatch(
      /p_release_condition\s*=\s*'after_verified_death'\s*\n?\s*and\s+p_lifecycle_state\s*=\s*'death_verified'/
    );
    const legacyArm = body.slice(body.indexOf("when 'legacy_immediate_only' then"));
    expect(legacyArm, "the death condition reached the legacy arm — the policies were harmonized (R12)")
      .not.toContain("'after_verified_death'");
    // ★ …and the body is not empty of conditions altogether, which would pass the loops above
    // trivially. The two it MUST name are named.
    expect(body).toContain("'immediately'");
    expect(body).toContain("'after_owner_approval'");
  });

  it("there is no permissive default anywhere in the canonical module", () => {
    const canonical = load(CANONICAL).code;
    expect(canonical, "an `else true` in the authority is a fail-open default").not.toMatch(/\belse\s+true\b/i);
    expect(canonical, "the coalesce default must be false").toMatch(/coalesce\([\s\S]*?false\s*\)/);
    expect(canonical).not.toMatch(/coalesce\([^)]*?,\s*true\s*\)/);
  });
});

describe("5 · the bundles ship the authority with the code that calls it", () => {
  /**
   * ★ THE PHASE 10-F DEFECT, NOT REPEATED. `asset_bracket_low`/`asset_bracket_high` shipped in no
   * bundle at all: a fresh database built from the artifacts would have created functions referencing
   * helpers that did not exist. `release_condition_satisfied` is called by four bundled functions and
   * one `language sql` function whose body is resolved at CREATE time — so a bundle missing it does
   * not degrade, it fails to load.
   */
  it("the release-conditions bundle defines the canonical predicate", () => {
    const bundle = load("db/bundles/release_conditions_bundle.sql").code;
    expect(bundle).toMatch(/create\s+or\s+replace\s+function\s+public\.release_condition_satisfied\s*\(/i);
    expect(bundle).toMatch(/create\s+or\s+replace\s+function\s+public\.release_condition_writable\s*\(/i);
  });

  it("every bundle whose functions CALL the predicate is loaded after the one that defines it", () => {
    const { SQL_SUITE_PARTS } = require("../scripts/lib/sqlSuiteParts.mjs") as { SQL_SUITE_PARTS: string[] };
    const definer = SQL_SUITE_PARTS.indexOf("db/bundles/release_conditions_bundle.sql");
    expect(definer).toBeGreaterThanOrEqual(0);
    for (const b of SQL_BUNDLES.filter((f) => f !== "db/bundles/release_conditions_bundle.sql")) {
      if (!/public\.release_condition_satisfied\s*\(/i.test(load(b).code)) continue;
      const idx = SQL_SUITE_PARTS.indexOf(b);
      expect(idx, `${b} is not in the suite parts list`).toBeGreaterThanOrEqual(0);
      expect(idx, `${b} calls the predicate but loads before the bundle that defines it`).toBeGreaterThan(definer);
    }
  });

  it("the generated bundles are current — a stale artifact would audit a fossil", () => {
    /**
     * ★ THE BUNDLE IS COMPARED TO ITS SOURCES, not merely present. A bundle on disk that predates the
     * source it claims to carry would satisfy every assertion above about text that is no longer in
     * `db/functions/`, and the audit would be describing a file nobody would deploy.
     */
    const bundle = load("db/bundles/release_conditions_bundle.sql").code;
    for (const part of [CANONICAL, "db/functions/can_access_document.sql", "db/functions/document_grantable.sql"]) {
      const src = load(part).code.trim();
      expect(src.length).toBeGreaterThan(100);
      expect(bundle.includes(src), `${part} in the bundle differs from its source — rebuild the bundle`).toBe(true);
    }
  });
});

describe("6 · the predicate consumes the lifecycle as an ARGUMENT and still reads nothing", () => {
  /**
   * ★ REWRITTEN DELIBERATELY IN PHASE 11-D — the 11-B version pinned "no lifecycle argument" and
   * fired when the 11-D widening arrived, which is what it was for. What survives the widening,
   * pinned here: the predicate takes the lifecycle STATE (text), never an estate id — a predicate
   * that resolved estate → lifecycle itself would be a client-executable death-status oracle — and
   * it remains a PURE function: no table read, no claim projection, no designation check. The
   * lifecycle READ lives in SECURITY DEFINER consumers, through the one revoked-from-clients
   * reader, beside the grant lookup it scopes.
   */
  it("the canonical predicate takes the lifecycle STATE, and no estate id", () => {
    const canonical = load(CANONICAL).code;
    const sig = canonical.slice(
      canonical.indexOf("create or replace function public.release_condition_satisfied"),
      canonical.indexOf("returns boolean")
    );
    expect(sig.length).toBeGreaterThan(50);
    expect(sig).toContain("p_release_condition");
    expect(sig).toContain("p_approved_at");
    expect(sig).toContain("p_policy");
    expect(sig, "the 11-D lifecycle argument is gone — the predicate went lifecycle-blind again")
      .toContain("p_lifecycle_state");
    expect(sig, "the predicate gained an ESTATE argument — resolving estate → lifecycle inside a "
      + "client-executable function is a death-status oracle").not.toMatch(/p_estate\b|uuid/i);
    expect(sig).not.toMatch(/release_state|claim/i);
  });

  it("the canonical module consults no table and no other authority", () => {
    const canonical = load(CANONICAL).code;
    expect(canonical, "the authority reads a table — it must be a pure function of its arguments")
      .not.toMatch(/\bfrom\s+public\./i);
    expect(canonical).not.toMatch(/estate_release_state|claim_packets|estate_designations|is_estate_executor/);
    // The reader is named only in prose (stripped) — never called: the module receives the state.
    expect(canonical).not.toMatch(/public\.estate_lifecycle_state\s*\(/);
  });

  /**
   * ★ THE LIFECYCLE ARGUMENT DISCIPLINE — every call site, censused with balanced parentheses.
   *
   * The policy-argument rule below this one captures `([^)]*)`, which stops at the first close
   * paren and cannot see a nested `estate_lifecycle_state(...)` call. This rule extracts each call's
   * FULL argument list by balancing parens, then requires the fourth argument to be one of exactly
   * two shapes:
   *
   *   · `public.estate_lifecycle_state(<estate expr>)` — the authoritative seam, resolved by the
   *     SECURITY DEFINER consumer for the estate whose grant it is evaluating;
   *   · the literal `'active'` — ONLY in `lifecycle_notification_rpcs.sql`: the emission predicate
   *     is pinned to the base state by decision (a "You have access" born from death_verified is
   *     the release announcement 11-F owns), and that pin is load-bearing for the
   *     source↔deployment reconciler, which requires notification_grant_is_live to stay
   *     behaviourally byte-identical to the deployed 10-E body.
   *
   * Anything else — a pinned 'death_verified', a local variable holding a guess, a missing fourth
   * argument — is release policy leaking out of the canonical module.
   */
  const fullArgs = (code: string): string[] => {
    const out: string[] = [];
    const re = /(?<!function\s)public\.release_condition_satisfied\s*\(/gi;
    let m: RegExpExecArray | null;
    while ((m = re.exec(code)) !== null) {
      let depth = 1;
      let i = m.index + m[0].length;
      const start = i;
      while (i < code.length && depth > 0) {
        if (code[i] === "(") depth += 1;
        else if (code[i] === ")") depth -= 1;
        i += 1;
      }
      out.push(code.slice(start, i - 1));
    }
    return out;
  };

  it("every consumer passes the seam as the lifecycle argument (the notification pin excepted)", () => {
    const calls = SQL_SOURCES.flatMap((f) => fullArgs(load(f).code).map((args) => ({ file: f, args })));
    expect(calls.length, "fewer call sites than the rewiring created — this rule would be vacuous")
      .toBeGreaterThanOrEqual(7);
    for (const { file, args } of calls) {
      // Split top-level commas (depth 0) to isolate the fourth argument.
      const parts: string[] = [];
      let depth = 0;
      let cur = "";
      for (const ch of args) {
        if (ch === "(") depth += 1;
        if (ch === ")") depth -= 1;
        if (ch === "," && depth === 0) { parts.push(cur.trim()); cur = ""; continue; }
        cur += ch;
      }
      parts.push(cur.trim());
      expect(parts.length, `${file}: a predicate call has ${parts.length} argument(s), expected 4`).toBe(4);
      const lifecycle = parts[3].replace(/\s+/g, " ");
      if (file === "db/functions/lifecycle_notification_rpcs.sql") {
        expect(lifecycle, `${file}: the emission pin must be the base-state literal`).toBe("'active'");
      } else {
        expect(
          /^public\.estate_lifecycle_state\(\s*\w+(\.\w+)?\s*\)$/.test(lifecycle),
          `${file} passes a lifecycle that is not the authoritative seam: ${lifecycle}`
        ).toBe(true);
      }
    }
  });

  it("detection sanity: a pinned or hand-rolled lifecycle argument WOULD be caught", () => {
    const pinned = fullArgs("x := public.release_condition_satisfied(c, a, 'standard', 'death_verified');");
    expect(pinned).toEqual(["c, a, 'standard', 'death_verified'"]);
    const nested = fullArgs("x := public.release_condition_satisfied(c, a, 'standard', public.estate_lifecycle_state(v_estate));");
    expect(nested[0]).toContain("public.estate_lifecycle_state(v_estate)");
    // And a three-argument survivor (an un-rewired caller) fails the arity check above by shape.
    const three = fullArgs("x := public.release_condition_satisfied(c, a, 'standard');");
    expect(three[0].split(",").length).toBe(3);
  });

  it("no function other than get_estate_discovery calls estate_release_state", () => {
    const callers = SQL_SOURCES.filter(
      (f) => f !== "db/functions/estate_discovery_rpcs.sql" && /\bpublic\.estate_release_state\s*\(/.test(load(f).code)
    );
    expect(callers).toEqual([]);
  });
});
