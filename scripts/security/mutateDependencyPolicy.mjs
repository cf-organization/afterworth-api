/**
 * MUTATION TESTING FOR THE DEPENDENCY VULNERABILITY GATE.
 *
 *   node scripts/security/mutateDependencyPolicy.mjs
 *
 * ★ A GREEN SECURITY GATE AND A GATE THAT CHECKS NOTHING ARE INDISTINGUISHABLE FROM THE OUTSIDE.
 *
 * Every guarantee this gate claims is removed here, one at a time, and the suite must go red. A
 * mutation that is NOT detected means the corresponding assertion is decorative — that the policy
 * could be reversed in a pull request and CI would stay green.
 *
 * ★ WHY THIS REPOSITORY HAS ITS OWN RUNNER.
 *
 * afterworth-mobile carries a general `scripts/mutate.js`; this repository's only mutation harness
 * is `mutateSqlAuthorization.mjs`, which is specific to PL/pgSQL authorization and cannot drive a
 * vitest suite. So the isolation DISCIPLINE is copied rather than the code, and it is the part that
 * matters:
 *
 *   · the mutation happens inside a disposable `git worktree`, never in the checkout;
 *   · the worktree is seeded with the working tree — uncommitted edits AND untracked files — so a
 *     branch's own new code is mutable;
 *   · the worktree is removed in a `finally`, so an early return cannot leak it;
 *   · nothing is ever written back to the checkout, which is why no `git checkout -- <file>` cleanup
 *     appears anywhere in this file. That cleanup is how this programme once silently reverted
 *     legitimate work committed minutes earlier.
 *
 * ★ AND A MUTATION THAT DID NOT APPLY IS A HARNESS FAILURE, NEVER A PASS.
 *
 * A `from` string that no longer matches produces a green run that reads exactly like "the control
 * did not fire". So a missing pattern, a missing file, and a suite that executed zero tests are all
 * HARNESS_FAILURE — a refusal to vote, not a vote.
 */
import { execFileSync, spawnSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');

const VERDICT = Object.freeze({
  DETECTED: 'DETECTED',
  NOT_DETECTED: 'NOT_DETECTED',
  HARNESS_FAILURE: 'HARNESS_FAILURE',
});

const git = (args, cwd = ROOT) => execFileSync('git', args, { cwd, encoding: 'utf8' }).trim();
/** RAW, never trimmed: a unified diff represents a blank context line as a single space, and
 *  trimming the last one corrupts the patch with an intermittence that depends on unrelated edits. */
const gitRaw = (args, cwd = ROOT) => execFileSync('git', args, { cwd, encoding: 'utf8' });

function runMutation({ file, from, to, command }) {
  const dir = mkdtempSync(join(tmpdir(), 'aw-depscan-mutation-'));
  const tree = join(dir, 'wt');
  let created = false;
  try {
    git(['worktree', 'add', '--detach', tree, 'HEAD']);
    created = true;

    const diff = gitRaw(['diff', 'HEAD']);
    if (diff.trim()) {
      const patch = join(dir, 'working.patch');
      writeFileSync(patch, diff);
      execFileSync('git', ['apply', patch], { cwd: tree });
    }
    for (const rel of git(['ls-files', '--others', '--exclude-standard']).split('\n').filter(Boolean)) {
      const dest = join(tree, rel);
      mkdirSync(dirname(dest), { recursive: true });
      copyFileSync(join(ROOT, rel), dest);
    }

    const target = join(tree, file);
    if (!existsSync(target)) return { verdict: VERDICT.HARNESS_FAILURE, detail: `missing file: ${file}` };

    const before = readFileSync(target, 'utf8');
    if (!before.includes(from)) return { verdict: VERDICT.HARNESS_FAILURE, detail: `pattern not found in ${file}` };
    writeFileSync(target, before.replace(from, to));

    const linked = join(tree, 'node_modules');
    if (!existsSync(linked)) symlinkSync(join(ROOT, 'node_modules'), linked, 'dir');

    const res = spawnSync(command[0], command.slice(1), { cwd: tree, encoding: 'utf8', shell: false });
    const out = `${res.stdout ?? ''}${res.stderr ?? ''}`;

    // vitest summary:  "Tests  92 passed (92)"  /  "Tests  1 failed | 91 passed (92)"
    const line = (out.match(/^\s*Tests\s+.*$/m) ?? [''])[0];
    const total = Number((line.match(/\((\d+)\)\s*$/) ?? [0, 0])[1]);
    const failed = Number((line.match(/(\d+) failed/) ?? [0, 0])[1]);

    // ★ Zero tests executed proves nothing about the mutation — the suite could not load.
    if (total === 0) return { verdict: VERDICT.HARNESS_FAILURE, detail: `no tests executed · ${line.trim() || out.trim().split('\n').slice(-1)[0]}` };
    if (failed > 0 && res.status !== 0) return { verdict: VERDICT.DETECTED, detail: line.trim() };
    return { verdict: VERDICT.NOT_DETECTED, detail: `${line.trim()} — the suite stayed green` };
  } finally {
    if (created) {
      try { git(['worktree', 'remove', '--force', tree]); } catch { /* the temp dir below still goes */ }
      try { git(['worktree', 'prune']); } catch { /* untidy, never unsafe */ }
    }
    rmSync(dir, { recursive: true, force: true });
  }
}

const POLICY_TEST = ['npx', 'vitest', 'run', 'test/dependencyVulnerabilityPolicy.test.ts'];
const INSTRUMENT_TEST = ['npx', 'vitest', 'run', 'test/dependencySecurityInstrument.test.ts'];
const POLICY_TEST_FILE = 'test/dependencyVulnerabilityPolicy.test.ts';

/**
 * ★ THE FOURTEEN MUTATIONS, AS DATA.
 *
 * Each one removes a specific guarantee. If the suite still passes, that guarantee was never being
 * enforced and the green run meant nothing. `from` strings are chosen to be UNIQUE in their file —
 * `- run: npm ci` alone appears in several jobs, and mutating the first occurrence would have
 * changed a DIFFERENT job than the one under test, producing a NOT_DETECTED that says nothing about
 * the dependency gate.
 */
const POLICY = 'scripts/security/vulnerabilityPolicy.mjs';
const WORKFLOW = '.github/workflows/ci.yml';

function specs({ policyTest, instrumentTest, policyTestFile }) {
  return [
    {
      id: 'M1',
      what: 'high severity changed from FAIL to REPORT',
      file: POLICY,
      from: "export const FAILING_SEVERITIES = Object.freeze(['critical', 'high']);",
      to: "export const FAILING_SEVERITIES = Object.freeze(['critical']);",
      command: policyTest,
    },
    {
      id: 'M2',
      what: 'critical severity changed from FAIL to REPORT',
      file: POLICY,
      from: "export const FAILING_SEVERITIES = Object.freeze(['critical', 'high']);",
      to: "export const FAILING_SEVERITIES = Object.freeze(['high']);",
      command: policyTest,
    },
    {
      id: 'M3',
      what: 'unknown severity mapped to a passing disposition',
      file: POLICY,
      from: "if (!known) return { severity: 'unknown', known: false, disposition: DISPOSITION.FAIL };",
      to: "if (!known) return { severity: 'unknown', known: false, disposition: DISPOSITION.REPORT };",
      command: policyTest,
    },
    {
      id: 'M4',
      what: 'scanner spawn failure treated as a clean scan',
      file: POLICY,
      from: '      outcome: OUTCOME.SCANNER_UNAVAILABLE,\n      reason: `the scanner could not be started',
      to: '      outcome: OUTCOME.SCAN_CLEAN,\n      reason: `the scanner could not be started',
      command: policyTest,
    },
    {
      id: 'M5',
      what: 'the dependency scan step removed from CI',
      file: WORKFLOW,
      from: '        run: node scripts/security/dependencyAudit.mjs',
      to: '        run: echo "scan skipped"',
      command: instrumentTest,
    },
    {
      id: 'M6',
      what: 'the enforcing step made continue-on-error',
      file: WORKFLOW,
      from: '      - name: Dependency vulnerability scan\n',
      to: '      - name: Dependency vulnerability scan\n        continue-on-error: true\n',
      command: instrumentTest,
    },
    {
      id: 'M7',
      what: '`|| true` appended to the enforcing step',
      file: WORKFLOW,
      from: '        run: node scripts/security/dependencyAudit.mjs',
      to: '        run: node scripts/security/dependencyAudit.mjs || true',
      command: instrumentTest,
    },
    {
      id: 'M8',
      what: 'the post-scan lockfile-immutability guard removed',
      file: WORKFLOW,
      from: '      - name: Assert the scan changed nothing\n        run: git diff --exit-code',
      to: '      - name: Assert the scan changed nothing\n        run: echo ok',
      command: instrumentTest,
    },
    {
      id: 'M9',
      what: 'the frozen install replaced with a mutable install',
      file: WORKFLOW,
      from: '      - run: npm ci\n\n      - name: Assert the frozen install changed nothing',
      to: '      - run: npm install\n\n      - name: Assert the frozen install changed nothing',
      command: instrumentTest,
    },
    {
      id: 'M10',
      what: 'an auto-fix command introduced into the job',
      file: WORKFLOW,
      from: '      - name: Dependency vulnerability scan\n',
      to: '      - name: Remediate\n        run: npm audit fix\n\n      - name: Dependency vulnerability scan\n',
      command: instrumentTest,
    },
    {
      id: 'M11',
      what: 'workflow permissions widened to write',
      file: WORKFLOW,
      from: '    permissions:\n      contents: read',
      to: '    permissions:\n      contents: write',
      command: instrumentTest,
    },
    {
      id: 'M12',
      what: 'an action unpinned to a moving ref',
      file: WORKFLOW,
      from: '      - uses: actions/checkout@v4\n\n      - uses: actions/setup-node@v4',
      to: '      - uses: actions/checkout@main\n\n      - uses: actions/setup-node@v4',
      command: instrumentTest,
    },
    {
      id: 'M13',
      what: 'the positive control no longer reaches a failing classification',
      file: policyTestFile,
      from: "const POSITIVE_CONTROL_SEVERITY = 'high';",
      to: "const POSITIVE_CONTROL_SEVERITY = 'low';",
      command: policyTest,
    },
    {
      id: 'M14',
      what: 'empty scanner output parsed as clean',
      file: POLICY,
      from: "return { outcome: OUTCOME.SCANNER_OUTPUT_INVALID, reason: 'the scanner produced no output', diagnostic };",
      to: "return { outcome: OUTCOME.SCAN_CLEAN, reason: 'the scanner produced no output', diagnostic };",
      command: policyTest,
    },
  ];
}


const MUTATIONS = specs({ policyTest: POLICY_TEST, instrumentTest: INSTRUMENT_TEST, policyTestFile: POLICY_TEST_FILE });

/** ★ The checkout is never written to — proved, not assumed, by comparing before and after. */
const treeBefore = git(['status', '--porcelain']);

const results = [];
for (const m of MUTATIONS) {
  const r = runMutation({ file: m.file, from: m.from, to: m.to, command: m.command });
  results.push({ ...m, ...r });
  console.log(`${m.id.padEnd(4)} ${r.verdict.padEnd(16)} ${m.what}`);
  if (r.verdict !== VERDICT.DETECTED) console.log(`      ↳ ${r.detail}`);
}

const detected = results.filter((r) => r.verdict === VERDICT.DETECTED).length;
const notDetected = results.filter((r) => r.verdict === VERDICT.NOT_DETECTED);
const harnessFailures = results.filter((r) => r.verdict === VERDICT.HARNESS_FAILURE);

const treeAfter = git(['status', '--porcelain']);
const worktrees = git(['worktree', 'list']).split('\n').filter(Boolean).length;

console.log('');
console.log(`DETECTED ${detected}/${MUTATIONS.length} · NOT_DETECTED ${notDetected.length} · HARNESS_FAILURE ${harnessFailures.length}`);
for (const r of notDetected) console.log(`  NOT_DETECTED ${r.id}: ${r.what}`);
for (const r of harnessFailures) console.log(`  HARNESS_FAILURE ${r.id}: ${r.detail}`);
console.log(`working tree unchanged: ${treeBefore === treeAfter} · worktrees remaining: ${worktrees} (expected 1)`);

const clean = detected === MUTATIONS.length && treeBefore === treeAfter && worktrees === 1;
process.exit(clean ? 0 : 1);
