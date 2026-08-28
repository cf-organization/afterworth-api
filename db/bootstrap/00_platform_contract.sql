-- ════════════════════════════════════════════════════════════════════════════════════════════
-- MODEL C CANONICAL BOOTSTRAP · 00 · platform contract / prerequisites
--
-- ★ THIS FILE CREATES NOTHING. It REFUSES if the Supabase-owned surface the application depends on
--   is absent. A bootstrap that silently proceeded without auth.users would build a schema whose
--   38 foreign keys and 131 SECURITY DEFINER functions reference a role system that does not
--   exist — and it would look like it worked.
--
-- ★ auth.users, storage.objects, storage.buckets and the anon/authenticated/service_role roles are
--   SUPABASE-PLATFORM-OWNED. They are never created here. A local test shim may create stand-ins,
--   but it lives in test infrastructure and is unmistakably non-production.
-- ════════════════════════════════════════════════════════════════════════════════════════════

do $contract$
declare
  missing text[] := array[]::text[];
begin
  if to_regclass('auth.users') is null then missing := missing || 'table auth.users'; end if;
  if to_regclass('storage.objects') is null then missing := missing || 'table storage.objects'; end if;
  if to_regclass('storage.buckets') is null then missing := missing || 'table storage.buckets'; end if;
  if to_regprocedure('auth.uid()') is null then missing := missing || 'function auth.uid()'; end if;
  if to_regprocedure('auth.jwt()') is null then missing := missing || 'function auth.jwt()'; end if;
  if not exists (select 1 from pg_roles where rolname = 'anon') then missing := missing || 'role anon'; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then missing := missing || 'role authenticated'; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then missing := missing || 'role service_role'; end if;
  -- * The 'extensions' SCHEMA is the prerequisite, not the extensions themselves. pgcrypto and
  --   uuid-ossp are created by phase 10 because the authoritative dump emits CREATE EXTENSION for
  --   them — they are application-installed. An earlier draft of this contract demanded both as
  --   prerequisites AND created them one phase later, which would have refused on every virgin
  --   database. The first fresh run would have caught it; writing the check correctly is better.
  if to_regnamespace('extensions') is null then missing := missing || 'schema extensions'; end if;

  if array_length(missing, 1) > 0 then
    raise exception 'MODEL C BOOTSTRAP REFUSED — required Supabase platform prerequisites are absent: %',
      array_to_string(missing, ', ')
      using hint = 'This bootstrap creates application objects only. Provision the Supabase platform surface first.';
  end if;
end
$contract$;

-- Platform-supplied extensions, recorded as prerequisites and NOT created here.
-- (pg_stat_statements and supabase_vault are installed by Supabase; creating them is not
--  application DDL and may fail or succeed differently depending on role.)
--   CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";
--   CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";
