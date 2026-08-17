/**
 * PHASE 11-OB PREP · NO-PRODUCTION-MUTATION AUDIT.
 *
 * ★ THE CLAIM THIS FILE MAKES IS NARROW AND EXACT: every instrument added by this prep slice names
 * no mutation RPC outside a comment, obtains no elevated credential, uses no mutating HTTP method,
 * and — where it can reach the network at all — reaches only paths on an allowlist.
 *
 * It is NOT a claim that the routines are unreachable by other means, and it is not named as one.
 *
 * ★ EVERY MECHANISM IS PROVED BEFORE IT IS TRUSTED:
 *   · the scan set is non-empty and every file was really read (lengths asserted);
 *   · the comment stripper has positive controls in BOTH directions — it removes a comment, and it
 *     does NOT remove a string;
 *   · the forbidden-RPC list is checked against `db/functions/` so a typo cannot retire a rule;
 *   · detection fixtures prove a violation of each class WOULD be caught;
 *   · the whole audit runs twice in one process and must agree.
 */
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  FORBIDDEN_METHODS,
  FORBIDDEN_SECRET_TOKENS,
  MUTATION_RPCS,
  auditReadOnlyScripts,
  pathLiterals,
  stripComments,
} from "../scripts/lib/readOnlyAudit.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");

/**
 * The instruments this prep slice added. Adding a read-only tool means adding a row — the same
 * discipline as the default-dependency audit.
 */
const READ_ONLY_FILES = [
  "scripts/observeOwnerNoticeDelivery.mjs",
  "scripts/branchBSentinel.mjs",
  /**
   * ★ PHASE 11-OC. The Phase A deployment verifier and production readiness census.
   *
   * It reads two `stable` census routines through a real AAL2 admin session and corroborates the
   * result against the operator queue. An earlier draft also probed `authorize_release` and
   * `begin_challenge_window` with a nil estate to read back their refusal sentinel — calls that
   * provably cannot write, because both raise at a state guard before any statement executes.
   *
   * It is listed here WITHOUT those probes, and that is the point: "provably cannot write" meant a
   * human traced the branch. This audit exists so read-only-ness is structural rather than argued, and
   * the way it enforces that is by refusing to let a script NAME a routine on MUTATION_RPCS at all.
   * A census instrument that needed case-by-case reasoning is precisely what the list prevents, so the
   * probes were removed rather than the file being left ungoverned.
   */
  "scripts/verifyPhaseADeployment.mjs",
  /**
   * ★ PHASE 11-OC / PHASE C. The Phase C deployment verifier.
   *
   * It is the sharpest case this list has governed so far, because the thing it verifies IS a
   * mutation RPC. The obvious design — probe `reissue_owner_safety_notice` with a nil uuid and read
   * back its refusal sentinel — is refused for the reason this audit exists: "provably cannot write"
   * would mean a human traced the branch, and a future edit that moved a side effect above the guard
   * would silently make the verifier the thing that fired it. On this routine that side effect is an
   * email to a living person about their own death process.
   *
   * So deployment is established from the READ side instead: the case-file projection carries
   * `owner_notice_reissue`, computed by the assessment function the door and only the door shares.
   * The script therefore never NAMES the writer in a call position at all, and this list is what
   * keeps it that way.
   */
  "scripts/verifyPhaseCDeployment.mjs",
  /**
   * ★ PHASE 11-OC / PHASE D. The Phase D deployment verifier, and the sharpest case yet.
   *
   * The routine it verifies is `authorize_release`, whose side effect is not an email — it is the
   * IRREVERSIBLE DISCLOSURE OF AN ESTATE. There is no probe of it that this audit could ever be
   * argued into permitting, and the script does not attempt one: it never names the routine in a
   * call position at all.
   *
   * Deployment is established from the READ side, and Phase D's architecture is what makes that a
   * real proof rather than a proxy. `admin_get_death_verification_case` and `authorize_release`
   * consume the SAME `owner_notice_release_authority`, so the projection is not standing in for the
   * door's rule — it IS the door's rule, evaluated on the same row. The verifier reads that verdict,
   * checks its refusal vocabulary is the Phase D set, and proves the CLOCK moved arithmetically
   * (`release_eligible_at` NULL exactly when there is no acceptance fact, which a Phase C server
   * cannot produce on a dispatched case because `owner_notified_at` is never null there).
   *
   * This list is what keeps it that way. Adding a "harmless" probe of the release door would fail
   * here rather than be discovered after an estate had been disclosed.
   */
  "scripts/verifyPhaseDDeployment.mjs",
  "scripts/lib/t2Classification.mjs",
  "scripts/lib/branchBCheckpoint.mjs",
  "scripts/lib/branchBBaseline.mjs",
  "scripts/lib/branchBSentinel.mjs",
  "scripts/lib/disclosureOracle.mjs",
  "scripts/lib/canonicalJson.mjs",
];

/**
 * ★ `scripts/lib/readOnlyAudit.mjs` IS DELIBERATELY NOT IN THAT LIST, and the exclusion is asserted
 * rather than assumed. It is the rule DECLARATION — it contains every forbidden routine name as a
 * string literal by definition, so scanning it would report 45 violations against the file whose
 * only job is to define them. What must be true of it instead is that it is not an instrument: it
 * reaches no network at all, which is checked below.
 */
const RULE_MODULE = "scripts/lib/readOnlyAudit.mjs";

describe("★ 0 · the scan set is real", () => {
  it("every declared file exists and is non-trivial", () => {
    expect(READ_ONLY_FILES.length).toBeGreaterThanOrEqual(8);
    for (const f of READ_ONLY_FILES) {
      const p = join(ROOT, f);
      expect(existsSync(p), `${f} does not exist`).toBe(true);
      expect(readFileSync(p, "utf8").length, `${f} is empty`).toBeGreaterThan(200);
    }
  });

  it("★ the audit reports having read every one of them", () => {
    const r = auditReadOnlyScripts({ root: ROOT, files: READ_ONLY_FILES });
    expect(r.scanned.map((s: { file: string }) => s.file).sort()).toEqual([...READ_ONLY_FILES].sort());
    for (const s of r.scanned) expect(s.rawLength).toBeGreaterThan(200);
  });

  it("★ an empty scan set is a failure, never 'clean'", () => {
    const r = auditReadOnlyScripts({ root: ROOT, files: [] });
    expect(r.ok).toBe(false);
    expect(r.violations[0].code).toBe("empty_file_list");
  });

  it("★ both file classes are represented — neither branch of the audit is vacuous", () => {
    const r = auditReadOnlyScripts({ root: ROOT, files: READ_ONLY_FILES });
    // At least one network-capable script (so the path allowlist is exercised)…
    expect(r.networkCapableCount).toBeGreaterThanOrEqual(1);
    // …and at least one pure library (so "no fetch" is a real category, not an empty one).
    expect(r.networkCapableCount).toBeLessThan(READ_ONLY_FILES.length);
  });

  it("★ the rule module is excluded, and it earns the exclusion by reaching no network", () => {
    expect(READ_ONLY_FILES).not.toContain(RULE_MODULE);
    const src = readFileSync(join(ROOT, RULE_MODULE), "utf8");
    expect(src).not.toMatch(/\bfetch\s*\(/);
    expect(src).not.toMatch(/\bspawnSync\s*\(|\bexecFileSync\s*\(/);
    // …and it really does hold the forbidden names, which is why it cannot scan itself.
    expect(src).toContain("authorize_release");
  });

  it("no declared file was silently skipped as unreadable", () => {
    const r = auditReadOnlyScripts({ root: ROOT, files: READ_ONLY_FILES });
    expect(r.violations.filter((v: { code: string }) => v.code === "unreadable")).toEqual([]);
  });
});

describe("★ 1 · the comment stripper is proved in both directions", () => {
  it("★ it removes a line comment and a block comment", () => {
    expect(stripComments("a // authorize_release\nb")).not.toContain("authorize_release");
    expect(stripComments("a /* claim_owner_notices */ b")).not.toContain("claim_owner_notices");
  });

  it("★ it does NOT remove a string literal — the evidence class lives there", () => {
    expect(stripComments("const x = 'authorize_release';")).toContain("authorize_release");
    expect(stripComments("const x = `rpc/${'purge_outbox_rows'}`;")).toContain("purge_outbox_rows");
  });

  it("★ `https://` inside a string is not mistaken for a line comment", () => {
    const src = "const u = 'https://api.example.test/x'; const rpc = 'authorize_release';";
    const out = stripComments(src);
    expect(out).toContain("https://api.example.test/x");
    expect(out).toContain("authorize_release");
  });

  it("escaped quotes do not end a string early", () => {
    expect(stripComments("const s = 'a\\'b // not a comment'; const t = 1;")).toContain("// not a comment");
  });

  /**
   * ★ THE REGRESSION CONTROL FOR A DEFECT THIS AUDIT ACTUALLY HAD.
   *
   * The first scanner tracked quotes only, so the quote characters INSIDE this regex were read as
   * string delimiters. Every quote in the remaining 180 lines of the observer paired one off: code
   * was treated as comment and comment as code. It surfaced as two false positives — the lucky
   * direction — and would hide a real call just as readily.
   */
  it("★ a regex literal containing quote characters does not desynchronize the scanner", () => {
    const src = [
      `const v = t.trim().replace(/^["']|["']\$/g, '');`,
      `// authorize_release must not survive`,
      `const rpc = 'admin_get_death_verification_case';`,
    ].join("\n");
    const out = stripComments(src);
    expect(out).not.toContain("authorize_release"); // the comment WAS stripped
    expect(out).toContain("admin_get_death_verification_case"); // the string was NOT
  });

  it("division is not mistaken for a regex", () => {
    const out = stripComments("const c = Math.floor(at / 30); // authorize_release\nconst d = 'keep';");
    expect(out).not.toContain("authorize_release");
    expect(out).toContain("keep");
  });

  it("★ POSITIVE CONTROL against the real files — the observer DISCUSSES routines it must not call", () => {
    // If this ever stops holding, the stripper is no longer being exercised by real input and the
    // whole "comments are stripped" argument becomes untested.
    const raw = readFileSync(join(ROOT, "scripts/observeOwnerNoticeDelivery.mjs"), "utf8");
    expect(raw).toContain("claim_owner_notices");
    expect(raw).toContain("purge_outbox_rows");
    expect(stripComments(raw)).not.toContain("claim_owner_notices");
    expect(stripComments(raw)).not.toContain("purge_outbox_rows");
  });

  it("★ POSITIVE CONTROL — the checkpoint library discusses authorize_release and survives stripping", () => {
    const raw = readFileSync(join(ROOT, "scripts/lib/branchBCheckpoint.mjs"), "utf8");
    expect(raw).toContain("authorize_release");
    expect(stripComments(raw)).not.toContain("authorize_release");
  });

  it("the stripper removes strictly less than the whole file", () => {
    for (const f of READ_ONLY_FILES) {
      const raw = readFileSync(join(ROOT, f), "utf8");
      const out = stripComments(raw);
      expect(out.length, `${f} stripped to nothing`).toBeGreaterThan(100);
      expect(out.length).toBeLessThan(raw.length);
    }
  });
});

describe("★ 2 · the forbidden list names real routines", () => {
  it("★ every forbidden RPC is genuinely a function in db/functions", () => {
    // A typo here would silently retire a rule and the audit would keep reporting clean.
    const sqlDir = join(ROOT, "db/functions");
    const all = readdirSync(sqlDir)
      .filter((f) => f.endsWith(".sql"))
      .map((f) => readFileSync(join(sqlDir, f), "utf8"))
      .join("\n");
    expect(all.length).toBeGreaterThan(10_000); // the scan set, asserted
    // ★ CASE-INSENSITIVE, because this control already caught something: `decline_invitation.sql`
    //   spells its header `CREATE OR REPLACE FUNCTION` in capitals, and a case-sensitive check
    //   reported a live routine as missing. A false "this rule is stale" is how a real rule gets
    //   deleted.
    const missing = MUTATION_RPCS.filter(
      (rpc) => !new RegExp(`create or replace function public\\.${rpc}\\s*\\(`, "i").test(all)
    );
    expect(missing).toEqual([]);
  });

  it("★ the control can fail — a name that is not a routine is reported missing", () => {
    const sqlDir = join(ROOT, "db/functions");
    const all = readdirSync(sqlDir)
      .filter((f) => f.endsWith(".sql"))
      .map((f) => readFileSync(join(sqlDir, f), "utf8"))
      .join("\n");
    expect(
      new RegExp("create or replace function public\\.authorise_release\\s*\\(", "i").test(all)
    ).toBe(false);
  });

  it("the list covers every verb the phase brief names", () => {
    const joined = MUTATION_RPCS.join(" ");
    for (const verb of [
      "initiate_death_verification_case",
      "cancel_death_verification_case",
      "admin_decide_death_verification_case",
      "dispatch_owner_safety_notice",
      "begin_challenge_window",
      "challenge_death_process",
      "authorize_release",
      "create_document_grant",
      "create_asset_grant",
      "create_invitation",
    ]) {
      expect(joined).toContain(verb);
    }
    expect(MUTATION_RPCS.length).toBeGreaterThanOrEqual(40);
  });
});

describe("★ 3 · THE AUDIT — every read-only instrument passes", () => {
  it("★ no violation of any class", () => {
    const r = auditReadOnlyScripts({ root: ROOT, files: READ_ONLY_FILES });
    expect(r.violations).toEqual([]);
    expect(r.ok).toBe(true);
  });

  it("★ running it twice in one process gives an identical result", () => {
    const a = auditReadOnlyScripts({ root: ROOT, files: READ_ONLY_FILES });
    const b = auditReadOnlyScripts({ root: ROOT, files: READ_ONLY_FILES });
    expect(JSON.stringify(a)).toBe(JSON.stringify(b));
  });

  it("the network-capable scripts reach only allowlisted paths", () => {
    for (const f of ["scripts/observeOwnerNoticeDelivery.mjs"]) {
      const stripped = stripComments(readFileSync(join(ROOT, f), "utf8"));
      const paths = pathLiterals(stripped);
      expect(paths.length).toBeGreaterThan(0); // the extractor found something
      for (const p of paths) {
        expect(p, `${f} reaches ${p}`).toMatch(/^\/(auth\/v1|rest\/v1\/rpc)\//);
      }
    }
  });

  it("★ the drain route is never a fetch target", () => {
    for (const f of READ_ONLY_FILES) {
      const stripped = stripComments(readFileSync(join(ROOT, f), "utf8"));
      for (const line of stripped.split("\n")) {
        if (line.includes("fetch(")) expect(line).not.toContain("drain_outboxes");
      }
    }
  });
});

describe("★ 4 · detection fixtures — each violation class WOULD be caught", () => {
  const audit = (source: string) =>
    auditReadOnlyScripts({ root: ROOT, files: ["synthetic.mjs"], readSource: () => source });

  it("a clean synthetic file passes — the fixture's own control", () => {
    const clean = `
      const r = await fetch(\`\${URL}/rest/v1/rpc/admin_get_death_verification_case\`, { method: 'POST' });
    `;
    expect(audit(clean).violations).toEqual([]);
  });

  it("★ a mutation RPC in code is caught", () => {
    const r = audit(`const x = await rpc('authorize_release', {});`);
    expect(r.violations.map((v: { code: string }) => v.code)).toContain("mutation_rpc_named");
    expect(r.violations[0].detail).toBe("authorize_release");
  });

  it("★ each forbidden RPC individually is caught", () => {
    for (const rpc of MUTATION_RPCS) {
      const r = audit(`await call('${rpc}');`);
      expect(r.ok, `${rpc} slipped through`).toBe(false);
    }
  });

  it("★ a mutation RPC in a COMMENT is NOT caught — documentation is not debt", () => {
    expect(audit(`// we never call authorize_release here\nconst a = 1;`).violations).toEqual([]);
  });

  it("★ CRON_SECRET is caught", () => {
    expect(audit(`const s = process.env.CRON_SECRET;`).violations.map((v: { code: string }) => v.code)).toContain(
      "secret_token"
    );
  });

  it("★ every secret token is caught", () => {
    for (const token of FORBIDDEN_SECRET_TOKENS) {
      expect(audit(`const s = process.env.${token};`).ok, `${token} slipped through`).toBe(false);
    }
  });

  it("★ a mutating HTTP method is caught", () => {
    for (const m of FORBIDDEN_METHODS) {
      expect(audit(`fetch(u, { method: '${m}' });`).ok, `${m} slipped through`).toBe(false);
    }
  });

  it("★ a disallowed network path is caught", () => {
    const r = audit(`await fetch(\`\${URL}/api/claims/drain_outboxes\`);`);
    expect(r.violations.map((v: { code: string }) => v.code)).toContain("disallowed_network_path");
  });

  it("★ a direct REST table write path is caught", () => {
    const r = audit(`await fetch(\`\${URL}/rest/v1/owner_notice_outbox\`, { method: 'POST' });`);
    expect(r.violations.map((v: { code: string }) => v.code)).toContain("disallowed_network_path");
  });

  it("★ an absolute URL in a network-capable file is caught", () => {
    const r = audit(`await fetch('https://evil.example.test/x');`);
    expect(r.violations.map((v: { code: string }) => v.code)).toContain("absolute_url_literal");
  });

  it("a filesystem path and a module specifier are NOT network claims", () => {
    // `${ENV_DIR}/.env` and './lib/x.mjs' both contain a `/…` run and neither is an endpoint.
    const r = audit("await fetch(u);\nconst a = `${DIR}/.env`;\nimport x from './lib/x.mjs';");
    expect(r.violations.filter((v: { code: string }) => v.code === "disallowed_network_path")).toEqual([]);
  });

  it("★ a template route is audited whole, not segment by segment", () => {
    expect(pathLiterals("const p = `/auth/v1/factors/${id}/challenge`;")).toEqual([
      "/auth/v1/factors/*/challenge",
    ]);
  });

  it("a path literal in a file with no fetch is NOT path-audited", () => {
    // Pure libraries legitimately hold the cron path as data — `t2Classification.mjs` does.
    expect(audit(`export const P = '/api/claims/drain_outboxes';`).violations).toEqual([]);
  });

  it("★ …and the moment that library gains a fetch, the same path IS audited", () => {
    const r = audit(`export const P = '/api/claims/drain_outboxes';\nawait fetch(P);`);
    expect(r.violations.map((v: { code: string }) => v.code)).toContain("disallowed_network_path");
  });

  it("an empty or unreadable source is a violation, never a pass", () => {
    expect(audit("   ").violations.map((v: { code: string }) => v.code)).toContain("empty_source");
    const r = auditReadOnlyScripts({
      root: ROOT,
      files: ["ghost.mjs"],
      readSource: () => {
        throw new Error("ENOENT");
      },
    });
    expect(r.violations[0].code).toBe("unreadable");
  });
});
