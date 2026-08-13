/**
 * Shared assembly for the paste-ready SQL bundles.
 *
 * ★ WHY A BUNDLER RATHER THAN A SECOND COPY. Every DDL and SECURITY DEFINER body lives in exactly one
 * file. Duplicating a DEFINER body into a migration would put an authorization gate in two places,
 * and the copy that gets patched is not necessarily the copy that is deployed. Phase 10-E found that
 * failure already realized in `db/tests/preamble_real_auth.sql`, which carried a hand-copied
 * `create_asset_grant` that had silently drifted from the real one.
 *
 * ★ IT FAILS LOUDLY WHEN IT CANNOT ASSEMBLE, AND CHECKS POSITIVE CONTROLS BEFORE WRITING A BYTE. A
 * bundler that emits half a migration is worse than no bundler — the objects exist with nothing
 * behind them, and the failure surfaces at first use rather than at deploy time. If the inputs do not
 * contain the objects the bundle exists to create, a green "wrote N bytes" would be indistinguishable
 * from a correct run, so the controls run first and a miss exits non-zero.
 *
 * Extracted from `buildEstateAssetBundle.mjs` when a second bundle arrived. The extraction is
 * verified the only way that means anything: the estate bundle rebuilds BYTE-FOR-BYTE identical.
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';

/**
 * Assemble one bundle.
 *
 * @param {object}   spec
 * @param {string}   spec.root       repository root
 * @param {string}   spec.script     the calling script's filename, recorded in the artifact header
 * @param {string[]} spec.parts      input paths, IN LOAD ORDER — order is load-bearing
 * @param {[string,string][]} spec.controls  [file, needle] pairs proving the inputs are what we think
 * @param {string}   spec.out        default output path, relative to root
 * @param {string[]} argv            process.argv.slice(2) — supports --check and --out
 */
export function buildBundle({ root, script, parts, controls, out }, argv = []) {
  const missing = parts.filter((p) => !existsSync(join(root, p)));
  if (missing.length > 0) {
    console.error(`✗ CANNOT ASSEMBLE — missing input(s):\n  ${missing.join('\n  ')}`);
    process.exit(2);
  }

  const sources = new Map(parts.map((p) => [p, readFileSync(join(root, p), 'utf8')]));

  // ★ EVERY CONTROL MUST NAME A FILE THAT IS ACTUALLY IN `parts`. A control pointing at a file the
  // bundle does not include would read `undefined` and throw — or worse, if it were written
  // defensively, would silently pass. Assert the scan set before evaluating any rule.
  const stray = controls.filter(([file]) => !sources.has(file));
  if (stray.length > 0) {
    console.error('✗ HARNESS ERROR — control(s) name a file this bundle does not include:');
    for (const [file, needle] of stray) console.error(`  ${file} (looking for: ${needle})`);
    process.exit(3);
  }

  const failed = controls.filter(([file, needle]) => !sources.get(file).includes(needle));
  if (failed.length > 0) {
    console.error('✗ FAILED POSITIVE CONTROL — the inputs do not contain what this bundle creates:');
    for (const [file, needle] of failed) console.error(`  ${file} is missing: ${needle}`);
    process.exit(3);
  }

  if (argv.includes('--check')) {
    console.log(`✓ inputs present and all ${controls.length} positive controls found`);
    process.exit(0);
  }

  const outIdx = argv.indexOf('--out');
  const target = resolve(root, outIdx > -1 ? argv[outIdx + 1] : out);

  /**
   * ★ PSQL META-COMMANDS ARE STRIPPED FROM THE ARTIFACT, AND THIS IS A DEPLOYMENT-SAFETY FIX.
   *
   * The source migrations begin `\set ON_ERROR_STOP on`. That is a **psql client** directive, not
   * SQL: the Supabase Web SQL Editor sends text to the server, so the line either errors or — far
   * worse — is ignored, leaving the operator believing ON_ERROR_STOP is in force when it is not. A
   * mid-bundle failure would then let the remaining statements run, producing exactly the
   * half-applied state every verifier in this repo exists to detect.
   *
   * Evidence it was new: every migration actually deployed (0042, 0043, 0048, 0049, 0050) contains
   * zero meta-commands; only the never-deployed 0051-0055 introduced the convention. No bundle the
   * operator has ever pasted carried one, so there was no precedent that the editor tolerates it.
   *
   * The SOURCE files keep the line — the psql-driven SQL suite applies those directly, and its
   * runner also passes `-v ON_ERROR_STOP=1` as a flag, so nothing is lost on that path.
   */
  /**
   * ★ AND PART-LEVEL TRANSACTION CONTROL IS NEUTRALISED TOO — THE DEFECT THAT MADE ONE ARTIFACT
   * NON-ATOMIC WHILE ITS HEADER CLAIMED OTHERWISE.
   *
   * Forty legacy migrations (0010-0049) wrap themselves in their own `begin; … commit;`. Inside a
   * bundle that is not harmless: the part's `commit;` CLOSES the artifact's wrapper early, so
   * everything before it is committed and everything after runs unprotected. The estate bundle
   * carries 0048 and 0049 and was exactly that shape — proven by executing it with an injected
   * mid-file error and finding `get_estate_discovery` still present afterwards.
   *
   * ★ IT IS DOLLAR-QUOTE AWARE, WHICH IS THE WHOLE DIFFICULTY. plpgsql bodies are full of `begin`
   * and `end` and live inside `$function$ … $function$`; a naive line filter would either miss
   * top-level control or maim a function body. So the scanner tracks quoting depth and only
   * neutralises control statements at depth 0. Block-starts are additionally distinguishable by
   * shape — plpgsql writes `begin` with NO semicolon, transaction control writes `begin;`.
   */
  const DOLLAR = /\$[A-Za-z_]*\$/g;
  const stripMeta = (sql) => {
    let depth = 0;
    let openTag = null;
    return sql
      .split('\n')
      .map((line) => {
        const atTopLevel = depth === 0;
        // Update quoting state from THIS line before deciding about the NEXT one.
        for (const m of line.match(DOLLAR) ?? []) {
          if (openTag === null) { openTag = m; depth = 1; }
          else if (m === openTag) { openTag = null; depth = 0; }
        }
        if (!atTopLevel) return line;
        if (/^\s*\\[a-zA-Z]/.test(line)) {
          return `-- [psql meta-command removed for the SQL editor] ${line.trim()}`;
        }
        if (/^\s*(begin|commit|rollback)\s*;\s*$/i.test(line)) {
          return `-- [part-level transaction control removed; the artifact owns one] ${line.trim()}`;
        }
        return line;
      })
      .join('\n');
  };

  const body = parts
    .map((p) => `\n-- ==== ${p} ${'='.repeat(Math.max(0, 92 - p.length))}\n${stripMeta(sources.get(p))}`)
    .join('\n');

  /**
   * ★ ONE EXPLICIT TRANSACTION AROUND THE WHOLE ARTIFACT — atomicity that does not depend on the
   * editor's behaviour.
   *
   * Postgres DDL is transactional, and every statement these bundles carry is transaction-safe:
   * there is no CREATE INDEX CONCURRENTLY, no VACUUM, no ALTER TYPE ... ADD VALUE, no CREATE
   * DATABASE/TABLESPACE, no ALTER SYSTEM. The bundler ASSERTS that below rather than trusting it,
   * so a future part that is not transaction-safe fails the build instead of silently producing an
   * artifact whose BEGIN/COMMIT is a lie.
   *
   * With the wrapper, mid-bundle failure behaviour stops being a property of the tool and becomes a
   * property of the artifact: any error aborts the transaction, COMMIT cannot be reached, and the
   * database is left exactly as it was. That is also why the migrations' own `raise exception`
   * self-checks are load-bearing here — a failed self-check aborts before COMMIT, so a bundle that
   * detects its own bad state cannot half-apply.
   */
  const NON_TRANSACTIONAL = [
    [/\bCONCURRENTLY\b/i, 'CREATE/DROP INDEX CONCURRENTLY'],
    [/^\s*VACUUM\b/im, 'VACUUM'],
    [/\bCREATE\s+DATABASE\b/i, 'CREATE DATABASE'],
    [/\bDROP\s+DATABASE\b/i, 'DROP DATABASE'],
    [/\bCREATE\s+TABLESPACE\b/i, 'CREATE TABLESPACE'],
    [/\bALTER\s+SYSTEM\b/i, 'ALTER SYSTEM'],
    [/^\s*CLUSTER\b/im, 'CLUSTER'],
    [/\bDISCARD\s+ALL\b/i, 'DISCARD ALL'],
    [/\bALTER\s+TYPE\b[\s\S]{0,80}?\bADD\s+VALUE\b/i, 'ALTER TYPE ... ADD VALUE'],
  ];
  const unsafe = NON_TRANSACTIONAL
    .filter(([re]) => re.test(body))
    .map(([, label]) => label);
  if (unsafe.length > 0) {
    console.error('✗ CANNOT WRAP IN A TRANSACTION — these parts contain statements Postgres forbids');
    console.error('  inside a transaction block, so a BEGIN/COMMIT artifact would fail at run time:');
    for (const u of unsafe) console.error(`    ${u}`);
    console.error('  Split the offending statement into its own deployment step with its own');
    console.error('  verification, and state the safe intermediate state in the runbook.');
    process.exit(3);
  }

  const header = `-- GENERATED by scripts/${script} — DO NOT EDIT.
-- Edit the sources instead:
${parts.map((p) => `--   ${p}`).join('\n')}
--
-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- PASTE THIS WHOLE FILE INTO THE SUPABASE WEB SQL EDITOR AND RUN IT ONCE.
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- PURE SQL: this artifact contains no psql meta-commands. (\\set and friends are client directives
-- the web editor cannot honour; they are stripped at build time and remain only in the sources,
-- which are applied through psql by the SQL suite.)
--
-- TRANSACTIONAL: the entire artifact runs inside ONE explicit transaction. Every statement here is
-- transaction-safe — the builder refuses to emit a wrapper otherwise — so:
--
--   · if ANY statement fails, the transaction aborts and COMMIT is never reached;
--   · the database is left EXACTLY as it was: there is no half-applied state to diagnose;
--   · the migrations' own self-checks raise on a bad state, which aborts before COMMIT too, so a
--     bundle that detects a problem rolls itself back rather than shipping it.
--
-- IDEMPOTENT: every table is IF NOT EXISTS, every function is CREATE OR REPLACE, every constraint
-- is dropped-then-added, and every seed uses ON CONFLICT. Re-running is safe and is the intended
-- recovery action after a failure.
begin;
`;

  const footer = `
commit;
-- ★ If you see an error above and no COMMIT, nothing was applied. Fix the cause and paste again.
`;

  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, `${header}${body}${footer}`);

  // ★ SELF-CHECK THE ARTIFACT WE JUST WROTE, rather than trusting the assembly.
  const written = readFileSync(target, 'utf8');
  const strays = written.split('\n').filter((l) => /^\s*\\[a-zA-Z]/.test(l));
  if (strays.length > 0) {
    console.error(`✗ ${strays.length} psql meta-command(s) survived into the artifact:`);
    for (const l of strays.slice(0, 5)) console.error(`    ${l}`);
    process.exit(3);
  }
  if (!/^begin;$/m.test(written) || !/^commit;$/m.test(written)) {
    console.error('✗ the artifact is not wrapped in an explicit transaction');
    process.exit(3);
  }
  /**
   * ★ EXACTLY ONE TRANSACTION, AND THE COUNT IS THE PROOF. A surviving part-level `commit;` would
   * close the wrapper early and silently un-do the atomicity this header promises — so the artifact
   * must contain precisely one `begin;` and one `commit;`, both the bundler's own.
   */
  const begins = (written.match(/^begin;$/gm) ?? []).length;
  const commits = (written.match(/^commit;$/gm) ?? []).length;
  if (begins !== 1 || commits !== 1) {
    console.error(`✗ the artifact contains ${begins} begin; and ${commits} commit; — expected exactly one`);
    console.error('  of each. A part-level commit closes the wrapper early: everything before it is');
    console.error('  applied and everything after runs unprotected, which is a half-deploy waiting');
    console.error('  to happen while the header claims atomicity.');
    process.exit(3);
  }

  console.log(`✓ wrote ${target}`);
  console.log(`  ${parts.length} parts, ${controls.length} positive controls passed`);
  console.log('  pure SQL (no meta-commands) · wrapped in one explicit transaction');
}
