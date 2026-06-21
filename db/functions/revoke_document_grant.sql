-- public.revoke_document_grant(p_grant_id uuid) -> SETOF public.access_grants
--
-- Audited, single-entry interface for revoking an access grant
-- (docs/live-data-migration.md Appendix A.2). Sets status='revoked',
-- revoked_at=now(), revoked_by_user_id=auth.uid() atomically and writes an
-- access_grant.revoked audit event. Idempotent: revoking an already-revoked grant
-- returns it unchanged with no duplicate audit. The direct PATCH-to-status path
-- (RLS access_grants_update) stays valid during transition (curl ⑦).
--
-- SECURITY (load-bearing): SECURITY DEFINER bypasses RLS. The grant's estate is
-- resolved by a read-only lookup (required — the owner-check needs the estate), then
-- the explicit is_estate_owner check gates the UPDATE. No mutation occurs before the
-- owner-check.
--
-- The enforce_grant_ceiling trigger does NOT block revoke: it only enforces when the
-- resulting row is status='active', so a sealed-reclassified doc can still be revoked.
--
-- UUID-case: p_grant_id is uuid-typed — canonicalized automatically; no manual cast.
--
-- Error codes (SQLSTATE -> PostgREST HTTP status; only mapped SQLSTATEs avoid 500):
--   42501 -> 403  unauthenticated (no auth.uid) / not_estate_owner (the privilege gate)
--   P0001 -> 400  grant_not_found (default RAISE sqlstate; message distinguishes)
--
-- SECURITY DEFINER; relies on auth.uid(). Source of truth — re-apply on DB reset.

create or replace function public.revoke_document_grant(p_grant_id uuid)
 returns setof public.access_grants
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_user uuid := auth.uid();
  v_estate uuid;
  v_status text;
begin
  -- Auth null-guard.
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;

  -- Read-only lookup to resolve the grant's estate for the owner-check. No mutation
  -- happens before the gate below.
  select estate_id, status into v_estate, v_status
  from public.access_grants
  where id = p_grant_id;

  if v_estate is null then
    raise exception 'grant_not_found';  -- P0001 -> 400
  end if;

  -- SECURITY SPINE (privilege-escalation gate): must precede the UPDATE.
  if not public.is_estate_owner(v_estate) then
    raise exception 'not estate owner' using errcode = '42501';
  end if;

  -- Idempotent: already revoked -> return as-is, no duplicate audit.
  if v_status = 'revoked' then
    return query select g.* from public.access_grants g where g.id = p_grant_id;
    return;
  end if;

  update public.access_grants
     set status = 'revoked',
         revoked_at = now(),
         revoked_by_user_id = v_user,
         updated_at = now()
   where id = p_grant_id;

  perform public.write_audit(
    'access_grant.revoked',
    'access_grants',
    p_grant_id,
    v_estate,
    jsonb_build_object('revoked_by_user_id', v_user)
  );

  return query select g.* from public.access_grants g where g.id = p_grant_id;
end;
$function$;
