-- db/migrations/0003_20260622_grant_approval.sql
--
-- Grant-APPROVAL primitive — activates the `after_owner_approval` release condition.
-- Idempotent; safe to re-run on a DB reset.
--
-- FOUNDATION, NOT an access-request flow: this is the generic "this grant is approved"
-- primitive. It activates exactly ONE dormant release_condition (after_owner_approval) and
-- proves the signal-plug-in point in can_access_document end-to-end, in isolation. The later
-- access-request slice (beneficiary requests -> owner approves) and V2 co-owner approval
-- REUSE this same approved_at column + approve path — they just add who creates the pending
-- grant. Every other signal-based condition (after_identity_verification,
-- after_access_request_approval, after_claim_case_approval, after_verified_death_or_incapacity)
-- still default-denies. See docs/live-data-migration.md Appendix A.4.
--
-- Captured here, in build order:
--   STEP 1 — approved_at / approved_by_user_id on access_grants (null = pending/unapproved)
--   STEP 2 — can_access_document: after_owner_approval passes once approved_at IS NOT NULL
--
-- Approval write path: public.approve_document_grant RPC (db/functions/) — owner-gated,
-- idempotent, audited. The enforce_grant_ceiling trigger (BEFORE INSERT OR UPDATE, no column
-- guard) re-fires on the approve UPDATE and re-reads the document's CURRENT sensitivity, so
-- approval CANNOT bypass the ceiling (a doc reclassified to sealed -> 42501 on approve).

-- =============================================================================
-- STEP 1 — approval state columns (nullable; null = pending/unapproved)
-- =============================================================================
-- Named for the STATE ("this grant is approved"), not the initiator — the same column is
-- reused by after_access_request_approval later (both gate on "owner approved the access").
-- No backfill: existing grants are release_condition='immediately', which ignores approved_at.
alter table public.access_grants
  add column if not exists approved_at timestamptz;
alter table public.access_grants
  add column if not exists approved_by_user_id uuid;

comment on column public.access_grants.approved_at is
  'When this grant was approved (null = pending/unapproved). Generic approval state: '
  'after_owner_approval passes only when set; reused by after_access_request_approval later. '
  'Set by approve_document_grant (owner-gated). See docs/live-data-migration.md A.4.';

-- =============================================================================
-- STEP 2 — can_access_document: honor after_owner_approval once approved
-- =============================================================================
-- Re-declared with approved_at added to both grant SELECTs and one new clause. Everything
-- else is unchanged from migration 0002 (owner inherent -> per-doc grant -> category
-- fallback -> default-deny; ceiling re-check; hidden-tier deny). The ONLY behavioral change:
-- after_owner_approval grants now pass when approved_at IS NOT NULL.
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

  -- Non-owner: per-document grant first... (now also reads approved_at)
  select grantee_role, visibility_tier, release_condition, approved_at
    into g
  from public.access_grants
  where estate_id = v_estate
    and grantee_user_id = v_uid
    and status = 'active'
    and document_id = p_document_id
  limit 1;

  -- ...then category 'estate_documents' fallback.
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

  -- Ceiling re-check against the document's CURRENT sensitivity (A.3).
  if not public.document_grantable(g.grantee_role, v_sens) then
    return false;
  end if;

  if g.visibility_tier = 'hidden' then
    return false;
  end if;

  -- Active release conditions: 'immediately' always; 'after_owner_approval' once approved.
  -- All other signal-based conditions (identity / access-request / claim / verified-event)
  -- and 'never' still default-deny — separate future slices (A.4).
  return g.release_condition = 'immediately'
      or (g.release_condition = 'after_owner_approval' and g.approved_at is not null);
end;
$$;
