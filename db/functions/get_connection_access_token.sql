-- public.get_connection_access_token(p_connection_id uuid) -> text   (the access_token, or NULL)
--
-- SERVER-ONLY read of a connection's provider access_token, for /api/connections/refresh to call
-- the aggregator (lib/plaid). The token lives in connection_secrets (grant-less, RLS-deny-all), so
-- this DEFINER RPC is the ONLY read path. Estate-OWNER-gated: returns the token only if the caller
-- owns the connection's estate — so a member/another estate can't extract it. The endpoint runs
-- this with the user's JWT and uses the result SERVER-SIDE only; it is never returned to the
-- client (the client gets the reference_token handle, never the access_token).
--
-- This is the recovery-codes/get-secret pattern: a grant-less secret table + an estate-gated
-- DEFINER read — NOT a service-key-for-data bypass.
--
-- Error codes: 42501 -> 403 (unauthenticated / not estate owner). Returns NULL if the connection
-- or its secret does not exist.
-- SECURITY DEFINER; relies on auth.uid(). Default EXECUTE is PUBLIC. Source of truth.

create or replace function public.get_connection_access_token(p_connection_id uuid)
 returns text
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_user      uuid := auth.uid();
  v_estate_id uuid;
  v_token     text;
begin
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;

  select estate_id into v_estate_id from public.connections where id = p_connection_id;
  if v_estate_id is null then
    return null;                          -- no such connection
  end if;
  if not public.is_estate_owner(v_estate_id) then
    raise exception 'not estate owner' using errcode = '42501';
  end if;
  -- aal2 GATE: reading a provider access_token (owner-only, feeds the aggregator refresh) -> ALWAYS
  -- require MFA. UNCONDITIONAL. DEFINER bypasses RLS, so the gate must be HERE.
  perform public.require_aal2();

  select access_token into v_token from public.connection_secrets where connection_id = p_connection_id;
  return v_token;
end;
$function$;
