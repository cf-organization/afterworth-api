#!/usr/bin/env node
/**
 * PHASE 11-OB PREP · THE BRANCH B SENTINEL (read-only CLI).
 *
 * Reports on two worlds in one pass:
 *
 *   THE STANDING WORLD  — the AW_FIDUCIARY fixture, live today. Delegated in full to
 *                         `afterworth-mobile/scripts/fiduciaryFixtureSentinel.mjs`, which owns those
 *                         assertions. Re-implementing them here would fork a proven instrument.
 *   THE BRANCH B WORLD  — absent until the drill starts, and reported as ABSENT rather than FAILED.
 *
 * ★ THE DELEGATE'S EXIT CODE IS READ FROM THE SPAWN RESULT, NOT FROM A PIPELINE. A backgrounded
 * `cmd > log; echo $?` reports the status of whatever ran last — this repository has already been
 * bitten by a Gradle build reported as exit 0 when it had failed in one second. `spawnSync().status`
 * is the delegate's own code, and a null status (killed by signal) is UNVERIFIABLE, never a pass.
 *
 * ★ THE TALLY IS DERIVED FROM THE DELEGATE'S OWN OUTPUT and its denominator is asserted non-zero.
 * A sentinel that checked nothing prints no ✗ and would otherwise read as intact.
 *
 * ★ NOTHING HERE MUTATES. It spawns one read-only script and, when a Branch B estate is named,
 * performs read-only projections through the operator door. `test/noProductionMutation.test.ts`
 * pins the RPC set.
 *
 * Usage:  node scripts/branchBSentinel.mjs [--mobile-dir=<path>] [--json]
 * Exit:   0 intact, or the expected BRANCH_B_FIXTURE_ABSENT · 1 drifted · 2 could not verify
 */
import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  BRANCH_B_PROPERTIES,
  SENTINEL,
  classifyBranchBSentinel,
  sentinelExitCode,
} from './lib/branchBSentinel.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const argOf = (name) => {
  const hit = process.argv.find((a) => a.startsWith(`--${name}=`));
  return hit ? hit.slice(name.length + 3) : null;
};
const JSON_OUT = process.argv.includes('--json');
const MOBILE_DIR = resolve(ROOT, argOf('mobile-dir') ?? '../afterworth-mobile');
const DELEGATE = join(MOBILE_DIR, 'scripts/fiduciaryFixtureSentinel.mjs');

/**
 * ★ BRANCH B DOES NOT EXIST, AND THIS CONSTANT IS WHERE THAT FACT LIVES.
 *
 * It stays `null` until a Branch B estate is genuinely provisioned by an authorized drill. It is not
 * a CLI flag: an estate uuid supplied on a command line would let this read-only sentinel be pointed
 * at an arbitrary estate, and "the sentinel says the Branch B estate is fine" would then mean
 * whichever estate the last operator typed.
 */
const BRANCH_B_ESTATE = null;

function runStandingFixture() {
  if (!existsSync(DELEGATE)) {
    return { error: `delegate not found at ${DELEGATE}` };
  }
  const r = spawnSync(process.execPath, [DELEGATE], {
    cwd: MOBILE_DIR,
    encoding: 'utf8',
    timeout: 120_000,
  });
  if (r.error) return { error: `delegate failed to start: ${r.error.code ?? r.error.message}` };
  // ★ A signal kill leaves status null. That is not a zero.
  if (r.status === null) return { error: `delegate terminated by signal ${r.signal}` };
  const out = `${r.stdout ?? ''}`;
  const passed = (out.match(/✓/g) ?? []).length;
  const failed = (out.match(/✗/g) ?? []).length;
  return { tally: `${passed}/${passed + failed}`, exitCode: r.status };
}

const standing = runStandingFixture();
if (standing.error) {
  console.error(`✗ COULD NOT VERIFY — ${standing.error}`);
  process.exit(2);
}

const result = classifyBranchBSentinel({ standingFixture: standing, branchB: BRANCH_B_ESTATE });

if (JSON_OUT) {
  console.log(
    JSON.stringify({
      ...result,
      standing_fixture_tally: standing.tally,
      standing_fixture_exit: standing.exitCode,
      branch_b_properties_when_present: BRANCH_B_PROPERTIES,
    })
  );
} else {
  console.log('BRANCH B SENTINEL (read-only)\n');
  console.log(`  standing fixture   ${standing.tally}  exit ${standing.exitCode}`);
  console.log(`  branch B estate    ${BRANCH_B_ESTATE ?? 'not provisioned'}`);
  console.log(`\n  VERDICT            ${result.verdict}`);
  for (const f of result.findings) console.log(`    · ${f.code}: ${f.detail}`);
  if (result.verdict === SENTINEL.ABSENT) {
    console.log('\n  ★ ABSENT IS THE EXPECTED ANSWER until Branch B is authorized and started.');
    console.log('    When it exists, these properties are checked:');
    for (const p of BRANCH_B_PROPERTIES) console.log(`      - ${p}`);
  }
}

process.exit(sentinelExitCode(result.verdict));
