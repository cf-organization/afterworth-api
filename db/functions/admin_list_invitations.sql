-- public.admin_list_invitations(...) — the admin invitations LIST read RPC. Source of truth.
-- Created in db/migrations/0018_20260712_admin_list_invitations.sql; re-apply on DB reset.
--
-- Gated INSIDE via admin_require_gate() (auth -> is_admin -> require_aal2 -> 15-min iat freshness).
-- SAFE columns only: derived token_fingerprint (12 hex) + masked hints + status — token_hash NEVER
-- in the return set (the raw token is never stored anyway). Keyset (created_at desc, id desc), clamp
-- <=200. All columns qualified `i.*` (RETURNS TABLE OUT names shadow invitations columns -> 42702).

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
  perform public.admin_require_gate();
  return query
    select
      i.id, i.estate_id, i.estate_display_name, i.kind, i.proposed_role, i.status,
      i.invitee_email_hint, i.invitee_phone_hint, i.inviter_display_name,
      i.expires_at, (i.expires_at < now()) as is_expired,
      i.created_at, i.accepted_at, i.accepted_by,
      substr(i.token_hash, 1, 12) as token_fingerprint
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

-- grants (also in the migration): EXECUTE to authenticated only.
-- revoke execute on function public.admin_list_invitations(uuid, text, timestamptz, uuid, int) from public, anon;
-- grant  execute on function public.admin_list_invitations(uuid, text, timestamptz, uuid, int) to authenticated;
