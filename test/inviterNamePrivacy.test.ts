/**
 * INVITER NAME PRIVACY (migration 0069) — the contract, pinned statically.
 *
 * The behaviour is proven by `scripts/verifyInviterNamePrivacy.mjs` (a container built from db/bootstrap
 * + 0067 + 0068 + 0069; synthetic owners in every name state; both create paths; every release point;
 * wired into CI) and, for the email itself, by the rendered-HTML-and-text cases in test/delivery.test.ts
 * and test/invitationTemplate.test.ts. This suite pins what a text scan can prove without a database, so
 * a later edit cannot quietly bring the address back:
 *
 *   · neither create path persists an email as the inviter name — both pass `full_name` through the
 *     server sanitizer and neither reads `profiles.email` for it;
 *   · every SQL release point to a recipient (pending list, token preview, membership cue) gates on the
 *     owner's choice AND passes the stored value through the sanitizer;
 *   · the worker gates on the choice and sanitizes; the template sanitizes again;
 *   · the three mirrors under db/functions carry 0069's bodies; 0069 changes no table and no grant;
 *   · 0068's cue predicates and 0067's binding predicate survive in the final resolve_membership;
 *   · CI runs the container verification and the script refuses a remote target.
 */
import { describe, expect, test } from "vitest";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

const ROOT = join(__dirname, "..");
const read = (p: string) => readFileSync(join(ROOT, p), "utf8");
const MIGRATION = "db/migrations/0069_20261126_inviter_name_privacy.sql";
const stripComments = (s: string) => s.replace(/--[^\n]*/g, "");
const bodyOf = (sql: string, name: string) =>
  (sql.match(new RegExp(`create\\s+or\\s+replace\\s+function\\s+public\\.${name}\\s*\\([\\s\\S]*?\\$[a-z_]*\\$;`, "i")) ?? [""])[0]
    .replace(/--[^\n]*/g, "")
    .replace(/\s+/g, " ")
    .trim();
/** The LATEST migration that defines a function — the body that is actually deployed. */
const latestMigrationDefining = (name: string): string => {
  const files = readdirSync(join(ROOT, "db/migrations")).filter((f) => /^\d{4}_.*\.sql$/.test(f)).sort();
  const defining = files.filter((f) => new RegExp(`create\\s+or\\s+replace\\s+function\\s+public\\.${name}\\s*\\(`, "i").test(read(`db/migrations/${f}`)));
  expect(defining.length).toBeGreaterThan(0);
  return `db/migrations/${defining[defining.length - 1]}`;
};
const FUNCTIONS = ["create_estate_invitation", "create_invitation", "invitation_preview", "resolve_membership"] as const;
const OLD_FALLBACK = /coalesce\s*\(\s*nullif\s*\(\s*\w+\.full_name\s*,\s*''\s*\)\s*,\s*\w+\.email\s*\)/i;

describe("0 · the scan set is real", () => {
  test("★ the migration exists, defines all four functions, and is the latest definition of each", () => {
    const m = read(MIGRATION);
    expect(m.length).toBeGreaterThan(5000);
    for (const fn of FUNCTIONS) {
      expect(bodyOf(m, fn).length, fn).toBeGreaterThan(300);
      expect(latestMigrationDefining(fn), fn).toBe(MIGRATION);
    }
  });
  test("★ positive control — the fallback matcher finds the deployed pre-0069 line in BOTH spellings", () => {
    expect(OLD_FALLBACK.test("select coalesce(nullif(pr.full_name, ''), pr.email) into v_inviter_name")).toBe(true);
    expect(OLD_FALLBACK.test("select coalesce(nullif(p.full_name,''), p.email) into v_inviter_name from public.profiles p")).toBe(true);
    expect(OLD_FALLBACK.test("select public.safe_inviter_display_name(pr.full_name) into v_inviter_name")).toBe(false);
  });
  test("★ positive control — the deployed bootstrap still carries the fallback in both create paths (what 0069 supersedes)", () => {
    const boot = read("db/bootstrap/60_functions.sql");
    expect((boot.match(new RegExp(OLD_FALLBACK.source, "gi")) ?? []).length).toBe(2);
  });
});

describe("0b · the prerequisite guard runs first and names what is missing", () => {
  const raw = () => read(MIGRATION);
  test("★ one DO block, placed before the first create or replace, checks the two 0067 helpers and the 0068 sanitizer", () => {
    const m = raw();
    const guardAt = m.indexOf("do $prereq$");
    const firstCreate = m.search(/create\s+or\s+replace\s+function/i);
    expect(guardAt).toBeGreaterThan(0);
    expect(firstCreate).toBeGreaterThan(guardAt); // nothing is replaced before the check
    const guard = m.slice(guardAt, m.indexOf("$prereq$;", guardAt));
    expect(guard).toContain("to_regprocedure('public.invitation_phone_key(text, boolean)')");
    expect(guard).toContain("to_regprocedure('public.caller_verified_contacts()')");
    expect(guard).toContain("to_regprocedure('public.safe_inviter_display_name(text)')");
    expect(guard).toMatch(/raise exception '0069_prerequisite_missing: apply migration % before 0069\. Nothing has been changed\.', v_missing/);
    // the message names the prerequisite MIGRATION as well as the function
    expect(guard).toMatch(/'0067 \(resolve_membership contact binding\): public\.invitation_phone_key\(text, boolean\)'/);
    expect(guard).toMatch(/'0067 \(resolve_membership contact binding\): public\.caller_verified_contacts\(\)'/);
    expect(guard).toMatch(/'0068 \(membership invitation cue\): public\.safe_inviter_display_name\(text\)'/);
    // it only reads the catalog: no write, no create, no grant inside the guard
    expect(stripComments(guard)).not.toMatch(/create|grant|revoke|insert|update|delete/i);
  });
  test("★ the container proof exercises the guard in both psql modes and fingerprints the four targets", () => {
    const script = read("scripts/verifyInviterNamePrivacy.mjs");
    expect(script).toContain("0069_prerequisite_missing");
    expect(script).toMatch(/const psql1 = .*'-1'/); // single-transaction mode, the hosted editor's shape
    expect(script).toContain("md5(p.prosrc)");
    for (const f of FUNCTIONS) expect(script).toContain(`'${f}'`);
    expect(script).toMatch(/bare bootstrap \(no 0067\)/);
    expect(script).toMatch(/0067 applied, 0068 missing/);
    expect(script).toMatch(/re-applying 0069 preserves the final definitions/);
  });
});

describe("1 · neither create path persists an address as the inviter name", () => {
  test.each(["create_estate_invitation", "create_invitation"])("★ %s: full_name through the sanitizer; no email fallback; no profile email read for the name", (fn) => {
    const b = bodyOf(read(MIGRATION), fn);
    expect(b).toMatch(/select public\.safe_inviter_display_name\(\w+\.full_name\) into v_inviter_name/);
    expect(b).not.toMatch(OLD_FALLBACK);
    // the only remaining profile-email read in create_estate_invitation is the SELF-INVITATION check, which
    // compares the caller's address to the invitee's and stores nothing — it may not feed v_inviter_name
    expect(b).not.toMatch(/v_inviter_name\s*:=\s*[^;]*email/i);
    expect(b).not.toMatch(/into v_inviter_name[^;]*\.email/i);
    // a missing name does not block the mint: nothing raises on a null inviter name
    expect(b).not.toMatch(/v_inviter_name is null[^;]*raise/i);
    expect(b).toMatch(/inviter_display_name, preview_visibility/); // the column is still written (NULL is a value)
  });
  test("★ the recipient contact and the two visibility choices are stored exactly as before", () => {
    for (const fn of ["create_estate_invitation", "create_invitation"] as const) {
      const b = bodyOf(read(MIGRATION), fn);
      expect(b, fn).toMatch(/jsonb_build_object\('showEstateName', p_show_estate_name, 'showInviterName', p_show_inviter_name\)/);
      expect(b, fn).toMatch(/invitee_email, invitee_phone/);
    }
  });
  test("★ create_estate_invitation keeps 0045's fix (alias-qualified expiry predicate)", () => {
    expect(bodyOf(read(MIGRATION), "create_estate_invitation")).toMatch(/inv\.expires_at <= now\(\)/);
  });
});

describe("2 · every SQL release point gates on the choice AND sanitizes", () => {
  test("★ the pending list (resolve_membership)", () => {
    const b = bodyOf(read(MIGRATION), "resolve_membership");
    const at = b.indexOf("into v_pending");
    const pending = b.slice(b.lastIndexOf("select coalesce(jsonb_agg", at), at);
    expect(pending.length).toBeGreaterThan(200);
    expect(pending).toMatch(/'inviterDisplayName', case when \(i\.preview_visibility->>'showInviterName'\)::boolean then public\.safe_inviter_display_name\(i\.inviter_display_name\) else null end/);
    expect(pending).not.toMatch(/then i\.inviter_display_name else null/);
    // the estate-name choice is independent and untouched
    expect(pending).toMatch(/'estateDisplayName', case when \(i\.preview_visibility->>'showEstateName'\)::boolean then i\.estate_display_name else null end/);
  });
  test("★ the token preview (invitation_preview)", () => {
    const b = bodyOf(read(MIGRATION), "invitation_preview");
    expect(b).toMatch(/case when \(v_inv\.preview_visibility->>'showInviterName'\)::boolean is true then public\.safe_inviter_display_name\(v_inv\.inviter_display_name\) else null end/);
    expect(b).not.toMatch(/then v_inv\.inviter_display_name else null/);
    expect(b).toMatch(/case when \(v_inv\.preview_visibility->>'showEstateName'\)::boolean is true then v_inv\.estate_display_name else null end/);
    expect(b).toMatch(/v_inv\.invitee_email_hint, v_inv\.invitee_phone_hint/); // the hints are untouched
  });
  test("★ the membership cue (0068) survives verbatim in the final resolve_membership", () => {
    const b = bodyOf(read(MIGRATION), "resolve_membership");
    const cue = b.slice(b.indexOf("'isPrimaryEstate', false"));
    expect(cue.length).toBeGreaterThan(200);
    for (const p of ["i.id = m.source_invitation_id", "i.estate_id = m.estate_id", "i.accepted_by = v_user", "i.status = 'accepted'", "coalesce((i.preview_visibility->>'showInviterName')::boolean, false)", "public.safe_inviter_display_name(i.inviter_display_name)"]) expect(cue).toContain(p);
    expect(b.slice(0, b.indexOf("into v_primary"))).not.toContain("inviterDisplayName"); // no cue on the primary context
  });
  test("★ 0067's contact binding survives verbatim", () => {
    const b = bodyOf(read(MIGRATION), "resolve_membership");
    expect(b).toContain("from public.caller_verified_contacts() c");
    expect(b).toContain("v_email is not null and lower(i.invitee_email) is not distinct from v_email");
    expect(b).toContain("v_phone is not null and public.invitation_phone_key(i.invitee_phone, true) is not distinct from v_phone");
    const at = b.indexOf("into v_pending");
    expect(b.slice(at, b.indexOf(";", at))).not.toMatch(/p_email|p_phone/);
    expect(b).toMatch(/'primaryEstateContext', v_primary, 'pendingInvitations', v_pending, 'additionalContexts', v_additional/);
  });
  test("★ nothing in the final resolve_membership reads a profile name or substitutes a neutral phrase", () => {
    const b = bodyOf(read(MIGRATION), "resolve_membership");
    expect(b).not.toMatch(/public\.profiles|full_name|An estate owner/i);
  });
});

describe("3 · the worker gates and sanitizes; the template sanitizes again", () => {
  test("★ delivery.ts: the choice gates, the sanitizer decides — and the same line serves every retry", () => {
    const src = read("lib/invitations/delivery.ts");
    expect(src).toContain('import { safeInviterDisplayName } from "./safeInviterDisplayName.js";');
    expect(src).toMatch(/const inviterName = preview\.showInviterName === true \? safeInviterDisplayName\(issued\.inviter_display_name\) : null;/);
    expect(src).not.toMatch(/\? issued\.inviter_display_name : null/); // the raw pass-through is gone
    // one orchestrator for both paths: claimAndDeliver (immediate + cron) → deliverClaimedRow → the line above
    expect(src).toMatch(/tally\(counters, await deliverClaimedRow\(admin, row, deps\)\)/);
    expect(read("lib/invitations/drainEmailOutbox.ts")).toContain("claimAndDeliver(admin, { max: BATCH }, deps)");
    expect(read("lib/invitations/createOwner.ts")).toContain("claimAndDeliver(admin, { outboxId }, deps)");
  });
  test("★ invitationTemplate.ts: the inviter name passes the sanitizer, the estate name keeps its trim-only rule", () => {
    const src = read("lib/email/invitationTemplate.ts");
    expect(src).toContain('import { safeInviterDisplayName } from "../invitations/safeInviterDisplayName.js";');
    expect(src).toMatch(/const inviter = safeInviterDisplayName\(input\.inviterDisplayName\);/);
    expect(src).not.toMatch(/const inviter = input\.inviterDisplayName\?\.trim\(\) \|\| null;/);
    expect(src).toMatch(/const estate = input\.estateDisplayName\?\.trim\(\) \|\| null;/);
  });
  test("★ the owner path still forwards the owner's choice as a strict boolean", () => {
    expect(read("lib/invitations/createOwner.ts")).toContain("p_show_inviter_name: o.showInviterName === true,");
    expect(read("lib/invitations/createOwner.ts")).toContain("p_show_estate_name: o.showEstateName === true,");
  });
  test("★ the sanitizer module has no substitute and no second rule", () => {
    const src = read("lib/invitations/safeInviterDisplayName.ts");
    expect(src).toMatch(/if \(\/\\S@\\S\/\.test\(trimmed\)\) return null;/);
    expect(src).toMatch(/Array\.from\(trimmed\)\.length > INVITER_NAME_MAX_LENGTH/);
    expect(src).toMatch(/export const INVITER_NAME_MAX_LENGTH = 200;/);
  });
});

describe("4 · mirrors, schema, grants", () => {
  test.each(["create_invitation", "invitation_preview", "resolve_membership"])("★ db/functions/%s.sql === migration 0069 (normalised)", (fn) => {
    expect(bodyOf(read(`db/functions/${fn}.sql`), fn)).toBe(bodyOf(read(MIGRATION), fn));
  });
  test("★ create_estate_invitation has no mirror (never had one); its authority is the migration", () => {
    expect(readdirSync(join(ROOT, "db/functions"))).not.toContain("create_estate_invitation.sql");
  });
  test("★ the migration changes no table and widens no grant", () => {
    const m = stripComments(read(MIGRATION));
    expect(m).not.toMatch(/alter\s+table|create\s+table|add\s+column/i);
    // no top-level data statement either (function bodies are indented; a backfill would start a line)
    expect(m).not.toMatch(/^(update|delete|insert)\s/im);
    expect(/^(update|delete|insert)\s/im.test("update public.invitations set inviter_display_name = null;")).toBe(true); // positive control
    // grants restate what the bootstrap already holds — authenticated for the two create paths and
    // resolve_membership, anon for the preview — and nothing more
    const grants = [...m.matchAll(/^grant\s+execute on function public\.(\w+)\([^)]*\) to ([a-z, ]+);/gim)].map((g) => `${g[1]}→${g[2].trim()}`).sort();
    expect(grants).toEqual(["create_estate_invitation→authenticated", "create_invitation→authenticated", "invitation_preview→anon", "resolve_membership→authenticated"]);
    expect(m).not.toMatch(/^grant[^\n]*to\s+(public|service_role)\b/im);
  });
  test("★ the migration says it lands after 0067 and 0068", () => {
    expect(read(MIGRATION)).toMatch(/LANDS AFTER 0067 AND 0068/);
  });
});

describe("5 · harness and CI", () => {
  test("★ CI runs the container verification and the script refuses a remote target", () => {
    expect(read(".github/workflows/ci.yml")).toMatch(/npm run verify:inviter-privacy/);
    expect(JSON.parse(read("package.json")).scripts["verify:inviter-privacy"]).toBe("node scripts/verifyInviterNamePrivacy.mjs");
    const script = read("scripts/verifyInviterNamePrivacy.mjs");
    expect(script).toMatch(/REFUSED/);
    expect(script).not.toMatch(/process\.env\.|SUPABASE_URL|SERVICE_ROLE/); // reads no environment at all
    expect(script).toMatch(/0067_/);
    expect(script).toMatch(/0068_/);
    expect(script).toMatch(/0069_/);
    expect(script).toMatch(/safe_inviter_display_name_assertions\.sql/);
  });
  test("★ the script's seed uses distinct sender and recipient addresses, so absence of one is separable from delivery to the other", () => {
    const script = read("scripts/verifyInviterNamePrivacy.mjs");
    expect(script).toContain("const RECIPIENT = 'recipient@example.test';");
    expect(script).toMatch(/SENDER_ADDRESSES/);
    expect(script).toMatch(/shown-sender@example\.test/);
    expect(script).toMatch(/legacy-sender@example\.test/);
  });
});
