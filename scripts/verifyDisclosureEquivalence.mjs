#!/usr/bin/env node
/**
 * PHASE 11-Q · THE CANONICAL POST-RELEASE DISCLOSURE VERIFIER — READ ONLY.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ WHAT IT PROVES: that the release revealed EXACTLY the sanctioned payload and moved nothing else.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * It loads a PRE snapshot captured while the challenge window was open, pins its digest, and
 * compares it against a POST snapshot of the same drill through the untouched canonical oracle,
 * `evaluateDisclosureEquivalence`. The policy is not re-implemented here — a second copy of a
 * disclosure rule is the drift this repository has already shipped twice.
 *
 * ★ REFUSAL IS A FIRST-CLASS OUTCOME AND IS NEVER A FAIL. "This release was wrong" and "I cannot
 *   say whether this release was wrong" need different responses from an operator, so they get
 *   different verdicts and different exit codes. A missing or partial pre-image REFUSES; it does not
 *   fall back, infer, or reconstruct.
 *
 * ★ IT CANNOT RETROACTIVELY CLOSE THE BRANCH B GAP, AND MUST NOT APPEAR TO. Branch B has no
 *   complete pre-image and never will. Pointing this verifier at it returns REFUSE_INCOMPLETE_PRE,
 *   which is the honest answer and the one `docs/phase11p11-*` already records.
 *
 * ★ NOTHING HERE MUTATES. It reads two files and, when asked to collect the post half itself,
 *   shells out to the read-only collector. `authorize_release` is not named in this file.
 *
 * Usage:
 *   node scripts/verifyDisclosureEquivalence.mjs --pre=<pre.json> --post=<post.json> \
 *        [--expect-pre-digest=<sha256>] [--json]
 *
 * Exit: 0 equivalence held · 1 violated · 2 refused / could not verify
 */
import { readFileSync } from 'node:fs';
import {
  EQUIVALENCE,
  equivalenceExitCode,
  snapshotDigest,
  verifyDisclosureEquivalence,
} from './lib/disclosureSnapshot.mjs';

const argOf = (n) => {
  const hit = process.argv.find((a) => a.startsWith(`--${n}=`));
  return hit ? hit.slice(n.length + 3) : null;
};
const JSON_OUT = process.argv.includes('--json');

const PRE = argOf('pre');
const POST = argOf('post');
const EXPECT = argOf('expect-pre-digest');

if (!PRE || !POST) {
  console.error('COULD NOT VERIFY — --pre=<file.json> and --post=<file.json> are both required.');
  console.error('');
  console.error('  ★ There is no single-file mode, deliberately. A verifier that could run on the post');
  console.error('    state alone is a verifier that infers the pre-image, and an inferred pre-image');
  console.error('    agrees with whatever the release did.');
  process.exit(2);
}

const load = (p, label) => {
  try {
    return JSON.parse(readFileSync(p, 'utf8'));
  } catch (e) {
    console.error(`COULD NOT VERIFY — ${label} unreadable: ${e.message}`);
    process.exit(2);
  }
};

const pre = load(PRE, '--pre');
const post = load(POST, '--post');

const result = verifyDisclosureEquivalence({ pre, post, expectedPreDigest: EXPECT });

if (JSON_OUT) {
  console.log(JSON.stringify({
    ...result,
    pre_artifact: PRE,
    pre_digest: snapshotDigest(pre),
    post_artifact: POST,
    post_digest: snapshotDigest(post),
  }, null, 2));
} else {
  console.log('CANONICAL POST-RELEASE DISCLOSURE VERIFICATION');
  console.log('='.repeat(96));
  console.log(`  pre   ${PRE}`);
  console.log(`        sha256 ${snapshotDigest(pre)}`);
  console.log(`  post  ${POST}`);
  console.log(`        sha256 ${snapshotDigest(post)}`);
  if (result.oracle) {
    const w = result.oracle.discriminating_world ?? {};
    console.log(`\n  discriminating world  universe=${w.universe} sanctioned=${w.sanctioned} unrelated=${w.unrelated}`);
    console.log(`  oracle verdict        ${result.oracle.verdict}`);
  }
  if (result.findings.length === 0) {
    console.log('\n  no findings');
  } else {
    console.log('\n  FINDINGS');
    for (const f of result.findings) console.log(`    · ${f.code}: ${f.detail}`);
  }
  console.log('\n' + '='.repeat(96));
  console.log(`VERDICT : ${result.verdict}`);
  if (result.verdict === EQUIVALENCE.REFUSE_INCOMPLETE_PRE) {
    console.log('');
    console.log('  ★ REFUSED, NOT FAILED. This says nothing about whether the release was correct —');
    console.log('    it says the evidence needed to answer that question was never captured. The');
    console.log('    pre-image must be taken while the lifecycle is `challenge_window`, and it cannot');
    console.log('    be reconstructed afterwards. See docs/phase11q-disclosure-verification.md.');
  }
}

process.exit(equivalenceExitCode(result.verdict));
