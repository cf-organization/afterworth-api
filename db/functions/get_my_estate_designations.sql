-- public.get_my_estate_designations() -> TABLE(estate_id uuid, designation_type text, status text)
--
-- Slice C1.6a-iOS (migration 0033). The iOS executor signal — returns the CALLER's own ACTIVE designations
-- (executor/trustee) per estate. Called DIRECTLY via supabase-swift (no Vercel endpoint; api stays 12/12). The
-- app filters by the current estate to gate the death-claim evidence-submit surface — so no one is shown a
-- Submit that would return not_estate_executor.
--
-- Scoped to auth.uid() (a caller sees only their own designations — no probing). DEFINER because
-- estate_designations is grant-less (born clean); reads it as owner. STABLE. EXECUTE authenticated only.
-- The full EstateRole vocabulary remap (executor-arc deferral) stays deferred — this touches nothing else.
--
-- Source of truth — re-apply on DB reset.

create or replace function public.get_my_estate_designations()
 returns table(estate_id uuid, designation_type text, status text)
 language sql
 security definer
 stable
 set search_path to 'public'
as $function$
  select d.estate_id, d.designation_type, d.status
  from public.estate_designations d
  where d.user_id = auth.uid() and d.status = 'active';
$function$;
revoke execute on function public.get_my_estate_designations() from public, anon;
grant  execute on function public.get_my_estate_designations() to authenticated;
