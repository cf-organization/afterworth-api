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
-- RLS / ROLE MISMATCH — RECONCILED by migration 0020 (Slice R). The executor-read policy ORIGINALLY gated on
-- estate_memberships.role IN ('executor','trustee') — phantom roles the membership CHECK forbids, so the path
-- was structurally UNREACHABLE. Executor/trustee are now modeled as DESIGNATIONS (0019 estate_designations,
-- NOT membership roles), and the policy uses is_estate_executor(estate_id, auth.uid()) — the executor-read
-- path is now REACHABLE (verified live 2026-07-15: executor+released -> read; executor+unreleased -> denied;
-- non-designee -> denied). FK rebuild order: needs estates + auth.users.

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

-- EXECUTOR/TRUSTEE read AFTER release — via the designation model (0019/0020). Reachable: an ACTIVE
-- executor/trustee designee reads a RELEASED instruction; the release gate (released = true) still holds.
create policy instructions_executor_read_after_release on public.encrypted_instructions
  for select using (
    released = true
    and public.is_estate_executor(encrypted_instructions.estate_id, auth.uid())
  );

-- NOTE: no GRANT to anon/authenticated/service_role at capture (only postgres) — the RLS policies above are
-- moot for client roles until a grant OR a SECURITY DEFINER RPC is added, and no wrap/unwrap function
-- exists. Dormant scaffold — see the Slice-A recon (Finding 2, master-key-custody).
