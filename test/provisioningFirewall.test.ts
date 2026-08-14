/**
 * PHASE 11-MC · THE PROVISIONING FIREWALL, INVERTED.
 *
 * ★ THIS TEST WAS WRITTEN TO BE FLIPPED, AND THIS IS THE FLIP. It previously asserted that
 * executor/trustee provisioning STILL forced a beneficiary membership — a tripwire against correcting
 * the defect before the mobile client could represent designation-only contexts. That client landed
 * (afterworth-mobile c4fb291: nullable access class, independent fiduciary axis, composing roster
 * merge), so the ordering constraint is satisfied and the correction has been made.
 *
 * The assertion is now permanent and points the other way: a fiduciary invitation must NOT manufacture
 * a disclosure class, and this fails if the old behaviour ever returns. It was NOT deleted, because
 * "the defect came back" is exactly the regression nobody would notice — the product would keep working
 * and quietly hand beneficiary standing to every new executor.
 *
 * ★ IT ASSERTS THE GATE IS ON `kind`, NOT ON `proposed_role`, AND THAT DISTINCTION IS THE WHOLE
 * COMPATIBILITY STORY. `proposed_role` is persisted at CREATE time, so every invitation minted before
 * the correction already carries 'beneficiary'. A provisioner keyed on that column would honour it
 * forever and outstanding invitations would keep manufacturing memberships. Keying on `kind` fixes new
 * and outstanding alike.
 */
import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";

const ROOT = path.resolve(__dirname, "..");
const read = (p: string) => readFileSync(path.join(ROOT, p), "utf8");

describe("0 · the firewall is reading the right files", () => {
  it("every file it reasons about exists and is nonempty", () => {
    // Asserting the scan set BEFORE evaluating any rule: a firewall that reads an empty string reports
    // whatever the matcher defaults to, and this repository has had 63 assertions pass against nothing.
    for (const f of [
      "db/functions/create_invitation.sql",
      "db/functions/provision_from_invitation.sql",
      "db/functions/accept_invitation.sql",
      "db/functions/bind_invitation_token.sql",
      "lib/invitations/accept.ts",
      "lib/invitations/bind.ts",
    ]) {
      expect(read(f).length, f).toBeGreaterThan(500);
    }
  });
});

describe("1 · a fiduciary invitation must NOT manufacture a disclosure class", () => {
  it("provision_from_invitation gates membership creation on the invitation KIND", () => {
    const src = read("db/functions/provision_from_invitation.sql");
    // The authoritative, immutable discriminator — not the persisted proposed_role. Tolerant of the
    // `coalesce(...)` wrapper so the null-safety fix does not read as the gate disappearing.
    expect(src).toMatch(/v_is_fiduciary\s*:=[^;]*v_inv\.kind\s+in\s*\(\s*'executor'\s*,\s*'trustee'\s*\)/);
    expect(src).toMatch(/if\s+not\s+v_is_fiduciary\s+then/);
    // It must NOT key off the persisted column, which is stale on every outstanding invitation.
    expect(src).not.toMatch(/v_is_fiduciary\s*:=[^;]*proposed_role/);
  });

  it("the kind gate is NULL-SAFE, so an unrecognised invitation provisions as before", () => {
    // `NULL in (...)` is NULL, and `not NULL` would SKIP the membership branch — an ordinary beneficiary
    // acceptance would then provision nothing. Production declares `invitations.kind` NOT NULL, but the
    // conservative default for an unrecognised invitation must be the pre-correction path, never the one
    // that creates no membership. A laxer test preamble caught this on the first run.
    const src = read("db/functions/provision_from_invitation.sql");
    expect(src).toMatch(/coalesce\(\s*v_inv\.kind\s+in\s*\([^)]*\)\s*,\s*false\s*\)/);
  });

  it("the membership insert is INSIDE the non-fiduciary branch", () => {
    const src = read("db/functions/provision_from_invitation.sql");
    const branch = src.indexOf("if not v_is_fiduciary then");
    const insert = src.indexOf("insert into public.estate_memberships");
    const elseAt = src.indexOf("\n  else\n", branch);
    expect(branch).toBeGreaterThanOrEqual(0);
    expect(insert).toBeGreaterThan(branch);
    expect(elseAt).toBeGreaterThan(insert); // the insert precedes the else, i.e. it is in the `if` arm
  });

  it("the beneficiary self-link is also inside the non-fiduciary branch", () => {
    const src = read("db/functions/provision_from_invitation.sql");
    const branch = src.indexOf("if not v_is_fiduciary then");
    const link = src.indexOf("update public.beneficiaries set user_id");
    const elseAt = src.indexOf("\n  else\n", branch);
    expect(link).toBeGreaterThan(branch);
    expect(elseAt).toBeGreaterThan(link);
  });

  it("the DESIGNATION is still stamped — the half that must survive the correction", () => {
    // A correction that removed both side effects would leave a fiduciary with NEITHER authority, which
    // is worse than the defect it replaced.
    const src = read("db/functions/provision_from_invitation.sql");
    expect(src).toMatch(/insert\s+into\s+public\.estate_designations/i);
    expect(src).toMatch(/v_inv\.kind\s+in\s*\(\s*'executor'\s*,\s*'trustee'\s*\)/);
    expect(src).toMatch(/source_invitation_id/); // provenance retained
  });

  it("no membership role is fabricated to carry fiduciary capacity", () => {
    const src = read("db/functions/provision_from_invitation.sql");
    // executor/trustee must never appear as a membership ROLE value being inserted.
    expect(src).not.toMatch(/role[^\n]*values[^\n]*'executor'/i);
    expect(src).not.toMatch(/'executor'::text\s*,\s*'approved'/i);
  });
});

describe("2 · the callers report a membership-less acceptance honestly", () => {
  it.each(["db/functions/accept_invitation.sql", "db/functions/bind_invitation_token.sql"])(
    "%s returns null role/status when there is no membership",
    (f) => {
      const src = read(f);
      const guards = src.match(/case when v_membership_id is null then null else/g) ?? [];
      // Both return sites — the main path and the idempotent self-heal branch.
      expect(guards.length).toBeGreaterThanOrEqual(4);
      expect(src).not.toMatch(/v_inv\.proposed_role::text,\s*'approved'::text/);
    }
  );

  it.each(["lib/invitations/accept.ts", "lib/invitations/bind.ts"])(
    "%s accepts a null membership instead of returning 502",
    (f) => {
      const src = read(f);
      // The old validator required all five fields to be strings; a fiduciary acceptance would have
      // been reported to the invitee as a server fault while the designation had committed.
      expect(src).not.toMatch(/typeof row\.membership_id !== "string" \|\|\s*\n\s*typeof row\.estate_id/);
      expect(src).toMatch(/membershipPresent/);
      expect(src).toMatch(/membershipAbsent/);
      // A partial membership (some fields present, some null) must still fail closed.
      expect(src).toMatch(/partial membership/);
    }
  );
});

describe("3 · create_invitation still persists a proposed_role, and that is deliberate", () => {
  it("the forced value remains, because the column is NOT NULL with a two-value CHECK", () => {
    // Documented at the site: removing the force without the provisioner gate would have provisioned a
    // PROFESSIONAL DELEGATE membership instead — a worse manufactured disclosure class.
    const src = read("db/functions/create_invitation.sql");
    expect(src).toMatch(/p_proposed_role\s*:=\s*'beneficiary'/);
    expect(src).toMatch(/INERT/);
  });

  it("the column really is constrained the way that reasoning claims", () => {
    // The justification above is only sound if the schema actually forbids a null or a third value.
    // Asserting it here means the comment cannot drift away from the constraint it depends on.
    const tbl = read("db/tables/invitations.sql");
    expect(tbl).toMatch(/proposed_role\s+text\s+not null/);
    expect(tbl).toMatch(/check \(proposed_role = any \(array\['beneficiary','professional_delegate'\]\)\)/);
  });
});
