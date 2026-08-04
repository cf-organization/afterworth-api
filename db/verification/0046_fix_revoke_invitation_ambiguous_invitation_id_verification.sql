-- 0046 verification harness — revoke actually runs, and nothing else moved.
--
-- 0046 is a two-line fix (alias the outbox, qualify both predicates) to a function that raised
-- SQLSTATE 42702 on EVERY legitimate owner revoke. As with 0045, a two-line fix still has to prove
-- two separate things: that the ambiguity is gone, and that fixing it changed nothing else —
-- signature, posture, grants, status transitions, outbox cancellation, audit, or return shape.
--
-- ⚠ RUN AGAINST A DISPOSABLE NON-PRODUCTION PROJECT ONLY, and only AFTER 0046 is applied there.
-- Every identifier is a generated UUID and every address is @verify.test. The whole script is one
-- transaction ending in ROLLBACK, so nothing survives — but the rows DO exist while it runs, and
-- triggers and audit writes fire against them.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f db/verification/0046_fix_revoke_invitation_ambiguous_invitation_id_verification.sql
--
-- ★ The function is SECURITY DEFINER and reads auth.uid(), so the harness sets a request JWT claim
-- to act as the fixture owner. Without it every call would fail the owner gate and §2 onward would
-- prove nothing. Test-harness concern only.
--
-- ★ EVERY COUNT IS SCOPED to the fixture estate or invitation. An unscoped outbox count would
-- observe unrelated rows and pass for the wrong reason.
--
-- COVERAGE MAP — the 22 required checks:
--   §0  exists, signature, DEFINER, search_path, grants ............... 1, 2, 3, 4, 5
--   §1  non-owner fails the owner gate ................................ 6
--   §2  ★ valid owner revoke no longer raises 42702 ................... 7
--   §3  status/revoked_at transition and returned tuple ............... 8, 9, 10, 11, 12
--   §4  outbox cancellation, scoped; unrelated rows untouched ......... 13, 14
--   §5  terminal-status behaviour (accepted/declined/revoked/expired) . 15, 16, 17, 18
--   §6  audit row ..................................................... 19
--   §7  no membership, no new delivery row created by revoke .......... 20, 21
--   §8  rollback removes every fixture ................................ 22

begin;

-- ============================================================================================
-- §0 · Identity and posture (checks 1–5)
-- ============================================================================================

do $$
declare
  v_oid oid; v_sig text; v_secdef boolean; v_config text[]; v_acl text;
begin
  select p.oid, pg_get_function_identity_arguments(p.oid), p.prosecdef, p.proconfig,
         coalesce(array_to_string(p.proacl, ','), '')
    into v_oid, v_sig, v_secdef, v_config, v_acl
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'revoke_estate_invitation';

  assert v_oid is not null, '0.1 revoke_estate_invitation is missing (is 0046 applied?)';
  assert v_sig = 'p_estate uuid, p_invitation uuid',
    '0.2 signature changed — 0046 must not alter the contract. Got: ' || v_sig;
  assert v_secdef, '0.3 SECURITY DEFINER was lost — the owner gate depends on it';
  assert array_to_string(v_config, ',') like '%search_path=public, extensions%',
    '0.4 search_path is no longer pinned. Got: ' || coalesce(array_to_string(v_config, ','), '(null)');
  assert v_acl like '%authenticated=X%', '0.5 authenticated lost EXECUTE. ACL: ' || v_acl;
  assert v_acl not like '%anon=X%', '0.5 anon must NOT hold EXECUTE. ACL: ' || v_acl;

  -- ★ The fix itself, asserted on the DEPLOYED definition rather than on the file.
  assert pg_get_functiondef(v_oid) like '%ob.invitation_id%',
    '0.6 ★ the outbox predicate is not alias-qualified — 0046 is not applied';
  assert pg_get_functiondef(v_oid) like '%ob.status%',
    '0.7 ★ the outbox status predicate is not alias-qualified';

  raise notice '§0 PASSED — signature, DEFINER, search_path, grants unchanged; fix present';
end $$;

-- ============================================================================================
-- §1 · Owner gate (check 6)  ·  §2 · ★ THE REGRESSION (check 7)
-- ============================================================================================

do $$
declare
  v_owner    uuid := gen_random_uuid();
  v_stranger uuid := gen_random_uuid();
  v_estate   uuid := gen_random_uuid();
  v_inv      uuid := gen_random_uuid();
  v_sqlstate text;
  r_id uuid; r_status text; r_revoked timestamptz;
begin
  insert into auth.users (id, email) values (v_owner, 'owner46a@verify.test');
  insert into auth.users (id, email) values (v_stranger, 'stranger46@verify.test');
  insert into public.profiles (id, email, full_name)
    values (v_owner, 'owner46a@verify.test', 'Verify Owner 46A') on conflict (id) do nothing;
  insert into public.profiles (id, email, full_name)
    values (v_stranger, 'stranger46@verify.test', 'Verify Stranger 46') on conflict (id) do nothing;
  insert into public.estates (id, owner_id, name, status, is_primary)
    values (v_estate, v_owner, 'Verify Estate 46A', 'active', true);

  insert into public.invitations
    (id, estate_id, invited_by, kind, proposed_role, status, expires_at,
     invitee_email, invitee_email_hint, preview_visibility, token_hash, created_at, updated_at)
  values
    (v_inv, v_estate, v_owner, 'beneficiary', 'beneficiary', 'pending',
     now() + interval '14 days', 'r46a@verify.test', 'r•••@verify.test',
     '{}'::jsonb, encode(digest('discarded46a', 'sha256'), 'hex'), now(), now());

  -- 6 · a non-owner is refused by the gate, NOT by the ambiguity.
  perform set_config('request.jwt.claims', json_build_object('sub', v_stranger::text)::text, true);
  begin
    perform public.revoke_estate_invitation(v_estate, v_inv);
    assert false, '1.1 a non-owner must be rejected';
  exception when others then
    get stacked diagnostics v_sqlstate = returned_sqlstate;
    assert v_sqlstate <> '42702', '1.2 ★ non-owner path still hits the ambiguity (42702)';
    assert v_sqlstate in ('42501', 'P0001', 'P0002'),
      '1.3 non-owner must fail the owner gate, got ' || v_sqlstate;
  end;

  -- 7 · ★ the owner revoke. Before 0046 this raised 42702 unconditionally.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  select invitation_id, status, revoked_at into r_id, r_status, r_revoked
  from public.revoke_estate_invitation(v_estate, v_inv);

  -- 10/11/12 · the returned tuple agrees with the stored row.
  assert r_id = v_inv, '2.1 returned invitation_id must equal the revoked invitation';
  assert r_status = 'revoked', '2.2 returned status must be revoked, got ' || coalesce(r_status,'(null)');
  assert r_revoked is not null, '2.3 returned revoked_at must be populated';

  -- 8/9 · the stored transition.
  assert (select status from public.invitations where id = v_inv) = 'revoked',
    '2.4 stored status must be revoked';
  assert (select revoked_at from public.invitations where id = v_inv) is not null,
    '2.5 stored revoked_at must be populated';

  raise notice '§1–2 PASSED — ★ 42702 is gone; owner gate intact; transition correct';
end $$;

-- ============================================================================================
-- §4 · Outbox cancellation, scoped (checks 13, 14)
-- ============================================================================================

do $$
declare
  v_owner  uuid := gen_random_uuid();
  v_estate uuid := gen_random_uuid();
  v_inv    uuid := gen_random_uuid();
  v_other  uuid := gen_random_uuid();
  v_ob     uuid; v_ob_other uuid;
begin
  insert into auth.users (id, email) values (v_owner, 'owner46b@verify.test');
  insert into public.profiles (id, email, full_name)
    values (v_owner, 'owner46b@verify.test', 'Verify Owner 46B') on conflict (id) do nothing;
  insert into public.estates (id, owner_id, name, status, is_primary)
    values (v_estate, v_owner, 'Verify Estate 46B', 'active', true);

  -- The invitation under test, plus an UNRELATED invitation on the same estate. The second exists
  -- purely to prove the cancellation is scoped to one invitation and not to the whole estate.
  insert into public.invitations
    (id, estate_id, invited_by, kind, proposed_role, status, expires_at,
     invitee_email, invitee_email_hint, preview_visibility, token_hash, created_at, updated_at)
  values
    (v_inv,   v_estate, v_owner, 'beneficiary', 'beneficiary', 'pending', now() + interval '14 days',
     'r46b@verify.test', 'r•••@verify.test', '{}'::jsonb, encode(digest('d46b','sha256'),'hex'), now(), now()),
    (v_other, v_estate, v_owner, 'beneficiary', 'professional_delegate', 'pending', now() + interval '14 days',
     'r46c@verify.test', 'r•••@verify.test', '{}'::jsonb, encode(digest('d46c','sha256'),'hex'), now(), now());

  insert into public.invitation_delivery_outbox (invitation_id, estate_id, reason, requested_by)
    values (v_inv, v_estate, 'invitation_created', v_owner) returning id into v_ob;
  insert into public.invitation_delivery_outbox (invitation_id, estate_id, reason, requested_by)
    values (v_other, v_estate, 'invitation_created', v_owner) returning id into v_ob_other;

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform public.revoke_estate_invitation(v_estate, v_inv);

  -- 13 · the revoked invitation's queued delivery is cancelled.
  assert (select status from public.invitation_delivery_outbox where id = v_ob) = 'failed',
    '4.1 a queued delivery for the revoked invitation must be cancelled';
  assert (select last_error from public.invitation_delivery_outbox where id = v_ob) = 'invitation_revoked',
    '4.2 the cancellation reason must be recorded';

  -- 14 · ★ the UNRELATED invitation's delivery is untouched. This is what the qualified predicate
  --      protects: a mis-scoped UPDATE would cancel every queued email on the estate.
  assert (select status from public.invitation_delivery_outbox where id = v_ob_other) = 'queued',
    '4.3 ★ an unrelated invitation''s queued delivery must NOT be cancelled';

  -- 21 · revoke inserts NO new delivery row — it sends no email.
  assert (select count(*) from public.invitation_delivery_outbox where invitation_id = v_inv) = 1,
    '4.4 revoke must not create an additional delivery row';

  raise notice '§4 PASSED — cancellation is scoped to the revoked invitation only';
end $$;

-- ============================================================================================
-- §5 · Terminal-status behaviour (checks 15–18)
-- ============================================================================================

do $$
declare
  v_owner  uuid := gen_random_uuid();
  v_estate uuid := gen_random_uuid();
  v_term   text;
  v_id     uuid;
  v_sqlstate text;
  r_status text;
begin
  insert into auth.users (id, email) values (v_owner, 'owner46c@verify.test');
  insert into public.profiles (id, email, full_name)
    values (v_owner, 'owner46c@verify.test', 'Verify Owner 46C') on conflict (id) do nothing;
  insert into public.estates (id, owner_id, name, status, is_primary)
    values (v_estate, v_owner, 'Verify Estate 46C', 'active', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);

  -- 15/16/18 · accepted, declined and expired are NOT actionable.
  foreach v_term in array array['accepted', 'declined'] loop
    v_id := gen_random_uuid();
    insert into public.invitations
      (id, estate_id, invited_by, kind, proposed_role, status, expires_at,
       invitee_email, invitee_email_hint, preview_visibility, token_hash, created_at, updated_at)
    values
      (v_id, v_estate, v_owner, 'beneficiary', 'beneficiary', v_term, now() + interval '14 days',
       v_term || '46@verify.test', 'x•••@verify.test', '{}'::jsonb,
       encode(digest('d' || v_term, 'sha256'), 'hex'), now(), now());
    begin
      perform public.revoke_estate_invitation(v_estate, v_id);
      assert false, '5.1 a ' || v_term || ' invitation must not be revocable';
    exception when others then
      get stacked diagnostics v_sqlstate = returned_sqlstate;
      assert v_sqlstate <> '42702', '5.2 ★ ' || v_term || ' path still hits the ambiguity';
      assert v_sqlstate = 'P0005', '5.3 ' || v_term || ' must raise invitation_not_actionable, got ' || v_sqlstate;
    end;
  end loop;

  -- 18 · an EXPIRED-by-date pending row is likewise not actionable (effective status).
  v_id := gen_random_uuid();
  insert into public.invitations
    (id, estate_id, invited_by, kind, proposed_role, status, expires_at,
     invitee_email, invitee_email_hint, preview_visibility, token_hash, created_at, updated_at)
  values
    (v_id, v_estate, v_owner, 'beneficiary', 'beneficiary', 'pending', now() - interval '1 day',
     'exp46@verify.test', 'x•••@verify.test', '{}'::jsonb, encode(digest('dexp','sha256'),'hex'), now(), now());
  begin
    perform public.revoke_estate_invitation(v_estate, v_id);
    assert false, '5.4 an overdue invitation must not be revocable';
  exception when others then
    get stacked diagnostics v_sqlstate = returned_sqlstate;
    assert v_sqlstate <> '42702', '5.5 ★ expired path still hits the ambiguity';
    assert v_sqlstate = 'P0005', '5.6 expired must raise invitation_not_actionable, got ' || v_sqlstate;
  end;

  -- 17 · an ALREADY-REVOKED invitation is IDEMPOTENT, not an error — the deployed function returns
  --      the existing row rather than raising. Pinned so a future change cannot silently make a
  --      double-tap destructive.
  v_id := gen_random_uuid();
  insert into public.invitations
    (id, estate_id, invited_by, kind, proposed_role, status, expires_at, revoked_at,
     invitee_email, invitee_email_hint, preview_visibility, token_hash, created_at, updated_at)
  values
    (v_id, v_estate, v_owner, 'beneficiary', 'beneficiary', 'revoked', now() + interval '14 days', now(),
     'rev46@verify.test', 'x•••@verify.test', '{}'::jsonb, encode(digest('drev','sha256'),'hex'), now(), now());
  select status into r_status from public.revoke_estate_invitation(v_estate, v_id);
  assert r_status = 'revoked', '5.7 re-revoking must return revoked idempotently, got ' || coalesce(r_status,'(null)');

  raise notice '§5 PASSED — terminal statuses behave as deployed; re-revoke is idempotent';
end $$;

-- ============================================================================================
-- §6 · Audit (check 19)  ·  §7 · No membership created (check 20)
-- ============================================================================================

do $$
declare
  v_owner  uuid := gen_random_uuid();
  v_estate uuid := gen_random_uuid();
  v_inv    uuid := gen_random_uuid();
  v_rcpt   uuid := gen_random_uuid();
begin
  insert into auth.users (id, email) values (v_owner, 'owner46d@verify.test');
  insert into auth.users (id, email) values (v_rcpt,  'rcpt46d@verify.test');
  insert into public.profiles (id, email, full_name)
    values (v_owner, 'owner46d@verify.test', 'Verify Owner 46D') on conflict (id) do nothing;
  insert into public.estates (id, owner_id, name, status, is_primary)
    values (v_estate, v_owner, 'Verify Estate 46D', 'active', true);
  insert into public.invitations
    (id, estate_id, invited_by, kind, proposed_role, status, expires_at,
     invitee_email, invitee_email_hint, preview_visibility, token_hash, created_at, updated_at)
  values
    (v_inv, v_estate, v_owner, 'beneficiary', 'beneficiary', 'pending', now() + interval '14 days',
     'rcpt46d@verify.test', 'r•••@verify.test', '{}'::jsonb, encode(digest('d46d','sha256'),'hex'), now(), now());

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);
  perform public.revoke_estate_invitation(v_estate, v_inv);

  -- 19 · audit written, scoped to this estate and target.
  assert (select count(*) from public.audit_logs
          where estate_id = v_estate and target_id = v_inv and action = 'invitation.revoked') = 1,
    '6.1 revoking must write exactly one invitation.revoked audit row';

  -- The audit must not carry the recipient address in the clear.
  assert not exists (
    select 1 from public.audit_logs
    where estate_id = v_estate and target_id = v_inv and metadata::text like '%rcpt46d@verify.test%'
  ), '6.2 ★ audit metadata must not contain the raw recipient address';

  -- 20 · revoking creates NO membership for the invitee.
  assert (select count(*) from public.estate_memberships
          where estate_id = v_estate and user_id = v_rcpt) = 0,
    '7.1 ★ revoke must never create a membership for the invitee';

  raise notice '§6–7 PASSED — audit correct and non-disclosing; no membership created';
end $$;

-- ============================================================================================
-- §8 · Rollback removes every fixture (check 22)
-- ============================================================================================

rollback;

-- Post-rollback proof. Runs OUTSIDE the transaction above, so it observes committed state only.
do $$
declare
  v_users bigint; v_estates bigint; v_invs bigint;
begin
  select count(*) into v_users   from auth.users         where email like '%46%@verify.test';
  select count(*) into v_estates from public.estates     where name like 'Verify Estate 46%';
  select count(*) into v_invs    from public.invitations where invitee_email like '%46%@verify.test';

  assert v_users = 0,   'R.1 fixture auth users survived ROLLBACK: '  || v_users;
  assert v_estates = 0, 'R.2 fixture estates survived ROLLBACK: '     || v_estates;
  assert v_invs = 0,    'R.3 fixture invitations survived ROLLBACK: ' || v_invs;

  raise notice 'ROLLBACK VERIFIED — no fixture row survived. 0046 harness complete.';
end $$;
