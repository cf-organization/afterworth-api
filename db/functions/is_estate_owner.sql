-- public.is_estate_owner(p_estate_id uuid) -> boolean
--
-- The ownership PRIMITIVE: true iff the caller (auth.uid()) owns the estate. Centralizes the owner
-- check so consumers (RLS policies + DEFINER RPCs) never scatter raw owner_id comparisons.
-- SECURITY DEFINER + STABLE: reads estates.owner_id bypassing the estates RLS, so it is callable from
-- inside other policies/RPCs without any grant on estates.
--
-- CAPTURED FROM LIVE — was live-only, NOT in version control (same class as the handle_new_user trap:
-- an invisible load-bearing object). This file is now the VC record; re-apply on DB reset. Depended on
-- by 0007's financial-table policies, 0010's aal2 flips, and every gated financial RPC.
--
-- NOTE (Pattern B): reads estates.owner_id DIRECTLY, not estate_memberships. This is the sanctioned
-- single site for the owner check — Pattern B's "never owner_id directly" targets scattering the check
-- across consumers, which this centralization satisfies. If ownership ever migrates fully into
-- estate_memberships, change it HERE only.
-- Source of truth.

create or replace function public.is_estate_owner(p_estate_id uuid)
 returns boolean
 language sql
 stable
 security definer
 set search_path to 'public'
as $function$
  select exists (
    select 1 from estates
    where id = p_estate_id and owner_id = auth.uid()
  )
$function$;
