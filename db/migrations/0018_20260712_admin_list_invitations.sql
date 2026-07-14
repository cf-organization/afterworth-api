-- 0018_20260712_admin_list_invitations — the admin invitations LIST read RPC (Slice-3.5 addendum).
--
-- The console cannot list invitations via consumer paths: admin has NO RLS carve-out (Posture B) and
-- NO grant on public.invitations; the invitee_read/member_read/owner_manage policies match the
-- invitee/member/owner, none of which an admin is for an arbitrary estate. So listing needs this
-- dedicated admin RPC — reachable via PostgREST rpc/ with the admin's own JWT, gated INSIDE.
--
-- HARD RULE: the raw token is never stored (only token_hash); this RPC returns ONLY the derived
-- 12-char token_fingerprint + masked hints + status — token_hash is NEVER in the return set.
--
-- Every column is qualified `i.*` — the RETURNS TABLE OUT columns shadow invitations columns, and a
-- bare reference is 42702-ambiguous (the Slice-2 create_invitation.expires_at / accept_invitation
-- .estate_id lesson).

begin;

create or replace function public.admin_list_invitations(
  p_estate         uuid        default null,
  p_status         text        default null,
  p_before_created timestamptz default null,
  p_before_id      uuid        default null,
  p_limit          int         default 50
)
 returns table(
   id                    uuid,
   estate_id             uuid,
   estate_display_name   text,
   kind                  text,
   proposed_role         text,
   status                text,
   invitee_email_hint    text,
   invitee_phone_hint    text,
   inviter_display_name  text,
   expires_at            timestamptz,
   is_expired            boolean,
   created_at            timestamptz,
   accepted_at           timestamptz,
   accepted_by           uuid,
   token_fingerprint     text
 )
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  perform public.admin_require_gate();   -- auth -> is_admin -> require_aal2 -> 15-min iat freshness
  return query
    select
      i.id, i.estate_id, i.estate_display_name, i.kind, i.proposed_role, i.status,
      i.invitee_email_hint, i.invitee_phone_hint, i.inviter_display_name,
      i.expires_at, (i.expires_at < now()) as is_expired,
      i.created_at, i.accepted_at, i.accepted_by,
      substr(i.token_hash, 1, 12) as token_fingerprint   -- derived; token_hash itself NEVER returned
    from public.invitations i
    where (p_estate is null or i.estate_id = p_estate)
      and (p_status is null or i.status = p_status)
      and (
        p_before_created is null
        or i.created_at < p_before_created
        or (i.created_at = p_before_created and i.id < p_before_id)
      )
    order by i.created_at desc, i.id desc
    limit least(greatest(coalesce(p_limit, 50), 1), 200);
end;
$function$;

revoke execute on function public.admin_list_invitations(uuid, text, timestamptz, uuid, int) from public, anon;
grant  execute on function public.admin_list_invitations(uuid, text, timestamptz, uuid, int) to authenticated;

commit;
