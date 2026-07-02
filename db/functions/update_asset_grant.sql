-- public.update_asset_grant(p_grant_id uuid, p_visibility_tier text) -> SETOF public.access_grants
--
-- In-place tier edit for a CATEGORY (asset) grant — replaces revoke+recreate (which only existed to
-- dodge the one-active-grant 409). Updates visibility_tier on the existing ACTIVE row, so the unique
-- index key (estate, grantee, category, status='active') is untouched -> NO 409.
--
-- ★ CEILING RE-ENFORCED ON THE NEW TIER (the load-bearing point). The enforce_grant_ceiling trigger
-- SKIPS category grants (document_id null), so this EXPLICIT asset_category_grantable(role, category,
-- new_tier) check is the ONLY ceiling guard — an update MUST reject what create rejects, or an owner
-- could edit a beneficiary's account_balances from category_summary -> full_detail and leak exact
-- values (a hole create doesn't have). Same guard as create_asset_grant, on the new tier.
--
-- Parallel to update_document_grant: same shared guard (assert_grant_updatable) + audit; differs only
-- in ceiling (explicit here; trigger there) + scope (category here; document there).
--
-- Errors: 42501 -> 403 (owner-gate / ceiling); P0001 -> 400 (not found / not an asset grant).

create or replace function public.update_asset_grant(
  p_grant_id uuid,
  p_visibility_tier text
)
 returns setof public.access_grants
 language plpgsql
 volatile
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_row public.access_grants;
begin
  -- Common guards: owner-gate-first + exists + active.
  v_row := public.assert_grant_updatable(p_grant_id);

  -- Scope: this RPC edits category (asset) grants only.
  if v_row.category is null then
    raise exception 'not an asset grant';  -- P0001 -> 400
  end if;

  -- No-op if the tier is unchanged (avoid a spurious audit row).
  if v_row.visibility_tier = p_visibility_tier then
    return query select g.* from public.access_grants g where g.id = p_grant_id;
    return;
  end if;

  -- ★ Ceiling on the NEW tier (explicit — the trigger won't fire for category grants).
  if not public.asset_category_grantable(v_row.grantee_role, v_row.category, p_visibility_tier) then
    raise exception 'asset grant ceiling: role % cannot be granted tier % for category %',
      v_row.grantee_role, p_visibility_tier, v_row.category
      using errcode = '42501';
  end if;

  update public.access_grants
     set visibility_tier = p_visibility_tier, updated_at = now()
   where id = p_grant_id;

  perform public.write_audit(
    'access_grant.updated', 'access_grants', p_grant_id, v_row.estate_id,
    jsonb_build_object(
      'category', v_row.category,
      'from_tier', v_row.visibility_tier,
      'to_tier', p_visibility_tier
    )
  );

  return query select g.* from public.access_grants g where g.id = p_grant_id;
end;
$function$;
