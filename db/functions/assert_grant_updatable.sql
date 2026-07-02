-- public.assert_grant_updatable(p_grant_id uuid) -> public.access_grants (the target row)
--
-- Shared guard for the in-place tier-edit RPCs (update_asset_grant / update_document_grant): the
-- COMMON guards both stacks need, factored out so they cannot drift. Owner-gate-FIRST (the DEFINER
-- boundary) + the grant exists + is active. Does NOT check the ceiling — that is per-stack (asset =
-- explicit asset_category_grantable; document = the enforce_grant_ceiling trigger on the UPDATE).
--
-- SECURITY DEFINER: reads access_grants (which is RLS-guarded) and returns the row only after the
-- owner-gate, so a non-owner caller raises 42501 before any row leaves. Internal — called by the
-- update_*_grant RPCs, but safe if called directly (the owner-gate is the boundary).
--
-- Errors: 42501 -> 403 (unauthenticated / not estate owner); P0001 -> 400 (grant not found/inactive).

create or replace function public.assert_grant_updatable(p_grant_id uuid)
 returns public.access_grants
 language plpgsql
 stable
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_row public.access_grants;
begin
  if v_uid is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;

  select * into v_row from public.access_grants where id = p_grant_id;
  if not found or v_row.status <> 'active' then
    raise exception 'grant not found or not active';  -- P0001 -> 400
  end if;

  -- SECURITY SPINE: only the estate owner may edit a grant (DEFINER bypasses RLS, so this explicit
  -- check IS the access boundary). Self/owner-reject isn't re-checked — the row already passed it at
  -- create; an update only changes the tier, never the grantee.
  if not public.is_estate_owner(v_row.estate_id) then
    raise exception 'not estate owner' using errcode = '42501';
  end if;

  return v_row;
end;
$function$;
