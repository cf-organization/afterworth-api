/**
 * MODEL C HOSTED BOOTSTRAP — execution authorization by HASH.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ VERB INSPECTION CANNOT MAKE A 921-STATEMENT BOOTSTRAP SAFE.
 *
 *   The event-trigger probe was six statements, so enumerating its allowed forms was tractable and
 *   correct. The bootstrap is 921 statements across 13 phases and legitimately contains CREATE
 *   TABLE, GRANT, REVOKE, CREATE POLICY, CREATE EVENT TRIGGER and ALTER ... OWNER TO. An allowlist
 *   permissive enough to admit all of that would also admit one substituted statement hidden among
 *   them — which is the only attack that matters here.
 *
 *   So authorization is by CONTENT HASH: each phase file must match its pinned sha256, the phase
 *   ORDER must match, and the cumulative hash over (phase, sha) must match. A single altered byte
 *   fails, and no judgement about what the bytes mean is required.
 *
 * ★ IT ALSO REFUSES THINGS THE HASH ALONE WOULD PERMIT, because a manifest can in principle be
 *   regenerated over an altered bootstrap: no migration 0001-0060 file may appear in the execution
 *   set, no write to supabase_migrations, and the version must be exactly 0060.
 *
 * PURE. The caller supplies { file, sha256 } records and a hash function.
 */

export const BOOTSTRAP_AUDIT = Object.freeze({
  OK: 'BOOTSTRAP_EXECUTION_AUTHORIZED',
  REFUSED: 'BOOTSTRAP_EXECUTION_REFUSED',
});

export const BOOTSTRAP_REFUSAL = Object.freeze({
  EMPTY: 'empty_execution_set',
  VERSION_MISMATCH: 'version_mismatch',
  PHASE_MISSING: 'phase_missing',
  PHASE_EXTRA: 'phase_not_in_manifest',
  PHASE_REORDERED: 'phase_order_mismatch',
  PHASE_HASH_MISMATCH: 'phase_content_hash_mismatch',
  CUMULATIVE_MISMATCH: 'cumulative_hash_mismatch',
  HISTORICAL_MIGRATION_PRESENT: 'historical_migration_in_execution_set',
  MIGRATION_METADATA_WRITE: 'migration_metadata_write_present',
  TARGET_MISMATCH: 'target_ref_mismatch',
});

/** True when the path is a historical migration 0001-0060. */
export function isHistoricalMigration(file) {
  const m = /(?:^|\/)db\/migrations\/(\d{4})_/.exec(String(file ?? ''));
  return Boolean(m) && Number(m[1]) <= 60;
}

/** True when the SQL would write the CLI migration history table. */
export function writesMigrationMetadata(sql) {
  const s = String(sql ?? '').replace(/\s+/g, ' ');
  return /\b(insert\s+into|update|delete\s+from|truncate)\s+"?supabase_migrations"?/i.test(s);
}

export function auditBootstrapExecution(manifest, execution, sha) {
  const problems = [];
  const files = execution?.files ?? [];
  if (!Array.isArray(files) || files.length === 0) {
    return { verdict: BOOTSTRAP_AUDIT.REFUSED, problems: [BOOTSTRAP_REFUSAL.EMPTY] };
  }

  if (String(execution?.version ?? '') !== String(manifest?.version ?? ' ')) problems.push(BOOTSTRAP_REFUSAL.VERSION_MISMATCH);
  if (String(execution?.targetRef ?? '') !== String(manifest?.target_ref ?? ' ')) problems.push(BOOTSTRAP_REFUSAL.TARGET_MISMATCH);

  const byFile = new Map((manifest?.phases ?? []).map((p) => [p.file, p]));
  const seen = [];
  for (const f of files) {
    if (isHistoricalMigration(f.file)) { problems.push(`${BOOTSTRAP_REFUSAL.HISTORICAL_MIGRATION_PRESENT}: ${f.file}`); continue; }
    if (f.sql && writesMigrationMetadata(f.sql)) problems.push(`${BOOTSTRAP_REFUSAL.MIGRATION_METADATA_WRITE}: ${f.file}`);
    const p = byFile.get(f.file);
    if (!p) { problems.push(`${BOOTSTRAP_REFUSAL.PHASE_EXTRA}: ${f.file}`); continue; }
    if (f.sha256 !== p.sha256) problems.push(`${BOOTSTRAP_REFUSAL.PHASE_HASH_MISMATCH}: ${f.file}`);
    seen.push(p.phase);
  }

  for (const p of manifest?.phases ?? []) {
    if (!files.some((f) => f.file === p.file)) problems.push(`${BOOTSTRAP_REFUSAL.PHASE_MISSING}: ${p.file}`);
  }

  const expectedOrder = (manifest?.phase_order ?? []).join(',');
  if (seen.length === (manifest?.phases ?? []).length && seen.join(',') !== expectedOrder) {
    problems.push(BOOTSTRAP_REFUSAL.PHASE_REORDERED);
  }

  // Cumulative hash recomputed over the EXECUTION set, never copied from the manifest.
  if (typeof sha === 'function') {
    const cumulative = sha(files
      .filter((f) => byFile.has(f.file))
      .map((f) => `${byFile.get(f.file).phase}:${f.sha256}`)
      .join('\n'));
    if (cumulative !== manifest?.cumulative_bootstrap_sha256) problems.push(BOOTSTRAP_REFUSAL.CUMULATIVE_MISMATCH);
  }

  return { verdict: problems.length === 0 ? BOOTSTRAP_AUDIT.OK : BOOTSTRAP_AUDIT.REFUSED, problems };
}
