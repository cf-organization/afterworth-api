-- public.check_primary_user_matches_owner() — CAPTURED FROM LIVE 2026-07-09. LIVE IS AUTHORITATIVE.
--
-- BEFORE INSERT OR UPDATE trigger on public.estate_memberships: enforces that a `primary_user`/
-- `approved` membership's user_id equals the estate's owner_id (Pattern-B integrity — the primary
-- membership IS the owner). Was LIVE-ONLY; re-apply the FUNCTION on a DB reset. Trigger binding
-- already exists live.
--
-- ★ 1c CROSS-CHECK (verdict CLEAN): this guard SELF-LIMITS — the first branch returns NEW unchanged
--   for any row that is not (role='primary_user' AND status='approved'). So beneficiary /
--   professional_delegate memberships, and non-approved rows, are UNCONSTRAINED by it. Slice 2's
--   admin RPCs (create/revoke invitations; grant non-owner memberships) never touch a primary_user
--   row, so this trigger does NOT constrain them. It only fires meaningfully on estate creation
--   (ensure_primary_user_membership stamps user_id = owner_id, which this then verifies) and would
--   reject only a hand-built primary row whose user_id ≠ owner_id (P0008) or a missing estate
--   (P0007). No surprise for downstream slices.
--
-- DEPENDENCY NOTE: pins search_path = 'public', 'extensions' (consistent with the primary-membership
-- trigger family). Reads public.estates.owner_id (SECURITY DEFINER bypasses estates RLS).

create or replace function public.check_primary_user_matches_owner()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_owner_id uuid;
begin
  -- Only validate primary_user/approved rows. All other combinations
  -- skip this check (no constraint on beneficiary/professional_delegate
  -- rows, or on pending/revoked primary_user rows if those ever exist).
  if new.role <> 'primary_user' or new.status <> 'approved' then
    return new;
  end if;

  select owner_id into v_owner_id
  from public.estates
  where id = new.estate_id;

  if v_owner_id is null then
    raise exception 'estate_not_found'
      using errcode = 'P0007';
  end if;

  if new.user_id <> v_owner_id then
    raise exception 'primary_user_mismatch: estate_memberships.user_id (%) must match estates.owner_id (%) for role=primary_user',
      new.user_id, v_owner_id
      using errcode = 'P0008';
  end if;

  return new;
end;
$function$;

-- Trigger binding — already live; here for the from-scratch rebuild record only. Do NOT run on a DB
-- that already has the trigger.
--   create trigger estate_memberships_check_primary_user
--     before insert or update on public.estate_memberships
--     for each row execute function public.check_primary_user_matches_owner();
