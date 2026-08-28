-- ════════════════════════════════════════════════════════════════════════════════════════════
-- MODEL C CANONICAL BOOTSTRAP · 20 · custom types
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

CREATE TYPE "public"."verification_level" AS ENUM (
    'attestation',
    'kyc',
    'enhanced_kyc'
);
