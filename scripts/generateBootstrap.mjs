#!/usr/bin/env node
/**
 * MODEL C — CANONICAL BOOTSTRAP GENERATOR.
 *
 * ★ LOCAL AND OFFLINE. Reads the verified snapshot plus hashed evidence CSVs and writes
 *   db/bootstrap/. It opens no socket and accepts no connection string.
 *
 * ★ IT REFUSES UNVERIFIED EVIDENCE. Every input file's SHA-256 is checked against the pinned
 *   value before a byte of it is used. Generating canonical DDL from an unverified capture would
 *   put unattributable SQL into the one artifact whose whole value is attribution.
 *
 * Usage: node scripts/generateBootstrap.mjs --snapshot <path> --evidence <dir> [--check]
 *   --check  verify the committed bootstrap matches what would be generated (no writes)
 */
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync, rmSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { splitStatements, inventory } from './lib/schemaInventory.mjs';
import { PHASES, buildComponents } from './lib/bootstrapComponents.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const OUT = join(ROOT, 'db/bootstrap');
const argv = process.argv.slice(2);
const arg = (n) => { const i = argv.indexOf(n); return i >= 0 ? argv[i + 1] : null; };
const CHECK = argv.includes('--check');

for (const f of ['--db-url', '--database-url', '--project-ref', '--linked', '--remote', '--production', '--host', '--dsn']) {
  if (argv.some((a) => a.split('=')[0] === f)) { console.error(`REFUSED — ${f} is not accepted. This generator reads files only.`); process.exit(2); }
}

const SNAP = arg('--snapshot');
const EVID = arg('--evidence') ?? join(process.env.HOME ?? '', 'aw-schema-capture');
const die = (m) => { console.error(m); process.exit(2); };
if (!SNAP || !existsSync(SNAP)) die('COULD NOT VERIFY — pass --snapshot <path> to the verified snapshot.');

/** ★ PINNED HASHES. An input that does not match is not used, it is refused. */
const PINNED = {
  'live-schema-20260827.sql': 'a21df219616e2f80e2885d3b29fb61723174300b6909af637bfa8c4f0ea1f8b7',
  'event-trigger-bindings-20260828.csv': 'e5c005cb27f959421a5f33c218eeb3c10819fd3c9b8070b2a31ce5681c1cb0a9',
  'event-trigger-binding-controls-20260828.csv': '7b1c894a4ea851eea768db2066c7be6e30b19aadda15d3a483e656009ed1f21c',
  'storage-policies-20260828.csv': '7b0adbe21f95fc61ff1773c31a1a89b6cbbce27dd819d59f2548a7426c98f13e',
  'storage-policy-controls-20260828.csv': '7bfc85be19b07c0d1518dcbe9290322c2f99468777a9e099d4e6e8796bf422c4',
};
const sha = (p) => createHash('sha256').update(readFileSync(p)).digest('hex');
const verify = (path, name) => {
  if (!existsSync(path)) die(`COULD NOT VERIFY — missing evidence: ${path}`);
  const got = sha(path);
  if (got !== PINNED[name]) die(`REFUSED — ${name} hash mismatch.\n  observed ${got}\n  expected ${PINNED[name]}`);
  return got;
};

const snapHash = (() => {
  const got = sha(SNAP);
  if (got !== PINNED['live-schema-20260827.sql']) die(`REFUSED — snapshot hash mismatch.\n  observed ${got}`);
  return got;
})();
const evidenceHashes = { 'live-schema-20260827.sql': snapHash };
for (const n of ['event-trigger-bindings-20260828.csv', 'event-trigger-binding-controls-20260828.csv',
                 'storage-policies-20260828.csv', 'storage-policy-controls-20260828.csv']) {
  evidenceHashes[n] = verify(join(EVID, n), n);
}

/** RFC4180-ish CSV reader: quoted fields, embedded commas, doubled quotes, embedded newlines. */
export function parseCsv(text) {
  const rows = []; let row = [], f = '', q = false;
  const s = String(text).replace(/\r\n/g, '\n');
  for (let i = 0; i < s.length; i += 1) {
    const c = s[i];
    if (q) { if (c === '"' && s[i + 1] === '"') { f += '"'; i += 1; } else if (c === '"') q = false; else f += c; continue; }
    if (c === '"') { q = true; continue; }
    if (c === ',') { row.push(f); f = ''; continue; }
    if (c === '\n') { row.push(f); rows.push(row); row = []; f = ''; continue; }
    f += c;
  }
  if (f !== '' || row.length) { row.push(f); rows.push(row); }
  const head = rows.shift();
  return rows.filter((r) => r.length === head.length).map((r) => Object.fromEntries(head.map((h, i) => [h, r[i]])));
}

const storagePolicies = parseCsv(readFileSync(join(EVID, 'storage-policies-20260828.csv'), 'utf8'));
const storageControls = parseCsv(readFileSync(join(EVID, 'storage-policy-controls-20260828.csv'), 'utf8'))[0];
const eventTriggers = parseCsv(readFileSync(join(EVID, 'event-trigger-bindings-20260828.csv'), 'utf8'));
const etControls = parseCsv(readFileSync(join(EVID, 'event-trigger-binding-controls-20260828.csv'), 'utf8'))[0];

/* ── EVIDENCE CONTROLS — assert the captures say what the rulings say, before generating ─────── */
const problems = [];
if (storagePolicies.length !== 2) problems.push(`expected 2 storage policies, capture has ${storagePolicies.length}`);
if (Number(storageControls?.policy_count_on_objects) !== 2) problems.push('storage control: policy_count_on_objects != 2');
if (Number(storageControls?.policy_count_whole_storage_schema) !== 2) problems.push('storage control: whole-schema count != 2');
if (String(storageControls?.rls_enabled) !== 'true') problems.push('storage control: storage.objects RLS not enabled');
const names = storagePolicies.map((p) => p.policyname).sort();
if (JSON.stringify(names) !== JSON.stringify(['documents_estate_insert', 'documents_estate_read'])) problems.push(`unexpected storage policy identities: ${names.join(', ')}`);
if (Number(etControls?.total_event_triggers) !== eventTriggers.length) problems.push(`event-trigger control says ${etControls?.total_event_triggers}, capture has ${eventTriggers.length}`);
if (Number(etControls?.rls_auto_enable_bindings) !== 1) problems.push('event-trigger control: rls_auto_enable_bindings != 1');
if (problems.length) die(`REFUSED — evidence controls failed:\n  ${problems.join('\n  ')}`);

/* ── BUILD ───────────────────────────────────────────────────────────────────────────────────── */
const sql = readFileSync(SNAP, 'utf8');
const statements = splitStatements(sql);
const live = inventory(sql);
if (live.unclassified.length) die(`REFUSED — ${live.unclassified.length} snapshot statement(s) unclassified.`);

const { byPhase, unassigned, skipped } = buildComponents({ statements, storagePolicies, eventTriggers });
if (unassigned.length) {
  die(`REFUSED — ${unassigned.length} statement(s) could not be assigned to a bootstrap phase:\n  ${unassigned.slice(0, 5).map((s) => s.slice(0, 120)).join('\n  ')}`);
}

/**
 * ★ RESTORE-CONTRACT PREAMBLE, PER PHASE FILE.
 *
 * pg_dump emits `SET check_function_bodies = false` for a reason: `language sql` bodies ARE
 * validated at creation, and a dump orders functions alphabetically, so a body referencing a
 * function created later fails. The first fresh run failed on exactly that —
 * `estate_lifecycle_state(uuid) does not exist` — because this generator classified the dump's
 * preamble as "session noise" and dropped it. Restoring the setting is not a workaround; it is the
 * contract the authoritative artifact was written against.
 *
 * Each phase is applied as its own psql invocation, so settings do not persist between files and
 * the preamble is repeated rather than stated once.
 *
 * ★ search_path IS SET WHERE PREDICATES ARE UNQUALIFIED. The captured storage policies call
 *   `is_estate_owner(...)` unqualified; policy predicates resolve to OIDs at CREATE time, so
 *   `public` must be on the path or the policy cannot be created at all.
 */
const PREAMBLE = (phaseId) => {
  const lines = ['SET client_min_messages = warning;', 'SET row_security = off;'];
  if (phaseId === '60') lines.push('SET check_function_bodies = false;');
  if (phaseId === '110' || phaseId === '90' || phaseId === '70') lines.push('SET search_path = public, storage, extensions, pg_catalog;');
  return `${lines.join('\n')}\n\n`;
};

const HEADER = (p, n) => `-- ════════════════════════════════════════════════════════════════════════════════════════════
-- MODEL C CANONICAL BOOTSTRAP · ${p.id} · ${p.title}
--
-- GENERATED — do not edit by hand. Regenerate with:
--   node scripts/generateBootstrap.mjs --snapshot <verified snapshot> --evidence <dir>
--
-- DERIVED FROM live authoritative state, NOT from migrations 0001-0060 and NOT from test preambles.
-- This file represents CURRENT authoritative schema through migration 0060.
-- It is NOT a pre-0001 baseline; no pre-0001 schema is recoverable from repository evidence.
--
-- statements: ${n}
-- ════════════════════════════════════════════════════════════════════════════════════════════

`;

const PLATFORM_CONTRACT = `-- ════════════════════════════════════════════════════════════════════════════════════════════
-- MODEL C CANONICAL BOOTSTRAP · 00 · platform contract / prerequisites
--
-- ★ THIS FILE CREATES NOTHING. It REFUSES if the Supabase-owned surface the application depends on
--   is absent. A bootstrap that silently proceeded without auth.users would build a schema whose
--   38 foreign keys and 131 SECURITY DEFINER functions reference a role system that does not
--   exist — and it would look like it worked.
--
-- ★ auth.users, storage.objects, storage.buckets and the anon/authenticated/service_role roles are
--   SUPABASE-PLATFORM-OWNED. They are never created here. A local test shim may create stand-ins,
--   but it lives in test infrastructure and is unmistakably non-production.
-- ════════════════════════════════════════════════════════════════════════════════════════════

do $contract$
declare
  missing text[] := array[]::text[];
begin
  if to_regclass('auth.users') is null then missing := missing || 'table auth.users'; end if;
  if to_regclass('storage.objects') is null then missing := missing || 'table storage.objects'; end if;
  if to_regclass('storage.buckets') is null then missing := missing || 'table storage.buckets'; end if;
  if to_regprocedure('auth.uid()') is null then missing := missing || 'function auth.uid()'; end if;
  if to_regprocedure('auth.jwt()') is null then missing := missing || 'function auth.jwt()'; end if;
  if not exists (select 1 from pg_roles where rolname = 'anon') then missing := missing || 'role anon'; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then missing := missing || 'role authenticated'; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then missing := missing || 'role service_role'; end if;
  -- * The 'extensions' SCHEMA is the prerequisite, not the extensions themselves. pgcrypto and
  --   uuid-ossp are created by phase 10 because the authoritative dump emits CREATE EXTENSION for
  --   them — they are application-installed. An earlier draft of this contract demanded both as
  --   prerequisites AND created them one phase later, which would have refused on every virgin
  --   database. The first fresh run would have caught it; writing the check correctly is better.
  if to_regnamespace('extensions') is null then missing := missing || 'schema extensions'; end if;

  if array_length(missing, 1) > 0 then
    raise exception 'MODEL C BOOTSTRAP REFUSED — required Supabase platform prerequisites are absent: %',
      array_to_string(missing, ', ')
      using hint = 'This bootstrap creates application objects only. Provision the Supabase platform surface first.';
  end if;
end
$contract$;

-- Platform-supplied extensions, recorded as prerequisites and NOT created here.
-- (pg_stat_statements and supabase_vault are installed by Supabase; creating them is not
--  application DDL and may fail or succeed differently depending on role.)
`;

function render() {
  const files = new Map();
  for (const p of PHASES) {
    const items = byPhase.get(p.id) ?? [];
    if (p.id === '00') {
      const notes = items.filter((i) => i.platform).map((i) => `--   ${i.sql.replace(/\s+/g, ' ')};`).join('\n');
      files.set(p.file, `${PLATFORM_CONTRACT}${notes}\n`);
      continue;
    }
    if (items.length === 0) { files.set(p.file, `${HEADER(p, 0)}${PREAMBLE(p.id)}-- (no statements in this phase)\n`); continue; }
    // ★ Evidence-rendered statements already carry their terminator; snapshot statements do not.
    const body = items.map((i) => { const t = i.sql.trim(); return t.endsWith(';') ? t : `${t};`; }).join('\n\n');
    let extra = '';
    if (p.id === '120') {
      extra = `-- ★ HOSTED_COMPATIBILITY_PROOF_REQUIRED
--   CREATE EVENT TRIGGER requires privileges that a hosted Supabase migration role may not hold.
--   A successful local CREATE EVENT TRIGGER does NOT prove hosted compatibility, and this flag is
--   NOT cleared by any local test. Only execution in a real non-production Supabase project can
--   clear it, and R-02 (no non-prod environment exists) currently blocks that.
--
--   Derived from event-trigger-bindings-20260828.csv. Six further event triggers exist live and are
--   owned by supabase_admin (pgrst_ddl_watch, issue_pg_cron_access, …); they are PLATFORM-OWNED and
--   deliberately excluded. Ownership was decided by evtowner, not by name.

`;
    }
    if (p.id === '110') {
      extra = `-- ★ APPLICATION-OWNED POLICIES ON A PLATFORM-OWNED TABLE.
--   storage.objects belongs to Supabase; these two policies belong to AfterWorth. The table is
--   NOT created here. Predicates are emitted verbatim from storage-policies-20260828.csv
--   (sha256 7b0adbe2…f13e) and were never retyped.

`;
    }
    files.set(p.file, `${HEADER(p, items.length)}${PREAMBLE(p.id)}${extra}${body}\n`);
  }
  return files;
}

const files = render();
const counts = Object.fromEntries(PHASES.map((p) => [p.id, (byPhase.get(p.id) ?? []).length]));
const manifest = {
  model: 'C — componentized current-state bootstrap',
  bootstrap_schema_version: '0060',
  generated_from: {
    snapshot: SNAP.split('/').pop(),
    evidence: evidenceHashes,
  },
  classification: 'CURRENT AUTHORITATIVE SCHEMA SNAPSHOT (not a pre-0001 baseline)',
  historical_migrations: { range: '0001-0060', role: 'immutable historical delta records', replayed_during_virgin_bootstrap: false },
  future_migrations: { start: '0061' },
  phases: PHASES.map((p) => ({ ...p, statements: counts[p.id] })),
  totals: {
    statements_emitted: Object.values(counts).reduce((a, b) => a + b, 0),
    statements_skipped_session_or_platform: skipped.length,
    unassigned: unassigned.length,
  },
  live_inventory: {
    tables: live.tables.length, columns: live.columns.length, functions: live.functions.length,
    policies: live.policies.length, indexes: live.indexes.length, triggers: live.triggers.length,
    types: live.types.length, sequences: live.sequences.length, rls_enabled: live.rlsEnabled.length,
    security_definer: live.functions.filter((f) => f.securityDefiner).length,
    security_definer_without_search_path: live.functions.filter((f) => f.securityDefiner && !f.setsSearchPath).length,
  },
  application_owned_on_platform: storagePolicies.map((p) => `${p.schemaname}.${p.tablename}.${p.policyname}`),
  event_triggers: {
    application_owned: eventTriggers.filter((e) => e.event_trigger_owner !== 'supabase_admin').map((e) => e.evtname),
    platform_owned_excluded: eventTriggers.filter((e) => e.event_trigger_owner === 'supabase_admin').map((e) => e.evtname),
    hosted_compatibility_proven: false,
  },
  legacy_compatibility_surface: {
    'public.assets': 'APPLICATION-OWNED LEGACY-COMPATIBILITY SURFACE — consumed at runtime by the shipping SwiftUI client. DROP NOT AUTHORIZED.',
  },
};

if (CHECK) {
  let diffs = 0;
  for (const [name, content] of files) {
    const p = join(OUT, name);
    if (!existsSync(p)) { console.error(`MISSING ${name}`); diffs++; continue; }
    if (readFileSync(p, 'utf8') !== content) { console.error(`DIFFERS ${name}`); diffs++; }
  }
  const mp = join(OUT, 'manifest.json');
  if (!existsSync(mp) || readFileSync(mp, 'utf8') !== `${JSON.stringify(manifest, null, 2)}\n`) { console.error('DIFFERS manifest.json'); diffs++; }
  console.log(diffs === 0 ? 'BOOTSTRAP IN SYNC with the authoritative evidence.' : `BOOTSTRAP DRIFT — ${diffs} file(s) differ. Regenerate.`);
  process.exit(diffs === 0 ? 0 : 1);
}

if (existsSync(OUT)) for (const f of readdirSync(OUT)) if (/\.sql$/.test(f)) rmSync(join(OUT, f));
mkdirSync(OUT, { recursive: true });
for (const [name, content] of files) writeFileSync(join(OUT, name), content);
writeFileSync(join(OUT, 'manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`);
writeFileSync(join(OUT, 'VERSION'), '0060\n');

console.log('MODEL C CANONICAL BOOTSTRAP GENERATED');
console.log('='.repeat(88));
for (const p of PHASES) console.log(`  ${p.id.padStart(3)}  ${p.file.padEnd(30)} ${String(counts[p.id]).padStart(4)} statements`);
console.log(`  total emitted: ${manifest.totals.statements_emitted}  ·  skipped (session/platform): ${skipped.length}  ·  unassigned: ${unassigned.length}`);
