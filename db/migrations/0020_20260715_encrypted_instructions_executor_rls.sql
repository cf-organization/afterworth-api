-- 0020_20260715_encrypted_instructions_executor_rls — reconcile the executor-read policy (Slice R commit #2).
--
-- The Slice-A capture flagged this policy as STRUCTURALLY UNREACHABLE: it gated SELECT on
-- estate_memberships.role IN ('executor','trustee') — phantom roles the membership CHECK forbids from ever
-- existing. Under the designation model (0019), executor/trustee are DESIGNATIONS, not membership roles.
-- Rewrite the policy to use is_estate_executor(estate_id, auth.uid()) — making the executor-read path
-- REACHABLE for the first time. The release gate (released = true) is preserved.
--
-- ONLY this one SELECT policy changes. The companion instructions_owner_all (owner_id = auth.uid()) is
-- UNTOUCHED. Postgres has no CREATE OR REPLACE POLICY, so drop + recreate.

begin;

drop policy if exists instructions_executor_read_after_release on public.encrypted_instructions;

create policy instructions_executor_read_after_release on public.encrypted_instructions
  for select using (
    released = true
    and public.is_estate_executor(encrypted_instructions.estate_id, auth.uid())
  );

commit;
