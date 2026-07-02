-- public.update_document_grant(p_grant_id uuid, p_visibility_tier text) -> SETOF public.access_grants
--
-- In-place tier edit for a DOCUMENT grant — replaces revoke+recreate. Updates visibility_tier on the
-- existing ACTIVE row (unique key (estate, grantee, document_id, status='active') untouched -> NO 409).
--
-- CEILING: the enforce_grant_ceiling trigger is BEFORE INSERT OR UPDATE and re-checks
-- document_grantable(grantee_role, DOCUMENT SENSITIVITY) on THIS update automatically (it fires for
-- document_id-not-null rows). So the ceiling is re-enforced without an explicit call — mirroring
-- create_document_grant / approve_document_grant, which also lean on the trigger.
--   NOTE: document_grantable keys on the document's SENSITIVITY, not on a tier — documents have NO
--   per-tier ceiling, so the tier value itself is unconstrained. The trigger's job on update is to
--   reject editing a grant whose document was RECLASSIFIED above the role's ceiling since creation
--   (e.g. a doc turned 'sealed'). (An explicit document_grantable(role, new_tier) call would be a bug:
--   the tier string is not a sensitivity, so it would reject every update.)
--
-- Parallel to update_asset_grant: same shared guard (assert_grant_updatable) + audit; differs only in
-- ceiling mechanism (trigger here; explicit there) + scope (document here; category there). Tier
-- validity is enforced at the endpoint (TIERS set) + the table CHECK, as with create.
--
-- Errors: 42501 -> 403 (owner-gate / trigger ceiling); P0001 -> 400 (not found / not a document grant).

create or replace function public.update_document_grant(
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

  -- Scope: this RPC edits document grants only.
  if v_row.document_id is null then
    raise exception 'not a document grant';  -- P0001 -> 400
  end if;

  -- No-op if the tier is unchanged.
  if v_row.visibility_tier = p_visibility_tier then
    return query select g.* from public.access_grants g where g.id = p_grant_id;
    return;
  end if;

  -- Ceiling re-enforced by the enforce_grant_ceiling trigger (BEFORE UPDATE) on the line below —
  -- no explicit call (see header). A now-over-ceiling document (reclassified sealed/restricted) makes
  -- the trigger raise 42501 -> 403.
  update public.access_grants
     set visibility_tier = p_visibility_tier, updated_at = now()
   where id = p_grant_id;

  perform public.write_audit(
    'access_grant.updated', 'access_grants', p_grant_id, v_row.estate_id,
    jsonb_build_object(
      'document_id', v_row.document_id,
      'from_tier', v_row.visibility_tier,
      'to_tier', p_visibility_tier
    )
  );

  return query select g.* from public.access_grants g where g.id = p_grant_id;
end;
$function$;
