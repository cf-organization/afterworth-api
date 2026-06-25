-- public.create_access_request(p_estate_id uuid, p_category text default 'estate_documents',
--                              p_reason text default null)
--   -> SETOF public.access_requests   (the created request row)
--
-- The FIRST beneficiary-initiated write. A NON-owner member of the estate requests access
-- to a category ('estate_documents' in V1); the owner later converts it to an
-- already-approved grant via approve_access_request. Mirrors the owner RPCs' care.
--
-- SECURITY (load-bearing): SECURITY DEFINER bypasses RLS, so the explicit gates below ARE
-- the boundary. requester_user_id is STAMPED = auth.uid() (never a client param —
-- anti-spoof, the same discipline as granted_by_user_id on grants). The MEMBER gate is the
-- INVERSE of the owner RPCs: an APPROVED estate_membership for auth.uid() AND a
-- non-ownership role (owners have inherent access — a request is meaningless, and is
-- rejected). A non-member calling this -> 42501.
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

  -- MEMBER GATE (privilege boundary; DEFINER bypasses RLS, so this explicit check IS the
  -- access boundary). Must be an APPROVED member AND a non-ownership role. Owners have
  -- inherent access and do not request — this is the inverse of the owner RPCs.
  if not exists (
    select 1 from public.estate_memberships m
    where m.estate_id = p_estate_id
      and m.user_id = v_user
      and m.status = 'approved'
      and not public.is_ownership_role(m.role)
  ) then
    raise exception 'not an estate member eligible to request access'
      using errcode = '42501';
  end if;

  -- Insert. requester_user_id STAMPED = auth.uid() (server-side, never a param). The
  -- one-pending partial unique fires here; surface a readable 409.
  begin
    insert into public.access_requests
      (estate_id, requester_user_id, category, reason, status)
    values
      (p_estate_id, v_user, p_category, p_reason, 'pending')
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
    jsonb_build_object('category', p_category)
  );

  return query select r.* from public.access_requests r where r.id = v_id;
end;
$function$;
