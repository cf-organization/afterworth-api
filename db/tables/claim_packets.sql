-- public.claim_packets — CAPTURED FROM LIVE 2026-07-15. LIVE IS AUTHORITATIVE.
--
-- Was live-only with ZERO version-control record (the handle_new_user / audit_logs / admins live-only
-- class). A death-claim SUBMIT + human-REVIEW workflow — NOT KYC / cryptographic attestation: a member
-- submits a packet referencing two supporting documents (death certificate + executor ID); a reviewer
-- decides; status walks submitted -> under_review -> approved/rejected -> released. So the earlier
-- "attest-vs-KYC identity-verification" decision is effectively ANSWERED IN-SCHEMA: it is neither — it's
-- human document review.
--
-- Access posture — ACTIVATED by Slice C1 (migration 0023), submit path:
--   * WRITES are RPC-only. submit_claim_packet (DEFINER, gated inside via is_estate_executor) is the sole
--     submit door; reviewer decisions are 0024 (admin RPCs). The table keeps NO client INSERT/UPDATE grant.
--   * READS are claimant-own: SELECT granted to authenticated + policy claim_own_read (requested_by =
--     auth.uid()). Admins read via the DEFINER admin_list_claim_packets, bypassing RLS. aclexplode verified
--     born-clean: authenticated SELECT ONLY (no anon/service_role, no disease grants).
--   * The two capture-era policies (claim_estate_visible owner/any-member, claim_insert_member) were
--     DROPPED by 0023 — the first was too broad (a beneficiary must not see the executor's claim + its
--     sensitive doc refs) and the second moot (writes are RPC-only). See db/migrations/0023.
-- iOS is mock (MockClaimService / orchestration) today. FK rebuild order: needs estates, documents
-- (live-only), and auth.users.

create table if not exists public.claim_packets (
  id                       uuid        not null default uuid_generate_v4(),
  estate_id                uuid        not null references public.estates(id) on delete cascade,
  requested_by             uuid        not null references auth.users(id),
  status                   text        not null default 'submitted'
                             check (status in ('submitted','under_review','approved','rejected','released')),
  death_certificate_doc_id uuid        references public.documents(id),
  executor_id_doc_id       uuid        references public.documents(id),
  reviewer_id              uuid        references auth.users(id),
  review_notes             text,
  submitted_at             timestamptz default now(),
  decided_at               timestamptz,
  constraint claim_packets_pkey primary key (id)
);

create index if not exists claim_packets_estate_id_idx on public.claim_packets using btree (estate_id);

-- Idempotency (0023): at most ONE ACTIVE (non-rejected) claim per estate; rejected rows coexist
-- (append-only history — the revoked-designation precedent), so a rejected claim can be re-submitted.
create unique index if not exists claim_packets_one_active_per_estate
  on public.claim_packets (estate_id) where status <> 'rejected';

alter table public.claim_packets enable row level security;

-- SELECT: the claimant reads their own claim (requested_by = auth.uid()). Admins read via the DEFINER
-- admin_list_claim_packets (0024), which bypasses RLS. No client INSERT/UPDATE policy — writes are RPC-only.
create policy claim_own_read on public.claim_packets
  for select using (requested_by = auth.uid());

grant select on public.claim_packets to authenticated;

-- NOTE: writes flow ONLY through DEFINER RPCs (submit_claim_packet 0023; admin_* decisions 0024). The
-- table exposes exactly one client grant: authenticated SELECT (RLS-scoped to claimant-own). No UPDATE/DELETE
-- policy or grant — reviewer transitions are DEFINER-RPC-only. The RELEASE transition is Slice C5.
