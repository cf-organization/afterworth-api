-- public.create_asset_grant(
--   p_estate_id uuid, p_grantee_user_id uuid, p_grantee_role text,
--   p_category text, p_visibility_tier text, p_release_condition text,
--   p_professional_type text default null, p_requires_step_up boolean default false)
--   -> SETOF public.access_grants   (the created grant row)
--
-- B2b — the audited, single-entry interface for creating a CATEGORY-scoped ASSET disclosure grant
-- (the connected-financial-data counterpart of create_document_grant, which is document-only by
-- design). Category-scoped: takes p_category (one of the asset categories), never a document_id —
-- the document_id XOR category table invariant is satisfied structurally (document_id stays NULL).
--
-- WRITE-TIME CEILING (the load-bearing addition): the enforce_grant_ceiling TRIGGER only fires for
-- per-document grants (new.document_id is not null), so category grants bypass it. This RPC enforces
-- the asset ceiling explicitly via asset_category_grantable(role, category, tier) BEFORE the insert —
-- an over-ceiling grant (e.g. beneficiary + account_balances + full_detail) is REJECTED at write, not
-- merely clamped at read. B2a's read-time clamp in list_estate_assets remains the backstop, so a bad
-- grant can neither be stored (this) nor leak (that). Defense-in-depth on a financial-disclosure grant.
--
-- SECURITY (load-bearing): SECURITY DEFINER runs as the table owner and BYPASSES RLS, so the
-- access_grants_insert WITH CHECK (is_estate_owner) does NOT auto-apply. The explicit
-- is_estate_owner(p_estate_id) check below IS the access boundary — FIRST check after the auth.uid()
-- null-guard, BEFORE any insert. Without it any authenticated user could grant themselves access.
--
-- Pre-granting is allowed (matches create_document_grant + the B2a grant-based read): the RPC does
-- NOT require the grantee to be a member. A grant to a uid that hasn't joined is inert until that uid
-- authenticates (access re-evaluated at read against auth.uid()) — no hole, an unmatched grant never
-- activates.
--
-- UUID-case: p_grantee_user_id is uuid-typed -> Postgres canonicalizes to lowercase automatically.
--
-- Error codes (SQLSTATE -> PostgREST HTTP; only mapped SQLSTATEs avoid 500):
--   42501 -> 403  unauthenticated / not_estate_owner (privilege gate) / ceiling violation
--   23505 -> 409  duplicate: an active grant already exists for this category + grantee
--   P0001 -> 400  validation: owner_grant (self/owner) OR invalid asset category
--
-- SECURITY DEFINER; relies on auth.uid(). Source of truth — re-apply on DB reset.

create or replace function public.create_asset_grant(
  p_estate_id uuid,
  p_grantee_user_id uuid,
  p_grantee_role text,
  p_category text,
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

  -- SECURITY SPINE (privilege-escalation gate). DEFINER bypasses RLS, so this explicit owner-check
  -- IS the access boundary and MUST precede any insert.
  if not public.is_estate_owner(p_estate_id) then
    raise exception 'not estate owner' using errcode = '42501';
  end if;

  -- No grants to owners (self, or any ownership-role member) — inherent access.
  if p_grantee_user_id = v_user
     or exists (
       select 1 from public.estate_memberships m
       where m.estate_id = p_estate_id
         and m.user_id = p_grantee_user_id
         and public.is_ownership_role(m.role)
     ) then
    raise exception 'cannot grant access to an owner; owners have inherent access';  -- P0001 -> 400
  end if;

  -- Category must be a real ASSET category (defense-in-depth beyond the access_grants.category CHECK;
  -- the RPC is the security boundary and may be called directly).
  if p_category not in
     ('account_balances', 'institution_names', 'total_asset_value', 'linked_account_details') then
    raise exception 'invalid asset category: %', p_category;  -- P0001 -> 400
  end if;

  -- ★ WRITE-TIME CEILING — reject an over-ceiling grant before storing it (the trigger skips category
  --   grants). Mirrors the read-time clamp in list_estate_assets: e.g. beneficiary + account_balances
  --   + full_detail -> asset_category_grantable = false -> rejected here.
  if not public.asset_category_grantable(p_grantee_role, p_category, p_visibility_tier) then
    raise exception 'asset grant ceiling: role % cannot be granted tier % for category %',
      p_grantee_role, p_visibility_tier, p_category
      using errcode = '42501';   -- ceiling violation -> 403 (mirrors document_grantable)
  end if;

  -- Insert (category-scoped: document_id NULL). Table CHECKs + the one-active-grant-per-(estate,
  -- grantee,category) unique index fire regardless of the DEFINER context. Catch the unique
  -- violation and surface a readable 409 (fail, never silent upsert — a silent tier change on a
  -- disclosure grant is dangerous; a tier change is revoke + re-create).
  begin
    insert into public.access_grants
      (estate_id, grantee_user_id, grantee_role, professional_type,
       document_id, category, visibility_tier, release_condition,
       requires_step_up, granted_by_user_id)
    values
      (p_estate_id, p_grantee_user_id, p_grantee_role, p_professional_type,
       null, p_category, p_visibility_tier, p_release_condition,
       p_requires_step_up, v_user)
    returning id into v_id;
  exception
    when unique_violation then
      raise exception
        'an active grant already exists for this category and grantee; revoke it first'
        using errcode = '23505';   -- unique_violation -> 409 Conflict
  end;

  perform public.write_audit(
    'access_grant.created',
    'access_grants',
    v_id,
    p_estate_id,
    jsonb_build_object(
      'grantee_user_id', p_grantee_user_id,
      'grantee_role', p_grantee_role,
      'category', p_category,
      'visibility_tier', p_visibility_tier,
      'release_condition', p_release_condition
    )
  );

  return query select g.* from public.access_grants g where g.id = v_id;
end;
$function$;
