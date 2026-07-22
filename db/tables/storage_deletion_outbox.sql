-- public.storage_deletion_outbox — the durable purge queue + per-object purge-status lifecycle (migration 0039).
--
-- The operational deletion lifecycle lives HERE, not on documents. A row is committed IN THE SAME TX as the
-- authorized documents mutation (delete_vault_document / replace_vault_document). Byte deletion is POST-commit:
-- the CLIENT-immediate purge (api purge_document) is the fast path; a Vercel cron drain + the 72h orphan sweeper
-- are the reliability backstops. estate_id is DENORMALIZED so ownership survives the HARD delete of the doc row.
--
-- Born clean: RLS on, NO anon/authenticated grants, no policies. The client path goes through the owner-gated
-- DEFINER RPCs (authorize_purge / record_purge_result, which run as owner); the cron drains via service_role
-- (explicit select+update grant below). Source of truth.

create table if not exists public.storage_deletion_outbox (
  id           uuid        primary key default uuid_generate_v4(),
  estate_id    uuid        not null references public.estates(id) on delete cascade,
  bucket       text        not null default 'documents',
  object_path  text        not null,
  reason       text        not null check (reason in ('document_deleted','document_replaced')),
  requested_by uuid        not null references auth.users(id),
  requested_at timestamptz not null default now(),
  status       text        not null default 'pending' check (status in ('pending','purged','failed')),
  attempts     int         not null default 0,
  last_error   text,
  purged_at    timestamptz
);

create index if not exists storage_deletion_outbox_unpurged_idx
  on public.storage_deletion_outbox (requested_at) where status <> 'purged';

alter table public.storage_deletion_outbox enable row level security;
grant select, update on public.storage_deletion_outbox to service_role;
