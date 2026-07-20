-- public.upload_policy — created by migration 0032 (upload contract unification). Source of truth.
--
-- The SINGLE server-driven source for the evidence-upload limits, so "what the client is told"
-- (get_upload_policy) == "what the server enforces" (submit_claim_with_evidence quotas) == the serving guard
-- (admin_authorize_claim_evidence.max_upload_bytes). Singleton (id=1 CHECK). Born clean: RLS on, NO client
-- grants — the client reads via the DEFINER get_upload_policy(); admins edit via the SQL editor (a
-- set_upload_policy admin RPC is a deferred nicety).
--
-- THE DUALITY: Storage enforces the bucket file_size_limit + allowed_mime_types INDEPENDENTLY of this table.
-- This table is the documented AUTHORITY; a limit change requires BOTH edits (table + bucket config). The
-- drift-check proof leg (bucket == table) is the guardrail. FK rebuild order: none.

create table if not exists public.upload_policy (
  id                  int         primary key default 1 check (id = 1),
  max_upload_bytes    bigint      not null,
  max_files_per_claim int         not null,
  max_aggregate_bytes bigint      not null,
  allowed_mime_types  text[]      not null,
  updated_at          timestamptz not null default now()
);

alter table public.upload_policy enable row level security;

-- Seeded singleton (mirrors the bucket: 25MB / 2 files / 50MB / pdf,jpeg,png,heic).
insert into public.upload_policy (id, max_upload_bytes, max_files_per_claim, max_aggregate_bytes, allowed_mime_types)
values (1, 25 * 1024 * 1024, 2, 50 * 1024 * 1024,
        array['application/pdf','image/jpeg','image/png','image/heic'])
on conflict (id) do nothing;

-- NO client grants / policies (born clean). Read path = public.get_upload_policy() (DEFINER, authenticated).
