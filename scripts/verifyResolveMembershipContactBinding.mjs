#!/usr/bin/env node
/**
 * INVITATION CONTACT BINDING — local verification (migration 0067).
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * Builds a throwaway Postgres container from db/bootstrap plus the binding migration, seeds SYNTHETIC
 * identities (fixed uuids, example.test addresses, invented phone numbers — nobody real) in every
 * contact state GoTrue can hold, and proves that each caller is matched only to invitations addressed
 * to THEIR OWN VERIFIED contacts — through the pending list (resolve_membership), accept, decline and
 * token binding — and that the resolve parameters widen nothing. Legitimate owner management and the
 * unauthenticated token preview are asserted unchanged.
 *
 * ★ IT CANNOT BE POINTED AT A REAL DATABASE. No --database-url, no project ref, no .env read; it talks
 *   only to the container it created, through `docker exec`, and removes it in `finally`.
 * ★ auth.uid() IS OVERRIDDEN TO READ A SESSION SETTING — verification-only, NOT production DDL — so each
 *   call runs as a chosen synthetic user. The override is applied AFTER the bootstrap and the migration.
 * ★ EXITS 2 WITHOUT DOCKER. A runner that cannot execute this fails rather than passing.
 *
 * Usage: node scripts/verifyResolveMembershipContactBinding.mjs [--keep]
 */
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

for (const f of ['--database-url', '--db-url', '--project-ref', '--linked', '--remote', '--production', '--host', '--dsn']) {
  if (process.argv.some((a) => a.split('=')[0] === f)) { console.error(`REFUSED — ${f} is not accepted. This verification only ever targets a container it creates itself.`); process.exit(2); }
}
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const BOOT = join(ROOT, 'db/bootstrap');
const migArg = process.argv.indexOf('--migration');
// --migration <path> is for BEFORE/AFTER comparison against an older copy of this same migration (verification-only).
const MIG = migArg >= 0 && process.argv[migArg + 1] ? resolve(process.argv[migArg + 1]) : join(ROOT, 'db/migrations/0067_20261125_resolve_membership_contact_binding.sql');
const CONTAINER = `aw-contact-binding-${process.pid}`;
const KEEP = process.argv.includes('--keep');
const say = (m) => console.log(m);
const rm = () => { if (!KEEP) spawnSync('docker', ['rm', '-f', CONTAINER], { stdio: 'ignore' }); };
const psql = (sql) => spawnSync('docker', ['exec', '-i', CONTAINER, 'psql', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-q', '-f', '-'], { input: sql, encoding: 'utf8' });
const q = (sql) => { const r = spawnSync('docker', ['exec', '-i', CONTAINER, 'psql', '-U', 'postgres', '-tAc', sql], { encoding: 'utf8' }); if (r.status !== 0) throw new Error(`query failed: ${sql.slice(0, 120)}\n${r.stderr}`); return r.stdout.trim().split('\n').pop() ?? ''; };
const must = (r, what) => { if (r.status !== 0) throw new Error(`${what} failed:\n${(r.stderr || '').slice(0, 1200)}`); };
const as = (uid, sql) => psql(`select set_config('app.uid', '${uid}', false);\n${sql}`);
const asQ = (uid, sql) => q(`select set_config('app.uid', '${uid}', false); ${sql}`);
const refused = (r, sentinel) => r.status !== 0 && (r.stderr || '').includes(sentinel);

let failures = 0;
const check = (cond, label) => { if (cond) say(`  ✓ ${label}`); else { failures += 1; say(`  ✗ ${label}`); } };

// ── synthetic identities ──────────────────────────────────────────────────────────────────────────
const U = {
  OWNER: '0a000000-0000-4000-8000-00000000000a', // confirmed email; owns estate 1; invites everyone
  OWNER2: '0a000000-0000-4000-8000-00000000000b', // confirmed email; owns estate 2 (one active invitation per role per estate)
  A:     '0a000000-0000-4000-8000-0000000000a1', // confirmed email
  B:     '0a000000-0000-4000-8000-0000000000b2', // UNCONFIRMED email
  C:     '0a000000-0000-4000-8000-0000000000c3', // confirmed phone only, no email
  G:     '0a000000-0000-4000-8000-0000000000d4', // the SAME phone as C, unconfirmed; confirmed email
  D:     '0a000000-0000-4000-8000-0000000000e5', // confirmed email, but a profile edited to an INVITED address nobody has signed up with
  E:     '0a000000-0000-4000-8000-0000000000f6', // confirmed email, account deleted
  F:     '0a000000-0000-4000-8000-000000000007', // another caller, no invitations
  H:     '0a000000-0000-4000-8000-000000000008', // confirmed email AND confirmed phone
  J:     '0a000000-0000-4000-8000-000000000009', // confirmed phone stored by Auth as international DIGITS (no "+")
  K:     '0a000000-0000-4000-8000-00000000000e', // confirmed phone (digits); invitations to it written WITHOUT "+", malformed, or a different number
};
const PHONE_C = '+15555550100';
const PHONE_H = '+15555550200';
const PHONE_J_AUTH = '15555550400'; // as GoTrue stores it
const PHONE_J_INV = '+15555550400'; // as the owner path writes it
const PHONE_K_AUTH = '15555550500';
const PHONE_X = '+15555550300'; // invited, held by no confirmed account; G will claim it in a PROFILE only
const EMAIL_X = 'invitee-x@example.test'; // invited, held by no account; D will claim it in a PROFILE only
/** [email, email_confirmed, phone, phone_confirmed, deleted] — auth.users is GoTrue's; profiles mirror the sign-up copy. */
const AUTH = {
  OWNER: ['owner@example.test', true, null, false, false],
  OWNER2: ['owner2@example.test', true, null, false, false],
  A: ['a@example.test', true, null, false, false],
  B: ['b@example.test', false, null, false, false],
  C: [null, false, PHONE_C, true, false],
  G: ['g@example.test', true, PHONE_C, false, false],
  D: ['d@example.test', true, null, false, false],
  E: ['e@example.test', true, null, false, true],
  F: ['f@example.test', true, null, false, false],
  H: ['h@example.test', true, PHONE_H, true, false],
  J: [null, false, PHONE_J_AUTH, true, false],
  K: [null, false, PHONE_K_AUTH, true, false],
};
const lit = (v) => (v == null ? 'null' : `'${v}'`);

try {
  if (spawnSync('docker', ['info'], { stdio: 'ignore' }).status !== 0) {
    console.error('✗ CANNOT VERIFY — Docker is not available. The binding must be EXECUTED, not described.');
    process.exit(2);
  }
  rm();
  must(spawnSync('docker', ['run', '-d', '--name', CONTAINER, '-e', 'POSTGRES_PASSWORD=verify', 'postgres:16'], { encoding: 'utf8' }), 'docker run');
  for (let i = 0; i < 60; i++) { if (spawnSync('docker', ['exec', CONTAINER, 'pg_isready', '-U', 'postgres'], { stdio: 'ignore' }).status === 0) break; await new Promise((r) => setTimeout(r, 1000)); }
  must(psql(readFileSync(join(BOOT, 'testing/PLATFORM_SHIM_NOT_PRODUCTION.sql'), 'utf8')), 'platform shim');
  const phases = readdirSync(BOOT).filter((f) => /^\d+_.*\.sql$/.test(f)).sort((a, b) => Number(a.split('_')[0]) - Number(b.split('_')[0]));
  for (const f of phases) must(psql(readFileSync(join(BOOT, f), 'utf8')), `bootstrap ${f}`);
  say(`bootstrap applied: ${phases.length} phases`);
  must(psql(readFileSync(MIG, 'utf8')), 'migration 0067 (1st apply)');
  must(psql(readFileSync(MIG, 'utf8')), 'migration 0067 (2nd apply — idempotent)');
  say('migration 0067 applied twice (idempotent)');
  must(psql(`create or replace function auth.uid() returns uuid language sql stable as $fn$ select nullif(current_setting('app.uid', true), '')::uuid $fn$;`), 'auth.uid override');

  // ── seed ──
  for (const [k, id] of Object.entries(U)) {
    const [email, ec, phone, pc, del] = AUTH[k];
    must(psql(`insert into auth.users (id, email, email_confirmed_at, phone, phone_confirmed_at, deleted_at)
      values ('${id}', ${lit(email)}, ${ec ? 'now()' : 'null'}, ${lit(phone)}, ${pc ? 'now()' : 'null'}, ${del ? 'now()' : 'null'});
      insert into public.profiles (id, email, phone) values ('${id}', ${lit(email ?? `${k.toLowerCase()}-noemail@example.test`)}, ${lit(phone)}) on conflict (id) do nothing;`), `seed ${k}`);
  }
  // D's profile is EDITED to an invited address — the ordinary self-update any user can perform (profiles.email is
  // unique, so the realistic target is an invitee who has not signed up yet, not an existing user's address)
  must(psql(`update public.profiles set email = '${EMAIL_X}' where id = '${U.D}';`), 'D edits profile to the invited address');
  // G's profile carries an invited phone (a profile is not a verified contact)
  must(psql(`update public.profiles set phone = '${PHONE_X}' where id = '${U.G}';`), 'G edits profile to the invited phone');

  // the owner's estate (bootstrapped by resolve_membership itself)
  must(as(U.OWNER, `select public.resolve_membership('owner@example.test', null);`), 'owner bootstrap');
  must(as(U.OWNER2, `select public.resolve_membership('owner2@example.test', null);`), 'owner 2 bootstrap');
  const ESTATE = q(`select id from public.estates where owner_id = '${U.OWNER}' and is_primary`);
  const ESTATE2 = q(`select id from public.estates where owner_id = '${U.OWNER2}' and is_primary`);
  // one ACTIVE invitation per (estate, address, role): A's three come as beneficiary + professional delegate here, and
  // a beneficiary invitation from estate 2
  const invite = (email, phone, role = 'beneficiary', owner = U.OWNER, estate = ESTATE) => {
    const row = asQ(owner, `select invitation_id || '|' || raw_token from public.create_invitation('${estate}', '${role}', '${role}', ${lit(email)}, ${lit(phone)}, true, true, 14);`);
    const [id, token] = row.split('|'); return { id, token };
  };
  const inv = {
    A1: invite('A@Example.Test', null), // mixed case on purpose
    A2: invite('a@example.test', null, 'professional_delegate'),
    A3: invite('a@example.test', null, 'beneficiary', U.OWNER2, ESTATE2),
    B: invite('b@example.test', null),
    C: invite(null, PHONE_C),
    E: invite('e@example.test', null),
    H_email: invite('h@example.test', null),
    H_phone: invite(null, PHONE_H),
    X_email: invite(EMAIL_X, null),
    X_phone: invite(null, PHONE_X),
    // ── the phone-format regression: Auth digits vs owner-path "+" ──
    J_plus: invite(null, PHONE_J_INV),
    J_plus_pro: invite(null, PHONE_J_INV, 'professional_delegate'),
    J_plus_e2: invite(null, PHONE_J_INV, 'beneficiary', U.OWNER2, ESTATE2),
    K_noplus: invite(null, PHONE_K_AUTH),                 // missing country-code marker
    K_other: invite(null, '+15555550501'),                 // a different number
    K_malformed: invite(null, '+1 (555) 555-0500', 'professional_delegate'), // malformed
  };
  const pendingIds = (who, email = null, phone = null) => {
    const j = asQ(who, `select public.resolve_membership(${lit(email)}, ${lit(phone)})::text;`);
    return new Set(JSON.parse(j).pendingInvitations.map((p) => p.id));
  };
  const same = (a, b) => a.size === b.size && [...a].every((x) => b.has(x));
  const ids = (...keys) => new Set(keys.map((k) => inv[k].id));

  say('\n── 1 · each caller sees only invitations addressed to their own VERIFIED contacts ──');
  check(same(pendingIds(U.A, 'a@example.test', null), ids('A1', 'A2', 'A3')), 'A (confirmed email) sees exactly A\'s three, including the mixed-case one');
  check(pendingIds(U.B, 'b@example.test', null).size === 0, 'B (UNCONFIRMED email) sees nothing — not even the invitation addressed to B');
  check(same(pendingIds(U.C, null, PHONE_C), ids('C')), 'C (confirmed phone, no email) sees exactly the phone invitation');
  check(pendingIds(U.G, 'g@example.test', PHONE_C).size === 0, 'G (C\'s phone unconfirmed; profile claims the invited phone) sees nothing');
  check(pendingIds(U.D, 'd@example.test', null).size === 0, 'D (profile edited to the invited address) sees nothing — the profile is not a contact');
  check(pendingIds(U.E, 'e@example.test', null).size === 0, 'E (deleted account) sees nothing');
  check(same(pendingIds(U.H, 'h@example.test', PHONE_H), ids('H_email', 'H_phone')), 'H (confirmed email AND phone) sees both, matched independently');
  must(psql(`update auth.users set phone_confirmed_at = null where id = '${U.H}';`), 'H loses phone confirmation');
  check(same(pendingIds(U.H, 'h@example.test', PHONE_H), ids('H_email')), 'H with the phone unconfirmed → the email invitation only (a verified email works without any phone)');
  must(psql(`update auth.users set phone_confirmed_at = now() where id = '${U.H}';`), 'H phone re-confirmed');

  say('\n── 1b · phone format: Auth stores international digits, the owner path writes "+" — one strict key ──');
  check(same(pendingIds(U.J, null, null), ids('J_plus', 'J_plus_pro', 'J_plus_e2')), 'J (Auth "15555550400", confirmed) sees every invitation written as "+15555550400"');
  check(pendingIds(U.K, null, null).size === 0, 'K (Auth "15555550500", confirmed) sees NOTHING: no "+" (no country-code marker), a different number, a malformed number');
  check(pendingIds(U.J, null, PHONE_J_AUTH).size === 3 && pendingIds(U.J, null, '+15555550500').size === 3, 'J\'s list is the same whatever phone is supplied (parameters not consulted)');
  check(refused(as(U.K, `select * from public.accept_invitation('${inv.K_noplus.id}');`), 'invitation_not_for_caller'), 'K cannot accept the invitation written without "+"');
  check(refused(as(U.K, `select * from public.accept_invitation('${inv.K_other.id}');`), 'invitation_not_for_caller'), 'K cannot accept the different number');
  check(refused(as(U.K, `select * from public.accept_invitation('${inv.K_malformed.id}');`), 'invitation_not_for_caller'), 'K cannot accept the malformed number');
  check(as(U.J, `select * from public.accept_invitation('${inv.J_plus.id}');`).status === 0, 'J ACCEPTS the "+"-written invitation with Auth digits');
  check(as(U.J, `select public.decline_invitation('${inv.J_plus_pro.id}');`).status === 0, 'J DECLINES one');
  check(as(U.J, `select * from public.bind_invitation_token('${inv.J_plus_e2.token}');`).status === 0, 'J BINDS one by token');
  // resolve_membership bootstraps each caller's OWN primary estate on first call, so count only memberships in estates they do not own
  const foreign = (uid) => q(`select count(*) from public.estate_memberships m join public.estates e on e.id = m.estate_id where m.user_id = '${uid}' and e.owner_id <> m.user_id and m.status = 'approved'`);
  check(foreign(U.J) === '2' && foreign(U.K) === '0', 'J holds two foreign memberships (accept + bind); K holds none');
  const keyOf = (v) => q(`select coalesce(public.invitation_phone_key(${v}, true), '<null>')`);
  check(keyOf("'+15555550400'") === '15555550400' && keyOf("'15555550400'") === '<null>' && keyOf("'+1 (555) 555-0400'") === '<null>' && keyOf("'+0123456789'") === '<null>' && keyOf("'+1555'") === '<null>' && keyOf("'+1234567890123456'") === '<null>', 'invitation-side key: "+E.164" only; no "+", separators, leading zero, too short, too long → NULL');
  check(q(`select coalesce(public.invitation_phone_key('15555550400', false), '<null>')`) === '15555550400' && q(`select coalesce(public.invitation_phone_key('+15555550400', false), '<null>')`) === '15555550400' && q(`select coalesce(public.invitation_phone_key('555-0400', false), '<null>')`) === '<null>', 'Auth-side key: digits with or without "+"; anything else NULL');

  say('\n── 2 · supplied parameters never widen the list ──');
  check(pendingIds(U.F, 'a@example.test', PHONE_C).size === 0, 'F passing A\'s email and C\'s phone sees nothing');
  check(same(pendingIds(U.A, 'zzz@example.test', '+10000000000'), ids('A1', 'A2', 'A3')), 'A passing someone else\'s contacts still sees exactly A\'s own');
  check(same(pendingIds(U.A, null, null), ids('A1', 'A2', 'A3')), 'A passing nothing still sees A\'s own (the parameters are not consulted)');

  say('\n── 3 · accept, decline and token binding use the same verified source ──');
  check(refused(as(U.D, `select * from public.accept_invitation('${inv.X_email.id}');`), 'invitation_not_for_caller'), 'D cannot ACCEPT the invitation its spoofed profile claims');
  check(refused(as(U.D, `select public.decline_invitation('${inv.X_email.id}');`), 'invitation_not_for_caller'), 'D cannot DECLINE it either');
  check(refused(as(U.D, `select * from public.bind_invitation_token('${inv.X_email.token}');`), 'invitation_not_for_caller'), 'D cannot BIND its token');
  check(refused(as(U.G, `select * from public.accept_invitation('${inv.X_phone.id}');`), 'invitation_not_for_caller'), 'G cannot accept the invitation its spoofed profile phone claims');
  check(refused(as(U.D, `select * from public.accept_invitation('${inv.A1.id}');`), 'invitation_not_for_caller'), 'D cannot ACCEPT A\'s invitation at all');
  check(refused(as(U.B, `select * from public.accept_invitation('${inv.B.id}');`), 'invitation_not_for_caller'), 'B cannot accept the invitation addressed to B\'s UNCONFIRMED email');
  check(refused(as(U.G, `select * from public.accept_invitation('${inv.C.id}');`), 'invitation_not_for_caller'), 'G cannot accept the phone invitation (phone unconfirmed)');
  check(refused(as(U.E, `select * from public.accept_invitation('${inv.E.id}');`), 'invitation_not_for_caller'), 'E (deleted) cannot accept');
  check(as(U.A, `select * from public.accept_invitation('${inv.A1.id}');`).status === 0, 'A accepts A1 (mixed-case address, confirmed email)');
  check(as(U.A, `select public.decline_invitation('${inv.A2.id}');`).status === 0, 'A declines A2');
  check(as(U.A, `select * from public.bind_invitation_token('${inv.A3.token}');`).status === 0, 'A binds A3 by token');
  check(as(U.C, `select * from public.accept_invitation('${inv.C.id}');`).status === 0, 'C accepts the phone invitation (confirmed phone)');
  check(q(`select count(*) from public.estate_memberships where estate_id = '${ESTATE}' and user_id in ('${U.A}','${U.C}') and status = 'approved'`) === '2', 'A and C hold approved memberships in estate 1');
  check(q(`select count(*) from public.estate_memberships where estate_id = '${ESTATE2}' and user_id = '${U.A}' and status = 'approved'`) === '1', 'A\'s token binding provisioned the estate-2 membership');
  check(q(`select count(*) from public.estate_memberships where estate_id = '${ESTATE}' and user_id in ('${U.B}','${U.D}','${U.E}','${U.G}','${U.F}')`) === '0', 'B, D, E, G, F hold no membership');

  say('\n── 4 · unchanged: owner management and token preview ──');
  check(Number(asQ(U.OWNER, `select count(*) from public.list_estate_invitations('${ESTATE}', 50);`)) >= 14, 'the owner still lists their estate\'s invitations');
  check(refused(as(U.F, `select * from public.list_estate_invitations('${ESTATE}', 50);`), 'owner_required'), 'a non-owner is refused (owner_required)');
  const preview = q(`select set_config('app.uid', '', false); select count(*) from public.invitation_preview('${inv.H_email.token}');`);
  check(preview === '1', 'the unauthenticated token preview still returns its one hint row');

  say(`\nFAILURES: ${failures}`);
  process.exitCode = failures === 0 ? 0 : 1;
} catch (e) {
  console.error(String(e?.message ?? e));
  process.exitCode = 2;
} finally {
  rm();
}
