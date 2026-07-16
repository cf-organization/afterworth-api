-- public.required_verification_level(p_estate uuid) -> public.verification_level
--
-- Slice C3 (migration 0027). THE monotonic verification policy engine.
--
-- LOCKED INVARIANT:  required_level = GREATEST(jurisdiction_floor, escalation_max)
-- Monotonic — risk factors ONLY escalate UPWARD, NEVER waive below the jurisdiction floor. Unknown/unapproved
-- jurisdiction -> enhanced_kyc (fail closed).
--
-- THE INVARIANT IS STRUCTURAL, not conventional:
--   * The ONLY combinator is GREATEST(). NO code path returns a level BELOW v_floor — a reviewer (or a future
--     grep) confirms monotonicity by the ABSENCE of any downward branch. Each escalation factor is a CASE that
--     maps a server-derived input to a level (monotone in the input), fed INTO the final GREATEST — never
--     subtracted, never LEAST-ed.
--   * Fail-closed on unknown: unmapped OR unapproved jurisdiction -> v_floor := enhanced_kyc IN CODE (the table
--     ships empty by design), so "unknown = maximum" survives deleting a config row.
--   * Unbypassable: takes ONLY p_estate. NO client-supplied level parameter; ALL inputs (jurisdiction, value)
--     are server-derived from the estate id.
--
-- DEFINER-INTERNAL: EXECUTE revoked from every client role so claims RPCs (C4/C5) call it as owner and the
-- invariant reads clean. The client-facing door is preview_required_verification_level (gated to a party).
-- Proven live 2026-07-16 (10/10): fail-closed unmapped/unapproved -> enhanced_kyc; monotonicity result>=floor
-- across every floor; upward-only escalation; no-bypass (args=p_estate only, sealed). Source of truth.

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
  --  stubbed at a low level. Adding one CANNOT lower the result.)

  -- (3) MONOTONIC COMBINE — the ONLY combinator. No path returns below v_floor.
  return greatest(v_floor, v_value_level);
end;
$function$;
revoke execute on function public.required_verification_level(uuid) from public, anon, authenticated;
