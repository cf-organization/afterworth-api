/**
 * UPLOAD-POLICY SEED — the static half.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ THE DEFECT. `db/bootstrap` creates `public.upload_policy`, its primary key, RLS and the grants on
 *   `get_upload_policy()` — and never INSERTS the `id = 1` row, because the seeding INSERT lives in
 *   historical migration 0032 and a virgin bootstrap deliberately does not replay those. Observed on
 *   nonprod: the routine returned ZERO ROWS, so document upload was dead on both mobile platforms and
 *   `submit_claim_with_evidence` would have raised `upload_policy_missing`. It recurs on every future
 *   bootstrap until 0065 lands.
 *
 * ★ WHAT THIS FILE CANNOT DO. It cannot prove the routine answers — only a database can, and
 *   `scripts/verifyUploadPolicySeed.mjs` does, against a throwaway container, with a mutation step
 *   proving the migration's postcondition can fail. What this file proves is the part a green
 *   container run cannot: that the migration is where the repository's own authority contract says it
 *   must be, that it cannot clobber a tuned row, and that the CI job which runs the container proof
 *   actually exists.
 *
 * ★ COMMENTS ARE STRIPPED BEFORE MATCHING. The migration's header discusses `130_seeds.sql`, the
 *   rejected design, and names `DO UPDATE` while explaining why it is not used. A matcher run against
 *   the raw file would be satisfied by the prose.
 */
import { readFileSync, existsSync, readdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "vitest";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const MIGRATION = "db/migrations/0065_20261001_upload_policy_seed.sql";
const VERIFIER = "scripts/verifyUploadPolicySeed.mjs";
const CHECKLIST = "docs/provisioning/documents-bucket.md";

const read = (rel: string) => readFileSync(join(ROOT, rel), "utf8");
const stripComments = (src: string): string =>
  src
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .split("\n")
    .filter((l) => !l.trimStart().startsWith("--"))
    .join("\n");

describe("the scan set is real", () => {
  test("every file this suite reasons about exists and is substantial", () => {
    for (const f of [MIGRATION, VERIFIER, CHECKLIST]) {
      expect(existsSync(join(ROOT, f)), `${f} is missing`).toBe(true);
      expect(read(f).length, `${f} is too small to be the real thing`).toBeGreaterThan(500);
    }
  });

  test("★ the comment stripper removes prose and keeps SQL — its own control", () => {
    const stripped = stripComments(read(MIGRATION));
    // Header-only. If this survives, nothing is being stripped.
    expect(stripped).not.toContain("130_seeds.sql");
    // Code. If this is gone, the stripper is eating what the rules must see.
    expect(stripped).toContain("insert into public.upload_policy");
  });
});

describe("★ the bootstrap really does lack the row — the premise, not an assumption", () => {
  const boot = () =>
    ["30_tables.sql", "40_constraints.sql", "60_functions.sql", "80_rls_enable.sql", "100_grants.sql", "110_storage_policies.sql"]
      .map((f) => read(`db/bootstrap/${f}`))
      .join("\n");

  test("it creates the table and the reader", () => {
    const b = boot();
    expect(b).toMatch(/CREATE TABLE IF NOT EXISTS "public"\."upload_policy"/);
    expect(b).toMatch(/FUNCTION "public"\."get_upload_policy"\(\)/);
  });

  test("★ and inserts NO row anywhere in the bootstrap — this is the whole defect", () => {
    const files = readdirSync(join(ROOT, "db/bootstrap")).filter((f) => /^\d+_.*\.sql$/.test(f));
    expect(files.length).toBeGreaterThan(10);                            // the scan set is real
    const inserts = files.filter((f) =>
      /insert\s+into\s+("?public"?\.)?"?upload_policy"?/i.test(read(`db/bootstrap/${f}`)));
    expect(inserts).toEqual([]);
  });

  test("the historical seed exists in 0032, which a virgin bootstrap does not replay", () => {
    expect(read("db/migrations/0032_20260720_upload_policy.sql"))
      .toMatch(/insert\s+into\s+public\.upload_policy/i);
    const manifest = JSON.parse(read("db/bootstrap/manifest.json"));
    expect(manifest.historical_migrations.replayed_during_virgin_bootstrap).toBe(false);
  });
});

describe("★ it is a future migration, which is where the authority contract puts it", () => {
  const A = () => JSON.parse(read("db/AUTHORITY.json"));

  test("0065 is above the cutoff, uniquely numbered, and correctly named", () => {
    const files = readdirSync(join(ROOT, "db/migrations")).filter((f) => f.endsWith(".sql"));
    expect(files.filter((f) => f.startsWith("0065_"))).toEqual(["0065_20261001_upload_policy_seed.sql"]);
    const seqs = files.map((f) => f.slice(0, 4));
    expect(new Set(seqs).size, "duplicate migration sequence numbers").toBe(seqs.length);
    expect(/^\d{4}_\d{8}_[a-z0-9_]+\.sql$/.test("0065_20261001_upload_policy_seed.sql")).toBe(true);
    expect(Number("0065")).toBeGreaterThan(Number(read("db/bootstrap/VERSION").trim()));
  });

  test("★ NOT a new bootstrap phase — the contract forbids a rolling snapshot", () => {
    // A reviewed draft of this fix proposed db/bootstrap/130_seeds.sql. The contract says the
    // bootstrap is a FIXED cutover base; folding change back into it makes a virgin install and an
    // upgraded install stop being provably the same schema.
    expect(A().bootstrap_authority.rolling).toBe(false);
    expect(A().future_migration_authority.adding_a_future_migration.does_not_change)
      .toContain("db/bootstrap/");
    const phases = readdirSync(join(ROOT, "db/bootstrap")).filter((f) => /^\d+_.*\.sql$/.test(f));
    expect(phases.some((f) => f.startsWith("130_"))).toBe(false);
    expect(JSON.parse(read("db/bootstrap/manifest.json")).phases.some((p: { id: string }) => p.id === "130")).toBe(false);
  });
});

describe("★ it cannot overwrite an operator's tuned policy", () => {
  const sql = () => stripComments(read(MIGRATION));

  test("ON CONFLICT DO NOTHING, and never DO UPDATE", () => {
    expect(sql()).toMatch(/on conflict \(id\) do nothing/i);
    expect(sql()).not.toMatch(/do update/i);
  });

  test("it contains exactly one INSERT and no UPDATE or DELETE of the policy", () => {
    const s = sql();
    expect((s.match(/insert\s+into\s+public\.upload_policy/gi) ?? []).length).toBe(1);
    expect(s).not.toMatch(/update\s+public\.upload_policy/i);
    expect(s).not.toMatch(/delete\s+from\s+public\.upload_policy/i);
  });

  test("it performs no DDL — not a table, grant, policy or function", () => {
    const s = sql();
    for (const forbidden of [/create\s+table/i, /alter\s+table/i, /create\s+policy/i, /\bgrant\b/i, /create\s+or\s+replace\s+function/i, /drop\s+/i]) {
      expect(s, String(forbidden)).not.toMatch(forbidden);
    }
  });

  test("it HALTS rather than creating the table it does not own", () => {
    expect(sql()).toContain("PRECONDITION FAILED");
  });

  test("it is transactional", () => {
    const s = sql();
    expect(s).toMatch(/^\s*BEGIN;/m);
    expect(s).toMatch(/^COMMIT;\s*$/m);
  });
});

describe("★ the postcondition checks the ROUTINE, not the table", () => {
  const sql = () => stripComments(read(MIGRATION));

  test("it calls get_upload_policy() and requires exactly one row", () => {
    // The nonprod outage is exactly the case a table-level assertion would have missed: the row
    // present, the routine unreachable. A grant, ownership or search_path mistake reproduces it.
    const s = sql();
    expect(s).toMatch(/count\(\*\)\s+INTO\s+v_rows\s+FROM\s+public\.get_upload_policy\(\)/i);
    expect(s).toMatch(/v_rows\s*<>\s*1/);
  });

  test("present is not usable — a NULL limit and an empty MIME array are both refused", () => {
    const s = sql();
    expect(s).toMatch(/v_bytes IS NULL OR v_bytes <= 0/);
    expect(s).toMatch(/array_length\(v_mimes, 1\), 0\) = 0/);
    expect(s).toMatch(/v_files IS NULL OR v_files <= 0/);
  });

  test("★ told == enforced: the routine's row and the table's row must be the same row", () => {
    // `submit_claim_with_evidence` and `create_vault_document` read the table directly while the
    // client is told `get_upload_policy()`. That is only one contract if they agree.
    expect(sql()).toMatch(/told\/enforced have diverged|told == enforced|the row the client is told/);
    expect(sql()).toMatch(/FROM public\.upload_policy t[\s\S]{0,400}allowed_mime_types\s*=\s*v_mimes/);
  });

  test("the seeded values mirror the documented bucket configuration", () => {
    const s = sql();
    expect(s).toContain("25 * 1024 * 1024");
    expect(s).toContain("50 * 1024 * 1024");
    for (const m of ["application/pdf", "image/jpeg", "image/png", "image/heic"]) expect(s).toContain(m);
    // And the checklist states the same numbers, so the manual duality has one written source.
    const doc = read(CHECKLIST);
    expect(doc).toContain("26214400");
    expect(doc).toContain("image/heic");
  });
});

describe("★ the container proof exists, is wired into CI, and cannot be aimed at a real database", () => {
  test("the verifier refuses every remote-target flag", () => {
    const v = read(VERIFIER);
    for (const flag of ["--database-url", "--project-ref", "--remote", "--production", "--host", "--dsn"]) {
      expect(v, flag).toContain(flag);
    }
    expect(v).toContain("REFUSED");
    expect(v).toContain("docker");
  });

  test("★ it treats an already-seeded fresh bootstrap as a REFUSAL, not a pass", () => {
    // Otherwise the day the bootstrap learns to seed the row, every later step goes vacuous and this
    // instrument becomes a rubber stamp for a fix it never exercised.
    expect(read(VERIFIER)).toContain("ALREADY RETURNS");
    expect(read(VERIFIER)).toMatch(/would be\s+'?\s*\+?\s*'?vacuous/);
  });

  test("it carries a mutation step that requires the postcondition to fail", () => {
    const v = read(VERIFIER);
    expect(v).toContain("MUTATION SURVIVED");
    expect(v).toContain("delete from public.upload_policy where id = 1");
    expect(v).toContain("0065 POSTCONDITION FAILED");
  });

  test("it proves idempotence AND that a tuned value survives", () => {
    const v = read(VERIFIER);
    expect(v).toContain("is NOT idempotent");
    expect(v).toContain("OVERWROTE an operator");
  });

  test("npm exposes it and CI runs it", () => {
    const pkg = JSON.parse(read("package.json"));
    expect(pkg.scripts["verify:upload-policy"]).toBe("node scripts/verifyUploadPolicySeed.mjs");
    const ci = read(".github/workflows/ci.yml");
    expect(ci).toContain("npm run verify:upload-policy");
  });

  test("it exits non-zero when it cannot verify, so a runner without Docker fails the job", () => {
    const v = read(VERIFIER);
    expect(v).toContain("UNVERIFIABLE");
    expect(v).toContain("Docker unavailable");
    expect(v).toMatch(/process\.exit\(verdict === 'UNVERIFIABLE' \? 2 : 1\)/);
  });
});

describe("the bucket is named as a separate, non-SQL prerequisite", () => {
  test("the checklist says the bucket cannot be created by SQL, and why", () => {
    const doc = read(CHECKLIST);
    expect(doc).toContain("platform");
    expect(doc).toMatch(/storage\.buckets/);
    expect(doc).toContain("public");
  });

  test("★ and it says a readable policy is NOT proof of a working upload", () => {
    // The nonprod outage was visible at the policy read and invisible at every layer above it.
    expect(read(CHECKLIST)).toMatch(/NOT that proof|prerequisites, not the journey/);
  });

  test("the migration points at the checklist rather than implying SQL covers it", () => {
    expect(read(MIGRATION)).toContain("docs/provisioning/documents-bucket.md");
  });
});
