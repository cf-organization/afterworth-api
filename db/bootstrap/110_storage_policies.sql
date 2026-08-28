-- ════════════════════════════════════════════════════════════════════════════════════════════
-- MODEL C CANONICAL BOOTSTRAP · 110 · application policies on platform storage.objects
--
-- GENERATED — do not edit by hand. Regenerate with:
--   node scripts/generateBootstrap.mjs --snapshot <verified snapshot> --evidence <dir>
--
-- DERIVED FROM live authoritative state, NOT from migrations 0001-0060 and NOT from test preambles.
-- This file represents CURRENT authoritative schema through migration 0060.
-- It is NOT a pre-0001 baseline; no pre-0001 schema is recoverable from repository evidence.
--
-- statements: 2
-- ════════════════════════════════════════════════════════════════════════════════════════════

SET client_min_messages = warning;
SET row_security = off;
SET search_path = public, storage, extensions, pg_catalog;

-- ★ APPLICATION-OWNED POLICIES ON A PLATFORM-OWNED TABLE.
--   storage.objects belongs to Supabase; these two policies belong to AfterWorth. The table is
--   NOT created here. Predicates are emitted verbatim from storage-policies-20260828.csv
--   (sha256 7b0adbe2…f13e) and were never retyped.

CREATE POLICY "documents_estate_insert" ON "storage"."objects"
  FOR INSERT
  TO "authenticated"
  WITH CHECK (((bucket_id = 'documents'::text) AND ((storage.foldername(name))[1] = 'estates'::text) AND ((storage.foldername(name))[2] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'::text) AND (is_estate_owner(((storage.foldername(name))[2])::uuid) OR (is_estate_executor(((storage.foldername(name))[2])::uuid, auth.uid()) AND ((storage.foldername(name))[3] = 'claim-evidence'::text)))));

CREATE POLICY "documents_estate_read" ON "storage"."objects"
  FOR SELECT
  TO "authenticated"
  USING (((bucket_id = 'documents'::text) AND ((storage.foldername(name))[1] = 'estates'::text) AND ((storage.foldername(name))[2] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'::text) AND (is_estate_owner(((storage.foldername(name))[2])::uuid) OR (is_estate_executor(((storage.foldername(name))[2])::uuid, auth.uid()) AND ((storage.foldername(name))[3] = 'claim-evidence'::text)))));
