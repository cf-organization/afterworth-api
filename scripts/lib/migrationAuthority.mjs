/**
 * MIGRATION AUTHORITY — historical range vs future delta authority.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ THE DEFECT THIS MODULE EXISTS TO REMOVE.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * The first validator enforced `no migration numbered above the bootstrap cutoff`. That is exactly
 * backwards: db/AUTHORITY.json declares db/migrations/0061+ the FUTURE DELTA AUTHORITY, so the one
 * thing the repository must permit is precisely what the test forbade. A legitimate
 * `0061_<date>_<name>.sql` produced NINE failures across three suites, every one of them a bug in
 * the guard rather than a problem with the migration.
 *
 * The confusion was between two different numbers that happened to be equal while no future
 * migration existed:
 *
 *   BOOTSTRAP CUTOFF   0060 — "this fixed artifact produces schema state through migration 0060"
 *   MAX MIGRATION      the highest file present, which GROWS as 0061, 0062 … are authored
 *
 * `VERSION` is the first. It is NOT a ceiling on repository content, and adding 0061 must not
 * change it, must not regenerate the bootstrap, and must not touch db/bootstrap at all.
 *
 * ★ SEMANTICS ARE DERIVED FROM db/AUTHORITY.json, never hard-coded here. A separate hard-coded rule
 *   is how the contradiction arose in the first place.
 *
 * PURE. The caller supplies filenames and (optionally) git status.
 */

export const MIGRATION_FILENAME = /^(\d{4})_(\d{8})_[a-z0-9_]+\.sql$/;

/** Markers that identify test-fixture content. Fixtures may never live in db/migrations. */
export const FIXTURE_MARKERS = Object.freeze([
  'TEST FIXTURE ONLY',
  'NEVER A REAL MIGRATION',
  'synthetic_probe',
  'MUST NEVER ENTER',
]);

export const VERDICT = Object.freeze({
  OK: 'MIGRATION_SET_VALID',
  INVALID: 'MIGRATION_SET_INVALID',
});

/** PURE. Parse one filename. Returns null when the name is not a migration at all. */
export function parseMigration(name) {
  const m = MIGRATION_FILENAME.exec(name);
  if (!m) return null;
  return { name, seq: Number(m[1]), raw: m[1], date: m[2] };
}

/**
 * PURE. Classify and validate a migration set against the authority contract.
 *
 * @param names       every filename in db/migrations
 * @param cutoff      bootstrap VERSION as a number (0060 -> 60)
 * @param futureStart declared first future number (0061 -> 61)
 * @param opts.contents        optional { name: sql } for fixture-content detection
 * @param opts.addedOrModified optional list of names git reports as new/changed
 */
export function classifyMigrations(names, cutoff, futureStart, opts = {}) {
  const problems = [];
  const sqlNames = (names ?? []).filter((n) => typeof n === 'string' && n.endsWith('.sql'));

  if (sqlNames.length === 0) {
    return { verdict: VERDICT.INVALID, problems: ['migration set is empty — an empty set proves nothing'], historical: [], future: [] };
  }

  const parsed = [];
  for (const n of sqlNames) {
    const p = parseMigration(n);
    if (!p) { problems.push(`malformed migration filename: ${n}`); continue; }
    parsed.push(p);
  }

  const bySeq = new Map();
  for (const p of parsed) {
    if (bySeq.has(p.seq)) problems.push(`duplicate migration number ${p.raw}: ${bySeq.get(p.seq).name} and ${p.name}`);
    else bySeq.set(p.seq, p);
  }

  const historical = parsed.filter((p) => p.seq <= cutoff).sort((a, b) => a.seq - b.seq);
  const future = parsed.filter((p) => p.seq > cutoff).sort((a, b) => a.seq - b.seq);

  // ★ A FUTURE MIGRATION IS ALLOWED. This is the whole point; only its NUMBER is constrained.
  if (future.length > 0 && future[0].seq !== futureStart) {
    // Legitimate only if some higher number already existed — i.e. the sequence continues.
    if (future[0].seq < futureStart) problems.push(`future migration ${future[0].raw} is below the declared future start ${String(futureStart).padStart(4, '0')}`);
  }
  for (let i = 1; i < future.length; i += 1) {
    if (future[i].seq <= future[i - 1].seq) problems.push(`future migrations must strictly increase: ${future[i - 1].name} then ${future[i].name}`);
  }

  // ★ NEW MATERIAL IN THE HISTORICAL RANGE IS REFUSED. Not the range's EXISTENCE — its GROWTH.
  //   0001-0060 are immutable; a newly added or edited file at or below the cutoff is a
  //   renumbering/rewrite of history, which is the thing the contract forbids.
  for (const n of opts.addedOrModified ?? []) {
    const p = parseMigration(n.replace(/^.*\//, ''));
    if (p && p.seq <= cutoff) problems.push(`historical range is immutable — ${p.name} (<= ${String(cutoff).padStart(4, '0')}) was added or modified`);
  }

  // ★ TEST FIXTURES MAY NOT ENTER PRODUCTION MIGRATION AUTHORITY — refused for being a FIXTURE,
  //   never merely for its number. A real 0061 and a fixture named 0061 are different objects.
  for (const [n, sql] of Object.entries(opts.contents ?? {})) {
    if (FIXTURE_MARKERS.some((m) => String(sql).includes(m))) {
      problems.push(`test-fixture content may not live in db/migrations: ${n}`);
    }
  }

  return {
    verdict: problems.length === 0 ? VERDICT.OK : VERDICT.INVALID,
    problems,
    historical: historical.map((p) => p.name),
    future: future.map((p) => p.name),
  };
}

/**
 * PURE. Validate the bootstrap VERSION string itself.
 * ★ It must be >= the highest HISTORICAL migration, never >= the highest migration overall — the
 *   latter would make every new future migration invalidate the bootstrap it is layered on.
 */
export function validateVersion(version, historicalNames) {
  const problems = [];
  if (!/^\d{4}$/.test(String(version ?? '').trim())) {
    return { ok: false, problems: [`VERSION must be exactly four decimal digits, got ${JSON.stringify(version)}`] };
  }
  const v = Number(version);
  const seqs = (historicalNames ?? []).map((n) => parseMigration(n)).filter(Boolean).map((p) => p.seq);
  if (seqs.length === 0) problems.push('no historical migrations found — cannot validate the cutoff');
  else if (v < Math.max(...seqs)) problems.push(`VERSION ${version} is below the highest historical migration ${String(Math.max(...seqs)).padStart(4, '0')}`);
  return { ok: problems.length === 0, problems };
}
