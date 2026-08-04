-- 0045_20260804_fix_create_invitation_ambiguous_expires_at.sql
--
-- ★ create_estate_invitation is BROKEN IN PRODUCTION. Every owner invitation create fails.
--
-- The function declares `RETURNS TABLE(invitation_id uuid, token_fingerprint text,
-- expires_at timestamptz, delivery_state text)`. In PL/pgSQL a RETURNS TABLE column is an
-- implicit OUT variable in scope for the ENTIRE body, so this statement in 0042:
--
--     update public.invitations
--        set status = 'expired', updated_at = now()
--      where estate_id = p_estate and status in ('pending','matched') and expires_at <= now();
--
-- has a bare `expires_at` that could mean either the OUT variable or invitations.expires_at.
-- PostgreSQL refuses it:
--
--     42702: column reference "expires_at" is ambiguous
--     It could refer to either a PL/pgSQL variable or a table column.
--
-- The statement runs unconditionally after estate_owner_gate and the input guards, so EVERY
-- create by a legitimate owner raises. The API maps the unrecognised code to a 502
-- `upstream_error`, which is why the failure looked like an outage rather than a bug.
--
-- Confirmed live against the deployed database by calling the RPC directly as an authenticated
-- estate owner with a valid estate, the `beneficiary` role, and a well-formed recipient.
--
-- ★ The irony is worth recording: the failing statement is the expiry-settling step whose own
-- comment says a stale invitation would otherwise "block re-inviting the same person forever".
-- Because it raises, NO invitation can be created at all.
--
-- THE FIX: alias the table and qualify the predicate — the same `inv.` form the very next
-- statement in this function already uses. Purely additive: `create or replace function`, no
-- signature change, no column change, no grant change. Migration 0042 is NOT modified.
--
-- Only the three predicate references changed; the body is otherwise byte-identical to 0042.

begin;

create or replace function public.create_estate_invitation(
  p_estate            uuid,
  p_proposed_role     text,
  p_invitee_email     text    default null,
  p_invitee_phone     text    default null,
  p_show_estate_name  boolean default false,
  p_show_inviter_name boolean default false,
  p_expires_in_days   int     default 14
)
 returns table(invitation_id uuid, token_fingerprint text, expires_at timestamptz, delivery_state text)
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_pending int; v_id uuid; v_expires timestamptz;
  v_estate_name text; v_inviter_name text;
  v_email text; v_phone text; v_email_hint text; v_phone_hint text;
  v_unissued_hash text; v_outbox uuid;
begin
  perform public.estate_owner_gate(p_estate);

  v_email := nullif(btrim(lower(coalesce(p_invitee_email, ''))), '');
  v_phone := nullif(btrim(coalesce(p_invitee_phone, '')), '');
  if v_email is null and v_phone is null then
    raise exception 'invitee_contact_required' using errcode = 'P0001';
  end if;

  -- Bounded to the verified product vocabulary. Ownership and fiduciary roles are unrepresentable
  -- here AND at the schema level (invitations_proposed_role_check), so an invitation can never
  -- grant executor, trustee, or owner. `kind` is set equal to the role: this consumer path does
  -- not expose the broader kind vocabulary the console uses.
  if p_proposed_role not in ('beneficiary', 'professional_delegate') then
    raise exception 'role_not_supported' using errcode = 'P0001';
  end if;
  if p_expires_in_days < 1 or p_expires_in_days > 90 then
    raise exception 'invalid_expiry' using errcode = 'P0001';
  end if;

  -- Self-invitation is rejected: an owner is already the estate's owner, and inviting themselves
  -- would create a second membership row for the same person.
  if v_email is not null and v_email = (select lower(p.email) from public.profiles p where p.id = auth.uid()) then
    raise exception 'cannot_invite_self' using errcode = 'P0001';
  end if;

  -- Already an approved member of this estate → nothing to invite them to.
  if v_email is not null and exists (
    select 1 from public.estate_memberships m
    join public.profiles pr on pr.id = m.user_id
    where m.estate_id = p_estate and lower(pr.email) = v_email and m.status = 'approved'
  ) then
    raise exception 'already_member' using errcode = 'P0001';
  end if;

  -- ★ ATOMIC EXPIRY SWEEP, then the duplicate check (design record D5). A partial unique index
  -- cannot use now(), so overdue rows are settled to their true status first — otherwise a stale
  -- invitation would block re-inviting the same person forever.
  update public.invitations as inv
     set status = 'expired', updated_at = now()
   where inv.estate_id = p_estate and inv.status in ('pending', 'matched') and inv.expires_at <= now();

  if v_email is not null and exists (
    select 1 from public.invitations i
    where i.estate_id = p_estate and lower(i.invitee_email) = v_email
      and i.proposed_role = p_proposed_role and i.status in ('pending', 'matched')
  ) then
    raise exception 'active_invitation_exists' using errcode = 'P0001';
  end if;

  select count(*) into v_pending
    from public.invitations inv
   where inv.estate_id = p_estate and inv.status in ('pending', 'matched') and inv.expires_at > now();
  if v_pending >= 20 then
    raise exception 'pending_invitation_cap' using errcode = 'P0001';
  end if;

  select e.name into v_estate_name from public.estates e where e.id = p_estate;
  select coalesce(nullif(pr.full_name, ''), pr.email) into v_inviter_name
    from public.profiles pr where pr.id = auth.uid();

  v_email_hint := case when v_email is not null
    then left(v_email, 1) || '•••@' || split_part(v_email, '@', 2) else null end;
  v_phone_hint := case when v_phone is not null then '•••' || right(v_phone, 4) else null end;

  -- ★ THE SECRET IS NOT MINTED HERE. token_hash is NOT NULL, so a hash of an immediately-discarded
  -- random value is stored. The invitation therefore exists but is NOT YET USABLE: no token that
  -- hashes to this value has ever existed outside this statement. The real secret is minted by
  -- issue_invitation_delivery() at delivery time. Fail-closed: an invitation nobody has been told
  -- about cannot be accepted.
  v_unissued_hash := encode(digest(encode(gen_random_bytes(32), 'hex'), 'sha256'), 'hex');
  v_expires := now() + make_interval(days => p_expires_in_days);

  insert into public.invitations
    (id, estate_id, invited_by, kind, proposed_role, status, expires_at,
     invitee_email, invitee_phone, invitee_email_hint, invitee_phone_hint,
     estate_display_name, inviter_display_name, preview_visibility, token_hash, created_at, updated_at)
  values
    (gen_random_uuid(), p_estate, auth.uid(), p_proposed_role, p_proposed_role, 'pending', v_expires,
     v_email, v_phone, v_email_hint, v_phone_hint, v_estate_name, v_inviter_name,
     jsonb_build_object('showEstateName', p_show_estate_name, 'showInviterName', p_show_inviter_name),
     v_unissued_hash, now(), now())
  returning id into v_id;

  -- Same transaction: the invitation and its delivery request commit together or not at all.
  insert into public.invitation_delivery_outbox (invitation_id, estate_id, reason, requested_by)
  values (v_id, p_estate, 'invitation_created', auth.uid())
  returning id into v_outbox;

  perform public.write_audit('invitation.created', 'invitations', v_id, p_estate,
    jsonb_build_object('invitation_id', v_id, 'proposed_role', p_proposed_role,
                       'invitee_email_hint', v_email_hint, 'expires_at', v_expires,
                       'delivery_outbox_id', v_outbox));

  -- 'queued' — NOT 'sent'. Nothing has been delivered; a worker must still run.
  return query select v_id, substr(v_unissued_hash, 1, 12), v_expires, 'queued'::text;
end;
$function$;
commit;
