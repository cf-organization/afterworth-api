-- public.approve_document_grant(p_grant_id uuid) -> SETOF public.access_grants
--
-- Owner-gated approval of an access grant — sets approved_at + approved_by_user_id
-- atomically and writes an access_grant.approved audit event. Activates
-- after_owner_approval grants: can_access_document passes them once approved_at is set
-- (see db/migrations/0003). Idempotent: approving an already-approved grant returns it
-- unchanged with no duplicate audit.
--
-- THE GENERIC GRANT-APPROVAL PRIMITIVE (docs/live-data-migration.md Appendix A.4) — reused
-- by the later access-request flow + V2 co-owner approval; it does NOT itself implement
-- access requests. Generic by design: it approves ANY active grant; can_access_document
-- currently consults approved_at only for after_owner_approval (approving a grant whose
-- condition doesn't read it is a harmless no-op on visibility).
--
-- SECURITY (load-bearing): SECURITY DEFINER bypasses RLS; the grant's estate is resolved by
-- a read-only lookup, then the explicit is_estate_owner check gates the UPDATE. No mutation
-- before the owner-check. The enforce_grant_ceiling trigger (BEFORE INSERT OR UPDATE, no
-- column guard) RE-FIRES on the approve UPDATE and re-reads the document's CURRENT
-- sensitivity — approval cannot bypass the ceiling (a now-sealed doc -> 42501).
--
-- UUID-case: p_grant_id is uuid-typed — canonicalized automatically.
--
-- Error codes (SQLSTATE -> PostgREST HTTP status):
--   42501 -> 403  unauthenticated / not_estate_owner (privilege gate) / ceiling violation
--                 (from the enforce_grant_ceiling trigger on a now-over-ceiling doc)
--   P0001 -> 400  grant_not_found (default RAISE sqlstate)
--
-- SECURITY DEFINER; relies on auth.uid(). Source of truth — re-apply on DB reset.

create or replace function public.approve_document_grant(p_grant_id uuid)
 returns setof public.access_grants
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_user uuid := auth.uid();
  v_estate uuid;
  v_approved timestamptz;
begin
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;

  -- Read-only lookup to resolve the grant's estate for the owner-check. No mutation yet.
  select estate_id, approved_at into v_estate, v_approved
  from public.access_grants
  where id = p_grant_id;

  if v_estate is null then
    raise exception 'grant_not_found';  -- P0001 -> 400
  end if;

  -- SECURITY SPINE (privilege-escalation gate): must precede the UPDATE.
  if not public.is_estate_owner(v_estate) then
    raise exception 'not estate owner' using errcode = '42501';
  end if;

  -- Idempotent: already approved -> return as-is, no duplicate audit.
  if v_approved is not null then
    return query select g.* from public.access_grants g where g.id = p_grant_id;
    return;
  end if;

  -- The enforce_grant_ceiling trigger re-fires on this UPDATE and re-reads the document's
  -- CURRENT sensitivity; a doc reclassified above the grantee's ceiling raises 42501 here,
  -- so approval cannot become a ceiling bypass.
  update public.access_grants
     set approved_at = now(),
         approved_by_user_id = v_user,
         updated_at = now()
   where id = p_grant_id;

  perform public.write_audit(
    'access_grant.approved',
    'access_grants',
    p_grant_id,
    v_estate,
    jsonb_build_object('approved_by_user_id', v_user)
  );

  return query select g.* from public.access_grants g where g.id = p_grant_id;
end;
$function$;
