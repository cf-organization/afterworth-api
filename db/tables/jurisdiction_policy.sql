-- public.jurisdiction_policy — Slice C3 (migration 0026). The counsel-owned verification-floor config.
--
-- COUNSEL'S table: engineering builds the mechanism; counsel populates the VALUES (real per-jurisdiction
-- floors) as approved rows later. Ships EMPTY — "unmapped = maximum" is a CODE invariant in
-- required_verification_level() (0027), NOT a seed row, so fail-closed survives any row deletion.
--
-- verification_level is an ORDERED Postgres ENUM (attestation < kyc < enhanced_kyc by declaration order): the
-- ordering IS the type, so GREATEST()/comparisons are native + single-sourced (monotonicity can't drift from
-- a rank mapping). Add a level via `ALTER TYPE public.verification_level ADD VALUE '<x>' BEFORE/AFTER '<y>'`.
--
-- is_counsel_approved = the DATA-GATE C5 reads: a row that exists but is UNAPPROVED is treated as unmapped
-- (-> enhanced_kyc). RLS posture: the matrix is an ATTACK MAP -> world-UNREADABLE by clients (NO
-- anon/authenticated grant; RLS on with no policies). Readers = the DEFINER policy function + admin RPCs only.
-- Verified live 2026-07-16: born-clean ACL (zero client grants), matrix unreadable (has_table_privilege
-- auth=f/anon=f), enum ordering (GREATEST(attestation,kyc)=kyc).

do $$ begin
  if not exists (select 1 from pg_type where typname = 'verification_level') then
    create type public.verification_level as enum ('attestation', 'kyc', 'enhanced_kyc');
  end if;
end $$;

create table if not exists public.jurisdiction_policy (
  jurisdiction        text        not null,
  floor_level         public.verification_level not null,
  is_counsel_approved boolean     not null default false,
  notes               text,
  updated_by          uuid        references auth.users(id),
  updated_at          timestamptz not null default now(),
  created_at          timestamptz not null default now(),
  constraint jurisdiction_policy_pkey primary key (jurisdiction)
);

alter table public.jurisdiction_policy enable row level security;
-- NO policies + NO anon/authenticated grants: a direct client SELECT is denied at the grant layer. Writes go
-- through set_jurisdiction_floor (admin-gated + audited); reads through required_verification_level (DEFINER)
-- and admin_list_jurisdiction_policy (admin-gated). See db/functions/ + db/migrations/0026.
