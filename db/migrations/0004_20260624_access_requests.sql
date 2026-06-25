-- db/migrations/0004_20260624_access_requests.sql
--
-- Beneficiary-initiated access-request lifecycle (after_access_request_approval).
-- The NEW part vs the grant-approval primitive (0003): a NON-owner member can REQUEST
-- access; the owner converts an approved request into an ALREADY-APPROVED grant in one
-- step. Reuses the approved_at primitive + can_access_document — it adds only WHO creates
-- the pending artifact. Idempotent; safe to re-run on a DB reset.
--
-- V1 SCOPE: CATEGORY-scoped requests ('estate_documents') only. Sidesteps the
-- can't-see-an-ungranted-document tension (documents_read hides ungranted docs from
-- non-owners); a category is not secret. Per-document / manifest requests are a deferred
-- slice (gated on the titles-disclosure decision).
--
-- SECURITY — FIRST beneficiary-initiated WRITE in the schema. Boundary parity with the
-- owner RPCs:
--   * create_access_request: member-gated (EXISTS approved estate_membership for
--     auth.uid()) AND non-ownership role; requester_user_id STAMPED = auth.uid()
--     server-side (never a client param).
--   * approve / deny_access_request: owner-gated (is_estate_owner FIRST).
--   * RLS select: requester sees OWN, owner sees ALL in estate (no cross-beneficiary).
--   * Writes are RPC-ONLY: authenticated gets SELECT only — NO direct insert/update grant
--     (avoids the access_grants transition-debt). The SECURITY DEFINER RPCs are the sole
--     write path; their explicit gates ARE the boundary (DEFINER bypasses RLS).
--
-- Captured here, in build order:
--   STEP 1 — public.access_requests table (3-state: pending | approved | denied)
--   STEP 2 — RLS (select: own-or-owner) + SELECT grant to authenticated
--   STEP 3 — can_access_document: MERGE after_access_request_approval into the approved
--            clause (both gate on approved_at — "owner approved the access")
-- RPCs live in db/functions/: create_access_request, approve_access_request,
-- deny_access_request. See docs/live-data-migration.md Appendix A.4.

-- =============================================================================
-- STEP 1 — access_requests table
-- =============================================================================
create table if not exists public.access_requests (
  id                    uuid primary key default gen_random_uuid(),
  estate_id             uuid not null,
  -- requester_user_id: BARE uuid, NO FK (mirrors access_grants.grantee_user_id /
  -- estate_memberships.user_id — auth.users is not FK-referenced). STAMPED = auth.uid()
  -- by create_access_request, never a client param (anti-spoof, like granted_by_user_id).
  requester_user_id     uuid not null,
  -- V1: 'estate_documents' only. CHECK prevents a typo'd category that would silently
  -- never match the category grant at read (same drift caution as access_grants.category).
  category              text not null
                          check (category in ('estate_documents')),
  reason                text,
  status                text not null default 'pending'
                          check (status in ('pending','approved','denied')),
  created_at            timestamptz not null default now(),
  resolved_at           timestamptz,
  resolved_by_user_id   uuid,
  -- provenance: the grant created on approval; also links the EXISTING grant when approval
  -- finds an active category grant already present (idempotent already-granted path).
  resulting_grant_id    uuid
);

-- One ACTIVE pending request per (estate, requester, scope). A re-request while one is
-- pending -> 23505 (409). After a denial the row is 'denied' (NOT covered by this partial
-- index), so a fresh 'pending' row is allowed — the "re-request after denial" rule, in DB.
create unique index if not exists access_requests_one_pending
  on public.access_requests (estate_id, requester_user_id, category)
  where status = 'pending';

-- Owner's pending-list read path.
create index if not exists access_requests_estate_status
  on public.access_requests (estate_id, status);

-- =============================================================================
-- STEP 2 — RLS + grants
-- =============================================================================
alter table public.access_requests enable row level security;

-- Requester sees ONLY their own rows; owner sees ALL rows in the estate. No
-- cross-beneficiary visibility (same self-scoping as beneficiaries_read). This is the
-- READ boundary; writes never use this path (RPC-only).
drop policy if exists access_requests_select on public.access_requests;
create policy access_requests_select
  on public.access_requests
  for select
  to authenticated
  using (
    requester_user_id = auth.uid()
    or public.is_estate_owner(estate_id)
  );

-- RPC-ONLY writes: SELECT only. With no insert/update grant, authenticated cannot write
-- directly; the SECURITY DEFINER RPCs (member/owner-gated) are the sole write path.
-- Deliberately tighter than access_grants (which kept a direct insert/update grant during
-- transition and now carries a "revoke the direct grant" follow-up) — no such debt here.
grant select on table public.access_requests to authenticated;

-- =============================================================================
-- STEP 3 — can_access_document: activate after_access_request_approval (MERGED)
-- =============================================================================
-- Re-declared from migration 0003 with ONE change: the final release clause now treats
-- after_access_request_approval IDENTICALLY to after_owner_approval — both gate on
-- approved_at IS NOT NULL ("owner approved the access"; they differ only by who initiated,
-- recorded in release_condition). Everything else is unchanged from 0003.
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

  -- Active release conditions: 'immediately' always; the two approval-based conditions
  -- once approved_at is set. after_owner_approval (owner-initiated) and
  -- after_access_request_approval (beneficiary-initiated) are the SAME gate — both mean
  -- "owner approved the access", differing only by initiator. All other signal-based
  -- conditions and 'never' still default-deny (A.4).
  return g.release_condition = 'immediately'
      or (g.release_condition in ('after_owner_approval','after_access_request_approval')
          and g.approved_at is not null);
end;
$$;
