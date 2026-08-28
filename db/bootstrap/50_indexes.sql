-- ════════════════════════════════════════════════════════════════════════════════════════════
-- MODEL C CANONICAL BOOTSTRAP · 50 · indexes
--
-- GENERATED — do not edit by hand. Regenerate with:
--   node scripts/generateBootstrap.mjs --snapshot <verified snapshot> --evidence <dir>
--
-- DERIVED FROM live authoritative state, NOT from migrations 0001-0060 and NOT from test preambles.
-- This file represents CURRENT authoritative schema through migration 0060.
-- It is NOT a pre-0001 baseline; no pre-0001 schema is recoverable from repository evidence.
--
-- statements: 59
-- ════════════════════════════════════════════════════════════════════════════════════════════

SET client_min_messages = warning;
SET row_security = off;

CREATE INDEX "access_grants_lookup" ON "public"."access_grants" USING "btree" ("estate_id", "grantee_user_id", "status");

CREATE UNIQUE INDEX "access_grants_uniq_cat" ON "public"."access_grants" USING "btree" ("estate_id", "grantee_user_id", "category") WHERE (("category" IS NOT NULL) AND ("status" = 'active'::"text"));

CREATE UNIQUE INDEX "access_grants_uniq_doc" ON "public"."access_grants" USING "btree" ("estate_id", "grantee_user_id", "document_id") WHERE (("document_id" IS NOT NULL) AND ("status" = 'active'::"text"));

CREATE INDEX "access_requests_estate_status" ON "public"."access_requests" USING "btree" ("estate_id", "status");

CREATE UNIQUE INDEX "access_requests_one_pending" ON "public"."access_requests" USING "btree" ("estate_id", "requester_user_id", "category") WHERE ("status" = 'pending'::"text");

CREATE INDEX "assets_estate_id_idx" ON "public"."assets" USING "btree" ("estate_id");

CREATE INDEX "assets_owner_id_idx" ON "public"."assets" USING "btree" ("owner_id");

CREATE INDEX "audit_logs_actor_id_created_at_idx" ON "public"."audit_logs" USING "btree" ("actor_id", "created_at" DESC);

CREATE INDEX "audit_logs_created_at_id_idx" ON "public"."audit_logs" USING "btree" ("created_at" DESC, "id" DESC);

CREATE INDEX "audit_logs_estate_id_created_at_idx" ON "public"."audit_logs" USING "btree" ("estate_id", "created_at" DESC);

CREATE INDEX "audit_logs_source_created_at_idx" ON "public"."audit_logs" USING "btree" ("source", "created_at" DESC);

CREATE INDEX "beneficiaries_estate_id_idx" ON "public"."beneficiaries" USING "btree" ("estate_id");

CREATE INDEX "claim_packets_estate_id_idx" ON "public"."claim_packets" USING "btree" ("estate_id");

CREATE UNIQUE INDEX "claim_packets_one_active_per_estate" ON "public"."claim_packets" USING "btree" ("estate_id") WHERE ("status" <> 'rejected'::"text");

CREATE INDEX "connections_estate_idx" ON "public"."connections" USING "btree" ("estate_id");

CREATE INDEX "consent_records_user_type_version_idx" ON "public"."consent_records" USING "btree" ("user_id", "consent_type", "document_version");

CREATE INDEX "death_verification_cases_estate_idx" ON "public"."death_verification_cases" USING "btree" ("estate_id");

CREATE UNIQUE INDEX "death_verification_cases_one_open_per_estate" ON "public"."death_verification_cases" USING "btree" ("estate_id") WHERE ("status" = 'open'::"text");

CREATE INDEX "death_verification_evidence_case_idx" ON "public"."death_verification_evidence" USING "btree" ("case_id");

CREATE INDEX "death_verification_evidence_document_idx" ON "public"."death_verification_evidence" USING "btree" ("document_id");

CREATE INDEX "documents_estate_id_idx" ON "public"."documents" USING "btree" ("estate_id");

CREATE INDEX "encrypted_instructions_estate_id_idx" ON "public"."encrypted_instructions" USING "btree" ("estate_id");

CREATE INDEX "estate_asset_documents_doc_idx" ON "public"."estate_asset_documents" USING "btree" ("doc_id");

CREATE INDEX "estate_asset_subtype_parent_idx" ON "public"."estate_asset_subtype" USING "btree" ("parent_category");

CREATE INDEX "estate_assets_estate_idx" ON "public"."estate_assets" USING "btree" ("estate_id");

CREATE INDEX "estate_assets_live_idx" ON "public"."estate_assets" USING "btree" ("estate_id", "created_at" DESC) WHERE ("archived_at" IS NULL);

CREATE INDEX "estate_designations_estate_type_idx" ON "public"."estate_designations" USING "btree" ("estate_id", "designation_type");

CREATE UNIQUE INDEX "estate_designations_one_active" ON "public"."estate_designations" USING "btree" ("estate_id", "user_id", "designation_type") WHERE ("status" = 'active'::"text");

CREATE INDEX "estate_designations_user_idx" ON "public"."estate_designations" USING "btree" ("user_id");

CREATE INDEX "estate_members_estate_id_idx" ON "public"."estate_memberships" USING "btree" ("estate_id");

CREATE INDEX "estate_members_user_id_idx" ON "public"."estate_memberships" USING "btree" ("user_id");

CREATE UNIQUE INDEX "estate_memberships_one_primary_user_per_estate" ON "public"."estate_memberships" USING "btree" ("estate_id") WHERE (("role" = 'primary_user'::"text") AND ("status" = 'approved'::"text"));

CREATE INDEX "estate_memberships_source_invitation_idx" ON "public"."estate_memberships" USING "btree" ("source_invitation_id") WHERE ("source_invitation_id" IS NOT NULL);

CREATE INDEX "estates_owner_id_idx" ON "public"."estates" USING "btree" ("owner_id");

CREATE UNIQUE INDEX "estates_primary_per_owner_idx" ON "public"."estates" USING "btree" ("owner_id") WHERE ("is_primary" = true);

CREATE INDEX "invitation_delivery_outbox_claimable_idx" ON "public"."invitation_delivery_outbox" USING "btree" ("requested_at") WHERE ("status" = ANY (ARRAY['queued'::"text", 'retryPending'::"text"]));

CREATE INDEX "invitation_delivery_outbox_invitation_idx" ON "public"."invitation_delivery_outbox" USING "btree" ("invitation_id", "requested_at" DESC);

CREATE INDEX "invitation_delivery_outbox_unissued_idx" ON "public"."invitation_delivery_outbox" USING "btree" ("requested_at") WHERE ("status" = 'pending'::"text");

CREATE INDEX "invitations_email_idx" ON "public"."invitations" USING "btree" ("lower"("invitee_email")) WHERE ("invitee_email" IS NOT NULL);

CREATE INDEX "invitations_estate_id_idx" ON "public"."invitations" USING "btree" ("estate_id");

CREATE UNIQUE INDEX "invitations_one_active_per_phone_role" ON "public"."invitations" USING "btree" ("estate_id", "invitee_phone", "proposed_role") WHERE (("status" = ANY (ARRAY['pending'::"text", 'matched'::"text"])) AND ("invitee_phone" IS NOT NULL));

CREATE UNIQUE INDEX "invitations_one_active_per_recipient_role" ON "public"."invitations" USING "btree" ("estate_id", "lower"("invitee_email"), "proposed_role") WHERE (("status" = ANY (ARRAY['pending'::"text", 'matched'::"text"])) AND ("invitee_email" IS NOT NULL));

CREATE INDEX "invitations_phone_idx" ON "public"."invitations" USING "btree" ("invitee_phone") WHERE ("invitee_phone" IS NOT NULL);

CREATE INDEX "invitations_status_idx" ON "public"."invitations" USING "btree" ("status");

CREATE INDEX "invitations_token_hash_idx" ON "public"."invitations" USING "btree" ("token_hash");

CREATE INDEX "legal_holds_active_idx" ON "public"."legal_holds" USING "btree" ("doc_id") WHERE ("released_at" IS NULL);

CREATE INDEX "normalized_assets_connection_idx" ON "public"."normalized_assets" USING "btree" ("connection_id");

CREATE INDEX "normalized_assets_estate_idx" ON "public"."normalized_assets" USING "btree" ("estate_id");

CREATE INDEX "notifications_recipient_idx" ON "public"."notifications" USING "btree" ("user_id", "created_at" DESC);

CREATE INDEX "notifications_unread_idx" ON "public"."notifications" USING "btree" ("user_id") WHERE ("read" = false);

CREATE INDEX "notifications_user_id_read_idx" ON "public"."notifications" USING "btree" ("user_id", "read");

CREATE INDEX "owner_notice_outbox_case_idx" ON "public"."owner_notice_outbox" USING "btree" ("case_id");

CREATE INDEX "owner_notice_outbox_claimable_idx" ON "public"."owner_notice_outbox" USING "btree" ("requested_at") WHERE ("status" = ANY (ARRAY['queued'::"text", 'processing'::"text"]));

CREATE INDEX "owner_notice_outbox_estate_idx" ON "public"."owner_notice_outbox" USING "btree" ("estate_id");

CREATE UNIQUE INDEX "owner_notice_outbox_one_current_per_episode_idx" ON "public"."owner_notice_outbox" USING "btree" ("case_id", "channel") WHERE ("superseded_by" IS NULL);

CREATE INDEX "owner_notice_outbox_processing_claimed_idx" ON "public"."owner_notice_outbox" USING "btree" ("requested_at") WHERE ("status" = 'processing'::"text");

CREATE INDEX "recovery_codes_user_unused_idx" ON "public"."recovery_codes" USING "btree" ("user_id") WHERE ("used_at" IS NULL);

CREATE UNIQUE INDEX "release_authorizations_one_per_estate" ON "public"."release_authorizations" USING "btree" ("estate_id");

CREATE INDEX "storage_deletion_outbox_unpurged_idx" ON "public"."storage_deletion_outbox" USING "btree" ("requested_at") WHERE ("status" <> 'purged'::"text");
