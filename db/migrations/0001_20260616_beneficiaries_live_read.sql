-- db/migrations/0001_20260616_beneficiaries_live_read.sql
--
-- Beneficiaries live-read slice. Idempotent; safe to re-run on a DB reset.
--
-- Captured here, in build order:
--   STEP 1 — link column: beneficiaries.user_id (bare uuid, nullable, NO FK)
--   STEP 3 — RLS read-policy rewrite  (appended in step 3)
--
-- Captured in their own source-of-truth files (NOT duplicated here):
--   - GRANT select on beneficiaries to authenticated -> db/grants.sql        (step 4)
--   - accept_invitation() beneficiary stamp          -> db/functions/accept_invitation.sql (step 2)

-- =============================================================================
-- STEP 1 — link column
-- =============================================================================
-- Convention match: estate_memberships.user_id is a BARE uuid (no FK) holding
-- auth.uid(). beneficiaries.user_id mirrors that exactly — nullable, no FK.
-- Null until the designated person accepts their invitation; accept_invitation
-- stamps it by contact match within the estate (step 2). The RLS read policy
-- (step 3) keys on this column so a beneficiary-role caller sees only their own
-- designation row.
alter table public.beneficiaries
  add column if not exists user_id uuid;

comment on column public.beneficiaries.user_id is
  'auth.uid() of the user who accepted the beneficiary invitation for this row. '
  'Bare uuid, no FK (matches estate_memberships.user_id). Null until accepted. '
  'RLS read policy: a beneficiary sees only rows where user_id = auth.uid().';

-- =============================================================================
-- STEP 3 — RLS read-policy rewrite
-- =============================================================================
-- Old qual: (owner_id = auth.uid()) OR is_estate_member(estate_id)
-- That let ANY approved member — including a beneficiary — read EVERY beneficiary
-- row in the estate. That over-disclosure is the security bug this slice fixes.
--
-- New qual (OR of three clauses):
--   * owner_id = auth.uid()       belt-and-suspenders: the row's CREATOR can
--                                 always read rows they created, even if their
--                                 ownership membership is momentarily absent
--                                 (trigger timing / migration). This is
--                                 beneficiaries.owner_id (FK -> auth.users), NOT
--                                 estates.owner_id, so it does not violate the
--                                 Pattern-B "no estates.owner_id access" rule. It
--                                 never widens disclosure: owner_id on a row is
--                                 the estate owner, never a co-beneficiary, so a
--                                 beneficiary caller gains nothing from it.
--   * user_id = auth.uid()        a beneficiary sees ONLY their own stamped row.
--   * is_estate_owner(estate_id)  the owner sees ALL rows in the estate
--                                 (Pattern B: approved ownership membership).
--
-- beneficiaries_write is intentionally left unchanged.
--
-- Role scope kept as `public` to match the pre-existing policy (no side-effect
-- tightening in this slice). Safe: only `authenticated` holds the SELECT grant
-- (db/grants.sql), and auth.uid() is null for anon, so every clause below is
-- false for a non-authenticated caller. Standardizing to `to authenticated`
-- would be a separate, deliberate change.
drop policy if exists beneficiaries_read on public.beneficiaries;

create policy beneficiaries_read
  on public.beneficiaries
  for select
  to public
  using (
    owner_id = auth.uid()
    or user_id = auth.uid()
    or public.is_estate_owner(estate_id)
  );
