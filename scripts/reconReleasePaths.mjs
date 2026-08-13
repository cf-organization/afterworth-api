#!/usr/bin/env node
/**
 * PHASE 11-F STAGE 1 — the release-path census, DERIVED rather than remembered.
 *
 * ★ WHY THIS IS A SCRIPT AND NOT A PARAGRAPH. Every prior phase in this programme has been bitten by
 * a number that was defensible in prose and wrong in fact — a landmark denominator that drifted
 * across four reports, a palette census that halved itself, an audit whose file list was empty. A
 * release path is exactly the kind of thing where "I believe there are three" is worthless: what
 * matters is the set the code actually contains, today, including the one nobody remembered.
 *
 * It answers, from source only:
 *
 *   1 · every routine that can WRITE the estate lifecycle, and the edges each one can take;
 *   2 · every route to `released` — the set that must be exhaustively guarded;
 *   3 · every notification emitter and what channel it reaches;
 *   4 · the email/outbox/cron infrastructure that exists to be reused rather than reinvented;
 *   5 · every site that ASSUMES something 11-F is about to change: delivery, reviewer identity,
 *       ownership, or the challenge duration.
 *
 * Exit 0 always — this is a REPORT, not a gate. It prints what is, and the phase decides.
 * Usage: node scripts/reconReleasePaths.mjs [--json]
 */
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const JSON_OUT = process.argv.includes('--json');

/** Line comments stripped, string literals preserved — a literal IS the evidence class here. */
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
const TS = [...walk('api', (f) => f.endsWith('.ts')), ...walk('lib', (f) => f.endsWith('.ts'))];
const load = (f) => ({ file: f, code: stripSql(readFileSync(join(ROOT, f), 'utf8')) });

// ★ ASSERT THE SCAN SET BEFORE EVALUATING ANY RULE (the 63-assertions-against-nothing lesson).
if (SQL.length < 40 || TS.length < 5) {
  console.error(`✗ CANNOT RECON — scan set is implausible (sql=${SQL.length}, ts=${TS.length}).`);
  process.exit(2);
}

const report = { scanSet: { sql: SQL.length, ts: TS.length } };

/* 1 · LIFECYCLE WRITERS AND THEIR EDGES ─────────────────────────────────────────────────────── */
const writers = SQL.filter((f) => /update\s+public\.estate_lifecycle|insert into public\.estate_lifecycle/i.test(load(f).code));
const mapFile = SQL.find((f) => /function public\.apply_estate_lifecycle_transition/.test(load(f).code));
const edges = mapFile
  ? [...load(mapFile).code.matchAll(/v_from\s*=\s*'(\w+)'\s*and\s+p_to\s*=\s*'(\w+)'/g)].map((m) => [m[1], m[2]])
  : [];
report.lifecycle = {
  transitionMapFile: mapFile ?? null,
  edges: edges.map(([f, t]) => `${f} -> ${t}`),
  directWriters: writers,
  routesToReleased: edges.filter(([, t]) => t === 'released').map(([f]) => f),
  terminalStates: ['challenge_halted', 'released'].filter((s) => !edges.some(([f]) => f === s)),
};

/* 2 · THE RELEASE / CHALLENGE / WINDOW ROUTINES AND THEIR PRIVILEGE ──────────────────────────── */
const ROUTINES = [
  // ★ `release_estate` STAYS ON THIS LIST THOUGH IT NO LONGER EXISTS, deliberately. 11-F dropped
  // the one-person lever; a census that simply stopped looking for it could not tell "correctly
  // removed" from "quietly reintroduced". It must report NOT DEFINED IN SOURCE, with the 0055 drop
  // as its only reference.
  'release_estate',
  'authorize_release', 'dispatch_owner_safety_notice',
  'challenge_death_process', 'begin_challenge_window',
  'get_owner_safety_status', 'challenge_window_duration', 'estate_lifecycle_state',
  'apply_estate_lifecycle_transition', 'admin_decide_death_verification_case',
  'claim_owner_notices', 'purge_outbox_rows', 'owner_notice_age_gate', 'owner_notice_census',
];
report.routines = ROUTINES.map((name) => {
  const def = SQL.find((f) => new RegExp(`create or replace function public\\.${name}\\s*\\(`).test(load(f).code));
  const all = SQL.map(load);
  const callers = all
    .filter((s) => s.file !== def && new RegExp(`public\\.${name}\\s*\\(`).test(s.code))
    .map((s) => s.file);
  const src = def ? load(def).code : '';
  const revoked = new RegExp(`revoke execute on function public\\.${name}[^;]*authenticated`, 'i').test(src);
  const granted = new RegExp(`grant\\s+execute on function public\\.${name}[^;]*to authenticated`, 'i').test(src);
  return { name, definedIn: def ?? null, callers, clientReachable: granted && !revoked ? 'GRANTED' : revoked ? 'REVOKED' : 'unknown' };
});

/* 3 · NOTIFICATION EMITTERS AND CHANNELS ────────────────────────────────────────────────────── */
const catalogFile = SQL.find((f) => /function public\.notification_event_copy/.test(load(f).code));
const events = catalogFile
  ? [...load(catalogFile).code.matchAll(/\(\s*'([a-z_]+\.[a-z_]+)'\s*,/g)].map((m) => m[1])
  : [];
report.notifications = {
  catalogFile: catalogFile ?? null,
  events,
  inAppEmitters: SQL.filter((f) => /public\.emit_lifecycle_notification\s*\(/.test(load(f).code)),
  // ★ THE CHANNEL QUESTION 11-F TURNS ON: is there ANY email path from a lifecycle event today?
  emailFromLifecycle: SQL.filter((f) =>
    /emit_lifecycle_notification/.test(load(f).code) && /outbox|email/i.test(load(f).code)),
};

/* 4 · EMAIL / OUTBOX / CRON INFRASTRUCTURE ──────────────────────────────────────────────────── */
const vercel = existsSync(join(ROOT, 'vercel.json')) ? JSON.parse(readFileSync(join(ROOT, 'vercel.json'), 'utf8')) : {};
report.delivery = {
  outboxTables: [...new Set(SQL.flatMap((f) =>
    [...load(f).code.matchAll(/create table if not exists public\.(\w*outbox\w*)/g)].map((m) => m[1])))],
  emailModules: TS.filter((f) => /resend|sendEmail|provider/i.test(f)),
  drainHandlers: TS.filter((f) => /drain/i.test(f)),
  crons: (vercel.crons ?? []).map((c) => `${c.path} @ ${c.schedule}`),
  // Does any drain claim rows WITHOUT an age bound? (Stage 3 asks precisely this.)
  drainAgeGate: SQL.filter((f) => /claim_invitation_delivery_batch/.test(load(f).code))
    .map((f) => ({ file: f, boundsAge: /requested_at\s*[<>]|now\(\)\s*-\s*interval/.test(load(f).code) })),
};

/* 5 · SITES THAT ASSUME WHAT 11-F CHANGES ───────────────────────────────────────────────────── */
const assume = (re) => SQL.concat(TS).filter((f) => re.test(load(f).code));
report.assumptions = {
  // "the owner was notified" == an in-app row committed
  notificationDelivery: assume(/owner_notified_at|safety_notification_id|owner_notification_failed/),
  // reviewer identity: anywhere a single admin decides alone
  reviewerIdentity: assume(/decided_by|admin_require_gate\(\)/).filter((f) => /death_verification|release_safety/.test(f)),
  // ownership assumptions on the safety path
  ownership: assume(/is_estate_owner\s*\(/).filter((f) => /release_safety|death_verification/.test(f)),
  // the challenge duration source
  challengeDuration: assume(/challenge_window_duration|release_safety_policy/),
};

if (JSON_OUT) {
  console.log(JSON.stringify(report, null, 2));
  process.exit(0);
}

const H = (s) => console.log(`\n══ ${s} ${'═'.repeat(Math.max(0, 74 - s.length))}`);
console.log(`PHASE 11-F · RELEASE-PATH CENSUS (derived from ${SQL.length} SQL + ${TS.length} TS sources)`);

H('1 · LIFECYCLE');
console.log(`  transition map: ${report.lifecycle.transitionMapFile}`);
for (const e of report.lifecycle.edges) console.log(`    ${e}`);
console.log(`  ROUTES TO released: ${report.lifecycle.routesToReleased.join(', ') || '(none)'}`);
console.log(`  terminal (no outbound edge): ${report.lifecycle.terminalStates.join(', ') || '(none)'}`);
console.log(`  direct table writers: ${report.lifecycle.directWriters.join(', ')}`);

H('2 · ROUTINES');
for (const r of report.routines) {
  console.log(`  ${r.name.padEnd(38)} ${String(r.clientReachable).padEnd(9)} callers: ${r.callers.length ? r.callers.join(', ') : '(none)'}`);
  if (!r.definedIn) console.log('      ✗ NOT DEFINED IN SOURCE');
}

H('3 · NOTIFICATIONS');
console.log(`  catalog: ${report.notifications.catalogFile}`);
console.log(`  events (${report.notifications.events.length}): ${report.notifications.events.join(', ')}`);
console.log(`  in-app emitters: ${report.notifications.inAppEmitters.length}`);
console.log(`  ★ lifecycle events reaching EMAIL: ${report.notifications.emailFromLifecycle.length ? report.notifications.emailFromLifecycle.join(', ') : 'NONE — in-app only'}`);

H('4 · DELIVERY INFRASTRUCTURE');
console.log(`  outbox tables: ${report.delivery.outboxTables.join(', ') || '(none)'}`);
console.log(`  email modules: ${report.delivery.emailModules.join(', ')}`);
console.log(`  drain handlers: ${report.delivery.drainHandlers.join(', ')}`);
console.log(`  crons: ${report.delivery.crons.join(' | ')}`);
for (const d of report.delivery.drainAgeGate) {
  console.log(`  ★ drain age gate in ${d.file}: ${d.boundsAge ? 'present' : 'ABSENT — any queued row is claimable'}`);
}

H('5 · ASSUMPTIONS 11-F CHANGES');
for (const [k, v] of Object.entries(report.assumptions)) {
  console.log(`  ${k} (${v.length}):`);
  for (const f of v) console.log(`      ${f}`);
}
console.log('\n(report only — no gate)');
