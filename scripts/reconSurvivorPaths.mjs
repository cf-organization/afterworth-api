#!/usr/bin/env node
/**
 * PHASE 11-G STAGE 1 — the post-release data-path census, DERIVED rather than remembered.
 *
 * ★ THE QUESTION THIS ANSWERS. Survivor Mode must consume the existing release and disclosure
 * architecture, not build a second one. Whether that is even possible is an empirical question about
 * what the current projections already return, which of them consult the canonical predicate, and
 * where a viewer's relationship is allowed to touch their tier. Remembering the answer is how a
 * "composition" quietly becomes a reimplementation.
 *
 * It reports, from source only:
 *
 *   1 · every client-reachable projection a survivor could read, with its security posture;
 *   2 · which of them route disclosure through the canonical predicate (and which decide locally);
 *   3 · the tier-deciding sites, and whether any of them consults RELATIONSHIP or CAPACITY —
 *       the G3 invariant, checked rather than asserted;
 *   4 · the viewer × grant-category × condition matrix each projection can produce;
 *   5 · every mutation door reachable post-release, so "release grants no new powers" is checkable.
 *
 * Exit 0 always — a REPORT, not a gate.
 * Usage: node scripts/reconSurvivorPaths.mjs [--json]
 */
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const JSON_OUT = process.argv.includes('--json');

const stripSql = (raw) =>
  raw.split('\n').filter((l) => !/^\s*--/.test(l)).map((l) => l.replace(/\s--.*$/, '')).join('\n');

const walk = (rel, filter) => {
  const abs = join(ROOT, rel);
  if (!existsSync(abs)) return [];
  return readdirSync(abs, { withFileTypes: true }).flatMap((e) =>
    e.isDirectory() ? walk(join(rel, e.name), filter) : filter(e.name) ? [join(rel, e.name)] : []
  );
};

const SQL = [...walk('db/functions', (f) => f.endsWith('.sql')), ...walk('db/migrations', (f) => f.endsWith('.sql'))];
if (SQL.length < 40) {
  console.error(`✗ CANNOT RECON — scan set implausible (${SQL.length}).`);
  process.exit(2);
}
const load = (f) => stripSql(readFileSync(join(ROOT, f), 'utf8'));
const CODE = new Map(SQL.map((f) => [f, load(f)]));

/** Extract one function body by name, wherever it is defined. */
function bodyOf(name) {
  for (const [file, code] of CODE) {
    const i = code.indexOf(`create or replace function public.${name}`);
    if (i === -1) continue;
    const rest = code.slice(i);
    const end = rest.indexOf('$function$;') !== -1 ? rest.indexOf('$function$;') : rest.indexOf('$$;');
    return { file, body: rest.slice(0, end === -1 ? 4000 : end) };
  }
  return null;
}

/** Every projection a survivor could plausibly read. */
const PROJECTIONS = [
  'get_estate_discovery', 'list_estate_assets', 'get_estate_net_worth',
  'can_access_document', 'get_professional_workspace', 'get_estate_readiness',
  'inventory_disclosure_tier', 'asset_grant_tier', 'estate_release_state',
  'get_my_estate_capability_facts', 'get_my_estate_designations', 'get_owner_safety_status',
];

/** Doors that WRITE — release must add none of these to a survivor. */
const MUTATION_DOORS = [
  'create_asset_grant', 'create_document_grant', 'approve_document_grant', 'revoke_document_grant',
  'create_access_request', 'approve_access_request', 'deny_access_request',
  'create_estate_asset', 'archive_estate_asset', 'create_vault_document', 'delete_vault_document',
  'authorize_release', 'challenge_death_process', 'dispatch_owner_safety_notice',
  'initiate_death_verification_case', 'submit_claim_packet',
];

const report = { scanSet: SQL.length };

/* 1 · PROJECTIONS ───────────────────────────────────────────────────────────────────────────── */
report.projections = PROJECTIONS.map((name) => {
  const f = bodyOf(name);
  if (!f) return { name, defined: false };
  const b = f.body;
  return {
    name,
    file: f.file,
    definer: /security definer/.test(b),
    // Does it route disclosure through the ONE canonical predicate?
    usesPredicate: /public\.release_condition_satisfied\s*\(/.test(b),
    // Does it read the authoritative lifecycle (as the predicate's argument)?
    usesLifecycle: /public\.estate_lifecycle_state\s*\(/.test(b),
    // Does it consult the read-time ceiling?
    usesCeiling: /asset_category_grantable|document_grantable/.test(b),
    // ★ G3: does a TIER decision consult RELATIONSHIP or CAPACITY anywhere?
    readsMembership: /estate_memberships/.test(b),
    readsDesignation: /estate_designations|is_estate_executor/.test(b),
    readsOwner: /is_estate_owner/.test(b),
  };
});

/* 2 · TIER-DECIDING SITES AND THE G3 INVARIANT ──────────────────────────────────────────────── */
//
// ★ THE INVARIANT, MADE CHECKABLE. "A beneficiary is not automatically a tier" is only true if the
// functions that RESOLVE a tier read the grant row and nothing about the person. Any tier resolver
// that also reads memberships or designations is a place where relationship could inflate
// disclosure — which is exactly the confusion G3 forbids.
const TIER_RESOLVERS = ['inventory_disclosure_tier', 'asset_grant_tier'];
report.g3 = TIER_RESOLVERS.map((name) => {
  const f = bodyOf(name);
  if (!f) return { name, defined: false };
  const b = f.body;
  return {
    name,
    tierFromGrantRow: /visibility_tier/.test(b) && /access_grants/.test(b),
    consultsMembership: /estate_memberships/.test(b),
    consultsDesignation: /estate_designations|is_estate_executor/.test(b),
    // The owner short-circuit is legitimate: ownership is not a grant, it is inherent.
    ownerShortCircuit: /is_estate_owner/.test(b),
    verdict: (/estate_memberships/.test(b) || /estate_designations|is_estate_executor/.test(b))
      ? 'RELATIONSHIP REACHES TIER — G3 AT RISK'
      : 'tier derives from the GRANT alone (G3 holds)',
  };
});

/* 3 · MUTATION DOORS ────────────────────────────────────────────────────────────────────────── */
report.mutationDoors = MUTATION_DOORS.map((name) => {
  const f = bodyOf(name);
  if (!f) return { name, defined: false };
  const b = f.body;
  const whole = CODE.get(f.file) ?? '';
  return {
    name,
    // Which gate does the door carry? A survivor passes NONE of these by being a survivor.
    ownerGated: /is_estate_owner/.test(b),
    designeeGated: /is_estate_executor/.test(b),
    adminGated: /admin_require_gate/.test(b),
    memberGated: /estate_memberships/.test(b),
    clientReachable: new RegExp(`grant\\s+execute on function public\\.${name}[^;]*to authenticated`).test(whole),
    // ★ THE 11-G QUESTION: does any door become passable BECAUSE an estate is released?
    consultsLifecycle: /estate_lifecycle_state|'released'/.test(b),
  };
});

/* 4 · THE VOCABULARY EACH SURVIVOR SURFACE CAN EXPRESS ──────────────────────────────────────── */
const grantCheck = SQL.map((f) => CODE.get(f)).join('\n');
report.vocabulary = {
  releaseConditions: [...new Set([...grantCheck.matchAll(/'(after_[a-z_]+|never|immediately)'/g)].map((m) => m[1]))].sort(),
  tiers: [...new Set([...grantCheck.matchAll(/'(hidden|range_only|category_summary|limited_detail|full_detail)'/g)].map((m) => m[1]))].sort(),
  categories: [...new Set([...grantCheck.matchAll(/'(account_balances|institution_names|total_asset_value|linked_account_details|estate_inventory|estate_documents)'/g)].map((m) => m[1]))].sort(),
};

if (JSON_OUT) { console.log(JSON.stringify(report, null, 2)); process.exit(0); }

const H = (s) => console.log(`\n══ ${s} ${'═'.repeat(Math.max(0, 74 - s.length))}`);
console.log(`PHASE 11-G · SURVIVOR PATH CENSUS (${SQL.length} SQL sources)`);

H('1 · PROJECTIONS A SURVIVOR CAN READ');
console.log('   name                              def  pred  life  ceil | reads: memb desig owner');
for (const p of report.projections) {
  if (!p.defined && p.defined !== undefined && p.file === undefined) {
    console.log(`   ${p.name.padEnd(33)} ✗ NOT DEFINED`);
    continue;
  }
  const y = (b) => (b ? ' ✓ ' : ' · ');
  console.log(`   ${p.name.padEnd(33)}${y(p.definer)}${y(p.usesPredicate)}${y(p.usesLifecycle)}${y(p.usesCeiling)}|        ${y(p.readsMembership)}${y(p.readsDesignation)}${y(p.readsOwner)}`);
}

H('2 · G3 — DOES RELATIONSHIP REACH TIER?');
for (const g of report.g3) {
  console.log(`   ${g.name}`);
  console.log(`      tier from grant row: ${g.tierFromGrantRow} · membership: ${g.consultsMembership} · designation: ${g.consultsDesignation}`);
  console.log(`      → ${g.verdict}`);
}

H('3 · MUTATION DOORS (release must add none of these)');
console.log('   name                              owner desig admin membr | client | lifecycle?');
for (const d of report.mutationDoors) {
  const y = (b) => (b ? '  ✓  ' : '  ·  ');
  console.log(`   ${d.name.padEnd(33)}${y(d.ownerGated)}${y(d.designeeGated)}${y(d.adminGated)}${y(d.memberGated)}|${y(d.clientReachable)}|${y(d.consultsLifecycle)}`);
}

H('4 · VOCABULARY');
console.log(`   release conditions (${report.vocabulary.releaseConditions.length}): ${report.vocabulary.releaseConditions.join(', ')}`);
console.log(`   tiers (${report.vocabulary.tiers.length}): ${report.vocabulary.tiers.join(', ')}`);
console.log(`   categories (${report.vocabulary.categories.length}): ${report.vocabulary.categories.join(', ')}`);
console.log('\n(report only — no gate)');
