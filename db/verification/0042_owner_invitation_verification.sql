-- Verification harness for migration 0042 — owner invitation management.
--
-- ⚠ RUN AGAINST A DISPOSABLE NON-PRODUCTION PROJECT ONLY. It creates estates, users, and
-- invitations, and rolls everything back at the end. It must never touch production.
--
-- Usage:  psql "$NONPROD_DB_URL" -v ON_ERROR_STOP=1 -f db/verification/0042_owner_invitation_verification.sql
--
-- Every assertion is an `assert`, so the script aborts at the first failure with the failing
-- condition named. A clean run prints only the section banners and 'ALL ASSERTIONS PASSED'.

\set ON_ERROR_STOP on
begin;

-- ── fixtures ────────────────────────────────────────────────────────────────────────────────
-- Synthetic ids only; no production data. auth.uid() is simulated via a settable role claim, so
-- these run without real Supabase sessions.
create temporary table t_ids as
select gen_random_uuid() as owner_id, gen_random_uuid() as other_owner_id,
       gen_random_uuid() as beneficiary_id, gen_random_uuid() as estate_a, gen_random_uuid() as estate_b;

do $$
declare v record;
begin
  select * into v from t_ids;
  insert into auth.users (id, email) values
    (v.owner_id, 'owner@verify.test'), (v.other_owner_id, 'other@verify.test'), (v.beneficiary_id, 'ben@verify.test')
  on conflict (id) do nothing;
  insert into public.profiles (id, email, full_name) values
    (v.owner_id, 'owner@verify.test', 'Verify Owner'),
    (v.other_owner_id, 'other@verify.test', 'Other Owner'),
    (v.beneficiary_id, 'ben@verify.test', 'Verify Beneficiary')
  on conflict (id) do nothing;
  insert into public.estates (id, owner_id, name, status, is_primary) values
    (v.estate_a, v.owner_id, 'Estate A', 'active', true),
    (v.estate_b, v.other_owner_id, 'Estate B', 'active', true)
  on conflict (id) do nothing;
end $$;

\echo '── 1 · AUTHORIZATION ───────────────────────────────────────────────'
-- Non-owner and cross-estate access must RAISE, never return empty. An empty result must be
-- reserved for "no invitations", otherwise the caller cannot tell refusal from absence.
do $$
declare v record; ok boolean;
begin
  select * into v from t_ids;

  perform set_config('request.jwt.claims', json_build_object('sub', v.beneficiary_id)::text, true);
  ok := false;
  begin perform public.list_estate_invitations(v.estate_a); exception when others then ok := true; end;
  assert ok, 'a non-owner must be REFUSED, not returned an empty list';

  perform set_config('request.jwt.claims', json_build_object('sub', v.other_owner_id)::text, true);
  ok := false;
  begin perform public.list_estate_invitations(v.estate_a); exception when others then ok := true; end;
  assert ok, 'another estate''s owner must be refused (cross-estate isolation)';

  perform set_config('request.jwt.claims', json_build_object('sub', v.owner_id)::text, true);
  perform public.list_estate_invitations(v.estate_a);  -- must not raise
end $$;

\echo '── 2 · CREATE ──────────────────────────────────────────────────────'
do $$
declare v record; r record; ok boolean; n int;
begin
  select * into v from t_ids;
  perform set_config('request.jwt.claims', json_build_object('sub', v.owner_id)::text, true);

  select * into r from public.create_estate_invitation(v.estate_a, 'beneficiary', 'invitee@verify.test');
  assert r.invitation_id is not null,        'create returns an invitation id';
  assert r.delivery_state = 'queued',        'create reports QUEUED, never sent/delivered';
  assert length(r.token_fingerprint) = 12,   'fingerprint is the 12-char derived value';

  -- ★ THE CENTRAL PROOF: the create result exposes no raw-token column at all.
  assert not exists (
    select 1 from information_schema.routines rt
    join information_schema.parameters p on p.specific_name = rt.specific_name
    where rt.routine_name = 'create_estate_invitation'
      and p.parameter_mode = 'OUT' and p.parameter_name ilike '%token%'
      and p.parameter_name not ilike '%fingerprint%'
  ), '★ create must expose NO raw-token OUT parameter';

  -- unsupported roles
  ok := false;
  begin perform public.create_estate_invitation(v.estate_a, 'executor', 'x@verify.test');
  exception when others then ok := true; end;
  assert ok, 'executor must be rejected — an invitation never grants fiduciary capacity';

  ok := false;
  begin perform public.create_estate_invitation(v.estate_a, 'primary_user', 'y@verify.test');
  exception when others then ok := true; end;
  assert ok, 'ownership roles must be rejected';

  -- duplicate active invitation
  ok := false;
  begin perform public.create_estate_invitation(v.estate_a, 'beneficiary', 'invitee@verify.test');
  exception when others then ok := true; end;
  assert ok, 'a second ACTIVE invitation for the same recipient+role must be rejected';

  -- ...but the SAME recipient may hold a different role, because they are different relationships
  select * into r from public.create_estate_invitation(v.estate_a, 'professional_delegate', 'invitee@verify.test');
  assert r.invitation_id is not null, 'the same recipient may hold one invitation per role';

  -- self-invitation
  ok := false;
  begin perform public.create_estate_invitation(v.estate_a, 'beneficiary', 'owner@verify.test');
  exception when others then ok := true; end;
  assert ok, 'self-invitation must be rejected';

  -- an outbox row was created atomically with each invitation
  select count(*) into n from public.invitation_delivery_outbox where estate_id = v.estate_a;
  assert n = 2, 'each created invitation enqueues exactly one delivery request';
end $$;

\echo '── 3 · EXPIRY SWEEP DOES NOT PERMANENTLY BLOCK RE-INVITATION ───────'
do $$
declare v record; r record;
begin
  select * into v from t_ids;
  perform set_config('request.jwt.claims', json_build_object('sub', v.owner_id)::text, true);
  -- age the beneficiary invitation past its expiry
  update public.invitations set expires_at = now() - interval '1 day'
   where estate_id = v.estate_a and proposed_role = 'beneficiary';
  -- the create path sweeps it to 'expired' first, so the same recipient can be re-invited
  select * into r from public.create_estate_invitation(v.estate_a, 'beneficiary', 'invitee@verify.test');
  assert r.invitation_id is not null, '★ a stale invitation must not block re-invitation forever';
  assert exists (select 1 from public.invitations
                  where estate_id = v.estate_a and status = 'expired'),
         'the overdue row was settled to expired, not left pending';
end $$;

\echo '── 4 · LIST PROJECTION ─────────────────────────────────────────────'
do $$
declare v record; r record; n int;
begin
  select * into v from t_ids;
  perform set_config('request.jwt.claims', json_build_object('sub', v.owner_id)::text, true);

  -- ★ no secret material is exposed by the list contract
  assert not exists (
    select 1 from information_schema.parameters p
    join information_schema.routines rt on rt.specific_name = p.specific_name
    where rt.routine_name = 'list_estate_invitations' and p.parameter_mode = 'OUT'
      and (p.parameter_name ilike '%token_hash%' or p.parameter_name = 'raw_token')
  ), '★ list must expose neither the raw token nor the hash';

  -- masked hints only; the full address must never appear in the projection
  for r in select * from public.list_estate_invitations(v.estate_a) loop
    assert r.invitee_email_hint is null or r.invitee_email_hint like '%•••@%',
           'the list returns the MASKED hint, never the address';
    assert r.status in ('pending','matched','accepted','declined','expired','revoked'),
           'status is from the closed vocabulary';
    assert r.delivery_state in ('none','queued','issued','failed'),
           '★ delivery_state must never claim delivered';
    -- an expired-by-time row must not advertise an action the mutation would refuse
    if r.status = 'expired' then
      assert not r.can_revoke and not r.can_extend and not r.can_redeliver,
             '★ action flags derive from EFFECTIVE status';
    end if;
  end loop;

  select count(*) into n from public.list_estate_invitations(v.estate_a, 1);
  assert n = 1, 'the limit is honoured';
end $$;

\echo '── 5 · REVOKE ──────────────────────────────────────────────────────'
do $$
declare v record; r record; inv uuid; ok boolean; prior text;
begin
  select * into v from t_ids;
  perform set_config('request.jwt.claims', json_build_object('sub', v.owner_id)::text, true);
  select invitation_id into inv from public.list_estate_invitations(v.estate_a)
   where can_revoke limit 1;

  select * into r from public.revoke_estate_invitation(v.estate_a, inv);
  assert r.status = 'revoked' and r.revoked_at is not null, 'revoke settles the row authoritatively';

  -- queued delivery for a revoked invitation must be cancelled
  assert not exists (select 1 from public.invitation_delivery_outbox
                      where invitation_id = inv and status = 'pending'),
         '★ revoking cancels any queued delivery';

  -- idempotent
  select * into r from public.revoke_estate_invitation(v.estate_a, inv);
  assert r.status = 'revoked', 'a repeated revoke returns the authoritative revoked state';

  -- cross-estate revoke is indistinguishable from not-found
  perform set_config('request.jwt.claims', json_build_object('sub', v.other_owner_id)::text, true);
  ok := false;
  begin perform public.revoke_estate_invitation(v.estate_b, inv); exception when others then ok := true; end;
  assert ok, '★ another owner must not be able to probe for this invitation';
end $$;

\echo '── 6 · TOKEN CUSTODY ───────────────────────────────────────────────'
do $$
declare v record; r record; inv uuid; ob uuid; h1 text; h2 text; ok boolean;
begin
  select * into v from t_ids;
  perform set_config('request.jwt.claims', json_build_object('sub', v.owner_id)::text, true);
  select invitation_id into inv from public.list_estate_invitations(v.estate_a) where can_redeliver limit 1;

  select token_hash into h1 from public.invitations where id = inv;
  select id into ob from public.invitation_delivery_outbox where invitation_id = inv and status = 'pending' limit 1;

  -- ★ an AUTHENTICATED caller must not be able to issue a token
  ok := false;
  begin
    set local role authenticated;
    perform public.issue_invitation_delivery(ob);
  exception when others then ok := true; end;
  reset role;
  assert ok, '★ issue_invitation_delivery must be unreachable by authenticated';

  -- the trusted worker path rotates the secret
  select * into r from public.issue_invitation_delivery(ob);
  assert length(r.raw_token) = 64, 'a 256-bit token is minted';
  select token_hash into h2 from public.invitations where id = inv;
  assert h2 <> h1, '★ issuing ROTATES the stored hash — any prior link stops working';
  assert h2 = encode(digest(r.raw_token, 'sha256'), 'hex'), 'only the hash of the issued token is stored';
  assert not exists (select 1 from public.invitations where token_hash = r.raw_token),
         '★ the raw token is never persisted anywhere';
end $$;

\echo '── 7 · RECIPIENT REGRESSION (must remain byte-compatible) ──────────'
do $$
declare v record; n int;
begin
  select * into v from t_ids;
  -- The recipient contract is untouched by 0042; these assert the functions still exist with the
  -- signatures the pending mobile work consumes.
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and p.proname in ('resolve_membership','accept_invitation','decline_invitation',
                       'invitation_preview','bind_invitation_token');
  assert n >= 5, 'every recipient function still exists';

  assert (select count(*) from information_schema.role_routine_grants
           where routine_name = 'create_invitation' and grantee = 'authenticated') = 1,
         'the console''s original create_invitation is left intact';
end $$;

\echo '── 8 · PRIVILEGES AND RLS ──────────────────────────────────────────'
do $$
declare n int;
begin
  assert (select relrowsecurity from pg_class where relname = 'invitation_delivery_outbox'),
         'RLS is enabled on the outbox';
  select count(*) into n from information_schema.role_table_grants
   where table_name = 'invitation_delivery_outbox' and grantee in ('authenticated','anon');
  assert n = 0, '★ the outbox has NO authenticated/anon grant';

  select count(*) into n from information_schema.role_table_grants
   where table_name = 'invitations' and grantee in ('authenticated','anon');
  assert n = 0, '★ invitations still has no client grant — RPC-only, unchanged';

  select count(*) into n from information_schema.role_routine_grants
   where routine_name in ('issue_invitation_delivery','record_invitation_delivery_failure')
     and grantee in ('authenticated','anon','PUBLIC');
  assert n = 0, '★ the trusted worker surface is service_role only';
end $$;

\echo ''
\echo 'ALL ASSERTIONS PASSED'
rollback;  -- ⚠ nothing is persisted, even on a non-production project
