-- ════════════════════════════════════════════════════════════════════════════════════════════
-- MODEL C CANONICAL BOOTSTRAP · 80 · RLS enablement
--
-- GENERATED — do not edit by hand. Regenerate with:
--   node scripts/generateBootstrap.mjs --snapshot <verified snapshot> --evidence <dir>
--
-- DERIVED FROM live authoritative state, NOT from migrations 0001-0060 and NOT from test preambles.
-- This file represents CURRENT authoritative schema through migration 0060.
-- It is NOT a pre-0001 baseline; no pre-0001 schema is recoverable from repository evidence.
--
-- statements: 41
-- ════════════════════════════════════════════════════════════════════════════════════════════

SET client_min_messages = warning;
SET row_security = off;

ALTER TABLE "public"."access_grants" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."access_requests" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."admins" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."assets" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."audit_logs" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."beneficiaries" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."claim_packets" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."connection_secrets" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."connections" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."consent_records" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."death_verification_cases" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."death_verification_evidence" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."document_sensitivity" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."document_subtype" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."document_type" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."documents" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."encrypted_instructions" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."estate_asset_category" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."estate_asset_documents" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."estate_asset_subtype" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."estate_assets" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."estate_designations" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."estate_lifecycle" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."estate_memberships" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."estates" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."invitation_delivery_outbox" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."invitations" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."jurisdiction_policy" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."legal_holds" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."mfa_recovery_attempts" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."normalized_assets" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."notifications" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."outbox_purge_audit" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."owner_notice_outbox" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."recovery_codes" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."release_authorizations" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."release_safety_policy" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."storage_deletion_outbox" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."taxonomy_version" ENABLE ROW LEVEL SECURITY;

ALTER TABLE "public"."upload_policy" ENABLE ROW LEVEL SECURITY;
