-- db/migrations/0007_20260630_connections.sql
--
-- Account aggregation — provider-agnostic schema (sandbox slice). Wires a live aggregator
-- (Plaid in the dev/sandbox build) behind the existing NormalizedAssetRecord model. The
-- provider is a TAG (`provider`), NOT baked into the schema — MX/Finicity is a new adapter, not
-- a migration. NOTHING Plaid-shaped lands here: only normalized records + a provider tag + an
-- opaque, server-only access token. See lib/plaid.ts (the only Plaid-aware backend module) +
-- the build recon.
--
-- TOKEN CONTAINMENT (the load-bearing security split):
--   connections        — OWNER-readable metadata + the reference_token HANDLE. NO access_token.
--   connection_secrets — the access_token. NO grants at all → the client literally cannot SELECT
--                        it; only the DEFINER RPCs (create_connection / get_connection_access_token)
--                        touch it, server-side. The recovery-codes pattern (grant-less + DEFINER).
--   normalized_assets  — the fetched balances/holdings (NormalizedAssetRecord). OWNER-readable
--                        (raw balances are NOT member-readable — beneficiary/professional disclosure
--                        is a later redaction-layer slice, like documents; never a blanket SELECT).
--
-- SANDBOX NOTE: these tables do NOT carry the aal2 gate yet (fake data). The real-institution
-- flip ADDS `and (auth.jwt() ->> 'aal') = 'aal2'` to the financial-table policies — a POLICY
-- tightening, not a restructure. Estate-scoped RLS is built now; the aal2 clause lands later.
--
-- Idempotent; safe to re-run.

-- =============================================================================
-- connections  (client-readable metadata; NO access_token)
-- =============================================================================
create table if not exists public.connections (
  id               uuid primary key default gen_random_uuid(),
  estate_id        uuid not null references public.estates(id) on delete cascade,
  provider         text not null,                       -- 'plaid' (the swap-later tag)
  institution_id   text,                                -- provider's institution id (opaque)
  institution_name text,
  reference_token  text not null,                       -- the CLIENT HANDLE (ProviderCredentialReference.referenceToken); NOT the access_token
  status           text not null default 'active',      -- active | error | disconnected
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index if not exists connections_estate_idx on public.connections (estate_id);

alter table public.connections enable row level security;
-- Read: estate OWNER ONLY, via the is_estate_owner DEFINER helper. An inline estate_memberships
-- subquery here would FAIL (authenticated has no SELECT grant on estate_memberships — the policy
-- subquery runs as the invoker). A blanket member-read is also deliberately avoided: connection
-- metadata must not reach a beneficiary/professional un-redacted (tiered-disclosure invariant), the
-- same tightening 0002 made to documents_read (off is_estate_member). Re-runnable: drop-then-create.
drop policy if exists connections_select_members on public.connections;
drop policy if exists connections_select_owner on public.connections;
create policy connections_select_owner on public.connections
  for select using (public.is_estate_owner(estate_id));
grant select on table public.connections to authenticated;
-- NO insert/update/delete grant — writes go through create_connection (DEFINER, owner-gated).

-- =============================================================================
-- connection_secrets  (the access_token — SERVER-ONLY, NO grants)
-- =============================================================================
create table if not exists public.connection_secrets (
  connection_id uuid primary key references public.connections(id) on delete cascade,
  provider      text not null,
  access_token  text not null,                          -- the provider access_token (sensitive)
  created_at    timestamptz not null default now()
);
alter table public.connection_secrets enable row level security;
-- NO policy, NO grant: only the DEFINER RPCs (create_connection / get_connection_access_token)
-- ever read or write this. The client cannot SELECT it (no grant) and RLS denies all (no policy).

-- =============================================================================
-- normalized_assets  (NormalizedAssetRecord — client-readable balances/holdings)
-- =============================================================================
create table if not exists public.normalized_assets (
  id                  uuid primary key default gen_random_uuid(),
  estate_id           uuid not null references public.estates(id) on delete cascade,
  connection_id       uuid not null references public.connections(id) on delete cascade,
  institution_name    text,
  provider_name       text,
  asset_group         text not null,                    -- cashBank | investmentBrokerage | retirement | ...
  asset_category      text,
  asset_subtype       text,
  source_type         text not null default 'aggregator',
  masked_identifier   text,
  balance_cents       bigint not null default 0,
  currency            text not null default 'USD',
  holdings            jsonb not null default '[]'::jsonb,
  refresh_timestamp   timestamptz,
  last_sync_status    text not null default 'live_connected',
  confidence_level    text not null default 'high',
  verification_status text not null default 'verified',
  created_at          timestamptz not null default now()
);
create index if not exists normalized_assets_estate_idx on public.normalized_assets (estate_id);
create index if not exists normalized_assets_connection_idx on public.normalized_assets (connection_id);

alter table public.normalized_assets enable row level security;
-- Read + write: estate OWNER ONLY — ONE `for all` policy via the is_estate_owner DEFINER helper.
-- (Same reasons as connections: estate_memberships has no authenticated grant for an inline
-- subquery, AND raw balances must not reach a beneficiary un-redacted.) refresh does delete+insert
-- as the owner; list selects as the owner. Beneficiary/professional asset disclosure = a later
-- redaction-layer slice. Re-runnable: drop-then-create (also drops the old member/write policies).
drop policy if exists normalized_assets_select_members on public.normalized_assets;
drop policy if exists normalized_assets_write_owner on public.normalized_assets;
drop policy if exists normalized_assets_owner_all on public.normalized_assets;
create policy normalized_assets_owner_all on public.normalized_assets
  for all using (public.is_estate_owner(estate_id)) with check (public.is_estate_owner(estate_id));
grant select, insert, delete on table public.normalized_assets to authenticated;
