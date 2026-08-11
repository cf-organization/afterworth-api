#!/usr/bin/env node
/**
 * Run the SQL authorization suite against a real Postgres.
 *
 * ★ IT FAILS LOUDLY WHEN IT CANNOT CHECK. No Docker and no `--database-url` exits **2** with an
 * explanation, never 0. A verifier that silently succeeds when it inspected nothing is the
 * vacuous-scan failure mode this repository has already shipped several times, and it is worse here
 * than elsewhere: a green "authorization verified" that ran no assertions is an actively false claim
 * about a security boundary.
 *
 * ★ IT ASSERTS THE ASSERTIONS RAN. psql exiting 0 is necessary but not sufficient — a file that
 * failed to load, or a DO block that was skipped, also exits 0. The runner requires the terminal
 * sentinel AND a plausible number of individual `ok` notices before reporting a pass.
 *
 * Usage:
 *   node scripts/verifySqlAuthorization.mjs                     # ephemeral docker postgres
 *   node scripts/verifySqlAuthorization.mjs --database-url URL  # an existing throwaway database
 *   node scripts/verifySqlAuthorization.mjs --keep              # leave the container up to inspect
 *
 * NEVER point --database-url at production. The suite creates roles, tables and users.
 */
import { execFileSync, spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..');

const PARTS = [
  'db/tests/preamble_real_auth.sql',
  'db/bundles/0048_estate_assets_bundle.sql',
  'db/tests/estate_assets_authorization.sql',
];

const missing = PARTS.filter((p) => !existsSync(join(ROOT, p)));
if (missing.length) {
  console.error(`✗ CANNOT VERIFY — missing input(s):\n  ${missing.join('\n  ')}`);
  process.exit(2);
}

/**
 * ★ THE HARNESS MUST INSTALL THE REAL GATE, AND THAT IS CHECKED RATHER THAN TRUSTED. If the preamble
 * ever drifts back to a stub, every refusal assertion silently becomes untestable — the exact defect
 * this suite was written to close. The bodies are compared before anything runs.
 */
const canonical = readFileSync(join(ROOT, 'db/functions/is_estate_owner.sql'), 'utf8');
const preamble = readFileSync(join(ROOT, 'db/tests/preamble_real_auth.sql'), 'utf8');
const normalise = (s) =>
  (s.match(/create or replace function public\.is_estate_owner[\s\S]*?\$function\$;/) ?? [''])[0]
    .replace(/\s+/g, ' ')
    .trim();
if (!normalise(canonical) || normalise(canonical) !== normalise(preamble)) {
  console.error('✗ CANNOT VERIFY — db/tests/preamble_real_auth.sql does not install the canonical');
  console.error('  is_estate_owner from db/functions/is_estate_owner.sql. Refusing to run: a drifted');
  console.error('  or stubbed gate would make every refusal assertion vacuous.');
  process.exit(2);
}
if (/is_estate_owner[\s\S]{0,400}?select\s+true/i.test(preamble)) {
  console.error('✗ CANNOT VERIFY — the preamble appears to stub is_estate_owner to true.');
  process.exit(2);
}

const argv = process.argv.slice(2);
const urlIdx = argv.indexOf('--database-url');
const KEEP = argv.includes('--keep');
const CONTAINER = 'aw-sqlauth';
const PORT = '55433';

let psql; // (sqlText | {file}) -> {status, out}
let cleanup = () => {};

function dockerAvailable() {
  const r = spawnSync('docker', ['info'], { stdio: 'ignore' });
  return r.status === 0;
}

if (urlIdx > -1) {
  const url = argv[urlIdx + 1];
  if (!url) {
    console.error('✗ --database-url requires a value');
    process.exit(2);
  }
  psql = (file) => spawnSync('psql', [url, '-v', 'ON_ERROR_STOP=1', '-f', file], { encoding: 'utf8' });
} else {
  if (!dockerAvailable()) {
    console.error('✗ CANNOT VERIFY — Docker is not running and no --database-url was given.');
    console.error('  This is a FAILURE, not a pass: no authorization assertion was executed.');
    process.exit(2);
  }
  spawnSync('docker', ['rm', '-f', CONTAINER], { stdio: 'ignore' });
  const up = spawnSync('docker', [
    'run', '-d', '--name', CONTAINER,
    '-e', 'POSTGRES_PASSWORD=pw', '-p', `${PORT}:5432`, 'postgres:16',
  ], { encoding: 'utf8' });
  if (up.status !== 0) {
    console.error(`✗ CANNOT VERIFY — failed to start postgres:\n${up.stderr}`);
    process.exit(2);
  }
  cleanup = () => {
    if (!KEEP) spawnSync('docker', ['rm', '-f', CONTAINER], { stdio: 'ignore' });
  };
  let ready = false;
  for (let i = 0; i < 60; i += 1) {
    if (spawnSync('docker', ['exec', CONTAINER, 'pg_isready', '-U', 'postgres'], { stdio: 'ignore' }).status === 0) {
      ready = true;
      break;
    }
    execFileSync('sleep', ['1']);
  }
  if (!ready) {
    cleanup();
    console.error('✗ CANNOT VERIFY — postgres never became ready.');
    process.exit(2);
  }
  psql = (file) =>
    spawnSync('docker', ['exec', '-i', CONTAINER, 'psql', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-f', '-'], {
      input: readFileSync(file, 'utf8'),
      encoding: 'utf8',
    });
}

let combined = '';
for (const part of PARTS) {
  const r = psql(join(ROOT, part));
  combined += (r.stdout ?? '') + (r.stderr ?? '');
  if (r.status !== 0) {
    cleanup();
    console.error(`✗ FAILED while applying ${part}\n`);
    console.error(((r.stderr ?? '') + (r.stdout ?? '')).split('\n').slice(-40).join('\n'));
    process.exit(1);
  }
}

// ★ PROVE THE ASSERTIONS ACTUALLY RAN. A file that silently did nothing also exits 0.
// psql prefixes notices with `psql:<stdin>:N: ` when reading from stdin, and omits it otherwise —
// the matcher tolerates both rather than silently counting zero, which is how this check first
// reported "0 assertions" against a suite that had in fact run every one of them.
const okCount = (combined.match(/NOTICE:\s+ok\s{2,}/g) ?? []).length;
const MIN_ASSERTIONS = 25;
if (!combined.includes('ALL AUTHORIZATION ASSERTIONS PASSED')) {
  cleanup();
  console.error('✗ the suite did not reach its terminal sentinel — it did not run to completion.');
  process.exit(1);
}
if (okCount < MIN_ASSERTIONS) {
  cleanup();
  console.error(`✗ only ${okCount} assertions reported ok (expected >= ${MIN_ASSERTIONS}).`);
  console.error('  The suite completed but inspected far less than it should — treat as a failure.');
  process.exit(1);
}

cleanup();
console.log(
  combined
    .split('\n')
    .filter((l) => /NOTICE:/.test(l))
    .map((l) => l.replace(/^.*?NOTICE:\s?/, ''))
    .join('\n')
);
console.log(`\n✓ SQL AUTHORIZATION VERIFIED — ${okCount} assertions, real is_estate_owner, RLS enforced under role "authenticated".`);
