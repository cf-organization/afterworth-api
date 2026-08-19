#!/usr/bin/env node
/**
 * PHASE 11-P.5 · BRANCH B SESSION-2 PREFLIGHT — READ ONLY.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ WHAT THIS PROVES, AND WHAT IT DELIBERATELY DOES NOT.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * PROVES: the frozen checkpoint is byte-intact and bound to the addendum; the addendum decodes
 * strictly; and each of the three Session-2 provenance facts, collected FROM ITS DECLARED SOURCE,
 * matches the reviewed revision.
 *
 * DOES NOT PROVE: that Branch B may resume. The production-state gates — lifecycle, case status,
 * halt, T2, reviewer seats, sentinel, standing fixture, drift, Phase D — need a live authenticated
 * read that belongs to the Session-2 operator. Without it they are UNOBSERVED, and an unobserved
 * fact is a FAILED gate here, never a skipped one.
 *
 * ★ SO A GREEN PROVENANCE RESULT BEFORE THE CLOCK IS THE POINT. It shows the remediation is ready
 *   without opening Session 2, and it cannot be mistaken for release clearance because the full
 *   verdict is printed alongside it and refuses.
 *
 * ★ NOTHING HERE MUTATES. `gh api` GETs and `git rev-parse` only. It never calls `authorize_release`,
 *   never challenges or halts, never drains, never reissues, and never touches AW_ADMIN_TEST_B.
 *
 * Usage:
 *   node scripts/branchBSession2Preflight.mjs                       provenance only (default)
 *   node scripts/branchBSession2Preflight.mjs --observed=<file.json> full resume evaluation
 *   node scripts/branchBSession2Preflight.mjs --now=<iso>            override the injected clock
 *
 * Exit: 0 provenance green · 1 a provenance gate refused · 2 could not verify
 */
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { decodeCheckpoint, evaluateResume } from './lib/branchBCheckpoint.mjs';
import {
  decodeProvenanceAddendum,
  evaluateSession2Resume,
  sha256Bytes,
  SUPERSEDED_LEGACY_GATE_IDS,
} from './lib/branchBProvenance.mjs';
import { collectSession2Provenance } from './lib/branchBObservation.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const CHECKPOINT_PATH = path.join(ROOT, 'docs/phase11p-branchb-session1-checkpoint.json');
const ADDENDUM_PATH = path.join(ROOT, 'docs/phase11p5-branchb-session15-provenance.json');

const arg = (name) => {
  const hit = process.argv.slice(2).find((a) => a.startsWith(`--${name}=`));
  return hit === undefined ? null : hit.slice(name.length + 3);
};

const line = (pass, id, detail) => `  ${pass ? 'PASS  ' : 'REFUSE'}  ${id.padEnd(38)}${detail ?? ''}`;

function main() {
  console.log('BRANCH B SESSION-2 PREFLIGHT — READ ONLY');
  console.log('='.repeat(96));

  let checkpointBytes;
  try {
    checkpointBytes = readFileSync(CHECKPOINT_PATH);
  } catch (e) {
    console.log(`COULD NOT VERIFY: frozen checkpoint unreadable — ${e.message}`);
    return 2;
  }
  const cp = decodeCheckpoint(JSON.parse(checkpointBytes.toString('utf8')));
  if (!cp.ok) {
    console.log('COULD NOT VERIFY: frozen checkpoint failed strict decode:');
    for (const e of cp.errors) console.log(`  - ${e}`);
    return 2;
  }
  console.log(`frozen checkpoint     ${CHECKPOINT_PATH.replace(ROOT + '/', '')}`);
  console.log(`  sha256              ${sha256Bytes(checkpointBytes)}`);
  console.log(`  strict decode       ok`);

  let addendumRaw;
  try {
    addendumRaw = JSON.parse(readFileSync(ADDENDUM_PATH, 'utf8'));
  } catch (e) {
    console.log(`COULD NOT VERIFY: provenance addendum unreadable — ${e.message}`);
    return 2;
  }
  const add = decodeProvenanceAddendum(addendumRaw);
  if (!add.ok) {
    console.log('COULD NOT VERIFY: addendum failed strict decode:');
    for (const e of add.errors) console.log(`  - ${e}`);
    return 2;
  }
  console.log(`addendum              ${ADDENDUM_PATH.replace(ROOT + '/', '')}`);
  console.log(`  operator ruling     ${add.addendum.operator_ruling}`);
  console.log(`  legacy gates        ${add.addendum.legacy_sha_gate_status}: ${SUPERSEDED_LEGACY_GATE_IDS.join(', ')}`);

  console.log('\nCOLLECTING PROVENANCE FROM DECLARED SOURCES (read-only)');
  const observedProvenance = collectSession2Provenance({ addendum: add.addendum });
  for (const [name, expected] of Object.entries(add.addendum.session2_provenance)) {
    const o = observedProvenance[name];
    console.log(`  ${name}`);
    console.log(`     expected  ${expected.source_kind.padEnd(22)}${expected.sha}`);
    console.log(
      `     observed  ${(o?.source_kind ?? 'UNAVAILABLE').padEnd(22)}${o?.sha ?? '-'}`
      + (o?.state ? `  state=${o.state}` : '')
      + (o?.environment ? ` env=${o.environment}` : '')
    );
  }

  const observedPath = arg('observed');
  let observed = {};
  if (observedPath !== null) {
    try {
      observed = JSON.parse(readFileSync(observedPath, 'utf8'));
    } catch (e) {
      console.log(`COULD NOT VERIFY: --observed unreadable — ${e.message}`);
      return 2;
    }
  }

  const now = arg('now') ?? new Date().toISOString();
  const r = evaluateSession2Resume({
    legacyEvaluateResume: evaluateResume,
    checkpoint: cp.checkpoint,
    checkpointBytes,
    addendumRaw,
    observed,
    observedProvenance,
    now,
  });

  // ★ THE INSTRUMENT REVISION IS SCORED SEPARATELY FROM SOURCE PROVENANCE, ON PURPOSE. They are
  //   different facts (Stage 19), and folding the unpinned instrument into the provenance verdict
  //   would report the three reviewed revisions as REFUSED when all three agree exactly.
  const provenanceIds = new Set([
    'addendum_decoded',
    'checkpoint_hash_bound',
    'supersession_targets_exist',
    ...Object.keys(add.addendum.session2_provenance).map((n) => `provenance_${n}`),
  ]);
  const provenanceGates = r.gates.filter((g) => provenanceIds.has(g.id));
  const instrumentIds = new Set(['resume_instrument_pinned', 'resume_instrument_not_stale']);
  const instrumentGates = r.gates.filter((g) => instrumentIds.has(g.id));
  const stateGates = r.gates.filter((g) => !provenanceIds.has(g.id) && !instrumentIds.has(g.id));

  console.log('\nPROVENANCE GATES');
  for (const g of provenanceGates) console.log(line(g.pass, g.id, g.detail));

  console.log('\nRESUME INSTRUMENT (Stage 19 — a separate fact, never folded into source provenance)');
  for (const g of instrumentGates) console.log(line(g.pass, g.id, g.detail));

  console.log('\nPRODUCTION-STATE GATES (legacy, retained verbatim)');
  if (observedPath === null) {
    console.log('  not evaluated in provenance-only mode — supply --observed=<file.json>');
    console.log('  an unobserved fact is a FAILED gate, never a skipped one');
  } else {
    for (const g of stateGates) console.log(line(g.pass, g.id, g.detail));
  }

  console.log('\nSUPERSESSION');
  console.log(`  retained legacy gates   ${r.retained_legacy_gates.length}`);
  console.log(`  superseded legacy gates ${r.superseded_legacy_gates.join(', ') || '(none)'}`);
  console.log(`  ${r.two_person_control}`);

  // ★ The provenance verdict is reported SEPARATELY from the resume verdict, and neither is allowed
  //   to stand in for the other. Collapsing them is how "the instrument is ready" would come to read
  //   as "the drill may proceed".
  const provenanceFailed = provenanceGates.filter((g) => !g.pass).map((g) => g.id);
  console.log('\n' + '='.repeat(96));
  console.log(`PROVENANCE VERDICT : ${provenanceFailed.length === 0 ? 'GREEN' : 'REFUSED'}`
    + (provenanceFailed.length ? `  failed=[${provenanceFailed.join(', ')}]` : ''));
  const instrumentOk = instrumentGates.every((g) => g.pass);
  console.log(`RESUME INSTRUMENT  : ${instrumentOk ? 'PINNED AND CURRENT' : 'NOT READY'}`
    + (instrumentOk ? '' : ` — ${instrumentGates.filter((g) => !g.pass).map((g) => g.id).join(', ')}`));
  console.log(`SESSION-2 VERDICT  : ${r.decision}`
    + (observedPath === null ? '   (production state unobserved — refusal expected)' : ''));
  console.log('RELEASE            : NOT AUTHORIZED BY THIS SCRIPT. It cannot authorize one.');
  return provenanceFailed.length === 0 ? 0 : 1;
}

process.exit(main());
