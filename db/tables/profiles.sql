-- public.profiles — CAPTURED FROM LIVE 2026-07-09. LIVE IS AUTHORITATIVE.
--
-- Was live-only. A mirror of auth.users seeded at signup by the on_auth_user_created trigger
-- (public.handle_new_user — see db/functions/handle_new_user.sql), which copies id/email/full_name
-- from auth.users(+raw_user_meta_data). `profiles.id` = auth.uid() (PK, FK to auth.users, no default
-- — it is supplied by the trigger, never uuid-generated). Authoritative contact/verification/MFA
-- state lives in auth.users; profiles can drift (a Supabase-side email change may not re-trigger).

create table if not exists public.profiles (
  id            uuid        not null,
  email         text        not null,
  full_name     text,
  phone         text,
  date_of_birth date,
  avatar_url    text,
  mfa_enabled   boolean     default false,
  created_at    timestamptz default now(),
  updated_at    timestamptz default now(),
  constraint profiles_pkey primary key (id),
  constraint profiles_email_key unique (email),
  constraint profiles_id_fkey foreign key (id) references auth.users(id) on delete cascade
);
-- (indexes profiles_pkey + profiles_email_key are the constraint-backing unique indexes)

-- RLS: enabled, not forced. Self-scoped policies are DEFENSE-IN-DEPTH — there is NO client-role
-- grant (see db/grants.sql: emails stay RPC-gated), so even self-read is RPC-only in practice
-- (resolve_membership / list_estate_members DEFINER project profile-derived fields). The policies
-- would apply only if a SELECT/INSERT/UPDATE grant were ever added.
alter table public.profiles enable row level security;
drop policy if exists profiles_self_read on public.profiles;
create policy profiles_self_read on public.profiles for select using (id = auth.uid());
drop policy if exists profiles_self_insert on public.profiles;
create policy profiles_self_insert on public.profiles for insert with check (id = auth.uid());
drop policy if exists profiles_self_update on public.profiles;
create policy profiles_self_update on public.profiles for update using (id = auth.uid());

-- Populated by trigger: on_auth_user_created AFTER INSERT ON auth.users -> public.handle_new_user().

-- GRANTS (as intended): NO anon/authenticated/service_role grants — RPC-only. Only postgres (owner).
-- Post-0012 sweep: no TRUNCATE/REFERENCES/TRIGGER/MAINTAIN for the client roles.
