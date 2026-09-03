-- R02_7 · HOSTED POST-0063 END-STATE VERIFIER — V2.  PREPARED, NOT EXECUTED.
-- Target: afterworth-nonprod (qxzeougbaarecaiiqsay).
-- SELECT-only: 0 DDL · 0 DML · 0 GRANT/REVOKE · 0 LOCK · 0 SET ROLE · 0 transaction control · 0 DO.
--
-- ★ WHY V2 EXISTS. V1 (sha 92423f2c…01fb) was executed hosted, read-only, and every gate it
--   implemented PASSed — but it gated only 12 of the 24 required application dimensions, and four
--   of those twelve by count alone. Its OVERALL row read ALL_PASS throughout. That is precisely why
--   coverage must be read from gate definitions and never inferred from an OVERALL verdict.
--   V1 is NOT edited: it is the artifact that was executed, and its bytes are its identity.
--
-- ★ V2 gates all 24 dimensions, replaces the four count-only gates with semantic fingerprints, and
--   pairs every expected-empty family with a live positive control. Expectations are the canonical
--   PATH_A_FINAL values proven by R02_7 primary + independent equivalence; the SQL below is its own
--   implementation and neither includes nor invokes the primary comparator or the local verifier.
--
-- ★ Normalization: no OIDs, no raw relacl, no relfilenode, no timestamps, no physical order. Every
--   string_agg carries ORDER BY. ACLs decoded via aclexplode. Row-DML kept separate from Dxtm.
--   MAINTAIN is only queried on PG17+.
with pin(k,v) as (values
  ('target_project_ref','qxzeougbaarecaiiqsay'),
  ('operator_project_identity_confirmation_required','true — confirm in dashboard; not verifiable in SQL'),
  ('canonical_authority','PATH A final = bootstrap@0060 + 0061 + 0062 + 0063'),
  ('supersedes','V1 sha 92423f2c27f92fe8eecd0e118979bd073624b80b5217a9c8f972130cad2d01fb (executed, partial coverage)')),
ctl(check_name, expected, actual) as (values
  ('ctl_table_probe','1',(select count(*)::text from information_schema.tables where table_schema='public' and table_name='assets')),
  ('ctl_column_probe','1',(select count(*)::text from information_schema.columns where table_schema='public' and table_name='assets' and column_name='estate_id')),
  ('ctl_constraint_probe','true',(select (count(*)>0)::text from pg_catalog.pg_constraint con join pg_catalog.pg_class c on c.oid=con.conrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='assets' and con.contype='p')),
  ('ctl_index_probe','true',(select (count(*)>0)::text from pg_catalog.pg_indexes where schemaname='public' and indexname='invitations_email_idx')),
  ('ctl_function_probe','1',(select count(*)::text from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='handle_new_user')),
  ('ctl_policy_probe','1',(select count(*)::text from pg_catalog.pg_policies where schemaname='public' and policyname='assets_read')),
  ('ctl_public_trigger_probe','true',(select (count(*)>0)::text from pg_catalog.pg_trigger t join pg_catalog.pg_class c on c.oid=t.tgrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and not t.tgisinternal)),
  ('ctl_auth_trigger_probe','1',(select count(*)::text from pg_catalog.pg_trigger t join pg_catalog.pg_class c on c.oid=t.tgrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='auth' and c.relname='users' and t.tgname='on_auth_user_created')),
  ('ctl_rls_probe','true',(select (count(*)>0)::text from pg_catalog.pg_tables where schemaname='public' and rowsecurity)),
  ('ctl_sequence_probe','true',(select (count(*)>0)::text from pg_catalog.pg_sequence)),
  ('ctl_enum_probe','true',(select (count(*)>0)::text from pg_catalog.pg_enum)),
  ('ctl_publication_catalog_probe','true',(select (count(*)>0)::text from pg_catalog.pg_publication)),
  ('ctl_event_trigger_probe','true',(select (count(*)>0)::text from pg_catalog.pg_event_trigger)),
  ('ctl_privilege_decoder_probe','true',(select has_table_privilege('authenticated','public.estate_assets','SELECT')::text)),
  ('gate_tables_ordinary','41',(select count(*)::text from information_schema.tables where table_schema='public' and table_type='BASE TABLE')),
  ('gate_table_set_fingerprint','0009141a4788e0e4adf17a3209bab24c',(select md5(string_agg(table_name,',' order by table_name)) from information_schema.tables where table_schema='public' and table_type='BASE TABLE')),
  ('gate_non_postgres_owned','0',(select count(*)::text from pg_catalog.pg_tables where schemaname='public' and tableowner<>'postgres')),
  ('gate_columns','415',(select count(*)::text from information_schema.columns where table_schema='public')),
  ('gate_columns_fingerprint','4b5b967fcbb085db5e7ae4fd20a07653',(select md5(string_agg(x,',' order by x)) from (select table_name||'.'||column_name||':'||data_type||':'||is_nullable||':'||coalesce(column_default,'-') x from information_schema.columns where table_schema='public') s)),
  ('gate_primary_keys','41',(select count(*)::text from pg_catalog.pg_constraint con join pg_catalog.pg_class rel on rel.oid=con.conrelid join pg_catalog.pg_namespace n on n.oid=rel.relnamespace where n.nspname='public' and con.contype='p')),
  ('gate_primary_keys_fingerprint','c7f0c62b328110e7517168e5826ac94c',(select md5(string_agg(x,',' order by x)) from (select rel.relname||':'||pg_catalog.pg_get_constraintdef(con.oid) x from pg_catalog.pg_constraint con join pg_catalog.pg_class rel on rel.oid=con.conrelid join pg_catalog.pg_namespace n on n.oid=rel.relnamespace where n.nspname='public' and con.contype='p') s)),
  ('gate_unique_constraints','2',(select count(*)::text from pg_catalog.pg_constraint con join pg_catalog.pg_class rel on rel.oid=con.conrelid join pg_catalog.pg_namespace n on n.oid=rel.relnamespace where n.nspname='public' and con.contype='u')),
  ('gate_unique_constraints_fingerprint','37a1de0e788ef698678f9f0fe5c9f0e0',(select md5(string_agg(x,',' order by x)) from (select rel.relname||':'||pg_catalog.pg_get_constraintdef(con.oid) x from pg_catalog.pg_constraint con join pg_catalog.pg_class rel on rel.oid=con.conrelid join pg_catalog.pg_namespace n on n.oid=rel.relnamespace where n.nspname='public' and con.contype='u') s)),
  ('gate_foreign_keys','83',(select count(*)::text from pg_catalog.pg_constraint con join pg_catalog.pg_class rel on rel.oid=con.conrelid join pg_catalog.pg_namespace n on n.oid=rel.relnamespace where n.nspname='public' and con.contype='f')),
  ('gate_foreign_keys_fingerprint','00c7ea37956641577fdcb38408e2fd69',(select md5(string_agg(x,',' order by x)) from (select rel.relname||':'||con.conname||':'||pg_catalog.pg_get_constraintdef(con.oid)||':'||con.confmatchtype::text||':'||con.confupdtype::text||':'||con.confdeltype::text||':'||con.condeferrable::text||':'||con.condeferred::text x from pg_catalog.pg_constraint con join pg_catalog.pg_class rel on rel.oid=con.conrelid join pg_catalog.pg_namespace n on n.oid=rel.relnamespace where n.nspname='public' and con.contype='f') s)),
  ('gate_check_constraints','50',(select count(*)::text from pg_catalog.pg_constraint con join pg_catalog.pg_class rel on rel.oid=con.conrelid join pg_catalog.pg_namespace n on n.oid=rel.relnamespace where n.nspname='public' and con.contype='c')),
  ('gate_check_constraints_fingerprint','e2a4c681a35f3387dd428d2987b1e504',(select md5(string_agg(x,',' order by x)) from (select rel.relname||':'||con.conname||':'||pg_catalog.pg_get_constraintdef(con.oid) x from pg_catalog.pg_constraint con join pg_catalog.pg_class rel on rel.oid=con.conrelid join pg_catalog.pg_namespace n on n.oid=rel.relnamespace where n.nspname='public' and con.contype='c') s)),
  ('gate_indexes','59',(select count(*)::text from pg_catalog.pg_index ix join pg_catalog.pg_class t on t.oid=ix.indrelid join pg_catalog.pg_namespace n on n.oid=t.relnamespace where n.nspname='public' and not exists (select 1 from pg_catalog.pg_constraint k where k.conindid=ix.indexrelid))),
  ('gate_indexes_fingerprint','2040f7b04a2f978241b468c7e3c799f6',(select md5(string_agg(x,',' order by x)) from (select t.relname||':'||i.relname||':'||ix.indisunique::text||':'||am.amname||':'||pg_catalog.pg_get_indexdef(ix.indexrelid)||':'||coalesce(pg_catalog.pg_get_expr(ix.indpred,ix.indrelid),'-') x from pg_catalog.pg_index ix join pg_catalog.pg_class i on i.oid=ix.indexrelid join pg_catalog.pg_class t on t.oid=ix.indrelid join pg_catalog.pg_namespace n on n.oid=t.relnamespace join pg_catalog.pg_am am on am.oid=i.relam where n.nspname='public' and not exists (select 1 from pg_catalog.pg_constraint k where k.conindid=ix.indexrelid)) s)),
  ('gate_functions','147',(select count(*)::text from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public')),
  ('gate_functions_fingerprint','db417ca88588541b8a4abd481a075cf8',(select md5(string_agg(x,',' order by x)) from (select p.proname||'('||pg_catalog.pg_get_function_identity_arguments(p.oid)||'):'||p.prosecdef::text||':'||coalesce(array_to_string(p.proconfig,';'),'-')||':'||md5(p.prosrc) x from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public') s)),
  ('gate_policies','38',(select count(*)::text from pg_catalog.pg_policies where schemaname='public')),
  ('gate_policies_fingerprint','14fe356da52e494ada68c00cec7db575',(select md5(string_agg(x,',' order by x)) from (select tablename||'.'||policyname||':'||cmd||':'||permissive||':'||array_to_string(roles,'+')||':'||coalesce(qual,'-')||':'||coalesce(with_check,'-') x from pg_catalog.pg_policies where schemaname='public') s)),
  ('gate_triggers_public','9',(select count(*)::text from pg_catalog.pg_trigger t join pg_catalog.pg_class c on c.oid=t.tgrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and not t.tgisinternal)),
  ('gate_triggers_public_fingerprint','a395dc2bf1c9340a36371ec2d748c449',(select md5(string_agg(x,',' order by x)) from (select c.relname||':'||t.tgname||':'||t.tgtype::text||':'||t.tgenabled::text||':'||p.proname x from pg_catalog.pg_trigger t join pg_catalog.pg_class c on c.oid=t.tgrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace join pg_catalog.pg_proc p on p.oid=t.tgfoid where n.nspname='public' and not t.tgisinternal) s)),
  ('gate_u1_trigger','CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION handle_new_user()',(select pg_catalog.pg_get_triggerdef(t.oid) from pg_catalog.pg_trigger t join pg_catalog.pg_class c on c.oid=t.tgrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='auth' and c.relname='users' and t.tgname='on_auth_user_created')),
  ('gate_u1_trigger_enabled','O',(select t.tgenabled::text from pg_catalog.pg_trigger t join pg_catalog.pg_class c on c.oid=t.tgrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='auth' and c.relname='users' and t.tgname='on_auth_user_created')),
  ('gate_u1_no_duplicate','1',(select count(*)::text from pg_catalog.pg_trigger t join pg_catalog.pg_class c on c.oid=t.tgrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='auth' and c.relname='users' and not t.tgisinternal)),
  ('gate_rls_enabled','41',(select count(*)::text from pg_catalog.pg_tables where schemaname='public' and rowsecurity)),
  ('gate_rls_not_enabled','0',(select count(*)::text from pg_catalog.pg_tables where schemaname='public' and not rowsecurity)),
  ('gate_force_rls','0',(select count(*)::text from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r' and c.relforcerowsecurity)),
  ('gate_sequences','1',(select count(*)::text from pg_catalog.pg_sequence s join pg_catalog.pg_class c on c.oid=s.seqrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='public')),
  ('gate_sequences_fingerprint','45ef0fc5af9f1fd2233b535c83f2ec81',(select md5(string_agg(x,',' order by x)) from (select c.relname||':'||s.seqtypid::regtype::text||':'||s.seqincrement::text||':'||s.seqstart::text x from pg_catalog.pg_sequence s join pg_catalog.pg_class c on c.oid=s.seqrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='public') s2)),
  ('gate_enum_types','1',(select count(*)::text from pg_catalog.pg_type t join pg_catalog.pg_namespace n on n.oid=t.typnamespace where n.nspname='public' and t.typtype='e')),
  ('gate_enum_labels','3',(select count(*)::text from pg_catalog.pg_type t join pg_catalog.pg_namespace n on n.oid=t.typnamespace join pg_catalog.pg_enum e on e.enumtypid=t.oid where n.nspname='public')),
  ('gate_enum_labels_fingerprint','a2e5692ae9a1e9a7691aa81d316da013',(select md5(string_agg(x,',' order by x)) from (select t.typname||':'||e.enumlabel||':'||e.enumsortorder::text x from pg_catalog.pg_type t join pg_catalog.pg_namespace n on n.oid=t.typnamespace join pg_catalog.pg_enum e on e.enumtypid=t.oid where n.nspname='public') s)),
  ('gate_publication_membership_rows','0',(select count(*)::text from pg_catalog.pg_publication_tables where schemaname='public')),
  ('gate_app_event_triggers','1',(select count(*)::text from pg_catalog.pg_event_trigger et where pg_catalog.pg_get_userbyid(et.evtowner)='postgres')),
  ('gate_app_event_triggers_fingerprint','c2e417efed05fb11fcf4836f0ad7e93e',(select md5(coalesce(string_agg(x,',' order by x),'NONE')) from (select et.evtname||':'||et.evtevent||':'||et.evtenabled::text||':'||coalesce(array_to_string(et.evttags,'+'),'-')||':'||p.proname x from pg_catalog.pg_event_trigger et join pg_catalog.pg_proc p on p.oid=et.evtfoid where pg_catalog.pg_get_userbyid(et.evtowner)='postgres') s)),
  ('gate_storage_policies','2',(select count(*)::text from pg_catalog.pg_policies where schemaname='storage')),
  ('gate_storage_policies_fingerprint','f35a6d468851d0aff1c02a78b1ed10de',(select md5(string_agg(x,',' order by x)) from (select policyname||':'||cmd||':'||coalesce(qual,'-')||':'||coalesce(with_check,'-') x from pg_catalog.pg_policies where schemaname='storage') s)),
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
  ('platform_event_triggers',(select coalesce(string_agg(et.evtname||':'||pg_catalog.pg_get_userbyid(et.evtowner),', ' order by et.evtname),'(none)') from pg_catalog.pg_event_trigger et where pg_catalog.pg_get_userbyid(et.evtowner)<>'postgres')),
  ('platform_publication_objects',(select coalesce(string_agg(pubname,', ' order by pubname),'(none)') from pg_catalog.pg_publication))
)
select 'PIN' as class, k as check_name, '__RECORD__' as expected, v as actual, 'RECORD' as verdict from pin
union all
select case when check_name like 'ctl_%' then 'CONTROL' else 'GATE' end, check_name, expected, actual,
       case when actual is not distinct from expected then 'PASS' else 'FAIL' end from ctl
union all
select 'PLATFORM', check_name, '__RECORD__', recorded, 'RECORD' from plat
union all
select 'OVERALL','r02_7_hosted_post0063_v2','ALL_PASS',
  (select case when count(*) filter (where actual is distinct from expected)=0 then 'ALL_PASS' else 'FAIL:'||count(*) filter (where actual is distinct from expected)::text end from ctl),
  (select case when count(*) filter (where actual is distinct from expected)=0 then 'HOSTED_POST0063_MATCHES_CANONICAL_V2' else 'HALT — INVESTIGATE' end from ctl);
