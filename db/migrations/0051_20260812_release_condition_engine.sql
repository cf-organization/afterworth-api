-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- 0051 · PHASE 11-B — the canonical release-condition engine, and the death/incapacity split
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- ★ THIS MIGRATION CHANGES NO DISCLOSURE. Every read path answers exactly what it answered before,
-- for every stored row, and the SQL suite compares the full input space to prove it rather than
-- asserting it. What changes is WHERE the answer is decided.
--
-- Two things happen here:
--
--   1 · The release rule — written out seven times across five routines, giving two different
--       answers — moves into `public.release_condition_satisfied`, and every evaluator becomes a
--       caller. Phase 11 activates a death condition; doing that with seven copies is how the four
--       role maps drifted apart in Phase 9.
--
--   2 · `after_verified_death_or_incapacity` is split into `after_verified_death` and
--       `after_verified_incapacity`. The CHECK is WIDENED to admit both while keeping the fused
--       value legal, so no stored row is rewritten, reinterpreted or invalidated. The RPC write gate
--       (`release_condition_writable`) refuses the fused value for new rows.
--
-- ★ WHY THE OLD VALUE STAYS LEGAL. Deciding that a fused row "really meant death" is a product
-- decision about somebody else's estate, and it points at a disclosure that cannot be undone.
-- Deciding it meant incapacity is the same guess reversed. An unsatisfiable legacy state costs an
-- owner one re-authoring; a wrong guess costs a survivor's privacy. No row becomes more permissive:
-- the fused value was dormant before this migration and is dormant after it.
--
-- ★ NOTHING HERE VERIFIES A DEATH OR RELEASES ANYTHING. `after_verified_death` is storable and
-- satisfied by nothing. There is still no routine that writes a released state, and no read path
-- consults the release seam. This migration makes the eventual wiring a one-file change; it does not
-- perform it.
--
-- IDEMPOTENT. Safe to re-apply: the constraint is dropped-if-exists before being added, and every
-- function is `create or replace`.
--
-- APPLY ORDER: this migration must precede any re-application of
-- `estate_inventory_and_discovery_bundle.sql` or `lifecycle_notifications_bundle.sql`, whose
-- functions now call `public.release_condition_satisfied`. The
-- `release_conditions_bundle.sql` artifact bundles this file with those functions in the right
-- order for a single paste.

\set ON_ERROR_STOP on

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- 1 · WIDEN the release-condition vocabulary. Additive only.
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ THE CONSTRAINT NAME IS RESOLVED, NOT GUESSED. `access_grants.release_condition` was declared
-- inline in migration 0002 (`release_condition text not null check (...)`), so Postgres generated
-- the name — `access_grants_release_condition_check` by convention, but a database that has been
-- through a table rewrite or a manual repair may carry something else. Dropping a guessed name with
-- `if exists` would silently no-op and leave the OLD constraint in force, and the migration would
-- report success having widened nothing: the new conditions would then be refused by storage while
-- the RPC gate accepted them. So the name is looked up from the catalog by the column it governs.
do $$
declare
  v_name text;
begin
  for v_name in
    select con.conname
      from pg_constraint con
      join pg_class rel on rel.oid = con.conrelid
      join pg_namespace nsp on nsp.oid = rel.relnamespace
     where nsp.nspname = 'public'
       and rel.relname = 'access_grants'
       and con.contype = 'c'
       and pg_get_constraintdef(con.oid) ilike '%release_condition%'
  loop
    execute format('alter table public.access_grants drop constraint %I', v_name);
    raise notice 'dropped prior release_condition constraint: %', v_name;
  end loop;

  alter table public.access_grants
    add constraint access_grants_release_condition_check
    check (release_condition in (
      'never',
      'immediately',
      'after_owner_approval',
      'after_identity_verification',
      'after_access_request_approval',
      -- Phase 11-B: the split. Storable, and satisfied by nothing.
      'after_verified_death',
      'after_verified_incapacity',
      -- DEPRECATED, DELIBERATELY STILL LEGAL. Stored rows must remain readable, and
      -- `release_condition_writable` refuses it for every new write.
      'after_verified_death_or_incapacity',
      'after_claim_case_approval'
    ));
end $$;

-- ★ PROVE THE WIDENING TOOK, IN THE MIGRATION ITSELF. A constraint that failed to move would leave
-- `create_asset_grant` accepting a condition storage refuses — an error surfacing at insert time,
-- from a gate that had already said yes. Both directions are checked: the new values admitted, the
-- fused value still admitted, and an invented value still refused (or the CHECK has been dropped
-- rather than replaced, which reads identically from the accepting side).
do $$
declare
  v_def text;
begin
  select pg_get_constraintdef(con.oid) into v_def
    from pg_constraint con
    join pg_class rel on rel.oid = con.conrelid
    join pg_namespace nsp on nsp.oid = rel.relnamespace
   where nsp.nspname = 'public' and rel.relname = 'access_grants'
     and con.conname = 'access_grants_release_condition_check';

  if v_def is null then
    raise exception '0051 FAILED: the release_condition CHECK is absent after the widening';
  end if;
  if position('after_verified_death''' in v_def) = 0 then
    raise exception '0051 FAILED: after_verified_death is not in the widened CHECK: %', v_def;
  end if;
  if position('after_verified_incapacity' in v_def) = 0 then
    raise exception '0051 FAILED: after_verified_incapacity is not in the widened CHECK: %', v_def;
  end if;
  if position('after_verified_death_or_incapacity' in v_def) = 0 then
    raise exception '0051 FAILED: the legacy fused value was dropped — stored rows would be orphaned';
  end if;
  raise notice '0051 · release_condition vocabulary widened (death/incapacity split, legacy retained)';
end $$;
