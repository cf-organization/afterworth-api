/**
 * R-02 EVENT-TRIGGER PROBE POLICY — what the mutation probe is allowed to contain.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ WHY A SEPARATE POLICY. Every other R-02 pack is audited SELECT-only. This one MUST contain DDL,
 *   so running the SELECT-only auditor against it would report a defect that is the whole point of
 *   the file. But "it may contain DDL" is not a licence — the DDL is enumerated statement-by-
 *   statement, with the object names PINNED, and anything else is refused.
 *
 * ★ THE ALLOWED SET IS TINY AND EXACT:
 *     SELECT
 *     CREATE FUNCTION      public.r02_probe_event_fn_v1        (that name, no other)
 *     CREATE EVENT TRIGGER r02_probe_event_trigger_v1          (that name, no other)
 *     DROP EVENT TRIGGER   r02_probe_event_trigger_v1
 *     DROP FUNCTION        public.r02_probe_event_fn_v1
 *     BEGIN / COMMIT / ROLLBACK
 *
 *   CREATE TABLE, CREATE SCHEMA, CREATE EXTENSION, ALTER, INSERT, UPDATE, DELETE, TRUNCATE, MERGE,
 *   GRANT, REVOKE, SET ROLE, DO, CALL and COPY are all refused — as is a DROP of anything other
 *   than the two disposable objects.
 *
 * ★ THE CANONICAL NAMES ARE FORBIDDEN OUTRIGHT. A probe that created `ensure_rls` or
 *   `rls_auto_enable` would stop being disposable: cleanup would then delete something Model C
 *   later needs, and a failed cleanup would leave a half-real canonical object behind. The probe
 *   must be unmistakably not-the-real-thing.
 *
 * PURE. No filesystem, no network.
 */

/** Replace string-literal CONTENTS with spaces so keyword matching cannot fire inside a literal. */
export function maskProbeLiterals(sql) {
  const s = String(sql ?? '');
  let out = '', i = 0, inS = false, dollar = null;
  while (i < s.length) {
    const c = s[i];
    if (dollar) { if (s.startsWith(dollar, i)) { out += dollar; i += dollar.length; dollar = null; continue; } out += ' '; i += 1; continue; }
    if (inS) { if (c === "'" && s[i + 1] === "'") { out += '  '; i += 2; continue; } if (c === "'") { inS = false; out += c; i += 1; continue; } out += ' '; i += 1; continue; }
    const dq = /^\$[A-Za-z_0-9]*\$/.exec(s.slice(i));
    if (dq) { dollar = dq[0]; out += dollar; i += dollar.length; continue; }
    if (c === "'") { inS = true; out += c; i += 1; continue; }
    out += c; i += 1;
  }
  return out;
}

export const PROBE_VERSION = 'v1';
export const PROBE_FUNCTION = `r02_probe_event_fn_${PROBE_VERSION}`;
export const PROBE_TRIGGER = `r02_probe_event_trigger_${PROBE_VERSION}`;

/** Names the probe may never create, drop or reference as its own objects. */
export const CANONICAL_NAMES = Object.freeze(['ensure_rls', 'rls_auto_enable']);

export const PROBE_REFUSAL = Object.freeze({
  EMPTY: 'probe_empty',
  DISALLOWED_STATEMENT: 'disallowed_statement',
  UNPINNED_OBJECT: 'unpinned_object_name',
  CANONICAL_NAME: 'canonical_name_forbidden',
  MISSING_CLEANUP: 'cleanup_missing',
  MISSING_PRECHECK: 'precheck_missing',
  MISSING_POSTCHECK: 'postcheck_missing',
  SECURITY_DEFINER: 'security_definer_not_permitted',
});

/** Statement classifier. Returns a kind, or null when nothing matches (which is a refusal). */
export function classifyProbeStatement(stmt) {
  const s = String(stmt ?? '').replace(/\s+/g, ' ').trim();
  if (s === '') return null;
  if (/^select\b/i.test(s)) {
    // ★ `SELECT ... INTO tbl` CREATES A TABLE. A statement beginning with SELECT is not
    //   automatically read-only, and classifying on the leading verb alone let
    //   `select * into public.newtbl from pg_class` through as harmless. Literals are masked first
    //   so the word inside a string cannot trigger a false refusal, and `\binto\b` will not match
    //   an identifier like `into_x`.
    return /\binto\b/i.test(maskProbeLiterals(s)) ? null : { kind: 'select' };
  }
  if (/^(begin|commit|rollback|start transaction)\b/i.test(s)) return { kind: 'transaction' };
  // ALTER ROLE / SET ROLE and friends fall through to the final `return null` (refusal).

  let m;
  if ((m = /^create\s+(or\s+replace\s+)?function\s+(?:"?public"?\.)?"?([a-z_0-9]+)"?/i.exec(s))) {
    return { kind: 'create_function', name: m[2].toLowerCase(), securityDefiner: /\bsecurity\s+definer\b/i.test(s) };
  }
  if ((m = /^create\s+event\s+trigger\s+"?([a-z_0-9]+)"?/i.exec(s))) {
    return { kind: 'create_event_trigger', name: m[1].toLowerCase() };
  }
  if ((m = /^drop\s+event\s+trigger\s+(?:if\s+exists\s+)?"?([a-z_0-9]+)"?/i.exec(s))) {
    return { kind: 'drop_event_trigger', name: m[1].toLowerCase() };
  }
  if ((m = /^drop\s+function\s+(?:if\s+exists\s+)?(?:"?public"?\.)?"?([a-z_0-9]+)"?/i.exec(s))) {
    return { kind: 'drop_function', name: m[1].toLowerCase() };
  }
  return null;   // ★ unrecognized is a REFUSAL, never a pass-through
}

/**
 * Audit a probe script. `statements` must already be comment-stripped by the caller.
 *
 * ★ IT ALSO REQUIRES THE SAFETY STRUCTURE, not just the absence of bad statements: a PRE check, a
 *   POST check, and a DROP for every CREATE. A probe that creates and never cleans up would pass a
 *   purely negative audit while leaving objects in a hosted project.
 */
export function auditProbe(statements) {
  const problems = [];
  const stmts = (statements ?? []).map((s) => String(s).trim()).filter(Boolean);
  if (stmts.length === 0) return { ok: false, problems: [PROBE_REFUSAL.EMPTY], kinds: [] };

  const kinds = [];
  for (const s of stmts) {
    const c = classifyProbeStatement(s);
    if (!c) { problems.push(`${PROBE_REFUSAL.DISALLOWED_STATEMENT}: ${s.slice(0, 70)}`); kinds.push('?'); continue; }
    kinds.push(c.kind);

    if (c.name && CANONICAL_NAMES.includes(c.name)) problems.push(`${PROBE_REFUSAL.CANONICAL_NAME}: ${c.name}`);
    if ((c.kind === 'create_function' || c.kind === 'drop_function') && c.name !== PROBE_FUNCTION)
      problems.push(`${PROBE_REFUSAL.UNPINNED_OBJECT}: function ${c.name}`);
    if ((c.kind === 'create_event_trigger' || c.kind === 'drop_event_trigger') && c.name !== PROBE_TRIGGER)
      problems.push(`${PROBE_REFUSAL.UNPINNED_OBJECT}: event trigger ${c.name}`);
    if (c.kind === 'create_function' && c.securityDefiner)
      problems.push(PROBE_REFUSAL.SECURITY_DEFINER);
  }

  // Structure: a PRE select, a POST select, and cleanup for everything created.
  if (kinds[0] !== 'select') problems.push(PROBE_REFUSAL.MISSING_PRECHECK);
  if (kinds[kinds.length - 1] !== 'select') problems.push(PROBE_REFUSAL.MISSING_POSTCHECK);
  if (kinds.includes('create_function') && !kinds.includes('drop_function')) problems.push(`${PROBE_REFUSAL.MISSING_CLEANUP}: function`);
  if (kinds.includes('create_event_trigger') && !kinds.includes('drop_event_trigger')) problems.push(`${PROBE_REFUSAL.MISSING_CLEANUP}: event trigger`);

  return { ok: problems.length === 0, problems, kinds };
}
