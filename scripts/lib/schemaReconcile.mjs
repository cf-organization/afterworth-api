/**
 * CURRENT AUTHORITATIVE SCHEMA ↔ REPOSITORY RECONCILIATION — the pure half.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ THE QUESTION: WHICH LIVE OBJECTS CAN THIS REPOSITORY BUILD IN A VIRGIN ENVIRONMENT?
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * Not "which objects are mentioned somewhere" — mentioned is not creatable. A migration that ALTERs
 * `documents` proves the repository knows the table exists; it does not prove the repository can
 * create it. The two are separated here by ROLE:
 *
 *   base      — a CREATE that can stand up the object from nothing
 *   delta     — an ALTER/DROP that presupposes the object
 *   test-only — a CREATE that exists solely inside db/tests, load-bearing for no deployment
 *
 * ★ SOURCE ROLE IS DECIDED BY PATH, NOT BY CONTENT. A `create table` inside db/tests is still
 *   test-only however complete it looks. This mirrors the standing repository rule that authority
 *   comes from WHERE a thing came from, never from whether it happens to contain what a caller
 *   wanted. `db/tests/preamble_real_auth.sql` contains a perfectly good-looking
 *   `create table public.beneficiaries` and it is still not a schema source.
 *
 * PURE. The caller supplies { path, sql } records.
 */
import { inventory } from './schemaInventory.mjs';

/** Path -> the authority that path carries. Order matters: first match wins. */
export const SOURCE_ROLES = Object.freeze([
  // * ORDER MATTERS AND testing/ COMES FIRST. db/bootstrap/testing/ holds a platform SHIM that
  //   fabricates auth.users and storage.objects for container tests. If the generic bootstrap rule
  //   matched it first, a fake auth.users would be classified as an application-owned base
  //   definition — the precise confusion the shim's filename shouts about.
  { match: /^db\/bootstrap\/testing\//, role: 'test-only', authority: 'local platform shim — NOT a schema source' },
  { match: /^db\/bootstrap\//, role: 'base', authority: 'Model C canonical current-state bootstrap (through 0060)' },
  { match: /^db\/tables\//, role: 'base', authority: 'current-state capture (2026-07-10)' },
  { match: /^db\/functions\//, role: 'base', authority: 'current-state function bodies' },
  { match: /^db\/grants\.sql$/, role: 'base', authority: 'current-state grants' },
  { match: /^db\/migrations\//, role: 'delta', authority: 'historical delta history' },
  { match: /^db\/bundles\//, role: 'bundle', authority: 'deployment slice (derived)' },
  { match: /^db\/tests\//, role: 'test-only', authority: 'test preamble — NOT a schema source' },
  { match: /^db\/verification\//, role: 'verification', authority: 'read-only checks' },
  { match: /^db\/hotfix\//, role: 'delta', authority: 'out-of-band delta' },
  { match: /^db\/seed_admin\.sql$/, role: 'seed', authority: 'data seed — not schema' },
]);

export function roleOf(path) {
  for (const r of SOURCE_ROLES) if (r.match.test(path)) return r;
  return { role: 'unknown', authority: 'unclassified path' };
}

/**
 * Which objects each repository file can CREATE, and which it merely presupposes.
 * ★ Unknown paths are surfaced, never silently dropped — a new db/ subdirectory must not become
 *   invisible bootstrap material.
 */
export function repositoryObjects(files) {
  const out = { creates: new Map(), touches: new Map(), unknownPaths: [], parseFailures: [] };
  for (const { path, sql } of files) {
    const r = roleOf(path);
    if (r.role === 'unknown') out.unknownPaths.push(path);
    let inv;
    try { inv = inventory(sql); } catch (e) { out.parseFailures.push({ path, error: String(e?.message ?? e) }); continue; }
    if (inv.unclassified.length) out.parseFailures.push({ path, unclassified: inv.unclassified.length });

    const add = (map, kind, name, extra = {}) => {
      const key = `${kind}:${name}`;
      if (!map.has(key)) map.set(key, []);
      map.get(key).push({ path, role: r.role, authority: r.authority, ...extra });
    };
    for (const t of inv.tables) add(out.creates, 'table', t.name);
    for (const f of inv.functions) add(out.creates, 'function', f.name);
    for (const p of inv.policies) add(out.creates, 'policy', `${p.table}.${p.name}`);
    for (const i of inv.indexes) add(out.creates, 'index', i.name);
    for (const t of inv.triggers) add(out.creates, 'trigger', `${t.table}.${t.name}`);
    for (const t of inv.types) add(out.creates, 'type', t.name);
    for (const s of inv.sequences) add(out.creates, 'sequence', s.name);
    for (const e of inv.extensions) add(out.creates, 'extension', e.name);
    for (const a of inv.alterTables) if (a.name) add(out.touches, 'table', a.name);
    for (const a of inv.rlsEnabled) add(out.creates, 'rls', a.name);
    for (const c of inv.constraints) if (c.table) add(out.touches, 'table', c.table);
  }
  return out;
}

/** BASE authority only — the roles that may stand an object up in a virgin database. */
export const BOOTSTRAP_ROLES = Object.freeze(['base']);

/**
 * The reconciliation. For every live object, what can the repository do about it?
 *
 * ★ A COUNT IS NEVER THE FINDING. Every category carries the exact object names, because "N objects
 *   missing" has been wrong in this repository before (39 vs 5) and an aggregate cannot be checked.
 */
export function reconcile({ live, repo }) {
  const rows = [];
  const kinds = [
    ['table', live.tables.map((t) => t.name)],
    ['function', [...new Set(live.functions.map((f) => f.name))]],
    ['policy', live.policies.map((p) => `${p.table}.${p.name}`)],
    ['index', live.indexes.map((i) => i.name)],
    ['trigger', live.triggers.map((t) => `${t.table}.${t.name}`)],
    ['type', live.types.map((t) => t.name)],
    ['sequence', live.sequences.map((s) => s.name)],
    ['extension', live.extensions.map((e) => e.name)],
    ['rls', live.rlsEnabled.map((t) => t.name)],
  ];
  for (const [kind, names] of kinds) {
    for (const name of names) {
      const defs = repo.creates.get(`${kind}:${name}`) ?? [];
      const base = defs.filter((d) => BOOTSTRAP_ROLES.includes(d.role));
      const testOnly = defs.length > 0 && base.length === 0 && defs.every((d) => d.role === 'test-only');
      const deltaOnly = defs.length > 0 && base.length === 0 && defs.some((d) => d.role === 'delta');
      rows.push({
        kind, name,
        live_present: true,
        repo_definitions: defs.map((d) => d.path),
        base_definitions: base.map((d) => d.path),
        duplicate_defs: base.length > 1,
        repo_role: base.length ? 'base' : testOnly ? 'test-only' : deltaOnly ? 'delta-only' : defs.length ? defs[0].role : 'none',
        disposition:
          base.length > 1 ? 'DUPLICATE_BASE'
          : base.length === 1 ? 'COVERED'
          : testOnly ? 'TEST_ONLY_DEFINITION'
          : deltaOnly ? 'DELTA_ONLY_NO_BASE'
          : defs.length ? 'NON_BOOTSTRAP_SOURCE_ONLY'
          : 'NO_REPO_DEFINITION',
      });
    }
  }
  return rows;
}

export const GAP_DISPOSITIONS = Object.freeze([
  'NO_REPO_DEFINITION', 'TEST_ONLY_DEFINITION', 'DELTA_ONLY_NO_BASE', 'NON_BOOTSTRAP_SOURCE_ONLY', 'DUPLICATE_BASE',
]);

/**
 * PURE. The instrument's own fitness to be believed, computed BEFORE any coverage claim.
 *
 * ★ A DEGRADED PARSE MAY NEVER REPORT CLEAN. This repository has published two false reconciliation
 *   results ("201/201 files unparseable", "293-object gap") that were artifacts of parser blindness,
 *   and a policy-role field that failed OPEN through three separate fixes. The lesson is not "parse
 *   better" — it is that coverage output must be gated on parse health, so a broken instrument
 *   produces a REFUSAL rather than a number.
 *
 * Returns { ok, problems }. `ok === false` MUST suppress any PASS/CLEAN verdict.
 */
export function parseHealth({ live, repo, minStatements = 1 }) {
  const problems = [];
  const n = Object.entries(live).filter(([k]) => k !== 'unclassified').reduce((a, [, v]) => a + (Array.isArray(v) ? v.length : 0), 0);
  if (n < minStatements) problems.push(`snapshot parsed to ${n} objects — an empty scan set is a failure, never "clean"`);
  if (live.tables.length === 0) problems.push('snapshot contains zero tables');
  if (live.unclassified.length) problems.push(`${live.unclassified.length} snapshot statement(s) unclassified`);
  if (live.dml?.length) problems.push(`${live.dml.length} data statement(s) present — this is not a schema-only snapshot`);
  const badRoles = (live.policies ?? []).filter((p) => p.roles?.includes('?unparsed'));
  if (badRoles.length) problems.push(`${badRoles.length} policy role list(s) unparsed: ${badRoles.map((p) => `${p.table}.${p.name}`).join(', ')}`);
  const badCmds = (live.policies ?? []).filter((p) => p.command === '?unparsed');
  if (badCmds.length) problems.push(`${badCmds.length} policy command(s) unparsed: ${badCmds.map((p) => `${p.table}.${p.name}`).join(', ')}`);
  if (repo) {
    if (repo.unknownPaths.length) problems.push(`unclassified source path(s): ${repo.unknownPaths.join(', ')}`);
    if (repo.parseFailures.length) problems.push(`${repo.parseFailures.length} repository file(s) with unclassified statements`);
  }
  return { ok: problems.length === 0, problems };
}

export function summarize(rows) {
  const by = {};
  for (const r of rows) {
    by[r.kind] ??= {};
    by[r.kind][r.disposition] = (by[r.kind][r.disposition] ?? 0) + 1;
  }
  return by;
}
