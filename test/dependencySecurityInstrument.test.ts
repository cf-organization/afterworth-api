import * as crypto from "node:crypto";
import * as fs from "node:fs";
import * as path from "node:path";
import { describe, expect, it } from "vitest";
import { BASELINEABLE_SEVERITIES, validateBaseline } from "../scripts/security/vulnerabilityPolicy.mjs";

const ROOT = path.resolve(__dirname, "..");

/**
 * AUDIT THE INSTRUMENT — the security tool's own security properties.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ A SCANNER IS A PIECE OF PRIVILEGED AUTOMATION, AND IT GETS AUDITED LIKE ONE.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * The dependency gate runs on every pull request, reads the whole tree, and talks to a registry. If
 * it could write to the repository, rewrite a lockfile, push a commit or print a token, it would be
 * a larger supply-chain risk than the advisories it reports. So the properties that make it safe
 * are asserted here rather than argued in a review.
 *
 * ★ COMMENTS ARE STRIPPED. STRING LITERALS ARE NOT. THE TWO DECISIONS ARE OPPOSITE AND BOTH LOAD-BEARING.
 *
 * The workflow and the runner DISCUSS every forbidden form — `npm audit fix`, `continue-on-error`,
 * `|| true` — while explaining that they do not use them. Leave comments in and the audit condemns
 * its own documentation. Strip string literals and the audit goes blind to the evidence class it
 * exists to find, because a forbidden command reaches a shell AS A STRING. This repository has
 * shipped the mirror mistake already: a raw-hex rule ran against a string-stripped view, and every
 * hex colour in React Native is a string literal. Both strippers are proved in both directions below.
 *
 * ★ THE SCAN SET IS ASSERTED BEFORE ANY RULE IS EVALUATED.
 *
 * Group 0 proves every file exists and is substantial. A resolved root one directory short once let
 * 63 assertions in this programme pass against empty strings.
 */
const SECURITY_DIR = path.join(ROOT, 'scripts', 'security');
const WORKFLOW = path.join(ROOT, '.github', 'workflows', 'ci.yml');

const POLICY_FILE = path.join(SECURITY_DIR, 'vulnerabilityPolicy.mjs');
const RUNNER_FILE = path.join(SECURITY_DIR, 'dependencyAudit.mjs');
const BASELINE_FILE = path.join(SECURITY_DIR, 'dependencyVulnerabilityBaseline.json');

/**
 * ★ THE CROSS-REPOSITORY PIN (Stage 19).
 *
 * afterworth-api and afterworth-mobile carry these two files BYTE-FOR-BYTE identically, and both
 * repositories assert the same two hashes. Editing the policy in one repository and not the other
 * fails BOTH suites. Nothing weaker works: a comment saying "keep these in sync" is a comment.
 *
 * The BASELINES are deliberately not pinned — they describe two different dependency graphs and are
 * expected to differ. It is the RULES that may not diverge.
 */
const SHARED_MODULE_SHA256 = Object.freeze({
  'vulnerabilityPolicy.mjs': 'c061928890a00b575ea77cfd6f72446156bf8d88df94699959a5775f69736e83',
  'dependencyAudit.mjs': 'ca16c6783f6d26e197e8675a910e31d2fcdefccc16c9bdd8a9d2ea700a3f5e34',
});

const read = (p: string) => fs.readFileSync(p, 'utf8');
const sha256 = (s: string) => crypto.createHash('sha256').update(s, 'utf8').digest('hex');

/** JS/JSON comments out, string literals in. */
function stripJsComments(src: string): string {
  return src.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/(^|[^:'"`\\])\/\/[^\n]*/g, '$1');
}

/** YAML `#` comments out, everything else in. A `#` only starts a comment at line start or after space. */
function stripYamlComments(src: string): string {
  return src
    .split('\n')
    .map((line) => line.replace(/(^|\s)#.*$/, '$1'))
    .join('\n');
}

const workflowCode = () => stripYamlComments(read(WORKFLOW));

/**
 * ★ THE DEPENDENCY-SCAN JOB, EXTRACTED — because the rules below are about THIS job.
 *
 * The first draft ran "no step swallows a failure with `|| true`" against the whole workflow file
 * and failed on afterworth-api's PRE-EXISTING secret-scan job, where `git grep … || true` is
 * correct: grep exits 1 when it matches nothing, and that is not an error. A rule that condemns
 * working code in a job it was never about is a false positive, and "fixing" it would have broken
 * a secret scanner. The boundary this audit inspects is one job, so it is named and extracted as
 * one job.
 *
 * Extraction stops at the next top-level job key, so a job appended after this one cannot be
 * silently absorbed into the region under test.
 */
function dependencyScanJob(): string {
  const after = workflowCode().split(/^ {2}dependency-scan:$/m)[1];
  if (after === undefined) return '';
  // The next line at exactly two-space indent that is a mapping key ends this job.
  const end = after.search(/^ {2}[A-Za-z_][\w-]*:/m);
  return end === -1 ? after : after.slice(0, end);
}
/**
 * The Node major the dependency-scan job requests, or null if it declares none.
 *
 * Structural, not a spelling match: it reads the value `actions/setup-node` is actually given,
 * so a rule about the endpoint npm will reach cannot be satisfied by a comment that mentions 24.
 */
function nodeMajorIn(job: string): number | null {
  const m = job.match(/node-version:\s*'?"?(\d+)/);
  return m ? Number(m[1]) : null;
}

/** Node 24 bundles npm 11, whose arborist calls only the bulk advisory endpoint. */
const BULK_ADVISORY_MIN_NODE_MAJOR = 24;

const instrumentCode = () => `${stripJsComments(read(POLICY_FILE))}\n${stripJsComments(read(RUNNER_FILE))}`;

// ═══════════════════════════════════════════════════════════════════════════════════════════════
describe('★ 0 · the scan set is real', () => {
  it('every instrument file exists and is substantial', () => {
    const files = [POLICY_FILE, RUNNER_FILE, BASELINE_FILE, WORKFLOW];
    expect(files.filter((p) => !fs.existsSync(p))).toEqual([]);
    expect(files.filter((p) => read(p).length <= 500)).toEqual([]);
  });

  it('the resolved root is this repository, not a parent', () => {
    expect(fs.existsSync(path.join(ROOT, 'package.json'))).toBe(true);
    expect(fs.existsSync(path.join(ROOT, '.github', 'workflows'))).toBe(true);
  });

  it('★ stripping did not erase the code — the rules below read something', () => {
    expect(workflowCode()).toContain('dependency-scan');
    expect(workflowCode().length).toBeGreaterThan(400);
    expect(instrumentCode()).toContain('parseAuditReport');
    expect(instrumentCode().length).toBeGreaterThan(1500);
  });
});

// ═══════════════════════════════════════════════════════════════════════════════════════════════
describe('★ 1 · both comment strippers are proved in BOTH directions', () => {
  it('the YAML stripper removes a comment', () => {
    expect(stripYamlComments('  # npm audit fix\n  run: x')).not.toContain('audit fix');
  });

  it('★ the YAML stripper does NOT remove a real instruction', () => {
    expect(stripYamlComments('  run: npm ci\n')).toContain('npm ci');
  });

  it('the JS stripper removes line and block comments', () => {
    expect(stripJsComments('a // npm audit fix\nb')).not.toContain('audit fix');
    expect(stripJsComments('a /* continue-on-error */ b')).not.toContain('continue-on-error');
  });

  it('★ the JS stripper does NOT remove a string literal — the evidence class lives there', () => {
    expect(stripJsComments("const a = 'npm audit fix';")).toContain('audit fix');
    expect(stripJsComments('spawnSync("npm", ["audit", "--fix"])')).toContain('--fix');
  });

  it('★ it does not mistake a URL inside a string for a line comment', () => {
    expect(stripJsComments("const u = 'https://example.test/x';")).toContain('example.test');
  });

  /**
   * ★ THE STRIPPERS ARE LOAD-BEARING, SO THEIR NECESSITY IS DEMONSTRATED RATHER THAN ASSERTED.
   *
   * The raw workflow really does contain every forbidden form, in prose. Without stripping, every
   * rule in group 2 would fail on this repository's own documentation.
   */
  it('★ the RAW workflow contains a forbidden form in prose — which is why stripping is required', () => {
    const raw = read(WORKFLOW);
    // The dependency-scan comment block explains what the job does NOT do, naming the forms
    // verbatim. Every one of these words is present ONLY inside a comment.
    const forms = ['audit fix', 'continue-on-error'];
    expect(forms.filter((f) => !raw.includes(f))).toEqual([]);
    expect(forms.filter((f) => stripYamlComments(raw).includes(f))).toEqual([]);
  });
});

// ═══════════════════════════════════════════════════════════════════════════════════════════════
describe('★ 2 · the dependency-scan job cannot be silently disabled', () => {
  it('the job exists and invokes the scanner', () => {
    expect(workflowCode()).toMatch(/^ {2}dependency-scan:$/m);
    expect(dependencyScanJob()).toContain('node scripts/security/dependencyAudit.mjs');
  });

  it('★ the extractor really isolated a job — and not the whole file', () => {
    const job = dependencyScanJob();
    expect(job.length).toBeGreaterThan(200);
    expect(job).toContain('npm ci');
    // A sibling job's body must NOT be inside the extracted region.
    expect(job).not.toMatch(/^ {2}(verify|checks|secret-scan|gitleaks):/m);
  });

  it('★ the enforcing step is NOT continue-on-error', () => {
    expect(dependencyScanJob()).not.toContain('continue-on-error');
  });

  it('★ no step in this job swallows a failure with `|| true`, `|| exit 0` or `set +e`', () => {
    const job = dependencyScanJob();
    expect(job).not.toMatch(/\|\|\s*true/);
    expect(job).not.toMatch(/\|\|\s*exit\s+0/);
    expect(job).not.toMatch(/set\s+\+e/);
  });

  it('★ the install is FROZEN — npm ci, never npm install/update/upgrade', () => {
    const job = dependencyScanJob();
    expect(job).toContain('npm ci');
    expect(job).not.toMatch(/npm\s+install/);
    expect(job).not.toMatch(/npm\s+update/);
    expect(job).not.toMatch(/npm\s+upgrade/);
  });

  /** Remediation is forbidden across the WHOLE file: no job in CI may ever rewrite the graph. */
  it('★ NO REMEDIATION COMMAND APPEARS ANYWHERE IN THIS WORKFLOW', () => {
    const code = workflowCode().toLowerCase();
    const forbidden = ['audit fix', '--fix', 'dependabot', 'renovate', 'auto-merge', 'automerge', 'npm-check-updates'];
    expect(forbidden.filter((f) => code.includes(f))).toEqual([]);
  });

  it('★ the lockfile-immutability guard runs after BOTH the install and the scan', () => {
    const job = dependencyScanJob();
    expect((job.match(/git diff --exit-code/g) ?? []).length).toBeGreaterThanOrEqual(2);
    // …and it is genuinely after the scan, not two guards stacked before it.
    expect(job.lastIndexOf('git diff --exit-code')).toBeGreaterThan(job.indexOf('dependencyAudit.mjs'));
  });

  it('★ the job holds contents: read and no write permission of any kind', () => {
    const job = dependencyScanJob();
    expect(job).toMatch(/permissions:\s*\n\s+contents: read/);
    for (const w of ['contents: write', 'pull-requests: write', 'actions: write', 'packages: write', 'id-token: write']) {
      expect(job).not.toContain(w);
    }
    expect(job).not.toMatch(/permissions:\s*write-all/);
  });

  it('★ no action anywhere in this workflow is pinned to a moving ref', () => {
    const uses = workflowCode().match(/uses:\s*\S+/g) ?? [];
    expect(uses.length).toBeGreaterThan(0);
    for (const u of uses) expect(u).not.toMatch(/@(main|master|latest|HEAD)\s*$/);
  });

  it('the job introduces no third-party action — only first-party actions/* already used here', () => {
    for (const u of dependencyScanJob().match(/uses:\s*(\S+)/g) ?? []) {
      expect(u).toMatch(/uses:\s*actions\//);
    }
  });

  it('no step pipes a downloaded script into a shell', () => {
    expect(dependencyScanJob()).not.toMatch(/curl[^\n]*\|\s*(ba)?sh/);
    expect(dependencyScanJob()).not.toMatch(/wget[^\n]*\|\s*(ba)?sh/);
  });

  /** ★ Detection fixtures — each rule above is proved capable of failing. */
  it('★ detection fixtures — every workflow rule would catch its violation', () => {
    expect(stripYamlComments('    continue-on-error: true')).toContain('continue-on-error');
    expect(/\|\|\s*true/.test('run: node x.mjs || true')).toBe(true);
    expect(/npm\s+install/.test('run: npm install')).toBe(true);
    expect('run: npm audit fix'.toLowerCase()).toContain('audit fix');
    expect('uses: actions/checkout@main').toMatch(/@(main|master|latest|HEAD)\s*$/);
    expect('      contents: write').toContain('contents: write');
    expect(/curl[^\n]*\|\s*(ba)?sh/.test('run: curl https://x/y.sh | sh')).toBe(true);
    expect(/set\s+\+e/.test('run: set +e')).toBe(true);
    expect(nodeMajorIn('        with:\n          node-version: 20\n')).toBe(20);
  });

  /**
   * ★ THE JOB MUST RUN ON A NODE WHOSE BUNDLED npm USES THE BULK ADVISORY ENDPOINT.
   *
   * Nothing in this repository chooses an advisory endpoint — `dependencyAudit.mjs` shells out to
   * `npm audit` and npm decides. On 2026-09-04 that turned into a CI failure: Node 20's npm still
   * POSTs to `/-/npm/v1/security/audits/quick`, npm retired that endpoint, the POST returned 400,
   * and the scan reported SCANNER_UNAVAILABLE. The gate behaved correctly — it refused to call an
   * unfinished scan clean — but the job could not complete at all.
   *
   * The fix was a one-line Node bump, and a one-line fix is exactly the kind that gets reverted by
   * someone tidying versions who has no idea it is load-bearing. So the minimum is pinned here,
   * with the reason attached. Node 24 bundles npm 11, whose arborist has no quick-endpoint path.
   */
  it('★ the dependency-scan job pins a Node major whose npm uses the bulk advisory endpoint', () => {
    const major = nodeMajorIn(dependencyScanJob());
    expect(major).not.toBeNull();
    expect(major).toBeGreaterThanOrEqual(BULK_ADVISORY_MIN_NODE_MAJOR);
  });

  it('★ that rule would catch a revert to the endpoint-retired Node', () => {
    // The exact text this job carried when the scan could not complete.
    const broken = '      - uses: actions/setup-node@v4\n        with:\n          node-version: 20\n';
    expect(nodeMajorIn(broken)).toBeLessThan(BULK_ADVISORY_MIN_NODE_MAJOR);
    // …and the rule is not vacuous: the current job really does declare a version.
    expect(nodeMajorIn(dependencyScanJob())).not.toBeNull();
  });
});

// ═══════════════════════════════════════════════════════════════════════════════════════════════
describe('★ 3 · the instrument itself is read-only and reaches nothing it should not', () => {
  it('★ it never invokes a remediating command', () => {
    const code = instrumentCode();
    expect(code).not.toContain('audit fix');
    expect(code).not.toMatch(/['"]--fix['"]/);
    expect(code).not.toMatch(/npm\s+install/);
    expect(code).not.toMatch(/['"]install['"]/);
  });

  it('★ it never writes to the repository or to git', () => {
    const code = instrumentCode();
    for (const forbidden of ['writeFileSync', 'writeFile', 'appendFile', 'rmSync', 'unlinkSync', 'mkdirSync']) {
      expect(code).not.toContain(forbidden);
    }
    expect(code).not.toMatch(/git\s+(push|commit|add|checkout|tag)/);
  });

  it('★ it spawns exactly one program, and that program is npm', () => {
    const code = instrumentCode();
    const spawns = code.match(/spawnSync\(\s*'([^']+)'/g) ?? [];
    expect(spawns.length).toBeGreaterThan(0);
    for (const s of spawns) expect(s).toContain("'npm'");
    expect(code).not.toContain('execSync');
    expect(code).not.toContain('shell: true');
    expect(code).toContain('shell: false');
  });

  it('★ it opens no network connection of its own', () => {
    const code = instrumentCode();
    for (const forbidden of ['fetch(', 'XMLHttpRequest', 'node:https', 'node:http', "require('https')", 'WebSocket']) {
      expect(code).not.toContain(forbidden);
    }
  });

  it('★ it names no production host, credential or environment secret', () => {
    const code = `${instrumentCode()}\n${read(BASELINE_FILE)}`;
    const forbidden = [
      'supabase.co',
      'SUPABASE',
      'SERVICE_ROLE',
      'service_role',
      'vercel.app',
      'RESEND',
      'UPSTASH',
      'AW_ADMIN',
    ];
    expect(forbidden.filter((f) => code.includes(f))).toEqual([]);
  });

  it('★ it names no Branch-B or release-programme identifier', () => {
    const code = `${instrumentCode()}\n${read(BASELINE_FILE)}\n${workflowCode()}`;
    for (const forbidden of ['branchB', 'BranchB', 'AW_ADMIN_TEST_B', 'authorize_release', 'challenge_window', 'owner_notice']) {
      expect(code).not.toContain(forbidden);
    }
  });

  it('★ the policy module is PURE — no clock, no process, no I/O', () => {
    const policy = stripJsComments(read(POLICY_FILE));
    const forbidden = ['Date.now', 'new Date(', 'readFileSync', 'spawnSync', 'process.', 'Math.random', 'fetch('];
    expect(forbidden.filter((f) => policy.includes(f))).toEqual([]);
  });

  it('★ detection fixtures — every instrument rule would catch its violation', () => {
    expect(stripJsComments("const c = ['audit','--fix'];")).toContain('--fix');
    expect(stripJsComments("await fetch('https://x');")).toContain('fetch(');
    expect(stripJsComments('fs.writeFileSync(p, s);')).toContain('writeFileSync');
    expect(stripJsComments('const t = Date.now();')).toContain('Date.now');
    expect(stripJsComments("spawnSync('sh', ['-c', x], { shell: true });")).toContain('shell: true');
  });
});

// ═══════════════════════════════════════════════════════════════════════════════════════════════
describe('★ 4 · the cross-repository policy pin', () => {
  it('★ the shared modules match the hashes BOTH repositories assert', () => {
    const actual = Object.fromEntries(
      Object.keys(SHARED_MODULE_SHA256).map((name) => [name, sha256(read(path.join(SECURITY_DIR, name)))])
    );
    expect(actual).toEqual(SHARED_MODULE_SHA256);
  });

  it('the pin covers the rule modules and deliberately not the baseline', () => {
    expect(Object.keys(SHARED_MODULE_SHA256).sort()).toEqual(['dependencyAudit.mjs', 'vulnerabilityPolicy.mjs']);
    expect(Object.keys(SHARED_MODULE_SHA256)).not.toContain('dependencyVulnerabilityBaseline.json');
  });

  it('★ the hash really discriminates — a one-byte change would fail', () => {
    expect(sha256(`${read(POLICY_FILE)} `)).not.toBe(SHARED_MODULE_SHA256['vulnerabilityPolicy.mjs']);
  });
});

// ═══════════════════════════════════════════════════════════════════════════════════════════════
describe('★ 5 · THE REAL COMMITTED BASELINE — not a reconstruction of it', () => {
  const baseline = () => JSON.parse(read(BASELINE_FILE));

  it('★ the committed baseline file passes the real validator', () => {
    expect(validateBaseline(baseline())).toEqual([]);
  });

  it('★ it contains no CRITICAL exception, and could not', () => {
    for (const e of baseline().exceptions) expect(e.severity).not.toBe('critical');
    expect(BASELINEABLE_SEVERITIES).not.toContain('critical');
  });

  it('every exception names an advisory, a reason, a follow-up and a review date', () => {
    for (const e of baseline().exceptions) {
      expect(e.advisory).toMatch(/^(GHSA|CVE)-/);
      expect(e.reason.length).toBeGreaterThan(60);
      expect(e.followUp.length).toBeGreaterThan(10);
      expect(e.reviewBy).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    }
  });

  it('★ no exception is a wildcard or a whole-severity suppression', () => {
    for (const e of baseline().exceptions) {
      expect(e.advisory).not.toContain('*');
      expect(e.package).not.toContain('*');
    }
  });

  it('the baseline suppresses a bounded number of advisories, not an open set', () => {
    expect(baseline().exceptions.length).toBeGreaterThan(0);
    expect(baseline().exceptions.length).toBeLessThanOrEqual(25);
  });
});

// ═══════════════════════════════════════════════════════════════════════════════════════════════
describe('★ 6 · the audit is not stateful', () => {
  it('★ running every rule twice in one process gives identical results', () => {
    const snapshot = () =>
      JSON.stringify({
        workflow: sha256(workflowCode()),
        instrument: sha256(instrumentCode()),
        baseline: validateBaseline(JSON.parse(read(BASELINE_FILE))),
        stripped: stripYamlComments(read(WORKFLOW)).length,
      });
    expect(snapshot()).toBe(snapshot());
  });

  it('★ a global-flagged matcher cannot silently halve a count here', () => {
    const uses = () => (workflowCode().match(/uses:\s*\S+/g) ?? []).length;
    expect(uses()).toBe(uses());
    expect(uses()).toBeGreaterThan(0);
  });
});
