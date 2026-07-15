-- public.claim_packets — CAPTURED FROM LIVE 2026-07-15. LIVE IS AUTHORITATIVE.
--
-- Was live-only with ZERO version-control record (the handle_new_user / audit_logs / admins live-only
-- class). A death-claim SUBMIT + human-REVIEW workflow — NOT KYC / cryptographic attestation: a member
-- submits a packet referencing two supporting documents (death certificate + executor ID); a reviewer
-- decides; status walks submitted -> under_review -> approved/rejected -> released. So the earlier
-- "attest-vs-KYC identity-verification" decision is effectively ANSWERED IN-SCHEMA: it is neither — it's
-- human document review.
--
-- Access posture AT CAPTURE: RLS ENABLED with a SELECT (estate owner/member) + INSERT (requested_by =
-- auth.uid() AND estate member/owner) policy — but NO client-role GRANTS (only postgres; born clean under
-- the 0012 default-priv cure), and NO trigger. So there is no authenticated/anon PostgREST path yet and
-- no writer/reader — effectively a DORMANT schema scaffold. Any real access path would be a SECURITY
-- DEFINER RPC (owner = postgres); iOS is mock (MockClaimService / orchestration) today. FK rebuild order:
-- needs estates, documents (live-only), and auth.users.

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

alter table public.claim_packets enable row level security;

-- SELECT: any estate owner or member sees the estate's claim packets.
create policy claim_estate_visible on public.claim_packets
  for select using (public.is_estate_owner(estate_id) or public.is_estate_member(estate_id));

-- INSERT: a member/owner may submit, and only as themselves (requested_by = auth.uid()).
create policy claim_insert_member on public.claim_packets
  for insert with check (
    requested_by = auth.uid()
    and (public.is_estate_member(estate_id) or public.is_estate_owner(estate_id))
  );

-- NOTE: no GRANT to anon/authenticated/service_role at capture — the RLS policies above are moot for
-- client roles until a grant OR a SECURITY DEFINER RPC is added. No UPDATE/DELETE policy exists (a
-- reviewer decision path would need one, or an RPC). Dormant scaffold — see the Slice-A recon.
