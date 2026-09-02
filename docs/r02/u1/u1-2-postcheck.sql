-- U1 · SELECT-ONLY POSTCONDITION.  Run only after a U1 execution attempt.  0 DDL · 0 DML.
with chk(class, check_name, expected, actual, gating) as (values
  ('CONTROL','pg_trigger_readable',$$true$$,(select (count(*)>=0)::text from pg_catalog.pg_trigger),true),
  ('DELTA','exact_binding_count',$$1$$,(select count(*)::text from pg_catalog.pg_trigger tg join pg_catalog.pg_class c on c.oid=tg.tgrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace join pg_catalog.pg_proc p on p.oid=tg.tgfoid join pg_catalog.pg_namespace pn on pn.oid=p.pronamespace where NOT tg.tgisinternal AND n.nspname='auth' AND c.relname='users' AND tg.tgname='on_auth_user_created' AND tg.tgenabled='O' AND pn.nspname='public' AND p.proname='handle_new_user' AND tg.tgnargs=0 AND (tg.tgtype & 66)=0 AND (tg.tgtype & 1)<>0 AND (tg.tgtype & 4)<>0 AND (tg.tgtype & 8)=0 AND (tg.tgtype & 16)=0 AND (tg.tgtype & 32)=0),true),
  ('DELTA','equivalent_binding_total',$$1$$,(select count(*)::text from pg_catalog.pg_trigger tg join pg_catalog.pg_class c on c.oid=tg.tgrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace join pg_catalog.pg_proc p on p.oid=tg.tgfoid join pg_catalog.pg_namespace pn on pn.oid=p.pronamespace where not tg.tgisinternal and n.nspname='auth' and c.relname='users' and pn.nspname='public' and p.proname='handle_new_user'),true),
  ('DELTA','auth_users_triggers_total',$$1$$,(select count(*)::text from pg_catalog.pg_trigger tg join pg_catalog.pg_class c on c.oid=tg.tgrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where not tg.tgisinternal and n.nspname='auth' and c.relname='users'),true),
  ('DELTA','trigger_definition',$$CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION handle_new_user()$$,(select coalesce((select pg_catalog.pg_get_triggerdef(tg.oid) from pg_catalog.pg_trigger tg join pg_catalog.pg_class c on c.oid=tg.tgrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where not tg.tgisinternal and n.nspname='auth' and c.relname='users' and tg.tgname='on_auth_user_created'),'MISSING')),true),
  ('FUNCTION','body_sha256',$$205a0555f463d294c286732bd9bd7be21fe4201f8310eb30a9ffcfa25b4bc456$$,(select coalesce((select encode(sha256(p.prosrc::bytea),'hex') from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='handle_new_user'),'MISSING')),true),
  ('FUNCTION','secdef',$$true$$,(select coalesce((select p.prosecdef::text from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='handle_new_user'),'MISSING')),true),
  ('FUNCTION','owner',$$postgres$$,(select coalesce((select pg_catalog.pg_get_userbyid(p.proowner) from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='handle_new_user'),'MISSING')),true),
  ('UNCHANGED','public_functions',$$147$$,(select count(*)::text from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public'),true),
  ('UNCHANGED','public_ordinary_triggers',$$9$$,(select count(*)::text from pg_catalog.pg_trigger tg join pg_catalog.pg_class c on c.oid=tg.tgrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where not tg.tgisinternal and n.nspname='public'),true),
  ('UNCHANGED','migration_metadata_tables',$$0$$,(select count(*)::text from information_schema.tables where table_schema='supabase_migrations'),true)
)
select class, check_name, expected, actual,
       case when not gating then 'RECORD' when actual is not distinct from expected then 'PASS' else 'FAIL' end as verdict
from chk
union all
select 'OVERALL','u1_postcheck',$$ALL_PASS$$,
  (select case when count(*) filter (where gating and actual is distinct from expected)=0 then 'ALL_PASS' else 'FAIL:'||count(*) filter (where gating and actual is distinct from expected)::text end from chk),
  (select case when count(*) filter (where gating and actual is distinct from expected)=0 then 'U1_APPLIED_AND_VERIFIED' else 'HALT — INVESTIGATE' end from chk);
