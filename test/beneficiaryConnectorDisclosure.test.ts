/**
 * 0066 — beneficiary connector disclosure, scoped per estate.
 *
 * ★ WHAT A STATIC TEST CAN PROVE HERE, AND WHAT IT CANNOT. The SQL authorization suite proves the
 *   behaviour against a real Postgres. This proves the part a green SQL run cannot: that the MIGRATION
 *   and its three db/functions MIRRORS are the same text (so the harness exercised what an operator
 *   would paste), that the mirror is registered where the suite and the bundle builder will load it,
 *   and that the non-owner path of list_estate_assets can no longer EXPRESS a per-account bracket.
 */
import { readFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "vitest";
import { SQL_SUITE_PARTS } from "../scripts/lib/sqlSuiteParts.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const MIGRATION = "db/migrations/0066_20261119_beneficiary_connector_disclosure.sql";
const MIRRORS: Record<string, string> = {
  connector_disclosure_tier: "db/functions/connector_disclosure_tier.sql",
  list_estate_assets: "db/functions/list_estate_assets.sql",
  get_estate_net_worth: "db/functions/get_estate_net_worth.sql",
  get_estate_discovery: "db/functions/estate_discovery_rpcs.sql",
};
const SUITE = "db/tests/beneficiary_connector_disclosure_authorization.sql";
const read = (rel: string) => readFileSync(join(ROOT, rel), "utf8");
/** `--` comments blanked (strings kept), whitespace collapsed — the comparison is about code. */
const code = (sql: string) => sql.replace(/--[^\n]*/g, "").replace(/\s+/g, " ").trim();
function fnBlock(sql: string, name: string): string {
  const re = new RegExp(`create or replace function public\\.${name}\\([\\s\\S]*?\\$function\\$;`);
  const m = sql.match(re);
  return m ? code(m[0]) : "";
}

describe("the scan set is real", () => {
  test("every file this suite reasons about exists and is non-empty", () => {
    for (const f of [MIGRATION, SUITE, ...Object.values(MIRRORS)]) {
      expect(existsSync(join(ROOT, f)), f).toBe(true);
      expect(read(f).length, f).toBeGreaterThan(400);
    }
  });
  test("★ the comment stripper keeps code and drops prose — its own positive control", () => {
    expect(code("select 1; -- a comment\n select 2")).toBe("select 1; select 2");
    // The stripper is deliberately simple: it also blanks `--` inside a string literal. That is
    // harmless for an EQUALITY comparison applied to both sides, and no rule below depends on a
    // string that contains `--`.
    expect(code("a  \n   b")).toBe("a b");
  });
});

describe("★ migration and mirrors are the same text", () => {
  test.each(Object.entries(MIRRORS))("%s is byte-identical (whitespace-normalised) in the migration and db/functions", (name, file) => {
    const fromMigration = fnBlock(read(MIGRATION), name);
    const fromMirror = fnBlock(read(file), name);
    expect(fromMigration.length, `${name} not found in the migration`).toBeGreaterThan(300);
    expect(fromMirror).toBe(fromMigration);
  });
});

describe("★ the non-owner path can no longer express a per-account bracket", () => {
  const lea = fnBlock(read(MIGRATION), "list_estate_assets");
  test("the non-owner select emits NULL for both range columns", () => {
    const nonOwner = lea.slice(lea.indexOf("-- NON-OWNER") >= 0 ? lea.indexOf("-- NON-OWNER") : lea.indexOf("connector_disclosure_tier"));
    expect(nonOwner).toContain("null::bigint, null::bigint");
    expect(nonOwner).not.toMatch(/asset_bracket_(low|high)\s*\(/);
  });
  test("every connector reader resolves tiers through the one per-estate helper", () => {
    for (const name of ["list_estate_assets", "get_estate_net_worth", "get_estate_discovery"]) {
      expect(fnBlock(read(MIGRATION), name)).toMatch(/public\.connector_disclosure_tier\(/);
    }
  });
  test("the total's suppression is keyed on the RESOLVED balances tier being category_summary, not on existence", () => {
    const gnw = fnBlock(read(MIGRATION), "get_estate_net_worth");
    expect(gnw).toMatch(/v_bal = 'category_summary'/);
    expect(gnw).not.toMatch(/if exists \(\s*select 1 from public\.access_grants/);
  });
  test("discovery never emits a per-account bracket and never emits holdings", () => {
    const disco = fnBlock(read(MIGRATION), "get_estate_discovery");
    const rows = disco.slice(disco.indexOf("'connected_institutions'") >= 0 ? 0 : 0);
    expect(rows).not.toMatch(/holdings/);
    // the only bracket calls are over the per-category SUM
    const brackets = disco.match(/asset_bracket_(low|high)\(([^)]*)\)/g) ?? [];
    expect(brackets.length).toBeGreaterThanOrEqual(4);
    for (const b of brackets) expect(b).toMatch(/sum_cents|sum\(a\.approximate_value_cents\)/);
  });
});

describe("registration", () => {
  test("the helper is loaded by the suite before the readers that call it, and the suite runs before the exit matrix", () => {
    const i = SQL_SUITE_PARTS.indexOf("db/functions/connector_disclosure_tier.sql");
    const j = SQL_SUITE_PARTS.indexOf("db/functions/get_estate_net_worth.sql");
    const k = SQL_SUITE_PARTS.indexOf(SUITE);
    const x = SQL_SUITE_PARTS.indexOf("db/tests/phase10_exit_matrix.sql");
    expect(i).toBeGreaterThan(-1); expect(j).toBeGreaterThan(i); expect(k).toBeGreaterThan(-1); expect(x).toBeGreaterThan(k);
  });
  test("the estate bundle carries the helper before list_estate_assets", () => {
    const bundle = read("db/bundles/estate_inventory_and_discovery_bundle.sql");
    const h = bundle.indexOf("function public.connector_disclosure_tier");
    const l = bundle.indexOf("function public.list_estate_assets(");
    expect(h).toBeGreaterThan(-1); expect(l).toBeGreaterThan(h);
  });
});
