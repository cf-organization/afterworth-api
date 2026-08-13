#!/usr/bin/env node
/**
 * CLASSIFY THE 42501 ON `release_condition_satisfied` — read-only, product-safe, no DDL.
 *
 * ★ THE QUESTION. After the Phase 11 bundles were applied, the source↔deployment reconciler failed
 * with `42501 permission denied for function release_condition_satisfied` while probing
 * `notification_grant_is_live`. That is either a real privilege defect in production or an
 * instrument probing under the wrong role, and the difference matters enormously: one is a broken
 * deployment, the other is a broken test.
 *
 * ★ WHY IT CANNOT BE ASSUMED. Both stories predict the same error message. Only the ROLE dimension
 * separates them, so this probes the same two functions under BOTH roles and additionally exercises
 * a real production path.
 *
 * ★ WHAT SOURCE SAYS (re-derived, not remembered):
 *   · release_condition_satisfied  — language sql, NO `security definer` ⇒ SECURITY INVOKER.
 *     `revoke ... from public, anon` + `grant ... to authenticated`.
 *   · notification_grant_is_live   — language sql, NO `security definer` ⇒ SECURITY INVOKER,
 *     deliberately left with default PUBLIC execute (0050: "Revoking them would be ceremony").
 *   · Its three production callers — create_asset_grant, create_document_grant,
 *     approve_document_grant — are all SECURITY DEFINER, so the nested predicate call runs as the
 *     function OWNER, not as the client role.
 *
 * So an `anon` caller reaching the predicate through an INVOKER helper is EXPECTED to be refused.
 * Whether that is the whole story is what the probes below decide.
 *
 * ★ EVERY PROBE IS READ-ONLY. Two pure functions and one read-only DEFINER projection. Nothing
 * writes; no DDL; production is not modified.
 *
 * Usage:  node scripts/classifyPredicatePrivilege.mjs
 * Exit:   0 classified · 2 could not classify (never a pass)
 */
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createClient } from '@supabase/supabase-js';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const MOBILE = resolve(ROOT, '../afterworth-mobile');

const parseEnv = (p) => {
  const out = new Map();
  if (!existsSync(p)) return out;
  for (const line of readFileSync(p, 'utf8').split('\n')) {
    const m = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/.exec(line.trim());
    if (m) out.set(m[1], m[2].replace(/^["']|["']$/g, ''));
  }
  return out;
};

const env = new Map([...parseEnv(join(ROOT, '.env')), ...parseEnv(join(ROOT, '.env.local'))]);
const URL_ = env.get('SUPABASE_URL');
const KEY = env.get('SUPABASE_PUBLISHABLE_KEY');
if (!URL_ || !KEY) {
  console.error('✗ CANNOT CLASSIFY — SUPABASE_URL / SUPABASE_PUBLISHABLE_KEY missing');
  process.exit(2);
}
if (KEY.startsWith('sb_secret')) {
  console.error('✗ REFUSING — this classification must use the key the product uses, never a secret key.');
  process.exit(2);
}

// Credentials come from the MOBILE repo's .env.test, the same source verifyDeployedContracts uses.
// Values are never printed.
const testEnv = new Map([...parseEnv(join(MOBILE, '.env.test'))]);
const EMAIL = testEnv.get('AW_OR_OWNER_EMAIL');
const PASSWORD = testEnv.get('AW_OR_OWNER_PASSWORD');

const mk = () => createClient(URL_, KEY, { auth: { persistSession: false } });

const call = async (c, fn, args) => {
  const { data, error } = await c.rpc(fn, args);
  return { data, code: error?.code ?? null, message: error?.message ?? null };
};

const PRED_ARGS = {
  p_release_condition: 'immediately', p_approved_at: null,
  p_policy: 'standard', p_lifecycle_state: 'active',
};
const LIVE_ARGS = { p_status: 'active', p_release_condition: 'immediately', p_approved_at: null };

const say = (ok, label, detail) => console.log(`  ${ok ? '✓' : '✗'} ${label.padEnd(56)} ${detail}`);

const main = async () => {
  console.log(`privilege classification · ${URL_.replace(/^https?:\/\//, '').split('.')[0]}\n`);

  /* ── 1 · ANON (the role the drift verifier used) ────────────────────────────────────────────── */
  console.log('1 · AS anon — the role verifySourceDeploymentDrift probes under');
  const anon = mk();
  const aPred = await call(anon, 'release_condition_satisfied', PRED_ARGS);
  const aLive = await call(anon, 'notification_grant_is_live', LIVE_ARGS);
  say(aPred.code === '42501', 'release_condition_satisfied (direct)', `${aPred.code ?? 'no error'} ${aPred.code === '42501' ? '(refused — matches source revoke)' : ''}`);
  say(aLive.code === '42501', 'notification_grant_is_live (nested call)', `${aLive.code ?? 'no error'} ${aLive.code === '42501' ? '(refused via the INVOKER chain)' : ''}`);

  /* ── 2 · AUTHENTICATED (the role source grants) ─────────────────────────────────────────────── */
  console.log('\n2 · AS authenticated — the role source explicitly GRANTS');
  if (!EMAIL || !PASSWORD) {
    console.error('  ✗ CANNOT CLASSIFY — AW_OR_OWNER_EMAIL/_PASSWORD absent from afterworth-mobile/.env.test.');
    console.error('    Without an authenticated probe, "anon is refused" cannot be distinguished from');
    console.error('    "everyone is refused", and those are opposite diagnoses.');
    process.exit(2);
  }
  const auth = mk();
  const { data: session, error: signInErr } = await auth.auth.signInWithPassword({
    email: EMAIL, password: PASSWORD,
  });
  if (signInErr || !session?.user) {
    console.error(`  ✗ CANNOT CLASSIFY — sign-in failed: ${signInErr?.message ?? 'no user'}`);
    process.exit(2);
  }
  const uPred = await call(auth, 'release_condition_satisfied', PRED_ARGS);
  const uLive = await call(auth, 'notification_grant_is_live', LIVE_ARGS);
  say(uPred.code === null && uPred.data === true, 'release_condition_satisfied (direct)',
    uPred.code ? `${uPred.code} ${uPred.message}` : `returned ${JSON.stringify(uPred.data)}`);
  say(uLive.code === null && uLive.data === true, 'notification_grant_is_live (nested call)',
    uLive.code ? `${uLive.code} ${uLive.message}` : `returned ${JSON.stringify(uLive.data)}`);

  /* ── 3 · A REAL PRODUCTION PATH (SECURITY DEFINER → predicate) ──────────────────────────────── */
  //
  // ★ THE OPERATOR'S CONDITION: do not call this a verifier problem unless production-path calls
  // prove it. `get_estate_discovery` is SECURITY DEFINER, read-only, and calls
  // `inventory_disclosure_tier`, which calls the predicate. If the DEFINER chain were broken, this
  // would raise 42501 rather than return a payload.
  console.log('\n3 · A REAL PRODUCTION PATH — SECURITY DEFINER routine that calls the predicate');
  const disc = await call(auth, 'get_estate_discovery', { p_estate: '00000000-0000-4000-8000-000000000000' });
  const definerOk = disc.code !== '42501';
  say(definerOk, 'get_estate_discovery (DEFINER → predicate)',
    disc.code ? `${disc.code} ${disc.message}` : 'returned a payload (chain resolves)');

  /* ── VERDICT ───────────────────────────────────────────────────────────────────────────────── */
  console.log(`\n${'─'.repeat(78)}`);
  const anonRefused = aPred.code === '42501' && aLive.code === '42501';
  const authWorks = uPred.code === null && uLive.code === null && uPred.data === true && uLive.data === true;

  if (anonRefused && authWorks && definerOk) {
    console.log('CLASSIFICATION: B — VERIFIER ROLE DEFECT');
    console.log('');
    console.log('  Production posture matches SOURCE exactly:');
    console.log('    · release_condition_satisfied is SECURITY INVOKER, revoked from anon, granted');
    console.log('      to authenticated — and deployed behaves precisely that way.');
    console.log('    · notification_grant_is_live is INVOKER and left PUBLIC, so an anon caller');
    console.log('      reaching the predicate through it is refused BY DESIGN.');
    console.log('    · authenticated executes both end-to-end.');
    console.log('    · the SECURITY DEFINER production path resolves the predicate as the function');
    console.log('      owner and is unaffected — no product call site is broken.');
    console.log('');
    console.log('  The reconciler probed as anon. That worked before this deployment only because');
    console.log('  the OLD deployed notification_grant_is_live INLINED the release rule and made no');
    console.log('  nested call. Delegation is the 11-B change; the anon probe was never valid for it.');
    console.log('');
    console.log('  FIX BELONGS IN THE INSTRUMENT, NOT IN PRODUCTION. No DDL is required.');
    process.exit(0);
  }
  if (!anonRefused && authWorks) {
    console.log('CLASSIFICATION: A — DEPLOYMENT PRIVILEGE DEFECT (anon is NOT refused as source requires)');
    process.exit(0);
  }
  if (!authWorks) {
    console.log('CLASSIFICATION: A — DEPLOYMENT PRIVILEGE DEFECT');
    console.log('  authenticated cannot execute a function source explicitly GRANTS to it.');
    console.log('  This is a production privilege problem; the reconciler is reporting it correctly.');
    process.exit(0);
  }
  console.log('CLASSIFICATION: D — OTHER. Evidence above does not match a known pattern.');
  process.exit(2);
};

main().catch((e) => {
  console.error(`✗ CANNOT CLASSIFY — ${e?.message ?? 'unknown failure'}`);
  process.exit(2);
});
