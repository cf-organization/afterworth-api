/**
 * INVITATION CONTACT BINDING (migration 0067) — the contract, pinned statically.
 *
 * The behaviour is proven by `scripts/verifyResolveMembershipContactBinding.mjs` (a container built from
 * db/bootstrap + the migration; synthetic identities in every contact state; 29 assertions; wired into CI).
 * This suite pins what a text scan can prove without a database, so a later edit cannot quietly reopen
 * the gap:
 *
 *   · every invitation matcher reads `caller_verified_contacts()` and none reads a contact from `profiles`;
 *   · `resolve_membership` no longer consults `p_email` / `p_phone` for the pending list, while keeping
 *     its signature;
 *   · the helper releases a contact only with its GoTrue confirmation timestamp, and is the caller's own row;
 *   · db/functions (source of truth), the bundles that carry the callers, and the migration agree;
 *   · the harness stand-ins model the confirmation columns, and CI runs the container verification.
 */
import { describe, expect, test } from 'vitest';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const ROOT = join(__dirname, '..');
const read = (p: string) => readFileSync(join(ROOT, p), 'utf8');
const MIGRATION = 'db/migrations/0067_20261125_resolve_membership_contact_binding.sql';
const HELPER = 'db/functions/caller_verified_contacts.sql';
const CALLERS = ['db/functions/resolve_membership.sql', 'db/functions/accept_invitation.sql', 'db/functions/decline_invitation.sql', 'db/functions/bind_invitation_token.sql'];
const stripComments = (s: string) => s.replace(/--[^\n]*/g, '');
const bodyOf = (sql: string, name: string) =>
  (sql.match(new RegExp(`create\\s+or\\s+replace\\s+function\\s+public\\.${name}\\b[\\s\\S]*?\\$[a-z_]*\\$;`, 'i')) ?? [''])[0]
    .replace(/--[^\n]*/g, '')
    .replace(/\s+/g, ' ')
    .trim();

describe('0 · the scan set is real', () => {
  test('★ helper, four callers and the migration exist and are non-trivial', () => {
    for (const p of [MIGRATION, HELPER, ...CALLERS]) expect(read(p).length).toBeGreaterThan(300);
  });
  test('★ positive control — the profile-read matcher finds the old form when planted', () => {
    expect(/from\s+public\.profiles/i.test('select profiles.email into v from public.profiles where profiles.id = v_user;')).toBe(true);
  });
});

describe('1 · every matcher reads the verified contacts and no matcher reads a profile contact', () => {
  test.each(CALLERS)('★ %s', (p) => {
    const code = stripComments(read(p));
    expect(code).toMatch(/from\s+public\.caller_verified_contacts\(\)/);
    expect(code).not.toMatch(/from\s+public\.profiles/i);
    expect(code).not.toMatch(/profiles\.(email|phone)/i);
  });
  test('★ a NULL contact matches nothing: every comparison is guarded by "is not null" on the caller side', () => {
    for (const p of CALLERS) {
      const code = stripComments(read(p));
      expect(code).toMatch(/v_(user_)?email is not null[\s\S]{0,120}lower\(/);
      expect(code).toMatch(/v_(user_)?phone is not null[\s\S]{0,120}invitee_phone = v_(user_)?phone/);
      expect(code).not.toMatch(/coalesce\(v_user_(email|phone), ?''\)/); // the old "empty string matches" shape is gone
    }
  });
});

describe('2 · resolve_membership keeps its signature and ignores the supplied contacts', () => {
  test('★ signature unchanged; the pending predicate never references p_email / p_phone', () => {
    const src = read('db/functions/resolve_membership.sql');
    expect(src).toMatch(/function public\.resolve_membership\(p_email text, p_phone text\)/i);
    const body = bodyOf(src, 'resolve_membership');
    // the pending select reads `... into v_pending from public.invitations i where ...;` — slice that statement
    const at = body.indexOf('into v_pending');
    const pending = body.slice(at, body.indexOf(';', at));
    expect(pending.length).toBeGreaterThan(200);
    expect(pending).not.toMatch(/p_email|p_phone/);
    expect(pending).toMatch(/lower\(i\.invitee_email\) = v_email/);
    expect(pending).toMatch(/i\.invitee_phone = v_phone/);
    expect(body).toMatch(/from public\.caller_verified_contacts\(\) c/);
    // the response shape is untouched: the same three top-level keys
    expect(body).toMatch(/'primaryEstateContext', v_primary, 'pendingInvitations', v_pending, 'additionalContexts', v_additional/);
  });
});

describe('3 · the helper', () => {
  test('★ releases a contact only with its confirmation timestamp, for the caller\'s own live row, from auth.users', () => {
    const b = bodyOf(read(HELPER), 'caller_verified_contacts');
    expect(b).toMatch(/from auth\.users u where u\.id = v_user and u\.deleted_at is null/);
    expect(b).toMatch(/u\.email_confirmed_at is not null/);
    expect(b).toMatch(/u\.phone_confirmed_at is not null/);
    expect(b).toMatch(/security definer/i);
    expect(b).toMatch(/stable/);
    expect(b).not.toMatch(/profiles|auth\.jwt\(\)|p_email|p_phone/);
    expect(read(HELPER)).toMatch(/revoke execute on function public\.caller_verified_contacts\(\) from public, anon;/);
  });
});

describe('4 · sources agree: functions ↔ migration ↔ bundles', () => {
  /** The LATEST migration that defines a function is the one whose body must equal db/functions — a later
   *  migration may legitimately supersede 0067's body (0068 does so for resolve_membership, adding the cue). */
  const latestMigrationDefining = (name: string): string => {
    const files = readdirSync(join(ROOT, 'db/migrations')).filter((f) => /^\d{4}_.*\.sql$/.test(f)).sort();
    const defining = files.filter((f) => new RegExp(`create\\s+or\\s+replace\\s+function\\s+public\\.${name}\\s*\\(`, 'i').test(read(`db/migrations/${f}`)));
    expect(defining.length).toBeGreaterThan(0);
    return `db/migrations/${defining[defining.length - 1]}`;
  };
  test.each(['caller_verified_contacts', 'resolve_membership', 'accept_invitation', 'decline_invitation', 'bind_invitation_token'])('★ %s: db/functions === its latest migration (normalised); 0067 defines it', (name) => {
    const src = read(name === 'caller_verified_contacts' ? HELPER : `db/functions/${name}.sql`);
    expect(bodyOf(src, name).length).toBeGreaterThan(200);
    expect(bodyOf(read(MIGRATION), name).length).toBeGreaterThan(200); // 0067 carries every one of them
    expect(bodyOf(read(latestMigrationDefining(name)), name)).toBe(bodyOf(src, name));
  });
  test('★ the bundles that carry accept/bind also carry the helper, and their bodies match the sources', () => {
    for (const [bundle, fns] of [
      ['db/bundles/lifecycle_notifications_bundle.sql', ['caller_verified_contacts', 'accept_invitation', 'decline_invitation']],
      ['db/bundles/provisioning_correction_bundle.sql', ['caller_verified_contacts', 'accept_invitation', 'bind_invitation_token']],
    ] as const) {
      const b = read(bundle);
      for (const fn of fns) {
        const src = fn === 'caller_verified_contacts' ? read(HELPER) : read(`db/functions/${fn}.sql`);
        expect(bodyOf(b, fn)).toBe(bodyOf(src, fn));
      }
    }
  });
  test('★ the migration changes no table', () => {
    expect(stripComments(read(MIGRATION))).not.toMatch(/alter\s+table|create\s+table|add\s+column/i);
  });
});

describe('5 · harness and CI', () => {
  test('★ both auth.users stand-ins model the confirmation columns the helper reads', () => {
    for (const p of ['db/tests/preamble_real_auth.sql', 'db/bootstrap/testing/PLATFORM_SHIM_NOT_PRODUCTION.sql']) {
      const s = read(p);
      for (const col of ['email_confirmed_at', 'phone_confirmed_at', 'deleted_at']) expect(s).toContain(col);
    }
  });
  test('★ the lifecycle suite confirms the auth.users address of each accepting/declining fixture user', () => {
    const s = read('db/tests/lifecycle_notification_authorization.sql');
    expect((s.match(/update auth\.users set email = '[^']+', email_confirmed_at = now\(\)/g) ?? []).length).toBe(2);
  });
  test('★ CI runs the container verification and the script refuses a remote target', () => {
    expect(read('.github/workflows/ci.yml')).toMatch(/npm run verify:contact-binding/);
    expect(JSON.parse(read('package.json')).scripts['verify:contact-binding']).toBe('node scripts/verifyResolveMembershipContactBinding.mjs');
    const script = read('scripts/verifyResolveMembershipContactBinding.mjs');
    expect(script).toMatch(/REFUSED/);
    expect(script).not.toMatch(/process\.env\.|SUPABASE_URL|SERVICE_ROLE/); // reads no environment at all
  });
});
