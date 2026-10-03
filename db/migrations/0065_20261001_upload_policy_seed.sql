-- 0065_20261001_upload_policy_seed.sql
-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- PROVISIONING FIX — a bootstrapped project is born with NO upload policy, and upload is dead.
--
-- ★ WHAT WAS OBSERVED, ON NONPROD, 2026-09-24 → 2026-09-30.
--
--   `get_upload_policy()` returned ZERO ROWS. The routine was deployed, owned, granted and callable
--   the whole time; only the ROW was missing. Consequences, on both platforms:
--
--     · the mobile Vault refused EVERY document upload — the client cannot name a limit it was never
--       told, and it fails closed rather than guessing one;
--     · `submit_claim_with_evidence` would have raised `upload_policy_missing` (P0002), so claims
--       evidence was dead too.
--
-- ★ WHY IT HAPPENED, AND WHY IT WILL RECUR WITHOUT THIS. `db/bootstrap` creates the table
--   (`30_tables.sql`), its primary key (`40_constraints.sql`), RLS (`80_rls_enable.sql`) and the grants
--   on the reader (`100_grants.sql`) — and never INSERTS the `id = 1` row. The seeding INSERT exists
--   only in historical migration `0032_20260720_upload_policy.sql`, and `manifest.json` records
--   `historical_migrations.replayed_during_virgin_bootstrap: false`. So EVERY project built from the
--   bootstrap is born with an empty singleton. Not a one-off: a standing provisioning defect.
--
-- ★ WHY THIS IS A MIGRATION AND NOT A NEW BOOTSTRAP PHASE. A reviewed draft of this fix proposed
--   `db/bootstrap/130_seeds.sql`. That was wrong, and `db/bootstrap/README.md` says why: provisioning
--   is `db/bootstrap/` (00…120) THEN `db/migrations/0061+`, and "future schema change is layered as
--   0061+; it is NOT folded back into this directory." `AUTHORITY.json` states the reason — a rolling
--   bootstrap makes its VERSION a moving target, so a virgin install and an upgraded install stop
--   being provably the same schema, which is the one property the whole model exists to guarantee.
--   A future migration reaches a fresh project by the documented path and costs the model nothing.
--
-- ★ IT CANNOT OVERWRITE A TUNED ROW. `ON CONFLICT (id) DO NOTHING` — so on an installation that
--   traversed the real history (where 0032 already seeded it, possibly since adjusted by an operator)
--   this migration is an exact no-op. Idempotent by construction, not by convention.
--
-- ★ THE VALUES MIRROR THE BUCKET, AND THE DUALITY IS STILL MANUAL. Storage enforces the `documents`
--   bucket's own `file_size_limit` and MIME allowlist INDEPENDENTLY of this table; these numbers match
--   the bucket configuration recorded in migration 0030's PREREQ note and verified on the nonprod
--   bucket on 2026-09-30 (25 MB; pdf, jpeg, png, heic). Changing a limit still requires BOTH edits.
--
-- ★ AND THE BUCKET ITSELF IS NOT SQL'S TO CREATE. `storage.buckets` is platform-owned;
--   `00_platform_contract.sql` only asserts it exists, and `110_storage_policies.sql` creates policies
--   ON `storage.objects` while stating the table is not created there. A bootstrapped project is born
--   missing the bucket AND the policy row; this migration fixes only the second. The first is a
--   provisioning checklist item — see docs/provisioning/documents-bucket.md.
--
-- ★ MUTATION SURFACE: ONE INSERT ... ON CONFLICT DO NOTHING. No DDL. No grant. No policy.
-- ════════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

-- Precondition: the table must already exist. If it does not, the bootstrap did not run and seeding a
-- row is not the problem to solve — so this HALTS rather than creating the table it does not own.
DO $do$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                  WHERE n.nspname = 'public' AND c.relname = 'upload_policy') THEN
    RAISE EXCEPTION '0065 PRECONDITION FAILED: public.upload_policy does not exist. This migration '
      'seeds the singleton; it does not create the table. Apply db/bootstrap first';
  END IF;
END
$do$;

insert into public.upload_policy
  (id, max_upload_bytes, max_files_per_claim, max_aggregate_bytes, allowed_mime_types)
values
  (1, 25 * 1024 * 1024, 2, 50 * 1024 * 1024,
   array['application/pdf','image/jpeg','image/png','image/heic'])
on conflict (id) do nothing;

-- ── POSTCONDITION, IN-TRANSACTION. Nothing commits unless the ROUTINE the client calls answers. ──
DO $do$
DECLARE
  v_rows   int;
  v_bytes  bigint;
  v_mimes  text[];
  v_files  int;
  v_agg    bigint;
BEGIN
  -- ★ THE ROUTINE, NOT THE TABLE. `get_upload_policy()` is the door the client actually knocks on, and
  --   a grant, ownership or search_path mistake would leave the table looking perfect while the client
  --   still received nothing. Asserting the row would have passed in exactly that case.
  SELECT count(*) INTO v_rows FROM public.get_upload_policy();
  IF v_rows <> 1 THEN
    RAISE EXCEPTION '0065 POSTCONDITION FAILED: get_upload_policy() returned % rows, expected exactly 1',
      v_rows;
  END IF;

  SELECT p.max_upload_bytes, p.allowed_mime_types, p.max_files_per_claim, p.max_aggregate_bytes
    INTO v_bytes, v_mimes, v_files, v_agg
    FROM public.get_upload_policy() p;

  -- ★ PRESENT IS NOT USABLE. A NULL limit or an empty MIME array satisfies a row count and still
  --   leaves every upload refused by a client that fails closed.
  IF v_bytes IS NULL OR v_bytes <= 0 THEN
    RAISE EXCEPTION '0065 POSTCONDITION FAILED: max_upload_bytes is % — not a usable limit', v_bytes;
  END IF;
  IF v_mimes IS NULL OR coalesce(array_length(v_mimes, 1), 0) = 0 THEN
    RAISE EXCEPTION '0065 POSTCONDITION FAILED: allowed_mime_types is empty — every upload refused';
  END IF;
  IF v_files IS NULL OR v_files <= 0 OR v_agg IS NULL OR v_agg <= 0 THEN
    RAISE EXCEPTION '0065 POSTCONDITION FAILED: claim quotas are unusable (files=%, aggregate=%)',
      v_files, v_agg;
  END IF;

  -- ★ THE OTHER CONSUMER READS THE SAME ROW. `submit_claim_with_evidence` and
  --   `create_vault_document` read `public.upload_policy` directly; the client is told
  --   `get_upload_policy()`. "Told == enforced" only holds if those are one row, so that is asserted
  --   rather than assumed.
  IF NOT EXISTS (
    SELECT 1 FROM public.upload_policy t
     WHERE t.id = 1
       AND t.max_upload_bytes    = v_bytes
       AND t.max_files_per_claim = v_files
       AND t.max_aggregate_bytes = v_agg
       AND t.allowed_mime_types  = v_mimes
  ) THEN
    RAISE EXCEPTION '0065 POSTCONDITION FAILED: the row the client is told differs from the row the '
      'server enforces — told/enforced have diverged';
  END IF;

  RAISE NOTICE '0065 OK — get_upload_policy() returns one usable row (% bytes, % mime types)',
    v_bytes, array_length(v_mimes, 1);
END
$do$;

COMMIT;
