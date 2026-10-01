-- public.require_aal2() -> void   (raises 'mfa_required' / 42501 if the caller is not MFA-authed)
--
-- The single, shared aal2 (MFA) gate for FINANCIAL paths. Centralize-don't-duplicate: every financial
-- RPC calls this instead of inlining the check, so a new financial RPC can't get the shape wrong.
--
-- ★ THE RULE ITSELF LIVES IN `public.aal2_is_current()`, AND THAT SPLIT IS THE POINT. Two of the AAL2
--   gates are not function calls at all — they are RESTRICTIVE policies on `connections` and
--   `normalized_assets` that used to inline `auth.jwt() ->> 'aal'` as their own copy of the rule. Both
--   now evaluate the same predicate, so "what makes a caller MFA-current" is defined once. A gate that
--   needs a boolean gets the boolean; this wrapper owns the exception and its sentinel.
--
-- ★ WHAT CHANGED IN 0064, AND WHY IT IS A SECURITY FIX RATHER THAN A TIDY-UP. This function used to
--   read the `aal` claim and nothing else. That claim is stateless, so an access token minted before
--   an MFA reset still satisfied it — MEASURED on nonprod: after recovery deleted the factor and
--   revoked the session, the retained token was still granted an aal2-gated read. `aal2_is_current()`
--   additionally requires the session and the verified factor to still exist. See that file for the
--   measurement, the three legs, and why a shorter token lifetime is not the fix.
--
-- FAIL-CLOSED: a null / absent `aal` claim coalesces to 'aal1' -> gated. The proven pattern from
-- generate_recovery_codes. auth.jwt() reads the REQUEST's JWT claims (set once per request by
-- PostgREST), so this returns the correct aal even when called from a SECURITY DEFINER RPC (DEFINER
-- changes the execution role, NOT the request.jwt.claims session setting).
--
-- SENTINEL: raises the message 'mfa_required' (errcode 42501 -> PostgREST 403) so the endpoint can map
-- it to { error: "mfa_required" } — distinguishable from a real 401 / a not-owner 403. EVERY refusal
-- uses this one message, including the new server-state legs: the client already handles it, so the
-- fix needs no client release, and a caller holding a stale token is not told which fact defeated it.
--
-- WHY the gate lives HERE, not (only) in table policies: the financial reads/writes go through
-- SECURITY DEFINER RPCs (list_estate_assets, get_estate_net_worth, create_connection,
-- get_connection_access_token) that BYPASS RLS — so aal2 on the table policies alone would gate
-- nothing on the RPC path. Table-policy aal2 (0010) is defense-in-depth for the direct-query paths.
--
-- Source of truth — re-apply on DB reset. Requires public.aal2_is_current() (0064).

create or replace function public.require_aal2()
 returns void
 language plpgsql
 stable
 set search_path to 'public', 'auth', 'extensions'
as $function$
begin
  if not public.aal2_is_current() then
    raise exception 'mfa_required' using errcode = '42501';
  end if;
end;
$function$;
