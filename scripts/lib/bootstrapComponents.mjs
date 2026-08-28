/**
 * MODEL C — COMPONENTIZED CURRENT-STATE BOOTSTRAP — the pure classifier.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ CANONICAL DDL IS DERIVED FROM LIVE DDL, NEVER RETYPED.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * Every statement emitted into db/bootstrap/ is a statement that came out of the verified snapshot
 * or a hashed evidence capture, re-ORDERED and re-GROUPED — not reconstructed. Retyping a policy
 * predicate or a function body from a report is how a bootstrap acquires a subtle difference nobody
 * can see, and this repository has already shipped one taxonomy defect from exactly that.
 *
 * ★ ORDERING SIDESTEPS FK CYCLES THE WAY pg_dump DOES: tables first WITHOUT their foreign keys,
 *   then constraints. There is therefore no table ordering problem to solve and no cycle to break —
 *   `owner_notice_outbox`'s self-reference lands in phase 40 like every other FK.
 *
 * ★ `language sql` FUNCTIONS ARE VALIDATED AT CREATION (check_function_bodies), `plpgsql` bodies are
 *   not. 29 of the 147 functions are `sql`, so functions MUST come after tables and constraints or
 *   the bootstrap fails on a body referencing a table that does not exist yet. This is a real
 *   ordering constraint, not a stylistic one.
 *
 * ★ OWNERSHIP IS DECIDED BY PROVENANCE, NEVER BY NAME. Six of the seven live event triggers are
 *   owned by `supabase_admin` and are Supabase's own (pgrst_ddl_watch, issue_pg_cron_access, …).
 *   Exactly one — `ensure_rls`, owner `postgres` — is application-owned. Filtering by name would
 *   have been a guess; filtering by owner is the evidence.
 *
 * PURE. No filesystem, no clock, no network.
 */

/** Phase identity. Order here IS execution order. */
export const PHASES = Object.freeze([
  { id: '00', file: '00_platform_contract.sql', title: 'platform contract / prerequisites' },
  { id: '10', file: '10_extensions.sql', title: 'extensions' },
  { id: '20', file: '20_types.sql', title: 'custom types' },
  { id: '30', file: '30_tables.sql', title: 'tables + sequences (no FKs yet)' },
  { id: '40', file: '40_constraints.sql', title: 'constraints, sequence ownership, defaults' },
  { id: '50', file: '50_indexes.sql', title: 'indexes' },
  { id: '60', file: '60_functions.sql', title: 'functions' },
  { id: '70', file: '70_triggers.sql', title: 'triggers' },
  { id: '80', file: '80_rls_enable.sql', title: 'RLS enablement' },
  { id: '90', file: '90_policies.sql', title: 'policies on application tables' },
  { id: '100', file: '100_grants.sql', title: 'ownership, grants, default privileges' },
  { id: '110', file: '110_storage_policies.sql', title: 'application policies on platform storage.objects' },
  { id: '120', file: '120_event_triggers.sql', title: 'event triggers (HOSTED_COMPATIBILITY_PROOF_REQUIRED)' },
]);

/**
 * Extensions Supabase supplies versus those the application requires.
 * ★ `supabase_vault` lives in schema `vault` and is created by the platform; a bootstrap that tried
 *   to create it would fail or, worse, succeed differently. `pg_stat_statements` is an observability
 *   extension the platform installs. Neither is application DDL.
 */
export const PLATFORM_EXTENSIONS = Object.freeze(['supabase_vault', 'pg_stat_statements']);

/** Event-trigger owners that mark a platform object. Evidence-derived, not guessed. */
export const PLATFORM_EVENT_TRIGGER_OWNERS = Object.freeze(['supabase_admin']);

/**
 * Assign a parsed snapshot statement to a bootstrap phase.
 * Returns null for statements the bootstrap deliberately does not carry (session SET, comments on
 * platform objects, publications).
 */
export function phaseOf(stmt) {
  const s = String(stmt).replace(/\s+/g, ' ').trim();

  if (/^SET /i.test(s) || /^SELECT pg_catalog\.set_config/i.test(s)) return null;
  if (/^ALTER PUBLICATION/i.test(s) || /^CREATE PUBLICATION/i.test(s)) return null;

  if (/^CREATE EXTENSION/i.test(s)) return '10';
  if (/^CREATE TYPE/i.test(s)) return '20';
  if (/^ALTER (TYPE|SEQUENCE|VIEW|SCHEMA|INDEX) .* OWNER TO/i.test(s)) return '100';

  if (/^CREATE TABLE/i.test(s)) return '30';
  if (/^CREATE SEQUENCE/i.test(s)) return '30';

  if (/^ALTER TABLE .*ADD CONSTRAINT/i.test(s)) return '40';
  if (/^ALTER SEQUENCE .*OWNED BY/i.test(s)) return '40';
  if (/^ALTER TABLE .*ALTER COLUMN .*SET DEFAULT/i.test(s)) return '40';

  if (/^CREATE (UNIQUE )?INDEX/i.test(s)) return '50';

  if (/^CREATE (OR REPLACE )?FUNCTION/i.test(s)) return '60';
  if (/^ALTER FUNCTION .* OWNER TO/i.test(s)) return '100';

  if (/^CREATE (OR REPLACE )?(CONSTRAINT )?TRIGGER/i.test(s)) return '70';

  if (/ENABLE ROW LEVEL SECURITY/i.test(s)) return '80';
  if (/FORCE ROW LEVEL SECURITY/i.test(s)) return '80';

  if (/^CREATE POLICY/i.test(s)) return '90';

  if (/^ALTER TABLE .* OWNER TO/i.test(s)) return '100';
  if (/^GRANT /i.test(s) || /^REVOKE /i.test(s)) return '100';
  if (/^ALTER DEFAULT PRIVILEGES/i.test(s)) return '100';

  if (/^COMMENT ON/i.test(s)) return '100';

  return '?';
}

/**
 * Build the ordered component set from a parsed snapshot plus hashed supplements.
 *
 * ★ `unassigned` is the honesty channel. A statement the classifier does not recognise must surface,
 *   never be dropped — a bootstrap silently missing statements would still apply cleanly and would
 *   still be wrong, which is the worst possible failure shape for this artifact.
 */
export function buildComponents({ statements, storagePolicies, eventTriggers }) {
  const byPhase = new Map(PHASES.map((p) => [p.id, []]));
  const unassigned = [];
  const skipped = [];

  for (const stmt of statements) {
    const ph = phaseOf(stmt);
    if (ph === null) { skipped.push(stmt); continue; }
    if (ph === '?') { unassigned.push(stmt); continue; }
    // Platform extensions are recorded as prerequisites, not created.
    if (ph === '10') {
      const m = /CREATE EXTENSION (?:IF NOT EXISTS )?"?([A-Za-z0-9_-]+)"?/i.exec(stmt);
      if (m && PLATFORM_EXTENSIONS.includes(m[1])) { byPhase.get('00').push({ platform: true, sql: stmt }); continue; }
    }
    byPhase.get(ph).push({ sql: stmt });
  }

  for (const p of storagePolicies ?? []) byPhase.get('110').push({ sql: renderStoragePolicy(p), evidence: true });
  for (const et of eventTriggers ?? []) {
    if (PLATFORM_EVENT_TRIGGER_OWNERS.includes(et.event_trigger_owner)) continue;  // platform-owned
    byPhase.get('120').push({ sql: renderEventTrigger(et), evidence: true });
  }

  return { byPhase, unassigned, skipped };
}

/**
 * Render a policy on storage.objects from CAPTURED catalog fields.
 * ★ qual/with_check are emitted verbatim from the hashed capture. `null` in the capture means the
 *   clause does not exist and MUST NOT be emitted — an INSERT policy has WITH CHECK and no USING.
 */
export function renderStoragePolicy(p) {
  const parts = [`CREATE POLICY "${p.policyname}" ON "${p.schemaname}"."${p.tablename}"`];
  if (String(p.permissive).toUpperCase() === 'RESTRICTIVE') parts.push('  AS RESTRICTIVE');
  parts.push(`  FOR ${String(p.cmd).toUpperCase()}`);
  const roles = String(p.roles ?? '').replace(/^\{|\}$/g, '').split(',').map((r) => r.trim()).filter(Boolean);
  if (roles.length) parts.push(`  TO ${roles.map((r) => `"${r}"`).join(', ')}`);
  if (p.qual && p.qual !== 'null') parts.push(`  USING (${p.qual})`);
  if (p.with_check && p.with_check !== 'null') parts.push(`  WITH CHECK (${p.with_check})`);
  return `${parts.join('\n')};`;
}

/**
 * Render an event-trigger binding from CAPTURED catalog fields.
 * ★ Tags come from evttags in the capture, not from the prose in a report. An empty/absent tag list
 *   means NO `WHEN TAG IN (...)` clause at all, which is a different trigger from one with tags.
 */
export function renderEventTrigger(et) {
  const tags = parseTags(et.evttags);
  const when = tags.length ? `\n  WHEN TAG IN (${tags.map((t) => `'${t}'`).join(', ')})` : '';
  const fn = `"${et.function_schema}"."${et.function_name}"`;
  return `CREATE EVENT TRIGGER "${et.evtname}"\n  ON ${et.evtevent}${when}\n  EXECUTE FUNCTION ${fn}();`;
}

/** PURE. evttags arrives as a JSON array string from the CSV capture, or null. */
export function parseTags(raw) {
  if (raw == null) return [];
  const s = String(raw).trim();
  if (s === '' || s.toLowerCase() === 'null') return [];
  try {
    const v = JSON.parse(s);
    return Array.isArray(v) ? v.map(String) : [];
  } catch {
    const inner = s.replace(/^\{|\}$/g, '');
    return inner ? inner.split(',').map((t) => t.trim().replace(/^"|"$/g, '')) : [];
  }
}
