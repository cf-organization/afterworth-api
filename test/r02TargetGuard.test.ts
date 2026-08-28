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
  MIGRATION_EXECUTION_MODEL,
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
    expect(FORBIDDEN_TARGETS.find((f) => f.ref === "rpjjwkoezuihpobotbjh")!.protectedReason).toBe("EXISTING_PROJECT_ROLE_UNESTABLISHED");
  });
  test("★ the application-facing classification is backed by README, not by the project's name", () => {
    const readme = readFileSync(join(ROOT, "README.md"), "utf8");
    const appFacing = FORBIDDEN_TARGETS.find((f) => f.protectedReason === "APPLICATION_FACING_EXISTING_DATABASE")!;
    expect(readme).toContain(`https://${appFacing.ref}.supabase.co`);
    expect(appFacing.supabaseName).toBe("afterworth-dev");   // the NAME says dev; the ROLE says otherwise
    expect(appFacing.evidence).toMatch(/README/);
  });
  test("★ the name-only project is genuinely absent from the repository", () => {
    const nameOnly = FORBIDDEN_TARGETS.find((f) => f.protectedReason === "EXISTING_PROJECT_ROLE_UNESTABLISHED")!;
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
