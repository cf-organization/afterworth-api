-- 0045 verification harness — the create RPC actually runs, and nothing else moved.
--
-- 0045 is a two-line fix (alias the table, qualify the predicate) to a function that raised
-- SQLSTATE 42702 on EVERY legitimate owner invocation. A two-line fix still needs proof of two
-- separate things: that the ambiguity is gone, and that fixing it changed nothing else — the
-- signature, posture, allowlist, duplicate rule, expiry settling, outbox atomicity, and token-free
-- behaviour that 0042 established.
--
-- ⚠ RUN AGAINST A DISPOSABLE NON-PRODUCTION PROJECT ONLY, and only AFTER 0045 is applied there.
-- Every identifier is a generated UUID and every address is @verify.test. The whole script is one
-- transaction ending in ROLLBACK, so nothing survives — but the rows DO exist while it runs, and
-- triggers and audit writes fire against them.
--
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f db/verification/0045_fix_create_invitation_ambiguous_expires_at_verification.sql
--
-- ★ THE FUNCTION IS SECURITY DEFINER AND READS auth.uid(). The harness therefore sets a request
-- JWT claim so `auth.uid()` returns the fixture owner; without it every call would fail the owner
-- gate and §3 onward would prove nothing. That is a test harness concern only.
--
-- Every assertion is a real comparison. There are no `or true` placeholders. Where a check is
-- structural rather than behavioural it says so.
--
-- COVERAGE MAP — the 24 required checks:
--   §0  function exists, signature, DEFINER, search_path, grants ..... 1, 2, 3, 4, 5
--   §1  role allowlist and unsupported role .......................... 6, 7
--   §2  non-owner rejection .......................................... 8
--   §3  ★ valid creates no longer raise 42702 ....................... 9, 10, 11
--   §4  expiry settling uses the qualified column .................... 12
--   §5  active duplicate behaviour ................................... 13, 14, 15
--   §6  terminal statuses do not block reinvitation .................. 16, 17, 18
--   §7  distinct roles are distinct invitations ...................... 19
--   §8  invitation + outbox atomicity ................................ 20
--   §9  token-free delivery, no raw token persisted .................. 21, 22
--   §10 audit records ................................................ 23
--   §11 rollback removes every fixture ............................... 24

begin;

-- ============================================================================================
-- §0 · Function identity and posture (checks 1–5)
-- ============================================================================================

do $$
declare
  v_oid       oid;
  v_sig       text;
  v_secdef    boolean;
  v_config    text[];
  v_acl       text;
begin
  select p.oid, pg_get_function_identity_arguments(p.oid), p.prosecdef, p.proconfig,
         coalesce(array_to_string(p.proacl, ','), '')
    into v_oid, v_sig, v_secdef, v_config, v_acl
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'create_estate_invitation';

  assert v_oid is not null, '0.1 create_estate_invitation is missing (is 0045 applied?)';

  -- Signature must be byte-for-byte what 0042 declared; 0045 is CREATE OR REPLACE, not a redesign.
  assert v_sig = 'p_estate uuid, p_proposed_role text, p_invitee_email text, p_invitee_phone text, '
              || 'p_show_estate_name boolean, p_show_inviter_name boolean, p_expires_in_days integer',
    '0.2 signature changed — 0045 must not alter the contract. Got: ' || v_sig;

  assert v_secdef, '0.3 SECURITY DEFINER was lost — the owner gate depends on it';

  assert array_to_string(v_config, ',') like '%search_path=public, extensions%',
    '0.4 search_path is no longer pinned — a DEFINER function without it is exploitable. Got: '
    || coalesce(array_to_string(v_config, ','), '(null)');

  -- authenticated must retain EXECUTE (owners call it through PostgREST); anon must not appear.
  assert v_acl like '%authenticated=X%', '0.5 authenticated lost EXECUTE. ACL: ' || v_acl;
  assert v_acl not like '%anon=X%', '0.5 anon must NOT hold EXECUTE. ACL: ' || v_acl;

  raise notice '§0 PASSED — signature, DEFINER, search_path and grants unchanged';
end $$;

-- ============================================================================================
-- §1 · Role allowlist (checks 6, 7)  ·  §2 · Owner gate (check 8)
-- ============================================================================================

do $$
declare
  v_owner    uuid := gen_random_uuid();
  v_stranger uuid := gen_random_uuid();
  v_estate   uuid := gen_random_uuid();
  v_sqlstate text;
  v_msg      text;
begin
  insert into auth.users (id, email) values (v_owner, 'owner45a@verify.test');
  insert into auth.users (id, email) values (v_stranger, 'stranger45@verify.test');
  insert into public.profiles (id, email, full_name)
    values (v_owner, 'owner45a@verify.test', 'Verify Owner 45A') on conflict (id) do nothing;
  insert into public.profiles (id, email, full_name)
    values (v_stranger, 'stranger45@verify.test', 'Verify Stranger 45') on conflict (id) do nothing;
  insert into public.estates (id, owner_id, name, status, is_primary)
    values (v_estate, v_owner, 'Verify Estate 45A', 'active', true);

  -- Act as the owner.
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);

  -- 6/7 · an unsupported role is refused, and refused by NAME rather than by accident.
  begin
    perform public.create_estate_invitation(
      v_estate, 'executor', 'x45@verify.test', null, false, false, 14);
    assert false, '1.1 an unsupported role must be rejected';
  exception when others then
    get stacked diagnostics v_sqlstate = returned_sqlstate, v_msg = message_text;
    assert v_sqlstate = 'P0001', '1.2 unsupported role must raise P0001, got ' || v_sqlstate;
    assert v_msg like '%role_not_supported%',
      '1.3 unsupported role must raise role_not_supported, got: ' || v_msg;
  end;

  -- 8 · a non-owner is refused by estate_owner_gate, NOT by the ambiguity.
  perform set_config('request.jwt.claims', json_build_object('sub', v_stranger::text)::text, true);
  begin
    perform public.create_estate_invitation(
      v_estate, 'beneficiary', 'x45b@verify.test', null, false, false, 14);
    assert false, '2.1 a non-owner must be rejected';
  exception when others then
    get stacked diagnostics v_sqlstate = returned_sqlstate;
    assert v_sqlstate <> '42702', '2.2 ★ non-owner path still hits the ambiguity (42702)';
    assert v_sqlstate in ('42501', 'P0001'),
      '2.3 non-owner must fail the owner gate, got ' || v_sqlstate;
  end;

  raise notice '§1–2 PASSED — role allowlist enforced, owner gate enforced, no 42702';
end $$;

-- ============================================================================================
-- §3 · ★ THE REGRESSION: valid creates no longer raise 42702 (checks 9, 10, 11)
-- ============================================================================================

do $$
declare
  v_owner   uuid := gen_random_uuid();
  v_estate  uuid := gen_random_uuid();
  v_inv_b   uuid;
  v_inv_p   uuid;
  v_exp     timestamptz;
  v_fp      text;
  v_state   text;
begin
  insert into auth.users (id, email) values (v_owner, 'owner45b@verify.test');
  insert into public.profiles (id, email, full_name)
    values (v_owner, 'owner45b@verify.test', 'Verify Owner 45B') on conflict (id) do nothing;
  insert into public.estates (id, owner_id, name, status, is_primary)
    values (v_estate, v_owner, 'Verify Estate 45B', 'active', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);

  -- 9 · beneficiary. Before 0045 this raised 42702 unconditionally.
  select invitation_id, expires_at, token_fingerprint, delivery_state
    into v_inv_b, v_exp, v_fp, v_state
  from public.create_estate_invitation(
    v_estate, 'beneficiary', 'benef45@verify.test', null, true, true, 14);
  assert v_inv_b is not null, '3.1 ★ beneficiary create returned no invitation';

  -- 11 · the returned expiry is real and consistent with the requested window.
  assert v_exp is not null, '3.2 expires_at must be returned';
  assert v_exp > now(), '3.3 expires_at must be in the future';
  assert v_exp < now() + interval '15 days', '3.4 expires_at must respect p_expires_in_days (14)';
  assert v_exp = (select expires_at from public.invitations where id = v_inv_b),
    '3.5 returned expires_at must equal the stored column — the OUT variable and the column agree';

  -- 20 · outbox row created atomically with the invitation.
  assert (select count(*) from public.invitation_delivery_outbox where invitation_id = v_inv_b) = 1,
    '3.6 exactly one outbox row must be created with the invitation';

  -- 21/22 · token-free: the RPC returns a FINGERPRINT, and no raw token is stored anywhere.
  assert v_fp is not null and length(v_fp) = 12,
    '3.7 a 12-char fingerprint must be returned (not a token)';
  assert (select token_hash from public.invitations where id = v_inv_b) is not null,
    '3.8 token_hash must still be written (0042 behaviour unchanged)';
  assert (select token_hash from public.invitations where id = v_inv_b) <> v_fp,
    '3.9 ★ the fingerprint must not BE the hash';
  assert v_state = 'queued', '3.10 delivery_state must start queued, got ' || coalesce(v_state,'(null)');

  -- 10 · professional_delegate, the other allowed role.
  select invitation_id into v_inv_p
  from public.create_estate_invitation(
    v_estate, 'professional_delegate', 'prof45@verify.test', null, false, false, 14);
  assert v_inv_p is not null, '3.11 ★ professional_delegate create returned no invitation';

  raise notice '§3 PASSED — ★ 42702 is gone; both allowed roles create, atomically, token-free';
end $$;

-- ============================================================================================
-- §4 · Expiry settling uses the qualified column (check 12)
-- ============================================================================================

do $$
declare
  v_owner  uuid := gen_random_uuid();
  v_estate uuid := gen_random_uuid();
  v_stale  uuid := gen_random_uuid();
  v_new    uuid;
begin
  insert into auth.users (id, email) values (v_owner, 'owner45c@verify.test');
  insert into public.profiles (id, email, full_name)
    values (v_owner, 'owner45c@verify.test', 'Verify Owner 45C') on conflict (id) do nothing;
  insert into public.estates (id, owner_id, name, status, is_primary)
    values (v_estate, v_owner, 'Verify Estate 45C', 'active', true);

  -- A pending invitation that is already overdue. The UPDATE 0045 fixed is what settles it.
  insert into public.invitations
    (id, estate_id, invited_by, kind, proposed_role, status, expires_at,
     invitee_email, invitee_email_hint, preview_visibility, token_hash, created_at, updated_at)
  values
    (v_stale, v_estate, v_owner, 'beneficiary', 'beneficiary', 'pending',
     now() - interval '1 day', 'stale45@verify.test', 's•••@verify.test',
     '{}'::jsonb, encode(digest('discarded45', 'sha256'), 'hex'), now(), now());

  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);

  -- Re-inviting the SAME address must succeed: the overdue row is settled to 'expired' first, so it
  -- no longer collides with the active-duplicate index. Before 0045 this statement raised.
  select invitation_id into v_new
  from public.create_estate_invitation(
    v_estate, 'beneficiary', 'stale45@verify.test', null, false, false, 14);

  assert (select status from public.invitations where id = v_stale) = 'expired',
    '4.1 ★ the overdue invitation must be settled to expired by the qualified UPDATE';
  assert v_new is not null and v_new <> v_stale,
    '4.2 a NEW invitation must be created after the stale one is settled';

  raise notice '§4 PASSED — overdue rows settle via the qualified predicate, unblocking reinvite';
end $$;

-- ============================================================================================
-- §5 · Active duplicate behaviour (checks 13, 14, 15)
-- ============================================================================================

do $$
declare
  v_owner    uuid := gen_random_uuid();
  v_estate   uuid := gen_random_uuid();
  v_first    uuid;
  v_inv_n    bigint;
  v_outbox_n bigint;
  v_sqlstate text;
  v_msg      text;
begin
  insert into auth.users (id, email) values (v_owner, 'owner45d@verify.test');
  insert into public.profiles (id, email, full_name)
    values (v_owner, 'owner45d@verify.test', 'Verify Owner 45D') on conflict (id) do nothing;
  insert into public.estates (id, owner_id, name, status, is_primary)
    values (v_estate, v_owner, 'Verify Estate 45D', 'active', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);

  select invitation_id into v_first
  from public.create_estate_invitation(
    v_estate, 'beneficiary', 'dup45@verify.test', null, false, false, 14);

  -- Counts scoped to THIS estate — an unscoped count would observe unrelated fixture rows.
  select count(*) into v_inv_n from public.invitations where estate_id = v_estate;
  select count(*) into v_outbox_n from public.invitation_delivery_outbox where estate_id = v_estate;

  -- 13 · the duplicate raises by name.
  begin
    perform public.create_estate_invitation(
      v_estate, 'beneficiary', 'dup45@verify.test', null, false, false, 14);
    assert false, '5.1 an active duplicate must be rejected';
  exception when others then
    get stacked diagnostics v_sqlstate = returned_sqlstate, v_msg = message_text;
    assert v_sqlstate = 'P0001', '5.2 duplicate must raise P0001, got ' || v_sqlstate;
    assert v_msg like '%active_invitation_exists%',
      '5.3 duplicate must raise active_invitation_exists, got: ' || v_msg;
  end;

  -- 14/15 · and it must leave NOTHING behind — no second invitation, no second outbox row.
  assert (select count(*) from public.invitations where estate_id = v_estate) = v_inv_n,
    '5.4 ★ a rejected duplicate must not create a second invitation';
  assert (select count(*) from public.invitation_delivery_outbox where estate_id = v_estate) = v_outbox_n,
    '5.5 ★ a rejected duplicate must not create a second outbox row (no second email)';

  -- 19 · a DIFFERENT role for the same recipient is a distinct active invitation.
  assert (select invitation_id from public.create_estate_invitation(
            v_estate, 'professional_delegate', 'dup45@verify.test', null, false, false, 14)) is not null,
    '5.6 a different proposed_role must be a distinct active invitation';

  raise notice '§5 PASSED — duplicate raises, creates nothing; distinct roles remain distinct';
end $$;

-- ============================================================================================
-- §6 · Terminal statuses do not block reinvitation (checks 16, 17, 18)
-- ============================================================================================

do $$
declare
  v_owner  uuid := gen_random_uuid();
  v_estate uuid := gen_random_uuid();
  v_term   text;
  v_id     uuid;
  v_new    uuid;
begin
  insert into auth.users (id, email) values (v_owner, 'owner45e@verify.test');
  insert into public.profiles (id, email, full_name)
    values (v_owner, 'owner45e@verify.test', 'Verify Owner 45E') on conflict (id) do nothing;
  insert into public.estates (id, owner_id, name, status, is_primary)
    values (v_estate, v_owner, 'Verify Estate 45E', 'active', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);

  -- Each terminal status gets its own recipient so the cases cannot mask one another.
  foreach v_term in array array['declined', 'revoked', 'expired'] loop
    v_id := gen_random_uuid();
    insert into public.invitations
      (id, estate_id, invited_by, kind, proposed_role, status, expires_at,
       invitee_email, invitee_email_hint, preview_visibility, token_hash, created_at, updated_at)
    values
      (v_id, v_estate, v_owner, 'beneficiary', 'beneficiary', v_term,
       now() + interval '14 days', v_term || '45@verify.test', 'x•••@verify.test',
       '{}'::jsonb, encode(digest('discarded' || v_term, 'sha256'), 'hex'), now(), now());

    select invitation_id into v_new
    from public.create_estate_invitation(
      v_estate, 'beneficiary', v_term || '45@verify.test', null, false, false, 14);

    assert v_new is not null and v_new <> v_id,
      '6.1 a ' || v_term || ' invitation must NOT block reinvitation';
  end loop;

  raise notice '§6 PASSED — declined, revoked and expired all permit reinvitation';
end $$;

-- ============================================================================================
-- §7 · Audit records (check 23)
-- ============================================================================================

do $$
declare
  v_owner  uuid := gen_random_uuid();
  v_estate uuid := gen_random_uuid();
  v_inv    uuid;
  v_audits bigint;
begin
  insert into auth.users (id, email) values (v_owner, 'owner45f@verify.test');
  insert into public.profiles (id, email, full_name)
    values (v_owner, 'owner45f@verify.test', 'Verify Owner 45F') on conflict (id) do nothing;
  insert into public.estates (id, owner_id, name, status, is_primary)
    values (v_estate, v_owner, 'Verify Estate 45F', 'active', true);
  perform set_config('request.jwt.claims', json_build_object('sub', v_owner::text)::text, true);

  select invitation_id into v_inv
  from public.create_estate_invitation(
    v_estate, 'beneficiary', 'audit45@verify.test', null, false, false, 14);

  -- Scoped to THIS estate: an unscoped count would observe unrelated audit activity.
  select count(*) into v_audits
  from public.audit_logs
  where estate_id = v_estate and target_id = v_inv;

  assert v_audits >= 1, '7.1 creating an invitation must write at least one audit row';

  -- The audit must not carry a raw token or the recipient address in the clear.
  assert not exists (
    select 1 from public.audit_logs
    where estate_id = v_estate and target_id = v_inv
      and (metadata::text like '%audit45@verify.test%' or metadata::text like '%token%')
  ), '7.2 ★ audit metadata must not contain the raw recipient address or a token';

  raise notice '§7 PASSED — audit written, and it discloses neither address nor token';
end $$;

-- ============================================================================================
-- §11 · Rollback removes every fixture (check 24)
-- ============================================================================================

rollback;

-- Post-rollback proof. Runs OUTSIDE the transaction above, so it observes committed state only:
-- if any fixture survived, these counts would be non-zero.
do $$
declare
  v_users   bigint;
  v_estates bigint;
  v_invs    bigint;
begin
  select count(*) into v_users   from auth.users        where email like '%@verify.test';
  select count(*) into v_estates from public.estates    where name like 'Verify Estate 45%';
  select count(*) into v_invs    from public.invitations where invitee_email like '%45@verify.test';

  assert v_users = 0,   'R.1 fixture auth users survived ROLLBACK: '   || v_users;
  assert v_estates = 0, 'R.2 fixture estates survived ROLLBACK: '      || v_estates;
  assert v_invs = 0,    'R.3 fixture invitations survived ROLLBACK: '  || v_invs;

  raise notice 'ROLLBACK VERIFIED — no fixture row survived. 0045 harness complete.';
end $$;
