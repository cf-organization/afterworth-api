/**
 * DEPENDENCY VULNERABILITY SCAN — the runner.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ THIS FILE IS BYTE-IDENTICAL IN afterworth-api AND afterworth-mobile, AND THAT IS ASSERTED.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 *   node scripts/security/dependencyAudit.mjs
 *
 * ★ IT SCANS. IT NEVER REMEDIATES.
 *
 * There is no `--fix` anywhere in this file and there never may be. `npm audit fix` rewrites
 * `package.json` and the lockfile, which would make a security gate a thing that silently changes
 * what the application ships — the one outcome that turns a scanner into a supply-chain risk of its
 * own. The gate's whole authority comes from being unable to alter the graph it measures.
 * `dependencySecurityInstrument.test.ts` asserts the absence of every remediating form.
 *
 * ★ IT AUDITS THE INSTALLED TREE, NOT `--package-lock-only`, AND THAT WAS MEASURED.
 *
 * The obvious choice is `npm audit --package-lock-only`: no install, nothing can possibly mutate.
 * It was measured against this repository's mobile graph and it UNDER-REPORTS — 33 entries against
 * the installed tree's 39, missing six packages including two DIRECT dependencies
 * (`expo-file-system`, `expo-font`), and it is internally inconsistent besides (see below). The ideal tree it reconstructs is not the tree `npm ci`
 * installs, and a scanner that inspects a tree nobody ships is the vacuous-audit failure mode with
 * extra steps. So CI runs `npm ci` — the frozen install, which fails rather than resolving anything
 * the lockfile does not already pin — and audits what that produced. The lockfile remains the
 * resolution authority; the installed tree is how that authority is observed.
 *
 * ★ IT RUNS TWO SCANS AND HIDES NEITHER.
 *
 * Build and test tooling is an execution surface: a compromised transform runs on every developer's
 * machine and in CI, with a checkout and a registry token in reach. So the default is to scan
 * everything the repository committed, and the runtime-only view is reported ALONGSIDE it rather
 * than instead of it.
 *
 * On the mobile graph, measured: runtime-only is currently a strict subset of all-dependencies —
 * 36 entries of 39, the three extra being @config-plugins/detox, @expo/ngrok and
 * expo-build-properties. That is a property of today's graph, not a guarantee, so the gate is the
 * UNION of both scopes rather than something that relies on the subset relation holding.
 *
 * It does NOT hold under `--package-lock-only`, which is a further reason that mode is not used
 * here: in lock-only mode the runtime-only scan surfaces FIVE entries the all-dependency scan of
 * the same lockfile misses. A mode in which omitting dependencies finds more of them is not a
 * sound basis for a security decision.
 */
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  EXIT_CODE,
  FAILING_SEVERITIES,
  OUTCOME,
  classifyReport,
  exitCodeFor,
  parseAuditReport,
  summarize,
} from './vulnerabilityPolicy.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..', '..');
const BASELINE_PATH = join(HERE, 'dependencyVulnerabilityBaseline.json');

/**
 * The two scopes, and the argv for each. `--json` is machine output; `--audit-level` is deliberately
 * absent, because the threshold is this repository's policy and not a flag npm gets to define.
 */
const SCOPES = Object.freeze([
  { name: 'all-dependencies', args: ['audit', '--json'] },
  { name: 'runtime-only', args: ['audit', '--json', '--omit=dev'] },
]);

/**
 * ★ WORST-FIRST PRECEDENCE. An instrument problem outranks a finding, because it invalidates the
 * finding: if one scope could not be read, the other scope's clean result says nothing about it.
 */
const OUTCOME_PRECEDENCE = Object.freeze([
  OUTCOME.POLICY_INVALID,
  OUTCOME.SCANNER_OUTPUT_INVALID,
  OUTCOME.SCANNER_UNAVAILABLE,
  OUTCOME.VULNERABILITIES_FOUND,
  OUTCOME.SCAN_CLEAN,
]);

export function worstOutcome(outcomes) {
  for (const o of OUTCOME_PRECEDENCE) if (outcomes.includes(o)) return o;
  // An outcome outside the closed union is not a pass.
  return OUTCOME.SCANNER_OUTPUT_INVALID;
}

function runScope(scope, cwd) {
  // shell: false — no interpolation, nothing a package name could inject into.
  const res = spawnSync('npm', scope.args, {
    cwd,
    encoding: 'utf8',
    shell: false,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, NPM_CONFIG_FUND: 'false', NPM_CONFIG_AUDIT_LEVEL: '' },
  });
  return parseAuditReport({
    stdout: res.stdout,
    stderr: res.stderr,
    exitCode: res.status,
    spawnError: res.error,
  });
}

function loadBaseline() {
  try {
    return { baseline: JSON.parse(readFileSync(BASELINE_PATH, 'utf8')) };
  } catch (e) {
    return { error: `baseline could not be read: ${String(e?.message ?? e)}` };
  }
}

function describeFinding(f) {
  const where = f.direct ? 'direct' : 'transitive';
  const fix = f.fixAvailable === true ? 'fix available' : f.fixAvailable ? 'fix available (breaking)' : 'no fix available';
  const path = f.nodes.length ? ` · ${f.nodes.slice(0, 3).join(', ')}${f.nodes.length > 3 ? ` (+${f.nodes.length - 3} more)` : ''}` : '';
  return `${String(f.severity).toUpperCase().padEnd(8)} ${f.advisory ?? '(no advisory id)'} · ${f.package}${f.range ? `@${f.range}` : ''} · ${where} · ${fix}${path}\n           ${f.title}${f.url ? `\n           ${f.url}` : ''}`;
}

export function report(scopeResults, { now }) {
  const out = [];
  out.push('═══ DEPENDENCY VULNERABILITY SCAN ═══');
  out.push(`policy: FAIL at ${FAILING_SEVERITIES.join(' + ')} · everything below is REPORTED · unknown severity FAILS`);
  out.push(`no remediation is performed: this scan cannot modify package.json or the lockfile`);
  out.push('');

  for (const { scope, parsed, classified } of scopeResults) {
    out.push(`── scope: ${scope} ──`);
    if (!classified) {
      out.push(...summarize({ ...parsed }, { scope }));
      if (parsed.diagnostic) out.push(`  scanner diagnostic (redacted): ${parsed.diagnostic.split('\n').slice(0, 5).join(' / ')}`);
      out.push('');
      continue;
    }
    const c = classified.counts;
    out.push(
      `counts — critical ${c.critical} · high ${c.high} · moderate ${c.moderate} · low ${c.low} · info ${c.info} · unknown ${c.unknown}`
    );
    out.push(
      `distinct advisories ${classified.findings.length} (direct ${classified.findings.filter((f) => f.direct).length} · transitive ${classified.findings.filter((f) => !f.direct).length}) · affected dependents ${classified.dependents.length}`
    );
    if (!classified.dependentsResolve) {
      out.push('  ⚠ some dependent entries do not resolve to a leaf advisory in this report — treat the finding list as incomplete');
    }
    out.push(...summarize(classified, { scope }));

    if (classified.failing.length) {
      out.push('  FAILING:');
      for (const f of classified.failing) out.push(`    ${describeFinding(f)}`);
    }
    if (classified.baselined.length) {
      out.push('  BASELINED (explicit, expiring exceptions — NOT fixed):');
      for (const f of classified.baselined) {
        out.push(`    ${String(f.severity).toUpperCase()} ${f.advisory} · ${f.package} · review by ${f.reviewBy}`);
        out.push(`           reason: ${f.reason}`);
        out.push(`           follow-up: ${f.followUp}`);
      }
    }
    if (classified.reporting.length) {
      out.push('  REPORT-ONLY (below the failing threshold — tracked, not suppressed):');
      for (const f of classified.reporting) out.push(`    ${describeFinding(f)}`);
    }
    out.push('');
  }

  /**
   * ★ STALENESS IS A PROPERTY OF THE UNION, NOT OF A SCOPE.
   *
   * Computed per-scope this reported the API's one baseline entry as stale, because the runtime-only
   * scan legitimately does not see a devDependency advisory. An exception is stale only when NO scope
   * matched it — otherwise the report tells a reviewer to delete a row that is actively suppressing a
   * live finding, which is the most damaging possible thing for this file to be wrong about.
   */
  const matched = new Set(
    scopeResults.flatMap((r) => [...(r.classified?.baselined ?? []), ...(r.classified?.expired ?? [])])
      .map((f) => `${f.advisory}::${f.package}`)
  );
  const declared = scopeResults.find((r) => r.classified)?.classified?.unusedBaseline ?? [];
  const stale = declared.filter((e) => !matched.has(`${e.advisory}::${e.package}`));
  if (stale.length) {
    out.push('── stale baseline entries (matched by NO scope — remove them) ──');
    for (const e of stale) out.push(`  ${e.advisory} · ${e.package}`);
    out.push('');
  }

  out.push(`scanned at ${now.toISOString()}`);
  return out;
}

export function main({ cwd = ROOT, now = new Date(), log = console.log } = {}) {
  const { baseline, error } = loadBaseline();
  if (error) {
    for (const l of summarize({ outcome: OUTCOME.POLICY_INVALID, baselineProblems: [error] })) log(l);
    return EXIT_CODE.POLICY_INVALID;
  }

  const scopeResults = SCOPES.map((scope) => {
    const parsed = runScope(scope, cwd);
    if (parsed.outcome) return { scope: scope.name, parsed, classified: null };
    return {
      scope: scope.name,
      parsed,
      classified: classifyReport({ report: parsed.report, baseline, now }),
    };
  });

  for (const line of report(scopeResults, { now })) log(line);

  const outcome = worstOutcome(scopeResults.map((r) => r.classified?.outcome ?? r.parsed.outcome));
  const code = exitCodeFor(outcome);
  log(`OUTCOME: ${outcome} (exit ${code})`);
  return code;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  process.exit(main());
}
