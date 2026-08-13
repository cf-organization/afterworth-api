#!/usr/bin/env node
/**
 * PHASE 11-H STAGE 1 — the fiduciary authority census, DERIVED rather than remembered.
 *
 * ★ THE QUESTION THIS ANSWERS. Phase 11-H asks whether fiduciary WORKFLOW authority can exist
 * without collapsing into DISCLOSURE authority. That is an empirical question about what the
 * deployed source actually gates on, and the honest way to ask it is to read every client-reachable
 * routine and classify the gate it carries — not to consult a design document that describes what
 * someone intended.
 *
 * ★ WHY A GATE CENSUS AND NOT A GREP FOR "executor". A routine that merely mentions
 * `is_estate_executor` tells us nothing: it might call it to ALLOW a workflow, or to REFUSE a
 * disclosure. The distinction between those two is the entire subject of this phase, so the script
 * classifies each routine on two independent axes:
 *
 *     WHAT IT RETURNS  — does it read data out (disclosure) or write data in (mutation)?
 *     WHAT IT ASKS     — ownership, fiduciary designation, membership, admin, or a grant?
 *
 * A fiduciary designation appearing on the MUTATION axis is the architecture working. The same
 * designation appearing on the DISCLOSURE axis is capacity inflating a tier, which is the defect
 * this phase exists to prevent.
 *
 * ★ THE SCAN SET IS ASSERTED BEFORE ANY RULE RUNS. A census that resolves its root one directory
 * short reads every file as an empty string and reports a confident, meaningless clean — the
 * Dashboard near-miss recorded in AGENTS.md, where 63 assertions passed against nothing.
 *
 * Exit 0 = report produced. Exit 2 = could not scan (never "clean").
 * Usage: node scripts/reconFiduciaryAuthority.mjs [--json]
 */
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const JSON_OUT = process.argv.includes('--json');

/** Comments stripped so prose describing a prohibition is never counted as the prohibition. */
const stripSql = (raw) =>
  raw.split('\n').filter((l) => !/^\s*--/.test(l)).map((l) => l.replace(/\s--.*$/, '')).join('\n');

const walk = (rel, filter) => {
  const abs = join(ROOT, rel);
  if (!existsSync(abs)) return [];
  return readdirSync(abs, { withFileTypes: true }).flatMap((e) =>
    e.isDirectory() ? walk(join(rel, e.name), filter) : filter(e.name) ? [join(rel, e.name)] : []
  );
};

/**
 * ★ THE SCAN SET COVERS EVERY db/ SUBDIRECTORY THAT DEFINES AUTHORITY, AND THAT WAS A CORRECTION.
 * The first version of this census read only `db/functions` and `db/migrations`. `db/tables` holds
 * the RLS policies — and one of them, `instructions_executor_read_after_release`, is a DISCLOSURE
 * surface gated on a fiduciary designation. The census reported "no instruction table defined" and
 * "capacity never reaches disclosure", both confidently, both against a scan set that could not see
 * the file. It was caught only because a positive control (`encrypted_instructions`, known present
 * from a direct grep) came back absent.
 *
 * Hence POSITIVE_CONTROLS below: the census now proves it can find known-present objects before it
 * reports that anything is missing.
 */
const SQL = [
  ...walk('db/functions', (f) => f.endsWith('.sql')),
  ...walk('db/migrations', (f) => f.endsWith('.sql')),
  ...walk('db/tables', (f) => f.endsWith('.sql')),
];

/* ★ SCAN-SET ASSERTION — before any rule reads anything. */
if (!existsSync(join(ROOT, 'db/functions'))) {
  console.error(`✗ CANNOT SCAN — db/functions missing under resolved ROOT ${ROOT}`);
  process.exit(2);
}
if (SQL.length < 40) {
  console.error(`✗ CANNOT SCAN — scan set implausible (${SQL.length} files under ${ROOT}).`);
  process.exit(2);
}

const CODE = new Map(SQL.map((f) => [f, stripSql(readFileSync(join(ROOT, f), 'utf8'))]));
const ALL = [...CODE.values()].join('\n');

/**
 * ★ POSITIVE CONTROLS RUN BEFORE ANY ABSENCE IS REPORTED. Each is an object known to exist in this
 * repository. If the census cannot find one, it has proved only that it cannot find things — so it
 * refuses to assess absence at all rather than printing a clean report it has not earned.
 */
const POSITIVE_CONTROLS = [
  ['table  encrypted_instructions', /create table (?:if not exists )?public\.encrypted_instructions/],
  ['policy instructions_executor_read_after_release', /instructions_executor_read_after_release/],
  ['fn     is_estate_executor', /create or replace function public\.is_estate_executor/],
  ['fn     get_estate_discovery', /create or replace function public\.get_estate_discovery/],
  ['fn     release_condition_satisfied', /create or replace function public\.release_condition_satisfied/],
];
const failedControls = POSITIVE_CONTROLS.filter(([, re]) => !re.test(ALL)).map(([n]) => n);
if (failedControls.length > 0) {
  console.error('✗ FAILED POSITIVE CONTROL — the census cannot see objects known to be present:');
  for (const n of failedControls) console.error(`    ${n}`);
  console.error('  Nothing is asserted about absence. Fix the scan set first.');
  process.exit(2);
}

/**
 * Every routine defined anywhere, with its body.
 * ★ The body ends at the dollar-quote terminator, so one file holding many routines does not
 * smear one routine's gates onto its neighbour — the mistake that would make every routine in
 * a file look owner-gated because the first one is.
 */
function routines() {
  const out = new Map();
  for (const [file, code] of CODE) {
    const re = /create or replace function public\.([a-z0-9_]+)\s*\(/g;
    let m;
    while ((m = re.exec(code)) !== null) {
      const rest = code.slice(m.index);
      const endRel = rest.search(/\$function\$;|\$\$;/);
      out.set(m[1], { name: m[1], file, body: rest.slice(0, endRel === -1 ? 6000 : endRel) });
    }
  }
  return out;
}
const R = routines();

/** Client-reachable = explicitly granted to the authenticated PostgREST role. */
const grantedTo = (name, role) =>
  new RegExp(`grant\\s+execute\\s+on\\s+function\\s+public\\.${name}\\b[^;]*to\\s+${role}\\b`, 'i').test(ALL);
const revokedFromAll = (name) =>
  new RegExp(`revoke\\s+(all|execute)[^;]*public\\.${name}\\b[^;]*from\\s+(public|anon|authenticated)`, 'i').test(ALL);

/**
 * ★ THE TWO AXES. `mutates` is deliberately structural (does the body write?) rather than
 * name-based: a routine called `get_*` that performs an insert is exactly the kind of thing a
 * name-based classifier would wave through.
 */
const classify = (r) => {
  const b = r.body;
  const mutates = /\b(insert\s+into|update\s+public\.|delete\s+from)\b/.test(b);
  return {
    name: r.name,
    file: r.file,
    definer: /security definer/.test(b),
    mutates,
    kind: mutates ? 'MUTATION' : 'DISCLOSURE',
    gates: {
      owner: /is_estate_owner/.test(b),
      fiduciary: /is_estate_executor/.test(b),
      membership: /estate_memberships/.test(b),
      admin: /admin_require_gate|is_platform_admin/.test(b),
      grant: /access_grants|can_access_document|release_condition_satisfied/.test(b),
      lifecycle: /estate_lifecycle_state|'released'/.test(b),
    },
    tierWords: /visibility_tier|inventory_tier|full_detail|limited_detail|category_summary/.test(b),
    clientAuthed: grantedTo(r.name, 'authenticated'),
    clientAnon: grantedTo(r.name, 'anon'),
    revoked: revokedFromAll(r.name),
  };
};

const rows = [...R.values()].map(classify);
const report = { root: ROOT, scanSet: SQL.length, routines: rows.length };

/* ── 1 · THE FIDUCIARY SURFACE ──────────────────────────────────────────────────────────────── */
report.fiduciary = rows.filter((r) => r.gates.fiduciary);

/* ── 2 · THE LOAD-BEARING INVARIANT ─────────────────────────────────────────────────────────────
 * A routine that consults a fiduciary designation AND resolves a disclosure tier is the exact
 * shape of "capacity inflates tier". This is the census's primary finding, so it is computed
 * rather than eyeballed.
 */
report.capacityTouchesTier = rows.filter((r) => r.gates.fiduciary && r.tierWords && !r.mutates);

/* ── 3 · WHAT A FIDUCIARY DESIGNATION ACTUALLY UNLOCKS, SPLIT BY AXIS ───────────────────────── */
report.fiduciaryDisclosure = report.fiduciary.filter((r) => r.kind === 'DISCLOSURE');
report.fiduciaryMutation = report.fiduciary.filter((r) => r.kind === 'MUTATION');

/* ── 4 · THE DESIGNATION VOCABULARY ─────────────────────────────────────────────────────────────
 * ★ EXECUTOR AND TRUSTEE MAY OR MAY NOT BE DISTINGUISHABLE. The brief treats them as two
 * capacities; whether the SOURCE does is a fact to be read, not assumed.
 */
report.designationTypes = [...new Set(
  [...ALL.matchAll(/designation_type\s*(?:=|in)\s*\(?\s*((?:'[a-z_]+'\s*,?\s*)+)\)?/g)]
    .flatMap((m) => [...m[1].matchAll(/'([a-z_]+)'/g)].map((x) => x[1]))
)].sort();
report.membershipRoles = [...new Set(
  [...ALL.matchAll(/role\s*(?:=|in)\s*\(?\s*((?:'[a-z_]+'\s*,?\s*)+)\)?/g)]
    .flatMap((m) => [...m[1].matchAll(/'([a-z_]+)'/g)].map((x) => x[1]))
)].sort();
// Does any routine distinguish executor from trustee, or are they one predicate?
report.executorTrusteeDistinguished = rows.filter(
  (r) => /'executor'/.test(r.body ?? '') !== /'trustee'/.test(r.body ?? '')
).length > 0 || /designation_type\s*=\s*'(executor|trustee)'/.test(ALL);

/* ── 5 · INSTRUCTIONS (Stage 5) ─────────────────────────────────────────────────────────────────
 * ★ NEVER ASSUME AN INSTRUCTION SURFACE IS SURVIVOR-FACING OR EXECUTOR-FACING. Report what
 * exists, including the possibility that it is scaffold with no routine at all.
 */
const instructionTables = [...new Set(
  [...ALL.matchAll(/create table (?:if not exists )?public\.([a-z_]*instruction[a-z_]*)/g)].map((m) => m[1])
)];
report.instructions = instructionTables.map((t) => ({
  table: t,
  readingRoutines: rows.filter((r) => new RegExp(`\\b${t}\\b`).test(R.get(r.name).body) && !r.mutates).map((r) => r.name),
  writingRoutines: rows.filter((r) => new RegExp(`\\b${t}\\b`).test(R.get(r.name).body) && r.mutates).map((r) => r.name),
  hasRlsPolicy: new RegExp(`create policy[^;]*on public\\.${t}`, 'i').test(ALL),
}));

/* ── 6 · CLIENT-REACHABLE MUTATION DOORS AND THEIR GATES ────────────────────────────────────── */
report.clientMutations = rows.filter((r) => r.mutates && r.clientAuthed);

/* ── 7 · RLS POLICIES AS A DISCLOSURE SURFACE (the axis the first census could not see) ────────
 * ★ A POLICY IS AN AUTHORIZATION RULE THAT NO ROUTINE CENSUS CAN SEE. `select` policies gated on a
 * fiduciary designation are disclosure granted by capacity — the exact shape this phase watches —
 * so they are enumerated separately and their client reachability is DERIVED, never read from a
 * comment claiming the table is ungranted.
 */
const policies = [...ALL.matchAll(/create policy\s+([a-z0-9_]+)\s+on\s+public\.([a-z0-9_]+)([\s\S]*?);/g)]
  .map((m) => ({
    policy: m[1],
    table: m[2],
    forSelect: /\bfor\s+select\b/.test(m[3]),
    forAll: /\bfor\s+all\b/.test(m[3]),
    fiduciaryGated: /is_estate_executor/.test(m[3]),
    ownerGated: /owner_id\s*=\s*auth\.uid\(\)|is_estate_owner/.test(m[3]),
    releaseGated: /released\s*=\s*true|release_condition_satisfied/.test(m[3]),
  }));
report.policies = policies;
report.fiduciaryReadPolicies = policies.filter((p) => p.fiduciaryGated && (p.forSelect || p.forAll));

/**
 * ★ REACHABILITY IS DERIVED. A policy on a table no client role may touch grants nothing. This
 * asks the source for a table-level GRANT rather than believing the note beside it.
 */
const tableGrantedToClient = (t) =>
  new RegExp(`grant\\s+[a-z, ]*\\bon\\b\\s+(table\\s+)?public\\.${t}\\b[^;]*to\\s+(anon|authenticated)`, 'i').test(ALL);
report.fiduciaryReadPolicies = report.fiduciaryReadPolicies.map((p) => ({
  ...p,
  tableClientGranted: tableGrantedToClient(p.table),
  definerRoutineReads: rows.filter((r) => r.definer && new RegExp(`\\b${p.table}\\b`).test(R.get(r.name).body)).map((r) => r.name),
}));

/* ── 8 · DIVERGENT RELEASE VOCABULARIES ────────────────────────────────────────────────────────
 * ★ A SECOND RELEASE VOCABULARY IS A SECOND RELEASE ENGINE WAITING TO BE WIRED. The canonical
 * predicate owns one vocabulary; any table carrying its own release words is a place where a
 * future edit could authorize disclosure without consulting it.
 */
report.releaseVocabularies = [...new Set(
  [...ALL.matchAll(/release_condition\s+text[^;]*check\s*\([^)]*in\s*\(([^)]*)\)/g)]
    .map((m) => [...m[1].matchAll(/'([a-z_]+)'/g)].map((x) => x[1]).sort().join(','))
)];

if (JSON_OUT) { console.log(JSON.stringify(report, null, 2)); process.exit(0); }

const H = (s) => console.log(`\n══ ${s} ${'═'.repeat(Math.max(0, 76 - s.length))}`);
console.log(`PHASE 11-H · FIDUCIARY AUTHORITY CENSUS`);
console.log(`   root ${ROOT}`);
console.log(`   ${SQL.length} SQL sources · ${rows.length} routines defined`);

H('1 · EVERY ROUTINE THAT CONSULTS A FIDUCIARY DESIGNATION');
console.log('   name                                   axis        | owner fid memb admin grant life | client');
for (const r of report.fiduciary) {
  const y = (b) => (b ? '  ✓  ' : '  ·  ');
  const g = r.gates;
  console.log(`   ${r.name.padEnd(38)}${r.kind.padEnd(12)}|${y(g.owner)}${y(g.fiduciary)}${y(g.membership)}${y(g.admin)}${y(g.grant)}${y(g.lifecycle)}| ${r.clientAuthed ? 'authed' : r.revoked ? 'REVOKED' : 'internal'}`);
}

H('2 · ★ THE LOAD-BEARING INVARIANT — does CAPACITY reach a TIER?');
if (report.capacityTouchesTier.length === 0) {
  console.log('   NONE. No read-side routine both consults a fiduciary designation and resolves a');
  console.log('   disclosure tier. Fiduciary capacity does not inflate disclosure in source.');
} else {
  console.log('   ⚠ CAPACITY REACHES TIER in:');
  for (const r of report.capacityTouchesTier) console.log(`     - ${r.name}  (${r.file})`);
}

H('3 · WHAT A DESIGNATION UNLOCKS, BY AXIS');
console.log(`   DISCLOSURE routines consulting a designation: ${report.fiduciaryDisclosure.length}`);
for (const r of report.fiduciaryDisclosure) console.log(`     - ${r.name}`);
console.log(`   MUTATION routines consulting a designation:   ${report.fiduciaryMutation.length}`);
for (const r of report.fiduciaryMutation) console.log(`     - ${r.name}`);

H('4 · VOCABULARY');
console.log(`   designation types: ${report.designationTypes.join(', ') || '(none found)'}`);
console.log(`   membership roles:  ${report.membershipRoles.join(', ') || '(none found)'}`);
console.log(`   executor vs trustee distinguished anywhere: ${report.executorTrusteeDistinguished}`);

H('5 · INSTRUCTION SURFACES');
if (report.instructions.length === 0) console.log('   (no instruction table defined)');
for (const i of report.instructions) {
  console.log(`   ${i.table}`);
  console.log(`      RLS policy: ${i.hasRlsPolicy} · readers: ${i.readingRoutines.join(', ') || 'NONE'} · writers: ${i.writingRoutines.join(', ') || 'NONE'}`);
  if (i.readingRoutines.length === 0 && i.writingRoutines.length === 0) {
    console.log('      → DORMANT SCAFFOLD: no routine reads or writes this table.');
  }
}

H('6 · CLIENT-REACHABLE MUTATION DOORS');
console.log('   name                                   | owner fid memb admin');
for (const r of report.clientMutations) {
  const y = (b) => (b ? '  ✓  ' : '  ·  ');
  console.log(`   ${r.name.padEnd(38)}|${y(r.gates.owner)}${y(r.gates.fiduciary)}${y(r.gates.membership)}${y(r.gates.admin)}`);
}

H('7 · ★ RLS POLICIES GRANTING READ ON A FIDUCIARY DESIGNATION');
if (report.fiduciaryReadPolicies.length === 0) {
  console.log('   NONE.');
} else {
  for (const p of report.fiduciaryReadPolicies) {
    console.log(`   ${p.policy}`);
    console.log(`      on public.${p.table} · select=${p.forSelect} · release-gated=${p.releaseGated}`);
    console.log(`      table granted to a CLIENT role: ${p.tableClientGranted}`);
    console.log(`      SECURITY DEFINER routines reading it: ${p.definerRoutineReads.join(', ') || 'NONE'}`);
    console.log(`      → ${p.tableClientGranted || p.definerRoutineReads.length > 0
      ? 'REACHABLE — capacity grants disclosure here'
      : 'UNREACHABLE by any client path: no table grant, no DEFINER reader (dormant scaffold)'}`);
  }
}

H('8 · RELEASE VOCABULARIES FOUND IN TABLE CHECKS');
for (const v of report.releaseVocabularies) console.log(`   ${v}`);
if (report.releaseVocabularies.length > 1) {
  console.log('   ⚠ MORE THAN ONE release vocabulary exists in table constraints.');
}

console.log('\n(report only — no gate)');
