/**
 * R-02 EVENT-TRIGGER PROBE — design controls.
 *
 * ★ THIS PROBE IS EXPECTED TO FAIL, AND THAT IS THE POINT. Q1 observed `postgres.rolsuper = false`
 *   on the hosted target, and local validation reproduced the boundary exactly: a role with
 *   rolcreaterole + rolcreatedb + bypassrls but no superuser is refused with
 *   "Must be superuser to create an event trigger." Supabase may differ from vanilla PostgreSQL,
 *   which is why the probe exists — but a refusal is a RESULT, not an error to route around.
 *
 * ★ NOTHING HERE EXECUTES HOSTED SQL. These are design controls over the probe text and the guard.
 */
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "vitest";
import { splitStatements, stripComments } from "../scripts/lib/schemaInventory.mjs";
import {
  auditProbe, classifyProbeStatement, PROBE_FUNCTION, PROBE_TRIGGER, PROBE_VERSION,
  CANONICAL_NAMES, PROBE_REFUSAL,
} from "../scripts/lib/r02ProbePolicy.mjs";
import {
  classifyR02Target, R02_OPERATIONS, R02_DECISION, R02_REFUSAL,
  CANDIDATE_R02_TARGETS, FORBIDDEN_TARGETS, OPERATION_AUTHORIZATION_FLAG,
} from "../scripts/lib/r02TargetGuard.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const TARGET = CANDIDATE_R02_TARGETS[0];
const PROTECTED = FORBIDDEN_TARGETS.map((f) => f.ref);
const probeSql = readFileSync(join(ROOT, "docs/r02/event-trigger-probe.sql"), "utf8");
const stmts = splitStatements(probeSql).map((s: string) => stripComments(s).trim()).filter(Boolean);

/** Manifest for the real target. `over` mutates safety/expected_model for negative cases. */
const manifest = (over: Record<string, unknown> = {}, model: Record<string, unknown> = {}) => ({
  environment: { name: TARGET.projectName, classification: "nonproduction" },
  supabase: { project_ref: TARGET.ref, region: TARGET.region },
  safety: {
    production: false, allowlisted_refs: [TARGET.ref],
    hosted_sql_read_authorized: true, mutation_test_authorized: false,
    bootstrap_authorized: false, destructive_reset_authorized: false,
    migration_metadata_write_authorized: false, deployment_authorized: false,
    ...over,
  },
  expected_model: { bootstrap_version: "0060", future_migration_start: "0061", probe_version: PROBE_VERSION, ...model },
});
const probeReq = (over = {}) => ({ operation: R02_OPERATIONS.EVENT_TRIGGER_PROBE, bootstrapVersion: "0060", probeVersion: PROBE_VERSION, ...over });

describe("guard · the future probe authorization behaves correctly", () => {
  test("★ 1 · a fully valid probe request is refused ONLY because the grant is consumed", () => {
    // Probe v1 ran on 2026-08-30 and the grant is now marked consumed, so this can no longer be
    // MUTATION_AUTHORIZED. The property re-anchored here is stronger than the original: the request
    // is otherwise completely valid, so CONSUMPTION is the single reason for refusal. If any other
    // gate had broken, a different reason would appear alongside it.
    const r = classifyR02Target(manifest({ mutation_test_authorized: true }), probeReq());
    expect(r.reasons).toEqual([R02_REFUSAL.PROBE_ALREADY_CONSUMED]);
    expect(r.decision).toBe(R02_DECISION.REFUSED);
    // every other guard passed:
    expect(r.guards.filter((g) => !g.pass).map((g) => g.id)).toEqual(["R8_operation_authorized"]);
  });
  test.each([
    ["2 bootstrap", "bootstrap_apply"], ["3 destructive reset", "destructive_reset"],
    ["4 migration metadata write", "migration_metadata_write"], ["5 deploy", "deploy"],
  ])("★ %s is still refused with the probe grant", (_l, operation) => {
    expect(classifyR02Target(manifest({ mutation_test_authorized: true }), { operation, bootstrapVersion: "0060" }).decision)
      .toBe(R02_DECISION.REFUSED);
  });
  test("★ conversely, bootstrap_authorized does NOT enable the probe", () => {
    const r = classifyR02Target(manifest({ bootstrap_authorized: true }), probeReq());
    expect(r.decision).toBe(R02_DECISION.REFUSED);
    expect(r.reasons).toContain(R02_REFUSAL.MUTATION_TEST_NOT_AUTHORIZED);
  });
  test.each(PROTECTED)("★ 6/7 · %s refuses the probe even with the grant true", (ref) => {
    const m = manifest({ mutation_test_authorized: true, allowlisted_refs: [ref] });
    (m.supabase as Record<string, unknown>).project_ref = ref;
    expect(classifyR02Target(m, probeReq()).decision).toBe(R02_DECISION.REFUSED);
  });
  test("★ 8/9 · unknown and malformed refs refuse the probe", () => {
    const m1 = manifest({ mutation_test_authorized: true, allowlisted_refs: [] });
    expect(classifyR02Target(m1, probeReq()).reasons).toContain(R02_REFUSAL.TARGET_NOT_ALLOWLISTED);
    const m2 = manifest({ mutation_test_authorized: true, allowlisted_refs: ["nope"] });
    (m2.supabase as Record<string, unknown>).project_ref = "nope";
    expect(classifyR02Target(m2, probeReq()).reasons).toContain(R02_REFUSAL.TARGET_MALFORMED);
  });
  test.each([[undefined], [false], ["true"], [1], [null]])("★ 10/11/12 · mutation flag %s refuses", (flag) => {
    expect(classifyR02Target(manifest({ mutation_test_authorized: flag as never }), probeReq()).decision)
      .toBe(R02_DECISION.REFUSED);
  });
  test("★ 13 · a wrong or absent probe version refuses", () => {
    const authorized = manifest({ mutation_test_authorized: true });
    expect(classifyR02Target(authorized, probeReq({ probeVersion: "v2" })).reasons).toContain(R02_REFUSAL.PROBE_VERSION_MISMATCH);
    expect(classifyR02Target(authorized, probeReq({ probeVersion: "" })).reasons).toContain(R02_REFUSAL.PROBE_VERSION_MISMATCH);
    const drifted = manifest({ mutation_test_authorized: true }, { probe_version: "v2" });
    expect(classifyR02Target(drifted, probeReq()).reasons).toContain(R02_REFUSAL.PROBE_VERSION_MISMATCH);
  });
  test("the probe has its own flag, distinct from every other operation", () => {
    expect(OPERATION_AUTHORIZATION_FLAG.event_trigger_probe).toBe("mutation_test_authorized");
    const flags = Object.values(OPERATION_AUTHORIZATION_FLAG);
    expect(new Set(flags).size).toBe(flags.length);
  });
  test("★ 26 · MUTATION KILL — a protected ref fails EARLIER than the consumed check", () => {
    // Control: for the registered ref, the only failing gate is the consumed-grant check.
    const valid = classifyR02Target(manifest({ mutation_test_authorized: true }), probeReq());
    expect(valid.guards.filter((g) => !g.pass).map((g) => g.id)).toEqual(["R8_operation_authorized"]);
    // A protected ref additionally fails the forbidden-target rule — a different, earlier gate.
    for (const ref of PROTECTED) {
      const m = manifest({ mutation_test_authorized: true, allowlisted_refs: [ref] });
      (m.supabase as Record<string, unknown>).project_ref = ref;
      expect(classifyR02Target(m, probeReq()).decision, ref).toBe(R02_DECISION.REFUSED);
    }
  });
  test("★ an unauthorized manifest cannot run the probe — authorization is a separate explicit act", () => {
    // R-02 Phase 3B subsequently granted the probe, so the committed manifest now carries true.
    // The property was never "the manifest says false" — it is that a manifest WITHOUT the grant
    // is refused. Re-anchored so the test keeps meaning something after a deliberate authorization.
    const r = classifyR02Target(manifest({ mutation_test_authorized: false }), probeReq());
    expect(r.decision).toBe(R02_DECISION.REFUSED);
    expect(r.reasons).toContain(R02_REFUSAL.MUTATION_TEST_NOT_AUTHORIZED);
    const tpl = JSON.parse(readFileSync(join(ROOT, "docs/r02/environment-manifest.example.json"), "utf8"));
    expect(tpl.expected_model.probe_version).toBe(PROBE_VERSION);
  });
});

describe("probe policy · only the exact reviewed DDL is permitted", () => {
  test("the committed probe satisfies the policy", () => {
    const r = auditProbe(stmts);
    expect(r.problems).toEqual([]);
    expect(r.ok).toBe(true);
    expect(r.kinds).toEqual(["select", "create_function", "create_event_trigger", "select",
      "drop_event_trigger", "drop_function", "select"]);
  });
  test.each([
    ["18 CREATE TABLE", "create table public.x (id uuid)"],
    ["19 CREATE EXTENSION", "create extension pgcrypto"],
    ["   CREATE SCHEMA", "create schema probe"],
    ["20 SET ROLE", "set role supabase_admin"],
    ["21 GRANT", "grant select on public.x to anon"],
    ["   REVOKE", "revoke select on public.x from anon"],
    ["   ALTER", "alter table public.x add column y text"],
    ["   INSERT", "insert into public.x values (1)"],
    ["   UPDATE", "update public.x set y = 1"],
    ["   DELETE", "delete from public.x"],
    ["   TRUNCATE", "truncate public.x"],
    ["   MERGE", "merge into public.x using y on true"],
    ["   DO", "do $$ begin end $$"],
    ["   CALL", "call public.p()"],
    ["   COPY", "copy public.x from stdin"],
    ["   ALTER ROLE", "alter role postgres superuser"],
    ["★  SELECT INTO creating a table", "select * into public.newtbl from pg_class"],
    ["★  SELECT INTO short form", "select 1 into probe_tbl"],
  ])("★ %s is refused", (_l, sql) => {
    expect(classifyProbeStatement(sql)).toBeNull();
    expect(auditProbe([sql]).ok).toBe(false);
  });
  test.each([
    ["16 rls_auto_enable", "create function public.rls_auto_enable() returns event_trigger language plpgsql as $$ begin end $$"],
    ["17 ensure_rls", "create event trigger ensure_rls on ddl_command_end execute function public.r02_probe_event_fn_v1()"],
    ["   dropping ensure_rls", "drop event trigger if exists ensure_rls"],
    ["   dropping rls_auto_enable", "drop function if exists public.rls_auto_enable()"],
  ])("★ %s — canonical Model C name is forbidden", (_l, sql) => {
    const r = auditProbe([sql]);
    expect(r.ok).toBe(false);
    expect(r.problems.join(" ")).toMatch(/canonical_name_forbidden|unpinned_object_name/);
  });
  test.each([
    ["14 wrong function name", "create function public.some_other_fn() returns event_trigger language plpgsql as $$ begin end $$"],
    ["15 wrong trigger name", "create event trigger some_other_trigger on ddl_command_end execute function public.r02_probe_event_fn_v1()"],
    ["25 mutated DROP target", "drop event trigger if exists pgrst_ddl_watch"],
    ["   mutated DROP function", "drop function if exists public.is_estate_owner()"],
  ])("★ %s is refused as unpinned", (_l, sql) => {
    expect(auditProbe([sql]).problems.join(" ")).toContain(PROBE_REFUSAL.UNPINNED_OBJECT);
  });
  test("★ 22 · SECURITY DEFINER on the probe function is refused", () => {
    const sql = `create function public.${PROBE_FUNCTION}() returns event_trigger language plpgsql security definer as $$ begin end $$`;
    expect(auditProbe([sql]).problems).toContain(PROBE_REFUSAL.SECURITY_DEFINER);
  });
  test("★ 23 · an extra statement after the allowed sequence is refused", () => {
    const extra = [...stmts, "grant usage on schema public to anon"];
    expect(auditProbe(extra).ok).toBe(false);
  });
  test("★ 24 · missing cleanup is refused", () => {
    const noDrops = stmts.filter((s: string) => !/^drop/i.test(s));
    const r = auditProbe(noDrops);
    expect(r.ok).toBe(false);
    expect(r.problems.join(" ")).toContain(PROBE_REFUSAL.MISSING_CLEANUP);
  });
  test("missing PRE or POST check is refused", () => {
    expect(auditProbe(stmts.slice(1)).problems).toContain(PROBE_REFUSAL.MISSING_PRECHECK);
    expect(auditProbe(stmts.slice(0, -1)).problems).toContain(PROBE_REFUSAL.MISSING_POSTCHECK);
  });
  test("★ an empty probe is refused, never 'clean'", () => {
    expect(auditProbe([]).problems).toEqual([PROBE_REFUSAL.EMPTY]);
    expect(auditProbe(undefined as never).ok).toBe(false);
  });
  test("★ SELECT INTO is refused, but ordinary SELECTs are not — the rule is precise, not blunt", () => {
    // A statement beginning with SELECT is not automatically read-only: `SELECT ... INTO tbl`
    // creates a table. Classifying on the leading verb alone let that through.
    expect(classifyProbeStatement("select * into public.newtbl from pg_class")).toBeNull();
    expect(classifyProbeStatement("select 1 into probe_tbl")).toBeNull();
    // ...and these must still be allowed, or the rule would be blunt rather than correct:
    expect(classifyProbeStatement("select 1")).toMatchObject({ kind: "select" });
    expect(classifyProbeStatement("select 'into' as literal_word")).toMatchObject({ kind: "select" });
    expect(classifyProbeStatement("select 1 as into_x")).toMatchObject({ kind: "select" });
  });
  test("the committed probe's own PRE/POST selects survive the INTO rule", () => {
    const selects = stmts.filter((s: string) => /^select/i.test(s));
    expect(selects.length).toBe(3);
    for (const s of selects) expect(classifyProbeStatement(s)).toMatchObject({ kind: "select" });
  });

  test("★ POSITIVE CONTROL — the allowed forms ARE recognised, so the policy is not vacuous", () => {
    expect(classifyProbeStatement("select 1")).toMatchObject({ kind: "select" });
    expect(classifyProbeStatement(`create function public.${PROBE_FUNCTION}() returns event_trigger language plpgsql as $$ begin end $$`))
      .toMatchObject({ kind: "create_function", name: PROBE_FUNCTION });
    expect(classifyProbeStatement(`create event trigger ${PROBE_TRIGGER} on ddl_command_end execute function public.${PROBE_FUNCTION}()`))
      .toMatchObject({ kind: "create_event_trigger", name: PROBE_TRIGGER });
    expect(classifyProbeStatement(`drop event trigger if exists ${PROBE_TRIGGER}`)).toMatchObject({ kind: "drop_event_trigger" });
    expect(classifyProbeStatement(`drop function if exists public.${PROBE_FUNCTION}()`)).toMatchObject({ kind: "drop_function" });
  });
});

describe("3B · the granted authorization is exactly one probe", () => {
  const grant = async () => (await import("../scripts/lib/r02TargetGuard.mjs")).MUTATION_TEST_AUTHORIZATION;

  test("★ 27 · the grant is now CONSUMED — recorded with its outcome, not silently dropped", async () => {
    const g = (await grant())[0];
    expect(g.consumed).toBe(true);
    expect(g.consumedAt).toBe("2026-08-30");
    expect(g.outcome).toBe("EVENT_TRIGGER_CREATION_SUCCEEDED_AND_CLEANED");
    // A one-question authorization must not survive the answer as a standing mutation licence.
    const live = JSON.parse(readFileSync(join(ROOT, "docs/r02/environment-manifest.example.json"), "utf8"));
    expect(live.safety.mutation_test_authorized).toBe(false);
  });
  test("★ the grant is a single entry, one operation, one probe version", async () => {
    const g = (await grant())[0];
    expect((await grant())).toHaveLength(1);
    expect(g.ref).toBe(TARGET.ref);
    expect(g.grants).toEqual(["event_trigger_probe"]);
    expect(g.probeVersion).toBe(PROBE_VERSION);
    expect(g.probeFunction).toBe(PROBE_FUNCTION);
    expect(g.probeTrigger).toBe(PROBE_TRIGGER);
  });
  test("★ it withholds every other operation, and names the canonical objects it forbids", async () => {
    const g = (await grant())[0];
    expect(g.withholds).toEqual(["bootstrap_apply", "destructive_reset", "migration_metadata_write", "deploy"]);
    expect(g.forbidsCanonicalObjects).toEqual(["ensure_rls", "rls_auto_enable"]);
  });
  test("★ the pinned probe SHA-256 matches the committed probe — an edited probe cannot inherit this approval", async () => {
    const { createHash } = await import("node:crypto");
    const actual = createHash("sha256").update(readFileSync(join(ROOT, "docs/r02/event-trigger-probe.sql"))).digest("hex");
    expect((await grant())[0].probeSqlSha256).toBe(actual);
  });
  test("★ the grant does not reach any protected ref", async () => {
    for (const g of await grant()) expect(PROTECTED).not.toContain(g.ref);
  });
  test("★ execution is recorded as manual — automation is not authorized to run it", async () => {
    expect((await grant())[0].executedBy).toMatch(/manually/i);
    expect((await grant())[0].executedBy).toMatch(/never by automation/i);
  });
  test("live manifest: the probe flag returned to false after consumption, and nothing else moved", () => {
    // Was true during Phase 3B while the probe was pending. Returned to false in Phase 4A once the
    // probe had run and been cleaned. Every other mutation flag has never been true.
    const live = JSON.parse(readFileSync(join(ROOT, "docs/r02/environment-manifest.example.json"), "utf8"));
    expect(live.safety.mutation_test_authorized).toBe(false);
    // model_c_bootstrap_0060_authorized was deliberately granted in Phase 4B and is excluded here;
    // this test is about the PROBE flag and the flags that have never been true.
    for (const f of ["bootstrap_authorized", "destructive_reset_authorized",
                     "migration_metadata_write_authorized", "deployment_authorized"]) {
      expect(live.safety[f], f).toBe(false);
    }
    expect(live.safety.hosted_sql_read_authorized).toBe(true);   // reads remain authorized
  });
});

describe("probe text · structure and honesty", () => {
  test("names are disposable and versioned, never canonical", () => {
    expect(PROBE_FUNCTION).toBe("r02_probe_event_fn_v1");
    expect(PROBE_TRIGGER).toBe("r02_probe_event_trigger_v1");
    for (const c of CANONICAL_NAMES) {
      expect(PROBE_FUNCTION).not.toBe(c);
      expect(PROBE_TRIGGER).not.toBe(c);
    }
  });
  test("it targets the right project and forbids both protected ones", () => {
    expect(probeSql).toContain(TARGET.ref);
    for (const ref of PROTECTED) expect(probeSql).toContain(ref);
    expect(probeSql).toMatch(/NEVER RUN AGAINST/i);
  });
  test("★ it states that refusal is a valid result and forbids workarounds", () => {
    expect(probeSql).toMatch(/REFUSAL IS A VALID RESULT/i);
    expect(probeSql).toMatch(/NO WORKAROUND IS AUTHORIZED/i);
    expect(probeSql).toMatch(/no SET ROLE/i);
    expect(probeSql).toMatch(/supabase_admin/);
  });
  test("★ it records that it is NOT authorized to run", () => {
    expect(probeSql).toMatch(/DESIGN ONLY/i);
    expect(probeSql).toMatch(/mutation_test_authorized = false/i);
  });
  test("no table is created merely to make the trigger fire", async () => {
    // * LITERALS MASKED FIRST. The event trigger's tag list legitimately contains the STRING
    //   'CREATE TABLE' — that is what it listens for, not something it does. Matching the raw text
    //   flagged the probe for containing the very tag it must contain.
    const { maskLiterals } = await import("../scripts/lib/schemaInventory.mjs");
    const code = stmts.map((s: string) => maskLiterals(s)).join("\n");
    expect(/create\s+table/i.test(code)).toBe(false);
    // ...and the tag list is still present in the unmasked text, which is the point.
    expect(stmts.join("\n")).toContain("'CREATE TABLE'");
  });
  test("★ positive control — the masked check WOULD catch a real CREATE TABLE", async () => {
    const { maskLiterals } = await import("../scripts/lib/schemaInventory.mjs");
    expect(/create\s+table/i.test(maskLiterals("create table public.x (id uuid);"))).toBe(true);
  });
  test("the function body has no side effects and is not SECURITY DEFINER", () => {
    const fn = stmts.find((s: string) => /^create function/i.test(s))!;
    expect(fn).toMatch(/begin end/i);
    expect(fn).not.toMatch(/security\s+definer/i);
    expect(fn).toMatch(/set search_path/i);
    for (const bad of ["insert", "update", "delete", "create table", "raise"]) expect(fn.toLowerCase()).not.toContain(bad);
  });
  test("emergency cleanup is documented and idempotent", () => {
    expect(probeSql).toMatch(/EMERGENCY CLEANUP/i);
    expect(probeSql).toMatch(/drop event trigger if exists/i);
    expect(probeSql).toMatch(/drop function if exists/i);
  });
  test("★ the local finding is recorded, and marked as NOT hosted proof", () => {
    expect(probeSql).toMatch(/Must be superuser to create an event trigger/i);
    expect(probeSql).toMatch(/not about Supabase|may grant the capability by other means/i);
  });
});
