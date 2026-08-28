-- ════════════════════════════════════════════════════════════════════════════════════════════
-- MODEL C CANONICAL BOOTSTRAP · 90 · policies on application tables
--
-- GENERATED — do not edit by hand. Regenerate with:
--   node scripts/generateBootstrap.mjs --snapshot <verified snapshot> --evidence <dir>
--
-- DERIVED FROM live authoritative state, NOT from migrations 0001-0060 and NOT from test preambles.
-- This file represents CURRENT authoritative schema through migration 0060.
-- It is NOT a pre-0001 baseline; no pre-0001 schema is recoverable from repository evidence.
--
-- statements: 36
-- ════════════════════════════════════════════════════════════════════════════════════════════

SET client_min_messages = warning;
SET row_security = off;
SET search_path = public, storage, extensions, pg_catalog;

CREATE POLICY "access_grants_insert" ON "public"."access_grants" FOR INSERT TO "authenticated" WITH CHECK (("public"."is_estate_owner"("estate_id") AND ("granted_by_user_id" = "auth"."uid"())));

CREATE POLICY "access_grants_read" ON "public"."access_grants" FOR SELECT TO "authenticated" USING ((("granted_by_user_id" = "auth"."uid"()) OR ("grantee_user_id" = "auth"."uid"()) OR "public"."is_estate_owner"("estate_id")));

CREATE POLICY "access_grants_update" ON "public"."access_grants" FOR UPDATE TO "authenticated" USING ("public"."is_estate_owner"("estate_id")) WITH CHECK ("public"."is_estate_owner"("estate_id"));

CREATE POLICY "access_requests_select" ON "public"."access_requests" FOR SELECT TO "authenticated" USING ((("requester_user_id" = "auth"."uid"()) OR "public"."is_estate_owner"("estate_id")));

CREATE POLICY "assets_read" ON "public"."assets" FOR SELECT USING ((("owner_id" = "auth"."uid"()) OR "public"."is_estate_member"("estate_id")));

CREATE POLICY "assets_write" ON "public"."assets" USING (("owner_id" = "auth"."uid"())) WITH CHECK (("owner_id" = "auth"."uid"()));

CREATE POLICY "audit_read_own" ON "public"."audit_logs" FOR SELECT USING (("actor_id" = "auth"."uid"()));

CREATE POLICY "beneficiaries_read" ON "public"."beneficiaries" FOR SELECT USING ((("owner_id" = "auth"."uid"()) OR ("user_id" = "auth"."uid"()) OR "public"."is_estate_owner"("estate_id")));

CREATE POLICY "beneficiaries_write" ON "public"."beneficiaries" USING (("owner_id" = "auth"."uid"())) WITH CHECK (("owner_id" = "auth"."uid"()));

CREATE POLICY "claim_own_read" ON "public"."claim_packets" FOR SELECT USING (("requested_by" = "auth"."uid"()));

CREATE POLICY "connections_require_aal2" ON "public"."connections" AS RESTRICTIVE USING ((COALESCE(("auth"."jwt"() ->> 'aal'::"text"), 'aal1'::"text") = 'aal2'::"text")) WITH CHECK ((COALESCE(("auth"."jwt"() ->> 'aal'::"text"), 'aal1'::"text") = 'aal2'::"text"));

CREATE POLICY "connections_select_owner" ON "public"."connections" FOR SELECT USING (("public"."is_estate_owner"("estate_id") AND (COALESCE(("auth"."jwt"() ->> 'aal'::"text"), 'aal1'::"text") = 'aal2'::"text")));

CREATE POLICY "consent_own_read" ON "public"."consent_records" FOR SELECT USING (("user_id" = "auth"."uid"()));

CREATE POLICY "documents_read" ON "public"."documents" FOR SELECT TO "authenticated" USING (("public"."is_estate_owner"("estate_id") OR "public"."can_access_document"("id")));

CREATE POLICY "estate_asset_documents_read" ON "public"."estate_asset_documents" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."estate_assets" "a"
  WHERE (("a"."id" = "estate_asset_documents"."asset_id") AND "public"."is_estate_owner"("a"."estate_id")))));

CREATE POLICY "estate_assets_read_owner" ON "public"."estate_assets" FOR SELECT TO "authenticated" USING ("public"."is_estate_owner"("estate_id"));

CREATE POLICY "estate_designations_designee_read" ON "public"."estate_designations" FOR SELECT USING (("user_id" = "auth"."uid"()));

CREATE POLICY "estate_designations_owner_all" ON "public"."estate_designations" USING ("public"."is_estate_owner"("estate_id")) WITH CHECK ("public"."is_estate_owner"("estate_id"));

CREATE POLICY "estates_member_read" ON "public"."estates" FOR SELECT USING ("public"."is_estate_member"("id"));

CREATE POLICY "estates_owner_all" ON "public"."estates" USING (("owner_id" = "auth"."uid"())) WITH CHECK (("owner_id" = "auth"."uid"()));

CREATE POLICY "instructions_executor_read_after_release" ON "public"."encrypted_instructions" FOR SELECT USING ((("released" = true) AND "public"."is_estate_executor"("estate_id", "auth"."uid"())));

CREATE POLICY "instructions_owner_all" ON "public"."encrypted_instructions" USING (("owner_id" = "auth"."uid"())) WITH CHECK (("owner_id" = "auth"."uid"()));

CREATE POLICY "invitations_invitee_read" ON "public"."invitations" FOR SELECT USING ((("status" = ANY (ARRAY['pending'::"text", 'matched'::"text"])) AND ("expires_at" > "now"()) AND (("invitee_email" = ( SELECT "profiles"."email"
   FROM "public"."profiles"
  WHERE ("profiles"."id" = "auth"."uid"()))) OR ("invitee_phone" = ( SELECT "profiles"."phone"
   FROM "public"."profiles"
  WHERE ("profiles"."id" = "auth"."uid"()))))));

CREATE POLICY "invitations_member_read" ON "public"."invitations" FOR SELECT USING ("public"."is_estate_member"("estate_id"));

CREATE POLICY "invitations_owner_manage" ON "public"."invitations" USING ("public"."is_estate_owner"("estate_id")) WITH CHECK ("public"."is_estate_owner"("estate_id"));

CREATE POLICY "members_owner_manage" ON "public"."estate_memberships" USING ("public"."is_estate_owner"("estate_id")) WITH CHECK ("public"."is_estate_owner"("estate_id"));

CREATE POLICY "members_self_read" ON "public"."estate_memberships" FOR SELECT USING (("user_id" = "auth"."uid"()));

CREATE POLICY "normalized_assets_owner_all" ON "public"."normalized_assets" USING (("public"."is_estate_owner"("estate_id") AND (COALESCE(("auth"."jwt"() ->> 'aal'::"text"), 'aal1'::"text") = 'aal2'::"text"))) WITH CHECK (("public"."is_estate_owner"("estate_id") AND (COALESCE(("auth"."jwt"() ->> 'aal'::"text"), 'aal1'::"text") = 'aal2'::"text")));

CREATE POLICY "normalized_assets_require_aal2" ON "public"."normalized_assets" AS RESTRICTIVE USING ((COALESCE(("auth"."jwt"() ->> 'aal'::"text"), 'aal1'::"text") = 'aal2'::"text")) WITH CHECK ((COALESCE(("auth"."jwt"() ->> 'aal'::"text"), 'aal1'::"text") = 'aal2'::"text"));

CREATE POLICY "notifications_select_self" ON "public"."notifications" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));

CREATE POLICY "notifications_self" ON "public"."notifications" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));

CREATE POLICY "notifications_update_self" ON "public"."notifications" FOR UPDATE TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));

CREATE POLICY "profiles_self_insert" ON "public"."profiles" FOR INSERT WITH CHECK (("id" = "auth"."uid"()));

CREATE POLICY "profiles_self_read" ON "public"."profiles" FOR SELECT USING (("id" = "auth"."uid"()));

CREATE POLICY "profiles_self_update" ON "public"."profiles" FOR UPDATE USING (("id" = "auth"."uid"()));

CREATE POLICY "recovery_codes_select_own" ON "public"."recovery_codes" FOR SELECT USING (("user_id" = "auth"."uid"()));
