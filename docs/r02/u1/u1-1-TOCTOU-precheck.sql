-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- U1 · SELECT-ONLY PRE-EXECUTION GATE (v2 — supersedes cc0df12e…)
--
-- STATUS : PREPARED, NOT EXECUTED.  Target: afterworth-nonprod (qxzeougbaarecaiiqsay).
-- ★ SELECT-ONLY. 0 DDL · 0 DML · 0 GRANT/REVOKE · 0 SET ROLE · 0 transaction mutation.
--
-- ★ WHY v2. v1 gated on `auth_users_triggers_total = 0` and `equivalent_binding_any_name = 0`.
--   That admits only the ABSENT prestate, so U1's ratified RECOGNIZE path was unreachable through
--   its own gate — and worse, v1 returned the IDENTICAL `FAIL:2 / HALT` for EXACT_EQUIVALENT,
--   SAME_NAME_DIFFERENT, EQUIVALENT_DIFFERENT_NAME, DISABLED_EQUIVALENT and MULTIPLE_EQUIVALENT.
--   An operator could not tell a valid prestate from a dangerous one. The migration was correct;
--   the gate was too narrow AND uninformative.
--
--   v2 reproduces the migration's eight-state classifier exactly and reports a DISPOSITION:
--     ABSENT            → ELIGIBLE_CREATE
--     EXACT_EQUIVALENT  → ELIGIBLE_RECOGNIZE
--     everything else   → HALT
--
-- ★ THIS IS ADVISORY, NOT A TOCTOU GUARANTEE. It runs before the migration, outside its
--   transaction. The migration re-classifies transactionally and is the only authority; a
--   conflicting change between the two causes the migration to HALT and roll back.
-- ════════════════════════════════════════════════════════════════════════════════════════════════
with fnok as (
  select count(*) = 1 as ok
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    join pg_catalog.pg_language l on l.oid = p.prolang
   where n.nspname = 'public' and p.proname = 'handle_new_user'
     and pg_catalog.format_type(p.prorettype, null) = 'trigger'
     and l.lanname = 'plpgsql' and p.prosecdef and p.provolatile = 'v'
     and pg_catalog.pg_get_userbyid(p.proowner) = 'postgres'
     and p.proconfig @> array['search_path=public']
     and pg_catalog.pg_get_function_identity_arguments(p.oid) = ''
     and encode(sha256(p.prosrc::bytea),'hex')
         = '205a0555f463d294c286732bd9bd7be21fe4201f8310eb30a9ffcfa25b4bc456'
), t as (
  select tg.tgname, tg.tgenabled::text en, tg.tgtype, tg.tgnargs, pn.nspname fs, p.proname fn
    from pg_catalog.pg_trigger tg
    join pg_catalog.pg_class c on c.oid = tg.tgrelid
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    join pg_catalog.pg_proc p on p.oid = tg.tgfoid
    join pg_catalog.pg_namespace pn on pn.oid = p.pronamespace
   where not tg.tgisinternal and n.nspname = 'auth' and c.relname = 'users'
), s as (
  select *, (fs='public' and fn='handle_new_user' and tgnargs=0
             and (tgtype & 66)=0 and (tgtype & 1)<>0 and (tgtype & 4)<>0
             and (tgtype & 8)=0 and (tgtype & 16)=0 and (tgtype & 32)=0) sem
    from t
), st as (
  select case
    when (select count(*) from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace
           where n.nspname='auth' and c.relname='users') <> 1 then 'INSTRUMENT_BROKEN'
    when not (select ok from fnok)                                            then 'FUNCTION_CONTRACT_MISMATCH'
    when (select count(*) from s where sem) > 1                               then 'MULTIPLE_EQUIVALENT'
    when (select count(*) from s where sem and en <> 'O') > 0                 then 'DISABLED_EQUIVALENT'
    when (select count(*) from s where tgname='on_auth_user_created' and not sem) > 0
                                                                              then 'SAME_NAME_DIFFERENT'
    when (select count(*) from s where sem and en='O' and tgname<>'on_auth_user_created') > 0
                                                                              then 'EQUIVALENT_DIFFERENT_NAME'
    when (select count(*) from s where sem and en='O' and tgname='on_auth_user_created') = 1
                                                                              then 'EXACT_EQUIVALENT'
    else 'ABSENT' end as state
), chk(class, check_name, expected, actual, gating) as (values
  ('CONTROL','pg_trigger_readable',$$true$$,(select (count(*)>=0)::text from pg_catalog.pg_trigger),true),
  ('CONTROL','auth_users_visible',$$1$$,(select count(*)::text from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='auth' and c.relname='users'),true),
  ('IDENTITY','current_user',$$postgres$$,current_user::text,true),
  ('PIN','target_project_ref',$$qxzeougbaarecaiiqsay$$,$$qxzeougbaarecaiiqsay$$,true),
  ('FUNCTION','contract_complete',$$true$$,(select ok::text from fnok),true),
  ('FUNCTION','body_sha256',$$205a0555f463d294c286732bd9bd7be21fe4201f8310eb30a9ffcfa25b4bc456$$,(select coalesce((select encode(sha256(p.prosrc::bytea),'hex') from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='handle_new_user'),'MISSING')),true),
  -- ★ THE GATE: exactly the two prestates the migration accepts. Never collapses them.
  ('PRESTATE','trigger_state_eligible',$$true$$,(select (state in ('ABSENT','EXACT_EQUIVALENT'))::text from st),true),
  ('PRESTATE','trigger_state',$$__RECORD__$$,(select state from st),false),
  ('PRESTATE','expected_migration_action',$$__RECORD__$$,(select case state when 'ABSENT' then 'CREATE' when 'EXACT_EQUIVALENT' then 'RECOGNIZE' else 'NONE — HALT' end from st),false),
  ('PRESTATE','auth_users_trigger_inventory',$$__RECORD__$$,(select coalesce(string_agg(tgname||':'||en||':'||tgtype::text,',' order by tgname),'(none)') from s),false),
  ('METADATA','migration_metadata_tables',$$0$$,(select count(*)::text from information_schema.tables where table_schema='supabase_migrations'),true)
)
select class, check_name, expected, actual,
       case when not gating then 'RECORD' when actual is not distinct from expected then 'PASS' else 'FAIL' end as verdict
from chk
union all
select 'OVERALL','u1_precheck',$$PASS$$,
  (select case when count(*) filter (where gating and actual is distinct from expected)=0 then 'PASS'
               else 'FAIL:'||count(*) filter (where gating and actual is distinct from expected)::text end from chk),
  (select case
     when (select count(*) from chk where gating and actual is distinct from expected) > 0
       then 'HALT — state='||(select state from st)
     when (select state from st) = 'ABSENT'           then 'ELIGIBLE_CREATE — pending explicit authorization'
     when (select state from st) = 'EXACT_EQUIVALENT' then 'ELIGIBLE_RECOGNIZE — pending explicit authorization'
     else 'HALT' end);
