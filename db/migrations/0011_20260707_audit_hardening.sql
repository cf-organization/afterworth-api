-- 0011_20260707_audit_hardening — audit-log hardening + live-only DDL capture.
--
-- CONTEXT: public.audit_logs was a LIVE-ONLY table (no CREATE TABLE in VC — the handle_new_user
-- live-only-object class). This migration (a) CAPTURES its baseline into VC (idempotent), and (b) closes
-- two live holes + adds a provenance column for the incoming client audit-forward pipe
-- (forward_client_audit, next commit). Idempotent; source of truth for the audit_logs baseline.
--
-- LIVE HOLES CLOSED (both confirmed on 2026-07-07 via has_function_privilege + role_table_grants):
--   1) FORGERY — `authenticated` had EXECUTE on write_audit (a SECURITY DEFINER RPC), so a client could
--      call it DIRECTLY via PostgREST and forge ANY audit row. actor_id is pinned to auth.uid() (WHO can't
--      be spoofed), but action/estate/target/meta are caller-controlled → a forged 'access_grant.revoked'
--      etc. would pollute the authorization trail. Revoked from PUBLIC (Postgres DEFAULT-grants EXECUTE to
--      PUBLIC — the load-bearing revoke), anon, authenticated. Server RPCs are UNAFFECTED: they are
--      SECURITY DEFINER owned by postgres and call write_audit AS postgres (the owner), not the request role.
--   2) DATA-LOSS — `authenticated`/`anon` had TRUNCATE on audit_logs (a Supabase default-grant leftover);
--      RLS does NOT gate TRUNCATE → a client could wipe the log. Revoked (+ REFERENCES/TRIGGER).
--
-- PROVENANCE: new `source` column (DEFAULT 'server', CHECK in ('server','ios_forward')) so client-forwarded
-- rows (stamped 'ios_forward' INSIDE forward_client_audit) are distinguishable from trusted server-RPC rows.
-- No client-settable source anywhere (never a parameter; the RPC stamps it).

begin;

-- ---- (a) baseline capture (idempotent) — documents the live-only table in VC ----
create table if not exists public.audit_logs (
  id            bigserial primary key,
  actor_id      uuid references auth.users(id),
  estate_id     uuid,
  action        text not null,
  target_table  text,
  target_id     uuid,
  ip            inet,
  user_agent    text,
  metadata      jsonb default '{}'::jsonb,
  created_at    timestamptz default now()
);
create index if not exists audit_logs_estate_id_created_at_idx on public.audit_logs (estate_id, created_at desc);
create index if not exists audit_logs_actor_id_created_at_idx on public.audit_logs (actor_id, created_at desc);
alter table public.audit_logs enable row level security;
-- self-read only: a user sees their own audit rows, never others'.
drop policy if exists audit_read_own on public.audit_logs;
create policy audit_read_own on public.audit_logs for select using (actor_id = auth.uid());

-- ---- (b) hardening ----
-- provenance (the NOT NULL default backfills all existing rows to 'server').
alter table public.audit_logs add column if not exists source text not null default 'server';
alter table public.audit_logs drop constraint if exists audit_logs_source_check;
alter table public.audit_logs add constraint audit_logs_source_check check (source in ('server', 'ios_forward'));

-- close the FORGERY hole (PUBLIC is load-bearing — Postgres default-grants EXECUTE to PUBLIC).
revoke execute on function public.write_audit(text, text, uuid, uuid, jsonb) from public, anon, authenticated;

-- close the DATA-LOSS hole (RLS does not gate TRUNCATE).
revoke truncate, references, trigger on table public.audit_logs from anon, authenticated;

commit;
