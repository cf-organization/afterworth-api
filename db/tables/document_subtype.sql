-- public.document_subtype — created by migration 0035 (owner vault-doc upload). Source of truth for the
-- PERSIST-BOTH taxonomy: the fine-grained client subtype -> the coarse public.documents.doc_type (11-CHECK),
-- with an is_active gate. The client (create_vault_document / update_vault_document) sends ONLY the subtype;
-- the RPC looks it up here, DERIVES doc_type, and persists BOTH (subtype-in / both-out). Unknown subtype ->
-- reject (fail-closed); present-but-inactive -> reject.
--
-- Born clean: RLS on, NO client grants — read only inside the DEFINER RPCs (no client read path in V1; the
-- picker is the iOS VaultDocumentType enum). A get_document_subtypes() client read is a deferred nicety.
--
-- ★ SEED lives in migration 0035 (NOT duplicated here) — it is 132 rows regenerated from the iOS
--   VaultDocumentType.legacyCategory mapping (EstateDocument.swift), the SINGLE source of the derivation.
--   Duplicating 132 rows across two files is a drift hazard; on reset, apply 0035 for the seed. To widen the
--   vocabulary, add rows via a new migration (or deactivate via is_active) — the enum and this catalog must
--   stay in sync, and a client subtype absent here fails CLOSED. FK rebuild order: none (referenced BY documents).

create table if not exists public.document_subtype (
  subtype    text primary key,
  doc_type   text not null
               check (doc_type in ('will','trust','power_of_attorney','insurance_policy','deed',
                      'id_document','tax_return','medical_directive','beneficiary_form','death_certificate','other')),
  is_active  boolean     not null default true,
  created_at timestamptz not null default now()
);

alter table public.document_subtype enable row level security;
-- NO client grants / policies (born clean). Read path = the DEFINER RPCs only. Seed: see migration 0035.
