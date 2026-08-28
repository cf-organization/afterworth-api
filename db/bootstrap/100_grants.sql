-- ════════════════════════════════════════════════════════════════════════════════════════════
-- MODEL C CANONICAL BOOTSTRAP · 100 · ownership, grants, default privileges
--
-- GENERATED — do not edit by hand. Regenerate with:
--   node scripts/generateBootstrap.mjs --snapshot <verified snapshot> --evidence <dir>
--
-- DERIVED FROM live authoritative state, NOT from migrations 0001-0060 and NOT from test preambles.
-- This file represents CURRENT authoritative schema through migration 0060.
-- It is NOT a pre-0001 baseline; no pre-0001 schema is recoverable from repository evidence.
--
-- statements: 452
-- ════════════════════════════════════════════════════════════════════════════════════════════

SET client_min_messages = warning;
SET row_security = off;

COMMENT ON SCHEMA "public" IS 'standard public schema';

ALTER TYPE "public"."verification_level" OWNER TO "postgres";

ALTER FUNCTION "public"."accept_invitation"("p_invitation_id" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."admin_authorize_claim_evidence"("p_claim" "uuid", "p_slot" "text") OWNER TO "postgres";

ALTER FUNCTION "public"."admin_create_executor_invitation"("p_estate" "uuid", "p_kind" "text", "p_invitee_email" "text", "p_invitee_phone" "text", "p_reason" "text", "p_case_ref" "text", "p_expires_in_days" integer) OWNER TO "postgres";

ALTER FUNCTION "public"."admin_decide_claim_packet"("p_claim_id" "uuid", "p_decision" "text", "p_review_notes" "text") OWNER TO "postgres";

ALTER FUNCTION "public"."admin_decide_death_verification_case"("p_case" "uuid", "p_decision" "text", "p_note" "text") OWNER TO "postgres";

ALTER FUNCTION "public"."admin_get_death_verification_case"("p_case" "uuid") OWNER TO "postgres";

COMMENT ON FUNCTION "public"."admin_get_death_verification_case"("p_case" "uuid") IS 'The operator case file (Phase 11-K): case facts, initiator identity, lifecycle timestamps, LIVE window facts, owner-notice dispatch status (NEVER the recipient address) and evidence METADATA. viewer_is_reviewer_a is derived from auth.uid() INSIDE this definer so the console can state release ineligibility truthfully — it grants nothing; authorize_release re-checks independently. Phase 11-OC/D: `window` and `release_authority` both come from owner_notice_release_authority, the SAME verdict the release door consults, so the console performs no notice qualification, no episode matching and no clock arithmetic of its own. Carries no asset, valuation, beneficiary, designation, grant, document byte or storage path.';

ALTER TABLE "public"."audit_logs" OWNER TO "postgres";

ALTER FUNCTION "public"."admin_list_audit"("p_before_created" timestamp with time zone, "p_before_id" bigint, "p_limit" integer, "p_estate" "uuid", "p_actor" "uuid", "p_action" "text", "p_source" "text") OWNER TO "postgres";

ALTER FUNCTION "public"."admin_list_claim_packets"("p_estate" "uuid", "p_status" "text", "p_before_submitted" timestamp with time zone, "p_before_id" "uuid", "p_limit" integer) OWNER TO "postgres";

ALTER FUNCTION "public"."admin_list_claim_packets_enriched"("p_estate" "uuid", "p_status" "text", "p_before_submitted" timestamp with time zone, "p_before_id" "uuid", "p_limit" integer) OWNER TO "postgres";

ALTER FUNCTION "public"."admin_list_death_verification_cases"("p_status" "text", "p_before_initiated" timestamp with time zone, "p_before_id" "uuid", "p_limit" integer) OWNER TO "postgres";

COMMENT ON FUNCTION "public"."admin_list_death_verification_cases"("p_status" "text", "p_before_initiated" timestamp with time zone, "p_before_id" "uuid", "p_limit" integer) IS 'The operator queue for death-verification cases (Phase 11-K). Workflow facts only: case status, lifecycle state, LIVE required level vs attained, evidence counts, and whether the owner channel RESOLVES — never the owner address. No asset, valuation, beneficiary, designation, grant, document byte or storage path. Admin-gated inside the definer; keyset paged; clamped to 200.';

ALTER FUNCTION "public"."admin_list_invitations"("p_estate" "uuid", "p_status" "text", "p_before_created" timestamp with time zone, "p_before_id" "uuid", "p_limit" integer) OWNER TO "postgres";

ALTER FUNCTION "public"."admin_list_jurisdiction_policy"() OWNER TO "postgres";

ALTER FUNCTION "public"."admin_reconciliation_report"() OWNER TO "postgres";

ALTER FUNCTION "public"."admin_require_gate"() OWNER TO "postgres";

ALTER FUNCTION "public"."admin_review_death_evidence"("p_evidence" "uuid", "p_outcome" "text", "p_note" "text") OWNER TO "postgres";

ALTER FUNCTION "public"."admin_set_attained_verification_level"("p_case" "uuid", "p_level" "public"."verification_level", "p_basis" "text") OWNER TO "postgres";

ALTER FUNCTION "public"."apply_estate_lifecycle_transition"("p_estate" "uuid", "p_to" "text", "p_case" "uuid", "p_reason" "text") OWNER TO "postgres";

ALTER TABLE "public"."access_requests" OWNER TO "postgres";

ALTER FUNCTION "public"."approve_access_request"("p_request_id" "uuid", "p_visibility_tier" "text") OWNER TO "postgres";

ALTER TABLE "public"."access_grants" OWNER TO "postgres";

COMMENT ON TABLE "public"."access_grants" IS 'Scope-polymorphic access grants for NON-OWNERS (beneficiary, professional_delegate). Owners are inherent via membership and have no grant row. document_id XOR category. See docs/live-data-migration.md Appendix A.';

COMMENT ON COLUMN "public"."access_grants"."approved_at" IS 'When this grant was approved (null = pending/unapproved). Generic approval state: after_owner_approval passes only when set; reused by after_access_request_approval later. Set by approve_document_grant (owner-gated). See docs/live-data-migration.md A.4.';

ALTER FUNCTION "public"."approve_document_grant"("p_grant_id" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."archive_estate_asset"("p_asset_id" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."assert_grant_updatable"("p_grant_id" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."assert_not_self_invitee"("p_invitee_email" "text", "p_invitee_phone" "text") OWNER TO "postgres";

ALTER FUNCTION "public"."asset_bracket_high"("p" bigint) OWNER TO "postgres";

ALTER FUNCTION "public"."asset_bracket_low"("p" bigint) OWNER TO "postgres";

ALTER FUNCTION "public"."asset_category_grantable"("p_role" "text", "p_category" "text", "p_tier" "text") OWNER TO "postgres";

COMMENT ON FUNCTION "public"."asset_category_grantable"("p_role" "text", "p_category" "text", "p_tier" "text") IS 'Asset-disclosure ceiling: max grantable visibility_tier per (role, category). The $ categories — including estate_inventory (0049) — cap beneficiaries below exact value; professionals may reach full_detail. THE POLICY KNOB. Mirrors document_grantable for the category path.';

ALTER FUNCTION "public"."asset_grant_tier"("p_estate" "uuid", "p_uid" "uuid", "p_category" "text") OWNER TO "postgres";

ALTER FUNCTION "public"."attach_death_verification_evidence"("p_case" "uuid", "p_document" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."authorize_purge"("p_outbox_id" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."authorize_release"("p_estate" "uuid", "p_reason" "text") OWNER TO "postgres";

COMMENT ON FUNCTION "public"."authorize_release"("p_estate" "uuid", "p_reason" "text") IS 'THE release transition (Phase 11-F, re-anchored 11-OC/D): challenge_window -> released, by a SECOND platform operator. Requires admin gate, a non-empty audit reason, the dispatch provenance on the lifecycle row, a verified case, reviewer_b <> reviewer_a where reviewer_a is DERIVED from the case decider, and — from Phase D — owner_notice_release_authority: the CURRENT generation of the CURRENT case episode must carry notice_accepted_at (PROVIDER ACCEPTANCE, never mailbox delivery) and the window must be STRICTLY elapsed from THAT instant, not from owner_notified_at. No status string participates. Ties go to the owner challenge. Records a release_authorizations row whose CHECK constraint makes a single-reviewer release unwritable by any path. Creates no grant, tier, membership or designation.';

ALTER FUNCTION "public"."begin_challenge_window"("p_estate" "uuid") OWNER TO "postgres";

COMMENT ON FUNCTION "public"."begin_challenge_window"("p_estate" "uuid") IS 'Opens the owner-challenge window (Phase 11-E, rewritten 11-F, re-scoped 11-OC/D). Its ONLY legal input is owner_notification_dispatched — the death_verified -> challenge_window edge was deleted, so a window cannot open on an un-notified owner even by mistake. Phase D replaced the inert estate-scoped status <> cancelled predicate with the fact it needs: a committed email notice for the CURRENT case episode (no_current_notice otherwise). It deliberately does NOT require notice_accepted_at — opening the window discloses nothing and the initial notice is normally still queued. Admin-gated; idempotent; discloses nothing.';

ALTER FUNCTION "public"."bind_invitation_token"("p_token" "text") OWNER TO "postgres";

ALTER FUNCTION "public"."bump_taxonomy_vocabulary_version"() OWNER TO "postgres";

ALTER FUNCTION "public"."can_access_document"("p_document_id" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."cancel_death_verification_case"("p_case" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."challenge_death_process"("p_estate" "uuid") OWNER TO "postgres";

COMMENT ON FUNCTION "public"."challenge_death_process"("p_estate" "uuid") IS 'The owner challenge (Phase 11-E, R12-R14): the authenticated estate owner halts a pre-released death process in one action — no evidence, no review, no waiting, no designation. Wins ties (release requires the window strictly elapsed; both serialize on the lifecycle row lock). Produces challenge_halted, terminal in 11-E. Records no provenance beyond the act itself.';

ALTER FUNCTION "public"."challenge_window_duration"() OWNER TO "postgres";

COMMENT ON FUNCTION "public"."challenge_window_duration"() IS 'The configured owner-challenge window (Phase 11-E). NULL = not configured = the window never elapses and release refuses. Set only by an explicit, reviewed operator INSERT into release_safety_policy — never seeded by a migration. INTERNAL: clients cannot read the safety clock; the owner surface answers through get_owner_safety_status.';

ALTER FUNCTION "public"."check_primary_user_matches_owner"() OWNER TO "postgres";

ALTER FUNCTION "public"."claim_invitation_deliveries"("p_max" integer, "p_outbox_id" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."claim_owner_notices"("p_max" integer) OWNER TO "postgres";

COMMENT ON FUNCTION "public"."claim_owner_notices"("p_max" integer) IS 'Claims owner safety notices for delivery, applying the age gate FIRST (Phase 11-F, Stage 3): rows older than the gate are marked failedPermanent/stale_beyond_age_gate and are never sent and never deleted. Fresh rows are claimed with skip-locked so concurrent drains cannot double-send. Refuses entirely when the age gate is unconfigured. service_role ONLY (Phase 11-K wired the drain); no client role may claim.';

ALTER FUNCTION "public"."create_access_request"("p_estate_id" "uuid", "p_category" "text", "p_reason" "text") OWNER TO "postgres";

ALTER FUNCTION "public"."create_asset_grant"("p_estate_id" "uuid", "p_grantee_user_id" "uuid", "p_grantee_role" "text", "p_category" "text", "p_visibility_tier" "text", "p_release_condition" "text", "p_professional_type" "text", "p_requires_step_up" boolean) OWNER TO "postgres";

ALTER TABLE "public"."connections" OWNER TO "postgres";

ALTER FUNCTION "public"."create_connection"("p_estate_id" "uuid", "p_provider" "text", "p_institution_id" "text", "p_institution_name" "text", "p_reference_token" "text", "p_access_token" "text") OWNER TO "postgres";

ALTER FUNCTION "public"."create_document_grant"("p_estate_id" "uuid", "p_grantee_user_id" "uuid", "p_grantee_role" "text", "p_document_id" "uuid", "p_visibility_tier" "text", "p_release_condition" "text", "p_professional_type" "text", "p_requires_step_up" boolean) OWNER TO "postgres";

ALTER FUNCTION "public"."create_estate_asset"("p_estate" "uuid", "p_subtype" "text", "p_label" "text", "p_sensitivity" "text", "p_owner_label" "text", "p_country_code" "text", "p_jurisdiction" "text", "p_institution_name" "text", "p_reference_hint" "text", "p_approximate_value_cents" bigint, "p_currency" "text", "p_notes" "text", "p_beneficiary_note" "text") OWNER TO "postgres";

ALTER FUNCTION "public"."create_estate_invitation"("p_estate" "uuid", "p_proposed_role" "text", "p_invitee_email" "text", "p_invitee_phone" "text", "p_show_estate_name" boolean, "p_show_inviter_name" boolean, "p_expires_in_days" integer) OWNER TO "postgres";

ALTER FUNCTION "public"."create_invitation"("p_estate" "uuid", "p_kind" "text", "p_proposed_role" "text", "p_invitee_email" "text", "p_invitee_phone" "text", "p_show_estate_name" boolean, "p_show_inviter_name" boolean, "p_expires_in_days" integer) OWNER TO "postgres";

ALTER FUNCTION "public"."create_vault_document"("p_estate" "uuid", "p_doc_id" "uuid", "p_storage_path" "text", "p_title" "text", "p_doc_subtype" "text", "p_sensitivity" "text") OWNER TO "postgres";

ALTER FUNCTION "public"."decline_invitation"("p_invitation_id" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."delete_vault_document"("p_doc_id" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."deny_access_request"("p_request_id" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."dispatch_owner_safety_notice"("p_estate" "uuid") OWNER TO "postgres";

COMMENT ON FUNCTION "public"."dispatch_owner_safety_notice"("p_estate" "uuid") IS 'Phase 11-F (D4): commits an EMAIL row and an in-app notice to the owner, in the same transaction as the death_verified -> owner_notification_dispatched transition, and stamps owner_notified_at (D2: the challenge clock starts at dispatch). Requires dispatch INITIATION, never delivery confirmation. An unresolvable owner address refuses the transition. Admin-gated; idempotent.';

ALTER FUNCTION "public"."document_grantable"("p_role" "text", "p_sensitivity" "text") OWNER TO "postgres";

ALTER FUNCTION "public"."emit_lifecycle_notification"("p_user_id" "uuid", "p_estate_id" "uuid", "p_event" "text", "p_deep_link" "text") OWNER TO "postgres";

COMMENT ON FUNCTION "public"."emit_lifecycle_notification"("p_user_id" "uuid", "p_estate_id" "uuid", "p_event" "text", "p_deep_link" "text") IS 'The only way a lifecycle notification is written. Copy comes from the immutable event catalog; callers name an event and never compose text. Runs in the caller transaction, so it commits or rolls back with the state transition. INTERNAL: execute revoked from public/authenticated.';

ALTER FUNCTION "public"."emit_notification"("p_user_id" "uuid", "p_estate_id" "uuid", "p_category" "text", "p_title" "text", "p_body" "text", "p_deep_link" "text", "p_payload" "jsonb") OWNER TO "postgres";

ALTER FUNCTION "public"."enforce_grant_ceiling"() OWNER TO "postgres";

ALTER FUNCTION "public"."ensure_primary_user_membership"() OWNER TO "postgres";

ALTER FUNCTION "public"."estate_lifecycle_state"("p_estate" "uuid") OWNER TO "postgres";

COMMENT ON FUNCTION "public"."estate_lifecycle_state"("p_estate" "uuid") IS 'THE authoritative estate lifecycle read (Phase 11-C, extracted 11-D). Absent row = active. INTERNAL: execute revoked from every client role — a client that can map estate to lifecycle state holds a death-status oracle. Consumed by the death-verification routines and, since 11-D, as the lifecycle argument to public.release_condition_satisfied inside disclosure evaluators. Never derived from claim_packets.status, evidence, or attained verification levels.';

ALTER FUNCTION "public"."estate_owner_gate"("p_estate" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."estate_owner_user_id"("p_estate_id" "uuid") OWNER TO "postgres";

COMMENT ON FUNCTION "public"."estate_owner_user_id"("p_estate_id" "uuid") IS 'The estate owner user id, for server-side notification recipient resolution. INTERNAL: execute is revoked from public/authenticated, because a client that can map estate -> owner identity has been handed an identity-disclosure surface nothing in the product offers.';

ALTER FUNCTION "public"."estate_release_state"("p_estate" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."extend_estate_invitation"("p_estate" "uuid", "p_invitation" "uuid", "p_expires_in_days" integer) OWNER TO "postgres";

ALTER FUNCTION "public"."extend_invitation"("p_invitation_id" "uuid", "p_expires_in_days" integer) OWNER TO "postgres";

ALTER FUNCTION "public"."forward_client_audit"("p_action" "text", "p_estate" "uuid", "p_table" "text", "p_target" "uuid", "p_meta" "jsonb", "p_client_ts" timestamp with time zone) OWNER TO "postgres";

ALTER FUNCTION "public"."generate_recovery_codes"() OWNER TO "postgres";

ALTER FUNCTION "public"."get_connection_access_token"("p_connection_id" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."get_document_taxonomy"() OWNER TO "postgres";

ALTER FUNCTION "public"."get_estate_asset_taxonomy"() OWNER TO "postgres";

ALTER FUNCTION "public"."get_estate_discovery"("p_estate" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."get_estate_net_worth"("p_estate_id" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."get_estate_readiness"("p_estate" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."get_executor_workspace"("p_estate" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."get_my_estate_capability_facts"("p_estate" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."get_my_estate_designations"() OWNER TO "postgres";

ALTER FUNCTION "public"."get_my_fiduciary_estates"() OWNER TO "postgres";

COMMENT ON FUNCTION "public"."get_my_fiduciary_estates"() IS 'Phase 11-MB. Enumerates estates on which the CALLER holds an active executor/trustee designation, for estate-context selection ONLY. Returns estate id, display name and one deterministic capacity; no tier, grant, membership, asset, valuation, document, beneficiary or lifecycle fact. Discovery is not disclosure: appearing here makes an estate selectable and readable by nothing. Scoped to auth.uid() with no caller parameter, so no one can enumerate another person''s fiduciary relationships.';

ALTER FUNCTION "public"."get_owner_safety_status"("p_estate" "uuid") OWNER TO "postgres";

COMMENT ON FUNCTION "public"."get_owner_safety_status"("p_estate" "uuid") IS 'Owner-scoped safety status (Phase 11-E): a closed presentation union (none / challengeable / halted / released) over the authoritative lifecycle, for the challenge surface. Owner-only; every other caller refuses byte-identically. Not an authorization and not a disclosure: it answers about the process, never about estate content.';

ALTER FUNCTION "public"."get_professional_workspace"("p_estate" "uuid") OWNER TO "postgres";

COMMENT ON FUNCTION "public"."get_professional_workspace"("p_estate" "uuid") IS 'Phase 10-D. The professional delegate''s view of ONE estate: their relationship, any fiduciary capacity, what the owner released to them (delegated to get_estate_discovery and can_access_document), and the state of their own access request. Gated on an APPROVED professional_delegate membership — never on a capability combination, a grant, or a designation. The owner is refused. Carries no readiness, no score, and no count of anything withheld.';

ALTER FUNCTION "public"."get_upload_policy"() OWNER TO "postgres";

ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";

ALTER FUNCTION "public"."initiate_death_verification_case"("p_estate" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."inventory_disclosure_tier"("p_estate" "uuid", "p_uid" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."invitation_delivery_health"() OWNER TO "postgres";

ALTER FUNCTION "public"."invitation_effective_status"("p_status" "text", "p_expires_at" timestamp with time zone) OWNER TO "postgres";

ALTER FUNCTION "public"."invitation_preview"("p_token" "text") OWNER TO "postgres";

ALTER FUNCTION "public"."invitation_write_gate"("p_estate" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."is_admin"() OWNER TO "postgres";

ALTER FUNCTION "public"."is_estate_executor"("p_estate" "uuid", "p_user" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."is_estate_member"("p_estate_id" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."is_estate_owner"("p_estate_id" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."is_ownership_role"("p_role" "text") OWNER TO "postgres";

ALTER FUNCTION "public"."issue_invitation_delivery"("p_outbox_id" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."issue_invitation_delivery_notice"("p_outbox_id" "uuid") OWNER TO "postgres";

COMMENT ON FUNCTION "public"."issue_invitation_delivery_notice"("p_outbox_id" "uuid") IS 'Token-free delivery issue step. Prepares an INFORMATIONAL notice: no secret is minted and invitations.token_hash is not touched. Supersedes issue_invitation_delivery_token for the production flow; that function is retained for backward compatibility.';

ALTER FUNCTION "public"."issue_invitation_delivery_token"("p_outbox_id" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."link_asset_document"("p_asset_id" "uuid", "p_doc_id" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."list_estate_assets"("p_estate_id" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."list_estate_invitations"("p_estate" "uuid", "p_limit" integer) OWNER TO "postgres";

ALTER FUNCTION "public"."list_estate_members"("p_estate_id" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."list_orphan_storage_objects"("p_grace_hours" integer, "p_max" integer) OWNER TO "postgres";

ALTER FUNCTION "public"."mark_recovery_code_used"("p_id" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."notification_estate_home"("p_estate_id" "uuid", "p_user_id" "uuid") OWNER TO "postgres";

COMMENT ON FUNCTION "public"."notification_estate_home"("p_estate_id" "uuid", "p_user_id" "uuid") IS 'Closed set of two in-app destinations for a lifecycle notification, chosen from authoritative membership. Not an authorization: both destinations re-check their own authority on arrival.';

ALTER FUNCTION "public"."notification_event_copy"("p_event" "text") OWNER TO "postgres";

COMMENT ON FUNCTION "public"."notification_event_copy"("p_event" "text") IS 'Immutable closed catalog of lifecycle notification copy, keyed by event name. Returns ZERO rows for an unknown event, which emit_lifecycle_notification treats as a refusal to emit. This is the ONLY place notification copy exists; emitters name an event and never compose text.';

ALTER FUNCTION "public"."notification_grant_is_live"("p_status" "text", "p_release_condition" "text", "p_approved_at" timestamp with time zone) OWNER TO "postgres";

COMMENT ON FUNCTION "public"."notification_grant_is_live"("p_status" "text", "p_release_condition" "text", "p_approved_at" timestamp with time zone) IS 'True only for a grant that confers access in the BASE lifecycle, a deliberate subset of can_access_document''s rule since 11-D: the lifecycle argument is pinned to active, so a death-conditioned grant emits NOTHING even at death_verified — release announcements are 11-F copy, not a side effect of grant emission. Claim-conditioned grants stay dormant. Decides whether to SPEAK, never what may be READ — no read path consults it.';

ALTER FUNCTION "public"."owner_notice_age_gate"() OWNER TO "postgres";

COMMENT ON FUNCTION "public"."owner_notice_age_gate"() IS 'How old an owner safety notice may be and still be worth sending (Phase 11-F): the challenge window plus one day of queue slack, DERIVED so the two cannot drift apart. NULL when the window is unconfigured, which makes the claim routine refuse rather than treat everything as fresh.';

ALTER FUNCTION "public"."owner_notice_census"() OWNER TO "postgres";

COMMENT ON FUNCTION "public"."owner_notice_census"() IS 'Read-only owner-notice outbox classification (Phase 11-F, Stage 3): totals, status and age distribution, and the actionable/stale/purgeable split against the CURRENT age gate. Phase 11-OC adds the acceptance and episode splits (accepted_total, legacy_unaccepted, no_episode, superseded_total, by_generation), each reconciling against total with no nameless gap. Counts only — never a recipient address. Admin-gated.';

ALTER FUNCTION "public"."owner_notice_claim_visibility"() OWNER TO "postgres";

COMMENT ON FUNCTION "public"."owner_notice_claim_visibility"() IS 'How long an owner-notice claim is believed before the row may be reclaimed (Phase 11-OBR). One hour: 12x the highest serverless execution ceiling and ~180x the real per-row send cost, and far inside the age gate so every daily drain remains a recovery opportunity. Single-sourced so the claim routine and the census cannot disagree about what is stale.';

ALTER FUNCTION "public"."owner_notice_episode_kinds"() OWNER TO "postgres";

COMMENT ON FUNCTION "public"."owner_notice_episode_kinds"() IS 'The owner-safety notice kinds that constitute ONE episode (Phase 11-OC / Phase C): the initial window-opened dispatch and every deliberate operator re-notice. Single-sourced so the readiness census, the operator projection and the re-notice routine cannot disagree about which rows belong to the episode — a literal in any one of them would make the remedy invisible to the instrument that measures whether the remedy worked. INTERNAL: no client role may read the vocabulary.';

ALTER FUNCTION "public"."owner_notice_reissue_assessment"("p_case" "uuid") OWNER TO "postgres";

COMMENT ON FUNCTION "public"."owner_notice_reissue_assessment"("p_case" "uuid") IS 'The ONE decision about whether an episode may be re-noticed (Phase 11-OC / Phase C), consumed by both reissue_owner_safety_notice and the operator case-file projection so the console can never offer an action the door refuses. Every refusal carries a NAMED code from a closed set. Reports owner_channel_resolvable as a BOOLEAN and never an address. INTERNAL — its callers are gated; a client role cannot reach it.';

ALTER FUNCTION "public"."owner_notice_reissue_kind"() OWNER TO "postgres";

COMMENT ON FUNCTION "public"."owner_notice_reissue_kind"() IS 'The notice_kind a deliberate operator re-notice takes (Phase 11-OC / Phase C). Distinct from death_process.window_opened so a second warning is never recorded as the initial window-opening event. Both kinds are members of owner_notice_episode_kinds().';

ALTER FUNCTION "public"."owner_notice_release_authority"("p_case" "uuid") OWNER TO "postgres";

COMMENT ON FUNCTION "public"."owner_notice_release_authority"("p_case" "uuid") IS 'THE owner-notice release authority (Phase 11-OC / Phase D), consumed by both authorize_release and the operator case-file projection so the console can never offer a release the door refuses. A release qualifies ONLY when the CURRENT generation (superseded_by is null) of the CURRENT case episode carries notice_accepted_at, and now() > that instant + challenge_window_duration() STRICTLY. No status string participates in the decision, so a future status cannot become release-qualifying by not being cancelled. notice_accepted_at is PROVIDER ACCEPTANCE and never mailbox delivery; owner_notified_at is provenance and is never the clock. Every refusal carries a NAMED code from a closed set. Discloses no address and no identity. INTERNAL.';

ALTER FUNCTION "public"."owner_notice_release_readiness_census"() OWNER TO "postgres";

COMMENT ON FUNCTION "public"."owner_notice_release_readiness_census"() IS 'Read-only Phase 11-OC blast-radius projection: how many estates standing at the release door would be admitted or refused by the Phase D acceptance predicate, classified by the state of the CURRENT generation of the CURRENT case episode. Scoped by case exactly as the Phase D predicate is, so it cannot credit an accepted notice from a prior rejected process. Every estate lands in one NAMED bucket and the buckets reconcile against the total. Counts ONLY — no estate id, no case id, no user id, no recipient address, on any branch. Admin-gated.';

ALTER FUNCTION "public"."owner_notice_require_episode"() OWNER TO "postgres";

COMMENT ON FUNCTION "public"."owner_notice_require_episode"() IS 'Phase 11-OC: every NEW owner-notice row must name its death-verification case. Enforced on INSERT only, deliberately — legacy rows carry a NULL case_id and MUST stay updatable, because the stale sweep and the settle path both UPDATE them. A NOT VALID CHECK constraint would have refused those UPDATEs and broken the drain; that was measured, not assumed.';

ALTER FUNCTION "public"."place_legal_hold"("p_doc_id" "uuid", "p_reason" "text") OWNER TO "postgres";

ALTER FUNCTION "public"."preview_required_verification_level"("p_estate" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."provision_from_invitation"("p_invitation_id" "uuid", "p_user" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."purge_outbox_health"() OWNER TO "postgres";

ALTER FUNCTION "public"."purge_outbox_rows"("p_outbox" "text", "p_before" timestamp with time zone, "p_reason" "text") OWNER TO "postgres";

COMMENT ON FUNCTION "public"."purge_outbox_rows"("p_outbox" "text", "p_before" timestamp with time zone, "p_reason" "text") IS 'Purges SETTLED owner-notice rows older than an explicit cutoff (Phase 11-F, Stage 3). Writes the outbox_purge_audit row BEFORE deleting, in the same transaction, so a silent purge is impossible. Requires a non-blank reason, refuses an unknown outbox name, and never touches queued or processing rows — those are live safety messages still in flight.';

ALTER FUNCTION "public"."record_consent"("p_type" "text", "p_version" "text") OWNER TO "postgres";

ALTER FUNCTION "public"."record_invitation_delivery_failure"("p_outbox_id" "uuid", "p_error" "text") OWNER TO "postgres";

ALTER FUNCTION "public"."record_invitation_delivery_outcome"("p_outbox_id" "uuid", "p_delivery_generation" integer, "p_outcome" "text", "p_provider_message_id" "text", "p_failure_class" "text") OWNER TO "postgres";

ALTER FUNCTION "public"."record_orphan_sweep"("p_mode" "text", "p_paths" "text"[], "p_grace_hours" integer, "p_batch_cap" integer) OWNER TO "postgres";

ALTER FUNCTION "public"."record_owner_notice_outcome"("p_id" "uuid", "p_outcome" "text", "p_failure_class" "text") OWNER TO "postgres";

COMMENT ON FUNCTION "public"."record_owner_notice_outcome"("p_id" "uuid", "p_outcome" "text", "p_failure_class" "text") IS 'Write-back half of the owner-safety notice drain (Phase 11-K). providerAccepted -> dispatched; retryPending -> queued with backoff until a 3-attempt cap, then failedPermanent; outcomeUncertain and failedPermanent are terminal. An already-settled row is a no-op, so a duplicate callback can never produce a second send. Records no recipient address. service_role only.';

ALTER FUNCTION "public"."record_purge_result"("p_outbox_id" "uuid", "p_ok" boolean, "p_error" "text") OWNER TO "postgres";

ALTER FUNCTION "public"."reissue_owner_safety_notice"("p_case" "uuid", "p_reason" "text") OWNER TO "postgres";

COMMENT ON FUNCTION "public"."reissue_owner_safety_notice"("p_case" "uuid", "p_reason" "text") IS 'Queues a NEW owner-safety notice generation for the CURRENT case episode (Phase 11-OC / Phase C). Eligible only when the current generation is failedPermanent, outcomeUncertain, or dispatched with NO acceptance fact (the pre-Phase-A legacy class) — and only from owner_notification_dispatched or challenge_window. Appends a row and retires the previous one with a pointer; mutates no forensic field of the predecessor. The new row starts queued with NULL acceptance, so a successful call means NEW WARNING QUEUED and never provider acceptance or delivery. Recipient is DERIVED, never supplied, and never returned. Requires a non-blank reason and writes death_process.owner_notice_reissued. Admin-gated inside the definer.';

ALTER FUNCTION "public"."release_condition_satisfied"("p_release_condition" "text", "p_approved_at" timestamp with time zone, "p_policy" "text", "p_lifecycle_state" "text") OWNER TO "postgres";

COMMENT ON FUNCTION "public"."release_condition_satisfied"("p_release_condition" "text", "p_approved_at" timestamp with time zone, "p_policy" "text", "p_lifecycle_state" "text") IS 'THE canonical release-condition authority (Phase 11-B; lifecycle-aware since 11-D; safety-seamed in 11-E). Answers only "is this condition presently satisfied", never who may receive a grant, what tier they get, or whether anyone has died. PURE: the lifecycle arrives as an argument, resolved by SECURITY DEFINER consumers through public.estate_lifecycle_state — never from claim status, evidence, or attained levels. after_verified_death is satisfied only under the standard policy at RELEASED (R7) — death_verified, challenge_window and challenge_halted all satisfy nothing; incapacity, the legacy fused value, identity and claim conditions are dormant under every policy. Unknown condition, unknown policy, unknown lifecycle and NULL all refuse.';

ALTER FUNCTION "public"."release_condition_writable"("p_release_condition" "text") OWNER TO "postgres";

COMMENT ON FUNCTION "public"."release_condition_writable"("p_release_condition" "text") IS 'Write-time vocabulary gate for access_grants.release_condition (Phase 11-B). Accepts the split after_verified_death / after_verified_incapacity and REFUSES the deprecated fused after_verified_death_or_incapacity, which remains legal in the CHECK so stored rows stay readable and unreinterpreted. Writable is not live: incapacity is satisfied by no policy, and death only by the authoritative death_verified lifecycle under the standard policy (11-D).';

ALTER FUNCTION "public"."release_legal_hold"("p_hold_id" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."replace_vault_document"("p_doc_id" "uuid", "p_new_storage_path" "text") OWNER TO "postgres";

ALTER FUNCTION "public"."request_invitation_redelivery"("p_estate" "uuid", "p_invitation" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."require_aal2"() OWNER TO "postgres";

ALTER FUNCTION "public"."require_breakglass_justification"("p_reason" "text", "p_case_ref" "text") OWNER TO "postgres";

ALTER FUNCTION "public"."required_verification_level"("p_estate" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."resolve_membership"("p_email" "text", "p_phone" "text") OWNER TO "postgres";

ALTER FUNCTION "public"."restore_estate_asset"("p_asset_id" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."revoke_document_grant"("p_grant_id" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."revoke_estate_invitation"("p_estate" "uuid", "p_invitation" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."revoke_invitation"("p_invitation_id" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."rls_auto_enable"() OWNER TO "postgres";

ALTER FUNCTION "public"."set_jurisdiction_floor"("p_jurisdiction" "text", "p_floor_level" "public"."verification_level", "p_is_approved" boolean, "p_notes" "text", "p_reason" "text", "p_case_ref" "text") OWNER TO "postgres";

ALTER FUNCTION "public"."submit_claim_packet"("p_estate" "uuid", "p_death_certificate_doc_id" "uuid", "p_executor_id_doc_id" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."submit_claim_with_evidence"("p_estate" "uuid", "p_death_cert_doc_id" "uuid", "p_death_cert_path" "text", "p_executor_id_doc_id" "uuid", "p_executor_id_path" "text") OWNER TO "postgres";

ALTER FUNCTION "public"."unlink_asset_document"("p_asset_id" "uuid", "p_doc_id" "uuid") OWNER TO "postgres";

ALTER FUNCTION "public"."update_asset_grant"("p_grant_id" "uuid", "p_visibility_tier" "text") OWNER TO "postgres";

ALTER FUNCTION "public"."update_document_grant"("p_grant_id" "uuid", "p_visibility_tier" "text") OWNER TO "postgres";

ALTER FUNCTION "public"."update_estate_asset"("p_asset_id" "uuid", "p_subtype" "text", "p_label" "text", "p_sensitivity" "text", "p_owner_label" "text", "p_country_code" "text", "p_jurisdiction" "text", "p_institution_name" "text", "p_reference_hint" "text", "p_approximate_value_cents" bigint, "p_currency" "text", "p_notes" "text", "p_beneficiary_note" "text", "p_verification_status" "text", "p_clear" "text"[]) OWNER TO "postgres";

ALTER FUNCTION "public"."update_vault_document"("p_doc_id" "uuid", "p_title" "text", "p_doc_subtype" "text", "p_sensitivity" "text") OWNER TO "postgres";

ALTER FUNCTION "public"."validate_recovery_code"("p_code" "text") OWNER TO "postgres";

ALTER FUNCTION "public"."write_admin_breakglass_audit"("p_action" "text", "p_table" "text", "p_target" "uuid", "p_estate" "uuid", "p_reason" "text", "p_case_ref" "text", "p_meta" "jsonb") OWNER TO "postgres";

ALTER FUNCTION "public"."write_audit"("p_action" "text", "p_table" "text", "p_target" "uuid", "p_estate" "uuid", "p_meta" "jsonb") OWNER TO "postgres";

ALTER TABLE "public"."admins" OWNER TO "postgres";

ALTER TABLE "public"."assets" OWNER TO "postgres";

ALTER SEQUENCE "public"."audit_logs_id_seq" OWNER TO "postgres";

ALTER TABLE "public"."beneficiaries" OWNER TO "postgres";

COMMENT ON COLUMN "public"."beneficiaries"."user_id" IS 'auth.uid() of the user who accepted the beneficiary invitation for this row. Bare uuid, no FK (matches estate_memberships.user_id). Null until accepted. RLS read policy: a beneficiary sees only rows where user_id = auth.uid().';

ALTER TABLE "public"."claim_packets" OWNER TO "postgres";

ALTER TABLE "public"."connection_secrets" OWNER TO "postgres";

ALTER TABLE "public"."consent_records" OWNER TO "postgres";

ALTER TABLE "public"."death_verification_cases" OWNER TO "postgres";

ALTER TABLE "public"."death_verification_evidence" OWNER TO "postgres";

ALTER TABLE "public"."document_sensitivity" OWNER TO "postgres";

ALTER TABLE "public"."document_subtype" OWNER TO "postgres";

ALTER TABLE "public"."document_type" OWNER TO "postgres";

ALTER TABLE "public"."documents" OWNER TO "postgres";

COMMENT ON COLUMN "public"."documents"."sensitivity" IS 'Document-sensitivity ceiling (5-level monotonic ladder), DISTINCT from per-category ResourceSensitivity. Default sealed = owner-only until reclassified down. low/medium/high grantable to beneficiary + professional_delegate; restricted excludes beneficiaries (professional-only); sealed excludes all non-owners (owner always inherent). low/medium/high are equally grantable today — informational only; real floors are restricted + sealed. See docs/live-data-migration.md Appendix A.3.';

ALTER TABLE "public"."encrypted_instructions" OWNER TO "postgres";

ALTER TABLE "public"."estate_asset_category" OWNER TO "postgres";

ALTER TABLE "public"."estate_asset_documents" OWNER TO "postgres";

ALTER TABLE "public"."estate_asset_subtype" OWNER TO "postgres";

ALTER TABLE "public"."estate_assets" OWNER TO "postgres";

ALTER TABLE "public"."estate_designations" OWNER TO "postgres";

ALTER TABLE "public"."estate_lifecycle" OWNER TO "postgres";

ALTER TABLE "public"."estate_memberships" OWNER TO "postgres";

ALTER TABLE "public"."estates" OWNER TO "postgres";

ALTER TABLE "public"."invitation_delivery_outbox" OWNER TO "postgres";

COMMENT ON TABLE "public"."invitation_delivery_outbox" IS 'Durable queue of invitation deliveries. Holds NO secret — the raw token is minted at issue time by issue_invitation_delivery() and never persisted. Drained by a trusted worker as service_role.';

COMMENT ON COLUMN "public"."invitation_delivery_outbox"."delivery_generation" IS 'Increments ONLY on deliberate token issuance. Half of the provider idempotency key. A retry reuses the generation; a reissue increments it and invalidates the previous link.';

COMMENT ON COLUMN "public"."invitation_delivery_outbox"."provider_message_id" IS 'Server-confined provider handle. NEVER returned to a client and NEVER logged.';

COMMENT ON COLUMN "public"."invitation_delivery_outbox"."failure_class" IS 'Sanitized classification. Raw provider text is not retained here — it can carry recipient PII.';

ALTER TABLE "public"."invitations" OWNER TO "postgres";

COMMENT ON COLUMN "public"."invitations"."revoked_by" IS 'Owner (or console admin) who revoked. Never returned to a client — actor identity is audit data.';

ALTER TABLE "public"."jurisdiction_policy" OWNER TO "postgres";

ALTER TABLE "public"."legal_holds" OWNER TO "postgres";

ALTER TABLE "public"."mfa_recovery_attempts" OWNER TO "postgres";

ALTER TABLE "public"."normalized_assets" OWNER TO "postgres";

ALTER TABLE "public"."notifications" OWNER TO "postgres";

COMMENT ON TABLE "public"."notifications" IS 'Self-scoped notification store. Rows are written ONLY by SECURITY DEFINER emitters — authenticated holds no INSERT grant and, since 0050, no EXECUTE on emit_notification either. Lifecycle copy is a constant looked up by event name in notification_event_copy; no emitter composes or interpolates text.';

ALTER TABLE "public"."outbox_purge_audit" OWNER TO "postgres";

ALTER TABLE "public"."owner_notice_outbox" OWNER TO "postgres";

COMMENT ON COLUMN "public"."owner_notice_outbox"."notice_kind" IS 'Which owner-safety event this row carries (Phase 11-OC). `death_process.window_opened` is the INITIAL dispatch, written once per episode by dispatch_owner_safety_notice. `death_process.window_renotice` is a deliberate operator re-issue (Phase C) and is never written by the drain, the settle path or the stale sweep. Both kinds belong to the SAME episode — see owner_notice_episode_kinds() — so the release predicate and the readiness census read the set, never one literal. OPERATOR vocabulary only: the email template takes no kind and cannot tell a recipient which attempt they are receiving.';

COMMENT ON COLUMN "public"."owner_notice_outbox"."status" IS 'queued -> processing -> {dispatched | outcomeUncertain | failedPermanent}, or cancelled. outcomeUncertain (Phase 11-K) means the provider never answered: the message may or may not have been accepted, so the row is TERMINAL — never re-claimed, never re-sent, never purged.';

COMMENT ON COLUMN "public"."owner_notice_outbox"."claimed_at" IS 'When claim_owner_notices last moved this row into `processing` (Phase 11-OBR / OB-1). NULL means never claimed, or claimed before this column existed. It is the ONLY basis for deciding that a claim has gone stale — attempts is a counter with no clock, and requested_at does not move on claim. Never backfilled: a guessed claim time defeats the column.';

COMMENT ON COLUMN "public"."owner_notice_outbox"."notice_accepted_at" IS 'The instant the email provider ACCEPTED this specific message (Phase 11-OC). Written ONLY by record_owner_notice_outcome on the providerAccepted branch, in the same UPDATE as status and dispatched_at. It is NOT delivery: providerAccepted is not delivered, received, opened or viewed, and nothing downstream may rename it. From Phase D this is the ONE fact that makes a release qualify, and the anchor of the challenge window. Never backfilled, never synthesized, never coalesced to dispatched_at or owner_notified_at — authority is decided by SOURCE, and both of those were written by paths that could not have been telling the truth about acceptance.';

COMMENT ON COLUMN "public"."owner_notice_outbox"."case_id" IS 'The death-verification case this notice belongs to (Phase 11-OC) — the EPISODE key. Estate id is insufficient: one estate may legitimately experience several independent death processes over time, and an accepted notice from a prior REJECTED case must never authorize a later one. NULL only on rows written before Phase A; those belong to no episode, satisfy no release predicate, and are remediated by operator re-notice rather than by a backfill.';

COMMENT ON COLUMN "public"."owner_notice_outbox"."generation" IS 'Which attempt this row is within its episode (Phase 11-OC). 1 for an original dispatch; n+1 for a deliberate operator re-notice, computed under the predecessor row lock and never from an unlocked max(). Every pre-Phase-A row is definitionally generation 1 — no re-notice mechanism has ever existed — which is the ONLY backfill in this phase and is vacuous rather than inferred.';

COMMENT ON COLUMN "public"."owner_notice_outbox"."superseded_by" IS 'The successor generation that retired this row (Phase 11-OC). NULL means this is the CURRENT generation of its episode. This is a LOOKUP enforced by a partial unique index, deliberately not a derived max(): a derived-max invariant cannot be expressed as a constraint, so the release door would depend on an invariant only the writer maintains, and a concurrent double-reissue would produce two rows that both believe they are latest. A retired row keeps its terminal status and its failure_class — that evidence is why the reissue was warranted — and gains only this pointer.';

COMMENT ON COLUMN "public"."owner_notice_outbox"."reissue_reason" IS 'Why a generation >= 2 exists (Phase 11-OC), from a closed four-value vocabulary. DERIVED from the predecessor row inside the definer, never a caller parameter: a caller-supplied reason would let an operator relabel an outcomeUncertain reissue as a failed one and skip its acknowledgement.';

COMMENT ON COLUMN "public"."owner_notice_outbox"."reissued_by" IS 'The operator who authorized a re-notice (Phase 11-OC). Derived from auth.uid() inside the definer — the reviewer_a discipline — so the routine has no parameter of this type and nominating somebody else is unwritable rather than merely forbidden.';

ALTER TABLE "public"."profiles" OWNER TO "postgres";

ALTER TABLE "public"."recovery_codes" OWNER TO "postgres";

ALTER TABLE "public"."release_authorizations" OWNER TO "postgres";

ALTER TABLE "public"."release_safety_policy" OWNER TO "postgres";

ALTER TABLE "public"."storage_deletion_outbox" OWNER TO "postgres";

ALTER TABLE "public"."taxonomy_version" OWNER TO "postgres";

ALTER TABLE "public"."upload_policy" OWNER TO "postgres";

COMMENT ON INDEX "public"."owner_notice_outbox_one_current_per_episode_idx" IS 'Exactly ONE current generation per episode (Phase 11-OC / Phase C). Replaces the Phase A index on (case_id, channel, notice_kind), which became insufficient the moment an episode could hold two kinds: it would have permitted one current window_opened row AND one current window_renotice row for the same case — two live generations. Strictly stronger than its predecessor and lossless on every extant row, because notice_kind admitted one value until this migration. Legacy rows carry a NULL case_id and NULLs are distinct in a unique index, so they neither collide nor are blocked.';

GRANT USAGE ON SCHEMA "public" TO "postgres";

GRANT USAGE ON SCHEMA "public" TO "anon";

GRANT USAGE ON SCHEMA "public" TO "authenticated";

GRANT USAGE ON SCHEMA "public" TO "service_role";

REVOKE ALL ON FUNCTION "public"."admin_authorize_claim_evidence"("p_claim" "uuid", "p_slot" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."admin_authorize_claim_evidence"("p_claim" "uuid", "p_slot" "text") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."admin_create_executor_invitation"("p_estate" "uuid", "p_kind" "text", "p_invitee_email" "text", "p_invitee_phone" "text", "p_reason" "text", "p_case_ref" "text", "p_expires_in_days" integer) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."admin_create_executor_invitation"("p_estate" "uuid", "p_kind" "text", "p_invitee_email" "text", "p_invitee_phone" "text", "p_reason" "text", "p_case_ref" "text", "p_expires_in_days" integer) TO "authenticated";

REVOKE ALL ON FUNCTION "public"."admin_decide_claim_packet"("p_claim_id" "uuid", "p_decision" "text", "p_review_notes" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."admin_decide_claim_packet"("p_claim_id" "uuid", "p_decision" "text", "p_review_notes" "text") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."admin_decide_death_verification_case"("p_case" "uuid", "p_decision" "text", "p_note" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."admin_decide_death_verification_case"("p_case" "uuid", "p_decision" "text", "p_note" "text") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."admin_get_death_verification_case"("p_case" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."admin_get_death_verification_case"("p_case" "uuid") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."admin_list_audit"("p_before_created" timestamp with time zone, "p_before_id" bigint, "p_limit" integer, "p_estate" "uuid", "p_actor" "uuid", "p_action" "text", "p_source" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."admin_list_audit"("p_before_created" timestamp with time zone, "p_before_id" bigint, "p_limit" integer, "p_estate" "uuid", "p_actor" "uuid", "p_action" "text", "p_source" "text") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."admin_list_claim_packets"("p_estate" "uuid", "p_status" "text", "p_before_submitted" timestamp with time zone, "p_before_id" "uuid", "p_limit" integer) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."admin_list_claim_packets"("p_estate" "uuid", "p_status" "text", "p_before_submitted" timestamp with time zone, "p_before_id" "uuid", "p_limit" integer) TO "authenticated";

REVOKE ALL ON FUNCTION "public"."admin_list_claim_packets_enriched"("p_estate" "uuid", "p_status" "text", "p_before_submitted" timestamp with time zone, "p_before_id" "uuid", "p_limit" integer) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."admin_list_claim_packets_enriched"("p_estate" "uuid", "p_status" "text", "p_before_submitted" timestamp with time zone, "p_before_id" "uuid", "p_limit" integer) TO "authenticated";

REVOKE ALL ON FUNCTION "public"."admin_list_death_verification_cases"("p_status" "text", "p_before_initiated" timestamp with time zone, "p_before_id" "uuid", "p_limit" integer) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."admin_list_death_verification_cases"("p_status" "text", "p_before_initiated" timestamp with time zone, "p_before_id" "uuid", "p_limit" integer) TO "authenticated";

REVOKE ALL ON FUNCTION "public"."admin_list_jurisdiction_policy"() FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."admin_list_jurisdiction_policy"() TO "authenticated";

REVOKE ALL ON FUNCTION "public"."admin_reconciliation_report"() FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."admin_reconciliation_report"() TO "authenticated";

REVOKE ALL ON FUNCTION "public"."admin_require_gate"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "public"."admin_review_death_evidence"("p_evidence" "uuid", "p_outcome" "text", "p_note" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."admin_review_death_evidence"("p_evidence" "uuid", "p_outcome" "text", "p_note" "text") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."admin_set_attained_verification_level"("p_case" "uuid", "p_level" "public"."verification_level", "p_basis" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."admin_set_attained_verification_level"("p_case" "uuid", "p_level" "public"."verification_level", "p_basis" "text") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."apply_estate_lifecycle_transition"("p_estate" "uuid", "p_to" "text", "p_case" "uuid", "p_reason" "text") FROM PUBLIC;

GRANT SELECT ON TABLE "public"."access_requests" TO "authenticated";

GRANT SELECT,INSERT,UPDATE ON TABLE "public"."access_grants" TO "authenticated";

REVOKE ALL ON FUNCTION "public"."archive_estate_asset"("p_asset_id" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."archive_estate_asset"("p_asset_id" "uuid") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."assert_not_self_invitee"("p_invitee_email" "text", "p_invitee_phone" "text") FROM PUBLIC;

REVOKE ALL ON FUNCTION "public"."attach_death_verification_evidence"("p_case" "uuid", "p_document" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."attach_death_verification_evidence"("p_case" "uuid", "p_document" "uuid") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."authorize_purge"("p_outbox_id" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."authorize_purge"("p_outbox_id" "uuid") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."authorize_release"("p_estate" "uuid", "p_reason" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."authorize_release"("p_estate" "uuid", "p_reason" "text") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."begin_challenge_window"("p_estate" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."begin_challenge_window"("p_estate" "uuid") TO "authenticated";

GRANT ALL ON FUNCTION "public"."bind_invitation_token"("p_token" "text") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."cancel_death_verification_case"("p_case" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."cancel_death_verification_case"("p_case" "uuid") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."challenge_death_process"("p_estate" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."challenge_death_process"("p_estate" "uuid") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."challenge_window_duration"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "public"."claim_invitation_deliveries"("p_max" integer, "p_outbox_id" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."claim_invitation_deliveries"("p_max" integer, "p_outbox_id" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."claim_owner_notices"("p_max" integer) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."claim_owner_notices"("p_max" integer) TO "service_role";

GRANT SELECT ON TABLE "public"."connections" TO "authenticated";

REVOKE ALL ON FUNCTION "public"."create_estate_asset"("p_estate" "uuid", "p_subtype" "text", "p_label" "text", "p_sensitivity" "text", "p_owner_label" "text", "p_country_code" "text", "p_jurisdiction" "text", "p_institution_name" "text", "p_reference_hint" "text", "p_approximate_value_cents" bigint, "p_currency" "text", "p_notes" "text", "p_beneficiary_note" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."create_estate_asset"("p_estate" "uuid", "p_subtype" "text", "p_label" "text", "p_sensitivity" "text", "p_owner_label" "text", "p_country_code" "text", "p_jurisdiction" "text", "p_institution_name" "text", "p_reference_hint" "text", "p_approximate_value_cents" bigint, "p_currency" "text", "p_notes" "text", "p_beneficiary_note" "text") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."create_estate_invitation"("p_estate" "uuid", "p_proposed_role" "text", "p_invitee_email" "text", "p_invitee_phone" "text", "p_show_estate_name" boolean, "p_show_inviter_name" boolean, "p_expires_in_days" integer) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."create_estate_invitation"("p_estate" "uuid", "p_proposed_role" "text", "p_invitee_email" "text", "p_invitee_phone" "text", "p_show_estate_name" boolean, "p_show_inviter_name" boolean, "p_expires_in_days" integer) TO "authenticated";

REVOKE ALL ON FUNCTION "public"."create_invitation"("p_estate" "uuid", "p_kind" "text", "p_proposed_role" "text", "p_invitee_email" "text", "p_invitee_phone" "text", "p_show_estate_name" boolean, "p_show_inviter_name" boolean, "p_expires_in_days" integer) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."create_invitation"("p_estate" "uuid", "p_kind" "text", "p_proposed_role" "text", "p_invitee_email" "text", "p_invitee_phone" "text", "p_show_estate_name" boolean, "p_show_inviter_name" boolean, "p_expires_in_days" integer) TO "authenticated";

REVOKE ALL ON FUNCTION "public"."create_vault_document"("p_estate" "uuid", "p_doc_id" "uuid", "p_storage_path" "text", "p_title" "text", "p_doc_subtype" "text", "p_sensitivity" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."create_vault_document"("p_estate" "uuid", "p_doc_id" "uuid", "p_storage_path" "text", "p_title" "text", "p_doc_subtype" "text", "p_sensitivity" "text") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."delete_vault_document"("p_doc_id" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."delete_vault_document"("p_doc_id" "uuid") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."dispatch_owner_safety_notice"("p_estate" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."dispatch_owner_safety_notice"("p_estate" "uuid") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."emit_lifecycle_notification"("p_user_id" "uuid", "p_estate_id" "uuid", "p_event" "text", "p_deep_link" "text") FROM PUBLIC;

REVOKE ALL ON FUNCTION "public"."emit_notification"("p_user_id" "uuid", "p_estate_id" "uuid", "p_category" "text", "p_title" "text", "p_body" "text", "p_deep_link" "text", "p_payload" "jsonb") FROM PUBLIC;

REVOKE ALL ON FUNCTION "public"."estate_lifecycle_state"("p_estate" "uuid") FROM PUBLIC;

REVOKE ALL ON FUNCTION "public"."estate_owner_gate"("p_estate" "uuid") FROM PUBLIC;

REVOKE ALL ON FUNCTION "public"."estate_owner_user_id"("p_estate_id" "uuid") FROM PUBLIC;

REVOKE ALL ON FUNCTION "public"."estate_release_state"("p_estate" "uuid") FROM PUBLIC;

REVOKE ALL ON FUNCTION "public"."extend_estate_invitation"("p_estate" "uuid", "p_invitation" "uuid", "p_expires_in_days" integer) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."extend_estate_invitation"("p_estate" "uuid", "p_invitation" "uuid", "p_expires_in_days" integer) TO "authenticated";

REVOKE ALL ON FUNCTION "public"."extend_invitation"("p_invitation_id" "uuid", "p_expires_in_days" integer) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."extend_invitation"("p_invitation_id" "uuid", "p_expires_in_days" integer) TO "authenticated";

REVOKE ALL ON FUNCTION "public"."forward_client_audit"("p_action" "text", "p_estate" "uuid", "p_table" "text", "p_target" "uuid", "p_meta" "jsonb", "p_client_ts" timestamp with time zone) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."forward_client_audit"("p_action" "text", "p_estate" "uuid", "p_table" "text", "p_target" "uuid", "p_meta" "jsonb", "p_client_ts" timestamp with time zone) TO "authenticated";

REVOKE ALL ON FUNCTION "public"."get_document_taxonomy"() FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."get_document_taxonomy"() TO "authenticated";

REVOKE ALL ON FUNCTION "public"."get_estate_asset_taxonomy"() FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."get_estate_asset_taxonomy"() TO "authenticated";

REVOKE ALL ON FUNCTION "public"."get_estate_discovery"("p_estate" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."get_estate_discovery"("p_estate" "uuid") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."get_estate_readiness"("p_estate" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."get_estate_readiness"("p_estate" "uuid") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."get_executor_workspace"("p_estate" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."get_executor_workspace"("p_estate" "uuid") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."get_my_estate_capability_facts"("p_estate" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."get_my_estate_capability_facts"("p_estate" "uuid") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."get_my_estate_designations"() FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."get_my_estate_designations"() TO "authenticated";

REVOKE ALL ON FUNCTION "public"."get_my_fiduciary_estates"() FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."get_my_fiduciary_estates"() TO "authenticated";

REVOKE ALL ON FUNCTION "public"."get_owner_safety_status"("p_estate" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."get_owner_safety_status"("p_estate" "uuid") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."get_professional_workspace"("p_estate" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."get_professional_workspace"("p_estate" "uuid") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."get_upload_policy"() FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."get_upload_policy"() TO "authenticated";

REVOKE ALL ON FUNCTION "public"."initiate_death_verification_case"("p_estate" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."initiate_death_verification_case"("p_estate" "uuid") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."inventory_disclosure_tier"("p_estate" "uuid", "p_uid" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."inventory_disclosure_tier"("p_estate" "uuid", "p_uid" "uuid") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."invitation_delivery_health"() FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."invitation_delivery_health"() TO "authenticated";

REVOKE ALL ON FUNCTION "public"."invitation_effective_status"("p_status" "text", "p_expires_at" timestamp with time zone) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."invitation_preview"("p_token" "text") TO "anon";

REVOKE ALL ON FUNCTION "public"."invitation_write_gate"("p_estate" "uuid") FROM PUBLIC;

REVOKE ALL ON FUNCTION "public"."is_admin"() FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."is_admin"() TO "authenticated";

REVOKE ALL ON FUNCTION "public"."is_estate_executor"("p_estate" "uuid", "p_user" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."is_estate_executor"("p_estate" "uuid", "p_user" "uuid") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."issue_invitation_delivery"("p_outbox_id" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."issue_invitation_delivery"("p_outbox_id" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."issue_invitation_delivery_notice"("p_outbox_id" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."issue_invitation_delivery_notice"("p_outbox_id" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."issue_invitation_delivery_token"("p_outbox_id" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."issue_invitation_delivery_token"("p_outbox_id" "uuid") TO "service_role";

REVOKE ALL ON FUNCTION "public"."link_asset_document"("p_asset_id" "uuid", "p_doc_id" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."link_asset_document"("p_asset_id" "uuid", "p_doc_id" "uuid") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."list_estate_invitations"("p_estate" "uuid", "p_limit" integer) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."list_estate_invitations"("p_estate" "uuid", "p_limit" integer) TO "authenticated";

REVOKE ALL ON FUNCTION "public"."list_orphan_storage_objects"("p_grace_hours" integer, "p_max" integer) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."list_orphan_storage_objects"("p_grace_hours" integer, "p_max" integer) TO "authenticated";

REVOKE ALL ON FUNCTION "public"."notification_estate_home"("p_estate_id" "uuid", "p_user_id" "uuid") FROM PUBLIC;

REVOKE ALL ON FUNCTION "public"."owner_notice_age_gate"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "public"."owner_notice_census"() FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."owner_notice_census"() TO "authenticated";

REVOKE ALL ON FUNCTION "public"."owner_notice_claim_visibility"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "public"."owner_notice_episode_kinds"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "public"."owner_notice_reissue_assessment"("p_case" "uuid") FROM PUBLIC;

REVOKE ALL ON FUNCTION "public"."owner_notice_reissue_kind"() FROM PUBLIC;

REVOKE ALL ON FUNCTION "public"."owner_notice_release_authority"("p_case" "uuid") FROM PUBLIC;

REVOKE ALL ON FUNCTION "public"."owner_notice_release_readiness_census"() FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."owner_notice_release_readiness_census"() TO "authenticated";

REVOKE ALL ON FUNCTION "public"."place_legal_hold"("p_doc_id" "uuid", "p_reason" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."place_legal_hold"("p_doc_id" "uuid", "p_reason" "text") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."preview_required_verification_level"("p_estate" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."preview_required_verification_level"("p_estate" "uuid") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."provision_from_invitation"("p_invitation_id" "uuid", "p_user" "uuid") FROM PUBLIC;

REVOKE ALL ON FUNCTION "public"."purge_outbox_health"() FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."purge_outbox_health"() TO "authenticated";

REVOKE ALL ON FUNCTION "public"."purge_outbox_rows"("p_outbox" "text", "p_before" timestamp with time zone, "p_reason" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."purge_outbox_rows"("p_outbox" "text", "p_before" timestamp with time zone, "p_reason" "text") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."record_consent"("p_type" "text", "p_version" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."record_consent"("p_type" "text", "p_version" "text") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."record_invitation_delivery_failure"("p_outbox_id" "uuid", "p_error" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."record_invitation_delivery_failure"("p_outbox_id" "uuid", "p_error" "text") TO "service_role";

REVOKE ALL ON FUNCTION "public"."record_invitation_delivery_outcome"("p_outbox_id" "uuid", "p_delivery_generation" integer, "p_outcome" "text", "p_provider_message_id" "text", "p_failure_class" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."record_invitation_delivery_outcome"("p_outbox_id" "uuid", "p_delivery_generation" integer, "p_outcome" "text", "p_provider_message_id" "text", "p_failure_class" "text") TO "service_role";

REVOKE ALL ON FUNCTION "public"."record_orphan_sweep"("p_mode" "text", "p_paths" "text"[], "p_grace_hours" integer, "p_batch_cap" integer) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."record_orphan_sweep"("p_mode" "text", "p_paths" "text"[], "p_grace_hours" integer, "p_batch_cap" integer) TO "authenticated";

REVOKE ALL ON FUNCTION "public"."record_owner_notice_outcome"("p_id" "uuid", "p_outcome" "text", "p_failure_class" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."record_owner_notice_outcome"("p_id" "uuid", "p_outcome" "text", "p_failure_class" "text") TO "service_role";

REVOKE ALL ON FUNCTION "public"."record_purge_result"("p_outbox_id" "uuid", "p_ok" boolean, "p_error" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."record_purge_result"("p_outbox_id" "uuid", "p_ok" boolean, "p_error" "text") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."reissue_owner_safety_notice"("p_case" "uuid", "p_reason" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."reissue_owner_safety_notice"("p_case" "uuid", "p_reason" "text") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."release_condition_satisfied"("p_release_condition" "text", "p_approved_at" timestamp with time zone, "p_policy" "text", "p_lifecycle_state" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."release_condition_satisfied"("p_release_condition" "text", "p_approved_at" timestamp with time zone, "p_policy" "text", "p_lifecycle_state" "text") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."release_condition_writable"("p_release_condition" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."release_condition_writable"("p_release_condition" "text") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."release_legal_hold"("p_hold_id" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."release_legal_hold"("p_hold_id" "uuid") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."replace_vault_document"("p_doc_id" "uuid", "p_new_storage_path" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."replace_vault_document"("p_doc_id" "uuid", "p_new_storage_path" "text") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."request_invitation_redelivery"("p_estate" "uuid", "p_invitation" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."request_invitation_redelivery"("p_estate" "uuid", "p_invitation" "uuid") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."require_breakglass_justification"("p_reason" "text", "p_case_ref" "text") FROM PUBLIC;

REVOKE ALL ON FUNCTION "public"."required_verification_level"("p_estate" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."resolve_membership"("p_email" "text", "p_phone" "text") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."restore_estate_asset"("p_asset_id" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."restore_estate_asset"("p_asset_id" "uuid") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."revoke_estate_invitation"("p_estate" "uuid", "p_invitation" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."revoke_estate_invitation"("p_estate" "uuid", "p_invitation" "uuid") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."revoke_invitation"("p_invitation_id" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."revoke_invitation"("p_invitation_id" "uuid") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."set_jurisdiction_floor"("p_jurisdiction" "text", "p_floor_level" "public"."verification_level", "p_is_approved" boolean, "p_notes" "text", "p_reason" "text", "p_case_ref" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."set_jurisdiction_floor"("p_jurisdiction" "text", "p_floor_level" "public"."verification_level", "p_is_approved" boolean, "p_notes" "text", "p_reason" "text", "p_case_ref" "text") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."submit_claim_packet"("p_estate" "uuid", "p_death_certificate_doc_id" "uuid", "p_executor_id_doc_id" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."submit_claim_packet"("p_estate" "uuid", "p_death_certificate_doc_id" "uuid", "p_executor_id_doc_id" "uuid") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."submit_claim_with_evidence"("p_estate" "uuid", "p_death_cert_doc_id" "uuid", "p_death_cert_path" "text", "p_executor_id_doc_id" "uuid", "p_executor_id_path" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."submit_claim_with_evidence"("p_estate" "uuid", "p_death_cert_doc_id" "uuid", "p_death_cert_path" "text", "p_executor_id_doc_id" "uuid", "p_executor_id_path" "text") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."unlink_asset_document"("p_asset_id" "uuid", "p_doc_id" "uuid") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."unlink_asset_document"("p_asset_id" "uuid", "p_doc_id" "uuid") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."update_estate_asset"("p_asset_id" "uuid", "p_subtype" "text", "p_label" "text", "p_sensitivity" "text", "p_owner_label" "text", "p_country_code" "text", "p_jurisdiction" "text", "p_institution_name" "text", "p_reference_hint" "text", "p_approximate_value_cents" bigint, "p_currency" "text", "p_notes" "text", "p_beneficiary_note" "text", "p_verification_status" "text", "p_clear" "text"[]) FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."update_estate_asset"("p_asset_id" "uuid", "p_subtype" "text", "p_label" "text", "p_sensitivity" "text", "p_owner_label" "text", "p_country_code" "text", "p_jurisdiction" "text", "p_institution_name" "text", "p_reference_hint" "text", "p_approximate_value_cents" bigint, "p_currency" "text", "p_notes" "text", "p_beneficiary_note" "text", "p_verification_status" "text", "p_clear" "text"[]) TO "authenticated";

REVOKE ALL ON FUNCTION "public"."update_vault_document"("p_doc_id" "uuid", "p_title" "text", "p_doc_subtype" "text", "p_sensitivity" "text") FROM PUBLIC;

GRANT ALL ON FUNCTION "public"."update_vault_document"("p_doc_id" "uuid", "p_title" "text", "p_doc_subtype" "text", "p_sensitivity" "text") TO "authenticated";

REVOKE ALL ON FUNCTION "public"."write_admin_breakglass_audit"("p_action" "text", "p_table" "text", "p_target" "uuid", "p_estate" "uuid", "p_reason" "text", "p_case_ref" "text", "p_meta" "jsonb") FROM PUBLIC;

REVOKE ALL ON FUNCTION "public"."write_audit"("p_action" "text", "p_table" "text", "p_target" "uuid", "p_estate" "uuid", "p_meta" "jsonb") FROM PUBLIC;

GRANT SELECT ON TABLE "public"."beneficiaries" TO "authenticated";

GRANT SELECT ON TABLE "public"."claim_packets" TO "authenticated";

GRANT SELECT ON TABLE "public"."consent_records" TO "authenticated";

GRANT SELECT ON TABLE "public"."documents" TO "authenticated";

GRANT SELECT ON TABLE "public"."estate_asset_documents" TO "authenticated";

GRANT SELECT ON TABLE "public"."estate_assets" TO "authenticated";

GRANT SELECT,UPDATE ON TABLE "public"."invitation_delivery_outbox" TO "service_role";

GRANT SELECT,INSERT,DELETE ON TABLE "public"."normalized_assets" TO "authenticated";

GRANT SELECT,UPDATE ON TABLE "public"."notifications" TO "authenticated";

GRANT SELECT ON TABLE "public"."recovery_codes" TO "authenticated";

GRANT SELECT,UPDATE ON TABLE "public"."storage_deletion_outbox" TO "service_role";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";

ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
