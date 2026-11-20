-- public.connector_disclosure_tier(p_estate, p_uid, p_category) -> text
--
-- ★ MIRROR of migration 0066. The migration is the authority; this copy exists for the consumers that
-- cannot read a migration (the bundle builders and the SQL authorization harness), and
-- test/beneficiaryConnectorDisclosure.test.ts holds the two byte-identical (whitespace-normalised).
--
-- THE ONE per-estate resolution every connector reader uses: the active grant's tier for THIS estate
-- under the canonical release predicate, clamped by the read-time ceiling for the grant's own role;
-- 'hidden' for anything it cannot resolve. Ownership is not consulted here — callers branch on
-- is_estate_owner first. No fallback to another estate exists, by construction.

create or replace function public.connector_disclosure_tier(p_estate uuid, p_uid uuid, p_category text)
 returns text
 language plpgsql
 stable
 security definer
 set search_path to 'public'
as $function$
declare v_tier text; v_role text;
begin
  if p_uid is null or p_estate is null then return 'hidden'; end if;

  select g.visibility_tier, g.grantee_role into v_tier, v_role
    from public.access_grants g
   where g.estate_id = p_estate
     and g.grantee_user_id = p_uid
     and g.category = p_category
     and g.status = 'active'
     and public.release_condition_satisfied(g.release_condition, g.approved_at, 'legacy_immediate_only',
                                            public.estate_lifecycle_state(p_estate))
   limit 1;

  if v_tier is null then return 'hidden'; end if;
  -- Read-time ceiling clamp (authoritative): a grant above its role's ceiling discloses nothing.
  if not public.asset_category_grantable(v_role, p_category, v_tier) then return 'hidden'; end if;
  return v_tier;
end;
$function$;
revoke execute on function public.connector_disclosure_tier(uuid, uuid, text) from public, anon, authenticated;
