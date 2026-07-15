-- public.invitation_write_gate(p_estate uuid) -> void   (raises 42501 on any failed check)
--
-- The write gate for create_invitation: the estate OWNER may mint freely; a platform ADMIN (non-owner) may
-- also mint but is held to the stricter admin bar — require_aal2 + 15-min token freshness — on the
-- non-owner branch. This is why admin_create_executor_invitation can delegate minting to create_invitation:
-- the admin caller passes here (owner-OR-admin), and the admin branch re-checks aal2+freshness as
-- defense-in-depth behind admin_require_gate.
--
-- Sentinels: 'auth_required' / 'owner_or_admin_required' / 'mfa_required' (via require_aal2) /
-- 'stale_token_reauth_required'. SECURITY DEFINER (reads is_estate_owner / is_admin, both DEFINER).
--
-- CAPTURED FROM LIVE 2026-07-15 — was live-only (migration 0016). This file is now the VC record; re-apply
-- on DB reset.

create or replace function public.invitation_write_gate(p_estate uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  if auth.uid() is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;
  if not (public.is_estate_owner(p_estate) or public.is_admin()) then
    raise exception 'owner_or_admin_required' using errcode = '42501';
  end if;
  if not public.is_estate_owner(p_estate) then
    -- admin (non-owner) branch
    perform public.require_aal2();
    if extract(epoch from now())::bigint - coalesce((auth.jwt() ->> 'iat')::bigint, 0) > 900 then
      raise exception 'stale_token_reauth_required' using errcode = '42501';
    end if;
  end if;
end;
$function$;
