-- public.deny_access_request(p_request_id uuid)
--   -> SETOF public.access_requests   (the denied request row)
--
-- Owner-gated denial of a PENDING access request. Marks it denied; creates NO grant. A
-- denied request frees the one-pending partial-unique slot, so the requester may
-- re-request (a new pending row). Denial-with-reason is deferred (matches the slice's
-- defer list).
--
-- Error codes (SQLSTATE -> PostgREST HTTP status):
--   42501 -> 403  unauthenticated / not_estate_owner (privilege gate)
--   P0001 -> 400  request_not_found / request_not_pending (default RAISE sqlstate)
--
-- SECURITY DEFINER; relies on auth.uid(). Source of truth — re-apply on DB reset.

create or replace function public.deny_access_request(p_request_id uuid)
 returns setof public.access_requests
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_user      uuid := auth.uid();
  v_estate    uuid;
  v_status    text;
  -- ★ PHASE 10-E — read alongside the estate, from the request row itself. The recipient of a
  -- decision notification is the person who made the request; it is never derived from who happens
  -- to hold a capability on this estate.
  v_requester uuid;
begin
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;

  -- Lock the request row for the txn.
  select estate_id, status, requester_user_id into v_estate, v_status, v_requester
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

  if v_status is distinct from 'pending' then
    raise exception 'request_not_pending';  -- P0001 -> 400
  end if;

  update public.access_requests
     set status = 'denied',
         resolved_at = now(),
         resolved_by_user_id = v_user
   where id = p_request_id;

  perform public.write_audit(
    'access_request.denied',
    'access_requests',
    p_request_id,
    v_estate,
    jsonb_build_object('outcome', 'denied')
  );

  -- ★ PHASE 10-E — the REQUESTER learns the outcome of THEIR OWN request. Only they receive it: a
  -- denial is not estate news, and no other member is told that someone asked and was refused.
  --
  -- NO DEEP LINK. There is nothing newly available to open, and sending a refused requester to an
  -- estate surface would be an invitation to a screen that says no.
  perform public.emit_lifecycle_notification(
    v_requester,
    v_estate,
    'access_request.denied',
    null
  );

  return query select r.* from public.access_requests r where r.id = p_request_id;
end;
$function$;
