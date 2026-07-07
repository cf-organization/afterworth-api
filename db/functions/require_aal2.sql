-- public.require_aal2() -> void   (raises 'mfa_required' / 42501 if the caller is not MFA-authed)
--
-- The single, shared aal2 (MFA) gate for FINANCIAL paths. Centralize-don't-duplicate: every financial
-- RPC calls this instead of inlining the check, so a new financial RPC can't get the shape wrong.
--
-- FAIL-CLOSED: a null / absent `aal` claim coalesces to 'aal1' -> gated. The proven pattern from
-- generate_recovery_codes. auth.jwt() reads the REQUEST's JWT claims (set once per request by
-- PostgREST), so this returns the correct aal even when called from a SECURITY DEFINER RPC (DEFINER
-- changes the execution role, NOT the request.jwt.claims session setting).
--
-- SENTINEL: raises the message 'mfa_required' (errcode 42501 -> PostgREST 403) so the endpoint can map
-- it to { error: "mfa_required" } — distinguishable from a real 401 / a not-owner 403.
--
-- WHY the gate lives HERE, not (only) in table policies: the financial reads/writes go through
-- SECURITY DEFINER RPCs (list_estate_assets, get_estate_net_worth, create_connection,
-- get_connection_access_token) that BYPASS RLS — so aal2 on the table policies alone would gate
-- nothing on the RPC path. Table-policy aal2 (0010) is defense-in-depth for the direct-query paths.
--
-- Source of truth — re-apply on DB reset.

create or replace function public.require_aal2()
 returns void
 language plpgsql
 stable
 set search_path to 'public', 'auth', 'extensions'
as $function$
begin
  if coalesce(auth.jwt() ->> 'aal', 'aal1') <> 'aal2' then
    raise exception 'mfa_required' using errcode = '42501';
  end if;
end;
$function$;
