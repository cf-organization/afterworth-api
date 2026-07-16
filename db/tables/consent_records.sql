-- public.consent_records — Slice C2 (migration 0025). Durable, versioned, APPEND-ONLY acknowledgment consent.
--
-- SCOPE = ACKNOWLEDGMENT class ONLY: "a user affirmed a versioned document at a server-stamped time" (tax
-- disclaimer, ToS, privacy, data-sharing, beneficiary-disclosure, platform-disclosure). EXPLICITLY NOT
-- attestation-grade consent (identity-bound, non-repudiable, statutory, claim-bound, statement-capturing) —
-- that STRICTER class is deferred to C4 under counsel as its own record; do NOT overload this table.
--
-- APPEND-ONLY / immutable (the audit_logs posture): a consent is a historical fact — new consent = a NEW ROW,
-- NEVER an update. Enforced by GRANTS: no client UPDATE/DELETE. Writes flow ONLY through record_consent
-- (DEFINER); reads are own-only via RLS. accepted_at is SERVER-stamped (record_consent takes no timestamp — a
-- client consent timestamp is forgeable). Verified live 2026-07-15: born-clean ACL (authenticated SELECT only),
-- append-only (update=f/delete=f, 0 update policies), server-stamp, own-only RLS, version gate.

create table if not exists public.consent_records (
  id               uuid        not null default uuid_generate_v4(),
  user_id          uuid        not null references auth.users(id) on delete cascade,
  consent_type     text        not null
                     check (consent_type in (
                       'terms_of_service', 'privacy_policy', 'data_sharing',
                       'beneficiary_disclosure', 'tax_disclaimer', 'platform_disclosure'
                     )),
  document_version text        not null,
  accepted_at      timestamptz not null default now(),   -- SERVER-derived; never client-supplied
  created_at       timestamptz not null default now(),
  constraint consent_records_pkey primary key (id)
);

-- The "has user accepted type X at version V" gate query.
create index if not exists consent_records_user_type_version_idx
  on public.consent_records (user_id, consent_type, document_version);

alter table public.consent_records enable row level security;

-- Reads own-only; writes RPC-only (no INSERT policy/grant); NO UPDATE/DELETE policy or grant (append-only).
create policy consent_own_read on public.consent_records
  for select using (user_id = auth.uid());
grant select on public.consent_records to authenticated;

-- NOTE: the ONLY client grant is authenticated SELECT (RLS-scoped to own). Writes go through record_consent
-- (db/functions/record_consent.sql). Immutability is structural — there is no UPDATE/DELETE path for any
-- client role. A version bump = a new document_version = a new row (the old rows stay as historical facts).
