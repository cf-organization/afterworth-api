-- R02_7 · HOSTED POST-0063 END-STATE VERIFIER.  PREPARED, NOT EXECUTED.
-- Target: afterworth-nonprod (qxzeougbaarecaiiqsay).
-- SELECT-only: 0 DDL · 0 DML · 0 GRANT/REVOKE · 0 LOCK · 0 SET ROLE · 0 transaction control · 0 DO.
--
-- ★ Proves hosted nonprod matches the canonical PATH A final application state. Project identity is
--   a RECORD/operator pin — a Supabase project ref has no in-database source and this row cannot
--   fail. OPERATOR_PROJECT_IDENTITY_CONFIRMATION_REQUIRED = true: confirm the project in the
--   dashboard before running.
-- ★ Every expected-empty family is paired with a positive control, so a zero cannot be the sound of
--   a blind instrument. Platform-owned state is RECORDED, never gated. No raw relacl equality.
with pin(k,v) as (values
  ('target_project_ref','qxzeougbaarecaiiqsay'),
  ('operator_project_identity_confirmation_required','true — confirm in dashboard; not verifiable in SQL'),
  ('canonical_authority','PATH A final = bootstrap@0060 + 0061 + 0062 + 0063')),
ctl(check_name, expected, actual) as (values
  ('ctl_table_probe','1',(select count(*)::text from information_schema.tables where table_schema='public' and table_name='assets')),
  ('ctl_function_probe','1',(select count(*)::text from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='handle_new_user')),
  ('ctl_policy_probe','1',(select count(*)::text from pg_catalog.pg_policies where schemaname='public' and policyname='assets_read')),
  ('ctl_trigger_probe','1',(select count(*)::text from pg_catalog.pg_trigger t join pg_catalog.pg_class c on c.oid=t.tgrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='auth' and c.relname='users' and t.tgname='on_auth_user_created')),
  ('ctl_privilege_decoder_probe','true',(select has_table_privilege('authenticated','public.estate_assets','SELECT')::text)),
  ('gate_tables_ordinary','41',(select count(*)::text from information_schema.tables where table_schema='public' and table_type='BASE TABLE')),
  ('gate_table_set_fingerprint','0009141a4788e0e4adf17a3209bab24c',(select md5(string_agg(table_name,',' order by table_name)) from information_schema.tables where table_schema='public' and table_type='BASE TABLE')),
  ('gate_non_postgres_owned','0',(select count(*)::text from pg_catalog.pg_tables where schemaname='public' and tableowner<>'postgres')),
  ('gate_columns','415',(select count(*)::text from information_schema.columns where table_schema='public')),
  ('gate_functions','147',(select count(*)::text from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public')),
  ('gate_policies','38',(select count(*)::text from pg_catalog.pg_policies where schemaname='public')),
  ('gate_storage_policies','2',(select count(*)::text from pg_catalog.pg_policies where schemaname='storage')),
  ('gate_rls_enabled','41',(select count(*)::text from pg_catalog.pg_tables where schemaname='public' and rowsecurity)),
  ('gate_u1_trigger','CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION handle_new_user()',(select pg_catalog.pg_get_triggerdef(t.oid) from pg_catalog.pg_trigger t join pg_catalog.pg_class c on c.oid=t.tgrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='auth' and c.relname='users' and t.tgname='on_auth_user_created')),
  ('gate_u1_trigger_enabled','O',(select t.tgenabled::text from pg_catalog.pg_trigger t join pg_catalog.pg_class c on c.oid=t.tgrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='auth' and c.relname='users' and t.tgname='on_auth_user_created')),
  ('gate_u2_assets_policy_count','4',(select count(*)::text from pg_catalog.pg_policies where schemaname='public' and tablename='assets')),
  ('gate_u2_assets_fingerprint','f3b3f92058a4be2945de72be3800e32f',(select md5(string_agg(pol.polname||'|'||pol.polcmd::text||'|'||pol.polpermissive::text||'|'||(case when pol.polroles='{0}'::oid[] then 'PUBLIC' else 'SCOPED' end)||'|'||coalesce(pg_catalog.pg_get_expr(pol.polqual,pol.polrelid),'~')||'|'||coalesce(pg_catalog.pg_get_expr(pol.polwithcheck,pol.polrelid),'~'),',' order by pol.polname)) from pg_catalog.pg_policy pol join pg_catalog.pg_class c on c.oid=pol.polrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='assets')),
  ('gate_u3_client_dxtm','0',(select count(*)::text from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace, aclexplode(c.relacl) a where n.nspname='public' and c.relkind='r' and pg_catalog.pg_get_userbyid(a.grantee) in ('anon','authenticated','service_role') and a.privilege_type in ('TRUNCATE','REFERENCES','TRIGGER','MAINTAIN'))),
  ('gate_u3_creator_default_dxtm','0',(select count(*)::text from pg_catalog.pg_default_acl d, aclexplode(d.defaclacl) a where d.defaclobjtype='r' and pg_catalog.pg_get_userbyid(d.defaclrole)='postgres' and d.defaclnamespace='public'::regnamespace::oid and pg_catalog.pg_get_userbyid(a.grantee) in ('anon','authenticated','service_role') and a.privilege_type in ('TRUNCATE','REFERENCES','TRIGGER','MAINTAIN'))),
  ('gate_u3_global_default_dxtm','0',(select count(*)::text from pg_catalog.pg_default_acl d, aclexplode(d.defaclacl) a where d.defaclobjtype='r' and pg_catalog.pg_get_userbyid(d.defaclrole)='postgres' and d.defaclnamespace=0 and pg_catalog.pg_get_userbyid(a.grantee) in ('anon','authenticated','service_role') and a.privilege_type in ('TRUNCATE','REFERENCES','TRIGGER','MAINTAIN'))),
  ('gate_row_dml_grant_rows','21',(select count(*)::text from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace, aclexplode(c.relacl) a where n.nspname='public' and c.relkind='r' and pg_catalog.pg_get_userbyid(a.grantee) in ('anon','authenticated','service_role') and a.privilege_type in ('SELECT','INSERT','UPDATE','DELETE'))),
  ('gate_row_dml_fingerprint','052198590dd92ba70ab07c99cbd21f15',(select md5(string_agg(c.relname||'|'||pg_catalog.pg_get_userbyid(a.grantee)||'|'||a.privilege_type,',' order by c.relname||'|'||pg_catalog.pg_get_userbyid(a.grantee)||'|'||a.privilege_type)) from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace, aclexplode(c.relacl) a where n.nspname='public' and c.relkind='r' and pg_catalog.pg_get_userbyid(a.grantee) in ('anon','authenticated','service_role') and a.privilege_type in ('SELECT','INSERT','UPDATE','DELETE'))),
  ('gate_migration_metadata_tables','0',(select count(*)::text from information_schema.tables where table_schema='supabase_migrations'))
), plat(check_name, recorded) as (values
  ('platform_default_acl_grantors',(select coalesce(string_agg(distinct pg_catalog.pg_get_userbyid(d.defaclrole),', '),'(none)') from pg_catalog.pg_default_acl d where pg_catalog.pg_get_userbyid(d.defaclrole)<>'postgres')),
  ('platform_all_extensions',(select string_agg(extname,', ' order by extname) from pg_catalog.pg_extension)),
  ('platform_event_triggers',(select coalesce(string_agg(evtname||':'||pg_catalog.pg_get_userbyid(evtowner),', ' order by evtname),'(none)') from pg_catalog.pg_event_trigger))
)
select 'PIN' as class, k as check_name, '__RECORD__' as expected, v as actual, 'RECORD' as verdict from pin
union all
select case when check_name like 'ctl_%' then 'CONTROL' else 'GATE' end, check_name, expected, actual,
       case when actual is not distinct from expected then 'PASS' else 'FAIL' end from ctl
union all
select 'PLATFORM', check_name, '__RECORD__', recorded, 'RECORD' from plat
union all
select 'OVERALL','r02_7_hosted_post0063','ALL_PASS',
  (select case when count(*) filter (where actual is distinct from expected)=0 then 'ALL_PASS' else 'FAIL:'||count(*) filter (where actual is distinct from expected)::text end from ctl),
  (select case when count(*) filter (where actual is distinct from expected)=0 then 'HOSTED_POST0063_MATCHES_CANONICAL' else 'HALT — INVESTIGATE' end from ctl);
