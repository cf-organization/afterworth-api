-- public.approve_access_request(p_request_id uuid, p_visibility_tier text default 'limited_detail')
--   -> SETOF public.access_requests   (the approved request row, incl. resulting_grant_id)
--
-- Owner-gated approval of a beneficiary-initiated access request. ATOMIC, one-step:
-- creates an ALREADY-APPROVED category grant (category = request.category, document_id
-- null, release_condition = 'after_access_request_approval', approved_at = now()) AND
-- marks the request approved — both in this single plpgsql function, i.e. ONE transaction,
-- so they commit or roll back together. A failed grant insert leaves the request pending.
--
-- INLINE insert (not create_document_grant — that RPC is document-only, category null by
-- design). Promote to a create_category_grant RPC when the Assets path needs general
-- category grants; until then this is the only category-grant site.
--
-- TIER: the owner chooses disclosure via p_visibility_tier; default 'limited_detail'
-- (conservative — mirrors the sealed-default philosophy). Restricted to the two
-- document-meaningful tiers (matches the grant UI's tierOptions); a bad tier -> clean 400,
-- not a raw CHECK 500.
--
-- CEILING: enforce_grant_ceiling NO-OPs on a category grant (document_id null), so there
-- is no approval-time ceiling rejection. The ceiling is enforced AT READ, per-document, in
-- can_access_document (document_grantable) — a sealed/restricted doc stays hidden from the
-- grantee even with this category grant.
--
-- ALREADY-GRANTED: if an active category grant already exists for (estate, grantee,
-- category) (the access_grants one-active-category partial unique), the insert raises
-- 23505; we CATCH it, link the EXISTING grant via resulting_grant_id, and still mark the
-- request approved — idempotent, no duplicate, no error.
--
-- Error codes (SQLSTATE -> PostgREST HTTP status):
--   42501 -> 403  unauthenticated / not_estate_owner (privilege gate)
--   P0001 -> 400  request_not_found / request_not_pending / unsupported tier /
--                 requester no longer a member (default RAISE sqlstate)
--
-- SECURITY DEFINER; relies on auth.uid(). Source of truth — re-apply on DB reset.

create or replace function public.approve_access_request(
  p_request_id uuid,
  p_visibility_tier text default 'limited_detail'
)
 returns setof public.access_requests
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_user      uuid := auth.uid();
  v_estate    uuid;
  v_requester uuid;
  v_category  text;
  v_status    text;
  v_role      text;
  v_grant_id  uuid;
begin
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;

  -- Lock the request row for the txn (no concurrent double-approve).
  select estate_id, requester_user_id, category, status
    into v_estate, v_requester, v_category, v_status
  from public.access_requests
  where id = p_request_id
  for update;

  if v_estate is null then
    raise exception 'request_not_found';  -- P0001 -> 400
  end if;

  -- SECURITY SPINE (privilege gate): owner-only, BEFORE any mutation.
  if not public.is_estate_owner(v_estate) then
    raise exception 'not estate owner' using errcode = '42501';
  end if;

  -- Only a pending request can be approved (prevents double-approve / duplicate grant).
  if v_status is distinct from 'pending' then
    raise exception 'request_not_pending';  -- P0001 -> 400
  end if;

  -- Owner-chosen disclosure tier; restrict to the two document-meaningful tiers (mirrors
  -- the grant UI's tierOptions). Avoids a raw CHECK violation (500) on a bad tier.
  if p_visibility_tier not in ('full_detail','limited_detail') then
    raise exception 'unsupported visibility tier';  -- P0001 -> 400
  end if;

  -- Resolve the requester's CURRENT role in the estate (for grantee_role + the ceiling
  -- matrix). If they are no longer an approved member, do not grant.
  select m.role into v_role
  from public.estate_memberships m
  where m.estate_id = v_estate
    and m.user_id = v_requester
    and m.status = 'approved'
  limit 1;

  if v_role is null then
    raise exception 'requester is not an active member of this estate';  -- P0001 -> 400
  end if;

  -- Create the ALREADY-APPROVED category grant (inline; create_document_grant is doc-only).
  -- enforce_grant_ceiling no-ops here (document_id null). The one-active-category-grant
  -- unique index may fire -> already-granted path in the handler below.
  begin
    insert into public.access_grants
      (estate_id, grantee_user_id, grantee_role, professional_type,
       document_id, category, visibility_tier, release_condition,
       requires_step_up, status, granted_by_user_id,
       approved_at, approved_by_user_id)
    values
      (v_estate, v_requester, v_role, null,
       null, v_category, p_visibility_tier, 'after_access_request_approval',
       false, 'active', v_user,
       now(), v_user)
    returning id into v_grant_id;
  exception
    when unique_violation then
      -- Already-granted: an active category grant exists for this grantee. Link it, mark
      -- the request approved, no duplicate, no error (idempotent).
      select g.id into v_grant_id
      from public.access_grants g
      where g.estate_id = v_estate
        and g.grantee_user_id = v_requester
        and g.category = v_category
        and g.status = 'active'
      limit 1;
  end;

  update public.access_requests
     set status = 'approved',
         resolved_at = now(),
         resolved_by_user_id = v_user,
         resulting_grant_id = v_grant_id
   where id = p_request_id;

  perform public.write_audit(
    'access_request.approved',
    'access_requests',
    p_request_id,
    v_estate,
    jsonb_build_object(
      'grant_id', v_grant_id,
      'category', v_category,
      'grantee_user_id', v_requester,
      'visibility_tier', p_visibility_tier
    )
  );

  return query select r.* from public.access_requests r where r.id = p_request_id;
end;
$function$;
