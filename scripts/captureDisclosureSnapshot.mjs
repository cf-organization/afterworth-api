#!/usr/bin/env node
/**
 * PHASE 11-Q · THE CANONICAL DISCLOSURE SNAPSHOT COLLECTOR — READ ONLY.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ THE PRE SNAPSHOT IS MANDATORY BEFORE THE IRREVERSIBLE BOUNDARY, AND THAT IS THE WHOLE POINT.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * `evaluateDisclosureEquivalence` needs a pre-image that only exists while the lifecycle is
 * `challenge_window`. Branch B reached its release having captured two of four documents, so the
 * canonical rule could never be evaluated for it — and once the estate was `released` the window
 * was closed for good.
 *
 * ★ SO RUNNING THIS AFTER RELEASE REFUSES, LOUDLY, WITH `PRE_RELEASE_OBSERVATION_WINDOW_CLOSED`.
 *   That refusal is the single most important behaviour in this file. The temptation it exists to
 *   defeat is the obvious one: a drill finishes, someone notices the pre-image is missing, and
 *   reconstructs a plausible one from the post state. A reconstructed pre-image agrees with whatever
 *   the release did, so the oracle would confirm any release, including a leaking one.
 *
 * ★ THE UNIVERSE IS ENUMERATED, NEVER ASSUMED. The owner can select every document on the estate;
 *   a non-owner sees only what `can_access_document` admits (`documents_read`, migration 0002). So
 *   the owner's SELECT IS the universe and the fiduciary's SELECT IS the disclosure surface. The
 *   four Branch B documents are NOT hardcoded — a future drill with eleven documents captures
 *   eleven, and completeness is asserted against what the owner can actually see.
 *
 * ★ BOTH ACCESS SIGNALS ARE RECORDED. `can_access_document` is the policy gate; the RLS-filtered
 *   read is the product path. They answer the same question by different mechanisms, and the
 *   verifier refuses when they disagree rather than picking the nicer one.
 *
 * ★ NOTHING HERE MUTATES. One `stable` RPC and PostgREST SELECTs under existing RLS.
 *   `authorize_release` is not named anywhere in this file.
 *
 * Usage:
 *   node scripts/captureDisclosureSnapshot.mjs --phase=pre|post --case=<uuid> --grant=<uuid> \
 *        --sanctioned=<uuid[,uuid]> --out=<file.json> [--env-dir=<path to afterworth-mobile>]
 *
 * Exit: 0 captured · 1 refused (wrong lifecycle, incomplete universe) · 2 could not verify
 */
import { writeFileSync } from 'node:fs';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  SNAPSHOT_SCHEMA_VERSION,
  SNAPSHOT_PHASE,
  PHASE_LIFECYCLE,
  decodeSnapshot,
  snapshotDigest,
} from './lib/disclosureSnapshot.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const argOf = (n) => {
  const hit = process.argv.find((a) => a.startsWith(`--${n}=`));
  return hit ? hit.slice(n.length + 3) : null;
};
const die = (code, msg) => { console.error(msg); process.exit(code); };

const PHASE_ARG = (argOf('phase') ?? '').toLowerCase();
const PHASE = PHASE_ARG === 'pre' ? SNAPSHOT_PHASE.PRE_RELEASE
  : PHASE_ARG === 'post' ? SNAPSHOT_PHASE.POST_RELEASE : null;
if (PHASE === null) die(2, 'COULD NOT VERIFY — --phase=pre|post is required.');

const CASE_ID = argOf('case');
const GRANT_ID = argOf('grant');
const OUT = argOf('out');
const SANCTIONED = (argOf('sanctioned') ?? '').split(',').map((s) => s.trim()).filter(Boolean);
const ENV_DIR = resolve(ROOT, argOf('env-dir') ?? '../afterworth-mobile');
if (!CASE_ID) die(2, 'COULD NOT VERIFY — --case=<uuid> is required.');
if (!GRANT_ID) die(2, 'COULD NOT VERIFY — --grant=<uuid> is required.');
if (!OUT) die(2, 'COULD NOT VERIFY — --out=<file.json> is required.');
if (SANCTIONED.length === 0) die(2, 'COULD NOT VERIFY — --sanctioned=<uuid[,uuid]> is required.');

const parseEnv = (p) => {
  const out = new Map();
  if (!existsSync(p)) return out;
  for (const line of readFileSync(p, 'utf8').split('\n')) {
    const t = line.trim();
    if (!t || t.startsWith('#')) continue;
    const i = t.indexOf('=');
    if (i > 0) out.set(t.slice(0, i).trim(), t.slice(i + 1).trim().replace(/^["']|["']$/g, ''));
  }
  return out;
};

const app = parseEnv(join(ENV_DIR, '.env'));
const store = parseEnv(join(ENV_DIR, '.env.test'));
const base = app.get('EXPO_PUBLIC_SUPABASE_URL');
const pub = app.get('EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY');
if (!base || !pub) die(2, 'COULD NOT VERIFY — supabase url/publishable key absent.');
if (pub.startsWith('sb_secret')) die(2, 'COULD NOT VERIFY — refusing a secret key; this collector is never service_role.');

const req = async (path, init = {}, bearer = null) => {
  const r = await fetch(`${base}${path}`, {
    ...init,
    headers: { apikey: pub, 'content-type': 'application/json', ...(bearer ? { Authorization: `Bearer ${bearer}` } : {}), ...(init.headers ?? {}) },
  });
  const txt = await r.text();
  let body = null;
  try { body = txt ? JSON.parse(txt) : null; } catch { body = txt; }
  return { ok: r.ok, status: r.status, body };
};
const rpc = (tok, fn, args = {}) => req(`/rest/v1/rpc/${fn}`, { method: 'POST', body: JSON.stringify(args) }, tok);

const signIn = async (prefix) => {
  const email = store.get(`${prefix}_EMAIL`);
  const password = store.get(`${prefix}_PASSWORD`);
  if (!email || !password) die(2, `COULD NOT VERIFY — ${prefix}_* incomplete in the credential store.`);
  const pw = await req('/auth/v1/token?grant_type=password', { method: 'POST', body: JSON.stringify({ email, password }) });
  if (!pw.ok) die(2, `COULD NOT VERIFY — ${prefix} sign-in failed (${pw.status}).`);
  return { token: pw.body.access_token, uid: JSON.parse(Buffer.from(pw.body.access_token.split('.')[1], 'base64').toString('utf8')).sub };
};

const OWNER_PREFIX = argOf('owner-persona') ?? 'AW_BRANCHB_OWNER';
const FID_PREFIX = argOf('fiduciary-persona') ?? 'AW_BRANCHB_FID';

const owner = await signIn(OWNER_PREFIX);
const fid = await signIn(FID_PREFIX);

/* ── 1 · THE CASE AND ITS LIFECYCLE ────────────────────────────────────────────────────────────── */
// Read through the fiduciary's own grant listing rather than an admin door: this collector needs no
// admin privilege, and an instrument that does not hold one cannot misuse one.
const grantRow = await req(`/rest/v1/document_grants?id=eq.${GRANT_ID}&select=*`, {}, owner);
if (!grantRow.ok || !Array.isArray(grantRow.body) || grantRow.body.length !== 1) {
  die(2, `COULD NOT VERIFY — the pinned grant ${GRANT_ID} is not readable as the owner (${grantRow.status}).`);
}
const grant = grantRow.body[0];
const ESTATE_ID = grant.estate_id;

const lifeRow = await req(`/rest/v1/estate_lifecycle?estate_id=eq.${ESTATE_ID}&select=state,released_at`, {}, owner);
if (!lifeRow.ok || !Array.isArray(lifeRow.body) || lifeRow.body.length !== 1) {
  die(2, `COULD NOT VERIFY — the estate lifecycle is not readable (${lifeRow.status}).`);
}
const lifecycle = lifeRow.body[0].state;

/* ── 2 · THE WINDOW GATE — THE REFUSAL THIS FILE EXISTS FOR ────────────────────────────────────── */
const requiredLifecycle = PHASE_LIFECYCLE[PHASE];
if (lifecycle !== requiredLifecycle) {
  if (PHASE === SNAPSHOT_PHASE.PRE_RELEASE) {
    console.error('REFUSED — PRE_RELEASE_OBSERVATION_WINDOW_CLOSED');
    console.error(`  the estate lifecycle is '${lifecycle}', not '${requiredLifecycle}'.`);
    console.error('  A pre-release disclosure image can only be taken while the challenge window is open.');
    console.error('  It CANNOT be reconstructed from the post-release state: a reconstructed pre-image');
    console.error('  agrees with whatever the release did, so the oracle would confirm any release,');
    console.error('  including a leaking one. This is the Branch B gap, and it is permanent for that drill.');
  } else {
    console.error('REFUSED — POST snapshot requested but the estate is not released.');
    console.error(`  lifecycle='${lifecycle}', expected '${requiredLifecycle}'.`);
  }
  process.exit(1);
}

/* ── 3 · THE UNIVERSE, ENUMERATED BY THE OWNER ─────────────────────────────────────────────────── */
const uni = await req(`/rest/v1/documents?estate_id=eq.${ESTATE_ID}&select=id,sensitivity&order=created_at.asc`, {}, owner);
if (!uni.ok || !Array.isArray(uni.body) || uni.body.length === 0) {
  die(2, `COULD NOT VERIFY — owner document enumeration failed or returned nothing (${uni.status}).`);
}
const universeIds = uni.body.map((d) => d.id);
const sensitivityById = new Map(uni.body.map((d) => [d.id, d.sensitivity]));

for (const s of SANCTIONED) {
  if (!sensitivityById.has(s)) die(1, `REFUSED — sanctioned document ${s} is not in the observed universe.`);
}

/** Observe one actor's view of every document: the policy gate AND the product read path. */
async function observe(actorToken) {
  const seen = await req(`/rest/v1/documents?estate_id=eq.${ESTATE_ID}&select=id`, {}, actorToken);
  if (!seen.ok || !Array.isArray(seen.body)) die(2, `COULD NOT VERIFY — actor document read failed (${seen.status}).`);
  const rlsVisible = new Set(seen.body.map((d) => d.id));
  const rows = [];
  for (const id of universeIds) {
    const g = await rpc(actorToken, 'can_access_document', { p_document_id: id });
    if (!g.ok || typeof g.body !== 'boolean') {
      die(2, `COULD NOT VERIFY — can_access_document(${id}) did not return a boolean (${g.status}).`);
    }
    rows.push({
      document_id: id,
      sensitivity: sensitivityById.get(id),
      can_access_document: g.body,
      rls_visible: rlsVisible.has(id),
    });
  }
  return rows;
}

const documents = await observe(fid.token);
const ownerDocuments = await observe(owner.token);

/* ── 4 · BUILD, VALIDATE, EMIT ─────────────────────────────────────────────────────────────────── */
const snapshot = {
  schema_version: SNAPSHOT_SCHEMA_VERSION,
  phase: PHASE,
  estate_id: ESTATE_ID,
  case_id: CASE_ID,
  lifecycle,
  observed_at_utc: new Date().toISOString(),
  actor_uid: fid.uid,
  actor_role: 'fiduciary',
  owner_uid: owner.uid,
  sanctioned_document_ids: SANCTIONED,
  expected_universe_ids: universeIds,
  documents,
  owner_documents: ownerDocuments,
  grant,
  provenance: `captureDisclosureSnapshot.mjs --phase=${PHASE_ARG} (owner-enumerated universe, ${universeIds.length} document(s))`,
};

const decoded = decodeSnapshot(snapshot);
if (!decoded.ok) {
  console.error('COULD NOT VERIFY — the collected snapshot failed its own strict decode:');
  for (const e of decoded.errors) console.error(`  - ${e}`);
  process.exit(2);
}

writeFileSync(OUT, `${JSON.stringify(snapshot, null, 2)}\n`);
const digest = snapshotDigest(snapshot);

console.log(`CANONICAL DISCLOSURE SNAPSHOT — ${PHASE}`);
console.log(`  estate            ${ESTATE_ID}`);
console.log(`  case              ${CASE_ID}`);
console.log(`  lifecycle         ${lifecycle}`);
console.log(`  universe          ${universeIds.length} document(s), owner-enumerated`);
console.log(`  sanctioned        ${SANCTIONED.length}`);
console.log(`  fiduciary sees    ${documents.filter((d) => d.can_access_document || d.rls_visible).length}`);
console.log(`  artifact          ${OUT}`);
console.log(`  canonical digest  ${digest}`);
console.log('\n  ★ Record this digest. The post-release verifier pins it, so a snapshot edited');
console.log('    between the two halves of the drill refuses instead of being evaluated.');
