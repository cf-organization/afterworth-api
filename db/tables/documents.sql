-- public.documents — CAPTURED FROM LIVE 2026-07-19. LIVE IS AUTHORITATIVE.
--
-- Live-only until now (the handle_new_user / audit_logs / admins / claim_packets live-only class). grants.sql
-- recorded authenticated SELECT-only but MISSED the live documents_write policy (ALL / owner_id = auth.uid())
-- — a live-vs-VC divergence surfaced by Slice C1.6a (CQ3). This file is now the VC record; re-apply on reset.
--
-- Access posture AFTER Slice C1.6a (migration 0030):
--   * READS — authenticated SELECT, RLS documents_read = is_estate_owner(estate_id) OR can_access_document(id):
--     the owner sees every doc in their estate; a non-owner sees a doc ONLY through a covering access grant.
--     /api/vault/documents field-masks below full_detail. UNCHANGED by 0030.
--   * WRITES — the live documents_write (ALL / owner_id = auth.uid()) was DROPPED by 0030: there is NO client
--     INSERT/UPDATE/DELETE path. Row creation is DEFINER-RPC-ONLY (submit_claim_with_evidence, migration 0031;
--     the owner vault-doc RPC is the named fast-follow). Confirmed no live client write path before dropping
--     (iOS uploadDocument/uploadClaimDocument mock; api/vault/documents.ts .select-only). The table keeps
--     exactly ONE client grant: authenticated SELECT.
--   * BYTES live in the private `documents` storage bucket; storage.objects RLS (0030) gates client reads/writes
--     by ESTATE (owner anywhere in their estate; executor only under estates/<estate_id>/claim-evidence/).
--     Admins read evidence via the C1.6b service-role endpoint (bypasses RLS) — the sole audited admin door.
-- FK rebuild order: needs public.estates + auth.users.

create table if not exists public.documents (
  id           uuid not null default uuid_generate_v4(),
  estate_id    uuid not null references public.estates(id) on delete cascade,
  owner_id     uuid not null references auth.users(id) on delete cascade,
  doc_type     text not null
                 check (doc_type in ('will','trust','power_of_attorney','insurance_policy','deed',
                        'id_document','tax_return','medical_directive','beneficiary_form','death_certificate','other')),
  title        text not null,
  storage_path text not null,
  mime_type    text,
  size_bytes   bigint,
  sha256       text,
  is_encrypted boolean default true,
  created_at   timestamptz default now(),
  sensitivity  text not null default 'sealed'
                 check (sensitivity in ('low','medium','high','restricted','sealed')),
  constraint documents_pkey primary key (id)
);

create index if not exists documents_estate_id_idx on public.documents using btree (estate_id);

alter table public.documents enable row level security;

-- SELECT: owner sees their estate's docs; a non-owner only via a covering grant (can_access_document).
create policy documents_read on public.documents
  for select to authenticated
  using (public.is_estate_owner(estate_id) or public.can_access_document(id));

grant select on public.documents to authenticated;

-- WRITES ARE DEFINER-RPC-ONLY. The live documents_write (ALL / {public} / owner_id = auth.uid()) was dropped by
-- migration 0030 (Slice C1.6a) — no client INSERT/UPDATE/DELETE. Row creation flows through DEFINER RPCs
-- (submit_claim_with_evidence 0031; owner vault-doc RPC = fast-follow). No UPDATE/DELETE policy or grant.
