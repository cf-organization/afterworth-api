-- public.get_my_estate_capability_facts(p_estate uuid) -> jsonb
--
-- EstateRole Remap — Unit 2 (iOS live capability source). The authoritative, side-effect-free
-- read of the CALLER's non-fiduciary capability FACTS for ONE estate:
--   * estate_exists     — does the estate row exist at all (distinguishes "estate not found"
--                         from "estate exists but I have no standing"; a boolean existence
--                         oracle on an unguessable uuid — negligible leak, authenticated-only).
--   * is_owner          — auth.uid() == estates.owner_id (the authoritative ownership signal).
--   * membership_role   — the caller's OWN estate_memberships.role RAW string, or null when the
--                         caller has no membership row (a CONFIRMED negative, distinct from a
--                         transport failure). Decoded client-side into the canonical vocabulary
--                         (primary_user / beneficiary / professional_delegate / unknown-raw).
--   * membership_status — the caller's OWN membership status RAW string (client honors 'approved'
--                         only; pending/revoked/expired grant no access class).
--
-- Fiduciary designations are NOT here — they come SEPARATELY from get_my_estate_designations()
-- and are never inferred from ownership or the membership role. This RPC is pure factual identity
-- (ownership + membership), never UI permissions or resource grants.
--
-- Scoped to auth.uid() (a caller sees only their OWN facts — no probing of other users). DEFINER
-- because estates / estate_memberships are grant-less (born clean, RPC-only); it reads them as
-- owner but exposes only the caller-scoped facts above. STABLE (no writes — unlike resolve_membership,
-- which bootstraps an estate; this must never mutate). EXECUTE authenticated only.
--
-- Source of truth — re-apply on DB reset.

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
