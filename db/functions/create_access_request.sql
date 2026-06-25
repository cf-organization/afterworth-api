-- public.create_access_request(p_estate_id uuid, p_category text default 'estate_documents',
--                              p_reason text default null)
--   -> SETOF public.access_requests   (the created request row)
--
-- A NON-owner member of the estate requests access to a category ('estate_documents' in V1);
-- the owner later converts it to an already-approved grant via approve_access_request.
--
-- SECURITY (load-bearing): SECURITY DEFINER bypasses RLS, so the explicit gate below IS the
-- boundary. requester_user_id is STAMPED = auth.uid() (never a client param — anti-spoof,
-- the same discipline as granted_by_user_id on grants). The MEMBER gate is the INVERSE of
-- the owner RPCs: an APPROVED estate_membership for auth.uid() AND a non-ownership role
-- (owners have inherent access — a request is meaningless, and is rejected). Non-member -> 42501.
--
-- requester_role: captured in the SAME membership lookup the gate performs (no second query)
-- and STAMPED onto the row, so the owner-review surface can show the SCOPE of an approval
-- (approving a professional_delegate grants RESTRICTED-doc access — more than a beneficiary;
-- document_grantable keys on role). The gate changed from an EXISTS to a SELECT ... INTO so
-- the one lookup both gates AND returns the role.
--
-- Dedup: the access_requests_one_pending partial unique (one pending per estate,requester,
-- category) fires on insert; surfaced as a readable 409.
--
-- Error codes (SQLSTATE -> PostgREST HTTP status):
--   42501 -> 403  unauthenticated / not an eligible member (privilege gate)
--   23505 -> 409  a pending request already exists for this (estate, requester, category)
--   P0001 -> 400  unsupported category (default RAISE sqlstate)
--
-- SECURITY DEFINER; relies on auth.uid(). Source of truth — re-apply on DB reset.

create or replace function public.create_access_request(
  p_estate_id uuid,
  p_category text default 'estate_documents',
  p_reason text default null
)
 returns setof public.access_requests
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_user uuid := auth.uid();
  v_requester_role text;
  v_id uuid;
begin
  -- Auth null-guard.
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;

  -- Category validation (V1: estate_documents only). Belt-and-suspenders with the table
  -- CHECK — a clean 400 instead of a raw constraint error.
  if p_category is distinct from 'estate_documents' then
    raise exception 'unsupported request category';  -- P0001 -> 400
  end if;

  -- MEMBER GATE + ROLE CAPTURE in ONE lookup (privilege boundary; DEFINER bypasses RLS, so
  -- this explicit check IS the access boundary). The ownership exclusion stays IN the WHERE
  -- (NOT a post-LIMIT check): a single (estate, user) is NOT guaranteed to have only one
  -- approved membership (accept_invitation inserts with no (estate,user) uniqueness; V2 adds
  -- more ownership roles), so a status-only select + post-check would be nondeterministic —
  -- it could grab an ownership row and wrongly reject a user who also has a non-ownership row.
  -- Filtering here makes this provably equivalent to the original EXISTS (passes iff an
  -- approved NON-ownership membership exists) AND captures that surviving role to stamp.
  select m.role into v_requester_role
  from public.estate_memberships m
  where m.estate_id = p_estate_id
    and m.user_id = v_user
    and m.status = 'approved'
    and not public.is_ownership_role(m.role)
  limit 1;

  if v_requester_role is null then
    raise exception 'not an estate member eligible to request access'
      using errcode = '42501';
  end if;

  -- Insert. requester_user_id + requester_role STAMPED server-side (never params). The
  -- one-pending partial unique fires here; surface a readable 409.
  begin
    insert into public.access_requests
      (estate_id, requester_user_id, requester_role, category, reason, status)
    values
      (p_estate_id, v_user, v_requester_role, p_category, p_reason, 'pending')
    returning id into v_id;
  exception
    when unique_violation then
      raise exception
        'a pending access request already exists for this category; await a decision'
        using errcode = '23505';   -- -> 409 Conflict
  end;

  perform public.write_audit(
    'access_request.created',
    'access_requests',
    v_id,
    p_estate_id,
    jsonb_build_object('category', p_category, 'requester_role', v_requester_role)
  );

  return query select r.* from public.access_requests r where r.id = v_id;
end;
$function$;
