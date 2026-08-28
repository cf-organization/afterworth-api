/**
 * MODEL C CANONICAL BOOTSTRAP — the pins.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ THESE ARE NOT THE PROOF. The proof is a container executing 13 phase files against a virgin
 *   Postgres and a 27-dimension drift audit (`scripts/bootstrapFreshRun.mjs`). That takes a minute
 *   and Docker. These tests pin the parts that can be checked in milliseconds — classification,
 *   ownership boundaries, and the rules that must never quietly relax.
 *
 * ★ MUTATIONS 18-20 FROM THE BATTERY LIVE HERE, because they are classification defects rather than
 *   schema defects: a statement the generator cannot place, a platform object adopted as
 *   application-owned, and an application-owned-on-platform object dropped. None of those three can
 *   be expressed as a container run — a wrongly-classified object still applies cleanly.
 */
import { readFileSync, existsSync, readdirSync } from "node:fs";
import { execSync } from "node:child_process";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "vitest";
import { FIXTURE_MARKERS } from "../scripts/lib/migrationAuthority.mjs";
import {
  PHASES, PLATFORM_EXTENSIONS, PLATFORM_EVENT_TRIGGER_OWNERS,
  phaseOf, buildComponents, renderStoragePolicy, renderEventTrigger, parseTags,
} from "../scripts/lib/bootstrapComponents.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const BOOT = join(ROOT, "db/bootstrap");

describe("the bootstrap exists and is non-empty — assert the scan set first", () => {
  test("every declared phase has a file on disk", () => {
    for (const p of PHASES) expect(existsSync(join(BOOT, p.file))).toBe(true);
  });
  test("VERSION pins the cutover at 0060", () => {
    expect(readFileSync(join(BOOT, "VERSION"), "utf8").trim()).toBe("0060");
  });
  test("the manifest records bootstrap_schema_version 0060 and future start 0061", () => {
    const m = JSON.parse(readFileSync(join(BOOT, "manifest.json"), "utf8"));
    expect(m.bootstrap_schema_version).toBe("0060");
    expect(m.future_migrations.start).toBe("0061");
    expect(m.historical_migrations.replayed_during_virgin_bootstrap).toBe(false);
  });
  test("no phase file is empty of statements except by explicit note", () => {
    for (const p of PHASES) {
      const src = readFileSync(join(BOOT, p.file), "utf8");
      expect(src.length).toBeGreaterThan(200);
    }
  });
});

describe("historical honesty", () => {
  test("every phase file explicitly disclaims being a pre-0001 baseline", () => {
    // Assert the disclaimer is PRESENT rather than trying to pattern-dodge the phrase. A negative
    // regex over prose is brittle in both directions; the positive form says what is meant.
    for (const f of readdirSync(BOOT).filter((x) => x.endsWith(".sql"))) {
      const src = readFileSync(join(BOOT, f), "utf8");
      if (f.startsWith("00_")) continue;                    // the contract file has its own header
      expect(src).toMatch(/It is NOT a pre-0001 baseline/i);
    }
  });
  test("no file makes an affirmative pre-0001 claim", () => {
    for (const f of readdirSync(BOOT).filter((x) => x.endsWith(".sql"))) {
      const src = readFileSync(join(BOOT, f), "utf8");
      expect(src).not.toMatch(/(is|represents) the pre-0001|pre-0001 baseline\.(?! )/i);
    }
  });
  test("★ migrations 0001-0060 are untouched by this work", () => {
    // * SCOPED TO THE HISTORICAL RANGE. The first version asserted the whole directory was clean,
    //   so an UNTRACKED legitimate 0061 — which git reports as `??` — failed it. That conflated
    //   "history was rewritten" with "a future migration exists", and the second is permitted.
    const cutoff = Number(readFileSync(join(ROOT, "db/bootstrap/VERSION"), "utf8").trim());
    const changed = execSync("git status --porcelain db/migrations/", { cwd: ROOT, encoding: "utf8" })
      .trim().split("\n").filter(Boolean)
      .map((l) => l.slice(3).trim().replace(/^.*\//, ""))
      .filter((n) => { const q = Number(n.slice(0, 4)); return Number.isFinite(q) && q <= cutoff; });
    expect(changed).toEqual([]);
  });
  test("the synthetic FIXTURE never entered production numbering", () => {
    // * THE TEST IS ABOUT FIXTURES, NOT ABOUT THE NUMBER 0061. Forbidding /^0061/ outright would
    //   forbid the legitimate first future migration, which db/AUTHORITY.json explicitly authorizes.
    const names = readdirSync(join(ROOT, "db/migrations"));
    expect(names.filter((n) => /synthetic/i.test(n))).toEqual([]);
    for (const n of names.filter((x) => x.endsWith(".sql"))) {
      const sql = readFileSync(join(ROOT, "db/migrations", n), "utf8");
      expect(FIXTURE_MARKERS.some((m) => sql.includes(m))).toBe(false);
    }
    expect(existsSync(join(ROOT, "test/fixtures/synthetic_future_migration.sql"))).toBe(true);
  });
});

describe("ownership boundaries are enforced by classification, not by name filtering", () => {
  test("the platform contract creates nothing", () => {
    const src = readFileSync(join(BOOT, "00_platform_contract.sql"), "utf8");
    expect(src).not.toMatch(/^\s*create (table|schema|role|extension)/im);
    expect(src).toMatch(/raise exception/i);
  });
  test("auth.users and storage.objects are never created by production bootstrap DDL", () => {
    for (const f of readdirSync(BOOT).filter((x) => x.endsWith(".sql"))) {
      const src = readFileSync(join(BOOT, f), "utf8");
      expect(src).not.toMatch(/create table[^\n]*"?auth"?\."?users/i);
      expect(src).not.toMatch(/create table[^\n]*"?storage"?\."?objects/i);
    }
  });
  test("the test shim is quarantined and unreferenced", () => {
    expect(existsSync(join(BOOT, "testing/PLATFORM_SHIM_NOT_PRODUCTION.sql"))).toBe(true);
    for (const f of readdirSync(BOOT).filter((x) => x.endsWith(".sql"))) {
      expect(readFileSync(join(BOOT, f), "utf8")).not.toMatch(/PLATFORM_SHIM/);
    }
  });

  test("★ MUTATION 19: a platform-owned event trigger is NOT adopted as application-owned", () => {
    const platform = { evtname: "pgrst_ddl_watch", evtevent: "ddl_command_end", evttags: null,
      event_trigger_owner: "supabase_admin", function_schema: "extensions", function_name: "pgrst_ddl_watch" };
    const app = { evtname: "ensure_rls", evtevent: "ddl_command_end", evttags: '["CREATE TABLE"]',
      event_trigger_owner: "postgres", function_schema: "public", function_name: "rls_auto_enable" };
    const { byPhase } = buildComponents({ statements: [], storagePolicies: [], eventTriggers: [platform, app] });
    const emitted = byPhase.get("120").map((i) => i.sql).join("\n");
    expect(emitted).toMatch(/ensure_rls/);
    expect(emitted).not.toMatch(/pgrst_ddl_watch/);
  });
  test("ownership is decided by evtowner — renaming the app trigger does not change adoption", () => {
    const renamed = { evtname: "pgrst_ddl_watch", evtevent: "ddl_command_end", evttags: null,
      event_trigger_owner: "postgres", function_schema: "public", function_name: "rls_auto_enable" };
    const { byPhase } = buildComponents({ statements: [], storagePolicies: [], eventTriggers: [renamed] });
    expect(byPhase.get("120")).toHaveLength(1);   // adopted because of its OWNER, despite the name
  });
  test("platform extensions are recorded as prerequisites, not created", () => {
    const { byPhase } = buildComponents({
      statements: ['CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault"',
                   'CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions"'],
      storagePolicies: [], eventTriggers: [],
    });
    expect(byPhase.get("10").map((i) => i.sql).join()).toMatch(/pgcrypto/);
    expect(byPhase.get("10").map((i) => i.sql).join()).not.toMatch(/supabase_vault/);
    expect(byPhase.get("00").map((i) => i.sql).join()).toMatch(/supabase_vault/);
    expect(PLATFORM_EXTENSIONS).toContain("supabase_vault");
    expect(PLATFORM_EVENT_TRIGGER_OWNERS).toContain("supabase_admin");
  });

  test("★ MUTATION 20: an application-owned-on-platform policy is not silently dropped", () => {
    const { byPhase } = buildComponents({
      statements: [], eventTriggers: [],
      storagePolicies: [
        { schemaname: "storage", tablename: "objects", policyname: "documents_estate_read", permissive: "PERMISSIVE", roles: "{authenticated}", cmd: "SELECT", qual: "true", with_check: "null" },
        { schemaname: "storage", tablename: "objects", policyname: "documents_estate_insert", permissive: "PERMISSIVE", roles: "{authenticated}", cmd: "INSERT", qual: "null", with_check: "true" },
      ],
    });
    expect(byPhase.get("110")).toHaveLength(2);
    const sql = byPhase.get("110").map((i) => i.sql).join("\n");
    expect(sql).toMatch(/documents_estate_read/);
    expect(sql).toMatch(/documents_estate_insert/);
  });
});

describe("★ MUTATION 18: an unclassifiable statement is surfaced, never dropped", () => {
  test("a statement no phase claims is reported as unassigned", () => {
    const { unassigned } = buildComponents({ statements: ["FLURB TABLE public.x"], storagePolicies: [], eventTriggers: [] });
    expect(unassigned).toHaveLength(1);
  });
  test("the generator refuses when anything is unassigned", () => {
    // The runner exits 2 on unassigned; proven behaviourally against the real binary elsewhere.
    expect(phaseOf("FLURB TABLE public.x")).toBe("?");
  });
  test("session settings are skipped explicitly (null), not silently unassigned", () => {
    expect(phaseOf("SET statement_timeout = 0")).toBeNull();
    expect(phaseOf("ALTER PUBLICATION supabase_realtime OWNER TO postgres")).toBeNull();
  });
  test.each([
    ['CREATE TABLE IF NOT EXISTS "public"."x" ("id" uuid)', "30"],
    ['ALTER TABLE ONLY "public"."x" ADD CONSTRAINT "x_pkey" PRIMARY KEY ("id")', "40"],
    ['ALTER TABLE "public"."x" ALTER COLUMN "id" SET DEFAULT 1', "40"],
    ['ALTER SEQUENCE "public"."s" OWNED BY "public"."x"."id"', "40"],
    ['ALTER SEQUENCE "public"."s" OWNER TO "postgres"', "100"],
    ['CREATE INDEX "i" ON "public"."x" USING btree ("id")', "50"],
    ['CREATE OR REPLACE FUNCTION "public"."f"() RETURNS void', "60"],
    ['CREATE OR REPLACE TRIGGER "t" BEFORE INSERT ON "public"."x"', "70"],
    ['ALTER TABLE "public"."x" ENABLE ROW LEVEL SECURITY', "80"],
    ['CREATE POLICY "p" ON "public"."x" FOR SELECT', "90"],
    ['GRANT SELECT ON TABLE "public"."x" TO "authenticated"', "100"],
    ['REVOKE ALL ON FUNCTION "public"."f"() FROM PUBLIC', "100"],
    ['ALTER TABLE "public"."x" OWNER TO "postgres"', "100"],
    ['CREATE TYPE "public"."e" AS ENUM (\'a\')', "20"],
    ['CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions"', "10"],
  ])("classifies %s", (stmt, want) => {
    expect(phaseOf(stmt)).toBe(want);
  });
});

describe("evidence rendering is verbatim, never reconstructed", () => {
  test("an INSERT policy emits WITH CHECK and no USING", () => {
    const sql = renderStoragePolicy({ schemaname: "storage", tablename: "objects", policyname: "p",
      permissive: "PERMISSIVE", roles: "{authenticated}", cmd: "INSERT", qual: "null", with_check: "(a = 1)" });
    expect(sql).toMatch(/WITH CHECK \(\(a = 1\)\)/);
    expect(sql).not.toMatch(/USING/);
  });
  test("a SELECT policy emits USING and no WITH CHECK", () => {
    const sql = renderStoragePolicy({ schemaname: "storage", tablename: "objects", policyname: "p",
      permissive: "PERMISSIVE", roles: "{authenticated}", cmd: "SELECT", qual: "(a = 1)", with_check: "null" });
    expect(sql).toMatch(/USING \(\(a = 1\)\)/);
    expect(sql).not.toMatch(/WITH CHECK/);
  });
  test("★ the string 'null' from a CSV is a missing clause, not a predicate", () => {
    const sql = renderStoragePolicy({ schemaname: "storage", tablename: "objects", policyname: "p",
      permissive: "PERMISSIVE", roles: "{authenticated}", cmd: "SELECT", qual: "(a = 1)", with_check: "null" });
    expect(sql).not.toMatch(/WITH CHECK \(null\)/);
  });
  test("event-trigger tags come from evttags — absent tags mean NO WHEN clause", () => {
    expect(renderEventTrigger({ evtname: "t", evtevent: "ddl_command_end", evttags: null,
      function_schema: "public", function_name: "f" })).not.toMatch(/WHEN TAG/);
    expect(renderEventTrigger({ evtname: "t", evtevent: "ddl_command_end", evttags: '["CREATE TABLE","SELECT INTO"]',
      function_schema: "public", function_name: "f" })).toMatch(/WHEN TAG IN \('CREATE TABLE', 'SELECT INTO'\)/);
  });
  test.each([
    ['["CREATE TABLE","SELECT INTO"]', ["CREATE TABLE", "SELECT INTO"]],
    ["{CREATE TABLE}", ["CREATE TABLE"]],
    [null, []],
    ["null", []],
    ["", []],
  ])("parseTags(%s)", (raw, want) => {
    expect(parseTags(raw as string)).toEqual(want);
  });
});

describe("legacy compatibility surface", () => {
  test("★ public.assets is present in the bootstrap and its removal is not a tidy-up", () => {
    const tables = readFileSync(join(BOOT, "30_tables.sql"), "utf8");
    expect(tables).toMatch(/CREATE TABLE IF NOT EXISTS "public"\."assets"/);
    const m = JSON.parse(readFileSync(join(BOOT, "manifest.json"), "utf8"));
    expect(m.legacy_compatibility_surface["public.assets"]).toMatch(/DROP NOT AUTHORIZED/);
  });
  test("its RLS and both policies travel with it", () => {
    expect(readFileSync(join(BOOT, "80_rls_enable.sql"), "utf8")).toMatch(/"public"\."assets" ENABLE ROW LEVEL SECURITY/);
    const pol = readFileSync(join(BOOT, "90_policies.sql"), "utf8");
    expect(pol).toMatch(/"assets_read"/);
    expect(pol).toMatch(/"assets_write"/);
  });
});

describe("hosted compatibility is never claimed locally", () => {
  test("the event-trigger phase carries the unproven flag", () => {
    expect(readFileSync(join(BOOT, "120_event_triggers.sql"), "utf8")).toMatch(/HOSTED_COMPATIBILITY_PROOF_REQUIRED/);
  });
  test("★ the manifest records hosted compatibility as NOT proven", () => {
    const m = JSON.parse(readFileSync(join(BOOT, "manifest.json"), "utf8"));
    expect(m.event_triggers.hosted_compatibility_proven).toBe(false);
  });
  test("the shim states that local success is not hosted proof", () => {
    const shim = readFileSync(join(BOOT, "testing/PLATFORM_SHIM_NOT_PRODUCTION.sql"), "utf8");
    expect(shim).toMatch(/NOT PRODUCTION/);
    expect(shim).toMatch(/does not clear|NOT hosted Supabase compatibility/i);
  });
});

describe("restore contract", () => {
  test("phase 60 disables function-body checking, as pg_dump does", () => {
    expect(readFileSync(join(BOOT, "60_functions.sql"), "utf8")).toMatch(/SET check_function_bodies = false;/);
  });
  test("phases whose predicates are unqualified set a search_path", () => {
    for (const f of ["110_storage_policies.sql", "90_policies.sql", "70_triggers.sql"]) {
      expect(readFileSync(join(BOOT, f), "utf8")).toMatch(/SET search_path = /);
    }
  });
});
