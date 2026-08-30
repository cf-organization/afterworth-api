#!/usr/bin/env node
/**
 * MODEL C — FRESH VIRGIN BOOTSTRAP RUN + DRIFT AUDIT.
 *
 * ★ CONTAINER-OWNED, NO REMOTE TARGET EXPRESSIBLE. Same posture as the migration rehearsal: no
 *   --database-url, no project ref, no .env read. It creates a container it names, and destroys it.
 *
 * ★ WHAT IT PROVES AND WHAT IT DOES NOT. It proves the canonical bootstrap builds the authoritative
 *   schema from nothing, deterministically, twice. It does NOT prove hosted Supabase compatibility:
 *   this container grants superuser, and hosted Supabase does not. CREATE EVENT TRIGGER is the
 *   sharp edge — it succeeds here and may fail there.
 *
 * Usage: node scripts/bootstrapFreshRun.mjs --snapshot <path> [--run N] [--json] [--mutate <spec>]
 * Exit:  0 equivalent · 1 drift · 2 could not verify
 */
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { inventory } from './lib/schemaInventory.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const BOOT = join(ROOT, 'db/bootstrap');
const argv = process.argv.slice(2);
const arg = (n) => { const i = argv.indexOf(n); return i >= 0 ? argv[i + 1] : null; };
const JSON_OUT = argv.includes('--json');
const KEEP = argv.includes('--keep');
const MUTATE = arg('--mutate');
/**
 * ★ THE POSTGRES MAJOR VERSION IS SELECTABLE, AND THAT MATTERS. The hosted target reports
 *   PostgreSQL 17.6; rehearsing on 16 would leave a version gap between the local proof and the
 *   thing it is meant to inform. Default stays 16 so existing evidence remains reproducible.
 */
const PG_IMAGE = arg('--pg-image') ?? 'postgres:16';
const RUN = arg('--run') ?? '1';

for (const f of ['--database-url', '--db-url', '--project-ref', '--linked', '--remote', '--production', '--host', '--dsn']) {
  if (argv.some((a) => a.split('=')[0] === f)) { console.error(`REFUSED — ${f} is not accepted.`); process.exit(2); }
}
const SNAP = arg('--snapshot');
const die = (m, code = 2) => { console.error(m); process.exit(code); };
if (!SNAP || !existsSync(SNAP)) die('COULD NOT VERIFY — pass --snapshot <verified snapshot>.');

const CONTAINER = `aw-model-c-bootstrap-${RUN}-${process.pid}`;
if (spawnSync('docker', ['info'], { stdio: 'ignore' }).status !== 0) die('COULD NOT VERIFY — Docker unavailable. The bootstrap must be EXECUTED, not described.');

const phaseFiles = readdirSync(BOOT).filter((f) => /^\d+_.*\.sql$/.test(f))
  .sort((a, b) => Number(a.split('_')[0]) - Number(b.split('_')[0]));
if (phaseFiles.length === 0) die('COULD NOT VERIFY — no bootstrap phase files. An empty run proves nothing.');

const rm = () => { if (!KEEP) spawnSync('docker', ['rm', '-f', CONTAINER], { stdio: 'ignore' }); };
rm();
if (spawnSync('docker', ['run', '-d', '--name', CONTAINER, '-e', 'POSTGRES_PASSWORD=bootstrap', PG_IMAGE], { encoding: 'utf8' }).status !== 0) {
  die('COULD NOT VERIFY — failed to start the container.');
}

let verdict = 'UNVERIFIABLE'; let failure = null; const applied = [];
const out = [];
const say = (s) => { out.push(s); if (!JSON_OUT) console.log(s); };

try {
  let ready = false;
  for (let i = 0; i < 90; i += 1) {
    if (spawnSync('docker', ['exec', CONTAINER, 'pg_isready', '-U', 'postgres'], { stdio: 'ignore' }).status === 0) { ready = true; break; }
    spawnSync('sleep', ['1']);
  }
  if (!ready) throw new Error('postgres never became ready');

  const psql = (sql) => spawnSync('docker', ['exec', '-i', CONTAINER, 'psql', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-q', '-f', '-'],
    { input: sql, encoding: 'utf8', maxBuffer: 128 * 1024 * 1024 });
  const q = (sql) => { const r = spawnSync('docker', ['exec', '-i', CONTAINER, 'psql', '-U', 'postgres', '-tAc', sql], { encoding: 'utf8' }); return r.status === 0 ? r.stdout.trim() : null; };

  say(`MODEL C FRESH BOOTSTRAP RUN #${RUN}`);
  say('='.repeat(92));
  say(`  container   ${CONTAINER} (created by this run, destroyed in finally)`);
  say(`  image       ${PG_IMAGE}`);

  // ★ PROVE THE DATABASE IS ACTUALLY EMPTY. A "fresh" run against a dirty container proves nothing.
  const pre = Number(q("select count(*) from information_schema.tables where table_schema='public'") ?? -1);
  if (pre !== 0) throw new Error(`container is not virgin: ${pre} public tables already present`);
  say(`  virgin check public tables=${pre}`);

  // Platform shim — test infrastructure, never production.
  const shim = readFileSync(join(BOOT, 'testing/PLATFORM_SHIM_NOT_PRODUCTION.sql'), 'utf8');
  const sr = psql(shim);
  if (sr.status !== 0) throw new Error(`platform shim failed:\n${(sr.stderr || '').slice(0, 900)}`);
  say('  platform shim applied (auth/storage/roles/extensions) — NOT production DDL');

  for (const f of phaseFiles) {
    let sql = readFileSync(join(BOOT, f), 'utf8');
    if (MUTATE) sql = applyMutation(sql, f, MUTATE);
    const r = psql(sql);
    if (r.status !== 0) { failure = { file: f, stderr: (r.stderr || '').trim().split('\n').slice(0, 12).join('\n') }; break; }
    applied.push(f);
  }
  if (failure) {
    verdict = 'BOOTSTRAP_FAILED';
    say(`  applied ${applied.length}/${phaseFiles.length} before failure`);
    say(`  FIRST FAILING PHASE  ${failure.file}`);
    for (const l of failure.stderr.split('\n')) say(`    ${l}`);
  } else {
    say(`  applied ${applied.length}/${phaseFiles.length} phases`);
    const built = {
      tables: Number(q("select count(*) from information_schema.tables where table_schema='public' and table_type='BASE TABLE'") ?? 0),
      columns: Number(q("select count(*) from information_schema.columns where table_schema='public'") ?? 0),
      functions: Number(q("select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'") ?? 0),
      secdef: Number(q("select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef") ?? 0),
      secdefNoPath: Number(q("select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.prosecdef and (p.proconfig is null or not exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%'))") ?? 0),
      // * CONSTRAINT-BACKED INDEXES ARE NOT `CREATE INDEX` STATEMENTS. Postgres creates a *_pkey
      //   index for every PRIMARY KEY and a backing index for every UNIQUE constraint; pg_indexes
      //   lists them, pg_dump never emits them. Comparing the two directly reported 43 phantom
      //   "extra" indexes that the bootstrap had not created and could not have. The constraints
      //   themselves are compared separately, so nothing goes unchecked by this exclusion.
      indexes: Number(q("select count(*) from pg_index i join pg_class c on c.oid=i.indexrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and not exists (select 1 from pg_constraint k where k.conindid=i.indexrelid)") ?? 0),
      triggers: Number(q("select count(*) from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and not t.tgisinternal") ?? 0),
      rlsEnabled: Number(q("select count(*) from pg_tables where schemaname='public' and rowsecurity") ?? 0),
      rlsForced: Number(q("select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relforcerowsecurity") ?? 0),
      policies: Number(q("select count(*) from pg_policies where schemaname='public'") ?? 0),
      storagePolicies: Number(q("select count(*) from pg_policies where schemaname='storage' and tablename='objects'") ?? 0),
      types: Number(q("select count(*) from pg_type t join pg_namespace n on n.oid=t.typnamespace where n.nspname='public' and t.typtype='e'") ?? 0),
      sequences: Number(q("select count(*) from information_schema.sequences where sequence_schema='public'") ?? 0),
      constraints: Number(q("select count(*) from pg_constraint where connamespace='public'::regnamespace") ?? 0),
      eventTriggers: Number(q("select count(*) from pg_event_trigger where evtname='ensure_rls'") ?? 0),
      assets: Number(q("select count(*) from information_schema.tables where table_schema='public' and table_name='assets'") ?? 0),
    };
    const objects = {
      tables: (q("select string_agg(table_name, ',' order by table_name) from information_schema.tables where table_schema='public' and table_type='BASE TABLE'") ?? '').split(',').filter(Boolean),
      functions: (q("select string_agg(p.proname, ',' order by p.proname) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'") ?? '').split(',').filter(Boolean),
      policies: (q("select string_agg(tablename||'.'||policyname, ',' order by tablename, policyname) from pg_policies where schemaname='public'") ?? '').split(',').filter(Boolean),
      rls: (q("select string_agg(tablename, ',' order by tablename) from pg_tables where schemaname='public' and rowsecurity") ?? '').split(',').filter(Boolean),
      storagePolicies: (q("select string_agg(policyname||':'||cmd, ',' order by policyname) from pg_policies where schemaname='storage' and tablename='objects'") ?? '').split(',').filter(Boolean),
      eventTriggerTags: q("select array_to_string(evttags, '|') from pg_event_trigger where evtname='ensure_rls'") ?? '',
      policyRoles: (q("select string_agg(tablename||'.'||policyname||'='||array_to_string(roles,'+'), ',' order by tablename, policyname) from pg_policies where schemaname='public'") ?? '').split(',').filter(Boolean),
      policyCmds: (q("select string_agg(tablename||'.'||policyname||'='||cmd, ',' order by tablename, policyname) from pg_policies where schemaname='public'") ?? '').split(',').filter(Boolean),
      columnTypes: (q("select string_agg(table_name||'.'||column_name||':'||data_type||':'||is_nullable||':'||coalesce(column_default,'-'), ',' order by table_name, column_name) from information_schema.columns where table_schema='public'") ?? '').split(',').filter(Boolean),
      // * NEWLINES INSIDE A PREDICATE ARE FLATTENED IN SQL, BEFORE AGGREGATION. pg_policies
      //   deparses subqueries across several lines; aggregating on a newline delimiter split one
      //   policy into several rows and made two predicates look like drift. The row delimiter must
      //   be a character the payload cannot contain.
      policyPredicates: (q("select string_agg(tablename||'.'||policyname||'|'||regexp_replace(coalesce(qual,'-'), '\\s+', ' ', 'g')||'|'||regexp_replace(coalesce(with_check,'-'), '\\s+', ' ', 'g'), chr(30) order by tablename, policyname) from pg_policies where schemaname='public'") ?? '').split(String.fromCharCode(30)).filter(Boolean),
      indexes: (q("select string_agg(c.relname, ',' order by c.relname) from pg_index i join pg_class c on c.oid=i.indexrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and not exists (select 1 from pg_constraint k where k.conindid=i.indexrelid)") ?? '').split(',').filter(Boolean),
      triggers: (q("select string_agg(c.relname||'.'||t.tgname, ',' order by c.relname, t.tgname) from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and not t.tgisinternal") ?? '').split(',').filter(Boolean),
      constraints: (q("select string_agg(conrelid::regclass::text||'.'||conname, ',' order by conrelid::regclass::text, conname) from pg_constraint where connamespace='public'::regnamespace") ?? '').split(',').filter(Boolean),
    };
    const audit = driftAudit(built, objects);
    verdict = audit.ok ? 'BOOTSTRAP_EQUIVALENT' : 'BOOTSTRAP_DRIFT';
    say('');
    say('  DRIFT AUDIT vs CURRENT AUTHORITATIVE SCHEMA');
    for (const l of audit.lines) say(`    ${l}`);
    if (!audit.ok) { say(''); for (const p of audit.problems) say(`    ✗ ${p}`); }
    if (JSON_OUT) out.push(JSON.stringify({ verdict, built, audit: audit.problems }, null, 2));
  }
} catch (e) {
  verdict = 'UNVERIFIABLE';
  say(`  COULD NOT VERIFY — ${String(e?.message ?? e).slice(0, 600)}`);
} finally { rm(); }

say('');
say(`VERDICT : ${verdict}`);
if (JSON_OUT) console.log(JSON.stringify({ run: RUN, verdict, applied, failure }, null, 2));
process.exit(verdict === 'BOOTSTRAP_EQUIVALENT' ? 0 : verdict === 'UNVERIFIABLE' ? 2 : 1);

/* ── the authoritative target, parsed from the verified snapshot + hashed supplements ─────────── */
/** Normalize a predicate for semantic comparison: drop quoting, collapse whitespace, drop casts. */
function normPred(s) {
  // * NEVER LOWERCASE A PREDICATE — it would erase a real distinction between 'USD' and 'usd'.
  //   Only quoting, casts, schema-qualification and whitespace are normalized. pg_policies deparses
  //   `public.is_estate_owner(...)` as `is_estate_owner(...)`; both spellings mean one function.
  return String(s)
    .replace(/"/g, '')
    .replace(/::[a-z_ ]+(\[\])?/gi, '')
    .replace(/\bpublic\./g, '')
    .replace(/[()\s]+/g, ' ')
    .trim();
}
/** information_schema.data_type spellings for the types this schema uses. */
function pgType(t) {
  // information_schema.data_type reports the base type without precision/scale: numeric(5,2) -> numeric.
  const x = String(t).replace(/"/g, '').trim().toLowerCase().replace(/\s*\(\d+(,\s*\d+)?\)/, '');
  const map = {
    'uuid': 'uuid', 'text': 'text', 'boolean': 'boolean', 'jsonb': 'jsonb', 'bigint': 'bigint',
    'integer': 'integer', 'smallint': 'smallint', 'numeric': 'numeric', 'date': 'date',
    'timestamp with time zone': 'timestamp with time zone', 'timestamp without time zone': 'timestamp without time zone',
    'interval': 'interval', 'inet': 'inet', 'bytea': 'bytea', 'json': 'json',
  };
  if (map[x]) return map[x];
  if (/^character varying/.test(x)) return 'character varying';
  if (/\[\]$/.test(x)) return 'ARRAY';
  if (/^public\./.test(x)) return 'USER-DEFINED';
  return x;
}
/** Normalize a collected column row: only the default segment needs normalizing. */
function normDefaultRow(row) {
  const i = row.indexOf(':');
  const j = row.indexOf(':', i + 1);
  const k = row.indexOf(':', j + 1);
  if (k < 0) return row;
  return `${row.slice(0, k + 1)}${normDefault(row.slice(k + 1))}`;
}

function normDefault(d) {
  // * CASE IS PRESERVED. An earlier version lowercased, which made 'USD' and 'usd' compare equal —
  //   a normalizer that hides the very class of change it is meant to detect.
  if (d == null) return '-';
  return String(d).replace(/"/g, '').replace(/\bpublic\./g, '').replace(/\s+/g, ' ').trim();
}

function driftAudit(built, objects) {
  const live = inventory(readFileSync(SNAP, 'utf8'));
  const problems = []; const lines = [];
  const cmp = (label, got, want) => {
    lines.push(`${label.padEnd(34)} built=${String(got).padStart(5)}  authoritative=${String(want).padStart(5)}  ${got === want ? 'ok' : '✗ MISMATCH'}`);
    if (got !== want) problems.push(`${label}: built ${got}, authoritative ${want}`);
  };
  cmp('tables', built.tables, live.tables.length);
  cmp('columns', built.columns, live.columns.length);
  cmp('functions', built.functions, live.functions.length);
  cmp('SECURITY DEFINER functions', built.secdef, live.functions.filter((f) => f.securityDefiner).length);
  cmp('SECDEF without search_path', built.secdefNoPath, 0);
  cmp('triggers', built.triggers, live.triggers.length);
  cmp('RLS-enabled tables', built.rlsEnabled, live.rlsEnabled.length);
  cmp('FORCE-RLS tables', built.rlsForced, live.rlsForced.length);
  cmp('policies (public)', built.policies, live.policies.length);
  cmp('enum types', built.types, live.types.length);
  cmp('storage.objects policies', built.storagePolicies, 2);
  cmp('ensure_rls event trigger', built.eventTriggers, 1);
  cmp('public.assets present', built.assets, 1);
  cmp('indexes (non-constraint-backed)', built.indexes, live.indexes.length);
  cmp('constraints', built.constraints, live.constraints.filter((c) => c.name).length);

  // set-level identity comparisons — a count can match while the members differ
  const setCmp = (label, got, want) => {
    const g = new Set(got); const w = new Set(want);
    const missing = [...w].filter((x) => !g.has(x)); const extra = [...g].filter((x) => !w.has(x));
    lines.push(`${label.padEnd(34)} ${missing.length === 0 && extra.length === 0 ? 'identical' : `✗ missing=${missing.length} extra=${extra.length}`}`);
    if (missing.length) problems.push(`${label} missing: ${missing.slice(0, 8).join(', ')}`);
    if (extra.length) problems.push(`${label} unexplained extra: ${extra.slice(0, 8).join(', ')}`);
  };
  setCmp('table identities', objects.tables, live.tables.map((t) => t.name));
  setCmp('function identities', objects.functions, [...new Set(live.functions.map((f) => f.name))]);
  setCmp('policy identities', objects.policies, live.policies.map((p) => `${p.table}.${p.name}`));
  setCmp('RLS identities', objects.rls, live.rlsEnabled.map((t) => t.name));
  setCmp('trigger identities', objects.triggers, live.triggers.map((t) => `${t.table}.${t.name}`));
  setCmp('policy roles', objects.policyRoles, live.policies.map((p) => `${p.table}.${p.name}=${p.roles.join('+')}`));
  setCmp('policy commands', objects.policyCmds, live.policies.map((p) => `${p.table}.${p.name}=${p.command === 'ALL' ? 'ALL' : p.command}`));
  setCmp('index identities', objects.indexes, live.indexes.map((i) => i.name));

  // * COLUMN TYPE + NULLABILITY + DEFAULT. Collected from the first run and never compared, which
  //   is why a bigint->integer mutation SURVIVED the whole battery. Data collected but unasserted
  //   is the same blindness as data never collected, and it looks more thorough.
  // * DEFAULTS ARRIVE IN TWO PLACES. pg_dump emits `bigserial` columns as a plain bigint plus a
  //   separate `ALTER TABLE ... ALTER COLUMN ... SET DEFAULT nextval(...)`. Reading only the inline
  //   default reported audit_logs.id as having none, while the built database correctly had one.
  const laterDefaults = new Map();
  for (const a of live.alterTables) {
    const m = /ALTER TABLE (?:ONLY )?"?public"?\."?([a-z_]+)"?\s+ALTER COLUMN "?([a-z_]+)"?\s+SET DEFAULT ([\s\S]+)$/i.exec(String(a.sql).replace(/\s+/g, ' '));
    if (m) laterDefaults.set(`${m[1]}.${m[2]}`, m[3].trim());
  }
  setCmp('column type/nullability/default', objects.columnTypes.map((x) => normDefaultRow(x)),
    live.columns.map((c) => {
      const key = `${c.table}.${c.name}`;
      const def = laterDefaults.get(key) ?? c.default;
      return normDefaultRow(`${key}:${pgType(c.type)}:${c.notNull ? 'NO' : 'YES'}:${normDefault(def)}`);
    }));

  // * POLICY PREDICATES. `alter-policy-using` also survived: roles and commands were compared but
  //   the USING/WITH CHECK expressions — the part that actually decides who sees what — were not.
  //   Postgres deparses predicates without quoted identifiers, pg_dump emits them quoted, so both
  //   sides are normalized to compare semantics rather than spelling.
  setCmp('policy predicates', objects.policyPredicates.map(normPred),
    live.policies.map((p) => normPred(`${p.table}.${p.name}|${p.using ?? '-'}|${p.withCheck ?? '-'}`)));
  setCmp('constraint identities', objects.constraints,
    live.constraints.filter((c) => c.name).map((c) => `${c.table}.${c.name}`));

  const wantStorage = ['documents_estate_insert:INSERT', 'documents_estate_read:SELECT'];
  setCmp('storage policy identities', objects.storagePolicies, wantStorage);
  const tags = objects.eventTriggerTags;
  lines.push(`${'ensure_rls tags'.padEnd(34)} ${tags === 'CREATE TABLE|CREATE TABLE AS|SELECT INTO' ? 'ok' : `✗ got "${tags}"`}`);
  if (tags !== 'CREATE TABLE|CREATE TABLE AS|SELECT INTO') problems.push(`ensure_rls tags: got "${tags}"`);

  return { ok: problems.length === 0, problems, lines };
}

/** Mutation injection — test-only. Each spec removes or alters exactly one authoritative property. */
function applyMutation(sql, file, spec) {
  const [target, ...rest] = spec.split(':');
  const rx = (re, rep = '') => sql.replace(re, rep);
  switch (target) {
    case 'drop-assets': return file.startsWith('30_') ? rx(/CREATE TABLE IF NOT EXISTS "public"\."assets"[\s\S]*?\n\);/, '') : sql;
    case 'drop-beneficiaries': return file.startsWith('30_') ? rx(/CREATE TABLE IF NOT EXISTS "public"\."beneficiaries"[\s\S]*?\n\);/, '') : sql;
    case 'drop-notifications': return file.startsWith('30_') ? rx(/CREATE TABLE IF NOT EXISTS "public"\."notifications"[\s\S]*?\n\);/, '') : sql;
    case 'alter-column-type': return file.startsWith('30_') ? sql.replace('"estimated_value_cents" bigint', '"estimated_value_cents" integer') : sql;
    case 'drop-fk': return file.startsWith('40_') ? sql.replace(/ALTER TABLE ONLY "public"\."assets"\s*\n\s*ADD CONSTRAINT[\s\S]*?;/, '') : sql;
    case 'drop-index': return file.startsWith('50_') ? sql.replace(/CREATE INDEX "assets_estate_id_idx"[^;]*;/, '') : sql;
    case 'drop-secdef': return file.startsWith('60_') ? sql.replace('LANGUAGE "plpgsql" SECURITY DEFINER', 'LANGUAGE "plpgsql"') : sql;
    case 'drop-searchpath': return file.startsWith('60_') ? sql.replace(/\n    SET "search_path" TO [^\n]*\n/, '\n') : sql;
    case 'disable-rls': return file.startsWith('80_') ? sql.replace(/ALTER TABLE "public"\."assets" ENABLE ROW LEVEL SECURITY;/, '') : sql;
    case 'change-policy-role': return file.startsWith('90_') ? sql.replace('TO "authenticated"', 'TO "anon"') : sql;
    case 'alter-policy-using': return file.startsWith('90_') ? sql.replace(/USING \(\(\("owner_id" = "auth"\."uid"\(\)\) OR "public"\."is_estate_member"\("estate_id"\)\)\)/, 'USING (true)') : sql;
    case 'drop-storage-read': return file.startsWith('110_') ? sql.replace(/CREATE POLICY "documents_estate_read"[\s\S]*?;\n/, '') : sql;
    case 'drop-storage-insert': return file.startsWith('110_') ? sql.replace(/CREATE POLICY "documents_estate_insert"[\s\S]*?;\n/, '') : sql;
    // * MATCH THE STATEMENT, NOT THE PROSE. The first version matched `CREATE EVENT TRIGGER` inside
    //   this file's own comment block and deleted comment text, leaving the real statement intact —
    //   so the mutation "survived" while never having been applied. Anchored to line start.
    case 'drop-event-trigger': return file.startsWith('120_') ? sql.replace(/^CREATE EVENT TRIGGER[\s\S]*?;\s*$/m, '') : sql;
    case 'change-event-tags': return file.startsWith('120_') ? sql.replace("WHEN TAG IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')", "WHEN TAG IN ('CREATE TABLE')") : sql;
    case 'drop-trigger': return file.startsWith('70_') ? sql.replace(/CREATE OR REPLACE TRIGGER "estates_ensure_primary_user_membership"[^;]*;/, '') : sql;
    case 'extra-object': return file.startsWith('30_') ? `${sql}\nCREATE TABLE "public"."phantom_extra" ("id" uuid);\n` : sql;
    default: throw new Error(`unknown mutation: ${spec}${rest.length ? ` ${rest.join(':')}` : ''}`);
  }
}
