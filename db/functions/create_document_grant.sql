-- public.create_document_grant(
--   p_estate_id uuid, p_grantee_user_id uuid, p_grantee_role text,
--   p_document_id uuid, p_visibility_tier text, p_release_condition text,
--   p_professional_type text default null, p_requires_step_up boolean default false)
--   -> SETOF public.access_grants   (the created grant row)
--
-- The audited, single-entry interface for creating a PER-DOCUMENT access grant
-- (docs/live-data-migration.md Appendix A.2). Wraps the direct INSERT into
-- public.access_grants so every grant creation runs the same owner-check, self/owner
-- rejection, ceiling, and audit. Document-scoped by design: takes p_document_id, never
-- a category — the document_id XOR category table invariant is satisfied structurally
-- (category stays NULL). Category grants get their own RPC when the Assets path is built.
--
-- SECURITY (load-bearing): SECURITY DEFINER runs as the table owner and BYPASSES RLS,
-- so the access_grants_insert WITH CHECK (is_estate_owner) does NOT auto-apply. The
-- explicit is_estate_owner(p_estate_id) check below IS the access boundary — it is the
-- FIRST check after the auth.uid() null-guard and runs BEFORE any insert. Without it,
-- ANY authenticated user could grant themselves access (privilege escalation). The
-- inherited table guards still fire on the INSERT regardless of caller: the
-- enforce_grant_ceiling trigger (restricted/sealed ceiling) and all CHECK constraints
-- + the one-active-grant-per-(estate,grantee,document) unique index.
--
-- Pre-granting is allowed: the RPC does NOT require the grantee to be an existing
-- member. A grant to a uid that hasn't joined is inert until that uid authenticates
-- (access is re-evaluated at read against auth.uid(), like beneficiaries) — no security
-- hole, an unmatched grant never activates. The RPC trusts the caller to supply a valid
-- grantee_user_id (the iOS member-picker does); it intentionally does not validate
-- grantee existence, to keep pre-granting possible.
--
-- UUID-case: p_grantee_user_id / p_document_id are uuid-typed, so Postgres canonicalizes
-- them to lowercase automatically — no manual lowercasing here.
--
-- Error codes (SQLSTATE -> PostgREST HTTP status; only mapped SQLSTATEs avoid 500):
--   42501 -> 403  unauthenticated (no auth.uid) / not_estate_owner (the privilege gate);
--                 the enforce_grant_ceiling trigger's ceiling violation surfaces here too
--   23505 -> 409  duplicate: an active grant already exists for this document + grantee
--   P0001 -> 400  validation: owner_grant (grantee is self/owner) OR document not in estate
--                 (P0001 is the default RAISE sqlstate; the two are distinguished by message)
--
-- SECURITY DEFINER; relies on auth.uid(). Source of truth — re-apply on DB reset.

create or replace function public.create_document_grant(
  p_estate_id uuid,
  p_grantee_user_id uuid,
  p_grantee_role text,
  p_document_id uuid,
  p_visibility_tier text,
  p_release_condition text,
  p_professional_type text default null,
  p_requires_step_up boolean default false
)
 returns setof public.access_grants
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

  -- SECURITY SPINE (privilege-escalation gate). SECURITY DEFINER bypasses RLS, so this
  -- explicit owner-check IS the access boundary and MUST precede any insert.
  if not public.is_estate_owner(p_estate_id) then
    raise exception 'not estate owner' using errcode = '42501';
  end if;

  -- Q1: no grants to owners (self, or any ownership-role member) — inherent access.
  if p_grantee_user_id = v_user
     or exists (
       select 1 from public.estate_memberships m
       where m.estate_id = p_estate_id
         and m.user_id = p_grantee_user_id
         and public.is_ownership_role(m.role)
     ) then
    raise exception 'cannot grant access to an owner; owners have inherent access';
      -- default sqlstate P0001 -> PostgREST 400 (validation)
  end if;

  -- The document must belong to this estate. Prevents inert cross-estate junk rows
  -- (a grant whose estate_id never matches the doc's real estate at read) and turns a
  -- missing/foreign doc into a clean error instead of a confusing ceiling-on-NULL from
  -- the trigger.
  if not exists (
    select 1 from public.documents d
    where d.id = p_document_id and d.estate_id = p_estate_id
  ) then
    raise exception 'document not found in this estate';  -- P0001 -> 400
  end if;

  -- Insert. The ceiling trigger + table CHECKs + unique indexes fire here regardless of
  -- the DEFINER context. Catch the one-active-grant unique violation and surface a
  -- readable error instead of a raw constraint failure (Q4: fail, never silent upsert).
  begin
    insert into public.access_grants
      (estate_id, grantee_user_id, grantee_role, professional_type,
       document_id, category, visibility_tier, release_condition,
       requires_step_up, granted_by_user_id)
    values
      (p_estate_id, p_grantee_user_id, p_grantee_role, p_professional_type,
       p_document_id, null, p_visibility_tier, p_release_condition,
       p_requires_step_up, v_user)
    returning id into v_id;
  exception
    when unique_violation then
      raise exception
        'an active grant already exists for this document and grantee; revoke it first'
        using errcode = '23505';   -- unique_violation -> PostgREST 409 Conflict
  end;

  perform public.write_audit(
    'access_grant.created',
    'access_grants',
    v_id,
    p_estate_id,
    jsonb_build_object(
      'grantee_user_id', p_grantee_user_id,
      'grantee_role', p_grantee_role,
      'document_id', p_document_id,
      'visibility_tier', p_visibility_tier,
      'release_condition', p_release_condition
    )
  );

  return query select g.* from public.access_grants g where g.id = v_id;
end;
$function$;
