#!/usr/bin/env node
/**
 * FRESH-DATABASE MIGRATION REHEARSAL — the runner.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ WHAT THIS PROVES, AND WHY IT HAD TO EXIST BEFORE A SECOND ENVIRONMENT.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * `db/migrations/` has only ever been applied incrementally, one file at a time, to one long-lived
 * project. That the deployed schema works says nothing about whether the RECORDED history rebuilds
 * it — and the day R-02's non-production project is provisioned, the recorded history is the only
 * thing there will be. Finding out then costs a paid project and a day; finding out here costs a
 * container.
 *
 * ★ IT CANNOT BE POINTED AT A REAL DATABASE, BY CONSTRUCTION. There is no `--database-url`, no
 *   `--project-ref`, no `--remote`, no host argument, and no read of `SUPABASE_URL`, any service
 *   key, or any `.env`. The script starts its own container, invents its own throwaway password and
 *   talks to it through `docker exec`. Validating a supplied target would be a weaker property than
 *   having no way to supply one.
 *
 * ★ EVERY FILE IS EXECUTED WHOLE, THROUGH `psql -f`. Migrations contain `$$`-quoted function
 *   bodies, `do` blocks and policies; splitting SQL on semicolons would corrupt them and produce
 *   failures that are artefacts of the runner rather than facts about the history. No SQL parser is
 *   reimplemented here.
 *
 * ★ FIRST ERROR STOPS THE RUN. `ON_ERROR_STOP=1` plus an inspected exit status, and no continuation
 *   past a failure: a rehearsal that skipped a broken migration and kept going would report a
 *   schema nobody can build.
 *
 * Usage:  node scripts/rehearseFreshDatabase.mjs [--json] [--keep]
 * Exit:   0 built · 1 failed · 2 could not verify
 */
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  REHEARSAL,
  discoverMigrations,
  rehearsalExitCode,
  unsatisfiedTableReferences,
} from './lib/freshDatabaseRehearsal.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const MIGRATIONS_DIR = join(ROOT, 'db/migrations');
const JSON_OUT = process.argv.includes('--json');
const KEEP = process.argv.includes('--keep');

/**
 * ★ REJECTED ARGUMENTS ARE REFUSED LOUDLY RATHER THAN IGNORED. An operator who believes they
 *   redirected this at another database must be told they did not, not left to read a success line
 *   and conclude the wrong database was rebuilt.
 */
const FORBIDDEN_ARGS = ['--database-url', '--project-ref', '--remote', '--production', '--host', '--dsn'];
for (const a of process.argv.slice(2)) {
  const flag = a.split('=')[0];
  if (FORBIDDEN_ARGS.includes(flag)) {
    console.error(`REFUSED — ${flag} is not accepted. This rehearsal only ever targets a container it creates itself.`);
    process.exit(2);
  }
}

const CONTAINER = `aw-fresh-db-rehearsal-${process.pid}`;
const out = [];
const say = (s) => { out.push(s); if (!JSON_OUT) console.log(s); };
const die = (verdict, msg, extra = {}) => {
  if (JSON_OUT) console.log(JSON.stringify({ verdict, message: msg, ...extra }, null, 2));
  else console.error(msg);
  process.exit(rehearsalExitCode(verdict));
};

/* ── 1 · DISCOVER, from disk, never from a list in this file ─────────────────────────────────── */
if (!existsSync(MIGRATIONS_DIR)) die(REHEARSAL.UNVERIFIABLE, `COULD NOT VERIFY — ${MIGRATIONS_DIR} does not exist.`);
const listing = readdirSync(MIGRATIONS_DIR);
const found = discoverMigrations(listing);
if (!found.ok) {
  die(REHEARSAL.UNVERIFIABLE, `COULD NOT VERIFY — the migration set is not usable:\n  ${found.problems.join('\n  ')}`,
    { problems: found.problems });
}
const ordered = found.ordered;
const files = ordered.map((name) => ({ name, sql: readFileSync(join(MIGRATIONS_DIR, name), 'utf8') }));

say('FRESH-DATABASE MIGRATION REHEARSAL');
say('='.repeat(96));
say(`  migrations discovered   ${ordered.length}`);
say(`  first                   ${ordered[0]}`);
say(`  last                    ${ordered[ordered.length - 1]}`);
say(`  target                  ephemeral container ${CONTAINER} (no remote target is expressible)`);

/* ── 2 · SYMBOLIC PRE-FLIGHT ─────────────────────────────────────────────────────────────────── */
const gaps = unsatisfiedTableReferences(files);
if (gaps.length > 0) {
  say('');
  say('  PRE-FLIGHT — statements referencing a table no earlier migration creates:');
  for (const g of gaps.slice(0, 10)) say(`    ${g.migration}  ALTERs public.${g.table}, never created by an earlier migration`);
  if (gaps.length > 10) say(`    … and ${gaps.length - 10} more`);
  say('');
  say('  This is reported, not assumed fatal — Postgres decides. Continuing to the real apply.');
}

/* ── 3 · THE CONTAINER, OWNED BY THIS RUN ────────────────────────────────────────────────────── */
if (spawnSync('docker', ['info'], { stdio: 'ignore' }).status !== 0) {
  die(REHEARSAL.UNVERIFIABLE, 'COULD NOT VERIFY — Docker is not available. The history must be EXECUTED, not described.');
}
const removeContainer = () => { if (!KEEP) spawnSync('docker', ['rm', '-f', CONTAINER], { stdio: 'ignore' }); };
removeContainer();
if (spawnSync('docker', ['run', '-d', '--name', CONTAINER, '-e', 'POSTGRES_PASSWORD=rehearsal', 'postgres:16'],
  { encoding: 'utf8' }).status !== 0) {
  die(REHEARSAL.UNVERIFIABLE, 'COULD NOT VERIFY — failed to start the rehearsal container.');
}

let verdict = REHEARSAL.UNVERIFIABLE;
let applied = 0;
let failure = null;

try {
  let ready = false;
  for (let i = 0; i < 90; i += 1) {
    if (spawnSync('docker', ['exec', CONTAINER, 'pg_isready', '-U', 'postgres'], { stdio: 'ignore' }).status === 0) { ready = true; break; }
    spawnSync('sleep', ['1']);
  }
  if (!ready) throw new Error('postgres never became ready');

  const psqlFile = (sql) => spawnSync(
    'docker', ['exec', '-i', CONTAINER, 'psql', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-q', '-f', '-'],
    { input: sql, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 }
  );

  /* Supabase supplies `auth` and its own extensions. A rehearsal that omitted them would blame the
     migrations for a platform the history has always been written against. Only the platform
     surface the migrations reference is created — nothing of the application schema. */
  const platform = `
    create schema if not exists auth;
    create extension if not exists pgcrypto;
    create table if not exists auth.users (id uuid primary key default gen_random_uuid(), email text);
    create or replace function auth.uid() returns uuid language sql stable as $fn$ select null::uuid $fn$;
    create or replace function auth.role() returns text language sql stable as $fn$ select 'authenticated'::text $fn$;
    create or replace function auth.jwt() returns jsonb language sql stable as $fn$ select '{}'::jsonb $fn$;
    create role authenticated;
    create role anon;
    create role service_role;
  `;
  const p = psqlFile(platform);
  if (p.status !== 0) throw new Error(`platform preamble failed:\n${(p.stderr || '').slice(0, 800)}`);

  say('');
  say('  APPLYING MIGRATIONS IN ORDER');
  for (const f of files) {
    const r = psqlFile(f.sql);
    if (r.status !== 0) {
      failure = { migration: f.name, status: r.status, stderr: (r.stderr || '').trim().split('\n').slice(0, 12).join('\n') };
      break;
    }
    applied += 1;
  }

  if (failure) {
    verdict = REHEARSAL.FAILED;
    say(`  applied ${applied}/${ordered.length} before the first failure`);
    say('');
    say(`  FIRST FAILING MIGRATION  ${failure.migration}`);
    say(`  exit status              ${failure.status}`);
    for (const line of failure.stderr.split('\n')) say(`    ${line}`);
  } else {
    /* ── SCHEMA SMOKE — small and stable; this is not a second drift verifier ───────────────── */
    const q = (sql) => {
      const r = spawnSync('docker', ['exec', '-i', CONTAINER, 'psql', '-U', 'postgres', '-tAc', sql], { encoding: 'utf8' });
      return r.status === 0 ? r.stdout.trim() : null;
    };
    const tables = Number(q("select count(*) from information_schema.tables where table_schema='public'") ?? 0);
    const funcs = Number(q("select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'") ?? 0);
    const rls = Number(q("select count(*) from pg_tables where schemaname='public' and rowsecurity") ?? 0);
    say('');
    say(`  SCHEMA SMOKE  tables=${tables}  functions=${funcs}  rls-enabled=${rls}`);
    if (tables === 0) { verdict = REHEARSAL.FAILED; say('  REFUSED — every migration applied but the schema is empty.'); }
    else verdict = REHEARSAL.BUILT;
  }
} catch (e) {
  verdict = REHEARSAL.UNVERIFIABLE;
  failure = { migration: null, status: null, stderr: String(e?.message ?? e).slice(0, 800) };
  say(`  COULD NOT VERIFY — ${failure.stderr}`);
} finally {
  removeContainer();
}

say('');
say('='.repeat(96));
say(`VERDICT : ${verdict}`);
if (verdict === REHEARSAL.FAILED) {
  say('');
  say('  ★ THIS IS A FINDING ABOUT THE RECORDED HISTORY, NOT A BUG IN THIS SCRIPT, AND IT IS NOT');
  say('    FIXED HERE. No migration file is edited to make a rehearsal pass — that would forge the');
  say('    very history this exists to check. It needs a separate migration-history adjudication.');
}

if (JSON_OUT) {
  console.log(JSON.stringify({
    verdict, migrations: ordered.length, first: ordered[0], last: ordered[ordered.length - 1],
    applied, failure, preflight_gaps: gaps, container_removed: !KEEP,
  }, null, 2));
}
process.exit(rehearsalExitCode(verdict));
