-- public.aal2_is_current() -> boolean
--
-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- ★ WHY THIS EXISTS: `aal2` IN A JWT IS A MEMORY, NOT A FACT.
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- `require_aal2()` used to read `auth.jwt() ->> 'aal'` and nothing else. That claim is STATELESS: it
-- records what was true at the moment GoTrue minted the token, and no later event can change it.
--
-- MEASURED ON THE NONPROD PROJECT, 2026-10-01, on a dedicated MFA account that owns nothing else:
--
--   1. enrol a TOTP factor, verify it            -> the session is aal2
--   2. RETAIN that access token                  -> `aal` = aal2, lifetime 3600s
--   3. positive control, with that token         -> get_estate_net_worth returns HTTP 200
--   4. recover (POST /api/auth/mfa/recover)      -> HTTP 200: factor DELETED, sessions REVOKED
--   5. the SAME token, three seconds later       -> get_estate_net_worth returns HTTP 200  ✗
--
-- So for up to SIXTY MINUTES after a user says "I lost my authenticator, lock it out", the device
-- holding the old token keeps full access to the exact estate totals and holdings that aal2 exists to
-- protect. Recovery is the lost-device path; the window is open precisely when it matters most.
--
-- ★ AND IT IS NOT FIXED BY A SHORTER TOKEN LIFETIME. A shorter lifetime shrinks the window; it never
--   closes it, and it taxes every request in the product to do so. Nor is it fixed by GoTrue's global
--   logout, which revokes REFRESH tokens — the outstanding ACCESS token is stateless and unrevokable
--   by construction. The only thing that can close it is the gate asking the SERVER, at call time,
--   whether the assurance the token remembers is still true.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- THE THREE LEGS, AND WHY EACH IS SEPARATELY NECESSARY
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
--   LEG 1 · the token must CLAIM aal2.           The original check, unchanged, and still first: it is
--           free, and it is the only leg that can be true for a caller who never stepped up at all.
--
--   LEG 2 · the SESSION must still exist, belong to this user, and not be past `not_after`.
--           This is the leg that fires on recovery and on every global sign-out — the user's own
--           "log me out everywhere" becomes immediate for privileged operations instead of
--           eventually-consistent with the token clock.
--
--   LEG 3 · a VERIFIED factor must still exist for this user.
--           This is the leg that fires on factor removal — recovery, an admin reset, or the user's own
--           unenrol — even if a session row somehow outlives it. It is also the leg that states the
--           real invariant: GoTrue only ever issues aal2 to someone who verified a factor, so a
--           caller with no verified factor cannot legitimately be at aal2, whatever their token says.
--
-- Legs 2 and 3 fail INDEPENDENTLY. Either alone closes the measured window; both are kept because
-- they close it for different reasons, and a single mechanism that is one platform change away from
-- being wrong is not defence in depth.
--
-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- DESIGN NOTES THAT ARE LOAD-BEARING
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- ★ SECURITY DEFINER, DELIBERATELY. `auth.sessions` and `auth.mfa_factors` are not readable by
--   `authenticated`, and two of the AAL2 gates are RESTRICTIVE RLS POLICIES evaluated AS that role —
--   an invoker-rights predicate would raise "permission denied" there instead of answering. DEFINER
--   is safe here in the strict sense: the function takes NO arguments, so a caller cannot aim it. It
--   answers exactly one question, about the caller's own request, as a boolean.
--
-- ★ IT RETURNS A BOOLEAN AND RAISES NOTHING. `require_aal2()` owns the exception and its sentinel
--   message; a policy needs a predicate. One body, two shapes, no second copy of the rule.
--
-- ★ THE LEGS ARE NOT DISTINGUISHED TO THE CALLER, AND THAT IS A CHOICE. "your factor was deleted"
--   and "your session was revoked" are facts about another device's state, and the caller holding a
--   stale token is the one party who should not be told which. Every refusal is the same
--   `mfa_required` the client already handles, so this change needs no client release to be safe.
--
-- ★ CALL IT FROM A POLICY AS `(select public.aal2_is_current())`. Wrapped in a scalar subquery the
--   planner evaluates it ONCE PER STATEMENT as an InitPlan; written bare it is a STABLE call in a
--   qual and is evaluated PER ROW. On `normalized_assets` that is the difference between two index
--   lookups and two per asset.
--
-- Source of truth — re-apply on DB reset. Migration: 0064_20261001_aal2_session_currency.sql.

create or replace function public.aal2_is_current()
 returns boolean
 language plpgsql
 stable
 security definer
 set search_path to 'public', 'auth', 'extensions'
as $function$
declare
  v_claims  jsonb := coalesce(auth.jwt(), '{}'::jsonb);
  v_uid     uuid;
  v_session uuid;
begin
  -- LEG 1 — the token must claim aal2. Absent claim coalesces to aal1: fail-closed.
  if coalesce(v_claims ->> 'aal', 'aal1') <> 'aal2' then
    return false;
  end if;

  v_uid := auth.uid();
  if v_uid is null then
    return false;
  end if;

  -- LEG 2 — the session that minted the claim must still be live, and be THIS user's.
  -- A malformed or absent session_id is refused rather than waived: a token shape we do not
  -- recognise is not a token we can vouch for.
  begin
    v_session := nullif(v_claims ->> 'session_id', '')::uuid;
  exception when others then
    return false;
  end;
  if v_session is null then
    return false;
  end if;
  if not exists (
    select 1 from auth.sessions s
     where s.id = v_session
       and s.user_id = v_uid
       and (s.not_after is null or s.not_after > now())
  ) then
    return false;
  end if;

  -- LEG 3 — a verified factor must still exist for this user.
  if not exists (
    select 1 from auth.mfa_factors f
     where f.user_id = v_uid
       and f.status::text = 'verified'
  ) then
    return false;
  end if;

  return true;
end;
$function$;
