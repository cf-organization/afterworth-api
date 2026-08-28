-- ════════════════════════════════════════════════════════════════════════════════════════════
-- MODEL C CANONICAL BOOTSTRAP · 30 · tables + sequences (no FKs yet)
--
-- GENERATED — do not edit by hand. Regenerate with:
--   node scripts/generateBootstrap.mjs --snapshot <verified snapshot> --evidence <dir>
--
-- DERIVED FROM live authoritative state, NOT from migrations 0001-0060 and NOT from test preambles.
-- This file represents CURRENT authoritative schema through migration 0060.
-- It is NOT a pre-0001 baseline; no pre-0001 schema is recoverable from repository evidence.
--
-- statements: 42
-- ════════════════════════════════════════════════════════════════════════════════════════════

SET client_min_messages = warning;
SET row_security = off;

CREATE TABLE IF NOT EXISTS "public"."audit_logs" (
    "id" bigint NOT NULL,
    "actor_id" "uuid",
    "estate_id" "uuid",
    "action" "text" NOT NULL,
    "target_table" "text",
    "target_id" "uuid",
    "ip" "inet",
    "user_agent" "text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "source" "text" DEFAULT 'server'::"text" NOT NULL,
    CONSTRAINT "audit_logs_source_check" CHECK (("source" = ANY (ARRAY['server'::"text", 'ios_forward'::"text", 'admin'::"text", 'worker'::"text"])))
);

CREATE TABLE IF NOT EXISTS "public"."access_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "estate_id" "uuid" NOT NULL,
    "requester_user_id" "uuid" NOT NULL,
    "category" "text" NOT NULL,
    "reason" "text",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "resolved_at" timestamp with time zone,
    "resolved_by_user_id" "uuid",
    "resulting_grant_id" "uuid",
    "requester_role" "text",
    CONSTRAINT "access_requests_category_check" CHECK (("category" = 'estate_documents'::"text")),
    CONSTRAINT "access_requests_requester_role_check" CHECK ((("requester_role" IS NULL) OR ("requester_role" = ANY (ARRAY['beneficiary'::"text", 'professional_delegate'::"text"])))),
    CONSTRAINT "access_requests_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'denied'::"text"])))
);

CREATE TABLE IF NOT EXISTS "public"."access_grants" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "estate_id" "uuid" NOT NULL,
    "grantee_user_id" "uuid" NOT NULL,
    "grantee_role" "text" NOT NULL,
    "professional_type" "text",
    "document_id" "uuid",
    "category" "text",
    "visibility_tier" "text" NOT NULL,
    "release_condition" "text" NOT NULL,
    "requires_step_up" boolean DEFAULT false NOT NULL,
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "granted_by_user_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "revoked_at" timestamp with time zone,
    "revoked_by_user_id" "uuid",
    "approved_at" timestamp with time zone,
    "approved_by_user_id" "uuid",
    CONSTRAINT "access_grants_category_check" CHECK ((("category" IS NULL) OR ("category" = ANY (ARRAY['estate_documents'::"text", 'account_balances'::"text", 'institution_names'::"text", 'total_asset_value'::"text", 'linked_account_details'::"text", 'estate_inventory'::"text"])))),
    CONSTRAINT "access_grants_grantee_role_check" CHECK (("grantee_role" = ANY (ARRAY['beneficiary'::"text", 'professional_delegate'::"text"]))),
    CONSTRAINT "access_grants_release_condition_check" CHECK (("release_condition" = ANY (ARRAY['never'::"text", 'immediately'::"text", 'after_owner_approval'::"text", 'after_identity_verification'::"text", 'after_access_request_approval'::"text", 'after_verified_death'::"text", 'after_verified_incapacity'::"text", 'after_verified_death_or_incapacity'::"text", 'after_claim_case_approval'::"text"]))),
    CONSTRAINT "access_grants_scope_xor" CHECK ((("document_id" IS NOT NULL) <> ("category" IS NOT NULL))),
    CONSTRAINT "access_grants_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'revoked'::"text"]))),
    CONSTRAINT "access_grants_visibility_tier_check" CHECK (("visibility_tier" = ANY (ARRAY['hidden'::"text", 'range_only'::"text", 'category_summary'::"text", 'limited_detail'::"text", 'full_detail'::"text"])))
);

CREATE TABLE IF NOT EXISTS "public"."connections" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "estate_id" "uuid" NOT NULL,
    "provider" "text" NOT NULL,
    "institution_id" "text",
    "institution_name" "text",
    "reference_token" "text" NOT NULL,
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

CREATE TABLE IF NOT EXISTS "public"."admins" (
    "user_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "note" "text"
);

CREATE TABLE IF NOT EXISTS "public"."assets" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "estate_id" "uuid" NOT NULL,
    "owner_id" "uuid" NOT NULL,
    "asset_type" "text" NOT NULL,
    "title" "text" NOT NULL,
    "institution" "text",
    "identifier_last4" "text",
    "estimated_value_cents" bigint,
    "currency" "text" DEFAULT 'USD'::"text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "assets_asset_type_check" CHECK (("asset_type" = ANY (ARRAY['bank_account'::"text", 'investment'::"text", 'real_estate'::"text", 'vehicle'::"text", 'digital_asset'::"text", 'crypto'::"text", 'insurance'::"text", 'retirement'::"text", 'other'::"text"])))
);

CREATE SEQUENCE IF NOT EXISTS "public"."audit_logs_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

CREATE TABLE IF NOT EXISTS "public"."beneficiaries" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "estate_id" "uuid" NOT NULL,
    "owner_id" "uuid" NOT NULL,
    "full_name" "text" NOT NULL,
    "relationship" "text",
    "email" "text",
    "phone" "text",
    "allocation_percent" numeric(5,2),
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "user_id" "uuid",
    CONSTRAINT "beneficiaries_allocation_percent_check" CHECK ((("allocation_percent" >= (0)::numeric) AND ("allocation_percent" <= (100)::numeric)))
);

CREATE TABLE IF NOT EXISTS "public"."claim_packets" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "estate_id" "uuid" NOT NULL,
    "requested_by" "uuid" NOT NULL,
    "status" "text" DEFAULT 'submitted'::"text" NOT NULL,
    "death_certificate_doc_id" "uuid",
    "executor_id_doc_id" "uuid",
    "reviewer_id" "uuid",
    "review_notes" "text",
    "submitted_at" timestamp with time zone DEFAULT "now"(),
    "decided_at" timestamp with time zone,
    CONSTRAINT "claim_packets_status_check" CHECK (("status" = ANY (ARRAY['submitted'::"text", 'under_review'::"text", 'approved'::"text", 'rejected'::"text", 'released'::"text"])))
);

CREATE TABLE IF NOT EXISTS "public"."connection_secrets" (
    "connection_id" "uuid" NOT NULL,
    "provider" "text" NOT NULL,
    "access_token" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

CREATE TABLE IF NOT EXISTS "public"."consent_records" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "consent_type" "text" NOT NULL,
    "document_version" "text" NOT NULL,
    "accepted_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "consent_records_consent_type_check" CHECK (("consent_type" = ANY (ARRAY['terms_of_service'::"text", 'privacy_policy'::"text", 'data_sharing'::"text", 'beneficiary_disclosure'::"text", 'tax_disclaimer'::"text", 'platform_disclosure'::"text"])))
);

CREATE TABLE IF NOT EXISTS "public"."death_verification_cases" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "estate_id" "uuid" NOT NULL,
    "event_type" "text" DEFAULT 'death'::"text" NOT NULL,
    "status" "text" DEFAULT 'open'::"text" NOT NULL,
    "initiated_by" "uuid" NOT NULL,
    "initiator_designation_id" "uuid" NOT NULL,
    "initiator_capacity" "text" NOT NULL,
    "jurisdiction_context" "text",
    "required_level_at_initiation" "public"."verification_level" NOT NULL,
    "attained_level" "public"."verification_level",
    "decided_by" "uuid",
    "decided_at" timestamp with time zone,
    "decision_note" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "death_verification_cases_event_type_check" CHECK (("event_type" = 'death'::"text")),
    CONSTRAINT "death_verification_cases_initiator_capacity_check" CHECK (("initiator_capacity" = ANY (ARRAY['executor'::"text", 'trustee'::"text"]))),
    CONSTRAINT "death_verification_cases_status_check" CHECK (("status" = ANY (ARRAY['open'::"text", 'verified'::"text", 'rejected'::"text", 'cancelled'::"text", 'halted'::"text"])))
);

CREATE TABLE IF NOT EXISTS "public"."death_verification_evidence" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "case_id" "uuid" NOT NULL,
    "estate_id" "uuid" NOT NULL,
    "document_id" "uuid" NOT NULL,
    "submitted_by" "uuid" NOT NULL,
    "submitted_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "review_status" "text" DEFAULT 'received'::"text" NOT NULL,
    "reviewed_by" "uuid",
    "reviewed_at" timestamp with time zone,
    "review_note" "text",
    CONSTRAINT "death_verification_evidence_review_status_check" CHECK (("review_status" = ANY (ARRAY['received'::"text", 'reviewed_accepted'::"text", 'reviewed_rejected'::"text"])))
);

CREATE TABLE IF NOT EXISTS "public"."document_sensitivity" (
    "value" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "description" "text",
    "rank" integer DEFAULT 0 NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "badge_color_key" "text",
    "icon_key" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

CREATE TABLE IF NOT EXISTS "public"."document_subtype" (
    "subtype" "text" NOT NULL,
    "parent_doc_type" "text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "display_name" "text" NOT NULL,
    "description" "text",
    "rank" integer DEFAULT 0 NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "badge_color_key" "text",
    "icon_key" "text"
);

CREATE TABLE IF NOT EXISTS "public"."document_type" (
    "value" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "description" "text",
    "rank" integer DEFAULT 0 NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "badge_color_key" "text",
    "icon_key" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

CREATE TABLE IF NOT EXISTS "public"."documents" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "estate_id" "uuid" NOT NULL,
    "owner_id" "uuid" NOT NULL,
    "doc_type" "text" NOT NULL,
    "title" "text" NOT NULL,
    "storage_path" "text" NOT NULL,
    "mime_type" "text",
    "size_bytes" bigint,
    "sha256" "text",
    "is_encrypted" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "sensitivity" "text" DEFAULT 'sealed'::"text" NOT NULL,
    "doc_subtype" "text",
    "retention_until" timestamp with time zone
);

CREATE TABLE IF NOT EXISTS "public"."encrypted_instructions" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "estate_id" "uuid" NOT NULL,
    "owner_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "ciphertext" "bytea" NOT NULL,
    "iv" "bytea" NOT NULL,
    "wrapped_key" "bytea" NOT NULL,
    "release_condition" "text" NOT NULL,
    "released" boolean DEFAULT false,
    "released_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "encrypted_instructions_release_condition_check" CHECK (("release_condition" = ANY (ARRAY['on_death'::"text", 'on_executor_claim'::"text", 'manual'::"text"])))
);

CREATE TABLE IF NOT EXISTS "public"."estate_asset_category" (
    "value" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "description" "text",
    "sort_order" integer DEFAULT 0 NOT NULL,
    "icon_key" "text",
    "is_physical" boolean DEFAULT false NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

CREATE TABLE IF NOT EXISTS "public"."estate_asset_documents" (
    "asset_id" "uuid" NOT NULL,
    "doc_id" "uuid" NOT NULL,
    "linked_by" "uuid" NOT NULL,
    "linked_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

CREATE TABLE IF NOT EXISTS "public"."estate_asset_subtype" (
    "subtype" "text" NOT NULL,
    "parent_category" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "description" "text",
    "sort_order" integer DEFAULT 0 NOT NULL,
    "icon_key" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

CREATE TABLE IF NOT EXISTS "public"."estate_assets" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "estate_id" "uuid" NOT NULL,
    "created_by" "uuid" NOT NULL,
    "category" "text" NOT NULL,
    "subtype" "text" NOT NULL,
    "label" "text" NOT NULL,
    "sensitivity" "text" DEFAULT 'sealed'::"text" NOT NULL,
    "owner_label" "text",
    "country_code" "text",
    "jurisdiction" "text",
    "institution_name" "text",
    "reference_hint" "text",
    "approximate_value_cents" bigint,
    "currency" "text" DEFAULT 'USD'::"text" NOT NULL,
    "notes" "text",
    "beneficiary_note" "text",
    "verification_status" "text" DEFAULT 'unverified'::"text" NOT NULL,
    "archived_at" timestamp with time zone,
    "archived_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "estate_assets_approximate_value_cents_check" CHECK ((("approximate_value_cents" IS NULL) OR ("approximate_value_cents" >= 0))),
    CONSTRAINT "estate_assets_archived_pair" CHECK ((("archived_at" IS NULL) = ("archived_by" IS NULL))),
    CONSTRAINT "estate_assets_country_code_check" CHECK ((("country_code" IS NULL) OR ("country_code" ~ '^[A-Z]{2}$'::"text"))),
    CONSTRAINT "estate_assets_currency_check" CHECK (("currency" ~ '^[A-Z]{3}$'::"text")),
    CONSTRAINT "estate_assets_label_len" CHECK (("length"("label") <= 200)),
    CONSTRAINT "estate_assets_label_not_blank" CHECK (("length"("btrim"("label")) > 0)),
    CONSTRAINT "estate_assets_reference_hint_check" CHECK ((("reference_hint" IS NULL) OR ("length"("reference_hint") <= 12))),
    CONSTRAINT "estate_assets_verification_status_check" CHECK (("verification_status" = ANY (ARRAY['unverified'::"text", 'ownerAsserted'::"text", 'documented'::"text", 'verified'::"text"])))
);

CREATE TABLE IF NOT EXISTS "public"."estate_designations" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "estate_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "designation_type" "text" NOT NULL,
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "source_invitation_id" "uuid",
    "granted_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "revoked_at" timestamp with time zone,
    CONSTRAINT "estate_designations_designation_type_check" CHECK (("designation_type" = ANY (ARRAY['executor'::"text", 'trustee'::"text"]))),
    CONSTRAINT "estate_designations_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'revoked'::"text"])))
);

CREATE TABLE IF NOT EXISTS "public"."estate_lifecycle" (
    "estate_id" "uuid" NOT NULL,
    "state" "text" DEFAULT 'active'::"text" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_case_id" "uuid",
    "owner_notified_at" timestamp with time zone,
    "challenge_window_started_at" timestamp with time zone,
    "halted_at" timestamp with time zone,
    "released_at" timestamp with time zone,
    "safety_notification_id" "uuid",
    CONSTRAINT "estate_lifecycle_state_check" CHECK (("state" = ANY (ARRAY['active'::"text", 'death_verification_pending'::"text", 'death_verified'::"text", 'owner_notification_dispatched'::"text", 'challenge_window'::"text", 'challenge_halted'::"text", 'released'::"text"])))
);

CREATE TABLE IF NOT EXISTS "public"."estate_memberships" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "estate_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "role" "text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "invited_by" "uuid",
    "approved_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "source_invitation_id" "uuid",
    CONSTRAINT "estate_memberships_role_check" CHECK (("role" = ANY (ARRAY['primary_user'::"text", 'beneficiary'::"text", 'professional_delegate'::"text"]))),
    CONSTRAINT "estate_memberships_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'revoked'::"text", 'expired'::"text"])))
);

CREATE TABLE IF NOT EXISTS "public"."estates" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "owner_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "jurisdiction" "text",
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "is_primary" boolean DEFAULT false NOT NULL,
    CONSTRAINT "estates_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'locked'::"text", 'archived'::"text", 'in_claim'::"text"])))
);

CREATE TABLE IF NOT EXISTS "public"."invitation_delivery_outbox" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "invitation_id" "uuid" NOT NULL,
    "estate_id" "uuid" NOT NULL,
    "reason" "text" NOT NULL,
    "requested_by" "uuid" NOT NULL,
    "requested_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "status" "text" DEFAULT 'queued'::"text" NOT NULL,
    "attempts" integer DEFAULT 0 NOT NULL,
    "last_error" "text",
    "issued_at" timestamp with time zone,
    "delivery_generation" integer DEFAULT 0 NOT NULL,
    "idempotency_key" "text",
    "provider_message_id" "text",
    "failure_class" "text",
    "next_attempt_at" timestamp with time zone,
    "claimed_at" timestamp with time zone,
    "last_outcome_at" timestamp with time zone,
    CONSTRAINT "invitation_delivery_outbox_failure_class_check" CHECK ((("failure_class" IS NULL) OR ("failure_class" = ANY (ARRAY['provider_rejected'::"text", 'provider_unavailable'::"text", 'rate_limited'::"text", 'invalid_recipient'::"text", 'configuration'::"text", 'timeout'::"text", 'unknown'::"text"])))),
    CONSTRAINT "invitation_delivery_outbox_reason_check" CHECK (("reason" = ANY (ARRAY['invitation_created'::"text", 'invitation_redelivery'::"text"]))),
    CONSTRAINT "invitation_delivery_outbox_status_check" CHECK (("status" = ANY (ARRAY['queued'::"text", 'processing'::"text", 'providerAccepted'::"text", 'outcomeUncertain'::"text", 'retryPending'::"text", 'failedPermanent'::"text", 'cancelled'::"text"])))
);

CREATE TABLE IF NOT EXISTS "public"."invitations" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "estate_id" "uuid" NOT NULL,
    "invited_by" "uuid" NOT NULL,
    "kind" "text" NOT NULL,
    "proposed_role" "text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "expires_at" timestamp with time zone NOT NULL,
    "invitee_email" "text",
    "invitee_phone" "text",
    "accepted_by" "uuid",
    "accepted_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "token_hash" "text" NOT NULL,
    "estate_display_name" "text",
    "inviter_display_name" "text",
    "invitee_email_hint" "text",
    "invitee_phone_hint" "text",
    "preview_visibility" "jsonb" DEFAULT '{}'::"jsonb",
    "declined_at" timestamp with time zone,
    "revoked_at" timestamp with time zone,
    "revoked_by" "uuid",
    "extended_at" timestamp with time zone,
    "extended_by" "uuid",
    CONSTRAINT "invitations_kind_check" CHECK (("kind" = ANY (ARRAY['beneficiary'::"text", 'professional_delegate'::"text", 'executor'::"text", 'trustee'::"text"]))),
    CONSTRAINT "invitations_proposed_role_check" CHECK (("proposed_role" = ANY (ARRAY['beneficiary'::"text", 'professional_delegate'::"text"]))),
    CONSTRAINT "invitations_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'matched'::"text", 'accepted'::"text", 'declined'::"text", 'expired'::"text", 'revoked'::"text"])))
);

CREATE TABLE IF NOT EXISTS "public"."jurisdiction_policy" (
    "jurisdiction" "text" NOT NULL,
    "floor_level" "public"."verification_level" NOT NULL,
    "is_counsel_approved" boolean DEFAULT false NOT NULL,
    "notes" "text",
    "updated_by" "uuid",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

CREATE TABLE IF NOT EXISTS "public"."legal_holds" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "doc_id" "uuid" NOT NULL,
    "reason" "text" NOT NULL,
    "placed_by" "uuid" NOT NULL,
    "placed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "released_at" timestamp with time zone,
    "released_by" "uuid"
);

CREATE TABLE IF NOT EXISTS "public"."mfa_recovery_attempts" (
    "user_id" "uuid" NOT NULL,
    "failed_count" integer DEFAULT 0 NOT NULL,
    "locked_until" timestamp with time zone,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

CREATE TABLE IF NOT EXISTS "public"."normalized_assets" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "estate_id" "uuid" NOT NULL,
    "connection_id" "uuid" NOT NULL,
    "institution_name" "text",
    "provider_name" "text",
    "asset_group" "text" NOT NULL,
    "asset_category" "text",
    "asset_subtype" "text",
    "source_type" "text" DEFAULT 'aggregator'::"text" NOT NULL,
    "masked_identifier" "text",
    "balance_cents" bigint DEFAULT 0 NOT NULL,
    "currency" "text" DEFAULT 'USD'::"text" NOT NULL,
    "holdings" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "refresh_timestamp" timestamp with time zone,
    "last_sync_status" "text" DEFAULT 'live_connected'::"text" NOT NULL,
    "confidence_level" "text" DEFAULT 'high'::"text" NOT NULL,
    "verification_status" "text" DEFAULT 'verified'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

CREATE TABLE IF NOT EXISTS "public"."notifications" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "estate_id" "uuid",
    "kind" "text" NOT NULL,
    "title" "text" NOT NULL,
    "body" "text",
    "read" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "channel" "text" DEFAULT 'inApp'::"text" NOT NULL,
    "action_deep_link" "text",
    "related_document_id" "uuid",
    "payload" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL
);

CREATE TABLE IF NOT EXISTS "public"."outbox_purge_audit" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "outbox_name" "text" NOT NULL,
    "purged_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "actor_id" "uuid",
    "row_count" integer NOT NULL,
    "oldest_row_at" timestamp with time zone,
    "newest_row_at" timestamp with time zone,
    "reason" "text" NOT NULL
);

CREATE TABLE IF NOT EXISTS "public"."owner_notice_outbox" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "estate_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "channel" "text" DEFAULT 'email'::"text" NOT NULL,
    "recipient" "text" NOT NULL,
    "notice_kind" "text" NOT NULL,
    "status" "text" DEFAULT 'queued'::"text" NOT NULL,
    "requested_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "dispatched_at" timestamp with time zone,
    "attempts" integer DEFAULT 0 NOT NULL,
    "next_attempt_at" timestamp with time zone,
    "failure_class" "text",
    "purge_audit_id" "uuid",
    "claimed_at" timestamp with time zone,
    "notice_accepted_at" timestamp with time zone,
    "case_id" "uuid",
    "generation" integer DEFAULT 1 NOT NULL,
    "superseded_by" "uuid",
    "reissue_reason" "text",
    "reissued_by" "uuid",
    CONSTRAINT "owner_notice_outbox_channel_check" CHECK (("channel" = 'email'::"text")),
    CONSTRAINT "owner_notice_outbox_notice_kind_check" CHECK (("notice_kind" = ANY (ARRAY['death_process.window_opened'::"text", 'death_process.window_renotice'::"text"]))),
    CONSTRAINT "owner_notice_outbox_reissue_pairing" CHECK (((("generation" = 1) AND ("reissue_reason" IS NULL)) OR (("generation" > 1) AND ("reissue_reason" IS NOT NULL)))),
    CONSTRAINT "owner_notice_outbox_reissue_reason_check" CHECK ((("reissue_reason" IS NULL) OR ("reissue_reason" = ANY (ARRAY['prior_failed_permanent'::"text", 'prior_stale_beyond_age_gate'::"text", 'prior_outcome_uncertain'::"text", 'legacy_no_acceptance_record'::"text"])))),
    CONSTRAINT "owner_notice_outbox_status_check" CHECK (("status" = ANY (ARRAY['queued'::"text", 'processing'::"text", 'dispatched'::"text", 'outcomeUncertain'::"text", 'failedPermanent'::"text", 'cancelled'::"text"])))
);

CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "email" "text" NOT NULL,
    "full_name" "text",
    "phone" "text",
    "date_of_birth" "date",
    "avatar_url" "text",
    "mfa_enabled" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);

CREATE TABLE IF NOT EXISTS "public"."recovery_codes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "code_hash" "text" NOT NULL,
    "used_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

CREATE TABLE IF NOT EXISTS "public"."release_authorizations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "estate_id" "uuid" NOT NULL,
    "case_id" "uuid" NOT NULL,
    "reviewer_a" "uuid" NOT NULL,
    "reviewer_b" "uuid" NOT NULL,
    "verified_at" timestamp with time zone NOT NULL,
    "authorized_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "released_at" timestamp with time zone,
    "audit_reason" "text" NOT NULL,
    CONSTRAINT "release_authorizations_two_person" CHECK (("reviewer_a" <> "reviewer_b"))
);

CREATE TABLE IF NOT EXISTS "public"."release_safety_policy" (
    "id" boolean DEFAULT true NOT NULL,
    "challenge_window" interval NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "release_safety_policy_id_check" CHECK ("id")
);

CREATE TABLE IF NOT EXISTS "public"."storage_deletion_outbox" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "estate_id" "uuid" NOT NULL,
    "bucket" "text" DEFAULT 'documents'::"text" NOT NULL,
    "object_path" "text" NOT NULL,
    "reason" "text" NOT NULL,
    "requested_by" "uuid" NOT NULL,
    "requested_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "attempts" integer DEFAULT 0 NOT NULL,
    "last_error" "text",
    "purged_at" timestamp with time zone,
    CONSTRAINT "storage_deletion_outbox_reason_check" CHECK (("reason" = ANY (ARRAY['document_deleted'::"text", 'document_replaced'::"text"]))),
    CONSTRAINT "storage_deletion_outbox_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'purged'::"text", 'failed'::"text"])))
);

CREATE TABLE IF NOT EXISTS "public"."taxonomy_version" (
    "id" integer DEFAULT 1 NOT NULL,
    "schema_version" integer DEFAULT 1 NOT NULL,
    "vocabulary_version" integer DEFAULT 1 NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "taxonomy_version_id_check" CHECK (("id" = 1))
);

CREATE TABLE IF NOT EXISTS "public"."upload_policy" (
    "id" integer DEFAULT 1 NOT NULL,
    "max_upload_bytes" bigint NOT NULL,
    "max_files_per_claim" integer NOT NULL,
    "max_aggregate_bytes" bigint NOT NULL,
    "allowed_mime_types" "text"[] NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "upload_policy_id_check" CHECK (("id" = 1))
);
