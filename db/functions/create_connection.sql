-- public.create_connection(p_estate_id uuid, p_provider text, p_institution_id text,
--                          p_institution_name text, p_reference_token text, p_access_token text)
--   -> SETOF public.connections   (the created connection row — WITHOUT the access_token)
--
-- The single audited entry for persisting an aggregator connection. Writes the client-readable
-- connections row AND the server-only connection_secrets row (the access_token) ATOMICALLY, so a
-- connection never exists without its secret (or vice-versa). Owner-gated: only the estate OWNER
-- connects accounts. The access_token is passed in by the /api/connections/exchange endpoint
-- (which got it from lib/plaid's public_token→access_token exchange) and lands ONLY in
-- connection_secrets (no grants) — never in the client-readable connections table.
--
-- SECURITY DEFINER bypasses RLS, so the is_estate_owner gate below IS the boundary (FIRST check
-- after the auth null-guard). Returns the connection row only (the token never leaves the server).
--
-- Error codes: 42501 -> 403 (unauthenticated / not estate owner).
-- SECURITY DEFINER; relies on auth.uid(). Default EXECUTE is PUBLIC. Source of truth.

create or replace function public.create_connection(
  p_estate_id        uuid,
  p_provider         text,
  p_institution_id   text,
  p_institution_name text,
  p_reference_token  text,
  p_access_token     text
)
 returns setof public.connections
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_user uuid := auth.uid();
  v_id   uuid;
begin
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;
  -- SECURITY SPINE: only the estate owner connects accounts (DEFINER bypasses RLS).
  if not public.is_estate_owner(p_estate_id) then
    raise exception 'not estate owner' using errcode = '42501';
  end if;
  -- aal2 GATE: connecting an account is an owner financial action -> ALWAYS require MFA. UNCONDITIONAL
  -- (no tier — this persists the raw access_token). DEFINER bypasses RLS, so the gate must be HERE.
  perform public.require_aal2();

  insert into public.connections
    (estate_id, provider, institution_id, institution_name, reference_token, status)
  values
    (p_estate_id, p_provider, p_institution_id, p_institution_name, p_reference_token, 'active')
  returning id into v_id;

  -- The access_token lands ONLY here (grant-less table). Same row id as the connection.
  insert into public.connection_secrets (connection_id, provider, access_token)
  values (v_id, p_provider, p_access_token);

  perform public.write_audit(
    'connection.created', 'connections', v_id, p_estate_id,
    jsonb_build_object('provider', p_provider, 'institution_name', p_institution_name)
  );

  return query select c.* from public.connections c where c.id = v_id;
end;
$function$;
