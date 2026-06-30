-- db/migrations/0006_20260629_mfa_recovery.sql
--
-- Custom MFA recovery codes. Supabase provides NO native recovery codes (the MFA platform
-- guide recommends registering a backup factor instead) — but for an estate-planning account
-- we want SELF-SERVICE one-time recovery so a user who loses their authenticator isn't
-- permanently locked out. The factor REMOVAL on recovery goes through the SUPPORTED admin API
-- (auth.admin.mfa.deleteFactor, which also revokes the user's sessions) from a service-role
-- endpoint — NOT raw surgery on auth.mfa_factors. These tables only hold the recovery-code
-- state + a brute-force guard.
--
-- recovery_codes: bcrypt-hashed, one-time, per-user, self-scoped. Plaintext is returned ONCE
-- by generate_recovery_codes and NEVER stored. Writes are RPC-only (generate / validate+mark);
-- direct read is RLS-self-scoped (only hashes — useless if leaked — for a "N remaining" hint).
-- Recovery is a TWO-step RPC split (validate_recovery_code then mark_recovery_code_used) so the
-- code is only burned AFTER the factor-delete it authorizes succeeds — a deleteFactor failure
-- never strands the user on a dead code.
--
-- mfa_recovery_attempts: per-user brute-force guard on the aal1 recovery path (lock after
-- repeated failures). Defense-in-depth on top of 64-bit codes + bcrypt; written only by the
-- validate_recovery_code RPC, never client-read.
--
-- Idempotent; safe to re-run.

-- =============================================================================
-- recovery_codes
-- =============================================================================
create table if not exists public.recovery_codes (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  code_hash  text not null,                 -- bcrypt hash; the plaintext is NEVER stored
  used_at    timestamptz,                   -- null = available; set once on consume (one-time)
  created_at timestamptz not null default now()
);
create index if not exists recovery_codes_user_unused_idx
  on public.recovery_codes (user_id) where used_at is null;

alter table public.recovery_codes enable row level security;

-- Read OWN only (a "N codes remaining" indicator; exposes only hashes). No insert/update/delete
-- policy → all writes go through the DEFINER RPCs (generate/consume). (CREATE POLICY has no
-- IF NOT EXISTS — guard with a catalog check for idempotency.)
do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'recovery_codes'
      and policyname = 'recovery_codes_select_own'
  ) then
    create policy recovery_codes_select_own on public.recovery_codes
      for select using (user_id = auth.uid());
  end if;
end $$;

grant select on table public.recovery_codes to authenticated;
-- NO insert/update/delete grant — RPC-only (the access_requests pattern, but self-scoped).

-- =============================================================================
-- mfa_recovery_attempts  (per-user brute-force guard for the aal1 consume path)
-- =============================================================================
create table if not exists public.mfa_recovery_attempts (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  failed_count int not null default 0,
  locked_until timestamptz,                  -- non-null + future = locked out
  updated_at   timestamptz not null default now()
);
alter table public.mfa_recovery_attempts enable row level security;
-- No policy, no grant: written ONLY by the validate_recovery_code DEFINER RPC; never client-read.
