-- 0009 — Notifications store: RECONCILIATION of a PRE-EXISTING, live-only `public.notifications`
-- table that was never in version control (the handle_new_user-class trap: a live DB object invisible
-- in VC). This migration is the VC record of the REAL schema + hardens its access model.
--
-- The live table already had: id, user_id, estate_id, title, body, kind (text), read (boolean),
-- created_at. This ADDS the columns the iOS AppNotification wire needs (channel / action_deep_link /
-- related_document_id / payload) and — CRITICALLY — enables self-scoped RLS + the anti-forge lock
-- (the table had SELECT granted to `authenticated` but its RLS-enabled state was unverifiable through
-- the client; this makes it definitively self-scoped regardless of prior state).
--
-- Non-destructive (add-column-if-not-exists + idempotent policies) — it never drops the table, so any
-- existing rows survive. `kind`/`read` are kept as-is; the endpoint maps category<-kind, isRead<-read.
--
-- IDEMPOTENT: safe to re-apply (add column if not exists, enable RLS is a no-op if on, drop-then-create
-- policies).

-- 1) Columns the iOS wire needs (kept alongside the existing kind/read).
alter table public.notifications add column if not exists channel text not null default 'inApp';
alter table public.notifications add column if not exists action_deep_link text;
alter table public.notifications add column if not exists related_document_id uuid;
alter table public.notifications add column if not exists payload jsonb not null default '{}'::jsonb;

create index if not exists notifications_recipient_idx
  on public.notifications (user_id, created_at desc);

-- 2) ★ SELF-SCOPED RLS + ANTI-FORGE LOCK — the reconciliation's primary job (closes any read hole).
alter table public.notifications enable row level security;

-- SELF-SCOPED READ: a user reads only their own notifications.
drop policy if exists notifications_select_self on public.notifications;
create policy notifications_select_self on public.notifications
  for select to authenticated using (user_id = auth.uid());

-- SELF-SCOPED MARK-READ: a user updates only their own rows (endpoint only flips `read`).
drop policy if exists notifications_update_self on public.notifications;
create policy notifications_update_self on public.notifications
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Privilege lock: SELECT + UPDATE only for `authenticated`; NO INSERT/DELETE grant (curl-confirmed the
-- table already withholds INSERT — this makes it explicit + adds no delete). A client therefore cannot
-- forge or delete a notification; only the SECURITY DEFINER emit_notification (table owner) inserts.
revoke insert, delete on public.notifications from authenticated;
grant select, update on public.notifications to authenticated;
