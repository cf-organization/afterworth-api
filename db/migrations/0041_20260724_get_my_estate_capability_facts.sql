-- 0041_20260724_get_my_estate_capability_facts — the iOS live capability source's non-fiduciary
-- FACTS read (EstateRole Remap, Unit 2).
--
-- WHY: the iOS EstateCapabilitySource must resolve, for the signed-in caller + one estate, the
-- server-authoritative ownership + membership access-class signals. Neither estates nor
-- estate_memberships is client-readable (born-clean, RPC-only), and the only membership-bearing
-- RPC (resolve_membership) has WRITE side effects (it bootstraps an estate) — unusable as a
-- capability read. This adds the missing PURE, side-effect-free, auth.uid()-scoped read so the
-- client can build capabilities EXCLUSIVELY from live server facts (+ get_my_estate_designations
-- for the fiduciary axis), never from cached/derived client state.
--
-- ★ Pure read: STABLE, DEFINER (reads the grant-less estates / estate_memberships as owner but
-- exposes only the caller's own facts), no INSERT/UPDATE anywhere. Additive; changes nothing
-- about existing tables, policies, or RPCs. Supabase-direct (no Vercel endpoint — api function
-- count unchanged). Captured to VC: db/functions/get_my_estate_capability_facts.sql.

begin;

create or replace function public.get_my_estate_capability_facts(p_estate uuid)
 returns jsonb
 language plpgsql
 security definer
 stable
 set search_path to 'public'
as $function$
declare
  v_uid           uuid := auth.uid();
  v_estate_exists boolean;
  v_is_owner      boolean;
  v_role          text;
  v_status        text;
begin
  select exists(select 1 from public.estates e where e.id = p_estate)
    into v_estate_exists;

  select exists(select 1 from public.estates e where e.id = p_estate and e.owner_id = v_uid)
    into v_is_owner;

  -- estate_memberships is UNIQUE(estate_id, user_id) — at most one row; limit 1 is defensive.
  select m.role, m.status
    into v_role, v_status
    from public.estate_memberships m
   where m.estate_id = p_estate and m.user_id = v_uid
   limit 1;

  return jsonb_build_object(
    'estate_id',         p_estate,
    'estate_exists',     v_estate_exists,
    'is_owner',          v_is_owner,
    'membership_role',   v_role,
    'membership_status', v_status
  );
end;
$function$;

revoke execute on function public.get_my_estate_capability_facts(uuid) from public, anon;
grant  execute on function public.get_my_estate_capability_facts(uuid) to authenticated;

commit;
