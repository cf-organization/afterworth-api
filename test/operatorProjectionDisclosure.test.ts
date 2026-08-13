/**
 * PHASE 11-K — the operator projections disclose the WORKFLOW and never the ESTATE.
 *
 * ★ WHY A SOURCE AUDIT AND NOT ONLY A BEHAVIOUR TEST. What these two routines return is decided
 * entirely by the columns their bodies name. A runtime test proves what the CURRENT fixtures happen
 * to contain; it cannot prove that a future edit adding `e.jurisdiction`, `o.recipient`, or a join
 * to `estate_assets` would be caught — because a fixture with no assets returns no assets either
 * way. The absences here are structural, so they are pinned structurally.
 *
 * ★ AND THE CONTROLS COME FIRST. Every rule below runs against a source file that must exist, be
 * non-empty, and demonstrably contain things the matchers CAN find. A scanner that resolved the
 * wrong path would otherwise report a flawless disclosure posture about an empty string — the
 * Dashboard near-miss, where 63 assertions passed against nothing.
 */
import * as fs from "node:fs";
import * as path from "node:path";
import { describe, expect, it } from "vitest";

const ROOT = path.resolve(__dirname, "..");
const SOURCE = path.join(ROOT, "db/functions/operator_console.sql");

/**
 * Comments stripped, string literals KEPT. Both halves matter and in opposite directions: the file's
 * header prose deliberately ENUMERATES the forbidden words ("no asset, no valuation, no
 * beneficiary…"), so leaving comments in would make every absence rule fail on documentation. And
 * the column names this audit hunts are bare SQL identifiers rather than literals, so stripping
 * strings would remove nothing it needs — while stripping them by reflex is how a hex-colour rule
 * once matched a string-stripped view and could never have found anything.
 */
const stripComments = (raw: string): string =>
  raw
    .split("\n")
    .filter((l) => !/^\s*--/.test(l))
    .map((l) => l.replace(/\s--.*$/, ""))
    .join("\n");

const raw = fs.readFileSync(SOURCE, "utf8");
const code = stripComments(raw);

/** The body of one function, so a rule can name WHICH projection it governs. */
function bodyOf(fn: string): string {
  const start = code.indexOf(`create or replace function public.${fn}`);
  if (start < 0) return "";
  const rest = code.slice(start);
  const end = rest.indexOf("$function$;");
  return end < 0 ? rest : rest.slice(0, end);
}

describe("0 · the audit is reading something", () => {
  it("resolves a non-empty source file", () => {
    expect(fs.existsSync(SOURCE)).toBe(true);
    expect(code.length).toBeGreaterThan(2000);
  });

  it("finds BOTH projections (positive control)", () => {
    expect(bodyOf("admin_list_death_verification_cases").length).toBeGreaterThan(500);
    expect(bodyOf("admin_get_death_verification_case").length).toBeGreaterThan(500);
  });

  it("comment stripping removed the prose and kept the code", () => {
    // The header prose lists the forbidden vocabulary. If stripping failed, every absence rule
    // below would fail on documentation — and if stripping were too greedy, the code would vanish
    // and every rule would pass vacuously. This asserts both directions at once.
    expect(raw).toContain("NO OWNER EMAIL ADDRESS");
    expect(code).not.toContain("NO OWNER EMAIL ADDRESS");
    expect(code).toContain("admin_require_gate()");
    expect(code).toContain("death_verification_cases");
  });
});

describe("1 · the gate is inside the definer, on both doors", () => {
  for (const fn of ["admin_list_death_verification_cases", "admin_get_death_verification_case"]) {
    it(`${fn} runs admin_require_gate before it reads anything`, () => {
      const body = bodyOf(fn);
      const gate = body.indexOf("admin_require_gate()");
      expect(gate).toBeGreaterThan(-1);

      /**
       * ★ MATCH THE READ, NOT THE TOKEN. The first draft searched for the bare table names and
       * failed on both routines for reasons that were not reads at all: `death_verification_cases`
       * is a substring of `admin_list_death_verification_cases` (the function's own NAME, at
       * offset 45), and `death_verification_cases%rowtype` is a DECLARE-block type annotation.
       * Neither reads a row. A `from public.<table>` clause does.
       */
      const reads = [...body.matchAll(/\bfrom\s+public\.(death_verification_cases|death_verification_evidence|estate_lifecycle|owner_notice_outbox|release_authorizations)\b/g)];
      expect(reads.length, `${fn} reads no lifecycle table — the matcher found nothing`).toBeGreaterThan(0);
      expect(gate).toBeLessThan(reads[0].index!);
    });

    it(`${fn} is granted to authenticated and revoked from anon`, () => {
      expect(code).toMatch(new RegExp(`revoke execute on function public\\.${fn}[\\s\\S]{0,200}?from public, anon`));
      expect(code).toMatch(new RegExp(`grant\\s+execute on function public\\.${fn}[\\s\\S]{0,200}?to authenticated`));
    });
  }
});

describe("2 · no estate CONTENT reaches an operator", () => {
  /**
   * ★ EACH ENTRY IS A TABLE OR COLUMN THAT EXISTS IN THIS SCHEMA. A forbidden list of words that
   * name nothing real would pass forever and prove nothing — so these are drawn from the actual
   * disclosure surfaces Phase 9/10 built, which is exactly what a widening edit would reach for.
   */
  const FORBIDDEN_SURFACES = [
    "estate_assets",
    "normalized_assets",
    "get_estate_net_worth",
    "access_grants",
    "estate_memberships",
    "estate_designations",
    "encrypted_instructions",
    "claim_packets",
    "list_estate_members",
    "get_estate_discovery",
    "estate_release_state",
    "release_condition_satisfied",
  ];

  for (const surface of FORBIDDEN_SURFACES) {
    it(`neither projection names ${surface}`, () => {
      expect(code).not.toContain(surface);
    });
  }

  it("names no storage path, byte, or signed URL", () => {
    for (const forbidden of ["storage_path", "storage_object", "createSignedUrl", "signed_url", "object_name"]) {
      expect(code).not.toContain(forbidden);
    }
  });

  it("reads documents for METADATA only", () => {
    const body = bodyOf("admin_get_death_verification_case");
    // The join exists (positive control) …
    expect(body).toContain("public.documents d");
    // … and takes only the three metadata columns the review queue needs.
    expect(body).toContain("d.title");
    expect(body).toContain("d.doc_type");
    expect(body).toContain("d.created_at");
    expect(body).not.toMatch(/\bd\.storage_path\b/);
    expect(body).not.toMatch(/\bd\.subtype\b/);
    expect(body).not.toMatch(/\bd\.sensitivity\b/);
  });
});

describe("3 · the owner's address is never projected", () => {
  it("the case file reads the outbox but never selects the recipient", () => {
    const body = bodyOf("admin_get_death_verification_case");
    // POSITIVE CONTROL: it genuinely reads the outbox, so the absence below is meaningful.
    expect(body).toContain("public.owner_notice_outbox o");
    expect(body).toContain("'status',        o.status");
    // THE RULE.
    expect(body).not.toMatch(/\bo\.recipient\b/);
  });

  it("the queue answers resolvability as a BOOLEAN, never an address", () => {
    const body = bodyOf("admin_list_death_verification_cases");
    expect(body).toContain("owner_channel_resolvable");
    // It may ask auth.users whether an address exists…
    expect(body).toContain("btrim(coalesce(u.email, '')) <> ''");
    // …and must never return one. `u.email` may appear only inside that emptiness test.
    const selectsEmail = /select[\s\S]{0,400}?\bu\.email\b(?![\s\S]{0,40}?<> '')/.test(body);
    expect(selectsEmail).toBe(false);
  });

  it("neither projection returns an owner email column", () => {
    expect(code).not.toMatch(/owner_email/);
    expect(code).not.toMatch(/recipient\s+text/);
  });
});

describe("4 · the console cannot disagree with the door", () => {
  it("the required level is re-derived LIVE, as the decision routine derives it", () => {
    // `admin_decide_death_verification_case` calls required_verification_level at decision time.
    // A console showing the initiation SNAPSHOT as the bar would offer a verify the routine refuses.
    expect(bodyOf("admin_list_death_verification_cases")).toContain("public.required_verification_level(c.estate_id)");
    expect(bodyOf("admin_get_death_verification_case")).toContain("public.required_verification_level(v_c.estate_id)");
  });

  it("the case file labels the snapshot as a snapshot rather than presenting one level", () => {
    const body = bodyOf("admin_get_death_verification_case");
    expect(body).toContain("'required_level_at_initiation'");
    expect(body).toContain("'required_level_live'");
  });

  it("window elapse uses STRICT >, matching authorize_release exactly", () => {
    const body = bodyOf("admin_get_death_verification_case");
    // A console rounding the other way would offer a release the routine refuses, one second
    // before the owner's tie-break ends.
    expect(body).toMatch(/now\(\)\s*>\s*v_l\.owner_notified_at\s*\+\s*v_duration/);
    expect(body).not.toMatch(/now\(\)\s*>=\s*v_l\.owner_notified_at/);
  });

  it("the window duration is read live, never stamped or hardcoded", () => {
    const body = bodyOf("admin_get_death_verification_case");
    expect(body).toContain("public.challenge_window_duration()");
    expect(body).not.toMatch(/interval '7 days'/);
  });
});

describe("5 · reviewer A is derived from the server, never supplied", () => {
  it("viewer_is_reviewer_a is computed from auth.uid() inside the definer", () => {
    const body = bodyOf("admin_get_death_verification_case");
    expect(body).toContain("v_uid := auth.uid()");
    expect(body).toContain("'viewer_is_reviewer_a', v_c.decided_by is not null and v_c.decided_by = v_uid");
  });

  it("reviewer A is the case decider, matching authorize_release's derivation", () => {
    const body = bodyOf("admin_get_death_verification_case");
    expect(body).toContain("'reviewer_a',           v_c.decided_by");
    // The projection takes NO reviewer parameter — a client cannot nominate one.
    expect(code).toContain("admin_get_death_verification_case(p_case uuid)");
  });
});

describe("6 · the projections are reads, and only reads", () => {
  it("neither writes any table", () => {
    expect(code).not.toMatch(/\binsert\s+into\b/i);
    expect(code).not.toMatch(/\bupdate\s+public\./i);
    expect(code).not.toMatch(/\bdelete\s+from\b/i);
  });

  it("neither CALLS a transition, decision, dispatch, window or release routine", () => {
    /**
     * ★ A TOKEN MATCH IS NOT A USAGE MATCH. The first draft searched for the bare names and fired
     * on `authorize_release` — which appears in this file only inside a `comment on function`
     * string literal, explaining that the door re-checks reviewer distinctness independently.
     * Documenting a routine is not calling it. A CALL is `public.<name>(`.
     */
    const DOORS = [
      "apply_estate_lifecycle_transition",
      "admin_decide_death_verification_case",
      "admin_set_attained_verification_level",
      "dispatch_owner_safety_notice",
      "begin_challenge_window",
      "authorize_release",
      "challenge_death_process",
    ];

    // POSITIVE CONTROL: the call matcher must be able to find a call that IS present, or its
    // silence below would prove nothing about the doors.
    expect(/\bpublic\.required_verification_level\s*\(/.test(code)).toBe(true);
    expect(/\bpublic\.challenge_window_duration\s*\(/.test(code)).toBe(true);

    for (const door of DOORS) {
      expect(new RegExp(`\\bpublic\\.${door}\\s*\\(`).test(code), `${door} is called`).toBe(false);
      expect(new RegExp(`\\bperform\\s+${door}\\s*\\(`).test(code), `${door} is performed`).toBe(false);
    }
  });

  it("both are declared STABLE, which forbids a write at the engine level", () => {
    const decls = code.match(/\bstable\b/g) ?? [];
    expect(decls.length).toBe(2);
  });
});
