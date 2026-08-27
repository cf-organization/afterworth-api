/**
 * FRESH-DATABASE MIGRATION REHEARSAL — the pure half.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ THE QUESTION NOBODY HAD ASKED: CAN THIS REPOSITORY BUILD A DATABASE FROM NOTHING?
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * Sixty migrations have only ever been applied ONE AT A TIME to a single long-lived project. Every
 * signal a developer sees — the files exist, CI is green, the deployed schema works — is a statement
 * about that one database's history, not about whether the recorded history reproduces it. Those are
 * different claims, and only the second one matters the day a second environment is provisioned.
 *
 * ★ THIS MODULE IS THE PART THAT CAN BE TESTED WITHOUT DOCKER. Discovery, ordering and the
 *   completeness rules are pure functions over filenames; the runner that starts a container and
 *   executes SQL lives in `scripts/rehearseFreshDatabase.mjs`. Splitting them is what lets the
 *   fail-closed rules have unit tests at all — a rule that can only be exercised by a 90-second
 *   container run is a rule nobody re-runs.
 *
 * ★ THERE IS NO REMOTE TARGET, BY CONSTRUCTION. Nothing here accepts a connection string, a project
 *   ref, a host or a credential. The runner creates its own throwaway container and derives its own
 *   local credentials, so there is no argument an operator could supply that would point this at a
 *   real database. That is a stronger property than validating one.
 *
 * PURE. No clock, no network, no container. The caller supplies the directory listing.
 */

/** `NNNN_YYYYMMDD_snake_case.sql` — the only filename shape the migration directory may hold. */
export const MIGRATION_FILENAME = /^(\d{4})_(\d{8})_[a-z0-9_]+\.sql$/;

export const REHEARSAL = Object.freeze({
  BUILT: 'FRESH_DATABASE_BUILT',
  FAILED: 'FRESH_DATABASE_FAILED',
  UNVERIFIABLE: 'FRESH_DATABASE_UNVERIFIABLE',
});

/**
 * PURE. Decide the ordered migration set from a raw directory listing.
 *
 * ★ AN EMPTY SET IS A FAILURE, NEVER "CLEAN". A rehearsal that applied nothing and reported success
 *   is the vacuous-audit shape this repository has shipped before: it would go green on the day
 *   somebody pointed it at the wrong directory, which is exactly the day it needed to shout.
 *
 * ★ ORDER IS ASSERTED, NOT ASSUMED. Lexical sort equals numeric sort only while every prefix is the
 *   same width, and that is guaranteed upstream: `MIGRATION_FILENAME` admits exactly four digits, so
 *   a three- or five-digit prefix is refused as unparseable before ordering is ever considered.
 *
 *   An explicit `widths.size > 1` branch was written here first and then REMOVED, because mutation
 *   testing showed it could not fire — the regex had already made it unreachable. A guard that no
 *   input can reach is not a second layer of safety, it is a line that makes the file look safer
 *   than it is. The property is real; the place it is enforced is the filename rule.
 */
export function discoverMigrations(entries) {
  const problems = [];
  const files = (Array.isArray(entries) ? entries : []).filter((n) => typeof n === 'string' && n.endsWith('.sql'));

  if (files.length === 0) {
    return { ok: false, problems: ['migration set is empty — a rehearsal that applies nothing proves nothing'], ordered: [] };
  }

  const malformed = files.filter((n) => !MIGRATION_FILENAME.test(n));
  for (const n of malformed) problems.push(`unparseable migration filename: ${n}`);

  const parsed = files
    .filter((n) => MIGRATION_FILENAME.test(n))
    .map((n) => ({ name: n, seq: MIGRATION_FILENAME.exec(n)[1] }));

  const seen = new Map();
  for (const p of parsed) {
    if (seen.has(p.seq)) problems.push(`duplicate migration sequence ${p.seq}: ${seen.get(p.seq)} and ${p.name}`);
    else seen.set(p.seq, p.name);
  }

  const ordered = parsed.map((p) => p.name).sort();
  return { ok: problems.length === 0, problems, ordered };
}

/**
 * PURE. The `public.<table>` operations a migration performs, IN SOURCE ORDER.
 *
 * ★ ORDER IS THE WHOLE POINT, AND THE FIRST VERSION THREW IT AWAY. This returned two SETS —
 *   `created` and `altered` — and the replay checked every alter before recording any creation from
 *   the same file. A migration that creates a table and then alters it therefore accused itself of
 *   a missing dependency. That inflated the published finding from 5 real gaps to 36, and 31 of
 *   those were files complaining about their own tables.
 *
 * ★ COMMENTS ARE STRIPPED AND STRINGS ARE KEPT, the asymmetry every scanner here uses. A table
 *   DISCUSSED in a header comment has not been created; a table named inside a policy body or a
 *   `raise` message is real SQL the planner will see.
 */
export function tableOperations(sql) {
  const code = String(sql ?? '').replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/^\s*--.*$/gm, ' ');
  const ops = [];
  const re = /(create\s+table\s+(?:if\s+not\s+exists\s+)?|alter\s+table\s+(?:only\s+)?)public\.([a-z_]+)/gi;
  for (const m of code.matchAll(re)) {
    ops.push({ op: /^create/i.test(m[1]) ? 'create' : 'alter', table: m[2].toLowerCase(), at: m.index });
  }
  return ops;
}

/** Back-compatible set view. Order-insensitive by nature — never use it to decide dependencies. */
export function tablesTouched(sql) {
  const ops = tableOperations(sql);
  return {
    created: new Set(ops.filter((o) => o.op === 'create').map((o) => o.table)),
    altered: new Set(ops.filter((o) => o.op === 'alter').map((o) => o.table)),
  };
}

/**
 * PURE. Replay the ordered set symbolically and report the first statement that touches a table no
 * earlier statement created.
 *
 * ★ THIS IS A PRE-FLIGHT, NOT A SUBSTITUTE FOR RUNNING THE SQL. It answers one question cheaply —
 *   "does the recorded history reference something it never builds?" — and it answers it before a
 *   container is started, so the report can name the gap instead of only naming an error string.
 *   The real proof is still Postgres executing the files; this exists so a failure is legible.
 */
export function unsatisfiedTableReferences(files) {
  const built = new Set();
  const gaps = [];
  for (const { name, sql } of files) {
    // ★ STATEMENT ORDER WITHIN THE FILE, not two sets. A table this migration creates satisfies a
    //   later alter in the same migration — which is the ordinary shape of a slice file.
    for (const { op, table } of tableOperations(sql)) {
      if (op === 'create') built.add(table);
      else if (!built.has(table)) gaps.push({ migration: name, table });
    }
  }
  return gaps;
}

/** 0 built · 1 failed · 2 could not verify. Never a bare pass. */
export function rehearsalExitCode(verdict) {
  if (verdict === REHEARSAL.BUILT) return 0;
  if (verdict === REHEARSAL.FAILED) return 1;
  return 2;
}
