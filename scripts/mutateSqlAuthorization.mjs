#!/usr/bin/env node
/**
 * Security mutation harness for the SQL authorization suite.
 *
 * ★ WHY THIS EXISTS. `verifySqlAuthorization.mjs` reports "104 assertions passed". That sentence is
 * only worth anything if the assertions can FAIL. An authorization suite that cannot detect a
 * deleted authorization check is indistinguishable, from the outside, from one that checks nothing —
 * and this repository has shipped that exact failure more than once (a Dashboard audit with 63
 * assertions against an empty file list; a private-palette matcher that halved its own count).
 *
 * So each mutation below DELETES or WEAKENS one real authorization decision and requires the suite
 * to fail. `NOT_DETECTED` is the finding; a pass here is the harness reporting on itself.
 *
 * ★ IT NEVER WRITES TO YOUR CHECKOUT. Every mutation happens inside a throwaway `git worktree`
 * seeded from the current HEAD, for the reason recorded in the mobile repo's `scripts/mutate.js`:
 * cleanup discipline failed twice, once destroying uncommitted work via a file-level
 * `git checkout`, once stranding three mutated production files after a crash. The developer's
 * working tree is not the thing being mutated, so no crash can strand a mutation in it.
 *
 * ★ AND IT PROVES THE MUTATION ACTUALLY APPLIED. A replacement whose `from` string no longer matches
 * silently mutates nothing, and the suite then passes for the most misleading possible reason: the
 * code under test was never changed. Every mutation asserts the substitution occurred before the
 * suite runs, and a miss is `HARNESS_FAILURE`, never `DETECTED`.
 *
 * Usage:  node scripts/mutateSqlAuthorization.mjs [--only <id>]
 * Exit:   0 every mutation was detected · 1 a mutation survived · 2 the harness could not run
 */
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const VERDICT = Object.freeze({
  DETECTED: 'DETECTED',
  NOT_DETECTED: 'NOT_DETECTED',
  HARNESS_FAILURE: 'HARNESS_FAILURE',
});

/**
 * One mutation = one file, one exact replacement, one expectation.
 *
 * `from` is matched EXACTLY and must occur exactly once. Requiring uniqueness is deliberate: a
 * `from` that matches twice would mutate an arbitrary one of them and the verdict would describe a
 * different edit than the one written here.
 */
const MUTATIONS = Object.freeze([
  {
    id: 'ownership-check-deleted',
    why: 'An owner must be refused the professional projection BY THE OWNERSHIP CHECK. The suite '
      + 'constructs the only data state where that check is load-bearing (an owner who also holds '
      + 'an approved professional_delegate row); without that case this mutation survives.',
    file: 'db/functions/professional_workspace_rpcs.sql',
    from: '  if public.is_estate_owner(p_estate) then',
    to: '  if false then',
  },
  {
    id: 'membership-status-ignored',
    why: 'A REVOKED delegate must lose the workspace. Dropping the status predicate makes any '
      + 'membership row — pending, revoked, expired — sufficient.',
    file: 'db/functions/professional_workspace_rpcs.sql',
    from: "     and m.status = 'approved'",
    to: "     and m.status is not null",
  },
  {
    id: 'role-filter-widened',
    why: 'Membership alone must not confer the workspace — a beneficiary holds a membership row too. '
      + 'Widening the role predicate is the single edit that turns delegation into membership.',
    file: 'db/functions/professional_workspace_rpcs.sql',
    from: "     and m.role = 'professional_delegate'",
    to: "     and m.role is not null",
  },
]);

const only = process.argv.includes('--only') ? process.argv[process.argv.indexOf('--only') + 1] : null;
const selected = only ? MUTATIONS.filter((m) => m.id === only) : MUTATIONS;
if (selected.length === 0) {
  console.error(`✗ CANNOT RUN — no mutation named "${only}". Known: ${MUTATIONS.map((m) => m.id).join(', ')}`);
  process.exit(2);
}

function git(args, cwd = ROOT) {
  return execFileSync('git', args, { cwd, encoding: 'utf8' }).trim();
}

/** The working tree's state, captured before and compared after — the anti-collateral-damage check. */
const treeBefore = git(['status', '--porcelain']);

const results = [];
for (const m of selected) {
  const dir = mkdtempSync(join(tmpdir(), 'aw-sqlmut-'));
  const wt = join(dir, 'wt');
  let verdict = VERDICT.HARNESS_FAILURE;
  let detail = '';
  try {
    git(['worktree', 'add', '--detach', wt, 'HEAD']);

    const target = join(wt, m.file);
    const original = readFileSync(target, 'utf8');
    const occurrences = original.split(m.from).length - 1;
    if (occurrences !== 1) {
      detail = `the mutation anchor occurs ${occurrences} time(s), expected exactly 1 — the harness `
        + 'would have mutated nothing (or the wrong site), and the suite would then pass for a '
        + 'reason that has nothing to do with authorization.';
      throw new Error('anchor');
    }
    const mutated = original.replace(m.from, m.to);

    // ★ PROVE THE EDIT LANDED. This is the check whose absence makes a mutation suite a no-op.
    if (mutated === original || !mutated.includes(m.to)) {
      detail = 'the replacement did not change the file';
      throw new Error('noop');
    }
    writeFileSync(target, mutated, 'utf8');
    const reread = readFileSync(target, 'utf8');
    if (!reread.includes(m.to) || reread.includes(m.from)) {
      detail = 'the mutation was not present on re-read from disk';
      throw new Error('unverified');
    }

    // The bundle is what the suite loads, so it must be rebuilt from the mutated part.
    const build = spawnSync('node', ['scripts/buildEstateAssetBundle.mjs'], {
      cwd: wt, encoding: 'utf8',
    });
    if (build.status !== 0) {
      detail = `bundle rebuild failed inside the worktree: ${(build.stderr || '').slice(0, 300)}`;
      throw new Error('bundle');
    }
    if (!readFileSync(join(wt, 'db/bundles/estate_inventory_and_discovery_bundle.sql'), 'utf8').includes(m.to)) {
      detail = 'the rebuilt bundle does not contain the mutation — the suite would load clean SQL';
      throw new Error('bundle-clean');
    }

    const run = spawnSync('node', ['scripts/verifySqlAuthorization.mjs'], { cwd: wt, encoding: 'utf8' });
    const out = `${run.stdout ?? ''}${run.stderr ?? ''}`;
    if (run.status === 2) {
      detail = 'the suite could not verify (exit 2) — that is a harness failure, never a detection';
      throw new Error('cannot-verify');
    }
    verdict = run.status === 0 ? VERDICT.NOT_DETECTED : VERDICT.DETECTED;
    detail = (out.match(/FAIL: [^\n]*/) ?? [''])[0].slice(0, 200)
      || (verdict === VERDICT.DETECTED ? 'suite exited non-zero' : 'suite still passed');
  } catch (e) {
    if (!detail) detail = e?.message ?? 'unknown harness failure';
  } finally {
    try {
      git(['worktree', 'remove', '--force', wt]);
    } catch {
      /* the temp dir goes next regardless */
    }
    rmSync(dir, { recursive: true, force: true });
  }
  results.push({ ...m, verdict, detail });
  console.log(`${verdict === VERDICT.DETECTED ? '✓' : '✗'} ${m.id.padEnd(28)} ${verdict}`);
  if (verdict !== VERDICT.DETECTED) console.log(`    ${detail}`);
}

// ★ THE CHECKOUT MUST BE BYTE-IDENTICAL TO HOW WE FOUND IT.
const treeAfter = git(['status', '--porcelain']);
if (treeAfter !== treeBefore) {
  console.error('\n✗ HARNESS FAILURE — the working tree changed during the run. Inspect before trusting anything above.');
  process.exit(2);
}
console.log('\nworking tree unchanged (verified, not assumed)');

const survived = results.filter((r) => r.verdict !== VERDICT.DETECTED);
if (survived.length) {
  console.error(`\n✗ ${survived.length} mutation(s) were not killed:`);
  for (const s of survived) console.error(`    ${s.id} — ${s.why}`);
  process.exit(survived.some((s) => s.verdict === VERDICT.HARNESS_FAILURE) ? 2 : 1);
}
console.log(`✓ ALL ${results.length} SECURITY MUTATIONS KILLED — the authorization suite can fail.`);
