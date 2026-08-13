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
import { existsSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SQL_SUITE_PARTS } from './lib/sqlSuiteParts.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..');

// ★ SINGLE-SOURCED WITH THE MUTATION RUNNER (Phase 11-B). The runner has to know whether a mutated
// file reaches this database at all; a private copy of the list here would drift from that check on
// the first reordering, invisibly. See scripts/lib/sqlSuiteParts.mjs.
const PARTS = SQL_SUITE_PARTS;

// ★ CAPTURE, NOT ASSERT. Run with --capture to emit one REAL payload per viewer class into a JSON
// fixture the mobile decoder is written against. A decoder built from a hand-written fixture agrees
// with whatever the client already believes; only a payload the database produced can teach it the
// real nullability.
const CAPTURE = process.argv.includes('--capture');
const CAPTURE_PART = 'db/tests/capture_discovery_payloads.sql';

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
/**
 * ★ THE PREAMBLE MAY NOT DEFINE A FUNCTION THAT ALSO EXISTS UNDER `db/functions/`.
 *
 * This is the general form of the `is_estate_owner` check above, and it exists because the specific
 * form was not enough. The harness also carried a hand-copied `create_asset_grant` — introduced as
 * "extracted verbatim", to prove `estate_inventory` was grantable through the REAL door — and a
 * stubbed `emit_notification`. Nothing compared either against source, so:
 *
 *   · the grant copy drifted the moment Phase 10-E changed the real body, and the suite would have
 *     gone on exercising the old one, green;
 *   · the notification stub took six parameters while its only caller passed seven, so no overload
 *     matched, the call raised, and the caller's `exception when others then null` swallowed it. The
 *     notification path had been dead for its entire life while appearing exercised.
 *
 * A suite that tests a copy is not testing the deployed thing, and the failure is invisible from the
 * outside — which is the definition of a vacuous audit. The rule is therefore structural: if a body
 * belongs to the product, it arrives from a bundle. If it is genuinely not the boundary under test
 * (the audit sink, the taxonomy counter), it has no file under `db/functions/` and is unaffected.
 *
 * The one sanctioned exception is `is_estate_owner`, which must be installed BEFORE the bundles load
 * because tables and policies below reference it — and which is byte-compared against source above,
 * so it is held to a stricter standard than this rule imposes rather than a weaker one.
 */
/**
 * Every function the preamble defines that ALSO has a real source file must be declared here, and
 * declaring it is not a waiver — each disposition is checked.
 *
 *   VERBATIM      the preamble claims to carry the production body. Byte-compared (whitespace
 *                 normalized) against `db/functions/<name>.sql`; a mismatch is drift and aborts.
 *                 These must be in the preamble rather than a bundle because tables, policies and
 *                 other bodies below them reference them at CREATE time.
 *
 *   STUB          deliberately NOT the production body, because it is not the boundary under test.
 *                 Checked to be genuinely different — a "stub" that has quietly become a copy is
 *                 the same drift risk wearing the opposite label, and a copy sitting under a
 *                 comment saying "not the boundary under test" is worse than either.
 *
 * Anything else aborts. That is the durable half of the Phase 10-E finding: the specific
 * `is_estate_owner` comparison could not see a hand-copied `create_asset_grant` or a rotted
 * `emit_notification` stub, and both were live for as long as they existed.
 */
const PREAMBLE_DISPOSITION = new Map([
  ['is_estate_owner', 'VERBATIM'],
  ['is_ownership_role', 'VERBATIM'],
  ['is_estate_member', 'VERBATIM'],
  ['is_estate_executor', 'VERBATIM'],
  // ★ ADDED IN 10-F, AND THEY HAD BEEN INVISIBLE. These are the ANTI-ORACLE mechanism: the brackets
  // that stop a category aggregate from publishing an exact value. The preamble carried its own copy
  // and nothing compared it to source, because the lookup below used to be `db/functions/<name>.sql`
  // and their real definition lives INSIDE `db/functions/list_estate_assets.sql`. A guard that finds
  // a function by guessing its filename cannot see a function defined in a file named after
  // something else — which is most of them.
  ['asset_bracket_low', 'VERBATIM'],
  ['asset_bracket_high', 'VERBATIM'],
  // ★ ALSO SURFACED BY THE CONTENT SEARCH IN 10-F: a taxonomy version counter defined inside
  // `get_document_taxonomy.sql`. Genuinely a stub — the harness version omits `updated_at` and the
  // DEFINER/search_path — and genuinely not the boundary under test: no authorization assertion in
  // any suite depends on a vocabulary version number.
  ['bump_taxonomy_vocabulary_version', 'STUB'],
  // ★ PROMOTED STUB → VERBATIM IN PHASE 11-C. The stub's rationale — "audit persistence is not
  // what any assertion in these suites is about" — stopped being true the day the death-verification
  // suite asserted that every case mutation writes an attributed audit row and that a DENIED
  // mutation writes no success row. The harness now models `audit_logs` (0011 shape) and carries the
  // real writer, held to source like every other real boundary.
  ['write_audit', 'VERBATIM'],
  /**
   * ★ SURFACED IN PHASE 11-B, AND ALL THREE HAD BEEN INVISIBLE FOR THEIR ENTIRE LIVES.
   *
   * `findSource` used to search `db/functions/` alone. A function whose source of truth lives in a
   * MIGRATION therefore resolved to `null`, and the loop above reads a null source as "genuinely no
   * production counterpart — a pure harness fixture" and skips it. Three production bodies sat in
   * that hole:
   *
   *   · `can_access_document`   — THE document authorization gate, the only thing between a
   *                               non-owner and a document row (defined in 0002 → 0003 → 0004);
   *   · `document_grantable`    — the document disclosure ceiling (0002);
   *   · `asset_category_grantable` — the ASSET disclosure ceiling (0008 → 0049).
   *
   * This is the `asset_bracket_low`/`asset_bracket_high` near-miss of Phase 10-F seen from one
   * directory over: there the guard could not find a function defined in a file named after a
   * different one; here it could not find one defined outside the directory it searched. The first
   * two copies happened to match their migrations. Nothing would have said so if they had not.
   *
   * `can_access_document` and `document_grantable` are extracted to `db/functions/` in this phase
   * and are held VERBATIM. They stay in the preamble rather than arriving from a bundle for the
   * `is_estate_owner` reason: the `documents_read` policy created below them names
   * `can_access_document`, and a policy cannot reference a function that does not yet exist.
   */
  ['can_access_document', 'VERBATIM'],
  ['document_grantable', 'VERBATIM'],
  /**
   * ★ A GENUINE STUB — AND A DANGEROUS-LOOKING ONE, WHICH IS WHY IT IS NOW DECLARED.
   *
   * The preamble installs `asset_category_grantable` as `select false`, then the estate bundle
   * replaces it with the real body a few files later. That is correct today and the suite exercises
   * the real ceiling. But it means that if the estate bundle ever stopped carrying it, every ceiling
   * assertion would run against a function that refuses everything — and "nothing is grantable" reads
   * as SAFE. A vacuous pass in the shape of a security win.
   *
   * `db/tests/release_condition_authorization.sql` asserts the loaded body is the real one before it
   * asserts anything with it, so the stub cannot be what a green run measured.
   */
  ['asset_category_grantable', 'STUB'],
]);

/**
 * ★ WHERE A FUNCTION IS REALLY DEFINED — searched by CONTENT across every source file.
 *
 * The first version of this guard resolved `public.foo` to `db/functions/foo.sql` and skipped the
 * check when that path did not exist. That silently exempted every function defined inside a file
 * named after a different one, and `asset_bracket_low` / `asset_bracket_high` — the brackets the
 * whole aggregate-disclosure defence rests on — sat in that blind spot with a shadow copy in the
 * harness the entire time. They happened to agree; nothing would have said so if they had not.
 */
const readDir = (rel) =>
  readdirSync(join(ROOT, rel))
    .filter((f) => f.endsWith('.sql'))
    .sort()
    .map((f) => ({ path: `${rel}/${f}`, text: readFileSync(join(ROOT, rel, f), 'utf8') }));

const FUNCTION_FILES = readDir('db/functions');
/**
 * ★ MIGRATIONS ARE SEARCHED TOO — THE BLIND SPOT THAT HID THREE CEILINGS (Phase 11-B).
 *
 * Sorted, so the highest-numbered migration defining a name is the one compared: a body re-declared
 * in 0004 supersedes 0003 supersedes 0002, and comparing the preamble against the OLDEST definition
 * would manufacture drift findings out of ordinary history.
 */
const MIGRATION_FILES = readDir('db/migrations');
if (FUNCTION_FILES.length === 0 || MIGRATION_FILES.length === 0) {
  console.error('✗ CANNOT VERIFY — the source scan set is empty; every shadow check below would be vacuous.');
  process.exit(2);
}

function findSource(name) {
  const re = new RegExp(`create\\s+or\\s+replace\\s+function\\s+public\\.${name}\\s*\\(`, 'i');
  // `db/functions/` is canonical and wins. A migration is only consulted when NO function file
  // declares the name — otherwise a historical re-declaration would out-rank the source of truth.
  const canonical = FUNCTION_FILES.find((f) => re.test(f.text));
  if (canonical) return canonical;
  const inMigrations = MIGRATION_FILES.filter((f) => re.test(f.text));
  return inMigrations.length ? inMigrations[inMigrations.length - 1] : null;
}

/**
 * ★ THE GUARD PROVES IT CAN SEE, BEFORE IT REPORTS THAT IT SAW NOTHING.
 *
 * A `findSource` that silently resolved nothing would skip every comparison and print the same
 * success as a run in which all of them passed — the exact "63 assertions against an empty file
 * list" shape this repository has shipped. So two positive controls run first: one function whose
 * source is a file under `db/functions/`, and one whose ONLY definition is inside a migration. The
 * second is the case that was invisible until Phase 11-B; if it ever resolves to null again, the
 * blind spot is back and this exits 2 rather than reporting a clean scan.
 */
for (const [control, expectDir] of [['is_estate_owner', 'db/functions/'], ['enforce_grant_ceiling', 'db/migrations/']]) {
  const found = findSource(control);
  if (!found || !found.path.startsWith(expectDir)) {
    console.error(`✗ CANNOT VERIFY — findSource positive control failed: public.${control} did not`);
    console.error(`  resolve to a file under ${expectDir} (got ${found ? found.path : 'null'}).`);
    console.error('  Every shadow-copy comparison below depends on this lookup; a null resolves as');
    console.error('  "no production counterpart" and skips the check silently.');
    process.exit(2);
  }
}

const bodyOf = (sql, name) =>
  (sql.match(new RegExp(`create\\s+or\\s+replace\\s+function\\s+public\\.${name}\\b[\\s\\S]*?\\$[a-z_]*\\$;`, 'i')) ?? [''])[0]
    .replace(/--[^\n]*/g, '')
    .replace(/\s+/g, ' ')
    .trim();

const declared = [...new Set(
  [...preamble.matchAll(/create\s+or\s+replace\s+function\s+public\.(\w+)\s*\(/gi)].map((m) => m[1])
)];
const problems = [];
for (const name of declared) {
  const source = findSource(name);
  if (!source) continue; // genuinely no production counterpart — a pure harness fixture
  const disposition = PREAMBLE_DISPOSITION.get(name);
  if (!disposition) {
    problems.push(`public.${name} — redefined here with no declared disposition (defined in ${source.path})`);
    continue;
  }
  const mine = bodyOf(preamble, name);
  const theirs = bodyOf(source.text, name);
  if (!mine || !theirs) {
    problems.push(`public.${name} — could not extract one of the two bodies to compare`);
  } else if (disposition === 'VERBATIM' && mine !== theirs) {
    problems.push(`public.${name} — declared VERBATIM but has DRIFTED from ${source.path}`);
  } else if (disposition === 'STUB' && mine === theirs) {
    problems.push(`public.${name} — declared STUB but is now identical to source; load it from a bundle instead`);
  }
}
if (problems.length > 0) {
  console.error('✗ CANNOT VERIFY — the preamble and db/functions/ disagree:');
  for (const p of problems) console.error(`    ${p}`);
  console.error('\n  A harness copy of a production body is a copy that drifts, and a suite exercising');
  console.error('  the copy proves nothing about what is deployed. Either load the real body from a');
  console.error('  bundle, or declare its disposition in PREAMBLE_DISPOSITION and keep it honest.');
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
  psql = (file, extra = []) => spawnSync('psql', [url, '-v', 'ON_ERROR_STOP=1', ...extra, '-f', file], { encoding: 'utf8' });
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
  psql = (file, extra = []) =>
    spawnSync('docker',
      ['exec', '-i', CONTAINER, 'psql', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', ...extra, '-f', '-'], {
      input: readFileSync(file, 'utf8'),
      encoding: 'utf8',
    });
}

let combined = '';
let capturedJson = '';
for (const part of [...PARTS, ...(CAPTURE ? [CAPTURE_PART] : [])]) {
  const isCapture = part === CAPTURE_PART;
  // -A -t: unaligned, tuples-only. Aligned output pads with '+' continuation markers and is not JSON.
  const r = psql(join(ROOT, part), isCapture ? ['-A', '-t'] : []);
  if (isCapture) capturedJson = r.stdout ?? '';
  combined += (r.stdout ?? '') + (r.stderr ?? '');
  if (r.status !== 0) {
    cleanup();
    console.error(`✗ FAILED while applying ${part}\n`);
    /**
     * ★ STDERR IN FULL AND FIRST. This previously printed the last 40 lines of
     * `stderr + stdout` — which, because psql writes a long stream of `CREATE FUNCTION` /
     * `GRANT` acknowledgements to STDOUT and the single `ERROR:` line to STDERR, reliably showed
     * forty lines of "everything is fine" and truncated the only line that said what broke.
     *
     * A failure report that omits the failure is worse than no report: it looks like diagnosis.
     */
    const err = (r.stderr ?? '').trim();
    if (err) {
      console.error('── psql stderr ──────────────────────────────────────────────────────────────');
      console.error(err);
    } else {
      console.error('(psql wrote nothing to stderr; the tail of stdout follows)');
      console.error((r.stdout ?? '').split('\n').slice(-25).join('\n'));
    }
    process.exit(1);
  }
}

// ★ PROVE THE ASSERTIONS ACTUALLY RAN. A file that silently did nothing also exits 0.
// psql prefixes notices with `psql:<stdin>:N: ` when reading from stdin, and omits it otherwise —
// the matcher tolerates both rather than silently counting zero, which is how this check first
// reported "0 assertions" against a suite that had in fact run every one of them.
const okCount = (combined.match(/NOTICE:\s+ok\s{2,}/g) ?? []).length;
const MIN_ASSERTIONS = 60;
for (const sentinel of [
  'ALL AUTHORIZATION ASSERTIONS PASSED',
  'ALL DISCOVERY ASSERTIONS PASSED',
  'ALL READINESS ASSERTIONS PASSED',
  // ★ EMITTED SINCE 10-D, CHECKED SINCE 11-C. The workspace suite printed this sentinel and the
  // runner never looked for it — a suite that aborted after the readiness file would have gone
  // green. Found while wiring the death-verification sentinel; fixed rather than filed.
  'ALL PROFESSIONAL WORKSPACE ASSERTIONS PASSED',
  'ALL RELEASE-CONDITION ASSERTIONS PASSED',
  'ALL DEATH VERIFICATION ASSERTIONS PASSED',
  'ALL RELEASE SAFETY ASSERTIONS PASSED',
  'ALL SURVIVOR MODE ASSERTIONS PASSED',
  'ALL FIDUCIARY CAPACITY ASSERTIONS PASSED',
  'ALL EXECUTOR WORKSPACE ASSERTIONS PASSED',
  'ALL PHASE 10-F EXIT MATRIX ASSERTIONS PASSED',
]) {
  if (!combined.includes(sentinel)) {
    cleanup();
    console.error(`✗ the suite did not reach "${sentinel}" — it did not run to completion.`);
    process.exit(1);
  }
}
if (okCount < MIN_ASSERTIONS) {
  cleanup();
  console.error(`✗ only ${okCount} assertions reported ok (expected >= ${MIN_ASSERTIONS}).`);
  console.error('  The suite completed but inspected far less than it should — treat as a failure.');
  process.exit(1);
}

if (CAPTURE) {
  // psql prints the jsonb_pretty result between the column header and the row count.
  // The capture file also runs DDL, whose command tags ("DO", "CREATE FUNCTION") share stdout with
  // the result. Take the outermost JSON object rather than assuming the stream is pure.
  const raw = capturedJson;
  const first = raw.indexOf('{');
  const last = raw.lastIndexOf('}');
  const text = first >= 0 && last > first ? raw.slice(first, last + 1) : '';
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    cleanup();
    console.error('✗ capture did not produce parseable JSON — refusing to write a fixture from nothing.');
    console.error(text.slice(0, 300));
    process.exit(1);
  }
  // ★ ASSERT THE CAPTURE IS NON-VACUOUS. An empty object parses fine and would silently become a
  // fixture that proves nothing about the contract.
  const scenarios = Object.keys(parsed);
  if (scenarios.length < 13) {
    cleanup();
    console.error(`✗ capture holds only ${scenarios.length} scenarios; expected every viewer class.`);
    process.exit(1);
  }
  writeFileSync(join(ROOT, 'db/tests/captured_discovery_payloads.json'), `${JSON.stringify(parsed, null, 2)}\n`);
  console.log('✓ wrote db/tests/captured_discovery_payloads.json');
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
