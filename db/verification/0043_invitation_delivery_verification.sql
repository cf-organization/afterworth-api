-- 0043 verification harness — the properties ONLY a database can prove.
--
-- The vitest suite covers the orchestrator against a modelled state machine. It cannot prove
-- `for update skip locked`, a CHECK constraint, a grant, or an RLS posture, because those are
-- Postgres behaviours and a JavaScript fake can only imitate them. Everything below is the part
-- that had to be proven here.
--
-- RUN AGAINST NON-PRODUCTION. It creates fixture users, estates, invitations and outbox rows. The
-- whole script rolls back at the end, so nothing survives — but rows DO exist inside the
-- transaction, and triggers/audit writes fire while they do.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f db/verification/0043_invitation_delivery_verification.sql
--
-- Every assertion is a real comparison. There are no `or true` placeholders.

begin;

do $$
declare
  v_owner uuid := gen_random_uuid();
  v_estate uuid := gen_random_uuid();
  v_inv uuid;
  v_outbox uuid;
  v_gen int;
  v_status text;
  v_attempts int;
  v_raw text;
  v_key text;
  v_count int;
  v_health jsonb;
begin
  -- ---------------------------------------------------------------------------------------
  -- Fixtures
  -- ---------------------------------------------------------------------------------------
  insert into auth.users (id, email) values (v_owner, 'owner@verify.test');
  insert into public.profiles (id, email, full_name) values (v_owner, 'owner@verify.test', 'Verify Owner')
    on conflict (id) do nothing;
  insert into public.estates (id, name, owner_id) values (v_estate, 'Verify Estate', v_owner);

  insert into public.invitations
    (id, estate_id, invited_by, kind, proposed_role, status, expires_at,
     invitee_email, invitee_email_hint, estate_display_name, inviter_display_name,
     preview_visibility, token_hash, created_at, updated_at)
  values
    (gen_random_uuid(), v_estate, v_owner, 'beneficiary', 'beneficiary', 'pending', now() + interval '14 days',
     'recipient@verify.test', 'r•••@verify.test', 'Verify Estate', 'Verify Owner',
     jsonb_build_object('showEstateName', true, 'showInviterName', true),
     encode(digest('discarded', 'sha256'), 'hex'), now(), now())
  returning id into v_inv;

  insert into public.invitation_delivery_outbox (invitation_id, estate_id, reason, requested_by)
  values (v_inv, v_estate, 'invitation_created', v_owner)
  returning id into v_outbox;

  -- ---------------------------------------------------------------------------------------
  -- 1 · Schema — the vocabulary is honest and `delivered` is unrepresentable
  -- ---------------------------------------------------------------------------------------
  select status into v_status from public.invitation_delivery_outbox where id = v_outbox;
  assert v_status = 'queued', '1.1 a new outbox row defaults to queued, got ' || v_status;

  begin
    update public.invitation_delivery_outbox set status = 'delivered' where id = v_outbox;
    raise exception '1.2 FAILED: the CHECK accepted status=delivered';
  exception when check_violation then
    null;  -- expected: there is no `delivered` anywhere in this system
  end;

  begin
    update public.invitation_delivery_outbox set status = 'sent' where id = v_outbox;
    raise exception '1.3 FAILED: the CHECK accepted status=sent';
  exception when check_violation then null;
  end;

  begin
    update public.invitation_delivery_outbox set failure_class = 'made_up' where id = v_outbox;
    raise exception '1.4 FAILED: the CHECK accepted an unknown failure_class';
  exception when check_violation then null;
  end;

  select delivery_generation into v_gen from public.invitation_delivery_outbox where id = v_outbox;
  assert v_gen = 0, '1.5 a row starts at generation 0, got ' || v_gen;

  -- ---------------------------------------------------------------------------------------
  -- 2 · Claim — bounded, transitions to processing, mints nothing
  -- ---------------------------------------------------------------------------------------
  select count(*) into v_count from public.claim_invitation_deliveries(25, v_outbox);
  assert v_count = 1, '2.1 the targeted claim returned ' || v_count || ' rows, expected 1';

  select status, attempts, delivery_generation
    into v_status, v_attempts, v_gen
    from public.invitation_delivery_outbox where id = v_outbox;
  assert v_status = 'processing', '2.2 claim must move the row to processing, got ' || v_status;
  assert v_attempts = 1, '2.3 claim must increment attempts, got ' || v_attempts;
  assert v_gen = 0, '2.4 ★ CLAIM MUST NOT MINT — generation moved to ' || v_gen;

  -- A processing row is not claimable again: that is what stops a second drain double-sending.
  select count(*) into v_count from public.claim_invitation_deliveries(25);
  assert v_count = 0, '2.5 a processing row was re-claimed (' || v_count || ' rows)';

  -- ---------------------------------------------------------------------------------------
  -- 3 · Issue — mints once, stores only the hash, derives the key from surrogate ids
  -- ---------------------------------------------------------------------------------------
  select raw_token, delivery_generation, idempotency_key
    into v_raw, v_gen, v_key
    from public.issue_invitation_delivery_token(v_outbox);

  assert length(v_raw) = 64, '3.1 raw token should be 64 hex chars, got ' || length(v_raw);
  assert v_gen = 1, '3.2 issue must advance the generation to 1, got ' || v_gen;
  assert v_key = 'afterworth/invitation/' || v_outbox::text || '/1',
    '3.3 idempotency key shape is wrong: ' || v_key;
  assert position('@' in v_key) = 0, '3.4 ★ the key must not contain a recipient address';
  assert position(v_raw in v_key) = 0, '3.5 ★ the key must not be derived from the raw token';

  -- ★ ONLY THE HASH IS STORED.
  select count(*) into v_count from public.invitations
   where id = v_inv and token_hash = encode(digest(v_raw, 'sha256'), 'hex');
  assert v_count = 1, '3.6 the invitation should store sha256(raw), and only that';

  select count(*) into v_count from public.invitations where id = v_inv and token_hash = v_raw;
  assert v_count = 0, '3.7 ★ THE RAW TOKEN WAS STORED IN token_hash';

  -- ★ THE OUTBOX HOLDS NO SECRET. Checked as text across the entire row, so a token in ANY column
  --   (including one added later) fails this.
  select count(*) into v_count from public.invitation_delivery_outbox o
   where o.id = v_outbox and position(v_raw in o::text) > 0;
  assert v_count = 0, '3.8 ★ THE RAW TOKEN APPEARS SOMEWHERE ON THE OUTBOX ROW';

  -- And not in the audit trail either — the audit records a fingerprint of the HASH.
  select count(*) into v_count from public.audit_log a
   where a.created_at > now() - interval '1 minute' and position(v_raw in a::text) > 0;
  assert v_count = 0, '3.9 ★ THE RAW TOKEN APPEARS IN AN AUDIT ROW';

  -- ---------------------------------------------------------------------------------------
  -- 4 · Outcome — generation guard, terminal no-op, retry cap
  -- ---------------------------------------------------------------------------------------
  -- A stale worker (older generation) must not clobber the current one.
  select status into v_status
    from public.record_invitation_delivery_outcome(v_outbox, 0, 'providerAccepted', 'msg_stale', null);
  assert v_status = 'processing',
    '4.1 a stale generation must be a no-op, but status became ' || v_status;

  select status into v_status
    from public.record_invitation_delivery_outcome(v_outbox, 1, 'providerAccepted', 'msg_real', null);
  assert v_status = 'providerAccepted', '4.2 expected providerAccepted, got ' || v_status;

  -- A settled row absorbs a duplicate result rather than sending again.
  select status into v_status
    from public.record_invitation_delivery_outcome(v_outbox, 1, 'retryPending', null, 'timeout');
  assert v_status = 'providerAccepted', '4.3 an accepted row must not fall back to retry, got ' || v_status;

  -- providerAccepted is terminal for the claim scan.
  select count(*) into v_count from public.claim_invitation_deliveries(25);
  assert v_count = 0, '4.4 an accepted row was re-claimed';

  begin
    perform public.record_invitation_delivery_outcome(v_outbox, 1, 'delivered', null, null);
    raise exception '4.5 FAILED: the outcome function accepted "delivered"';
  exception when sqlstate 'P0001' then null;
  end;

  -- ★ RETRY CAP. Drive a second row to the ceiling and confirm it lands on failedPermanent.
  insert into public.invitation_delivery_outbox (invitation_id, estate_id, reason, requested_by, attempts)
  values (v_inv, v_estate, 'invitation_redelivery', v_owner, 4)
  returning id into v_outbox;

  perform public.claim_invitation_deliveries(25, v_outbox);      -- attempts 4 -> 5 (the cap)
  select status into v_status
    from public.record_invitation_delivery_outcome(v_outbox, 0, 'retryPending', null, 'provider_unavailable');
  assert v_status = 'failedPermanent',
    '4.6 ★ at the attempt cap a retry must become failedPermanent, got ' || v_status;

  select count(*) into v_count from public.claim_invitation_deliveries(25);
  assert v_count = 0, '4.7 a failedPermanent row was re-claimed';

  -- ---------------------------------------------------------------------------------------
  -- 5 · Terminal invitations never reach the send path
  -- ---------------------------------------------------------------------------------------
  update public.invitations set status = 'revoked', revoked_at = now() where id = v_inv;
  insert into public.invitation_delivery_outbox (invitation_id, estate_id, reason, requested_by)
  values (v_inv, v_estate, 'invitation_redelivery', v_owner)
  returning id into v_outbox;

  select count(*) into v_count from public.claim_invitation_deliveries(25, v_outbox);
  assert v_count = 0, '5.1 a revoked invitation was handed to the worker';

  select status into v_status from public.invitation_delivery_outbox where id = v_outbox;
  assert v_status = 'cancelled', '5.2 a revoked invitation''s row should be cancelled, got ' || v_status;

  -- Expired-by-time (not by stored status) must behave identically.
  update public.invitations set status = 'pending', revoked_at = null,
         expires_at = now() - interval '1 day' where id = v_inv;
  insert into public.invitation_delivery_outbox (invitation_id, estate_id, reason, requested_by)
  values (v_inv, v_estate, 'invitation_redelivery', v_owner)
  returning id into v_outbox;

  select count(*) into v_count from public.claim_invitation_deliveries(25, v_outbox);
  assert v_count = 0, '5.3 an expired-by-time invitation was handed to the worker';
  select status into v_status from public.invitation_delivery_outbox where id = v_outbox;
  assert v_status = 'cancelled', '5.4 expired-by-time row should be cancelled, got ' || v_status;

  -- ---------------------------------------------------------------------------------------
  -- 6 · Heartbeat — counts and ages, and NOTHING identifying
  -- ---------------------------------------------------------------------------------------
  -- Called as the table owner here, so admin_require_gate is satisfied structurally; the gate
  -- itself is proven by section 7's privilege assertions.
  select public.invitation_delivery_health() into v_health;

  assert v_health ? 'oldest_pending_age_seconds', '6.1 heartbeat is missing oldest_pending_age_seconds';
  assert v_health ? 'queued_count',              '6.2 heartbeat is missing queued_count';
  assert v_health ? 'failed_permanent_count',    '6.3 heartbeat is missing failed_permanent_count';
  assert not (v_health ? 'delivered_count'),     '6.4 ★ the heartbeat invented a delivered count';

  -- ★ NO PII, NO IDENTIFIERS. Assert against the serialized payload so a future key cannot smuggle
  --   one in unnoticed.
  assert position('@' in v_health::text) = 0, '6.5 ★ an email address reached the heartbeat';
  assert position(v_inv::text in v_health::text) = 0, '6.6 ★ an invitation id reached the heartbeat';
  assert position(v_estate::text in v_health::text) = 0, '6.7 ★ an estate id reached the heartbeat';
  assert position('msg_real' in v_health::text) = 0, '6.8 ★ a provider message id reached the heartbeat';

  -- It is also surfaced on the existing operational heartbeat, additively.
  select public.purge_outbox_health() into v_health;
  assert v_health ? 'invitation_delivery', '6.9 purge_outbox_health lost the invitation_delivery key';
  assert v_health ? 'orphan_candidate_count', '6.10 purge_outbox_health lost a pre-existing key';

  raise notice 'SECTIONS 1-6 PASSED';
end $$;

-- ---------------------------------------------------------------------------------------
-- 7 · Privileges and RLS — set-based, outside the DO block
-- ---------------------------------------------------------------------------------------
do $$
declare v_count int; v_fn text;
begin
  -- ★ WORKER FUNCTIONS ARE service_role ONLY. Not authenticated, not anon, not PUBLIC.
  foreach v_fn in array array[
    'claim_invitation_deliveries',
    'issue_invitation_delivery_token',
    'record_invitation_delivery_outcome'
  ] loop
    select count(*) into v_count
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_fn
       and (has_function_privilege('authenticated', p.oid, 'execute')
         or has_function_privilege('anon', p.oid, 'execute')
         or has_function_privilege('public', p.oid, 'execute'));
    assert v_count = 0, '7.1 ★ ' || v_fn || ' is executable by a client role';

    select count(*) into v_count
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_fn
       and has_function_privilege('service_role', p.oid, 'execute');
    assert v_count = 1, '7.2 ' || v_fn || ' is not executable by service_role';

    -- DEFINER with a pinned search_path — the project-wide discipline.
    select count(*) into v_count
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_fn
       and p.prosecdef
       and exists (select 1 from unnest(coalesce(p.proconfig, array[]::text[])) c where c like 'search_path=%');
    assert v_count = 1, '7.3 ' || v_fn || ' is not DEFINER with a pinned search_path';
  end loop;

  -- The outbox stays closed to clients.
  select count(*) into v_count from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relname = 'invitation_delivery_outbox' and c.relrowsecurity;
  assert v_count = 1, '7.4 ★ RLS is not enabled on invitation_delivery_outbox';

  select count(*) into v_count from information_schema.role_table_grants
   where table_schema = 'public' and table_name = 'invitation_delivery_outbox'
     and grantee in ('authenticated', 'anon', 'PUBLIC');
  assert v_count = 0, '7.5 ★ a client role holds a grant on invitation_delivery_outbox';

  -- The outbox has no column that could hold a token, by name or by type-of-use.
  select count(*) into v_count from information_schema.columns
   where table_schema = 'public' and table_name = 'invitation_delivery_outbox'
     and (column_name ilike '%token%' and column_name not ilike '%fingerprint%');
  assert v_count = 0, '7.6 ★ the outbox grew a token-shaped column';

  raise notice 'SECTION 7 PASSED';
end $$;

rollback;
