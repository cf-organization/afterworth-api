#!/usr/bin/env node
/**
 * INVITER NAME PRIVACY — local verification (migration 0069).
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * Builds a throwaway Postgres container from db/bootstrap + 0067 + 0068 + 0069, seeds SYNTHETIC owners
 * (fixed uuids, example.test addresses, invented names — nobody real) in every name state the product
 * can hold, invites ONE synthetic recipient through BOTH create paths, and proves at every release point
 * that an email address is never handed to a recipient as a person's name:
 *
 *   · the stored row (new invitations): a name, or NULL — never the owner's address; the mint still
 *     succeeds and queues delivery when there is no usable name; the recipient address and the separate
 *     estate-name choice are untouched;
 *   · a LEGACY row that already stores an address (written before 0069) is NOT rewritten, and every
 *     release point returns NULL for it;
 *   · the pending-invitation list (resolve_membership) and the token preview (invitation_preview);
 *   · the post-acceptance membership cue (0068's rules, unchanged);
 *   · 0067's verified-contact matching of the pending list (unchanged);
 *   · the delivery-notice RPC still hands the worker the stored column RAW — recorded here so nobody
 *     mistakes the SQL for the email's enforcement: that is lib/invitations/delivery.ts, proven with the
 *     rendered HTML and text in test/delivery.test.ts;
 *   · the SQL sanitizer passes its own vector table (db/tests/safe_inviter_display_name_assertions.sql).
 *
 * ★ IT CANNOT BE POINTED AT A REAL DATABASE. No --database-url, no project ref, no .env read; it talks
 *   only to the container it created, through `docker exec`, and removes it in `finally`.
 * ★ auth.uid() IS OVERRIDDEN TO READ A SESSION SETTING — verification-only, NOT production DDL — so each
 *   call runs as a chosen synthetic user. The override is applied AFTER the bootstrap and the migrations.
 * ★ EXITS 2 WITHOUT DOCKER. A runner that cannot execute this fails rather than passing.
 * ★ POSITIVE CONTROLS FIRST. The address matcher is proven against a row known to hold one before any
 *   absence is believed, and the SHOWN owner's name is proven present before any null is.
 *
 * Usage: node scripts/verifyInviterNamePrivacy.mjs [--keep] [--migration <path to an alternative 0069>]
 */
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

for (const f of ['--database-url', '--db-url', '--project-ref', '--linked', '--remote', '--production', '--host', '--dsn']) {
  if (process.argv.some((a) => a.split('=')[0] === f)) { console.error(`REFUSED — ${f} is not accepted. This verification only ever targets a container it creates itself.`); process.exit(2); }
}
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const BOOT = join(ROOT, 'db/bootstrap');
const MIGS = readdirSync(join(ROOT, 'db/migrations'));
const find = (prefix, needle) => { const f = MIGS.find((m) => m.startsWith(prefix) && m.includes(needle)); if (!f) throw new Error(`migration ${prefix}*${needle}* not found`); return join(ROOT, 'db/migrations', f); };
const M0067 = find('0067_', 'contact_binding');
const M0068 = find('0068_', 'invitation_cue');
const migArg = process.argv.indexOf('--migration');
// --migration <path> is for BEFORE/AFTER or MUTANT comparison against another copy of 0069 (verification-only).
const M0069 = migArg >= 0 && process.argv[migArg + 1] ? resolve(process.argv[migArg + 1]) : find('0069_', 'inviter_name_privacy');
const SANITIZER_ASSERTIONS = join(ROOT, 'db/tests/safe_inviter_display_name_assertions.sql');
const CONTAINER = `aw-inviter-privacy-${process.pid}`;
const KEEP = process.argv.includes('--keep');
const say = (m) => console.log(m);
const rm = () => { if (!KEEP) spawnSync('docker', ['rm', '-f', CONTAINER], { stdio: 'ignore' }); };
const psql = (sql) => spawnSync('docker', ['exec', '-i', CONTAINER, 'psql', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-q', '-f', '-'], { input: sql, encoding: 'utf8' });
const q = (sql) => { const r = spawnSync('docker', ['exec', '-i', CONTAINER, 'psql', '-U', 'postgres', '-tAc', sql], { encoding: 'utf8' }); if (r.status !== 0) throw new Error(`query failed: ${sql.slice(0, 120)}\n${r.stderr}`); return r.stdout.trim().split('\n').pop() ?? ''; };
const must = (r, what) => { if (r.status !== 0) throw new Error(`${what} failed:\n${(r.stderr || '').slice(0, 1200)}`); };
const as = (uid, sql) => psql(`select set_config('app.uid', '${uid}', false);\n${sql}`);
const asQ = (uid, sql) => q(`select set_config('app.uid', '${uid}', false); ${sql}`);
const anonQ = (sql) => q(`select set_config('app.uid', '', false); ${sql}`);
const lit = (v) => (v == null ? 'null' : `'${String(v).replace(/'/g, "''")}'`);
const ADDRESS = /\S@\S/; // the client's rule, used here only as the OBSERVER's matcher

let failures = 0;
const check = (cond, label) => { if (cond) say(`  ✓ ${label}`); else { failures += 1; say(`  ✗ ${label}`); } };

// ── synthetic identities ──────────────────────────────────────────────────────────────────────────
// Every OWNER has an email on file that is DIFFERENT from the recipient's, and different from any name,
// so "the sender address is absent" and "delivery still targets the recipient" are two separable facts.
const U = {
  SHOWN:  '0a690000-0000-4000-8000-000000000001', // usable name, chooses to show it
  HIDDEN: '0a690000-0000-4000-8000-000000000002', // usable name, chooses to HIDE it (and hides the estate name)
  BLANK:  '0a690000-0000-4000-8000-000000000003', // profile full_name = ''  (blank), email on file
  NONE:   '0a690000-0000-4000-8000-000000000004', // profile full_name = NULL, email on file
  SPACES: '0a690000-0000-4000-8000-000000000005', // profile full_name = whitespace only
  ADDR:   '0a690000-0000-4000-8000-000000000006', // profile full_name is itself an address
  LONG:   '0a690000-0000-4000-8000-000000000007', // profile full_name longer than 200 characters
  LEGACY: '0a690000-0000-4000-8000-000000000008', // usable name at creation; its rows are then REWRITTEN to hold an address, as a pre-0069 row does
  BEN:    '0b690000-0000-4000-8000-00000000000b', // the recipient, confirmed email
  STRANGER: '0c690000-0000-4000-8000-00000000000c', // another confirmed caller, invited to nothing
};
const RECIPIENT = 'recipient@example.test';
const PROFILE = {
  SHOWN:  ['shown-sender@example.test',  'Dana Hartley'],
  HIDDEN: ['hidden-sender@example.test', 'Hidden Harper'],
  BLANK:  ['blank-sender@example.test',  ''],
  NONE:   ['none-sender@example.test',   null],
  SPACES: ['spaces-sender@example.test', '  \t '],
  ADDR:   ['addr-sender@example.test',   'addr-as-name@example.test'],
  LONG:   ['long-sender@example.test',   'x'.repeat(201)],
  LEGACY: ['legacy-sender@example.test', 'Legacy Owner'],
  BEN:    [RECIPIENT, 'Ben Example'],
  STRANGER: ['stranger@example.test', 'Stranger Example'],
};
const OWNERS = ['SHOWN', 'HIDDEN', 'BLANK', 'NONE', 'SPACES', 'ADDR', 'LONG', 'LEGACY'];
const SENDER_ADDRESSES = OWNERS.map((k) => PROFILE[k][0]).concat([PROFILE.ADDR[1]]);
const SHOW = { SHOWN: [true, true], HIDDEN: [false, false], BLANK: [true, true], NONE: [true, true], SPACES: [true, true], ADDR: [true, true], LONG: [true, true], LEGACY: [true, true] }; // [showEstateName, showInviterName]

try {
  if (spawnSync('docker', ['info'], { stdio: 'ignore' }).status !== 0) {
    console.error('✗ CANNOT VERIFY — Docker is not available. The privacy fix must be EXECUTED, not described.');
    process.exit(2);
  }
  rm();
  must(spawnSync('docker', ['run', '-d', '--name', CONTAINER, '-e', 'POSTGRES_PASSWORD=verify', 'postgres:16'], { encoding: 'utf8' }), 'docker run');
  for (let i = 0; i < 60; i++) { if (spawnSync('docker', ['exec', CONTAINER, 'pg_isready', '-U', 'postgres'], { stdio: 'ignore' }).status === 0) break; await new Promise((r) => setTimeout(r, 1000)); }
  must(psql(readFileSync(join(BOOT, 'testing/PLATFORM_SHIM_NOT_PRODUCTION.sql'), 'utf8')), 'platform shim');
  const phases = readdirSync(BOOT).filter((f) => /^\d+_.*\.sql$/.test(f)).sort((a, b) => Number(a.split('_')[0]) - Number(b.split('_')[0]));
  for (const f of phases) must(psql(readFileSync(join(BOOT, f), 'utf8')), `bootstrap ${f}`);
  say(`bootstrap applied: ${phases.length} phases`);
  must(psql(readFileSync(M0067, 'utf8')), 'migration 0067');
  must(psql(readFileSync(M0068, 'utf8')), 'migration 0068');
  must(psql(readFileSync(M0069, 'utf8')), 'migration 0069 (1st apply)');
  must(psql(readFileSync(M0069, 'utf8')), 'migration 0069 (2nd apply — idempotent)');
  say('migrations 0067, 0068, 0069 applied (0069 twice, idempotent)');
  must(psql(`create or replace function auth.uid() returns uuid language sql stable as $fn$ select nullif(current_setting('app.uid', true), '')::uuid $fn$;`), 'auth.uid override');

  say('\n── 0 · the SQL sanitizer passes its own vector table (decided inside SQL) ──');
  const vectors = psql(readFileSync(SANITIZER_ASSERTIONS, 'utf8'));
  check(vectors.status === 0, 'db/tests/safe_inviter_display_name_assertions.sql raised nothing');
  check(/\bok\s+address-shaped\b/.test(vectors.stderr + vectors.stdout), 'positive control — the vector run reported the address-shaped case');

  // ── seed ──
  for (const [k, id] of Object.entries(U)) {
    const [email, name] = PROFILE[k];
    must(psql(`insert into auth.users (id, email, email_confirmed_at) values ('${id}', ${lit(email)}, now());
      insert into public.profiles (id, email, full_name) values ('${id}', ${lit(email)}, ${lit(name)}) on conflict (id) do update set email = excluded.email, full_name = excluded.full_name;`), `seed ${k}`);
  }
  check(q(`select coalesce(full_name, '<null>') from public.profiles where id = '${U.BLANK}'`) === '' && q(`select coalesce(full_name, '<null>') from public.profiles where id = '${U.NONE}'`) === '<null>', 'precondition — BLANK holds an empty name, NONE holds NULL, both with an email on file');
  const estateOf = {};
  for (const k of OWNERS) {
    must(as(U[k], `select public.resolve_membership(${lit(PROFILE[k][0])}, null);`), `bootstrap estate ${k}`);
    estateOf[k] = q(`select id from public.estates where owner_id = '${U[k]}' and is_primary`);
  }

  // ── invitations to the recipient through BOTH create paths ──
  // The owner path refuses a second ACTIVE invitation per (estate, address, role), so the console path
  // mints the professional-delegate one. Both carry the owner's two visibility choices.
  const inv = {}; // key → { owner: invitation id (owner path), console: invitation id, token: raw token of the console row }
  for (const k of OWNERS) {
    const [showEstate, showInviter] = SHOW[k];
    const ownerRow = asQ(U[k], `select invitation_id from public.create_estate_invitation('${estateOf[k]}', 'beneficiary', '${RECIPIENT}', null, ${showEstate}, ${showInviter}, 14);`);
    const consoleRow = asQ(U[k], `select invitation_id || '|' || raw_token from public.create_invitation('${estateOf[k]}', 'professional_delegate', 'professional_delegate', '${RECIPIENT}', null, ${showEstate}, ${showInviter}, 14);`);
    const [cid, token] = consoleRow.split('|');
    inv[k] = { owner: ownerRow, console: cid, token };
    check(/^[0-9a-f-]{36}$/.test(ownerRow) && /^[0-9a-f-]{36}$/.test(cid), `${k}: both create paths minted an invitation (a missing or unusable name does not block sending)`);
  }
  const stored = (id) => q(`select coalesce(inviter_display_name, '<null>') from public.invitations where id = '${id}'`);

  say('\n── 1 · what the new rows STORE: a name or NULL, never the owner\'s address ──');
  check(stored(inv.SHOWN.owner) === 'Dana Hartley' && stored(inv.SHOWN.console) === 'Dana Hartley', 'SHOWN: both paths stored the usable name');
  check(stored(inv.HIDDEN.owner) === 'Hidden Harper' && stored(inv.HIDDEN.console) === 'Hidden Harper', 'HIDDEN: the name is stored (the choice is honoured at release, not by discarding the name)');
  for (const k of ['BLANK', 'NONE', 'SPACES', 'ADDR', 'LONG']) {
    check(stored(inv[k].owner) === '<null>' && stored(inv[k].console) === '<null>', `${k}: both paths stored NULL — not the owner's email address (${k === 'ADDR' ? 'the address-shaped name is refused too' : 'the old coalesce fallback is gone'})`);
  }
  const newRowsWithAddress = Number(q(`select count(*) from public.invitations where inviter_display_name ~ '[^[:space:]]@[^[:space:]]'`));
  check(newRowsWithAddress === 0, 'no new row anywhere stores an address-shaped inviter name');
  // the delivery address and the estate-name choice are untouched
  check(OWNERS.every((k) => q(`select invitee_email from public.invitations where id = '${inv[k].owner}'`) === RECIPIENT), 'every row\'s delivery address is the RECIPIENT\'s, unchanged');
  check(q(`select preview_visibility::text from public.invitations where id = '${inv.HIDDEN.owner}'`) === '{"showEstateName": false, "showInviterName": false}' && q(`select preview_visibility::text from public.invitations where id = '${inv.BLANK.owner}'`) === '{"showEstateName": true, "showInviterName": true}', 'preview_visibility carries both choices exactly as the owner set them (the estate-name choice is separate and unchanged)');
  check(OWNERS.every((k) => q(`select count(*) from public.invitation_delivery_outbox where invitation_id = '${inv[k].owner}'`) === '1'), 'every owner-path invitation queued its delivery — including the ones with no usable name');

  say('\n── 2 · a LEGACY row already storing an address is left exactly as it is ──');
  const legacyAddress = PROFILE.LEGACY[0];
  must(psql(`update public.invitations set inviter_display_name = '${legacyAddress}' where id in ('${inv.LEGACY.owner}', '${inv.LEGACY.console}');`), 'rewrite LEGACY rows to the pre-0069 shape');
  check(ADDRESS.test(stored(inv.LEGACY.owner)) && stored(inv.LEGACY.owner) === legacyAddress, 'positive control — the LEGACY row now holds an address and the observer\'s matcher sees it');
  const beforeReapply = q(`select count(*) from public.invitations where inviter_display_name ~ '[^[:space:]]@[^[:space:]]'`);
  must(psql(readFileSync(M0069, 'utf8')), 'migration 0069 (3rd apply, over a legacy row)');
  check(stored(inv.LEGACY.owner) === legacyAddress && stored(inv.LEGACY.console) === legacyAddress && q(`select count(*) from public.invitations where inviter_display_name ~ '[^[:space:]]@[^[:space:]]'`) === beforeReapply, 're-applying 0069 rewrote nothing: the stored legacy value is untouched (no backfill — the sanitizer runs on the way OUT)');

  say('\n── 3 · the pending-invitation list, as the recipient ──');
  const pendingJson = asQ(U.BEN, `select public.resolve_membership('${RECIPIENT}', null)::text;`);
  const pending = JSON.parse(pendingJson).pendingInvitations;
  const byId = new Map(pending.map((p) => [p.id, p]));
  const allIds = OWNERS.flatMap((k) => [inv[k].owner, inv[k].console]);
  check(pending.length === allIds.length && allIds.every((id) => byId.has(id)), `the recipient sees all ${allIds.length} invitations addressed to their verified email`);
  check(pending.every((p) => 'inviterDisplayName' in p && 'estateDisplayName' in p), 'every pending entry carries both keys (null, never omitted)');
  check(byId.get(inv.SHOWN.owner)?.inviterDisplayName === 'Dana Hartley' && byId.get(inv.SHOWN.console)?.inviterDisplayName === 'Dana Hartley', 'positive control — SHOWN releases "Dana Hartley" on both rows');
  check(byId.get(inv.HIDDEN.owner)?.inviterDisplayName === null && byId.get(inv.HIDDEN.console)?.inviterDisplayName === null, 'HIDDEN: null (the owner\'s choice)');
  for (const k of ['BLANK', 'NONE', 'SPACES', 'ADDR', 'LONG']) check(byId.get(inv[k].owner)?.inviterDisplayName === null && byId.get(inv[k].console)?.inviterDisplayName === null, `${k}: null (nothing usable was stored)`);
  check(byId.get(inv.LEGACY.owner)?.inviterDisplayName === null && byId.get(inv.LEGACY.console)?.inviterDisplayName === null, 'LEGACY: null — the stored address is sanitized on release, though the owner chose to show a name');
  check(byId.get(inv.HIDDEN.owner)?.estateDisplayName === null && byId.get(inv.SHOWN.owner)?.estateDisplayName === 'My Estate', 'the estate-name choice is honoured independently (hidden → null, shown → the name)');
  check(SENDER_ADDRESSES.every((a) => !pendingJson.includes(a)), 'the serialized pending list contains NO sender address, in any field');
  check(!pendingJson.includes(RECIPIENT), 'nor the recipient\'s own address');
  say('  · 0067 contact binding, unchanged:');
  check(JSON.parse(asQ(U.STRANGER, `select public.resolve_membership('${RECIPIENT}', null)::text;`)).pendingInvitations.length === 0, 'a stranger passing the recipient\'s email sees nothing');
  check(JSON.parse(asQ(U.BEN, `select public.resolve_membership('${PROFILE.STRANGER[0]}', '+15555550199')::text;`)).pendingInvitations.length === allIds.length, 'the recipient passing someone else\'s contacts still sees exactly their own');
  must(psql(`update auth.users set email_confirmed_at = null where id = '${U.BEN}';`), 'unconfirm the recipient');
  check(JSON.parse(asQ(U.BEN, `select public.resolve_membership('${RECIPIENT}', null)::text;`)).pendingInvitations.length === 0, 'with the email unconfirmed the recipient sees nothing');
  must(psql(`update auth.users set email_confirmed_at = now() where id = '${U.BEN}';`), 're-confirm the recipient');

  say('\n── 4 · the token preview (unauthenticated, token-bound) ──');
  const preview = (token) => { const j = anonQ(`select coalesce(row_to_json(p)::text, '') from public.invitation_preview('${token}') p;`); return j ? JSON.parse(j) : null; };
  const pv = Object.fromEntries(OWNERS.map((k) => [k, preview(inv[k].token)]));
  check(OWNERS.every((k) => pv[k] !== null), 'every console-path token previews to exactly one row');
  check(pv.SHOWN.inviter_display_name === 'Dana Hartley' && pv.SHOWN.estate_display_name === 'My Estate', 'positive control — SHOWN previews the name and the estate');
  check(pv.HIDDEN.inviter_display_name === null && pv.HIDDEN.estate_display_name === null, 'HIDDEN: both names withheld');
  for (const k of ['BLANK', 'NONE', 'SPACES', 'ADDR', 'LONG']) check(pv[k].inviter_display_name === null && pv[k].estate_display_name === 'My Estate', `${k}: inviter null, estate still shown`);
  check(pv.LEGACY.inviter_display_name === null, 'LEGACY: the stored address previews as null');
  check(OWNERS.every((k) => pv[k].invitee_email_hint === 'r•••@example.test'), 'the recipient hint is untouched (delivery still targets the recipient)');
  const previewText = JSON.stringify(pv);
  check(SENDER_ADDRESSES.every((a) => !previewText.includes(a)) && !previewText.includes(RECIPIENT), 'no preview row contains a sender address or the recipient\'s full address');

  say('\n── 5 · what the delivery worker is handed (the email\'s enforcement is in lib/, proven in test/delivery.test.ts) ──');
  const outboxId = q(`select id from public.invitation_delivery_outbox where invitation_id = '${inv.LEGACY.owner}'`);
  const claimed = q(`select count(*) from public.claim_invitation_deliveries(1, '${outboxId}');`);
  check(claimed === '1', 'the LEGACY owner-path row is claimed');
  const notice = JSON.parse(q(`select row_to_json(n)::text from public.issue_invitation_delivery_notice('${outboxId}') n;`));
  check(notice.invitee_email === RECIPIENT, 'the notice targets the RECIPIENT');
  check(notice.inviter_display_name === legacyAddress && notice.preview_visibility?.showInviterName === true, 'recorded: the notice RPC hands the worker the stored column RAW with showInviterName=true — so the worker\'s sanitizer (delivery.ts + the template) is what keeps the address out of the email');
  must(psql(`select public.record_invitation_delivery_outcome('${outboxId}', ${notice.delivery_generation}, 'providerAccepted', 'msg_verify', null);`), 'settle the claimed row');

  say('\n── 6 · the post-acceptance membership cue (0068), unchanged ──');
  for (const k of ['SHOWN', 'HIDDEN', 'LEGACY', 'BLANK']) must(as(U.BEN, `select * from public.accept_invitation('${inv[k].owner}');`), `BEN accepts ${k}`);
  const after = JSON.parse(asQ(U.BEN, `select public.resolve_membership('${RECIPIENT}', null)::text;`));
  const cueOf = (k) => after.additionalContexts.find((c) => c.estateId === estateOf[k])?.inviterDisplayName;
  check(after.additionalContexts.length === 4 && after.additionalContexts.every((c) => 'inviterDisplayName' in c), 'four accepted memberships, each carrying the cue key');
  check(cueOf('SHOWN') === 'Dana Hartley', 'positive control — the SHOWN membership carries the cue');
  check(cueOf('HIDDEN') === null, 'HIDDEN: no cue');
  check(cueOf('LEGACY') === null, 'LEGACY: no cue — the address never becomes a cue');
  check(cueOf('BLANK') === null, 'BLANK: no cue');
  check(!('inviterDisplayName' in after.primaryEstateContext), 'the primary (owned) context carries no cue key');
  check(SENDER_ADDRESSES.every((a) => !JSON.stringify(after).includes(a)), 'the whole resolve response contains no sender address');

  say(`\nFAILURES: ${failures}`);
  process.exitCode = failures === 0 ? 0 : 1;
} catch (e) {
  console.error(String(e?.message ?? e));
  process.exitCode = 2;
} finally {
  rm();
}
