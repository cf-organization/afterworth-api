#!/usr/bin/env node
/**
 * MEMBERSHIP INVITATION CUE — local capture and verification (migration 0067).
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * Builds a throwaway Postgres container from db/bootstrap + the migration, seeds SYNTHETIC identities
 * (fixed uuids, example.test addresses, invented names — nobody real), and exercises every case the
 * cue must get right: two owners named differently, two owners with the SAME safe name, an inviter
 * whose persisted "name" is an address, a NULL name, an owner who hid their name, a cross-estate link,
 * an unlinked membership, a link to an invitation someone ELSE accepted, another caller, and loss of
 * membership access. Each resolve_membership response is written as JSON and asserted.
 *
 * ★ IT CANNOT BE POINTED AT A REAL DATABASE. No --database-url, no project ref, no .env read; it talks
 *   only to the container it created, through `docker exec`, and removes it in `finally`.
 * ★ auth.uid() IS OVERRIDDEN TO READ A SESSION SETTING — capture-only, NOT production DDL — so each
 *   call runs as a chosen synthetic user. The override is applied AFTER the bootstrap and the migration.
 * ★ POSITIVE CONTROLS: dropping the accepted_by predicate, the estate match, the showInviterName gate or
 *   the sanitizer from the migration each makes this script fail (recorded in the PR).
 *
 * Usage: node scripts/captureMembershipInvitationCue.mjs [--out <dir>] [--keep]
 */
import { readFileSync, readdirSync, writeFileSync, mkdirSync, mkdtempSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

for (const f of ['--database-url', '--db-url', '--project-ref', '--linked', '--remote', '--production', '--host', '--dsn']) {
  if (process.argv.some((a) => a.split('=')[0] === f)) { console.error(`REFUSED — ${f} is not accepted. This capture only ever targets a container it creates itself.`); process.exit(2); }
}
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const outArg = process.argv.indexOf('--out');
const OUT = outArg >= 0 && process.argv[outArg + 1] ? resolve(process.argv[outArg + 1]) : mkdtempSync(join(tmpdir(), 'aw-cue-captures-'));
mkdirSync(OUT, { recursive: true });
const BOOT = join(ROOT, 'db/bootstrap');
const MIG = join(ROOT, 'db/migrations/0067_20261125_membership_invitation_cue.sql');
const CONTAINER = `aw-cue-capture-${process.pid}`;
const KEEP = process.argv.includes('--keep');
const say = (m) => console.log(m);
const rm = () => { if (!KEEP) spawnSync('docker', ['rm', '-f', CONTAINER], { stdio: 'ignore' }); };
const psql = (sql) => spawnSync('docker', ['exec', '-i', CONTAINER, 'psql', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-q', '-f', '-'], { input: sql, encoding: 'utf8' });
const q = (sql) => { const r = spawnSync('docker', ['exec', '-i', CONTAINER, 'psql', '-U', 'postgres', '-tAc', sql], { encoding: 'utf8' }); if (r.status !== 0) throw new Error(`query failed: ${sql.slice(0, 120)}\n${r.stderr}`); return r.stdout.trim(); };
const must = (r, what) => { if (r.status !== 0) { throw new Error(`${what} failed:\n${(r.stderr || '').slice(0, 1200)}`); } };

// ── synthetic identities (uuids are fixed so the captures are reproducible; never real people) ──
const U = {
  BEN:     '0b000000-0000-4000-8000-00000000000b', // the beneficiary under test
  OTHER:   '0c000000-0000-4000-8000-00000000000c', // another caller
  DANA:    '0d000000-0000-4000-8000-00000000000d', // owner, full_name 'Dana Hartley'
  PRIYA:   '0e000000-0000-4000-8000-00000000000e', // owner, full_name 'Priya Okafor'
  DANA2:   '0f000000-0000-4000-8000-00000000000f', // owner, full_name 'Dana Hartley' (identical safe name)
  UNSAFE:  '01000000-0000-4000-8000-000000000011', // owner with NO full_name → address persisted as inviter_display_name
  MISSING: '01000000-0000-4000-8000-000000000012', // owner whose invitation row will carry NULL inviter_display_name
  HIDDEN:  '01000000-0000-4000-8000-000000000013', // owner who did NOT show their name at invitation time
};
const PROFILE = {
  BEN: ['ben@example.test', 'Ben Example'], OTHER: ['other@example.test', 'Other Person'],
  DANA: ['dana@example.test', 'Dana Hartley'], PRIYA: ['priya@example.test', 'Priya Okafor'], DANA2: ['dana2@example.test', 'Dana Hartley'],
  UNSAFE: ['unsafe-owner@example.test', null], MISSING: ['missing@example.test', 'Missing Name'], HIDDEN: ['hidden@example.test', 'Hidden Harper'],
};
const as = (uid, sql) => psql(`select set_config('app.uid', '${uid}', false);\n${sql}`);
const asQ = (uid, sql) => q(`select set_config('app.uid', '${uid}', false); ${sql}`).split('\n').pop();

let failures = 0;
const check = (cond, label) => { if (cond) say(`  ✓ ${label}`); else { failures += 1; say(`  ✗ ${label}`); } };

try {
  rm();
  must(spawnSync('docker', ['run', '-d', '--name', CONTAINER, '-e', 'POSTGRES_PASSWORD=capture', 'postgres:16'], { encoding: 'utf8' }), 'docker run');
  for (let i = 0; i < 60; i++) { if (spawnSync('docker', ['exec', CONTAINER, 'pg_isready', '-U', 'postgres'], { stdio: 'ignore' }).status === 0) break; await new Promise((r) => setTimeout(r, 1000)); }
  must(psql(readFileSync(join(BOOT, 'testing/PLATFORM_SHIM_NOT_PRODUCTION.sql'), 'utf8')), 'platform shim');
  const phases = readdirSync(BOOT).filter((f) => /^\d+_.*\.sql$/.test(f)).sort((a, b) => Number(a.split('_')[0]) - Number(b.split('_')[0]));
  for (const f of phases) must(psql(readFileSync(join(BOOT, f), 'utf8')), `bootstrap ${f}`);
  say(`bootstrap applied: ${phases.length} phases`);
  must(psql(readFileSync(MIG, 'utf8')), 'migration 0067 (1st apply)');
  must(psql(readFileSync(MIG, 'utf8')), 'migration 0067 (2nd apply — idempotent)');
  say('migration 0067 applied twice (idempotent)');
  // auth.uid() reads a session setting: NOT production, capture-only.
  must(psql(`create or replace function auth.uid() returns uuid language sql stable as $fn$ select nullif(current_setting('app.uid', true), '')::uuid $fn$;`), 'auth.uid override');

  // ── seed identities ──
  for (const [k, id] of Object.entries(U)) {
    const [email, name] = PROFILE[k];
    must(psql(`insert into auth.users (id, email) values ('${id}', '${email}') on conflict do nothing;
      insert into public.profiles (id, email, full_name) values ('${id}', '${email}', ${name == null ? 'null' : `'${name}'`}) on conflict (id) do update set email = excluded.email, full_name = excluded.full_name;`), `seed ${k}`);
  }
  // ── owners bootstrap their estates (each named "My Estate" by resolve_membership itself) ──
  const estateOf = {};
  for (const k of ['DANA', 'PRIYA', 'DANA2', 'UNSAFE', 'MISSING', 'HIDDEN']) {
    must(as(U[k], `select public.resolve_membership('${PROFILE[k][0]}', null);`), `bootstrap estate ${k}`);
    estateOf[k] = q(`select id from public.estates where owner_id = '${U[k]}' and is_primary`);
    check(q(`select name from public.estates where id = '${estateOf[k]}'`) === 'My Estate', `${k}'s estate is named "My Estate"`);
  }
  // ── invitations to BEN (and one to OTHER from Dana) ──
  const invite = (owner, invitee, showName) => asQ(U[owner], `select invitation_id from public.create_invitation('${estateOf[owner]}', 'beneficiary', 'beneficiary', '${PROFILE[invitee][0]}', null, true, ${showName}, 14);`);
  const inv = {};
  inv.DANA = invite('DANA', 'BEN', true);
  inv.PRIYA = invite('PRIYA', 'BEN', true);
  inv.DANA2 = invite('DANA2', 'BEN', true);
  inv.UNSAFE = invite('UNSAFE', 'BEN', true);
  inv.MISSING = invite('MISSING', 'BEN', true);
  inv.HIDDEN = invite('HIDDEN', 'BEN', false);
  inv.DANA_OTHER = invite('DANA', 'OTHER', true);
  // the "missing" case: the persisted name is NULL on the row (as a row written before name capture could be)
  must(psql(`update public.invitations set inviter_display_name = null where id = '${inv.MISSING}';`), 'null out MISSING name');
  check(q(`select inviter_display_name from public.invitations where id = '${inv.UNSAFE}'`) === PROFILE.UNSAFE[0], 'UNSAFE invitation persisted the inviter ADDRESS (the deployed fallback)');
  check(q(`select inviter_display_name from public.invitations where id = '${inv.DANA}'`) === 'Dana Hartley', 'DANA invitation persisted "Dana Hartley"');

  // ── what the acceptance screen is shown (pending invitations, as BEN) ──
  const pendingJson = asQ(U.BEN, `select public.resolve_membership('${PROFILE.BEN[0]}', null)::text;`);
  writeFileSync(join(OUT, '0-pending-as-ben.json'), pendingJson);
  const pending = JSON.parse(pendingJson).pendingInvitations;
  check(pending.length === 6, `BEN sees 6 pending invitations (got ${pending.length})`);
  const pendingByEstate = Object.fromEntries(pending.map((p) => [p.estateId, p.inviterDisplayName]));
  check(pendingByEstate[estateOf.DANA] === 'Dana Hartley', 'pending: Dana\'s invitation shows "Dana Hartley"');
  check(pendingByEstate[estateOf.UNSAFE] === PROFILE.UNSAFE[0], 'pending: UNSAFE invitation releases the raw address (pre-existing behaviour; the client sanitizes it)');
  check(pendingByEstate[estateOf.HIDDEN] === null, 'pending: HIDDEN invitation releases no name');

  // ── BEN accepts all six; OTHER accepts Dana's ──
  for (const k of ['DANA', 'PRIYA', 'DANA2', 'UNSAFE', 'MISSING', 'HIDDEN']) must(as(U.BEN, `select * from public.accept_invitation('${inv[k]}');`), `BEN accepts ${k}`);
  must(as(U.OTHER, `select * from public.accept_invitation('${inv.DANA_OTHER}');`), 'OTHER accepts Dana\'s');

  const resolveAs = (who, file) => { const j = asQ(U[who], `select public.resolve_membership('${PROFILE[who][0]}', null)::text;`); writeFileSync(join(OUT, file), JSON.stringify(JSON.parse(j), null, 2)); return JSON.parse(j); };
  const cueByEstate = (r) => Object.fromEntries(r.additionalContexts.map((c) => [c.estateId, c.inviterDisplayName]));

  say('\n── 1 · the main capture: BEN in six estates all named "My Estate" ──');
  const r1 = resolveAs('BEN', '1-ben-after-acceptance.json');
  check(r1.additionalContexts.length === 6, `6 additional contexts (got ${r1.additionalContexts.length})`);
  check(r1.additionalContexts.every((c) => c.estateDisplayName === 'My Estate'), 'every context is named "My Estate"');
  check(r1.additionalContexts.every((c) => 'inviterDisplayName' in c), 'every additional context carries the inviterDisplayName key');
  check(!('inviterDisplayName' in r1.primaryEstateContext), 'the primary (owned) context carries NO cue key');
  const c1 = cueByEstate(r1);
  check(c1[estateOf.DANA] === 'Dana Hartley', 'Dana\'s estate → "Dana Hartley"');
  check(c1[estateOf.PRIYA] === 'Priya Okafor', 'Priya\'s estate → "Priya Okafor"');
  check(c1[estateOf.DANA2] === 'Dana Hartley', 'the second Dana Hartley\'s estate → "Dana Hartley" (identical safe name: valid, unresolved, not manufactured apart)');
  check(c1[estateOf.UNSAFE] === null, 'UNSAFE (address-shaped) → null');
  check(c1[estateOf.MISSING] === null, 'MISSING (null on the row) → null');
  check(c1[estateOf.HIDDEN] === null, 'HIDDEN (owner did not show the name) → null');
  const allText = JSON.stringify(r1);
  check(!allText.includes('unsafe-owner@example.test'), 'no address anywhere in BEN\'s response');
  check(!allText.includes('approvedAt') && !allText.includes('approved_at') && !allText.includes('acceptedAt'), 'no approval/acceptance date in the response');

  say('\n── 2 · another caller: OTHER sees only its own cue ──');
  const r2 = resolveAs('OTHER', '2-other.json');
  check(r2.additionalContexts.length === 1 && r2.additionalContexts[0].estateId === estateOf.DANA, 'OTHER has exactly one context (Dana\'s estate)');
  check(r2.additionalContexts[0].inviterDisplayName === 'Dana Hartley', 'OTHER\'s cue comes from OTHER\'s own accepted invitation');
  check(!JSON.stringify(r2).includes(U.BEN), 'nothing of BEN in OTHER\'s response');

  say('\n── 3 · mismatched links release nothing ──');
  // 3a: BEN's membership in Priya's estate repointed to BEN's accepted invitation from DANA (other estate)
  must(psql(`update public.estate_memberships set source_invitation_id = '${inv.DANA}' where user_id = '${U.BEN}' and estate_id = '${estateOf.PRIYA}';`), 'repoint PRIYA membership → DANA invitation');
  // 3b: OTHER's membership in Dana's estate repointed to BEN's invitation (same estate, accepted by someone else)
  must(psql(`update public.estate_memberships set source_invitation_id = '${inv.DANA}' where user_id = '${U.OTHER}' and estate_id = '${estateOf.DANA}';`), 'repoint OTHER membership → BEN\'s invitation');
  // 3c: BEN's membership in Dana2's estate unlinked (reconciled-membership shape)
  must(psql(`update public.estate_memberships set source_invitation_id = null where user_id = '${U.BEN}' and estate_id = '${estateOf.DANA2}';`), 'unlink DANA2 membership');
  const r3 = resolveAs('BEN', '3-ben-mismatched.json');
  const c3 = cueByEstate(r3);
  check(c3[estateOf.PRIYA] === null, 'cross-estate link (Priya membership → Dana invitation) → null');
  check(c3[estateOf.DANA2] === null, 'unlinked membership → null');
  check(c3[estateOf.DANA] === 'Dana Hartley', 'the untouched Dana membership still carries its cue');
  const r3o = resolveAs('OTHER', '3-other-mismatched.json');
  check(r3o.additionalContexts[0].inviterDisplayName === null, 'a link to an invitation ACCEPTED BY SOMEONE ELSE → null (accepted_by scoping)');

  say('\n── 4 · loss of membership access ──');
  must(psql(`update public.estate_memberships set status = 'revoked' where user_id = '${U.BEN}' and estate_id = '${estateOf.DANA}';`), 'revoke BEN in Dana\'s estate');
  const r4 = resolveAs('BEN', '4-ben-revoked.json');
  check(!r4.additionalContexts.some((c) => c.estateId === estateOf.DANA), 'the revoked membership\'s context is gone entirely (no cue without access)');
  check(r4.additionalContexts.length === 5, `5 contexts remain (got ${r4.additionalContexts.length})`);

  say('\n── 5 · the sanitizer, directly ──');
  const san = (v) => q(`select coalesce(public.safe_inviter_display_name(${v}), '<null>')`);
  check(san(`'  Dana Hartley '`) === 'Dana Hartley', 'trims');
  check(san(`'dana@example.test'`) === '<null>', 'email-shaped → null');
  check(san(`'Dana <dana@example.test>'`) === '<null>', 'name with an address inside → null (any \\S@\\S)');
  check(san(`'   '`) === '<null>', 'blank → null');
  check(san(`null`) === '<null>', 'null → null');
  check(san(`'@'`) === '@', 'a lone @ is not address-shaped (mirrors the client rule exactly)');
  check(san(`repeat('x', 201)`) === '<null>', 'over 200 chars → null');
  check(q(`select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proname = 'safe_inviter_display_name' and p.prosecdef`) === '0', 'the sanitizer is NOT security definer');

  say(`\nFAILURES: ${failures}`);
  say(`captures: ${OUT}`);
  process.exitCode = failures === 0 ? 0 : 1;
} catch (e) {
  console.error(String(e?.message ?? e));
  process.exitCode = 2;
} finally {
  rm();
}
