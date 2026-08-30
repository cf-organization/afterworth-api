/**
 * R-02 HOSTED MODEL C BOOTSTRAP — design controls.
 *
 * ★ AUTHORIZATION IS BY HASH, NOT BY INSPECTION. The event-trigger probe was six statements, so
 *   enumerating its allowed forms was tractable. The bootstrap is 921 statements that legitimately
 *   include CREATE TABLE, GRANT, CREATE POLICY and CREATE EVENT TRIGGER — an allowlist permissive
 *   enough to admit all of that would also admit one substituted statement hidden among them, which
 *   is the only attack that matters. So every phase is pinned by sha256.
 *
 * ★ NOTHING HERE EXECUTES ANYTHING, hosted or local.
 */
import { readFileSync, readdirSync } from "node:fs";
import { createHash } from "node:crypto";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "vitest";
import {
  auditBootstrapExecution, BOOTSTRAP_AUDIT, BOOTSTRAP_REFUSAL,
  isHistoricalMigration, writesMigrationMetadata,
} from "../scripts/lib/bootstrapExecutionAudit.mjs";
import {
  classifyR02Target, R02_OPERATIONS, R02_DECISION, R02_REFUSAL,
  CANDIDATE_R02_TARGETS, FORBIDDEN_TARGETS, OPERATION_AUTHORIZATION_FLAG,
  MUTATION_TEST_AUTHORIZATION, LOCAL_ONLY_OPERATIONS, MODEL_C_BOOTSTRAP_AUTHORIZATION,
} from "../scripts/lib/r02TargetGuard.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const TARGET = CANDIDATE_R02_TARGETS[0];
const PROTECTED = FORBIDDEN_TARGETS.map((f) => f.ref);
const MAN = JSON.parse(readFileSync(join(ROOT, "docs/r02/model-c-bootstrap-0060-manifest.json"), "utf8"));
const sha = (s: string) => createHash("sha256").update(s).digest("hex");
const realFiles = () => MAN.phases.map((p: { file: string; sha256: string }) =>
  ({ file: p.file, sha256: p.sha256, sql: readFileSync(join(ROOT, p.file), "utf8") }));
const exec = (over = {}) => ({ targetRef: TARGET.ref, version: "0060", files: realFiles(), ...over });

const manifest = (over: Record<string, unknown> = {}, model: Record<string, unknown> = {}) => ({
  environment: { name: TARGET.projectName, classification: "nonproduction" },
  supabase: { project_ref: TARGET.ref },
  safety: {
    production: false, allowlisted_refs: [TARGET.ref],
    hosted_sql_read_authorized: true, mutation_test_authorized: false,
    model_c_bootstrap_0060_authorized: false, bootstrap_authorized: false,
    destructive_reset_authorized: false, migration_metadata_write_authorized: false,
    deployment_authorized: false, ...over,
  },
  expected_model: {
    bootstrap_version: "0060", future_migration_start: "0061", probe_version: "v1",
    bootstrap_manifest_sha256: MAN.cumulative_bootstrap_sha256, ...model,
  },
});
const req = (over = {}) => ({
  operation: R02_OPERATIONS.MODEL_C_BOOTSTRAP_0060, bootstrapVersion: "0060",
  bootstrapManifestSha256: MAN.cumulative_bootstrap_sha256, ...over,
});

describe("manifest is computed from current main, not hard-coded", () => {
  test("★ 25 · every pinned phase hash matches the file on disk", () => {
    expect(MAN.phases.length).toBe(13);
    for (const p of MAN.phases) {
      expect(sha(readFileSync(join(ROOT, p.file), "utf8")), p.file).toBe(p.sha256);
    }
  });
  test("the cumulative hash is reproducible from the phase hashes", () => {
    const cumulative = sha(MAN.phases.map((p: { phase: string; sha256: string }) => `${p.phase}:${p.sha256}`).join("\n"));
    expect(cumulative).toBe(MAN.cumulative_bootstrap_sha256);
  });
  test("phase order matches the numeric filename order on disk", () => {
    const onDisk = readdirSync(join(ROOT, "db/bootstrap")).filter((f) => /^\d+_.*\.sql$/.test(f))
      .sort((a, b) => Number(a.split("_")[0]) - Number(b.split("_")[0])).map((f) => f.split("_")[0]);
    expect(MAN.phase_order).toEqual(onDisk);
  });
  test("version is 0060 and the assertions are explicit", () => {
    expect(MAN.version).toBe("0060");
    expect(readFileSync(join(ROOT, "db/bootstrap/VERSION"), "utf8").trim()).toBe("0060");
    expect(MAN.assertions.replays_migrations_0001_0060).toBe(false);
    expect(MAN.assertions.writes_migration_metadata).toBe(false);
    expect(MAN.assertions.bootstrap_rolls_forward).toBe(false);
  });
  test("★ the count differences are explained rather than silently adjusted", () => {
    expect(MAN.expected_objects.public_policies).toBe(36);
    expect(MAN.expected_objects.storage_policies).toBe(2);
    expect(MAN.expected_objects.extensions_created).toBe(2);
    expect(MAN.expected_objects.extensions_platform_supplied).toBe(2);
    expect(MAN.count_notes.policies).toMatch(/36 public.*2 storage/i);
    expect(MAN.count_notes.extensions).toMatch(/PLATFORM-SUPPLIED/i);
    expect(MAN.count_notes.statements).toMatch(/921/);
  });
});

describe("execution audit — hash-pinned", () => {
  test("★ 21 · POSITIVE CONTROL: the real bootstrap IS authorized", () => {
    const r = auditBootstrapExecution(MAN, exec(), sha);
    expect(r.problems).toEqual([]);
    expect(r.verdict).toBe(BOOTSTRAP_AUDIT.OK);
  });
  test.each([
    ["9  phase mutation", () => exec({ files: realFiles().map((f, i) => i === 3 ? { ...f, sha256: "0".repeat(64) } : f) }), BOOTSTRAP_REFUSAL.PHASE_HASH_MISMATCH],
    ["6  missing phase", () => exec({ files: realFiles().slice(1) }), BOOTSTRAP_REFUSAL.PHASE_MISSING],
    ["7  extra phase", () => exec({ files: [...realFiles(), { file: "db/bootstrap/99_rogue.sql", sha256: "a".repeat(64) }] }), BOOTSTRAP_REFUSAL.PHASE_EXTRA],
    ["8  reordered phases", () => { const f = realFiles(); return exec({ files: [f[1], f[0], ...f.slice(2)] }); }, BOOTSTRAP_REFUSAL.PHASE_REORDERED],
    ["10 migration 0001 injected", () => exec({ files: [{ file: "db/migrations/0001_x.sql", sha256: "b".repeat(64) }, ...realFiles()] }), BOOTSTRAP_REFUSAL.HISTORICAL_MIGRATION_PRESENT],
    ["11 migration 0060 replay", () => exec({ files: [...realFiles(), { file: "db/migrations/0060_x.sql", sha256: "c".repeat(64) }] }), BOOTSTRAP_REFUSAL.HISTORICAL_MIGRATION_PRESENT],
    ["12 metadata write injected", () => exec({ files: realFiles().map((f, i) => i === 0 ? { ...f, sql: "insert into supabase_migrations.schema_migrations values ('0060')" } : f) }), BOOTSTRAP_REFUSAL.MIGRATION_METADATA_WRITE],
    ["4  wrong version", () => exec({ version: "0061" }), BOOTSTRAP_REFUSAL.VERSION_MISMATCH],
    ["22 protected-ref target", () => exec({ targetRef: PROTECTED[0] }), BOOTSTRAP_REFUSAL.TARGET_MISMATCH],
    ["   empty set", () => exec({ files: [] }), BOOTSTRAP_REFUSAL.EMPTY],
  ])("★ %s is refused", (_l, build, reason) => {
    const r = auditBootstrapExecution(MAN, build(), sha);
    expect(r.verdict).toBe(BOOTSTRAP_AUDIT.REFUSED);
    expect(r.problems.join(" ")).toContain(reason);
  });
  test("★ 23 · MUTATION KILL — a regenerated cumulative hash still fails if a phase changed", () => {
    const tampered = { ...MAN, phases: MAN.phases.map((p: { sha256: string }, i: number) => i === 5 ? { ...p, sha256: "d".repeat(64) } : p) };
    const r = auditBootstrapExecution(tampered, exec(), sha);
    expect(r.verdict).toBe(BOOTSTRAP_AUDIT.REFUSED);
  });
  test("historical-migration and metadata detectors are precise", () => {
    expect(isHistoricalMigration("db/migrations/0001_x.sql")).toBe(true);
    expect(isHistoricalMigration("db/migrations/0060_x.sql")).toBe(true);
    expect(isHistoricalMigration("db/migrations/0061_x.sql")).toBe(false);   // future is not historical
    expect(isHistoricalMigration("db/bootstrap/30_tables.sql")).toBe(false);
    expect(writesMigrationMetadata("insert into supabase_migrations.schema_migrations values (1)")).toBe(true);
    expect(writesMigrationMetadata("select * from supabase_migrations.schema_migrations")).toBe(false);
  });
});

describe("bootstrap authorization guard", () => {
  test("★ 2 · a manifest WITHOUT the grant is refused — authorization is a separate explicit act", () => {
    // R-02 Phase 4B subsequently granted the bootstrap, so the committed manifest now carries true.
    // The property was never "the file says false"; it is that absence of the grant refuses.
    const r = classifyR02Target(manifest(), req());
    expect(r.decision).toBe(R02_DECISION.REFUSED);
    expect(r.reasons).toContain(R02_REFUSAL.MODEL_C_BOOTSTRAP_NOT_AUTHORIZED);
  });
  test("★ 21b · POSITIVE CONTROL: with the grant it WOULD authorize — the refusals are not vacuous", () => {
    const r = classifyR02Target(manifest({ model_c_bootstrap_0060_authorized: true }), req());
    expect(r.reasons).toEqual([]);
    expect(r.decision).toBe(R02_DECISION.MUTATION_AUTHORIZED);
  });
  test.each([
    ["16 hosted_sql_read cannot imply bootstrap", { hosted_sql_read_authorized: true }],
    ["15 probe authorization cannot imply bootstrap", { mutation_test_authorized: true }],
    ["   generic bootstrap_authorized cannot imply it", { bootstrap_authorized: true }],
    ["14 reset authorization cannot imply it", { destructive_reset_authorized: true }],
    ["13 deployment authorization cannot imply it", { deployment_authorized: true }],
  ])("★ %s", (_l, over) => {
    expect(classifyR02Target(manifest(over), req()).decision).toBe(R02_DECISION.REFUSED);
  });
  test("★ 5 · a wrong bootstrap manifest hash refuses", () => {
    const authorized = manifest({ model_c_bootstrap_0060_authorized: true });
    expect(classifyR02Target(authorized, req({ bootstrapManifestSha256: "f".repeat(64) })).reasons)
      .toContain(R02_REFUSAL.BOOTSTRAP_MANIFEST_MISMATCH);
    expect(classifyR02Target(authorized, req({ bootstrapManifestSha256: "" })).reasons)
      .toContain(R02_REFUSAL.BOOTSTRAP_MANIFEST_MISMATCH);
    const drifted = manifest({ model_c_bootstrap_0060_authorized: true }, { bootstrap_manifest_sha256: "e".repeat(64) });
    expect(classifyR02Target(drifted, req()).reasons).toContain(R02_REFUSAL.BOOTSTRAP_MANIFEST_MISMATCH);
  });
  test("★ 4 · a wrong bootstrap version refuses", () => {
    expect(classifyR02Target(manifest({ model_c_bootstrap_0060_authorized: true }), req({ bootstrapVersion: "0061" })).reasons)
      .toContain(R02_REFUSAL.BOOTSTRAP_VERSION_MISMATCH);
  });
  test.each(PROTECTED)("★ 3/22 · %s refuses the bootstrap with EVERY flag true", (ref) => {
    const m = manifest({ allowlisted_refs: [ref] });
    (m.supabase as Record<string, unknown>).project_ref = ref;
    for (const f of Object.values(OPERATION_AUTHORIZATION_FLAG)) (m.safety as Record<string, unknown>)[f] = true;
    expect(classifyR02Target(m, req()).decision).toBe(R02_DECISION.REFUSED);
  });
  test.each([
    ["18 wildcard target", "*"], ["19 malformed ref", "not-a-ref"], ["20 unknown ref", "zzzzzzzzzzzzzzzzzzzz"],
  ])("★ %s refuses even when self-allowlisted", (_l, ref) => {
    // The allowlist is operator-declared and sufficient for a READ. For a 921-statement mutation it
    // is not: a mistyped-but-allowlisted ref must still be refused, so the bootstrap is additionally
    // pinned to the REGISTERED candidate. This case originally returned MUTATION_AUTHORIZED.
    const m = manifest({ model_c_bootstrap_0060_authorized: true, allowlisted_refs: [ref] });
    (m.supabase as Record<string, unknown>).project_ref = ref;
    expect(classifyR02Target(m, req()).decision).toBe(R02_DECISION.REFUSED);
  });
  test("★ and the registered target itself is still authorized — the pin is not a blanket refusal", () => {
    expect(classifyR02Target(manifest({ model_c_bootstrap_0060_authorized: true }), req()).decision)
      .toBe(R02_DECISION.MUTATION_AUTHORIZED);
  });
  test("every operation still has its own distinct flag", () => {
    const flags = Object.values(OPERATION_AUTHORIZATION_FLAG);
    expect(new Set(flags).size).toBe(flags.length);
    expect(OPERATION_AUTHORIZATION_FLAG.model_c_bootstrap_0060).toBe("model_c_bootstrap_0060_authorized");
    expect(OPERATION_AUTHORIZATION_FLAG.model_c_bootstrap_0060).not.toBe(OPERATION_AUTHORIZATION_FLAG.bootstrap_apply);
    for (const op of Object.values(R02_OPERATIONS)) {
      expect(LOCAL_ONLY_OPERATIONS.includes(op) || Object.keys(OPERATION_AUTHORIZATION_FLAG).includes(op), op).toBe(true);
    }
  });
});

describe("probe v1 is consumed and cannot be silently reused", () => {
  test("★ 17 · a consumed probe grant cannot authorize, even with the flag true", () => {
    expect(MUTATION_TEST_AUTHORIZATION[0].consumed).toBe(true);
    expect(MUTATION_TEST_AUTHORIZATION[0].outcome).toBe("EVENT_TRIGGER_CREATION_SUCCEEDED_AND_CLEANED");
    const r = classifyR02Target(manifest({ mutation_test_authorized: true }),
      { operation: R02_OPERATIONS.EVENT_TRIGGER_PROBE, bootstrapVersion: "0060", probeVersion: "v1" });
    expect(r.decision).toBe(R02_DECISION.REFUSED);
    expect(r.reasons).toContain(R02_REFUSAL.PROBE_ALREADY_CONSUMED);
  });
  test("the live manifest returned the probe flag to false", () => {
    const live = JSON.parse(readFileSync(join(ROOT, "docs/r02/environment-manifest.example.json"), "utf8"));
    expect(live.safety.mutation_test_authorized).toBe(false);
  });
  test("★ 17b · and a consumed grant does not leak into bootstrap authorization", () => {
    expect(classifyR02Target(manifest({ mutation_test_authorized: true }), req()).decision).toBe(R02_DECISION.REFUSED);
  });
});

describe("design documents record what evidence supports", () => {
  const risks = readFileSync(join(ROOT, "docs/r02/supabase-sql-editor-risks.md"), "utf8");
  const plan = readFileSync(join(ROOT, "docs/r02/hosted-model-c-bootstrap-rehearsal.md"), "utf8");

  test("★ 24 · the SQL Editor rule requires the executed SQL to remain the reviewed SQL", () => {
    expect(risks).toMatch(/must remain the reviewed SQL/i);
    expect(risks).toMatch(/not a general recommendation to bypass RLS warnings/i);
    expect(risks).toMatch(/SUPABASE_SQL_EDITOR_RLS_ASSISTANT_FALSE_POSITIVE/);
  });
  test("★ observed behaviour is separated from inferred implementation", () => {
    expect(risks).toMatch(/What is NOT claimed/i);
    expect(risks).toMatch(/undocumented/i);
    expect(risks).toMatch(/42P01/);
    expect(risks).toMatch(/not a PostgreSQL privilege refusal/i);
  });
  test("the hazard scan classes are recorded with counts", () => {
    expect(risks).toMatch(/real table creation/i);
    expect(risks).toMatch(/\b41\b/);
    expect(risks).toMatch(/tag\/literal false-positive/i);
  });
  test("★ the plan forbids replaying 0001-0060 and states the authority path", () => {
    expect(plan).toMatch(/Migrations 0001–0060 are NOT replayed/i);
    expect(plan).toMatch(/db\/bootstrap @ VERSION 0060/);
    expect(plan).toMatch(/does not roll forward/i);
  });
  test("★ 14b · destructive reset requires separate authorization, and is not implicit", () => {
    expect(plan).toMatch(/destructive_reset_authorized.*false/i);
    expect(plan).toMatch(/PARTIAL_BOOTSTRAP/);
    // The sentence wraps across a blockquote line, so the continuation begins with "> ".
    expect(plan).toMatch(/must not make reset and retry an[\s>]+implicit behaviour/i);
    expect(plan).toMatch(/Do not drop large object sets/i);
  });
  test("★ the probe-v1 Stage 4 gap is named and closed for the canonical object", () => {
    expect(plan).toMatch(/not captured/i);
    // Backticked in the markdown: `ensure_rls` exists
    expect(plan).toMatch(/`?ensure_rls`? exists/);
    expect(plan).toMatch(/prosecdef/);
  });
  test("★ local rehearsal is explicitly not hosted proof", () => {
    expect(plan).toMatch(/not hosted proof/i);
    expect(plan).toMatch(/platform shim/i);
    expect(plan).toMatch(/PostgreSQL 17/);
  });
  test("equivalence reuses the canonical auditor rather than redefining it", () => {
    expect(plan).toMatch(/not a second, inconsistent definition of equivalence/i);
    expect(plan).toMatch(/bootstrapFreshRun/);
  });
});


/* ══════════════════════════════════════════════════════════════════════════════════════════════
 * 4B — the granted bootstrap authorization.
 *
 * ★ 921 STATEMENTS ON A REAL HOSTED DATABASE. The grant is pinned to one ref, one version and one
 *   cumulative manifest hash, and it deliberately carries NO recovery authorization: if a phase
 *   fails after mutation the environment is PARTIAL_BOOTSTRAP and the operator stops. Letting a
 *   bootstrap approval imply "and undo it if it goes wrong" would turn one decision into two, and
 *   the second one is destructive.
 * ══════════════════════════════════════════════════════════════════════════════════════════════ */

describe("4B · bootstrap grant", () => {
  const G = () => MODEL_C_BOOTSTRAP_AUTHORIZATION[0];
  const live = () => JSON.parse(readFileSync(join(ROOT, "docs/r02/environment-manifest.example.json"), "utf8"));
  const liveManifest = (over: Record<string, unknown> = {}) => {
    const l = live();
    return { environment: { name: TARGET.projectName, classification: "nonproduction" },
             supabase: { project_ref: TARGET.ref },
             safety: { ...l.safety, allowlisted_refs: [TARGET.ref], ...over },
             expected_model: l.expected_model };
  };

  test("★ 1/26 · POSITIVE CONTROL — exact target + version + manifest authorizes", () => {
    const r = classifyR02Target(liveManifest(), req());
    expect(r.reasons).toEqual([]);
    expect(r.decision).toBe(R02_DECISION.MUTATION_AUTHORIZED);
  });
  test("★ the grant is one entry pinned to the merged-main manifest hash", () => {
    expect(MODEL_C_BOOTSTRAP_AUTHORIZATION).toHaveLength(1);
    expect(G().ref).toBe(TARGET.ref);
    expect(G().bootstrapVersion).toBe("0060");
    expect(G().manifestSha256).toBe(MAN.cumulative_bootstrap_sha256);
    expect(G().executableStatements).toBe(921);
    expect(G().phaseCount).toBe(13);
    expect(G().grants).toEqual(["model_c_bootstrap_0060"]);
  });
  test("★ 21/22 · it authorizes NO recovery, reset, metadata write or deploy", () => {
    expect(G().recoveryAuthorized).toBe(false);
    expect(G().withholds).toContain("destructive_reset");
    expect(G().withholds).toContain("migration_metadata_write");
    expect(G().withholds).toContain("deploy");
    expect(G().partialFailurePolicy).toMatch(/PARTIAL_BOOTSTRAP/);
    const l = live();
    for (const f of ["destructive_reset_authorized", "migration_metadata_write_authorized",
                     "deployment_authorized", "bootstrap_authorized", "mutation_test_authorized"]) {
      expect(l.safety[f], f).toBe(false);
    }
  });
  test.each([
    ["2  wrong target", "zzzzzzzzzzzzzzzzzzzz"],
    ["5  malformed ref", "not-a-ref"],
    ["6  unknown ref", "aaaaaaaaaaaaaaaaaaaa"],
  ])("★ %s refuses even when self-allowlisted", (_l, ref) => {
    const m = liveManifest({ allowlisted_refs: [ref] });
    (m.supabase as Record<string, unknown>).project_ref = ref;
    expect(classifyR02Target(m, req()).decision).toBe(R02_DECISION.REFUSED);
  });
  test.each(PROTECTED)("★ 3/4/27 · %s refuses with EVERY flag true", (ref) => {
    const m = liveManifest({ allowlisted_refs: [ref] });
    (m.supabase as Record<string, unknown>).project_ref = ref;
    for (const f of Object.values(OPERATION_AUTHORIZATION_FLAG)) (m.safety as Record<string, unknown>)[f] = true;
    expect(classifyR02Target(m, req()).decision).toBe(R02_DECISION.REFUSED);
  });
  test.each([[undefined], [false], ["true"], [1], [null]])("★ 7/8/9 · authorization flag %s refuses", (flag) => {
    expect(classifyR02Target(liveManifest({ model_c_bootstrap_0060_authorized: flag as never }), req()).decision)
      .toBe(R02_DECISION.REFUSED);
  });
  test("★ 10 · wrong VERSION refuses", () => {
    expect(classifyR02Target(liveManifest(), req({ bootstrapVersion: "0061" })).reasons)
      .toContain(R02_REFUSAL.BOOTSTRAP_VERSION_MISMATCH);
  });
  test.each([["11 missing", ""], ["12 wrong", "f".repeat(64)], ["13 stale branch value", "0".repeat(64)]])
    ("★ %s manifest hash refuses", (_l, hash) => {
      expect(classifyR02Target(liveManifest(), req({ bootstrapManifestSha256: hash })).reasons)
        .toContain(R02_REFUSAL.BOOTSTRAP_MANIFEST_MISMATCH);
    });
  test.each([
    ["23 consumed probe grant", { mutation_test_authorized: true }],
    ["24 hosted-read grant", { hosted_sql_read_authorized: true }],
    ["25 generic bootstrap_authorized", { bootstrap_authorized: true }],
  ])("★ %s cannot authorize this operation", (_l, over) => {
    const m = liveManifest({ model_c_bootstrap_0060_authorized: false, ...over });
    expect(classifyR02Target(m, req()).decision).toBe(R02_DECISION.REFUSED);
  });
  test("★ 28/29/30 · MUTATION KILLS on the execution set, with the control alive", () => {
    // Control: the real set is authorized, so the refusals below are the mutations biting.
    expect(auditBootstrapExecution(MAN, exec(), sha).verdict).toBe(BOOTSTRAP_AUDIT.OK);
    const f = realFiles();
    const kills = [
      ["hash mutation", exec({ files: f.map((x, i) => i === 6 ? { ...x, sha256: "9".repeat(64) } : x) })],
      ["phase reorder", exec({ files: [...f.slice(0, 5), f[6], f[5], ...f.slice(7)] })],
      ["appended SQL", exec({ files: [...f, { file: "db/bootstrap/130_extra.sql", sha256: "8".repeat(64) }] })],
    ] as const;
    for (const [label, e] of kills) {
      expect(auditBootstrapExecution(MAN, e, sha).verdict, label).toBe(BOOTSTRAP_AUDIT.REFUSED);
    }
  });
  test("execution is manual and phase-by-phase — automation is not authorized", () => {
    expect(G().executedBy).toMatch(/manually/i);
    expect(G().executedBy).toMatch(/phase-by-phase/i);
    expect(G().executedBy).toMatch(/never by automation/i);
  });
  test("★ the grant's statement count matches the canonical files, not a remembered number", () => {
    const onDisk = MAN.phases.reduce((a: number, p: { statements: number }) => a + p.statements, 0);
    expect(G().executableStatements).toBe(onDisk);
    expect(onDisk).toBe(921);
  });
});
