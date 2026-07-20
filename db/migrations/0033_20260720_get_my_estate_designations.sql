-- 0033_20260720_get_my_estate_designations — the iOS executor signal (Slice C1.6a-iOS).
--
-- The app has NO way today to know the current user is an executor of an estate (PlatformAccountRole has no
-- executor; nothing reads estate_designations). The death-claim evidence-submit flow must be shown ONLY to an
-- active designated executor — otherwise the UI offers a Submit button that would just return not_estate_executor.
--
-- This is the MINIMAL signal: a DEFINER RPC returning the CALLER's own ACTIVE designations (executor/trustee)
-- per estate, called DIRECTLY via supabase-swift (no Vercel endpoint → api stays 12/12). The app filters by the
-- current estate to decide whether to show/enable the submit surface. The full EstateRole vocabulary remap (the
-- executor-arc deferral) STAYS DEFERRED — this does not touch PlatformAccountRole / estate_memberships.
--
-- estate_designations is grant-less (born clean); this DEFINER RPC reads it as owner and is scoped to
-- auth.uid() (a caller sees only THEIR OWN designations — no probing others). EXECUTE authenticated only.
-- Captured in db/functions/. Re-apply on reset.

begin;

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

commit;
