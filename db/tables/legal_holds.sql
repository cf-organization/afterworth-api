-- public.legal_holds — append-only litigation-hold source (migration 0039). "Active" = released_at IS NULL.
--
-- Blocks permanent deletion + replace of a document while any active hold exists (delete_vault_document /
-- replace_vault_document raise 'blocked_legal_hold'). Placed/released via ADMIN-gated RPCs only (the document
-- owner must NOT be able to lift a hold against their own estate). ON DELETE CASCADE: when a doc is legitimately
-- deleted (the delete RPC guarantees NO active hold), its released-hold history goes with it (deletion audited).
--
-- Born clean: RLS on, no client grants, no policies. Writes are DEFINER-RPC-only (place/release_legal_hold).
-- Append-only in normal operation (no client DELETE; release is a one-time released_at set). Source of truth.

create table if not exists public.legal_holds (
  id          uuid        primary key default uuid_generate_v4(),
  doc_id      uuid        not null references public.documents(id) on delete cascade,
  reason      text        not null,
  placed_by   uuid        not null references auth.users(id),
  placed_at   timestamptz not null default now(),
  released_at timestamptz,
  released_by uuid        references auth.users(id)
);

create index if not exists legal_holds_active_idx on public.legal_holds (doc_id) where released_at is null;

alter table public.legal_holds enable row level security;
