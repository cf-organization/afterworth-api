-- ════════════════════════════════════════════════════════════════════════════════════════════
-- MODEL C CANONICAL BOOTSTRAP · 70 · triggers
--
-- GENERATED — do not edit by hand. Regenerate with:
--   node scripts/generateBootstrap.mjs --snapshot <verified snapshot> --evidence <dir>
--
-- DERIVED FROM live authoritative state, NOT from migrations 0001-0060 and NOT from test preambles.
-- This file represents CURRENT authoritative schema through migration 0060.
-- It is NOT a pre-0001 baseline; no pre-0001 schema is recoverable from repository evidence.
--
-- statements: 9
-- ════════════════════════════════════════════════════════════════════════════════════════════

SET client_min_messages = warning;
SET row_security = off;
SET search_path = public, storage, extensions, pg_catalog;

CREATE OR REPLACE TRIGGER "access_grants_ceiling" BEFORE INSERT OR UPDATE ON "public"."access_grants" FOR EACH ROW EXECUTE FUNCTION "public"."enforce_grant_ceiling"();

CREATE OR REPLACE TRIGGER "document_sensitivity_taxonomy_bump" AFTER INSERT OR DELETE OR UPDATE ON "public"."document_sensitivity" FOR EACH STATEMENT EXECUTE FUNCTION "public"."bump_taxonomy_vocabulary_version"();

CREATE OR REPLACE TRIGGER "document_subtype_taxonomy_bump" AFTER INSERT OR DELETE OR UPDATE ON "public"."document_subtype" FOR EACH STATEMENT EXECUTE FUNCTION "public"."bump_taxonomy_vocabulary_version"();

CREATE OR REPLACE TRIGGER "document_type_taxonomy_bump" AFTER INSERT OR DELETE OR UPDATE ON "public"."document_type" FOR EACH STATEMENT EXECUTE FUNCTION "public"."bump_taxonomy_vocabulary_version"();

CREATE OR REPLACE TRIGGER "estate_asset_category_taxonomy_bump" AFTER INSERT OR DELETE OR UPDATE ON "public"."estate_asset_category" FOR EACH STATEMENT EXECUTE FUNCTION "public"."bump_taxonomy_vocabulary_version"();

CREATE OR REPLACE TRIGGER "estate_asset_subtype_taxonomy_bump" AFTER INSERT OR DELETE OR UPDATE ON "public"."estate_asset_subtype" FOR EACH STATEMENT EXECUTE FUNCTION "public"."bump_taxonomy_vocabulary_version"();

CREATE OR REPLACE TRIGGER "estate_memberships_check_primary_user" BEFORE INSERT OR UPDATE ON "public"."estate_memberships" FOR EACH ROW EXECUTE FUNCTION "public"."check_primary_user_matches_owner"();

CREATE OR REPLACE TRIGGER "estates_ensure_primary_user_membership" AFTER INSERT ON "public"."estates" FOR EACH ROW EXECUTE FUNCTION "public"."ensure_primary_user_membership"();

CREATE OR REPLACE TRIGGER "owner_notice_outbox_require_episode" BEFORE INSERT ON "public"."owner_notice_outbox" FOR EACH ROW EXECUTE FUNCTION "public"."owner_notice_require_episode"();
