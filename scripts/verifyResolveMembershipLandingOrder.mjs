#!/usr/bin/env node
/**
 * LANDING-ORDER PROOF for the two migrations that both replace resolve_membership:
 *   0067 — invitation contact binding (verified-contact matching of the pending list)
 *   0068 — membership invitation cue (inviterDisplayName on additional contexts)
 *
 * Builds a throwaway container from db/bootstrap, applies the two migrations IN THE PROPOSED ORDER
 * (0067 then 0068) and proves the FINAL function carries BOTH protections: a caller whose supplied
 * email is someone else's still sees only their own verified pending invitations, and an accepted
 * membership context carries the bound, sanitized inviter cue. Then it applies them in the REVERSE
 * order on a second container to show what that would lose — so the recommended order is a measured
 * fact, not a convention.
 *
 * ★ IT CANNOT BE POINTED AT A REAL DATABASE; auth.uid() is overridden to a session setting, proof-only.
 * Usage: node scripts/verifyResolveMembershipLandingOrder.mjs [--keep]
 */
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

for (const f of ['--database-url', '--db-url', '--project-ref', '--linked', '--remote', '--production', '--host', '--dsn']) {
  if (process.argv.some((a) => a.split('=')[0] === f)) { console.error(`REFUSED — ${f} is not accepted.`); process.exit(2); }
}
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const BOOT = join(ROOT, 'db/bootstrap');
const MIGS = readdirSync(join(ROOT, 'db/migrations'));
const M0067 = join(ROOT, 'db/migrations', MIGS.find((f) => f.startsWith('0067_') && f.includes('contact_binding')) ?? '');
const M0068 = join(ROOT, 'db/migrations', MIGS.find((f) => f.startsWith('0068_') && f.includes('invitation_cue')) ?? '');
const KEEP = process.argv.includes('--keep');
const say = (m) => console.log(m);
let failures = 0;
const check = (c, l) => { if (c) say(`  ✓ ${l}`); else { failures += 1; say(`  ✗ ${l}`); } };

const U = { OWNER: '0b000000-0000-4000-8000-00000000000a', BEN: '0b000000-0000-4000-8000-00000000000b', OTHER: '0b000000-0000-4000-8000-00000000000c' };
const lit = (v) => (v == null ? 'null' : `'${v}'`);

async function scenario(label, order) {
  const C = `aw-landing-${label}-${process.pid}`;
  const psql = (sql) => spawnSync('docker', ['exec', '-i', C, 'psql', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-q', '-f', '-'], { input: sql, encoding: 'utf8' });
  const q = (sql) => { const r = spawnSync('docker', ['exec', '-i', C, 'psql', '-U', 'postgres', '-tAc', sql], { encoding: 'utf8' }); if (r.status !== 0) throw new Error(r.stderr); return r.stdout.trim().split('\n').pop() ?? ''; };
  const must = (r, w) => { if (r.status !== 0) throw new Error(`${w} failed:\n${(r.stderr || '').slice(0, 900)}`); };
  const as = (uid, sql) => psql(`select set_config('app.uid', '${uid}', false);\n${sql}`);
  const asQ = (uid, sql) => q(`select set_config('app.uid', '${uid}', false); ${sql}`);
  try {
    spawnSync('docker', ['rm', '-f', C], { stdio: 'ignore' });
    must(spawnSync('docker', ['run', '-d', '--name', C, '-e', 'POSTGRES_PASSWORD=x', 'postgres:16'], { encoding: 'utf8' }), 'docker run');
    for (let i = 0; i < 60; i++) { if (spawnSync('docker', ['exec', C, 'pg_isready', '-U', 'postgres'], { stdio: 'ignore' }).status === 0) break; await new Promise((r) => setTimeout(r, 1000)); }
    must(psql(readFileSync(join(BOOT, 'testing/PLATFORM_SHIM_NOT_PRODUCTION.sql'), 'utf8')), 'shim');
    for (const f of readdirSync(BOOT).filter((f) => /^\d+_.*\.sql$/.test(f)).sort((a, b) => Number(a.split('_')[0]) - Number(b.split('_')[0]))) must(psql(readFileSync(join(BOOT, f), 'utf8')), f);
    for (const m of order) must(psql(readFileSync(m, 'utf8')), m.split('/').pop());
    say(`\n── ${label}: ${order.map((m) => m.split('/').pop().slice(0, 4)).join(' → ')} ──`);
    must(psql(`create or replace function auth.uid() returns uuid language sql stable as $fn$ select nullif(current_setting('app.uid', true), '')::uuid $fn$;`), 'auth.uid override');
    for (const [k, id] of Object.entries(U)) {
      must(psql(`insert into auth.users (id, email, email_confirmed_at) values ('${id}', '${k.toLowerCase()}@example.test', now());
        insert into public.profiles (id, email, full_name) values ('${id}', '${k.toLowerCase()}@example.test', ${k === 'OWNER' ? "'Dana Hartley'" : 'null'}) on conflict (id) do nothing;`), `seed ${k}`);
    }
    must(as(U.OWNER, `select public.resolve_membership('owner@example.test', null);`), 'owner bootstrap');
    const ESTATE = q(`select id from public.estates where owner_id = '${U.OWNER}' and is_primary`);
    const invBen = asQ(U.OWNER, `select invitation_id from public.create_invitation('${ESTATE}', 'beneficiary', 'beneficiary', 'ben@example.test', null, true, true, 14);`);
    const invOther = asQ(U.OWNER, `select invitation_id from public.create_invitation('${ESTATE}', 'professional_delegate', 'professional_delegate', 'other@example.test', null, true, true, 14);`);

    // protection 1 — verified-contact matching: OTHER supplying BEN's address must not see BEN's invitation
    const otherSees = JSON.parse(asQ(U.OTHER, `select public.resolve_membership('ben@example.test', null)::text;`)).pendingInvitations.map((p) => p.id);
    const binding = !otherSees.includes(invBen) && otherSees.includes(invOther);
    // protection 2 — the membership-bound cue after acceptance
    must(as(U.BEN, `select * from public.accept_invitation('${invBen}');`), 'ben accepts');
    const ctx = JSON.parse(asQ(U.BEN, `select public.resolve_membership('ben@example.test', null)::text;`)).additionalContexts.find((c) => c.estateId === ESTATE);
    const cue = ctx != null && ctx.inviterDisplayName === 'Dana Hartley';
    // decided in SQL (prosrc is multi-line; a last-line read would miss both markers)
    const hasHelper = q(`select prosrc like '%caller_verified_contacts%' from pg_proc where proname = 'resolve_membership'`) === 't';
    // the cue's own marker — the pending list ALSO emits an inviterDisplayName key, so the sanitizer call is the discriminator
    const hasCueSql = q(`select prosrc like '%safe_inviter_display_name(i.inviter_display_name)%' from pg_proc where proname = 'resolve_membership'`) === 't';
    return { binding, cue, hasHelper, hasCueSql };
  } finally {
    if (!KEEP) spawnSync('docker', ['rm', '-f', C], { stdio: 'ignore' });
  }
}

try {
  if (!M0067.endsWith('.sql') || !M0068.endsWith('.sql')) throw new Error('could not locate both migrations');
  if (spawnSync('docker', ['info'], { stdio: 'ignore' }).status !== 0) { console.error('✗ CANNOT VERIFY — Docker unavailable.'); process.exit(2); }
  const proposed = await scenario('proposed', [M0067, M0068]);
  check(proposed.binding, 'PROPOSED ORDER: the pending list is matched on verified contacts (a supplied address widens nothing)');
  check(proposed.cue, 'PROPOSED ORDER: the accepted membership carries the bound inviter cue');
  check(proposed.hasHelper && proposed.hasCueSql, 'PROPOSED ORDER: the final function text contains both the helper call and the cue');
  const reverse = await scenario('reverse', [M0068, M0067]);
  check(reverse.binding, 'REVERSE ORDER: binding present (0067 applied last)');
  check(!reverse.cue && !reverse.hasCueSql, 'REVERSE ORDER: the cue is LOST — 0067 re-creates resolve_membership without it (why the order matters)');
  say(`\nFAILURES: ${failures}`);
  process.exitCode = failures === 0 ? 0 : 1;
} catch (e) {
  console.error(String(e?.message ?? e));
  process.exitCode = 2;
}
