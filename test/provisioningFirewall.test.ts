/**
 * PHASE 11-MB · THE PROVISIONING FIREWALL — A TEST WRITTEN TO BE FLIPPED.
 *
 * ★ THIS ASSERTS A DEFECT IS STILL PRESENT, ON PURPOSE, AND THAT IS NOT A CONTRADICTION.
 *
 * Executor/trustee provisioning forces the invitation's `proposed_role` to `beneficiary`, which
 * manufactures a disclosure class as a side effect of granting workflow capacity. That is the defect
 * Phase 11-MA diagnosed and 11-MC will correct. It must NOT be corrected yet, because the ordering is
 * the safety property:
 *
 *   1. deploy fiduciary DISCOVERY            ← done (get_my_fiduciary_estates)
 *   2. teach the mobile selector to consume it
 *   3. THEN stop forcing the role
 *
 * Reversed, a newly provisioned fiduciary gets a designation, NO membership, and an estate the mobile
 * app cannot find — correctly authorized and permanently unable to reach the workflow. `resolve_membership`
 * enumerates `estate_memberships` alone, so today the forced membership is the ONLY thing making the
 * estate discoverable.
 *
 * So this test is a tripwire against doing step 3 early. When 11-MC lands, it is EXPECTED to fail, and
 * the correct response is to invert it — not to delete it. An inverted assertion then guards the other
 * direction: that the forced role never comes back.
 */
import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";

const ROOT = path.resolve(__dirname, "..");
const read = (p: string) => readFileSync(path.join(ROOT, p), "utf8");

describe("0 · the firewall is reading the right files", () => {
  it("both provisioning files exist and are nonempty", () => {
    // Asserting the scan set BEFORE evaluating any rule: a firewall that reads an empty string
    // reports whatever the matcher's default is, and 63 assertions once passed against nothing here.
    expect(read("db/functions/create_invitation.sql").length).toBeGreaterThan(500);
    expect(read("db/functions/provision_from_invitation.sql").length).toBeGreaterThan(500);
  });
});

describe("1 · executor/trustee provisioning is STILL in the pre-correction shape", () => {
  it("create_invitation still FORCES proposed_role to beneficiary", () => {
    const src = read("db/functions/create_invitation.sql");
    // The exact line 11-MA identified. Whitespace-tolerant so a reformat does not read as a fix.
    expect(src).toMatch(/p_kind\s+in\s*\(\s*'executor'\s*,\s*'trustee'\s*\)\s*then\s*\n?\s*p_proposed_role\s*:=\s*'beneficiary'/);
  });

  it("provision_from_invitation still inserts a membership at the invitation's proposed_role", () => {
    const src = read("db/functions/provision_from_invitation.sql");
    expect(src).toMatch(/insert\s+into\s+public\.estate_memberships/i);
    expect(src).toMatch(/v_inv\.proposed_role/);
  });

  it("provision_from_invitation still stamps the designation (this half is CORRECT and must survive)", () => {
    // The correction removes the membership side effect. It must not disturb the designation, or a
    // fiduciary would end up with neither authority — a worse outcome than the defect.
    const src = read("db/functions/provision_from_invitation.sql");
    expect(src).toMatch(/insert\s+into\s+public\.estate_designations/i);
    expect(src).toMatch(/v_inv\.kind\s+in\s*\(\s*'executor'\s*,\s*'trustee'\s*\)/);
  });
});

describe("2 · the discovery routine that must ship FIRST is present in source", () => {
  it("get_my_fiduciary_estates exists, is self-scoped, and is anon-revoked", () => {
    const src = read("db/functions/fiduciary_estate_discovery.sql");
    expect(src).toMatch(/create or replace function public\.get_my_fiduciary_estates\(\)/);
    expect(src).toMatch(/d\.user_id = auth\.uid\(\)/);
    expect(src).toMatch(/revoke execute on function public\.get_my_fiduciary_estates\(\) from public, anon;/);
  });

  it("it is offered as its own deploy artifact, separate from any provisioning change", () => {
    // Two artifacts is what makes the ordering enforceable rather than remembered.
    const bundle = read("db/bundles/fiduciary_discovery_bundle.sql");
    expect(bundle).toMatch(/get_my_fiduciary_estates/);
    expect(bundle).not.toMatch(/p_proposed_role\s*:=\s*'beneficiary'/);
    expect(bundle).not.toMatch(/create or replace function public\.create_invitation/);
  });
});
