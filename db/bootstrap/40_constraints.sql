-- ════════════════════════════════════════════════════════════════════════════════════════════
-- MODEL C CANONICAL BOOTSTRAP · 40 · constraints, sequence ownership, defaults
--
-- GENERATED — do not edit by hand. Regenerate with:
--   node scripts/generateBootstrap.mjs --snapshot <verified snapshot> --evidence <dir>
--
-- DERIVED FROM live authoritative state, NOT from migrations 0001-0060 and NOT from test preambles.
-- This file represents CURRENT authoritative schema through migration 0060.
-- It is NOT a pre-0001 baseline; no pre-0001 schema is recoverable from repository evidence.
--
-- statements: 128
-- ════════════════════════════════════════════════════════════════════════════════════════════

SET client_min_messages = warning;
SET row_security = off;

ALTER SEQUENCE "public"."audit_logs_id_seq" OWNED BY "public"."audit_logs"."id";

ALTER TABLE ONLY "public"."audit_logs" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."audit_logs_id_seq"'::"regclass");

ALTER TABLE ONLY "public"."access_grants"
    ADD CONSTRAINT "access_grants_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."access_requests"
    ADD CONSTRAINT "access_requests_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."admins"
    ADD CONSTRAINT "admins_pkey" PRIMARY KEY ("user_id");

ALTER TABLE ONLY "public"."assets"
    ADD CONSTRAINT "assets_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."audit_logs"
    ADD CONSTRAINT "audit_logs_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."beneficiaries"
    ADD CONSTRAINT "beneficiaries_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."claim_packets"
    ADD CONSTRAINT "claim_packets_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."connection_secrets"
    ADD CONSTRAINT "connection_secrets_pkey" PRIMARY KEY ("connection_id");

ALTER TABLE ONLY "public"."connections"
    ADD CONSTRAINT "connections_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."consent_records"
    ADD CONSTRAINT "consent_records_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."death_verification_cases"
    ADD CONSTRAINT "death_verification_cases_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."death_verification_evidence"
    ADD CONSTRAINT "death_verification_evidence_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."document_sensitivity"
    ADD CONSTRAINT "document_sensitivity_pkey" PRIMARY KEY ("value");

ALTER TABLE ONLY "public"."document_subtype"
    ADD CONSTRAINT "document_subtype_pkey" PRIMARY KEY ("subtype");

ALTER TABLE ONLY "public"."document_type"
    ADD CONSTRAINT "document_type_pkey" PRIMARY KEY ("value");

ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."encrypted_instructions"
    ADD CONSTRAINT "encrypted_instructions_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."estate_asset_category"
    ADD CONSTRAINT "estate_asset_category_pkey" PRIMARY KEY ("value");

ALTER TABLE ONLY "public"."estate_asset_documents"
    ADD CONSTRAINT "estate_asset_documents_pkey" PRIMARY KEY ("asset_id", "doc_id");

ALTER TABLE ONLY "public"."estate_asset_subtype"
    ADD CONSTRAINT "estate_asset_subtype_pkey" PRIMARY KEY ("subtype");

ALTER TABLE ONLY "public"."estate_assets"
    ADD CONSTRAINT "estate_assets_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."estate_designations"
    ADD CONSTRAINT "estate_designations_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."estate_lifecycle"
    ADD CONSTRAINT "estate_lifecycle_pkey" PRIMARY KEY ("estate_id");

ALTER TABLE ONLY "public"."estate_memberships"
    ADD CONSTRAINT "estate_members_estate_id_user_id_key" UNIQUE ("estate_id", "user_id");

ALTER TABLE ONLY "public"."estate_memberships"
    ADD CONSTRAINT "estate_members_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."estates"
    ADD CONSTRAINT "estates_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."invitation_delivery_outbox"
    ADD CONSTRAINT "invitation_delivery_outbox_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."invitations"
    ADD CONSTRAINT "invitations_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."jurisdiction_policy"
    ADD CONSTRAINT "jurisdiction_policy_pkey" PRIMARY KEY ("jurisdiction");

ALTER TABLE ONLY "public"."legal_holds"
    ADD CONSTRAINT "legal_holds_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."mfa_recovery_attempts"
    ADD CONSTRAINT "mfa_recovery_attempts_pkey" PRIMARY KEY ("user_id");

ALTER TABLE ONLY "public"."normalized_assets"
    ADD CONSTRAINT "normalized_assets_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."outbox_purge_audit"
    ADD CONSTRAINT "outbox_purge_audit_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."owner_notice_outbox"
    ADD CONSTRAINT "owner_notice_outbox_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_email_key" UNIQUE ("email");

ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."recovery_codes"
    ADD CONSTRAINT "recovery_codes_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."release_authorizations"
    ADD CONSTRAINT "release_authorizations_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."release_safety_policy"
    ADD CONSTRAINT "release_safety_policy_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."storage_deletion_outbox"
    ADD CONSTRAINT "storage_deletion_outbox_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."taxonomy_version"
    ADD CONSTRAINT "taxonomy_version_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."upload_policy"
    ADD CONSTRAINT "upload_policy_pkey" PRIMARY KEY ("id");

ALTER TABLE ONLY "public"."access_grants"
    ADD CONSTRAINT "access_grants_document_id_fkey" FOREIGN KEY ("document_id") REFERENCES "public"."documents"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."admins"
    ADD CONSTRAINT "admins_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id");

ALTER TABLE ONLY "public"."assets"
    ADD CONSTRAINT "assets_estate_id_fkey" FOREIGN KEY ("estate_id") REFERENCES "public"."estates"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."assets"
    ADD CONSTRAINT "assets_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."audit_logs"
    ADD CONSTRAINT "audit_logs_actor_id_fkey" FOREIGN KEY ("actor_id") REFERENCES "auth"."users"("id");

ALTER TABLE ONLY "public"."beneficiaries"
    ADD CONSTRAINT "beneficiaries_estate_id_fkey" FOREIGN KEY ("estate_id") REFERENCES "public"."estates"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."beneficiaries"
    ADD CONSTRAINT "beneficiaries_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."claim_packets"
    ADD CONSTRAINT "claim_packets_death_certificate_doc_id_fkey" FOREIGN KEY ("death_certificate_doc_id") REFERENCES "public"."documents"("id") ON DELETE SET NULL;

ALTER TABLE ONLY "public"."claim_packets"
    ADD CONSTRAINT "claim_packets_estate_id_fkey" FOREIGN KEY ("estate_id") REFERENCES "public"."estates"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."claim_packets"
    ADD CONSTRAINT "claim_packets_executor_id_doc_id_fkey" FOREIGN KEY ("executor_id_doc_id") REFERENCES "public"."documents"("id") ON DELETE SET NULL;

ALTER TABLE ONLY "public"."claim_packets"
    ADD CONSTRAINT "claim_packets_requested_by_fkey" FOREIGN KEY ("requested_by") REFERENCES "auth"."users"("id");

ALTER TABLE ONLY "public"."claim_packets"
    ADD CONSTRAINT "claim_packets_reviewer_id_fkey" FOREIGN KEY ("reviewer_id") REFERENCES "auth"."users"("id");

ALTER TABLE ONLY "public"."connection_secrets"
    ADD CONSTRAINT "connection_secrets_connection_id_fkey" FOREIGN KEY ("connection_id") REFERENCES "public"."connections"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."connections"
    ADD CONSTRAINT "connections_estate_id_fkey" FOREIGN KEY ("estate_id") REFERENCES "public"."estates"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."consent_records"
    ADD CONSTRAINT "consent_records_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."death_verification_cases"
    ADD CONSTRAINT "death_verification_cases_decided_by_fkey" FOREIGN KEY ("decided_by") REFERENCES "auth"."users"("id");

ALTER TABLE ONLY "public"."death_verification_cases"
    ADD CONSTRAINT "death_verification_cases_estate_id_fkey" FOREIGN KEY ("estate_id") REFERENCES "public"."estates"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."death_verification_cases"
    ADD CONSTRAINT "death_verification_cases_initiated_by_fkey" FOREIGN KEY ("initiated_by") REFERENCES "auth"."users"("id");

ALTER TABLE ONLY "public"."death_verification_cases"
    ADD CONSTRAINT "death_verification_cases_initiator_designation_id_fkey" FOREIGN KEY ("initiator_designation_id") REFERENCES "public"."estate_designations"("id");

ALTER TABLE ONLY "public"."death_verification_evidence"
    ADD CONSTRAINT "death_verification_evidence_case_id_fkey" FOREIGN KEY ("case_id") REFERENCES "public"."death_verification_cases"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."death_verification_evidence"
    ADD CONSTRAINT "death_verification_evidence_document_id_fkey" FOREIGN KEY ("document_id") REFERENCES "public"."documents"("id");

ALTER TABLE ONLY "public"."death_verification_evidence"
    ADD CONSTRAINT "death_verification_evidence_estate_id_fkey" FOREIGN KEY ("estate_id") REFERENCES "public"."estates"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."death_verification_evidence"
    ADD CONSTRAINT "death_verification_evidence_reviewed_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "auth"."users"("id");

ALTER TABLE ONLY "public"."death_verification_evidence"
    ADD CONSTRAINT "death_verification_evidence_submitted_by_fkey" FOREIGN KEY ("submitted_by") REFERENCES "auth"."users"("id");

ALTER TABLE ONLY "public"."document_subtype"
    ADD CONSTRAINT "document_subtype_parent_doc_type_fkey" FOREIGN KEY ("parent_doc_type") REFERENCES "public"."document_type"("value");

ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_doc_subtype_fkey" FOREIGN KEY ("doc_subtype") REFERENCES "public"."document_subtype"("subtype");

ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_doc_type_fkey" FOREIGN KEY ("doc_type") REFERENCES "public"."document_type"("value");

ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_estate_id_fkey" FOREIGN KEY ("estate_id") REFERENCES "public"."estates"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_sensitivity_fkey" FOREIGN KEY ("sensitivity") REFERENCES "public"."document_sensitivity"("value");

ALTER TABLE ONLY "public"."encrypted_instructions"
    ADD CONSTRAINT "encrypted_instructions_estate_id_fkey" FOREIGN KEY ("estate_id") REFERENCES "public"."estates"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."encrypted_instructions"
    ADD CONSTRAINT "encrypted_instructions_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."estate_asset_documents"
    ADD CONSTRAINT "estate_asset_documents_asset_id_fkey" FOREIGN KEY ("asset_id") REFERENCES "public"."estate_assets"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."estate_asset_documents"
    ADD CONSTRAINT "estate_asset_documents_doc_id_fkey" FOREIGN KEY ("doc_id") REFERENCES "public"."documents"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."estate_asset_documents"
    ADD CONSTRAINT "estate_asset_documents_linked_by_fkey" FOREIGN KEY ("linked_by") REFERENCES "auth"."users"("id");

ALTER TABLE ONLY "public"."estate_asset_subtype"
    ADD CONSTRAINT "estate_asset_subtype_parent_category_fkey" FOREIGN KEY ("parent_category") REFERENCES "public"."estate_asset_category"("value");

ALTER TABLE ONLY "public"."estate_assets"
    ADD CONSTRAINT "estate_assets_archived_by_fkey" FOREIGN KEY ("archived_by") REFERENCES "auth"."users"("id");

ALTER TABLE ONLY "public"."estate_assets"
    ADD CONSTRAINT "estate_assets_category_fkey" FOREIGN KEY ("category") REFERENCES "public"."estate_asset_category"("value");

ALTER TABLE ONLY "public"."estate_assets"
    ADD CONSTRAINT "estate_assets_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");

ALTER TABLE ONLY "public"."estate_assets"
    ADD CONSTRAINT "estate_assets_estate_id_fkey" FOREIGN KEY ("estate_id") REFERENCES "public"."estates"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."estate_assets"
    ADD CONSTRAINT "estate_assets_sensitivity_fkey" FOREIGN KEY ("sensitivity") REFERENCES "public"."document_sensitivity"("value");

ALTER TABLE ONLY "public"."estate_assets"
    ADD CONSTRAINT "estate_assets_subtype_fkey" FOREIGN KEY ("subtype") REFERENCES "public"."estate_asset_subtype"("subtype");

ALTER TABLE ONLY "public"."estate_designations"
    ADD CONSTRAINT "estate_designations_estate_id_fkey" FOREIGN KEY ("estate_id") REFERENCES "public"."estates"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."estate_designations"
    ADD CONSTRAINT "estate_designations_granted_by_fkey" FOREIGN KEY ("granted_by") REFERENCES "auth"."users"("id");

ALTER TABLE ONLY "public"."estate_designations"
    ADD CONSTRAINT "estate_designations_source_invitation_id_fkey" FOREIGN KEY ("source_invitation_id") REFERENCES "public"."invitations"("id");

ALTER TABLE ONLY "public"."estate_designations"
    ADD CONSTRAINT "estate_designations_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."estate_lifecycle"
    ADD CONSTRAINT "estate_lifecycle_estate_id_fkey" FOREIGN KEY ("estate_id") REFERENCES "public"."estates"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."estate_lifecycle"
    ADD CONSTRAINT "estate_lifecycle_updated_case_id_fkey" FOREIGN KEY ("updated_case_id") REFERENCES "public"."death_verification_cases"("id");

ALTER TABLE ONLY "public"."estate_memberships"
    ADD CONSTRAINT "estate_members_estate_id_fkey" FOREIGN KEY ("estate_id") REFERENCES "public"."estates"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."estate_memberships"
    ADD CONSTRAINT "estate_members_invited_by_fkey" FOREIGN KEY ("invited_by") REFERENCES "auth"."users"("id");

ALTER TABLE ONLY "public"."estate_memberships"
    ADD CONSTRAINT "estate_members_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."estate_memberships"
    ADD CONSTRAINT "estate_memberships_source_invitation_id_fkey" FOREIGN KEY ("source_invitation_id") REFERENCES "public"."invitations"("id") ON DELETE SET NULL;

ALTER TABLE ONLY "public"."estates"
    ADD CONSTRAINT "estates_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."invitation_delivery_outbox"
    ADD CONSTRAINT "invitation_delivery_outbox_estate_id_fkey" FOREIGN KEY ("estate_id") REFERENCES "public"."estates"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."invitation_delivery_outbox"
    ADD CONSTRAINT "invitation_delivery_outbox_invitation_id_fkey" FOREIGN KEY ("invitation_id") REFERENCES "public"."invitations"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."invitation_delivery_outbox"
    ADD CONSTRAINT "invitation_delivery_outbox_requested_by_fkey" FOREIGN KEY ("requested_by") REFERENCES "auth"."users"("id");

ALTER TABLE ONLY "public"."invitations"
    ADD CONSTRAINT "invitations_accepted_by_fkey" FOREIGN KEY ("accepted_by") REFERENCES "auth"."users"("id");

ALTER TABLE ONLY "public"."invitations"
    ADD CONSTRAINT "invitations_estate_id_fkey" FOREIGN KEY ("estate_id") REFERENCES "public"."estates"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."invitations"
    ADD CONSTRAINT "invitations_extended_by_fkey" FOREIGN KEY ("extended_by") REFERENCES "auth"."users"("id");

ALTER TABLE ONLY "public"."invitations"
    ADD CONSTRAINT "invitations_invited_by_fkey" FOREIGN KEY ("invited_by") REFERENCES "auth"."users"("id");

ALTER TABLE ONLY "public"."invitations"
    ADD CONSTRAINT "invitations_revoked_by_fkey" FOREIGN KEY ("revoked_by") REFERENCES "auth"."users"("id");

ALTER TABLE ONLY "public"."jurisdiction_policy"
    ADD CONSTRAINT "jurisdiction_policy_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "auth"."users"("id");

ALTER TABLE ONLY "public"."legal_holds"
    ADD CONSTRAINT "legal_holds_doc_id_fkey" FOREIGN KEY ("doc_id") REFERENCES "public"."documents"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."legal_holds"
    ADD CONSTRAINT "legal_holds_placed_by_fkey" FOREIGN KEY ("placed_by") REFERENCES "auth"."users"("id");

ALTER TABLE ONLY "public"."legal_holds"
    ADD CONSTRAINT "legal_holds_released_by_fkey" FOREIGN KEY ("released_by") REFERENCES "auth"."users"("id");

ALTER TABLE ONLY "public"."mfa_recovery_attempts"
    ADD CONSTRAINT "mfa_recovery_attempts_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."normalized_assets"
    ADD CONSTRAINT "normalized_assets_connection_id_fkey" FOREIGN KEY ("connection_id") REFERENCES "public"."connections"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."normalized_assets"
    ADD CONSTRAINT "normalized_assets_estate_id_fkey" FOREIGN KEY ("estate_id") REFERENCES "public"."estates"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_estate_id_fkey" FOREIGN KEY ("estate_id") REFERENCES "public"."estates"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."owner_notice_outbox"
    ADD CONSTRAINT "owner_notice_outbox_case_fk" FOREIGN KEY ("case_id") REFERENCES "public"."death_verification_cases"("id");

ALTER TABLE ONLY "public"."owner_notice_outbox"
    ADD CONSTRAINT "owner_notice_outbox_estate_id_fkey" FOREIGN KEY ("estate_id") REFERENCES "public"."estates"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."owner_notice_outbox"
    ADD CONSTRAINT "owner_notice_outbox_reissued_by_fk" FOREIGN KEY ("reissued_by") REFERENCES "auth"."users"("id");

ALTER TABLE ONLY "public"."owner_notice_outbox"
    ADD CONSTRAINT "owner_notice_outbox_superseded_fk" FOREIGN KEY ("superseded_by") REFERENCES "public"."owner_notice_outbox"("id") ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED;

ALTER TABLE ONLY "public"."owner_notice_outbox"
    ADD CONSTRAINT "owner_notice_outbox_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id");

ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."recovery_codes"
    ADD CONSTRAINT "recovery_codes_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."release_authorizations"
    ADD CONSTRAINT "release_authorizations_case_id_fkey" FOREIGN KEY ("case_id") REFERENCES "public"."death_verification_cases"("id");

ALTER TABLE ONLY "public"."release_authorizations"
    ADD CONSTRAINT "release_authorizations_estate_id_fkey" FOREIGN KEY ("estate_id") REFERENCES "public"."estates"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."release_authorizations"
    ADD CONSTRAINT "release_authorizations_reviewer_a_fkey" FOREIGN KEY ("reviewer_a") REFERENCES "auth"."users"("id");

ALTER TABLE ONLY "public"."release_authorizations"
    ADD CONSTRAINT "release_authorizations_reviewer_b_fkey" FOREIGN KEY ("reviewer_b") REFERENCES "auth"."users"("id");

ALTER TABLE ONLY "public"."storage_deletion_outbox"
    ADD CONSTRAINT "storage_deletion_outbox_estate_id_fkey" FOREIGN KEY ("estate_id") REFERENCES "public"."estates"("id") ON DELETE CASCADE;

ALTER TABLE ONLY "public"."storage_deletion_outbox"
    ADD CONSTRAINT "storage_deletion_outbox_requested_by_fkey" FOREIGN KEY ("requested_by") REFERENCES "auth"."users"("id");
