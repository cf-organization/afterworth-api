-- db/migrations/0005_20260626_access_request_requester_role.sql
--
-- Add requester_role to access_requests so the owner-review surface shows the SCOPE of what
-- an approval grants. A professional_delegate's approved request becomes a grant with
-- grantee_role='professional_delegate', which can_access_document admits to RESTRICTED docs
-- (document_grantable keys on role) — strictly more than a beneficiary. The owner must see
-- that BEFORE approving (informed disclosure). Role-keyed ACCESS is unchanged and was
-- already correct; this only surfaces the requester's role on the REQUEST row + wire.
-- Idempotent; safe to re-run on a DB reset.
--
-- requester_role is stamped at create time from the membership the member-gate ALREADY
-- resolves (no second lookup) — see db/functions/create_access_request.sql. Nullable: the
-- pre-existing rows (the 10/10 matrix fixtures) predate it; the CHECK permits null + the V1
-- non-owner roles, and the backfill below fills rows whose requester is still a member.

alter table public.access_requests
  add column if not exists requester_role text;

-- Vocabulary guard (mirrors access_grants.grantee_role): a requester is a NON-owner member,
-- so beneficiary | professional_delegate. NULL allowed for pre-existing / membership-gone rows.
-- (Postgres has no ADD CONSTRAINT IF NOT EXISTS, so guard with a catalog check.)
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'access_requests_requester_role_check'
  ) then
    alter table public.access_requests
      add constraint access_requests_requester_role_check
      check (requester_role is null or requester_role in ('beneficiary','professional_delegate'));
  end if;
end $$;

-- Backfill existing rows from the current approved membership; rows whose requester is no
-- longer an approved member stay NULL (the CHECK permits it).
update public.access_requests ar
   set requester_role = m.role
  from public.estate_memberships m
 where ar.requester_role is null
   and m.estate_id = ar.estate_id
   and m.user_id = ar.requester_user_id
   and m.status = 'approved';
