-- public.can_access_document(p_document_id uuid) -> boolean
--
-- THE DOCUMENT AUTHORIZATION GATE. Consulted by the `documents` RLS read policy and by
-- `get_professional_workspace`; it is the only thing standing between a non-owner and a document row.
--
-- ★ EXTRACTED TO A SOURCE FILE IN PHASE 11-B. Until then its definition lived in
-- `db/migrations/0004_20260624_access_requests.sql` (re-declared from 0003, itself from 0002), with a
-- hand-written copy in `db/tests/preamble_real_auth.sql` that the harness's own anti-shadow guard
-- could not see — the guard searched `db/functions/` for a production counterpart and found none, so
-- it classified the estate's document gate as "a pure harness fixture" and skipped it. The copy
-- happened to match 0004. It is now comparable rather than lucky.
--
-- ★ THE RELEASE RULE IS NO LONGER WRITTEN HERE (Phase 11-B). It was one of seven copies; it is now
-- one call to `public.release_condition_satisfied`. The `'standard'` policy is the same rule this
-- function has carried since 0004 — `immediately`, plus the two approval-based conditions once
-- `approved_at` is set — and the SQL suite compares the predicate's full truth table rather than
-- taking that claim on trust.
--
-- Ladder, unchanged: owner inherent → per-document grant → `estate_documents` category fallback →
-- default-deny → ceiling re-check against CURRENT sensitivity → hidden tier → release condition.
--
-- SECURITY DEFINER; relies on auth.uid(). The DEFINER context is what lets the policy call it
-- without recursing through `documents`' own RLS. Source of truth — re-apply on DB reset.

create or replace function public.can_access_document(p_document_id uuid)
returns boolean
language plpgsql
security definer
stable
set search_path to 'public'
as $$
declare
  v_uid    uuid := auth.uid();
  v_estate uuid;
  v_sens   text;
  g        record;
begin
  if v_uid is null then
    return false;
  end if;

  select estate_id, sensitivity into v_estate, v_sens
  from public.documents
  where id = p_document_id;

  if v_estate is null then
    return false;
  end if;

  -- Owner inherent (A.1) — no grant row needed.
  if public.is_estate_owner(v_estate) then
    return true;
  end if;

  -- Non-owner: per-document grant first...
  select grantee_role, visibility_tier, release_condition, approved_at
    into g
  from public.access_grants
  where estate_id = v_estate
    and grantee_user_id = v_uid
    and status = 'active'
    and document_id = p_document_id
  limit 1;

  -- ...then category 'estate_documents' fallback (the access-request grant lands here).
  if not found then
    select grantee_role, visibility_tier, release_condition, approved_at
      into g
    from public.access_grants
    where estate_id = v_estate
      and grantee_user_id = v_uid
      and status = 'active'
      and category = 'estate_documents'
    limit 1;
  end if;

  if not found then
    return false;                                            -- default-deny (A.5)
  end if;

  -- Ceiling re-check against the document's CURRENT sensitivity (A.3). For a CATEGORY
  -- grant this is the ONLY ceiling enforcement (the write-time trigger no-ops on category
  -- grants), so a sealed/restricted doc stays hidden here even with the category grant.
  if not public.document_grantable(g.grantee_role, v_sens) then
    return false;
  end if;

  if g.visibility_tier = 'hidden' then
    return false;
  end if;

  -- ★ THE CANONICAL RELEASE PREDICATE (Phase 11-B) — was seven scattered copies, now one call.
  -- Since 11-D it consumes the AUTHORITATIVE lifecycle for THIS document's estate, resolved through
  -- the one sanctioned reader: `after_verified_death` opens exactly while the estate is
  -- death_verified. 'never', incapacity, the legacy fused value, identity and claim conditions stay
  -- dormant-deny (A.4), and an unknown condition or lifecycle refuses. No comparison happens here —
  -- the lifecycle is an ARGUMENT, and the policy stays in the predicate.
  return public.release_condition_satisfied(
    g.release_condition, g.approved_at, 'standard', public.estate_lifecycle_state(v_estate));
end;
$$;
