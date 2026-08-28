-- ════════════════════════════════════════════════════════════════════════════════════════════
-- MODEL C CANONICAL BOOTSTRAP · 120 · event triggers (HOSTED_COMPATIBILITY_PROOF_REQUIRED)
--
-- GENERATED — do not edit by hand. Regenerate with:
--   node scripts/generateBootstrap.mjs --snapshot <verified snapshot> --evidence <dir>
--
-- DERIVED FROM live authoritative state, NOT from migrations 0001-0060 and NOT from test preambles.
-- This file represents CURRENT authoritative schema through migration 0060.
-- It is NOT a pre-0001 baseline; no pre-0001 schema is recoverable from repository evidence.
--
-- statements: 1
-- ════════════════════════════════════════════════════════════════════════════════════════════

SET client_min_messages = warning;
SET row_security = off;

-- ★ HOSTED_COMPATIBILITY_PROOF_REQUIRED
--   CREATE EVENT TRIGGER requires privileges that a hosted Supabase migration role may not hold.
--   A successful local CREATE EVENT TRIGGER does NOT prove hosted compatibility, and this flag is
--   NOT cleared by any local test. Only execution in a real non-production Supabase project can
--   clear it, and R-02 (no non-prod environment exists) currently blocks that.
--
--   Derived from event-trigger-bindings-20260828.csv. Six further event triggers exist live and are
--   owned by supabase_admin (pgrst_ddl_watch, issue_pg_cron_access, …); they are PLATFORM-OWNED and
--   deliberately excluded. Ownership was decided by evtowner, not by name.

CREATE EVENT TRIGGER "ensure_rls"
  ON ddl_command_end
  WHEN TAG IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
  EXECUTE FUNCTION "public"."rls_auto_enable"();
