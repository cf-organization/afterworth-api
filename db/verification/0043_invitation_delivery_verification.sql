-- 0043 verification harness — the properties ONLY a database can prove.
--
-- The vitest suite exercises the orchestrator against a modelled state machine. It cannot prove a
-- CHECK constraint, a grant, an RLS posture, or `for update skip locked`, because those are
-- Postgres behaviours and a JavaScript fake can only imitate them. This file is that half.
--
-- ⚠ RUN AGAINST A DISPOSABLE NON-PRODUCTION PROJECT ONLY, and only AFTER 0043 is applied there.
-- It creates fixture users, estates, invitations, outbox rows and an admin row. Every identifier is
-- a generated UUID and every address is @verify.test — no production estate, user, or invitation is
-- read or written. The whole script is one transaction ending in ROLLBACK, so nothing survives; but
-- the rows DO exist while it runs, and triggers and audit writes fire against them.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f db/verification/0043_invitation_delivery_verification.sql
--
-- Every assertion is a real comparison. There are no `or true` placeholders, and nothing claims a
-- property it cannot observe — where a check is structural rather than behavioural it says so
-- (see §4 on SKIP LOCKED).
--
-- COVERAGE MAP — the 14 required checks:
--   §0  migration 0043 objects exist ................................. 1
--   §1  CHECK constraints ............................................ 2
--   §2  SECURITY DEFINER, grants and revokes ......................... 4, 5
--   §3  RLS behaviour ................................................ 3
--   §4  SKIP LOCKED claiming ......................................... 6
--   §5  claim semantics: idempotent / retryPending / outcomeUncertain . 11, 12, 13
--   §6  issuance: no raw invitation token persisted .................. 10
--   §7  outcome: generation guard, provider_message_id, retry cap .... 7, 8, 9
--   §8  terminal invitations never reach the worker
--   §9  heartbeat, and its exposure on purge_outbox_health ........... 14

begin;

-- ============================================================================================
-- §0 · Migration 0043 objects exist (check 1)
-- ============================================================================================
-- Asserted explicitly rather than inferred from later use, so a partially-applied (or unapplied)
-- migration fails here naming the exact missing object, instead of failing downstream with a
-- confusing error about something else.

do $$
declare v_name text; v_count int;
begin
  foreach v_name in array array[
    'delivery_generation', 'idempotency_key', 'provider_message_id',
    'failure_class', 'next_attempt_at', 'claimed_at', 'last_outcome_at'
  ] loop
    select count(*) into v_count from information_schema.columns
     where table_schema = 'public' and table_name = 'invitation_delivery_outbox'
       and column_name = v_name;
    assert v_count = 1, '0.1 missing 0043 column: ' || v_name || ' (is 0043 applied?)';
  end loop;

  foreach v_name in array array[
    'claim_invitation_deliveries', 'issue_invitation_delivery_token',
    'record_invitation_delivery_outcome', 'invitation_delivery_health'
  ] loop
    select count(*) into v_count from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_name;
    assert v_count >= 1, '0.2 missing 0043 function: ' || v_name || ' (is 0043 applied?)';
  end loop;

  select count(*) into v_count from pg_indexes
   where schemaname = 'public' and indexname = 'invitation_delivery_outbox_claimable_idx';
  assert v_count = 1, '0.3 missing 0043 index: invitation_delivery_outbox_claimable_idx';

  -- 0042 must remain intact. 0043 supersedes issue_invitation_delivery; it must not drop it,
  -- because 0042 is applied history.
  select count(*) into v_count from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'issue_invitation_delivery';
  assert v_count = 1, '0.4 ★ 0042''s issue_invitation_delivery was dropped — 0042 must stay intact';

  raise notice '§0 PASSED — 0043 objects present, 0042 intact';
end $$;

-- ============================================================================================
-- §1 · CHECK constraints (check 2)
-- ============================================================================================

do $$
declare
  v_owner  uuid := gen_random_uuid();
  v_estate uuid := gen_random_uuid();
  v_inv    uuid;
  v_outbox uuid;
begin
  insert into auth.users (id, email) values (v_owner, 'owner1@verify.test');
  insert into public.profiles (id, email, full_name)
    values (v_owner, 'owner1@verify.test', 'Verify Owner 1') on conflict (id) do nothing;
  insert into public.estates (id, owner_id, name, status, is_primary)
    values (v_estate, v_owner, 'Verify Estate 1', 'active', true);

  insert into public.invitations
    (id, estate_id, invited_by, kind, proposed_role, status, expires_at,
     invitee_email, invitee_email_hint, estate_display_name, inviter_display_name,
     preview_visibility, token_hash, created_at, updated_at)
  values
    (gen_random_uuid(), v_estate, v_owner, 'beneficiary', 'beneficiary', 'pending',
     now() + interval '14 days', 'r1@verify.test', 'r•••@verify.test',
     'Verify Estate 1', 'Verify Owner 1',
     jsonb_build_object('showEstateName', true, 'showInviterName', true),
     encode(digest('discarded1', 'sha256'), 'hex'), now(), now())
  returning id into v_inv;

  insert into public.invitation_delivery_outbox (invitation_id, estate_id, reason, requested_by)
  values (v_inv, v_estate, 'invitation_created', v_owner)
  returning id into v_outbox;

  assert (select status from public.invitation_delivery_outbox where id = v_outbox) = 'queued',
    '1.1 a new outbox row must default to the 0043 vocabulary (queued)';
  assert (select delivery_generation from public.invitation_delivery_outbox where id = v_outbox) = 0,
    '1.2 a new row must start at generation 0 (no token ever issued)';

  -- ★ THERE IS NO `delivered`, AND NO `sent`. Nothing in this system can observe either, so
  --   neither may be representable.
  begin
    update public.invitation_delivery_outbox set status = 'delivered' where id = v_outbox;
    raise exception '1.3 FAILED: the status CHECK accepted "delivered"';
  exception when check_violation then null;
  end;

  begin
    update public.invitation_delivery_outbox set status = 'sent' where id = v_outbox;
    raise exception '1.4 FAILED: the status CHECK accepted "sent"';
  exception when check_violation then null;
  end;

  -- All seven legitimate states ARE accepted (a CHECK that rejects everything would pass the
  -- negative tests above while breaking the system).
  update public.invitation_delivery_outbox set status = 'processing'       where id = v_outbox;
  update public.invitation_delivery_outbox set status = 'providerAccepted' where id = v_outbox;
  update public.invitation_delivery_outbox set status = 'outcomeUncertain' where id = v_outbox;
  update public.invitation_delivery_outbox set status = 'retryPending'     where id = v_outbox;
  update public.invitation_delivery_outbox set status = 'failedPermanent'  where id = v_outbox;
  update public.invitation_delivery_outbox set status = 'cancelled'        where id = v_outbox;
  update public.invitation_delivery_outbox set status = 'queued'           where id = v_outbox;

  begin
    update public.invitation_delivery_outbox set failure_class = 'made_up' where id = v_outbox;
    raise exception '1.5 FAILED: the failure_class CHECK accepted an unknown value';
  exception when check_violation then null;
  end;
  update public.invitation_delivery_outbox set failure_class = 'timeout' where id = v_outbox;
  update public.invitation_delivery_outbox set failure_class = null      where id = v_outbox;

  -- 0042's reason CHECK must still hold — 0043 did not widen it.
  begin
    insert into public.invitation_delivery_outbox (invitation_id, estate_id, reason, requested_by)
    values (v_inv, v_estate, 'marketing_blast', v_owner);
    raise exception '1.6 FAILED: the reason CHECK accepted an unknown reason';
  exception when check_violation then null;
  end;

  raise notice '§1 PASSED — CHECK constraints';
end $$;

-- ============================================================================================
-- §2 · SECURITY DEFINER, grants and revokes (checks 4, 5)
-- ============================================================================================

do $$
declare v_count int; v_fn text;
begin
  foreach v_fn in array array[
    'claim_invitation_deliveries',
    'issue_invitation_delivery_token',
    'record_invitation_delivery_outcome'
  ] loop
    -- ★ WORKER-ONLY. Not authenticated, not anon, not PUBLIC.
    select count(*) into v_count
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_fn
       and (has_function_privilege('authenticated', p.oid, 'execute')
         or has_function_privilege('anon', p.oid, 'execute')
         or has_function_privilege('public', p.oid, 'execute'));
    assert v_count = 0, '2.1 ★ ' || v_fn || ' is executable by a client role';

    select count(*) into v_count
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_fn
       and has_function_privilege('service_role', p.oid, 'execute');
    assert v_count = 1, '2.2 ' || v_fn || ' is not executable by service_role';

    select count(*) into v_count
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_fn and p.prosecdef
       and exists (select 1 from unnest(coalesce(p.proconfig, array[]::text[])) c
                    where c like 'search_path=%');
    assert v_count = 1, '2.3 ' || v_fn || ' is not SECURITY DEFINER with a pinned search_path';
  end loop;

  -- The heartbeat is an operator-console read: admin-gated inside, granted to authenticated,
  -- never reachable by anon.
  select count(*) into v_count from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'invitation_delivery_health'
     and has_function_privilege('anon', p.oid, 'execute');
  assert v_count = 0, '2.4 ★ invitation_delivery_health is reachable by anon';

  raise notice '§2 PASSED — DEFINER, grants, revokes';
end $$;

-- ============================================================================================
-- §3 · RLS behaviour (check 3)
-- ============================================================================================
-- Catalog state AND an actual attempted read as `authenticated`. The catalog half alone would
-- still pass if someone granted SELECT, so the behavioural half is the one that matters.

do $$
declare v_count int;
begin
  select count(*) into v_count from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relname = 'invitation_delivery_outbox' and c.relrowsecurity;
  assert v_count = 1, '3.1 ★ RLS is not enabled on invitation_delivery_outbox';

  select count(*) into v_count from information_schema.role_table_grants
   where table_schema = 'public' and table_name = 'invitation_delivery_outbox'
     and grantee in ('authenticated', 'anon', 'PUBLIC');
  assert v_count = 0, '3.2 ★ a client role holds a table grant on invitation_delivery_outbox';

  -- Born clean: no policies at all, so even an accidental grant would expose nothing.
  select count(*) into v_count from pg_policies
   where schemaname = 'public' and tablename = 'invitation_delivery_outbox';
  assert v_count = 0, '3.3 invitation_delivery_outbox grew a policy — it should have none';

  -- The outbox must not have grown a column capable of holding a token.
  select count(*) into v_count from information_schema.columns
   where table_schema = 'public' and table_name = 'invitation_delivery_outbox'
     and column_name ilike '%token%' and column_name not ilike '%fingerprint%';
  assert v_count = 0, '3.4 ★ the outbox grew a token-shaped column';

  raise notice '§3 catalog checks PASSED';
end $$;

-- Behavioural: an authenticated session must be refused outright. Role switching goes through
-- EXECUTE so the utility statements run cleanly inside PL/pgSQL, and the role is always restored.
do $$
declare v_denied boolean := false; v_n int;
begin
  begin
    execute 'set local role authenticated';
    execute 'select count(*) from public.invitation_delivery_outbox' into v_n;
  exception when insufficient_privilege then
    v_denied := true;
  end;
  execute 'reset role';

  assert v_denied, '3.5 ★ an authenticated session could SELECT from invitation_delivery_outbox';
  raise notice '§3 PASSED — RLS behaviour';
exception when others then
  execute 'reset role';   -- never leave the session wearing another role
  raise;
end $$;

-- ============================================================================================
-- §4 · SKIP LOCKED claiming (check 6)
-- ============================================================================================
-- ★ HONEST SCOPE. Proving the race needs two concurrent transactions, and one psql session cannot
-- hold two. So this asserts the MECHANISM is present in the DEPLOYED function body — which is a
-- real check against the live definition, not a restatement of the migration file: an edit that
-- silently dropped the clause would fail here.
--
-- To observe the race itself, run this by hand in two psql sessions against the same disposable DB:
--
--   -- session A                                   -- session B
--   begin;                                         begin;
--   select * from claim_invitation_deliveries(10);
--                                                  select * from claim_invitation_deliveries(10);
--                                                  -- returns 0 rows IMMEDIATELY (does not block)
--   rollback;                                      rollback;
--
-- Session B returning at once with zero rows, rather than blocking until A finishes, is the
-- observable signature of SKIP LOCKED. Blocking would mean the clause is gone and two drains can
-- serialize into a double send.

do $$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'claim_invitation_deliveries'
   limit 1;

  assert v_def is not null, '4.1 claim_invitation_deliveries has no deployed definition';
  assert v_def ilike '%skip locked%',
    '4.2 ★ the deployed claim function does NOT use SKIP LOCKED — concurrent drains can double-send';
  assert v_def ilike '%for update%',
    '4.3 ★ the deployed claim function takes no row lock at all';

  raise notice '§4 PASSED — SKIP LOCKED present in the deployed claim function (structural)';
end $$;

-- ============================================================================================
-- §5 · Claim semantics — idempotent, retryPending, outcomeUncertain (checks 11, 12, 13)
-- ============================================================================================

do $$
declare
  v_owner  uuid := gen_random_uuid();
  v_estate uuid := gen_random_uuid();
  v_inv uuid; v_outbox uuid;
  v_count int; v_status text; v_attempts int; v_gen int; v_terminal text;
begin
  insert into auth.users (id, email) values (v_owner, 'owner5@verify.test');
  insert into public.profiles (id, email, full_name)
    values (v_owner, 'owner5@verify.test', 'Verify Owner 5') on conflict (id) do nothing;
  insert into public.estates (id, owner_id, name, status, is_primary)
    values (v_estate, v_owner, 'Verify Estate 5', 'active', true);
  insert into public.invitations
    (id, estate_id, invited_by, kind, proposed_role, status, expires_at,
     invitee_email, token_hash, created_at, updated_at)
  values
    (gen_random_uuid(), v_estate, v_owner, 'beneficiary', 'beneficiary', 'pending',
     now() + interval '14 days', 'r5@verify.test',
     encode(digest('discarded5', 'sha256'), 'hex'), now(), now())
  returning id into v_inv;

  insert into public.invitation_delivery_outbox (invitation_id, estate_id, reason, requested_by)
  values (v_inv, v_estate, 'invitation_created', v_owner)
  returning id into v_outbox;

  -- ---- claim moves to processing, bumps attempts, and MINTS NOTHING ----
  select count(*) into v_count from public.claim_invitation_deliveries(25, v_outbox);
  assert v_count = 1, '5.1 the targeted claim returned ' || v_count || ' rows, expected 1';

  select status, attempts, delivery_generation into v_status, v_attempts, v_gen
    from public.invitation_delivery_outbox where id = v_outbox;
  assert v_status = 'processing', '5.2 claim must move the row to processing, got ' || v_status;
  assert v_attempts = 1, '5.3 claim must increment attempts, got ' || v_attempts;
  assert v_gen = 0, '5.4 ★ CLAIM MUST NOT MINT — generation moved to ' || v_gen;
  assert (select claimed_at is not null from public.invitation_delivery_outbox where id = v_outbox),
    '5.5 claim must stamp claimed_at';

  -- ---- IDEMPOTENT CLAIMING (check 11): a processing row is never handed out twice ----
  select count(*) into v_count from public.claim_invitation_deliveries(25, v_outbox);
  assert v_count = 0, '5.6 ★ a processing row was re-claimed by a targeted claim';
  select count(*) into v_count from public.claim_invitation_deliveries(25);
  assert v_count = 0, '5.7 ★ a processing row was re-claimed by an untargeted drain';

  select attempts into v_attempts from public.invitation_delivery_outbox where id = v_outbox;
  assert v_attempts = 1, '5.8 a refused claim must not bump attempts, got ' || v_attempts;

  -- ---- retryPending IS claimable once due (check 13) ----
  update public.invitation_delivery_outbox
     set status = 'retryPending', next_attempt_at = now() - interval '1 minute'
   where id = v_outbox;
  select count(*) into v_count from public.claim_invitation_deliveries(25, v_outbox);
  assert v_count = 1, '5.9 ★ a DUE retryPending row was not claimable';

  -- ...and NOT claimable before it is due.
  update public.invitation_delivery_outbox
     set status = 'retryPending', next_attempt_at = now() + interval '1 hour'
   where id = v_outbox;
  select count(*) into v_count from public.claim_invitation_deliveries(25, v_outbox);
  assert v_count = 0, '5.10 a retryPending row was claimed before next_attempt_at';

  -- ---- ★ outcomeUncertain is EXCLUDED, permanently (check 12) ----
  -- This is the invariant that stops a schedule from rotating a link that may already be sitting in
  -- someone's inbox. It must hold no matter how stale next_attempt_at looks.
  update public.invitation_delivery_outbox
     set status = 'outcomeUncertain', next_attempt_at = now() - interval '30 days'
   where id = v_outbox;
  select count(*) into v_count from public.claim_invitation_deliveries(25, v_outbox);
  assert v_count = 0, '5.11 ★ AN outcomeUncertain ROW WAS CLAIMED — a live link could be rotated';
  select count(*) into v_count from public.claim_invitation_deliveries(25);
  assert v_count = 0, '5.12 ★ an outcomeUncertain row was claimed by an untargeted drain';

  -- ---- terminal states are never claimable ----
  foreach v_terminal in array array['providerAccepted', 'failedPermanent', 'cancelled'] loop
    update public.invitation_delivery_outbox
       set status = v_terminal, next_attempt_at = now() - interval '30 days' where id = v_outbox;
    select count(*) into v_count from public.claim_invitation_deliveries(25, v_outbox);
    assert v_count = 0, '5.13 a ' || v_terminal || ' row was claimed';
  end loop;

  raise notice '§5 PASSED — claim semantics';
end $$;

-- ============================================================================================
-- §6 · Issuance — no raw invitation token is ever persisted (check 10)
-- ============================================================================================

do $$
declare
  v_owner  uuid := gen_random_uuid();
  v_estate uuid := gen_random_uuid();
  v_inv uuid; v_outbox uuid;
  v_raw text; v_gen int; v_key text; v_count int;
  v_raw2 text; v_gen2 int; v_key2 text;
begin
  insert into auth.users (id, email) values (v_owner, 'owner6@verify.test');
  insert into public.profiles (id, email, full_name)
    values (v_owner, 'owner6@verify.test', 'Verify Owner 6') on conflict (id) do nothing;
  insert into public.estates (id, owner_id, name, status, is_primary)
    values (v_estate, v_owner, 'Verify Estate 6', 'active', true);
  insert into public.invitations
    (id, estate_id, invited_by, kind, proposed_role, status, expires_at,
     invitee_email, estate_display_name, inviter_display_name, preview_visibility,
     token_hash, created_at, updated_at)
  values
    (gen_random_uuid(), v_estate, v_owner, 'beneficiary', 'beneficiary', 'pending',
     now() + interval '14 days', 'r6@verify.test', 'Verify Estate 6', 'Verify Owner 6',
     jsonb_build_object('showEstateName', true, 'showInviterName', true),
     encode(digest('discarded6', 'sha256'), 'hex'), now(), now())
  returning id into v_inv;

  insert into public.invitation_delivery_outbox (invitation_id, estate_id, reason, requested_by)
  values (v_inv, v_estate, 'invitation_created', v_owner)
  returning id into v_outbox;

  -- Issue requires a CLAIMED row. An unclaimed (queued) row must be refused, or the claim step
  -- could be bypassed and two workers could both mint.
  begin
    perform public.issue_invitation_delivery_token(v_outbox);
    raise exception '6.1 FAILED: issue accepted an unclaimed (queued) row';
  exception when sqlstate 'P0002' then null;
  end;

  perform public.claim_invitation_deliveries(25, v_outbox);
  select raw_token, delivery_generation, idempotency_key into v_raw, v_gen, v_key
    from public.issue_invitation_delivery_token(v_outbox);

  assert length(v_raw) = 64, '6.2 raw token should be 64 hex chars, got ' || length(v_raw);
  assert v_gen = 1, '6.3 issue must advance the generation to 1, got ' || v_gen;
  assert v_key = 'afterworth/invitation/' || v_outbox::text || '/1',
    '6.4 idempotency key shape is wrong: ' || v_key;
  assert position('@' in v_key) = 0, '6.5 ★ the key must not contain a recipient address';
  assert position(v_raw in v_key) = 0, '6.6 ★ the key must not be derived from the raw token';

  -- ★ ONLY THE HASH IS STORED.
  select count(*) into v_count from public.invitations
   where id = v_inv and token_hash = encode(digest(v_raw, 'sha256'), 'hex');
  assert v_count = 1, '6.7 the invitation must store sha256(raw)';

  select count(*) into v_count from public.invitations where id = v_inv and token_hash = v_raw;
  assert v_count = 0, '6.8 ★ THE RAW TOKEN WAS STORED IN token_hash';

  -- ★ THE OUTBOX HOLDS NO SECRET. The whole row is cast to text, so a token in ANY column —
  --   including one a later migration adds — fails this.
  select count(*) into v_count from public.invitation_delivery_outbox o
   where o.id = v_outbox and position(v_raw in o::text) > 0;
  assert v_count = 0, '6.9 ★ THE RAW TOKEN APPEARS SOMEWHERE ON THE OUTBOX ROW';

  -- ★ NOR THE AUDIT TRAIL. write_audit writes public.audit_logs; the delivery audit carries a
  --   12-char fingerprint of the HASH, never the secret.
  select count(*) into v_count from public.audit_logs a
   where a.created_at > now() - interval '5 minutes' and position(v_raw in a::text) > 0;
  assert v_count = 0, '6.10 ★ THE RAW TOKEN APPEARS IN AN AUDIT ROW';

  select count(*) into v_count from public.audit_logs a
   where a.action = 'invitation.delivery_issued' and a.target_id = v_inv;
  assert v_count = 1, '6.11 issuance must write exactly one delivery_issued audit row';

  -- A second issue is a DELIBERATE REISSUE: new generation, new key, and the previous hash gone.
  update public.invitation_delivery_outbox set status = 'processing' where id = v_outbox;
  select raw_token, delivery_generation, idempotency_key into v_raw2, v_gen2, v_key2
    from public.issue_invitation_delivery_token(v_outbox);

  assert v_gen2 = 2, '6.12 a reissue must advance the generation to 2, got ' || v_gen2;
  assert v_key2 <> v_key, '6.13 ★ a reissue reused the previous idempotency key';
  assert v_raw2 <> v_raw, '6.14 a reissue produced the same token';

  select count(*) into v_count from public.invitations
   where id = v_inv and token_hash = encode(digest(v_raw, 'sha256'), 'hex');
  assert v_count = 0, '6.15 ★ the OLD token hash survived a reissue — the old link still works';

  raise notice '§6 PASSED — issuance and token custody';
end $$;

-- ============================================================================================
-- §7 · Outcome — generation guard, provider_message_id, retry cap (checks 7, 8, 9)
-- ============================================================================================

do $$
declare
  v_owner  uuid := gen_random_uuid();
  v_estate uuid := gen_random_uuid();
  v_inv uuid; v_outbox uuid; v_outbox2 uuid; v_outbox3 uuid; v_outbox4 uuid;
  v_status text; v_count int; v_msg text; v_class text;
begin
  insert into auth.users (id, email) values (v_owner, 'owner7@verify.test');
  insert into public.profiles (id, email, full_name)
    values (v_owner, 'owner7@verify.test', 'Verify Owner 7') on conflict (id) do nothing;
  insert into public.estates (id, owner_id, name, status, is_primary)
    values (v_estate, v_owner, 'Verify Estate 7', 'active', true);
  insert into public.invitations
    (id, estate_id, invited_by, kind, proposed_role, status, expires_at,
     invitee_email, token_hash, created_at, updated_at)
  values
    (gen_random_uuid(), v_estate, v_owner, 'beneficiary', 'beneficiary', 'pending',
     now() + interval '14 days', 'r7@verify.test',
     encode(digest('discarded7', 'sha256'), 'hex'), now(), now())
  returning id into v_inv;

  insert into public.invitation_delivery_outbox (invitation_id, estate_id, reason, requested_by)
  values (v_inv, v_estate, 'invitation_created', v_owner)
  returning id into v_outbox;

  perform public.claim_invitation_deliveries(25, v_outbox);
  perform public.issue_invitation_delivery_token(v_outbox);   -- now generation 1

  -- An invented outcome is rejected outright.
  begin
    perform public.record_invitation_delivery_outcome(v_outbox, 1, 'delivered', null, null);
    raise exception '7.1 FAILED: the outcome function accepted "delivered"';
  exception when sqlstate 'P0001' then null;
  end;

  -- ★ GENERATION GUARD (check 8): a worker whose generation has been superseded cannot stamp its
  --   stale verdict onto the current one.
  select status into v_status
    from public.record_invitation_delivery_outcome(v_outbox, 0, 'providerAccepted', 'msg_stale', null);
  assert v_status = 'processing', '7.2 ★ a stale generation was not a no-op; status became ' || v_status;
  select provider_message_id into v_msg from public.invitation_delivery_outbox where id = v_outbox;
  assert v_msg is null, '7.3 ★ a stale generation wrote a provider_message_id';

  -- ★ provider_message_id HANDLING (check 9): recorded only on acceptance.
  select status into v_status
    from public.record_invitation_delivery_outcome(v_outbox, 1, 'providerAccepted', 'msg_real', null);
  assert v_status = 'providerAccepted', '7.4 expected providerAccepted, got ' || v_status;

  select provider_message_id, failure_class into v_msg, v_class
    from public.invitation_delivery_outbox where id = v_outbox;
  assert v_msg = 'msg_real', '7.5 provider_message_id was not recorded on acceptance';
  assert v_class is null, '7.6 failure_class must be null on acceptance, got ' || coalesce(v_class, '<null>');
  assert (select issued_at is not null from public.invitation_delivery_outbox where id = v_outbox),
    '7.7 issued_at must be stamped on acceptance';

  -- A settled row absorbs a duplicate result rather than regressing into a re-send.
  select status into v_status
    from public.record_invitation_delivery_outcome(v_outbox, 1, 'retryPending', null, 'timeout');
  assert v_status = 'providerAccepted', '7.8 an accepted row regressed to ' || v_status;

  -- provider_message_id must NOT be recorded for a non-accepted outcome.
  insert into public.invitation_delivery_outbox (invitation_id, estate_id, reason, requested_by)
  values (v_inv, v_estate, 'invitation_redelivery', v_owner) returning id into v_outbox2;
  perform public.claim_invitation_deliveries(25, v_outbox2);
  perform public.issue_invitation_delivery_token(v_outbox2);
  perform public.record_invitation_delivery_outcome(
    v_outbox2, 1, 'retryPending', 'msg_should_be_ignored', 'provider_unavailable');

  select provider_message_id, failure_class into v_msg, v_class
    from public.invitation_delivery_outbox where id = v_outbox2;
  assert v_msg is null, '7.9 ★ a provider_message_id was recorded for a NON-accepted outcome';
  assert v_class = 'provider_unavailable',
    '7.10 failure_class was not recorded, got ' || coalesce(v_class, '<null>');
  assert (select last_error from public.invitation_delivery_outbox where id = v_outbox2) = 'provider_unavailable',
    '7.11 last_error must hold the sanitized class, never raw provider text';

  -- ★ RETRY CAP (check 7). A fresh row already at the ceiling-1 is driven over.
  insert into public.invitation_delivery_outbox (invitation_id, estate_id, reason, requested_by, attempts)
  values (v_inv, v_estate, 'invitation_redelivery', v_owner, 4) returning id into v_outbox3;

  perform public.claim_invitation_deliveries(25, v_outbox3);   -- attempts 4 -> 5 (the cap)
  select status into v_status
    from public.record_invitation_delivery_outcome(v_outbox3, 0, 'retryPending', null, 'provider_unavailable');
  assert v_status = 'failedPermanent',
    '7.12 ★ at the attempt cap a retry must become failedPermanent, got ' || v_status;
  assert (select next_attempt_at is null from public.invitation_delivery_outbox where id = v_outbox3),
    '7.13 a failedPermanent row must not carry a next_attempt_at';

  select count(*) into v_count from public.claim_invitation_deliveries(25, v_outbox3);
  assert v_count = 0, '7.14 a failedPermanent row was re-claimed';

  -- Below the cap, a retry stays retryPending and is scheduled forward.
  insert into public.invitation_delivery_outbox (invitation_id, estate_id, reason, requested_by)
  values (v_inv, v_estate, 'invitation_redelivery', v_owner) returning id into v_outbox4;
  perform public.claim_invitation_deliveries(25, v_outbox4);   -- attempts -> 1
  select status into v_status
    from public.record_invitation_delivery_outcome(v_outbox4, 0, 'retryPending', null, 'rate_limited');
  assert v_status = 'retryPending', '7.15 below the cap a retry must stay retryPending, got ' || v_status;
  assert (select next_attempt_at > now() from public.invitation_delivery_outbox where id = v_outbox4),
    '7.16 a retryPending row must be scheduled into the future';

  raise notice '§7 PASSED — generation guard, provider_message_id, retry cap';
end $$;

-- ============================================================================================
-- §8 · Terminal invitations never reach the worker
-- ============================================================================================

do $$
declare
  v_owner  uuid := gen_random_uuid();
  v_estate uuid := gen_random_uuid();
  v_inv uuid; v_outbox uuid; v_count int; v_status text; v_terminal text;
begin
  insert into auth.users (id, email) values (v_owner, 'owner8@verify.test');
  insert into public.profiles (id, email, full_name)
    values (v_owner, 'owner8@verify.test', 'Verify Owner 8') on conflict (id) do nothing;
  insert into public.estates (id, owner_id, name, status, is_primary)
    values (v_estate, v_owner, 'Verify Estate 8', 'active', true);
  insert into public.invitations
    (id, estate_id, invited_by, kind, proposed_role, status, expires_at,
     invitee_email, token_hash, created_at, updated_at)
  values
    (gen_random_uuid(), v_estate, v_owner, 'beneficiary', 'beneficiary', 'pending',
     now() + interval '14 days', 'r8@verify.test',
     encode(digest('discarded8', 'sha256'), 'hex'), now(), now())
  returning id into v_inv;

  foreach v_terminal in array array['revoked', 'accepted', 'declined'] loop
    update public.invitations set status = v_terminal where id = v_inv;
    insert into public.invitation_delivery_outbox (invitation_id, estate_id, reason, requested_by)
    values (v_inv, v_estate, 'invitation_redelivery', v_owner) returning id into v_outbox;

    select count(*) into v_count from public.claim_invitation_deliveries(25, v_outbox);
    assert v_count = 0, '8.1 a ' || v_terminal || ' invitation was handed to the worker';
    select status into v_status from public.invitation_delivery_outbox where id = v_outbox;
    assert v_status = 'cancelled',
      '8.2 a ' || v_terminal || ' invitation''s row should be cancelled, got ' || v_status;
  end loop;

  -- Expired BY TIME, not by stored status. 0042's table header warns that `expired` is both a
  -- stored value and a read-time derivation, and both must be honoured.
  update public.invitations set status = 'pending', expires_at = now() - interval '1 day'
   where id = v_inv;
  insert into public.invitation_delivery_outbox (invitation_id, estate_id, reason, requested_by)
  values (v_inv, v_estate, 'invitation_redelivery', v_owner) returning id into v_outbox;

  select count(*) into v_count from public.claim_invitation_deliveries(25, v_outbox);
  assert v_count = 0, '8.3 ★ an expired-by-time invitation was handed to the worker';
  select status into v_status from public.invitation_delivery_outbox where id = v_outbox;
  assert v_status = 'cancelled', '8.4 expired-by-time row should be cancelled, got ' || v_status;

  -- And no token was minted for any of them.
  select count(*) into v_count from public.audit_logs
   where action = 'invitation.delivery_issued' and target_id = v_inv;
  assert v_count = 0, '8.5 ★ a token was issued for a terminal invitation';

  raise notice '§8 PASSED — terminal invitations';
end $$;

-- ============================================================================================
-- §9 · Heartbeat, and its exposure on purge_outbox_health (check 14)
-- ============================================================================================
-- Both functions run admin_require_gate(), which reads auth.uid() / auth.jwt(). A plain psql
-- session has neither, so a request context is simulated for this section only and cleared
-- immediately afterwards. The gate itself is real and unmodified — §2 proves anon cannot reach
-- these functions at all.

do $$
declare
  v_admin uuid := gen_random_uuid();
  v_health jsonb; v_purge jsonb;
begin
  insert into auth.users (id, email) values (v_admin, 'admin9@verify.test');
  insert into public.profiles (id, email, full_name)
    values (v_admin, 'admin9@verify.test', 'Verify Admin') on conflict (id) do nothing;
  insert into public.admins (user_id) values (v_admin) on conflict do nothing;

  perform set_config('request.jwt.claims', json_build_object(
    'sub',  v_admin::text,
    'role', 'authenticated',
    'aal',  'aal2',
    'iat',  extract(epoch from now())::bigint
  )::text, true);   -- true = local to this transaction

  select public.invitation_delivery_health() into v_health;

  assert v_health ? 'queued_count',               '9.1 heartbeat is missing queued_count';
  assert v_health ? 'processing_count',           '9.2 heartbeat is missing processing_count';
  assert v_health ? 'retry_pending_count',        '9.3 heartbeat is missing retry_pending_count';
  assert v_health ? 'outcome_uncertain_count',    '9.4 heartbeat is missing outcome_uncertain_count';
  assert v_health ? 'failed_permanent_count',     '9.5 heartbeat is missing failed_permanent_count';
  assert v_health ? 'oldest_pending_age_seconds', '9.6 heartbeat is missing oldest_pending_age_seconds';
  assert not (v_health ? 'delivered_count'),      '9.7 ★ the heartbeat invented a delivered count';

  -- ★ COUNTS AND AGES ONLY. Asserted against the serialized payload, so a future key cannot
  --   smuggle an identifier in unnoticed.
  assert position('@' in v_health::text) = 0,           '9.8 ★ an email address reached the heartbeat';
  assert position('verify.test' in v_health::text) = 0, '9.9 ★ a fixture domain reached the heartbeat';
  assert position('msg_real' in v_health::text) = 0,    '9.10 ★ a provider message id reached the heartbeat';
  assert v_health::text !~ '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
    '9.11 ★ a UUID reached the heartbeat';
  assert v_health::text !~ 'afterworth/invitation/', '9.12 ★ an idempotency key reached the heartbeat';

  -- Surfaced ADDITIVELY on the existing operational heartbeat, without losing a prior key.
  select public.purge_outbox_health() into v_purge;
  assert v_purge ? 'invitation_delivery',        '9.13 purge_outbox_health lost the invitation_delivery key';
  assert v_purge ? 'orphan_candidate_count',     '9.14 purge_outbox_health lost a pre-existing key';
  assert v_purge ? 'oldest_pending_age_seconds', '9.15 purge_outbox_health lost oldest_pending_age_seconds';
  assert (v_purge -> 'invitation_delivery') ? 'oldest_pending_age_seconds',
    '9.16 the embedded invitation heartbeat is missing oldest_pending_age_seconds';
  assert position('@' in v_purge::text) = 0, '9.17 ★ an email address reached purge_outbox_health';

  perform set_config('request.jwt.claims', '', true);
  raise notice '§9 PASSED — heartbeat';
exception when others then
  perform set_config('request.jwt.claims', '', true);
  raise;
end $$;

-- ============================================================================================
-- Nothing above survives. Every fixture existed only inside this transaction.
-- ============================================================================================

rollback;
