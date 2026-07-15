-- public.encrypted_instructions — CAPTURED FROM LIVE 2026-07-15. LIVE IS AUTHORITATIVE.
--
-- Was live-only with ZERO version-control record (the handle_new_user / audit_logs / admins / claim_packets
-- live-only class). REAL ENVELOPE ENCRYPTION (NOT aspirational base64): a per-instruction data key encrypts
-- the body (ciphertext + iv/nonce), and that data key is itself WRAPPED (wrapped_key) by a master key.
-- `title` is plaintext (listable); the body is sealed. So the deferred "key-model" decision is NARROWED to
-- MASTER-KEY CUSTODY — who holds the key that unwraps wrapped_key, and where the unwrap runs: server/KMS
-- (server can decrypt) vs client-side zero-knowledge (only the executor's device unwraps). That custody
-- choice is the whole remaining question.
--
-- DORMANT HALF-BUILD at capture: grants are postgres-only (born clean under the 0012 default-priv cure) — no
-- authenticated/anon PostgREST path; no trigger; and NO live wrap/unwrap FUNCTION exists (the fixed
-- prokind='f' functions sweep returned nothing), so the bytea columns are written by NOTHING yet. Wiring
-- this = building the entire crypto layer outward from the custody decision. Correctly deferred.
--
-- (!) RLS / ROLE MISMATCH — captured AS-IS, NOT fixed: instructions_executor_read_after_release gates SELECT
-- on estate_memberships.role IN ('executor','trustee'), but the live estate_memberships role CHECK only
-- permits primary_user / beneficiary / professional_delegate — so those roles CANNOT EXIST and the
-- executor-read path is UNREACHABLE today. The executor/trustee vocabulary is half-plumbed (present in
-- invitations.kind, absent from invitations.proposed_role + the estate_memberships role CHECK). A future
-- encrypted-instructions slice must reconcile this. FK rebuild order: needs estates + auth.users.

create table if not exists public.encrypted_instructions (
  id                uuid        not null default uuid_generate_v4(),
  estate_id         uuid        not null references public.estates(id) on delete cascade,
  owner_id          uuid        not null references auth.users(id) on delete cascade,
  title             text        not null,
  ciphertext        bytea       not null,
  iv                bytea       not null,
  wrapped_key       bytea       not null,
  release_condition text        not null
                      check (release_condition in ('on_death','on_executor_claim','manual')),
  released          boolean     default false,
  released_at       timestamptz,
  created_at        timestamptz default now(),
  constraint encrypted_instructions_pkey primary key (id)
);

create index if not exists encrypted_instructions_estate_id_idx
  on public.encrypted_instructions using btree (estate_id);

alter table public.encrypted_instructions enable row level security;

-- OWNER (the instruction's author) has full control of their own rows.
create policy instructions_owner_all on public.encrypted_instructions
  for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());

-- EXECUTOR/TRUSTEE read AFTER release — see the RLS/ROLE MISMATCH note above: the roles 'executor'/'trustee'
-- cannot exist under the current estate_memberships role CHECK, so this path is UNREACHABLE today.
create policy instructions_executor_read_after_release on public.encrypted_instructions
  for select using (
    released = true
    and exists (
      select 1 from public.estate_memberships
      where estate_memberships.estate_id = encrypted_instructions.estate_id
        and estate_memberships.user_id  = auth.uid()
        and estate_memberships.role     = any (array['executor','trustee'])
        and estate_memberships.status   = 'approved'
    )
  );

-- NOTE: no GRANT to anon/authenticated/service_role at capture (only postgres) — the RLS policies above are
-- moot for client roles until a grant OR a SECURITY DEFINER RPC is added, and no wrap/unwrap function
-- exists. Dormant scaffold — see the Slice-A recon (Finding 2, master-key-custody).
