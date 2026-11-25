/**
 * MEMBERSHIP INVITATION CUE (migration 0067) — the contract, pinned statically.
 *
 * The live behaviour is proven by `scripts/captureMembershipInvitationCue.mjs` (a container built from
 * db/bootstrap + the migration; every case captured and asserted; four positive-control mutants recorded
 * in the PR). This suite pins what a text scan CAN prove without a database, so a later edit cannot
 * quietly widen the release:
 *
 *   · the cue is bound to THIS membership (`source_invitation_id`), THIS estate and THIS caller's own
 *     acceptance (`accepted_by = v_user`, status 'accepted'), and only where the recipient already saw
 *     the name (`showInviterName`);
 *   · the value passes the one server sanitizer before serialization, and that sanitizer mirrors the
 *     client rule (`\S@\S`) — the two must never disagree;
 *   · nothing else rides along: no profile lookup, no approval date, no contact detail, no neutral
 *     "An estate owner" substitute, no cue on the primary (owned) context;
 *   · db/functions (source of truth) and the migration carry the SAME bodies (the shadow-copy rule);
 *   · the captured responses on disk say what the script observed — a fixture that drifted from the
 *     contract would be caught here, and the fixtures contain no address.
 */
import { describe, expect, test } from 'vitest';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const ROOT = join(__dirname, '..');
const read = (p: string) => readFileSync(join(ROOT, p), 'utf8');
const MIGRATION = 'db/migrations/0067_20261125_membership_invitation_cue.sql';
const RESOLVE = 'db/functions/resolve_membership.sql';
const SANITIZER = 'db/functions/safe_inviter_display_name.sql';
const FIXTURES = 'test/fixtures/membershipInvitationCue';

/** The function body, comments and whitespace normalised — the same normalisation verifySqlAuthorization uses. */
const bodyOf = (sql: string, name: string) =>
  (sql.match(new RegExp(`create\\s+or\\s+replace\\s+function\\s+public\\.${name}\\b[\\s\\S]*?\\$[a-z_]*\\$;`, 'i')) ?? [''])[0]
    .replace(/--[^\n]*/g, '')
    .replace(/\s+/g, ' ')
    .trim();

describe('0 · the scan set exists', () => {
  test('★ all three sources are present and non-trivial', () => {
    for (const p of [MIGRATION, RESOLVE, SANITIZER]) expect(read(p).length).toBeGreaterThan(400);
    expect(bodyOf(read(RESOLVE), 'resolve_membership').length).toBeGreaterThan(400);
    expect(bodyOf(read(SANITIZER), 'safe_inviter_display_name').length).toBeGreaterThan(100);
  });
});

describe('1 · the cue is scoped to the recipient, the membership and the estate', () => {
  const cue = () => {
    const body = read(RESOLVE);
    const start = body.indexOf("'inviterDisplayName', (");
    expect(start).toBeGreaterThan(0);
    return body.slice(start, body.indexOf(')), \'[]\'::jsonb)', start));
  };
  test('★ bound to this membership\'s own invitation, this estate, and this caller\'s acceptance', () => {
    const c = cue();
    expect(c).toMatch(/i\.id = m\.source_invitation_id/);
    expect(c).toMatch(/i\.estate_id = m\.estate_id/);
    expect(c).toMatch(/i\.accepted_by = v_user/);
    expect(c).toMatch(/i\.status = 'accepted'/);
    expect(c).toMatch(/preview_visibility->>'showInviterName'/);
  });
  test('★ the stored value passes the server sanitizer before serialization — never the raw column', () => {
    const c = cue();
    expect(c).toMatch(/public\.safe_inviter_display_name\(i\.inviter_display_name\)/);
    expect(c).not.toMatch(/'inviterDisplayName',\s*i\.inviter_display_name/);
  });
  test('★ the cue lives only in the ADDITIONAL (non-owned) contexts, not the primary one', () => {
    const body = read(RESOLVE);
    const primary = body.slice(body.indexOf('-- Primary estate context'), body.indexOf('-- Pending invitations'));
    expect(primary).not.toContain('inviterDisplayName');
    expect(body.slice(body.indexOf('-- Additional contexts'))).toContain("'inviterDisplayName'");
  });
  test('★ nothing rides along: no profile lookup for a name, no approval date, no contact, no neutral substitute', () => {
    const b = bodyOf(read(RESOLVE), 'resolve_membership');
    // the whole function: no profile join for a name, no neutral substitute, no profile name column
    expect(b).not.toMatch(/public\.profiles/i);
    expect(b).not.toMatch(/An estate owner/);
    expect(b).not.toMatch(/full_name/);
    // the ADDITIONAL-contexts section (the only place the cue is built): no date, no contact, no hint
    const additional = b.slice(b.indexOf("'isPrimaryEstate', false"));
    expect(additional.length).toBeGreaterThan(200); // positive control: the slice found the section
    expect(additional).toContain("'inviterDisplayName'");
    expect(additional).not.toMatch(/approved_at|accepted_at|approvedAt|acceptedAt|created_at/);
    expect(additional).not.toMatch(/invitee_email|invitee_phone|email_hint|phone_hint/i);
  });
});

describe('2 · the sanitizer mirrors the client rule', () => {
  test('★ email-shaped (\\S@\\S), blank and over-long values become NULL; nothing is substituted', () => {
    const b = bodyOf(read(SANITIZER), 'safe_inviter_display_name');
    expect(b).toContain("~ '\\S@\\S'");
    expect(b).toContain("when v = '' then null");
    expect(b).toContain('> 200 then null');
    // the trim set is JavaScript's, not btrim's: NBSP, the Zs block, the line terminators and the BOM
    for (const cp of ['\\u00a0', '\\u2000-\\u200a', '\\u2028', '\\u2029', '\\u202f', '\\u205f', '\\u3000', '\\ufeff']) expect(b).toContain(cp);
    expect(b).not.toMatch(/btrim\(/);
    expect(b).toMatch(/strict/);
    expect(b).not.toMatch(/security definer/i); // a pure sanitizer needs no elevated rights
    expect(b).not.toMatch(/An estate owner|coalesce\(/);
  });
  test('★ the SQL-decided assertion file exists, is non-vacuous, and the capture script runs it', () => {
    const sql = read('db/tests/safe_inviter_display_name_assertions.sql');
    expect(sql).toMatch(/is not distinct from r\.expected/); // compared INSIDE SQL, never by a client trim
    expect((sql.match(/^\s+\('/gm) ?? []).length).toBeGreaterThanOrEqual(20); // at least twenty cases
    for (const label of ['tabs and newlines only', 'nonbreaking spaces only', 'valid name padded with NBSP', 'address-shaped', 'exactly 200 characters', '201 characters']) expect(sql).toContain(label);
    expect(read('scripts/captureMembershipInvitationCue.mjs')).toContain('db/tests/safe_inviter_display_name_assertions.sql');
  });

  test('★ positive control — the regex this pins is the one the mobile model uses verbatim', () => {
    // The client: `if (/\S@\S/.test(trimmed)) return null;` (features/invitations/model.ts). Same shape, same outcome.
    const clientRule = /\S@\S/;
    expect(clientRule.test('dana@example.test')).toBe(true);
    expect(clientRule.test('Dana Hartley')).toBe(false);
    expect(clientRule.test('@')).toBe(false);
  });
});

describe('3 · source of truth and migration carry the same bodies', () => {
  test('★ resolve_membership: db/functions === migration 0067 (normalised)', () => {
    expect(bodyOf(read(MIGRATION), 'resolve_membership')).toBe(bodyOf(read(RESOLVE), 'resolve_membership'));
  });
  test('★ safe_inviter_display_name: db/functions === migration 0067 (normalised)', () => {
    expect(bodyOf(read(MIGRATION), 'safe_inviter_display_name')).toBe(bodyOf(read(SANITIZER), 'safe_inviter_display_name'));
  });
  test('★ both functions are granted to authenticated and revoked from public/anon, in both places', () => {
    for (const p of [MIGRATION, RESOLVE]) expect(read(p)).toMatch(/revoke execute on function public\.resolve_membership\(text, text\) from public, anon;/);
    for (const p of [MIGRATION, SANITIZER]) expect(read(p)).toMatch(/revoke execute on function public\.safe_inviter_display_name\(text\) from public, anon;/);
    for (const p of [MIGRATION, RESOLVE]) expect(read(p)).toMatch(/grant\s+execute on function public\.resolve_membership\(text, text\) to authenticated;/);
  });
  test('★ the migration changes no table', () => {
    const m = read(MIGRATION).replace(/--[^\n]*/g, '');
    expect(m).not.toMatch(/alter\s+table|create\s+table|add\s+column/i);
  });
});

describe('4 · the captured responses say what the contract says', () => {
  type Ctx = { estateId: string; estateDisplayName: string; roleWithinEstate: string; inviterDisplayName?: string | null };
  type Resp = { primaryEstateContext: Record<string, unknown>; additionalContexts: Ctx[] };
  const load = (f: string): Resp => JSON.parse(read(join(FIXTURES, f))) as Resp;

  test('★ the fixture set is non-empty and address-free', () => {
    const files = readdirSync(join(ROOT, FIXTURES)).filter((f) => f.endsWith('.json'));
    expect(files.length).toBe(4);
    for (const f of files) expect(read(join(FIXTURES, f))).not.toMatch(/\S@\S/);
  });
  test('★ six "My Estate" memberships: two distinct cues, one identical pair, three nulls; the primary context carries no key', () => {
    const r = load('beneficiary-six-my-estates.json');
    expect(r.additionalContexts).toHaveLength(6);
    expect(r.additionalContexts.every((c) => c.estateDisplayName === 'My Estate' && c.roleWithinEstate === 'beneficiary')).toBe(true);
    expect(r.additionalContexts.every((c) => 'inviterDisplayName' in c)).toBe(true);
    const cues = r.additionalContexts.map((c) => c.inviterDisplayName);
    expect(cues.filter((c) => c === null)).toHaveLength(3);
    expect(cues.filter((c) => c === 'Dana Hartley')).toHaveLength(2); // the identical pair, unresolved by design
    expect(cues.filter((c) => c === 'Priya Okafor')).toHaveLength(1);
    expect('inviterDisplayName' in r.primaryEstateContext).toBe(false);
  });
  test('★ another caller sees only its own cue, from its own invitation', () => {
    const r = load('another-caller.json');
    expect(r.additionalContexts).toHaveLength(1);
    expect(r.additionalContexts[0]!.inviterDisplayName).toBe('Dana Hartley');
  });
  test('★ mismatched or unlinked memberships carry null; the untouched one keeps its cue', () => {
    const r = load('beneficiary-mismatched-links.json');
    const cues = r.additionalContexts.map((c) => c.inviterDisplayName);
    expect(cues.filter((c) => c === 'Dana Hartley')).toHaveLength(1); // the untouched Dana membership
    expect(cues.filter((c) => c === null)).toHaveLength(5); // Priya (cross-estate link), Dana2 (unlinked) + the three never-cued
  });
  test('★ after revocation the membership is absent altogether — no cue without access', () => {
    // Captured AFTER the mismatch step (Priya's link repointed, Dana2 unlinked) and after revoking the Dana
    // membership: six contexts become five, and the only remaining cue-bearing membership (Dana) is gone.
    const r = load('beneficiary-after-revocation.json');
    expect(r.additionalContexts).toHaveLength(5);
    expect(r.additionalContexts.every((c) => c.inviterDisplayName === null)).toBe(true);
    expect(r.additionalContexts.some((c) => c.inviterDisplayName === 'Dana Hartley')).toBe(false);
  });
});
