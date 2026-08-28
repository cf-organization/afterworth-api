#!/usr/bin/env node
/**
 * CURRENT AUTHORITATIVE SCHEMA ↔ REPOSITORY RECONCILIATION — the runner.
 *
 * ★ READ-ONLY, LOCAL, OFFLINE. It reads one snapshot file and the tracked contents of db/. It opens
 *   no socket, reads no .env, accepts no connection string and cannot reach Supabase. The snapshot
 *   is produced by the MANUAL, user-run procedure in docs/schema-capture/README.md; this script
 *   never captures one.
 *
 * ★ IT REFUSES A SNAPSHOT THAT CONTAINS DATA. A dump with COPY/INSERT is evidence of the wrong
 *   capture and is rejected rather than parsed, because analysing rows is not this tool's business.
 *
 * Usage:  node scripts/reconcileSchema.mjs --snapshot <path> [--json]
 * Exit:   0 reconciled · 1 gaps present · 2 could not verify
 */
import { existsSync, readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { inventory } from './lib/schemaInventory.mjs';
import { repositoryObjects, reconcile, summarize, parseHealth, GAP_DISPOSITIONS } from './lib/schemaReconcile.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const argv = process.argv.slice(2);
const JSON_OUT = argv.includes('--json');

const FORBIDDEN = ['--database-url', '--db-url', '--project-ref', '--linked', '--remote', '--production', '--host', '--dsn'];
for (const a of argv) {
  if (FORBIDDEN.includes(a.split('=')[0])) {
    console.error(`REFUSED — ${a.split('=')[0]} is not accepted. This tool reads a file that a human captured; it never connects to a database.`);
    process.exit(2);
  }
}

const i = argv.indexOf('--snapshot');
const snapPath = i >= 0 ? argv[i + 1] : null;
const die = (msg) => { console.error(msg); process.exit(2); };
if (!snapPath) die('COULD NOT VERIFY — pass --snapshot <path>. See docs/schema-capture/README.md for how to obtain one.');
if (!existsSync(snapPath)) die(`COULD NOT VERIFY — no such snapshot: ${snapPath}`);

const sql = readFileSync(snapPath, 'utf8');
if (!sql.trim()) die('COULD NOT VERIFY — the snapshot is empty. Empty input is a failure, never "clean".');
const dataLines = (sql.match(/^(COPY |INSERT INTO)/gm) ?? []).length;
if (dataLines > 0) die(`REFUSED — the snapshot contains ${dataLines} data statement(s). Recapture schema-only; do not edit the file.`);

const live = inventory(sql);
if (live.tables.length === 0) die('COULD NOT VERIFY — the snapshot parsed to zero tables. A scan set of nothing proves nothing.');
if (live.unclassified.length > 0) {
  die(`COULD NOT VERIFY — ${live.unclassified.length} statement(s) in the snapshot were not understood:\n  ${live.unclassified.slice(0, 5).map((s) => s.slice(0, 120)).join('\n  ')}`);
}

const paths = execFileSync('git', ['ls-files', 'db/'], { cwd: ROOT, encoding: 'utf8' })
  .trim().split('\n').filter((p) => p.endsWith('.sql'));
if (paths.length === 0) die('COULD NOT VERIFY — the repository scan set is empty.');
const repo = repositoryObjects(paths.map((p) => ({ path: p, sql: readFileSync(join(ROOT, p), 'utf8') })));
if (repo.unknownPaths.length) die(`COULD NOT VERIFY — unclassified source paths:\n  ${repo.unknownPaths.join('\n  ')}`);

// ★ PARSE HEALTH GATES THE VERDICT. Computed before coverage, so a blind instrument refuses
//   instead of reporting a number that looks like a finding.
const health = parseHealth({ live, repo });
if (!health.ok) {
  console.error('CANNOT RECONCILE — the instrument is not fit to make a claim:');
  for (const pr of health.problems) console.error(`  · ${pr}`);
  process.exit(2);
}

const rows = reconcile({ live, repo });
const gaps = rows.filter((r) => GAP_DISPOSITIONS.includes(r.disposition));

if (JSON_OUT) {
  console.log(JSON.stringify({ snapshot: snapPath, live: Object.fromEntries(Object.entries(live).map(([k, v]) => [k, v.length])), summary: summarize(rows), rows }, null, 2));
} else {
  console.log('CURRENT AUTHORITATIVE SCHEMA ↔ REPOSITORY RECONCILIATION');
  console.log('='.repeat(96));
  console.log(`  snapshot                ${snapPath}`);
  console.log(`  repository files        ${paths.length}`);
  console.log(`  live objects            ${rows.length}`);
  console.log('');
  const sum = summarize(rows);
  const cols = ['COVERED', 'DUPLICATE_BASE', 'TEST_ONLY_DEFINITION', 'DELTA_ONLY_NO_BASE', 'NON_BOOTSTRAP_SOURCE_ONLY', 'NO_REPO_DEFINITION'];
  console.log('  kind'.padEnd(12) + cols.map((c) => c.slice(0, 11).padStart(12)).join(''));
  for (const [k, v] of Object.entries(sum)) console.log('  ' + k.padEnd(10) + cols.map((c) => String(v[c] ?? 0).padStart(12)).join(''));
  console.log('');
  console.log('  ★ THE NAMES ARE THE FINDING — a count has been wrong here before.');
  for (const d of GAP_DISPOSITIONS) {
    const g = gaps.filter((r) => r.disposition === d);
    if (!g.length) continue;
    console.log(`\n  ${d} (${g.length}):`);
    for (const r of g) console.log(`    ${r.kind.padEnd(10)} ${r.name}${r.repo_definitions.length ? `   [${r.repo_definitions.join(', ')}]` : ''}`);
  }
  console.log('');
  console.log(`VERDICT : ${gaps.length === 0 ? 'REPOSITORY_COVERS_LIVE' : `BOOTSTRAP_GAP (${gaps.length})`}`);
}
process.exit(gaps.length === 0 ? 0 : 1);
