#!/usr/bin/env node
/**
 * ROUTINE-LEVEL PROOF that a bootstrapped project ends up able to upload a document.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ THE CLAIM THIS MAKES, AND THE ONE IT REFUSES TO MAKE. It proves that a database built from
 *   `db/bootstrap` has NO upload policy (the defect, reproduced rather than described), that migration
 *   0065 gives it one, that the ROUTINE the client calls returns it, that re-applying changes nothing,
 *   and that an operator's tuned value survives a re-run. It proves nothing about hosted Supabase:
 *   the container grants superuser and hosted does not.
 *
 * ★ IT TESTS THE ROUTINE, NOT THE TABLE. `get_upload_policy()` is the door the mobile client knocks
 *   on. A seed that populated the table while the routine stayed unreadable — a grant, an ownership or
 *   a search_path mistake — would satisfy every table-level assertion and leave upload exactly as dead
 *   as it was. That is the whole lesson of the nonprod outage: the routine was deployed, granted and
 *   callable for weeks, and only the row was missing.
 *
 * ★ STEP A IS A POSITIVE CONTROL FOR THE DEFECT, AND IT CAN FAIL LOUDLY. If a freshly bootstrapped
 *   database already returns a policy row, this script REFUSES rather than passing: it would mean the
 *   bootstrap has learned to seed it, which makes every later step vacuous and this instrument a
 *   rubber stamp. "Already fixed elsewhere" is a finding, not a pass.
 *
 * ★ CONTAINER-OWNED, NO REMOTE TARGET EXPRESSIBLE. Same posture as the bootstrap rehearsal: no
 *   connection string, project ref or host can be supplied, so there is no argument an operator could
 *   pass that would point this at a real database. That is stronger than validating one.
 *
 * Usage: node scripts/verifyUploadPolicySeed.mjs [--pg-image postgres:17] [--keep] [--json]
 * Exit:  0 UPLOAD_POLICY_SEEDED · 1 FAILED · 2 UNVERIFIABLE
 */
import { spawnSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const BOOT = join(ROOT, 'db/bootstrap');
const SEED = 'db/migrations/0065_20261001_upload_policy_seed.sql';

const argv = process.argv.slice(2);
const arg = (n) => { const i = argv.indexOf(n); return i >= 0 ? argv[i + 1] : null; };
const JSON_OUT = argv.includes('--json');
const KEEP = argv.includes('--keep');
const PG_IMAGE = arg('--pg-image') ?? 'postgres:16';

for (const f of ['--database-url', '--db-url', '--project-ref', '--linked', '--remote', '--production', '--host', '--dsn']) {
  if (argv.some((a) => a.split('=')[0] === f)) { console.error(`REFUSED — ${f} is not accepted.`); process.exit(2); }
}

const lines = [];
const say = (s) => { lines.push(s); if (!JSON_OUT) console.log(s); };
const die = (verdict, msg) => {
  say('');
  say(`  ${msg}`);
  say('');
  say(`VERDICT : ${verdict}`);
  if (JSON_OUT) console.log(JSON.stringify({ verdict, message: msg, lines }, null, 2));
  process.exit(verdict === 'UNVERIFIABLE' ? 2 : 1);
};

if (!existsSync(join(ROOT, SEED))) die('UNVERIFIABLE', `COULD NOT VERIFY — ${SEED} is missing.`);
if (spawnSync('docker', ['info'], { stdio: 'ignore' }).status !== 0) {
  die('UNVERIFIABLE', 'COULD NOT VERIFY — Docker unavailable. The seed must be EXECUTED, not described.');
}

const phaseFiles = readdirSync(BOOT).filter((f) => /^\d+_.*\.sql$/.test(f))
  .sort((a, b) => Number(a.split('_')[0]) - Number(b.split('_')[0]));
if (phaseFiles.length === 0) die('UNVERIFIABLE', 'COULD NOT VERIFY — no bootstrap phase files; an empty build proves nothing.');

const CONTAINER = `aw-upload-policy-seed-${process.pid}`;
const rm = () => { if (!KEEP) spawnSync('docker', ['rm', '-f', CONTAINER], { stdio: 'ignore' }); };
rm();
if (spawnSync('docker', ['run', '-d', '--name', CONTAINER, '-e', 'POSTGRES_PASSWORD=seed', PG_IMAGE], { encoding: 'utf8' }).status !== 0) {
  die('UNVERIFIABLE', 'COULD NOT VERIFY — failed to start the container.');
}

let verdict = 'UNVERIFIABLE';
try {
  let ready = false;
  for (let i = 0; i < 90; i += 1) {
    if (spawnSync('docker', ['exec', CONTAINER, 'pg_isready', '-U', 'postgres'], { stdio: 'ignore' }).status === 0) { ready = true; break; }
    spawnSync('sleep', ['1']);
  }
  if (!ready) throw new Error('postgres never became ready');

  const psql = (sql) => spawnSync('docker', ['exec', '-i', CONTAINER, 'psql', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-q', '-f', '-'],
    { input: sql, encoding: 'utf8', maxBuffer: 128 * 1024 * 1024 });
  const q = (sql) => {
    const r = spawnSync('docker', ['exec', '-i', CONTAINER, 'psql', '-U', 'postgres', '-tAc', sql], { encoding: 'utf8' });
    return r.status === 0 ? r.stdout.trim() : null;
  };
  const fail = (m) => { throw Object.assign(new Error(m), { expected: true }); };

  say('UPLOAD-POLICY SEED — ROUTINE-LEVEL PROOF');
  say('='.repeat(92));
  say(`  container   ${CONTAINER} (created here, destroyed in finally)`);
  say(`  image       ${PG_IMAGE}`);

  const pre = Number(q("select count(*) from information_schema.tables where table_schema='public'") ?? -1);
  if (pre !== 0) fail(`container is not virgin: ${pre} public tables already present`);
  say(`  virgin      public tables=${pre}`);

  const shim = psql(readFileSync(join(BOOT, 'testing/PLATFORM_SHIM_NOT_PRODUCTION.sql'), 'utf8'));
  if (shim.status !== 0) fail(`platform shim failed:\n${(shim.stderr || '').slice(0, 800)}`);
  say('  shim        applied (auth/storage/roles/extensions) — NOT production DDL');

  for (const f of phaseFiles) {
    const r = psql(readFileSync(join(BOOT, f), 'utf8'));
    if (r.status !== 0) fail(`bootstrap phase ${f} failed:\n${(r.stderr || '').trim().split('\n').slice(0, 10).join('\n')}`);
  }
  say(`  bootstrap   ${phaseFiles.length} phases applied`);
  say('');

  // ── A · THE DEFECT, REPRODUCED ────────────────────────────────────────────────────────────────
  if (Number(q("select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='upload_policy'")) !== 1) {
    fail('the bootstrap did not create public.upload_policy — this is a different problem');
  }
  if (Number(q("select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='get_upload_policy'")) !== 1) {
    fail('the bootstrap did not create public.get_upload_policy() — this is a different problem');
  }
  const before = Number(q('select count(*) from public.get_upload_policy()') ?? -1);
  if (before === -1) fail('get_upload_policy() could not be called on a freshly bootstrapped database');
  if (before !== 0) {
    fail(`A FRESHLY BOOTSTRAPPED DATABASE ALREADY RETURNS ${before} POLICY ROW(S). Either the bootstrap `
      + 'now seeds it or this container is not fresh. Refusing to continue: every step below would be '
      + 'vacuous, and this script would become a rubber stamp for a fix it never exercised.');
  }
  say('  A · the table and the routine exist, and the routine returns 0 ROWS — the defect, reproduced');

  // ── B · THE SEED ──────────────────────────────────────────────────────────────────────────────
  const seedSql = readFileSync(join(ROOT, SEED), 'utf8');
  const s1 = psql(seedSql);
  if (s1.status !== 0) fail(`0065 failed to apply:\n${(s1.stderr || '').trim().split('\n').slice(0, 12).join('\n')}`);
  const after = Number(q('select count(*) from public.get_upload_policy()') ?? -1);
  if (after !== 1) fail(`after 0065, get_upload_policy() returned ${after} rows, expected exactly 1`);
  const row = q("select max_upload_bytes||'|'||max_files_per_claim||'|'||max_aggregate_bytes||'|'||array_to_string(allowed_mime_types,',') from public.get_upload_policy()");
  const EXPECTED = '26214400|2|52428800|application/pdf,image/jpeg,image/png,image/heic';
  if (row !== EXPECTED) fail(`the seeded policy is ${row}\n                       expected ${EXPECTED}`);
  say(`  B · 0065 applied — the ROUTINE returns one usable row (${row})`);

  // ── C · IDEMPOTENCE ───────────────────────────────────────────────────────────────────────────
  const s2 = psql(seedSql);
  if (s2.status !== 0) fail(`0065 is NOT idempotent — a second apply failed:\n${(s2.stderr || '').slice(0, 600)}`);
  if (Number(q('select count(*) from public.upload_policy')) !== 1) fail('a second apply changed the row count');
  if (q("select max_upload_bytes||'|'||max_files_per_claim||'|'||max_aggregate_bytes||'|'||array_to_string(allowed_mime_types,',') from public.get_upload_policy()") !== EXPECTED) {
    fail('a second apply changed the row');
  }
  say('  C · applied twice — same single row, byte for byte');

  // ── D · AN OPERATOR'S TUNED VALUE SURVIVES ────────────────────────────────────────────────────
  // This is what ON CONFLICT DO NOTHING buys, and the reason it is not DO UPDATE. On an installation
  // that traversed the real history, 0032 seeded this row years ago and an operator may have adjusted
  // it; a migration that reset it would be a silent policy change dressed as provisioning.
  psql('update public.upload_policy set max_upload_bytes = 1048576 where id = 1;');
  const s3 = psql(seedSql);
  if (s3.status !== 0) fail(`0065 failed against a tuned row:\n${(s3.stderr || '').slice(0, 600)}`);
  if (Number(q('select max_upload_bytes from public.get_upload_policy()')) !== 1048576) {
    fail("0065 OVERWROTE an operator's tuned max_upload_bytes — ON CONFLICT DO NOTHING is not holding");
  }
  say("  D · re-applied over a tuned row — the operator's value SURVIVED (not overwritten)");
  psql('update public.upload_policy set max_upload_bytes = 26214400 where id = 1;');

  // ── E · MUTATION: the postcondition can actually FAIL ──────────────────────────────────────────
  // ★ WITHOUT THIS, EVERY CHECK ABOVE MIGHT BE UNABLE TO FAIL. The row is deleted and the migration's
  //   own postcondition block is re-run on its own; it MUST raise. A postcondition that has never
  //   failed has not been verified — and this repository has shipped assertions that could not fail.
  psql('delete from public.upload_policy where id = 1;');
  if (Number(q('select count(*) from public.get_upload_policy()')) !== 0) fail('the row could not be deleted');
  const post = seedSql.slice(seedSql.indexOf('-- ── POSTCONDITION'), seedSql.lastIndexOf('COMMIT;'));
  if (!post.includes('get_upload_policy()')) fail('could not isolate the postcondition block from 0065');
  const mutated = psql(post);
  if (mutated.status === 0) {
    fail("MUTATION SURVIVED: with the singleton DELETED, 0065's postcondition still reported success. "
      + 'It is not checking what it claims to check.');
  }
  if (!(mutated.stderr || '').includes('0065 POSTCONDITION FAILED')) {
    fail(`the postcondition raised, but not its own error:\n${(mutated.stderr || '').slice(0, 400)}`);
  }
  say('  E · MUTATION — with the row deleted, the postcondition RAISES (it can fail)');

  // ── F · AND THE MIGRATION AS A WHOLE REPAIRS THAT STATE ────────────────────────────────────────
  const s4 = psql(seedSql);
  if (s4.status !== 0) fail(`0065 could not repair a missing row:\n${(s4.stderr || '').slice(0, 600)}`);
  if (Number(q('select count(*) from public.get_upload_policy()')) !== 1) fail('0065 did not restore the row');
  say('  F · re-applied after the deletion — the routine answers again (repair, not just create)');

  verdict = 'UPLOAD_POLICY_SEEDED';
  say('');
  say('  THE BOOTSTRAP ALONE LEAVES UPLOAD DEAD. BOOTSTRAP + 0065 LEAVES THE ROUTINE ANSWERING.');
  say('  Not proven here: hosted Supabase behaviour, and the documents BUCKET, which is');
  say('  platform-owned and cannot be created by SQL — see docs/provisioning/documents-bucket.md.');
} catch (e) {
  rm();
  die(e?.expected ? 'FAILED' : 'UNVERIFIABLE', `${e?.expected ? '✗ ' : 'COULD NOT VERIFY — '}${String(e?.message ?? e).slice(0, 900)}`);
} finally { rm(); }

say('');
say(`VERDICT : ${verdict}`);
if (JSON_OUT) console.log(JSON.stringify({ verdict, lines }, null, 2));
process.exit(0);
