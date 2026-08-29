/**
 * R-02 TARGET GUARD — the controls.
 *
 * ★ THE NEAR-MISS THIS FILE ENCODES. `supabase projects list` names one project "afterworth-prod"
 *   and another "afterworth-dev". The one named "dev" is what the deployed application connects to
 *   (README.md pins its URL for Vercel); the one named "prod" appears nowhere in the repository.
 *   Acting on the names, this session briefly "corrected" the seed guard's production pin to the
 *   name-only project — which would have removed protection from the database serving users. It was
 *   caught by an existing test that corroborated the ref against README and the proof docs.
 *
 *   So: every classification here is asserted with its EVIDENCE, and both refs are refused.
 */
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "vitest";
import {
  classifyR02Target, isRemoteMutationCommand,
  R02_DECISION, R02_OPERATIONS, R02_REFUSAL, FORBIDDEN_TARGETS, FORBIDDEN_REMOTE_COMMANDS, SECRET_KEY_PATTERN,
  MIGRATION_EXECUTION_MODEL, CANDIDATE_R02_TARGETS, LOCAL_ONLY_OPERATIONS, OPERATION_AUTHORIZATION_FLAG,
} from "../scripts/lib/r02TargetGuard.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");

/** A synthetic, clearly-not-real non-production identity. */
const SYNTHETIC_REF = "qqqqwwwweeeerrrrtttt";
const ok = (over: Record<string, unknown> = {}) => ({
  environment: { name: "afterworth-nonprod-synthetic", classification: "nonproduction" },
  supabase: { project_ref: SYNTHETIC_REF, region: "us-west-1" },
  safety: { production: false, allowlisted_refs: [SYNTHETIC_REF], bootstrap_authorized: false, destructive_reset_authorized: false },
  expected_model: { bootstrap_version: "0060", future_migration_start: "0061" },
  ...over,
});

describe("POSITIVE CONTROLS — the guard is not vacuous", () => {
  test("a synthetic, allowlisted, non-production identity is accepted for read-only preflight", () => {
    const r = classifyR02Target(ok(), { operation: R02_OPERATIONS.READ_ONLY_PREFLIGHT, bootstrapVersion: "0060" });
    expect(r.reasons).toEqual([]);
    expect(r.decision).toBe(R02_DECISION.READ_ONLY_AUTHORIZED);
    expect(r.guards.every((g) => g.pass)).toBe(true);
  });
  test("with explicit authorization, a bootstrap mutation is permitted on that same identity", () => {
    const m = ok(); (m.safety as Record<string, unknown>).bootstrap_authorized = true;
    const r = classifyR02Target(m, { operation: R02_OPERATIONS.BOOTSTRAP_APPLY, bootstrapVersion: "0060" });
    expect(r.decision).toBe(R02_DECISION.MUTATION_AUTHORIZED);
  });
  test("every guard id appears on every verdict, so none can silently vanish", () => {
    const good = classifyR02Target(ok(), { operation: R02_OPERATIONS.READ_ONLY_PREFLIGHT });
    const bad = classifyR02Target(ok({ supabase: { project_ref: "" } }), { operation: R02_OPERATIONS.READ_ONLY_PREFLIGHT });
    expect(new Set(bad.guards.map((g) => g.id))).toEqual(new Set(good.guards.map((g) => g.id)));
  });
});

describe("the two REAL projects are refused, by evidenced role and never by name", () => {
  test("★ the application-facing database is refused — and it is the one NAMED 'dev'", () => {
    const m = ok(); (m.supabase as Record<string, unknown>).project_ref = "yiaavvkulrpqkkbqhwit";
    (m.safety as Record<string, unknown>).allowlisted_refs = ["yiaavvkulrpqkkbqhwit"];   // even if allowlisted
    const r = classifyR02Target(m, { operation: R02_OPERATIONS.READ_ONLY_PREFLIGHT });
    expect(r.decision).toBe(R02_DECISION.REFUSED);
    expect(r.reasons).toContain(R02_REFUSAL.APPLICATION_FACING_TARGET);
    expect(FORBIDDEN_TARGETS.find((f) => f.ref === "yiaavvkulrpqkkbqhwit")!.protectedReason).toBe("APPLICATION_FACING_EXISTING_DATABASE");
  });
  test("★ the name-only 'prod' project is refused too — an unestablished role is not a licence", () => {
    const m = ok(); (m.supabase as Record<string, unknown>).project_ref = "rpjjwkoezuihpobotbjh";
    (m.safety as Record<string, unknown>).allowlisted_refs = ["rpjjwkoezuihpobotbjh"];
    const r = classifyR02Target(m, { operation: R02_OPERATIONS.READ_ONLY_PREFLIGHT });
    expect(r.decision).toBe(R02_DECISION.REFUSED);
    expect(r.reasons).toContain(R02_REFUSAL.ROLE_UNESTABLISHED_TARGET);
    expect(FORBIDDEN_TARGETS.find((f) => f.ref === "rpjjwkoezuihpobotbjh")!.protectedReason).toBe("EXISTING_PAUSED_FUTURE_PRODUCTION_CANDIDATE");
  });
  test("★ the application-facing classification is backed by README, not by the project's name", () => {
    const readme = readFileSync(join(ROOT, "README.md"), "utf8");
    const appFacing = FORBIDDEN_TARGETS.find((f) => f.protectedReason === "APPLICATION_FACING_EXISTING_DATABASE")!;
    expect(readme).toContain(`https://${appFacing.ref}.supabase.co`);
    expect(appFacing.supabaseName).toBe("afterworth-dev");   // the NAME says dev; the ROLE says otherwise
    expect(appFacing.evidence).toMatch(/README/);
  });
  test("★ the name-only project is genuinely absent from the repository", () => {
    const nameOnly = FORBIDDEN_TARGETS.find((f) => f.protectedReason === "EXISTING_PAUSED_FUTURE_PRODUCTION_CANDIDATE")!;
    const readme = readFileSync(join(ROOT, "README.md"), "utf8");
    expect(readme).not.toContain(nameOnly.ref);
    expect(nameOnly.supabaseName).toBe("afterworth-prod");
  });
  test("every forbidden target records evidence, not just a verdict", () => {
    for (const f of FORBIDDEN_TARGETS) {
      expect(f.evidence.length).toBeGreaterThan(60);
      expect(f.ref).toMatch(/^[a-z]{20}$/);
    }
  });
});

describe("fail-closed refusals", () => {
  test.each([
    ["absent manifest", undefined, R02_REFUSAL.MANIFEST_MISSING],
    ["null manifest", null, R02_REFUSAL.MANIFEST_MISSING],
    ["array manifest", [], R02_REFUSAL.MANIFEST_MISSING],
  ])("%s is refused", (_l, m, reason) => {
    const r = classifyR02Target(m as never, { operation: R02_OPERATIONS.READ_ONLY_PREFLIGHT });
    expect(r.decision).toBe(R02_DECISION.REFUSED);
    expect(r.reasons).toContain(reason);
  });

  test("★ an UNKNOWN well-formed ref is refused — allowlist, not denylist", () => {
    const m = ok({ safety: { production: false, allowlisted_refs: [], bootstrap_authorized: false, destructive_reset_authorized: false } });
    const r = classifyR02Target(m, { operation: R02_OPERATIONS.READ_ONLY_PREFLIGHT });
    expect(r.reasons).toContain(R02_REFUSAL.TARGET_NOT_ALLOWLISTED);
  });
  test("empty and malformed refs are refused", () => {
    expect(classifyR02Target(ok({ supabase: { project_ref: "" } }), { operation: R02_OPERATIONS.READ_ONLY_PREFLIGHT }).reasons).toContain(R02_REFUSAL.TARGET_MISSING);
    expect(classifyR02Target(ok({ supabase: { project_ref: "not-a-ref" } }), { operation: R02_OPERATIONS.READ_ONLY_PREFLIGHT }).reasons).toContain(R02_REFUSAL.TARGET_MALFORMED);
    expect(classifyR02Target(ok({ supabase: { project_ref: "TOOSHORT" } }), { operation: R02_OPERATIONS.READ_ONLY_PREFLIGHT }).reasons).toContain(R02_REFUSAL.TARGET_MALFORMED);
  });
  test("absent classification is refused — never inferred from absence", () => {
    expect(classifyR02Target(ok({ environment: { name: "x" } }), { operation: R02_OPERATIONS.READ_ONLY_PREFLIGHT }).reasons)
      .toContain(R02_REFUSAL.CLASSIFICATION_MISSING);
  });
  test("★ a production classification is refused, by either expression", () => {
    expect(classifyR02Target(ok({ environment: { name: "x", classification: "production" } }), { operation: R02_OPERATIONS.READ_ONLY_PREFLIGHT }).reasons)
      .toContain(R02_REFUSAL.CLASSIFICATION_PRODUCTION);
    const m = ok(); (m.safety as Record<string, unknown>).production = true;
    expect(classifyR02Target(m, { operation: R02_OPERATIONS.READ_ONLY_PREFLIGHT }).reasons).toContain(R02_REFUSAL.CLASSIFICATION_PRODUCTION);
  });
  test("an unrecognized classification is refused, not treated as non-production", () => {
    expect(classifyR02Target(ok({ environment: { name: "x", classification: "staging-ish" } }), { operation: R02_OPERATIONS.READ_ONLY_PREFLIGHT }).reasons)
      .toContain(R02_REFUSAL.CLASSIFICATION_UNRECOGNIZED);
  });
  test.each([["", R02_REFUSAL.OPERATION_MISSING], ["deploy_everything", R02_REFUSAL.OPERATION_UNRECOGNIZED]])
    ("operation %s is refused", (operation, reason) => {
      expect(classifyR02Target(ok(), { operation }).reasons).toContain(reason);
    });

  test("★ bootstrap mutation BEFORE authorization is refused", () => {
    const r = classifyR02Target(ok(), { operation: R02_OPERATIONS.BOOTSTRAP_APPLY });
    expect(r.decision).toBe(R02_DECISION.REFUSED);
    expect(r.reasons).toContain(R02_REFUSAL.MUTATION_NOT_AUTHORIZED);
  });
  test("★ destructive reset needs its OWN authorization — bootstrap authorization does not imply it", () => {
    const m = ok(); (m.safety as Record<string, unknown>).bootstrap_authorized = true;
    const r = classifyR02Target(m, { operation: R02_OPERATIONS.DESTRUCTIVE_RESET });
    expect(r.reasons).toContain(R02_REFUSAL.DESTRUCTIVE_NOT_AUTHORIZED);
  });
  test("a bootstrap-version mismatch is refused", () => {
    expect(classifyR02Target(ok(), { operation: R02_OPERATIONS.READ_ONLY_PREFLIGHT, bootstrapVersion: "0061" }).reasons)
      .toContain(R02_REFUSAL.BOOTSTRAP_VERSION_MISMATCH);
  });
  test("the manifest must agree with the repository's actual VERSION file", () => {
    const version = readFileSync(join(ROOT, "db/bootstrap/VERSION"), "utf8").trim();
    expect(classifyR02Target(ok(), { operation: R02_OPERATIONS.READ_ONLY_PREFLIGHT, bootstrapVersion: version }).decision)
      .toBe(R02_DECISION.READ_ONLY_AUTHORIZED);
  });
});

describe("secrets may never be serialized into a manifest", () => {
  test.each([
    ["db password", { supabase: { project_ref: SYNTHETIC_REF, db_password: "x" } }],
    ["service role key", { supabase: { project_ref: SYNTHETIC_REF, service_role_key: "x" } }],
    ["nested access token", { supabase: { project_ref: SYNTHETIC_REF, auth: { access_token: "x" } } }],
    ["connection string", { supabase: { project_ref: SYNTHETIC_REF, connection_string: "x" } }],
  ])("★ %s in the manifest is refused", (_l, supabase) => {
    const r = classifyR02Target(ok({ supabase }), { operation: R02_OPERATIONS.READ_ONLY_PREFLIGHT });
    expect(r.reasons).toContain(R02_REFUSAL.SECRET_IN_MANIFEST);
  });
  test("positive control: the detector recognises the key names it claims to", () => {
    for (const k of ["password", "service_role_key", "access_token", "api_key", "db_url", "dsn", "anon_key"]) {
      expect(SECRET_KEY_PATTERN.test(k)).toBe(true);
    }
    for (const k of ["project_ref", "region", "classification", "bootstrap_version"]) {
      expect(SECRET_KEY_PATTERN.test(k)).toBe(false);
    }
  });
});

describe("remote mutation command strings are statically refused", () => {
  test.each([
    "supabase db push", "supabase db reset --linked", "supabase migration up --linked",
    "supabase migration repair 0001 --status applied", "supabase projects create x",
    "CREATE EVENT TRIGGER ensure_rls ON ddl_command_end", "drop table public.estates",
    "INSERT INTO public.estates VALUES (1)", "TRUNCATE public.documents",
  ])("★ %s is refused", (cmd) => {
    expect(isRemoteMutationCommand(cmd)).toBe(true);
  });
  test.each([
    "supabase projects list", "supabase migration list --linked",
    "select current_user, version()", "SELECT count(*) FROM pg_event_trigger",
  ])("read-only %s is permitted", (cmd) => {
    expect(isRemoteMutationCommand(cmd)).toBe(false);
  });
  test("the forbidden list is non-empty and includes the irreversible ones", () => {
    expect(FORBIDDEN_REMOTE_COMMANDS.length).toBeGreaterThan(5);
    expect(FORBIDDEN_REMOTE_COMMANDS).toContain("db push");
    expect(FORBIDDEN_REMOTE_COMMANDS).toContain("migration repair");
  });
  test("empty input is not a mutation, and is not an approval either", () => {
    expect(isRemoteMutationCommand("")).toBe(false);
    expect(isRemoteMutationCommand(null as never)).toBe(false);
  });
});

describe("no escape hatch exists", () => {
  test("★ there is no force/override/bypass path in the guard source", () => {
    const src = readFileSync(join(ROOT, "scripts/lib/r02TargetGuard.mjs"), "utf8");
    const code = src.replace(/\/\*[\s\S]*?\*\//g, " ").replace(/^\s*\/\/.*$/gm, " ");
    for (const bad of ["process.env", "--force", "force:", "bypass", "override", "skipGuard"]) {
      expect(code).not.toContain(bad);
    }
  });
  test("positive control: the scanner CAN see such a token when present", () => {
    expect("if (opts.force) return APPROVED;").toContain("force");
  });
});


describe("PHASE E — the migration execution model is adjudicated, not assumed", () => {
  test("★ 15/16/17 · CLI workflow NOT adopted; repair and preseed NOT authorized", () => {
    expect(MIGRATION_EXECUTION_MODEL.supabase_cli_workflow_adopted).toBe(false);
    expect(MIGRATION_EXECUTION_MODEL.migration_repair_authorized).toBe(false);
    expect(MIGRATION_EXECUTION_MODEL.schema_migrations_preseed_authorized).toBe(false);
    expect(MIGRATION_EXECUTION_MODEL.current).toBe("MANUAL_MODEL_C_HOSTED_COMPATIBILITY");
  });
  test("★ 16 · `supabase migration up` is a refused remote command", () => {
    expect(isRemoteMutationCommand("supabase migration up --linked")).toBe(true);
    expect(isRemoteMutationCommand("supabase migration up --include-all --linked")).toBe(true);
  });
  test("★ 15 · `supabase migration repair` is a refused remote command", () => {
    expect(isRemoteMutationCommand("supabase migration repair 0060 --status applied --linked")).toBe(true);
  });
  test("★ 17 · any write to schema_migrations is refused", () => {
    for (const c of [
      "insert into supabase_migrations.schema_migrations (version) values ('0060')",
      "update supabase_migrations.schema_migrations set version = '0060'",
      "delete from supabase_migrations.schema_migrations",
    ]) expect(isRemoteMutationCommand(c)).toBe(true);
  });
  test("reading migration state stays permitted — the refusal is about writes", () => {
    expect(isRemoteMutationCommand("supabase migration list --linked")).toBe(false);
    expect(isRemoteMutationCommand("select version from supabase_migrations.schema_migrations")).toBe(false);
  });
  test("the schema contract is explicitly untouched by this tooling decision", () => {
    expect(MIGRATION_EXECUTION_MODEL.unchanged_schema_contract).toMatch(/bootstrap@0060.*0061/);
  });
  test("no supabase/migrations directory was created", () => {
    expect(existsSync(join(ROOT, "supabase"))).toBe(false);
    expect(existsSync(join(ROOT, "supabase/migrations"))).toBe(false);
  });
});

describe("★ 18 · a project's display name cannot override its ref classification", () => {
  test("the guard source contains no name-based branch", () => {
    const src = readFileSync(join(ROOT, "scripts/lib/r02TargetGuard.mjs"), "utf8");
    const code = src.replace(/\/\*[\s\S]*?\*\//g, " ").replace(/^\s*\/\/.*$/gm, " ");
    // `supabaseName` may be DEFINED as data, but must never be READ in a decision.
    expect(code).not.toMatch(/supabaseName\s*===/);
    expect(code).not.toMatch(/\.supabaseName\s*\)/);
    for (const nameToken of ["'prod'", '"prod"', "'dev'", '"dev"', "'staging'", '"staging"']) {
      expect(code).not.toContain(`=== ${nameToken}`);
      expect(code).not.toContain(`includes(${nameToken})`);
    }
  });
  test("★ renaming a project in Supabase cannot change the verdict — matching is on ref", () => {
    const m = ok();
    (m.supabase as Record<string, unknown>).project_ref = "yiaavvkulrpqkkbqhwit";
    (m.supabase as Record<string, unknown>).display_name = "totally-harmless-sandbox";
    (m.environment as Record<string, unknown>).name = "afterworth-nonprod";     // lies about itself
    (m.safety as Record<string, unknown>).allowlisted_refs = ["yiaavvkulrpqkkbqhwit"];
    const r = classifyR02Target(m, { operation: R02_OPERATIONS.READ_ONLY_PREFLIGHT });
    expect(r.decision).toBe(R02_DECISION.REFUSED);
    expect(r.reasons).toContain(R02_REFUSAL.APPLICATION_FACING_TARGET);
  });
  test("the recorded display names are the REAL ones, and they are misleading — that is the point", () => {
    const byRef = Object.fromEntries(FORBIDDEN_TARGETS.map((f) => [f.ref, f]));
    expect(byRef["yiaavvkulrpqkkbqhwit"].supabaseName).toBe("afterworth-dev");    // named dev, IS the app db
    expect(byRef["rpjjwkoezuihpobotbjh"].supabaseName).toBe("afterworth-prod");   // named prod, role unknown
  });
  test("NAME_BASED_CLASSIFICATION_FORBIDDEN is declared", async () => {
    const mod = await import("../scripts/lib/r02TargetGuard.mjs");
    expect(mod.NAME_BASED_CLASSIFICATION_FORBIDDEN).toBe(true);
  });
});

describe("PHASE G — the hosted query pack is SELECT-only, with all seven verbs controlled", () => {
  const pack = readFileSync(join(ROOT, "docs/r02/hosted-capability-queries.sql"), "utf8");

  test("the pack exists and is non-trivial", () => {
    expect(pack.length).toBeGreaterThan(1000);
    expect((pack.match(/^select/gim) ?? []).length).toBeGreaterThan(5);
  });
  test("★ every executable statement is a SELECT", async () => {
    const { splitStatements, stripComments, maskLiterals } = await import("../scripts/lib/schemaInventory.mjs");
    const stmts = splitStatements(pack).map((x: string) => maskLiterals(stripComments(x)).trim()).filter(Boolean);
    expect(stmts.length).toBeGreaterThan(5);
    expect(stmts.filter((x: string) => !/^select/i.test(x))).toEqual([]);
    expect(stmts.filter((x: string) => isRemoteMutationCommand(x))).toEqual([]);
  });
  test.each([
    ["CREATE", "create table public.x (id uuid)"],
    ["ALTER", "alter table public.x add column y text"],
    ["DROP", "drop table public.x"],
    ["INSERT", "insert into public.x values (1)"],
    ["UPDATE", "update public.x set y = 1"],
    ["DELETE", "delete from public.x"],
    ["TRUNCATE", "truncate public.x"],
  ])("★ positive control — a real %s is detected", (_verb, sql) => {
    expect(isRemoteMutationCommand(sql)).toBe(true);
  });
  test("★ and none of those seven verbs appears as executable text in the pack", async () => {
    const { splitStatements, stripComments, maskLiterals } = await import("../scripts/lib/schemaInventory.mjs");
    const code = splitStatements(pack).map((x: string) => maskLiterals(stripComments(x)).trim()).join("\n");
    for (const verb of ["create", "alter", "drop", "insert", "update", "delete", "truncate"]) {
      expect(new RegExp(`(^|\\n)\\s*${verb}\\b`, "i").test(code)).toBe(false);
    }
  });
  test("the pack warns against running it on the application-facing project", () => {
    expect(pack).toMatch(/DO NOT RUN AGAINST yiaavvkulrpqkkbqhwit/i);
  });
});


describe("paused is not disposable — the retention decision is explicit and testable", () => {
  test("★ a PAUSED project is still refused for every R-02 operation", async () => {
    const { EXISTING_PROJECT_DISPOSITION } = await import("../scripts/lib/r02TargetGuard.mjs");
    for (const op of Object.values(R02_OPERATIONS)) {
      const m = ok();
      (m.supabase as Record<string, unknown>).project_ref = "rpjjwkoezuihpobotbjh";
      (m.safety as Record<string, unknown>).allowlisted_refs = ["rpjjwkoezuihpobotbjh"];
      (m.safety as Record<string, unknown>).bootstrap_authorized = true;
      (m.safety as Record<string, unknown>).destructive_reset_authorized = true;
      const r = classifyR02Target(m, { operation: op, bootstrapVersion: "0060" });
      expect(r.decision).toBe(R02_DECISION.REFUSED);          // even fully "authorized"
      expect(r.reasons).toContain(R02_REFUSAL.ROLE_UNESTABLISHED_TARGET);
    }
    expect(EXISTING_PROJECT_DISPOSITION.rpjjwkoezuihpobotbjh.r02_target).toBe(false);
  });
  test("★ neither existing project is deletable by any R-02 workflow", async () => {
    const { EXISTING_PROJECT_DISPOSITION } = await import("../scripts/lib/r02TargetGuard.mjs");
    for (const ref of ["yiaavvkulrpqkkbqhwit", "rpjjwkoezuihpobotbjh"]) {
      expect(EXISTING_PROJECT_DISPOSITION[ref].retained).toBe(true);
      expect(EXISTING_PROJECT_DISPOSITION[ref].deletable).toBe(false);
    }
    // The module names "projects delete" only to REFUSE it. The property under test is that no
    // code path can execute anything at all, so assert the absence of execution primitives —
    // matching the literal string caught the refusal list and asserted the opposite of the intent.
    const src = readFileSync(join(ROOT, "scripts/lib/r02TargetGuard.mjs"), "utf8");
    const code = src.replace(/\/\*[\s\S]*?\*\//g, " ").replace(/^\s*\/\/.*$/gm, " ");
    // Precise: bare "exec" matches RegExp.prototype.exec, which this module uses legitimately.
    for (const primitive of ["child_process", "spawnSync", "spawn(", "execSync", "execFile", "fetch(", "require(", "node:http", "node:fs"]) {
      expect(code, `${primitive} must not appear`).not.toContain(primitive);
    }
    expect(isRemoteMutationCommand("supabase projects delete rpjjwkoezuihpobotbjh")).toBe(true);
  });
  test("the paused status is recorded as OBSERVED from the control plane, not merely reported", () => {
    const paused = FORBIDDEN_TARGETS.find((f) => f.ref === "rpjjwkoezuihpobotbjh")!;
    expect(paused.observedStatus).toBe("INACTIVE");
    expect(paused.evidence).toMatch(/INACTIVE/);
  });
  test("★ positive control: the execution-primitive scanner CAN see one when present", () => {
    const sample = 'import { spawnSync } from "node:child_process";';
    expect(sample).toContain("spawnSync");
    expect(sample).toContain("child_process");
    // ...and the precise patterns do NOT fire on a legitimate regex call, which is why they are precise.
    expect("REF.exec(ref)").not.toContain("execSync");
  });
  test("every disposition entry is explicitly non-target — none defaults to permissive", async () => {
    const { EXISTING_PROJECT_DISPOSITION } = await import("../scripts/lib/r02TargetGuard.mjs");
    const entries = Object.entries(EXISTING_PROJECT_DISPOSITION);
    expect(entries.length).toBe(2);
    for (const [, v] of entries) expect(v.r02_target).toBe(false);
  });
});


/* ══════════════════════════════════════════════════════════════════════════════════════════════
 * PHASE 1D — the registered real non-production target.
 *
 * ★ REGISTERED IS NOT AUTHORIZED. `afterworth-nonprod` exists and is named here, and every hosted
 *   operation against it is still refused. The only thing it may do is local planning.
 * ══════════════════════════════════════════════════════════════════════════════════════════════ */

const TARGET = CANDIDATE_R02_TARGETS[0];
const PROTECTED_REFS = ["yiaavvkulrpqkkbqhwit", "rpjjwkoezuihpobotbjh"];
const HOSTED_OPS = Object.keys(OPERATION_AUTHORIZATION_FLAG);

/** A manifest for the real target with every hosted authorization false. */
const candidateManifest = (over: Record<string, unknown> = {}) => ({
  environment: { name: TARGET.projectName, classification: "nonproduction" },
  supabase: { project_ref: TARGET.ref, region: TARGET.region, organization_id: TARGET.organization },
  safety: {
    production: false,
    allowlisted_refs: [TARGET.ref],
    hosted_sql_read_authorized: false,
    bootstrap_authorized: false,
    destructive_reset_authorized: false,
    migration_metadata_write_authorized: false,
    deployment_authorized: false,
  },
  expected_model: { bootstrap_version: "0060", future_migration_start: "0061" },
  ...over,
});

describe("1D · the registered target", () => {
  test("★ 5 · the exact discovered ref is registered as CANDIDATE_R02_NONPROD", () => {
    expect(CANDIDATE_R02_TARGETS).toHaveLength(1);
    expect(TARGET.ref).toBe("qxzeougbaarecaiiqsay");
    expect(TARGET.ref).toMatch(/^[a-z]{20}$/);
    expect(TARGET.projectName).toBe("afterworth-nonprod");
    expect(TARGET.organization).toBe("rvudommjwqgtluhvfgcw");
    expect(TARGET.region).toBe("us-west-2");
    expect(TARGET.classification).toBe("CANDIDATE_R02_NONPROD");
    expect(TARGET.creationMethod).toBe("USER_SUPABASE_DASHBOARD");
  });
  test("★ 5b · the registered ref is not either protected ref", () => {
    expect(PROTECTED_REFS).not.toContain(TARGET.ref);
    for (const f of FORBIDDEN_TARGETS) expect(f.ref).not.toBe(TARGET.ref);
  });
  test("★ 6 · it MAY enter READ_ONLY_PLANNING", () => {
    const r = classifyR02Target(candidateManifest(), { operation: R02_OPERATIONS.READ_ONLY_PLANNING, bootstrapVersion: "0060" });
    expect(r.reasons).toEqual([]);
    expect(r.decision).toBe(R02_DECISION.READ_ONLY_AUTHORIZED);
  });
  test.each([
    ["7  hosted SQL read", "hosted_sql_read", R02_REFUSAL.HOSTED_SQL_READ_NOT_AUTHORIZED],
    ["8  bootstrap", "bootstrap_apply", R02_REFUSAL.MUTATION_NOT_AUTHORIZED],
    ["9  destructive reset", "destructive_reset", R02_REFUSAL.DESTRUCTIVE_NOT_AUTHORIZED],
    ["10 migration metadata write", "migration_metadata_write", R02_REFUSAL.MIGRATION_METADATA_WRITE_NOT_AUTHORIZED],
    ["11 deploy", "deploy", R02_REFUSAL.DEPLOY_NOT_AUTHORIZED],
  ])("★ %s is REFUSED for the registered target", (_l, operation, reason) => {
    const r = classifyR02Target(candidateManifest(), { operation, bootstrapVersion: "0060" });
    expect(r.decision).toBe(R02_DECISION.REFUSED);
    expect(r.reasons).toContain(reason);
  });
  test("★ authorizing ONE hosted operation does not authorize the others", () => {
    const m = candidateManifest();
    (m.safety as Record<string, unknown>).bootstrap_authorized = true;
    expect(classifyR02Target(m, { operation: "bootstrap_apply", bootstrapVersion: "0060" }).decision).toBe(R02_DECISION.MUTATION_AUTHORIZED);
    for (const op of HOSTED_OPS.filter((o) => o !== "bootstrap_apply")) {
      expect(classifyR02Target(m, { operation: op, bootstrapVersion: "0060" }).decision, op).toBe(R02_DECISION.REFUSED);
    }
  });
  test("every hosted operation has its own distinct flag — no shared mutation flag", () => {
    const flags = Object.values(OPERATION_AUTHORIZATION_FLAG);
    expect(new Set(flags).size).toBe(flags.length);
    expect(flags).toHaveLength(5);
    expect(LOCAL_ONLY_OPERATIONS).not.toContain("hosted_sql_read");
  });
  test("★ 15 · removing the ref from the allowlist refuses it", () => {
    const m = candidateManifest();
    (m.safety as Record<string, unknown>).allowlisted_refs = [];
    expect(classifyR02Target(m, { operation: R02_OPERATIONS.READ_ONLY_PLANNING }).reasons).toContain(R02_REFUSAL.TARGET_NOT_ALLOWLISTED);
  });
  test("★ 12 · a display-name change does not affect authorization", () => {
    const m = candidateManifest({ environment: { name: "something-else-entirely", classification: "nonproduction" } });
    (m.supabase as Record<string, unknown>).display_name = "afterworth-prod";
    expect(classifyR02Target(m, { operation: R02_OPERATIONS.READ_ONLY_PLANNING, bootstrapVersion: "0060" }).decision)
      .toBe(R02_DECISION.READ_ONLY_AUTHORIZED);
  });
  test("★ 16 · an unknown classification fails closed", () => {
    const m = candidateManifest({ environment: { name: TARGET.projectName, classification: "sandbox" } });
    expect(classifyR02Target(m, { operation: R02_OPERATIONS.READ_ONLY_PLANNING }).reasons).toContain(R02_REFUSAL.CLASSIFICATION_UNRECOGNIZED);
  });
  test("★ 17 · missing authorization fields fail closed — absent is not true", () => {
    const m = candidateManifest();
    delete (m.safety as Record<string, unknown>).bootstrap_authorized;
    expect(classifyR02Target(m, { operation: "bootstrap_apply" }).reasons).toContain(R02_REFUSAL.MUTATION_NOT_AUTHORIZED);
    const m2 = candidateManifest({ safety: { production: false, allowlisted_refs: [TARGET.ref] } });
    for (const op of HOSTED_OPS) expect(classifyR02Target(m2, { operation: op }).decision, op).toBe(R02_DECISION.REFUSED);
  });
  test("a truthy-but-not-true flag is refused", () => {
    const m = candidateManifest();
    (m.safety as Record<string, unknown>).bootstrap_authorized = "yes";
    expect(classifyR02Target(m, { operation: "bootstrap_apply" }).decision).toBe(R02_DECISION.REFUSED);
  });
});

describe("1D · PHASE F — protection OUTRANKS every authorization", () => {
  test.each(PROTECTED_REFS)("★ 13/14 · %s in the candidate slot is refused for EVERY operation", (ref) => {
    // Maximally permissive manifest: allowlisted, non-production, every flag true, correct version.
    const m = candidateManifest();
    (m.supabase as Record<string, unknown>).project_ref = ref;
    (m.safety as Record<string, unknown>).allowlisted_refs = [ref];
    for (const f of Object.values(OPERATION_AUTHORIZATION_FLAG)) (m.safety as Record<string, unknown>)[f] = true;
    for (const op of Object.values(R02_OPERATIONS)) {
      const r = classifyR02Target(m, { operation: op, bootstrapVersion: "0060" });
      expect(r.decision, `${ref} / ${op}`).toBe(R02_DECISION.REFUSED);
    }
  });
  test("★ a protected ref can never be added to the candidate registry", () => {
    for (const t of CANDIDATE_R02_TARGETS) expect(PROTECTED_REFS).not.toContain(t.ref);
  });
  test("★ 1/2 · both protected refs keep their classifications after registration", () => {
    const byRef = Object.fromEntries(FORBIDDEN_TARGETS.map((f) => [f.ref, f]));
    expect(byRef["yiaavvkulrpqkkbqhwit"].protectedReason).toBe("APPLICATION_FACING_EXISTING_DATABASE");
    expect(byRef["rpjjwkoezuihpobotbjh"].protectedReason).toBe("EXISTING_PAUSED_FUTURE_PRODUCTION_CANDIDATE");
    expect(FORBIDDEN_TARGETS).toHaveLength(2);
  });
  test("★ 3/4 · an unallowlisted or malformed ref is still refused after registration", () => {
    const m1 = candidateManifest();
    (m1.supabase as Record<string, unknown>).project_ref = "abcdefghijklmnopqrst";
    expect(classifyR02Target(m1, { operation: R02_OPERATIONS.READ_ONLY_PLANNING }).reasons).toContain(R02_REFUSAL.TARGET_NOT_ALLOWLISTED);
    const m2 = candidateManifest();
    (m2.supabase as Record<string, unknown>).project_ref = "not-a-ref";
    (m2.safety as Record<string, unknown>).allowlisted_refs = ["not-a-ref"];
    expect(classifyR02Target(m2, { operation: R02_OPERATIONS.READ_ONLY_PLANNING }).reasons).toContain(R02_REFUSAL.TARGET_MALFORMED);
  });
  test("★ MUTATION CONTROL: if R4 were removed, the protected refs WOULD pass — proving R4 is load-bearing", () => {
    // Same maximally-permissive manifest, but with a ref that is merely unknown rather than
    // protected. It is authorized — so the ONLY thing refusing the protected refs above is R4.
    const m = candidateManifest();
    (m.supabase as Record<string, unknown>).project_ref = "mmmmnnnnooooppppqqqq";
    (m.safety as Record<string, unknown>).allowlisted_refs = ["mmmmnnnnooooppppqqqq"];
    for (const f of Object.values(OPERATION_AUTHORIZATION_FLAG)) (m.safety as Record<string, unknown>)[f] = true;
    expect(classifyR02Target(m, { operation: "bootstrap_apply", bootstrapVersion: "0060" }).decision).toBe(R02_DECISION.MUTATION_AUTHORIZED);
  });
});

describe("1D · PHASE I — the query pack remains locked and unexecuted", () => {
  test("★ hosted_sql_read remains unauthorized in the manifest template", () => {
    const tpl = JSON.parse(readFileSync(join(ROOT, "docs/r02/environment-manifest.example.json"), "utf8"));
    expect(tpl.safety.bootstrap_authorized).toBe(false);
    expect(tpl.safety.destructive_reset_authorized).toBe(false);
  });
  test("★ the pack is still SELECT-only after registration", async () => {
    const { splitStatements, stripComments, maskLiterals } = await import("../scripts/lib/schemaInventory.mjs");
    const pack = readFileSync(join(ROOT, "docs/r02/hosted-capability-queries.sql"), "utf8");
    const stmts = splitStatements(pack).map((x: string) => maskLiterals(stripComments(x)).trim()).filter(Boolean);
    expect(stmts.length).toBeGreaterThan(5);
    expect(stmts.filter((x: string) => !/^select/i.test(x))).toEqual([]);
  });
});


describe("2A · the read-only identity check pack", () => {
  const pack = readFileSync(join(ROOT, "docs/r02/identity-check.sql"), "utf8");
  const parse = async () => {
    const { splitStatements, stripComments, maskLiterals } = await import("../scripts/lib/schemaInventory.mjs");
    return splitStatements(pack).map((x: string) => maskLiterals(stripComments(x)).trim()).filter(Boolean);
  };

  test("★ it is SELECT-only, and the scan set is non-empty", async () => {
    const stmts = await parse();
    expect(stmts.length).toBeGreaterThan(0);
    expect(stmts.filter((x: string) => !/^select/i.test(x))).toEqual([]);
    expect(stmts.filter((x: string) => isRemoteMutationCommand(x))).toEqual([]);
  });

  test.each(["CREATE", "ALTER", "DROP", "INSERT", "UPDATE", "DELETE", "TRUNCATE", "MERGE", "CALL", "COPY", "GRANT", "REVOKE"])
    ("★ no executable %s appears in the pack", async (verb) => {
      const code = (await parse()).join("\n");
      expect(new RegExp(`(^|\\n)\\s*${verb}\\b`, "i").test(code)).toBe(false);
    });

  test("★ every function called is a PostgreSQL built-in — no application function may run", async () => {
    // A SECURITY DEFINER application function could have side effects; only built-ins are permitted
    // in an identity check, and the allowlist is explicit rather than assumed.
    const BUILTINS = new Set(["current_database", "current_user", "session_user", "version",
      "current_setting", "pg_postmaster_start_time", "pg_backend_pid", "inet_server_addr",
      "inet_server_port", "now"]);
    const KEYWORDS = new Set(["select", "from", "where", "order", "and", "or", "not", "like", "as", "on", "in"]);
    const called = new Set<string>();
    for (const stmt of await parse()) {
      for (const m of stmt.matchAll(/([a-z_][a-z_0-9]*)\s*\(/gi)) {
        const fn = m[1].toLowerCase();
        if (!KEYWORDS.has(fn)) called.add(fn);
      }
    }
    expect(called.size).toBeGreaterThan(3);
    expect([...called].filter((f) => !BUILTINS.has(f))).toEqual([]);
  });

  test("★ positive control: the built-in allowlist WOULD reject an application function", () => {
    const BUILTINS = new Set(["current_database", "now"]);
    const sample = "select public.is_estate_owner(null), now();";
    const called = [...sample.matchAll(/([a-z_][a-z_0-9]*)\s*\(/gi)].map((m) => m[1].toLowerCase());
    expect(called).toContain("is_estate_owner");
    expect(called.filter((f) => !BUILTINS.has(f))).toEqual(["is_estate_owner"]);
  });

  test("★ it names the registered target and warns off both protected projects", () => {
    expect(pack).toContain(TARGET.ref);
    expect(pack).toMatch(/NEVER RUN THIS AGAINST yiaavvkulrpqkkbqhwit/i);
    expect(pack).toContain("rpjjwkoezuihpobotbjh");
  });

  test("★ it states the limit of what it can prove — current_database cannot identify the project", () => {
    // Asserted as independent claims: the text is wrapped across comment lines, and reflowing prose
    // to satisfy a regex is the wrong direction — the assertion should match the meaning.
    expect(pack).toMatch(/CANNOT/);
    expect(pack).toMatch(/current_database\(\)/);
    expect(pack).toMatch(/EVERY Supabase project/i);
    expect(pack).toMatch(/distinguishes nothing/i);
    expect(pack).toMatch(/SQL Editor of that\s*--\s*specific project|opened the SQL Editor/i);
  });

  test("no capability adjudication leaks into the identity check", () => {
    const code = pack.replace(/--.*$/gm, "");
    for (const capability of ["rolsuper", "rolbypassrls", "pg_event_trigger", "pg_available_extensions", "pg_extension"]) {
      expect(code).not.toContain(capability);
    }
  });

  test("★ preparing a pack does not authorize running it — authorization is a separate explicit act", () => {
    // R-02 Phase 2B subsequently granted hosted_sql_read for the registered ref, so the TEMPLATE now
    // carries true. The property under test was never "the template says false" — it is that a
    // manifest WITHOUT the grant cannot run hosted SQL. Re-anchored on that, so the test keeps
    // meaning something after a deliberate authorization rather than merely recording a past state.
    const r = classifyR02Target(candidateManifest(), { operation: R02_OPERATIONS.HOSTED_SQL_READ, bootstrapVersion: "0060" });
    expect(r.decision).toBe(R02_DECISION.REFUSED);
    expect(r.reasons).toContain(R02_REFUSAL.HOSTED_SQL_READ_NOT_AUTHORIZED);
  });
  test("the granted authorization is narrow, explicit and recorded in source", async () => {
    const { HOSTED_READ_AUTHORIZATION } = await import("../scripts/lib/r02TargetGuard.mjs");
    const tpl = JSON.parse(readFileSync(join(ROOT, "docs/r02/environment-manifest.example.json"), "utf8"));
    expect(tpl.safety.hosted_sql_read_authorized).toBe(true);       // deliberate, Phase 2B
    for (const f of ["bootstrap_authorized", "destructive_reset_authorized",
                     "migration_metadata_write_authorized", "deployment_authorized"]) {
      expect(tpl.safety[f], f).toBe(false);                          // and nothing else moved
    }
    expect(HOSTED_READ_AUTHORIZATION).toHaveLength(1);
    expect(HOSTED_READ_AUTHORIZATION[0].grants).toEqual(["hosted_sql_read"]);
  });
});


describe("2B · hosted read authorization — exact-ref scoped, one operation only", () => {
  const authorized = () => {
    const m = candidateManifest();
    (m.safety as Record<string, unknown>).hosted_sql_read_authorized = true;
    return m;
  };

  test("★ 1 · the exact nonprod ref MAY hosted_sql_read when explicitly authorized", async () => {
    const { HOSTED_READ_AUTHORIZATION } = await import("../scripts/lib/r02TargetGuard.mjs");
    const r = classifyR02Target(authorized(), { operation: R02_OPERATIONS.HOSTED_SQL_READ, bootstrapVersion: "0060" });
    expect(r.reasons).toEqual([]);
    expect(r.decision).toBe(R02_DECISION.HOSTED_READ_AUTHORIZED);
    expect(HOSTED_READ_AUTHORIZATION[0].ref).toBe(TARGET.ref);
    expect(HOSTED_READ_AUTHORIZATION[0].grants).toEqual(["hosted_sql_read"]);
  });
  test("★ an authorized READ is not reported as a mutation", () => {
    const r = classifyR02Target(authorized(), { operation: R02_OPERATIONS.HOSTED_SQL_READ, bootstrapVersion: "0060" });
    expect(r.decision).not.toBe(R02_DECISION.MUTATION_AUTHORIZED);
  });
  test.each([
    ["2 bootstrap", "bootstrap_apply"],
    ["3 reset", "destructive_reset"],
    ["4 migration metadata write", "migration_metadata_write"],
    ["5 deploy", "deploy"],
  ])("★ %s is STILL refused after the read grant", (_l, operation) => {
    expect(classifyR02Target(authorized(), { operation, bootstrapVersion: "0060" }).decision).toBe(R02_DECISION.REFUSED);
  });
  test("the grant record withholds every other operation explicitly", async () => {
    const { HOSTED_READ_AUTHORIZATION } = await import("../scripts/lib/r02TargetGuard.mjs");
    const g = HOSTED_READ_AUTHORIZATION[0];
    expect(g.withholds).toEqual(["bootstrap_apply", "destructive_reset", "migration_metadata_write", "deploy"]);
    expect(g.grants).not.toContain("bootstrap_apply");
  });

  test.each(PROTECTED_REFS)("★ 6/7 · %s cannot hosted_sql_read even with the flag true", (ref) => {
    const m = authorized();
    (m.supabase as Record<string, unknown>).project_ref = ref;
    (m.safety as Record<string, unknown>).allowlisted_refs = [ref];
    expect(classifyR02Target(m, { operation: R02_OPERATIONS.HOSTED_SQL_READ, bootstrapVersion: "0060" }).decision)
      .toBe(R02_DECISION.REFUSED);
  });
  test("★ a protected ref in the authorization list would still be refused — R4 outranks the grant", async () => {
    const { HOSTED_READ_AUTHORIZATION } = await import("../scripts/lib/r02TargetGuard.mjs");
    for (const g of HOSTED_READ_AUTHORIZATION) expect(PROTECTED_REFS).not.toContain(g.ref);
    // and prove ordering: even a hypothetical grant cannot help, because R4 fires first
    const m = authorized();
    (m.supabase as Record<string, unknown>).project_ref = PROTECTED_REFS[0];
    (m.safety as Record<string, unknown>).allowlisted_refs = [PROTECTED_REFS[0]];
    expect(classifyR02Target(m, { operation: R02_OPERATIONS.HOSTED_SQL_READ }).reasons)
      .toContain(R02_REFUSAL.APPLICATION_FACING_TARGET);
  });
  test("★ 8/9 · unallowlisted and malformed refs are refused for hosted read", () => {
    const m1 = authorized(); (m1.safety as Record<string, unknown>).allowlisted_refs = [];
    expect(classifyR02Target(m1, { operation: R02_OPERATIONS.HOSTED_SQL_READ }).reasons).toContain(R02_REFUSAL.TARGET_NOT_ALLOWLISTED);
    const m2 = authorized(); (m2.supabase as Record<string, unknown>).project_ref = "bad";
    (m2.safety as Record<string, unknown>).allowlisted_refs = ["bad"];
    expect(classifyR02Target(m2, { operation: R02_OPERATIONS.HOSTED_SQL_READ }).reasons).toContain(R02_REFUSAL.TARGET_MALFORMED);
  });
  test("★ 10 · a display name cannot grant hosted read", () => {
    const m = candidateManifest({ environment: { name: "afterworth-nonprod-totally-safe", classification: "nonproduction" } });
    expect(classifyR02Target(m, { operation: R02_OPERATIONS.HOSTED_SQL_READ }).decision).toBe(R02_DECISION.REFUSED);
  });
  test.each([[false], [undefined], ["true"], [1], [null]])("★ 11 · hosted read flag %s is refused", (flag) => {
    const m = candidateManifest();
    (m.safety as Record<string, unknown>).hosted_sql_read_authorized = flag as never;
    expect(classifyR02Target(m, { operation: R02_OPERATIONS.HOSTED_SQL_READ }).decision).toBe(R02_DECISION.REFUSED);
  });
});

describe("2B · the capability pack is SELECT-only", () => {
  const pack = readFileSync(join(ROOT, "docs/r02/capability-check.sql"), "utf8");
  const parse = async () => {
    const { splitStatements, stripComments, maskLiterals } = await import("../scripts/lib/schemaInventory.mjs");
    return splitStatements(pack).map((x: string) => maskLiterals(stripComments(x)).trim()).filter(Boolean);
  };

  test("★ 12 · every statement is a SELECT and the scan set is non-empty", async () => {
    const stmts = await parse();
    expect(stmts.length).toBe(8);
    expect(stmts.filter((x: string) => !/^select/i.test(x))).toEqual([]);
    expect(stmts.filter((x: string) => isRemoteMutationCommand(x))).toEqual([]);
  });
  test.each(["CREATE", "ALTER", "DROP", "INSERT", "UPDATE", "DELETE", "TRUNCATE", "MERGE", "CALL", "COPY", "GRANT", "REVOKE"])
    ("★ 13 · no executable %s", async (verb) => {
      expect(new RegExp(`(^|\\n)\\s*${verb}\\b`, "i").test((await parse()).join("\n"))).toBe(false);
    });
  test("★ 14 · every function is a read-only built-in — no application function may be invoked", async () => {
    const BUILTINS = new Set(["count", "coalesce", "string_agg", "array", "exists", "current_user", "session_user",
      "to_regclass", "to_regprocedure", "to_regnamespace", "pg_get_userbyid"]);
    const KEYWORDS = new Set(["select", "from", "where", "order", "and", "or", "not", "like", "as", "on", "in",
      "join", "left", "case", "when", "then", "else", "end", "by", "group", "is"]);
    const called = new Set<string>();
    for (const s of await parse()) for (const m of s.matchAll(/([a-z_][a-z_0-9]*)\s*\(/gi)) {
      const fn = m[1].toLowerCase();
      if (!KEYWORDS.has(fn)) called.add(fn);
    }
    expect(called.size).toBeGreaterThan(4);
    expect([...called].filter((f) => !BUILTINS.has(f))).toEqual([]);
  });
  test("★ 14b · positive control — a SECURITY DEFINER RPC would be rejected by that allowlist", () => {
    const BUILTINS = new Set(["count"]);
    const called = [...("select public.authorize_release(1), count(*);").matchAll(/([a-z_][a-z_0-9]*)\s*\(/gi)].map((m) => m[1].toLowerCase());
    expect(called).toContain("authorize_release");
    expect(called.filter((f) => !BUILTINS.has(f))).toEqual(["authorize_release"]);
  });
  test("★ 15 · an empty pack is refused, never 'clean'", async () => {
    const { splitStatements } = await import("../scripts/lib/schemaInventory.mjs");
    expect(splitStatements("").filter(Boolean)).toEqual([]);
    expect(splitStatements("-- only a comment\n").map((x: string) => x.trim()).filter((x: string) => x && !x.startsWith("--"))).toEqual([]);
  });
  test("★ 16 · virginity is AfterWorth-specific, not 'public must be empty'", () => {
    expect(pack).toMatch(/afterworth_tables_present/);
    expect(pack).toMatch(/A FRESH SUPABASE PROJECT IS NOT AN EMPTY POSTGRES SERVER/i);
    expect(pack).toContain("'estates'");
    expect(pack).toContain("'documents'");
  });
  test("★ event triggers are separated into platform vs application", () => {
    expect(pack).toMatch(/owner_class/);
    expect(pack).toMatch(/PLATFORM/);
    expect(pack).toMatch(/ensure_rls_binding/);
    expect(pack).toMatch(/rls_auto_enable_function/);
  });
  test("it names the target and forbids both protected projects", () => {
    expect(pack).toContain(TARGET.ref);
    expect(pack).toMatch(/NEVER RUN AGAINST yiaavvkulrpqkkbqhwit/i);
    expect(pack).toContain("rpjjwkoezuihpobotbjh");
  });
  test("no CREATE EXTENSION or CREATE EVENT TRIGGER is attempted", () => {
    const code = pack.replace(/--.*$/gm, "");
    expect(code).not.toMatch(/create\s+extension/i);
    expect(code).not.toMatch(/create\s+event\s+trigger/i);
  });
});
