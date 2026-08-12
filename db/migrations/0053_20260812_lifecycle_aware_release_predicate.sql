-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 0053 · PHASE 11-D — the release predicate becomes lifecycle-aware (one signature, one authority)
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- ★ WHAT THIS PHASE CONNECTS, AND THE ONLY THING IT CONNECTS:
--
--       authoritative estate lifecycle state  (estate_lifecycle, read via estate_lifecycle_state)
--               ↓
--       public.release_condition_satisfied(condition, approved_at, policy, lifecycle_state)
--               ↓
--       existing owner-authored death-conditioned grants may become live
--
-- `after_verified_death` becomes satisfiable — under the `standard` policy only, and only while the
-- estate's authoritative lifecycle is `death_verified`. Nothing else moves:
--
--   · NO grant is created, widened, re-tiered or re-approved. Activation is EVALUATIVE — the same
--     stored row, the same ceiling, the same membership requirements, one predicate answering
--     differently because the lifecycle fact it now consumes has changed.
--   · `legacy_immediate_only` is PRESERVED EXACTLY: the asset-value surfaces still honour
--     `immediately` alone. A death-conditioned asset grant stays dormant on those surfaces.
--     Policy unification remains a deferred product decision (R12), not a side effect.
--   · `after_verified_incapacity` stays dormant (no incapacity workflow exists — R6).
--   · `after_verified_death_or_incapacity` (legacy fused rows) stays dormant and unreinterpreted (R7).
--   · claim approval, evidence receipt, evidence review and attained verification levels satisfy
--     nothing — only the lifecycle record does, and only its one audited writer can move it.
--   · No `released` estate state exists; the 0052 CHECK still cannot store one.
--
-- ★ THE DDL HERE IS ONE DROP. The widened predicate itself lives in
-- `db/functions/release_conditions.sql` (the canonical module) and arrives with the bundle; what a
-- migration must own is the removal of the LIFECYCLE-BLIND overload. `create or replace` cannot
-- replace across a signature change — it would leave both, and Postgres overload resolution would
-- quietly keep serving the 3-argument version to any consumer that was not rewired. A consumer that
-- bypasses the widening must fail LOUDLY at first call, not keep getting yesterday's answer.
--
-- DEPLOYMENT STATE NOTE: the 11-B/11-C bundles are source-merged but not yet pasted, so no deployed
-- database carries the 3-argument predicate; there this drop is a documented no-op. The database it
-- is load-bearing for is any that applied the 11-B artifacts (the SQL harness, a dev paste).
--
-- IDEMPOTENT. Safe to re-apply: `drop function if exists`, and the self-check raises rather than
-- silently no-ops.
--
-- APPLY ORDER: inside `release_conditions_bundle.sql`, after 0051/0052 and immediately before the
-- canonical module that creates the 4-argument predicate. Standing rule unchanged: that bundle is
-- pasted FIRST, before any other bundle re-application.

\set ON_ERROR_STOP on

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- 1 · REMOVE the lifecycle-blind overload, so exactly one authority can exist.
-- ────────────────────────────────────────────────────────────────────────────────────────────────
drop function if exists public.release_condition_satisfied(text, timestamptz, text);

-- ★ PROVE THE REMOVAL TOOK. A drop that silently missed (a renamed schema, an altered signature)
-- would leave two authorities answering the same question, and the un-rewired consumer would keep
-- binding to the blind one — green everywhere, wrong at the first verified death.
do $$
begin
  if to_regprocedure('public.release_condition_satisfied(text, timestamptz, text)') is not null then
    raise exception '0053 FAILED: the 3-argument (lifecycle-blind) release_condition_satisfied still '
      'exists after the drop — two release authorities would coexist and overload resolution would '
      'quietly serve the blind one to any consumer that was not rewired';
  end if;
  raise notice '0053 · lifecycle-blind release predicate removed (the 4-argument authority in '
    'release_conditions.sql is now the only satisfiable spelling)';
end $$;
