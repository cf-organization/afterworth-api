#!/usr/bin/env node
/**
 * MODEL C — CUTOVER CONTRACT PROOF (synthetic future migration).
 *
 * ★ THE PROPERTY UNDER TEST: a post-cutover migration must land IDENTICALLY on
 *     PATH A — a database restored from the authoritative snapshot (the upgraded production shape)
 *     PATH B — a database built by the componentized Model C bootstrap
 *   If those diverge, the bootstrap is not a substitute for the real schema and the 0060/0061
 *   contract is unsound. This is the only thing that makes "virgin installs skip 0001-0060" safe.
 *
 * ★ IT PROVES NOTHING ABOUT HOSTED SUPABASE. Both paths run in local containers with superuser.
 *
 * Usage: node scripts/bootstrapCutoverProof.mjs --snapshot <path>
 * Exit:  0 equivalent · 1 divergent · 2 could not verify
 */
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const BOOT = join(ROOT, 'db/bootstrap');
const argv = process.argv.slice(2);
const arg = (n) => { const i = argv.indexOf(n); return i >= 0 ? argv[i + 1] : null; };
// * THE REFUSAL LIST MUST MATCH ITS SIBLINGS EXACTLY. This one omitted --dsn and --host, so
//   `--dsn` exited 0 while the generator and fresh-run refused it. A partial refusal list is
//   worse than none: it advertises a guarantee it does not uniformly provide.
for (const f of ['--database-url', '--db-url', '--project-ref', '--linked', '--remote', '--production', '--host', '--dsn']) {
  if (argv.some((a) => a.split('=')[0] === f)) { console.error(`REFUSED — ${f} is not accepted.`); process.exit(2); }
}
const SNAP = arg('--snapshot');
const die = (m) => { console.error(m); process.exit(2); };
if (!SNAP || !existsSync(SNAP)) die('COULD NOT VERIFY — pass --snapshot.');

const SYNTH = join(ROOT, 'test/fixtures/synthetic_future_migration.sql');
if (!existsSync(SYNTH)) die('COULD NOT VERIFY — synthetic future migration fixture missing.');
const SHIM = readFileSync(join(BOOT, 'testing/PLATFORM_SHIM_NOT_PRODUCTION.sql'), 'utf8');
const phaseFiles = readdirSync(BOOT).filter((f) => /^\d+_.*\.sql$/.test(f)).sort((a, b) => Number(a.split('_')[0]) - Number(b.split('_')[0]));
if (!phaseFiles.length) die('COULD NOT VERIFY — no bootstrap phases.');

if (spawnSync('docker', ['info'], { stdio: 'ignore' }).status !== 0) die('COULD NOT VERIFY — Docker unavailable.');

/** Fingerprint every schema property the cutover contract depends on. */
const FINGERPRINT = `
select string_agg(line, E'\\n' order by line) from (
  select 'T '||table_name as line from information_schema.tables where table_schema='public' and table_type='BASE TABLE'
  union all
  select 'C '||table_name||'.'||column_name||':'||data_type||':'||is_nullable||':'||coalesce(regexp_replace(column_default,'\\\\s+',' ','g'),'-')
    from information_schema.columns where table_schema='public'
  union all
  select 'F '||p.proname||':'||p.prosecdef::text||':'||coalesce(array_to_string(p.proconfig,','),'-')
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'
  union all
  select 'I '||c.relname from pg_index i join pg_class c on c.oid=i.indexrelid join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and not exists (select 1 from pg_constraint k where k.conindid=i.indexrelid)
  union all
  select 'K '||conrelid::regclass::text||'.'||conname from pg_constraint where connamespace='public'::regnamespace
  union all
  select 'R '||tablename||':'||rowsecurity::text from pg_tables where schemaname='public'
  union all
  select 'P '||tablename||'.'||policyname||':'||cmd||':'||array_to_string(roles,'+')||':'
         ||regexp_replace(coalesce(qual,'-'),'\\\\s+',' ','g')||':'||regexp_replace(coalesce(with_check,'-'),'\\\\s+',' ','g')
    from pg_policies where schemaname='public'
  union all
  select 'S '||policyname||':'||cmd from pg_policies where schemaname='storage' and tablename='objects'
  union all
  select 'G '||tgname from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and not t.tgisinternal
  union all
  select 'E '||evtname||':'||coalesce(array_to_string(evttags,'|'),'-') from pg_event_trigger where evtname='ensure_rls'
) x;`;

function runPath(label, container, build) {
  spawnSync('docker', ['rm', '-f', container], { stdio: 'ignore' });
  if (spawnSync('docker', ['run', '-d', '--name', container, '-e', 'POSTGRES_PASSWORD=cutover', 'postgres:16'], { encoding: 'utf8' }).status !== 0) {
    throw new Error(`${label}: container failed to start`);
  }
  try {
    let ready = false;
    for (let i = 0; i < 90; i += 1) {
      if (spawnSync('docker', ['exec', container, 'pg_isready', '-U', 'postgres'], { stdio: 'ignore' }).status === 0) { ready = true; break; }
      spawnSync('sleep', ['1']);
    }
    if (!ready) throw new Error(`${label}: postgres never ready`);
    const psql = (sql) => spawnSync('docker', ['exec', '-i', container, 'psql', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-q', '-f', '-'],
      { input: sql, encoding: 'utf8', maxBuffer: 128 * 1024 * 1024 });
    const q = (sql) => { const r = spawnSync('docker', ['exec', '-i', container, 'psql', '-U', 'postgres', '-tAc', sql], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 }); return r.status === 0 ? r.stdout.trim() : null; };

    const pre = Number(q("select count(*) from information_schema.tables where table_schema='public'") ?? -1);
    if (pre !== 0) throw new Error(`${label}: container not virgin (${pre} tables)`);

    const shim = psql(SHIM);
    if (shim.status !== 0) throw new Error(`${label}: shim failed\n${(shim.stderr || '').slice(0, 500)}`);

    build(psql);

    const synth = psql(`SET check_function_bodies = false;\nSET search_path = public, extensions, pg_catalog;\n${readFileSync(SYNTH, 'utf8')}`);
    if (synth.status !== 0) throw new Error(`${label}: synthetic migration failed\n${(synth.stderr || '').slice(0, 700)}`);

    const probe = {
      column: Number(q("select count(*) from information_schema.columns where table_schema='public' and table_name='estates' and column_name='synthetic_probe_note'") ?? 0),
      table: Number(q("select count(*) from information_schema.tables where table_schema='public' and table_name='synthetic_probe_table'") ?? 0),
      fn: Number(q("select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='synthetic_probe_fn'") ?? 0),
      policy: Number(q("select count(*) from pg_policies where schemaname='public' and policyname='synthetic_probe_read'") ?? 0),
    };
    return { fingerprint: q(FINGERPRINT) ?? '', probe };
  } finally {
    spawnSync('docker', ['rm', '-f', container], { stdio: 'ignore' });
  }
}

console.log('MODEL C CUTOVER CONTRACT PROOF — 0060 bootstrap + synthetic 0061');
console.log('='.repeat(92));
let a, b;
try {
  a = runPath('PATH A', `aw-cutover-a-${process.pid}`, (psql) => {
    // ★ PATH A restores the AUTHORITATIVE SNAPSHOT — the upgraded production shape, not a replay of
    //   0001-0060 (which cannot build from zero; that is the finding this whole programme rests on).
    //   ★ PLATFORM-ONLY EXTENSIONS ARE FILTERED, AND THAT IS ITSELF A FINDING. The raw dump
    //     contains `CREATE EXTENSION supabase_vault` and `pg_stat_statements`; vanilla Postgres has
    //     neither, so the authoritative dump is NOT directly restorable off Supabase. The Model C
    //     bootstrap already classifies both as platform prerequisites and does not create them, so
    //     Path A is filtered the same way — otherwise the comparison would be between a build that
    //     ran and one that could not start, which measures nothing.
    const raw = readFileSync(SNAP, 'utf8');
    //     The filtered set is exactly what bootstrapComponents.phaseOf() treats as platform-owned
    //     or session-scoped: the two platform extensions and the realtime publication.
    let filtered = raw
      .replace(/^CREATE EXTENSION IF NOT EXISTS "(supabase_vault|pg_stat_statements)"[^;]*;$/gmi, '-- [platform extension filtered for local Path A]')
      .replace(/^(ALTER|CREATE|DROP) PUBLICATION[^;]*;$/gmi, '-- [platform publication filtered for local Path A]');
    const removed = (raw.match(/^CREATE EXTENSION IF NOT EXISTS "(supabase_vault|pg_stat_statements)"[^;]*;$/gmi) ?? []).length
      + (raw.match(/^(ALTER|CREATE|DROP) PUBLICATION[^;]*;$/gmi) ?? []).length;
    if (removed !== 3) throw new Error(`PATH A: expected to filter exactly 3 platform statements, filtered ${removed} — the filter is broken, not the dump`);
    const r = psql(filtered);
    if (r.status !== 0) throw new Error(`PATH A: snapshot restore failed\n${(r.stderr || '').slice(0, 700)}`);

    //   ★ THE SUPPLEMENTS ARE PART OF PATH A TOO, AND THE REASON IS NOT CONVENIENCE.
    //     Path A models the EXISTING UPGRADED PRODUCTION DATABASE. That database demonstrably has
    //     the two storage.objects policies and the ensure_rls event trigger — the hashed captures
    //     prove it. `pg_dump` simply cannot express either: it excludes platform schemas and emits
    //     no CREATE EVENT TRIGGER. Restoring the dump alone therefore builds something STRICTLY
    //     LESS COMPLETE than production, and comparing that against Model C measured the dump's
    //     blind spots rather than the cutover contract.
    //
    //     Run without this block, the proof reported exactly three B-only objects:
    //       E ensure_rls, S documents_estate_insert, S documents_estate_read
    //     — i.e. precisely the objects the supplemental catalog captures were taken to recover.
    for (const f of ['110_storage_policies.sql', '120_event_triggers.sql']) {
      const sr = psql(readFileSync(join(BOOT, f), 'utf8'));
      if (sr.status !== 0) throw new Error(`PATH A: supplement ${f} failed\n${(sr.stderr || '').slice(0, 500)}`);
    }
  });
  console.log('  PATH A  snapshot restore (upgraded production shape) + synthetic migration   ok');

  b = runPath('PATH B', `aw-cutover-b-${process.pid}`, (psql) => {
    for (const f of phaseFiles) {
      const r = psql(readFileSync(join(BOOT, f), 'utf8'));
      if (r.status !== 0) throw new Error(`PATH B: ${f} failed\n${(r.stderr || '').slice(0, 700)}`);
    }
  });
  console.log('  PATH B  Model C componentized bootstrap + synthetic migration                ok');
} catch (e) {
  console.error(`  COULD NOT VERIFY — ${String(e?.message ?? e).slice(0, 900)}`);
  process.exit(2);
}

console.log('');
console.log(`  synthetic objects present  A: ${JSON.stringify(a.probe)}`);
console.log(`                             B: ${JSON.stringify(b.probe)}`);
const probesOk = JSON.stringify(a.probe) === JSON.stringify(b.probe) && Object.values(a.probe).every((v) => v === 1);

const la = a.fingerprint.split('\n').filter(Boolean);
const lb = b.fingerprint.split('\n').filter(Boolean);
if (la.length === 0 || lb.length === 0) { console.error('  REFUSED — an empty fingerprint is never equivalence.'); process.exit(2); }
const sa = new Set(la), sb = new Set(lb);
const onlyA = la.filter((x) => !sb.has(x));
const onlyB = lb.filter((x) => !sa.has(x));

console.log(`  fingerprint lines          A: ${la.length}   B: ${lb.length}`);
console.log(`  only in A: ${onlyA.length}   only in B: ${onlyB.length}`);
for (const x of onlyA.slice(0, 10)) console.log(`    A-only  ${x.slice(0, 130)}`);
for (const x of onlyB.slice(0, 10)) console.log(`    B-only  ${x.slice(0, 130)}`);

const ok = onlyA.length === 0 && onlyB.length === 0 && probesOk;
console.log('');
console.log(`VERDICT : ${ok ? 'CUTOVER_EQUIVALENT — a future migration lands identically on both paths' : 'CUTOVER_DIVERGENT'}`);
process.exit(ok ? 0 : 1);
