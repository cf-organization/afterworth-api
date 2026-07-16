-- 0027_20260716_required_verification_level — Slice C3 (part 2): THE monotonic policy engine.
--
-- LOCKED INVARIANT (the reason this slice exists):
--     required_level = GREATEST(jurisdiction_floor, escalation_max)
-- Monotonic — risk factors ONLY escalate UPWARD, NEVER waive below the jurisdiction floor. Unknown/unapproved
-- jurisdiction -> the HIGHEST floor (enhanced_kyc, fail closed).
--
-- THE INVARIANT IS STRUCTURAL, not conventional:
--   * The ONLY combinator is GREATEST(). There is NO code path that returns a level BELOW v_floor — a reviewer
--     (or a future `grep -i 'return'`) confirms monotonicity by the ABSENCE of any downward branch. Every
--     escalation factor is a CASE that MAPS a server-derived input to a level (monotone in the input); the
--     factors are only ever fed INTO the final GREATEST, never subtracted, never LEAST-ed.
--   * Fail-closed on unknown: an unmapped OR unapproved jurisdiction yields v_floor := enhanced_kyc IN CODE
--     (the table ships empty by design), so "unknown = maximum" cannot be broken by deleting a config row.
--   * Unbypassable: the function takes ONLY p_estate. There is NO client-supplied level parameter to inject;
--     ALL inputs (jurisdiction, estate value) are server-derived from the estate id.
--
-- Grant posture (2c): the engine is DEFINER-INTERNAL (revoked from every client role) so claims RPCs (C4/C5)
-- call it as owner and the invariant reads clean. preview_required_verification_level is the ONLY client door:
-- gated to a party of the estate (executor/owner/admin) — the RESULT is not secret to the claimant (they must
-- know what to pass), but the full jurisdiction matrix IS (protected separately, world-unreadable).

begin;

create or replace function public.required_verification_level(p_estate uuid)
 returns public.verification_level
 language plpgsql
 security definer
 stable
 set search_path to 'public'
as $function$
declare
  v_juris       text;
  v_floor       public.verification_level;
  v_value_cents bigint;
  v_value_level public.verification_level;
begin
  -- (1) JURISDICTION FLOOR — the immovable legal minimum. Unmapped OR unapproved -> enhanced_kyc (fail closed).
  select e.jurisdiction into v_juris from public.estates e where e.id = p_estate;
  select jp.floor_level into v_floor
    from public.jurisdiction_policy jp
    where jp.jurisdiction = v_juris and jp.is_counsel_approved = true;
  if v_floor is null then
    v_floor := 'enhanced_kyc';   -- STRUCTURAL fail-closed: unknown/unapproved = maximum
  end if;

  -- (2) ESCALATION FACTORS — each maps a SERVER-DERIVED input to a level; each can only RAISE.
  --     Estate value (normalized_assets): a value-tier CASE, monotone in value.
  select coalesce(sum(na.balance_cents), 0) into v_value_cents
    from public.normalized_assets na where na.estate_id = p_estate;
  v_value_level := case
    when v_value_cents >= 100000000 then 'enhanced_kyc'::public.verification_level   -- >= $1,000,000
    when v_value_cents >=  10000000 then 'kyc'::public.verification_level             -- >= $100,000
    else 'attestation'::public.verification_level
  end;
  -- (future factors — international participants [always >= kyc], fraud signals, owner override — each becomes
  --  ONE more argument to the GREATEST below. No data source exists for them yet, so they are OMITTED, not
  --  stubbed at a low level. Adding one CANNOT lower the result — it can only add an upward contributor.)

  -- (3) MONOTONIC COMBINE — the ONLY combinator. No path returns below v_floor.
  return greatest(v_floor, v_value_level);
end;
$function$;
revoke execute on function public.required_verification_level(uuid) from public, anon, authenticated;

-- ==================================================================================================
-- preview_required_verification_level — the ONLY client door to the RESULT. Gated to a party of the estate.
-- ==================================================================================================
create or replace function public.preview_required_verification_level(p_estate uuid)
 returns text
 language plpgsql
 security definer
 stable
 set search_path to 'public'
as $function$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;
  -- The result is not secret to a PARTY of the estate (they must know what verification to pass); a
  -- non-party cannot probe arbitrary estates. The jurisdiction matrix itself stays unreadable.
  if not (public.is_estate_executor(p_estate, v_uid)
          or public.is_estate_owner(p_estate)
          or public.is_admin()) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return public.required_verification_level(p_estate)::text;
end;
$function$;
revoke execute on function public.preview_required_verification_level(uuid) from public, anon;
grant  execute on function public.preview_required_verification_level(uuid) to authenticated;

commit;
