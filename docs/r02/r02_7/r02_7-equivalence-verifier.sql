-- R02_7 · PRIMARY EQUIVALENCE COMPARATOR.  SELECT-only.
--
-- Emits one row per authoritative dimension: name, unit count, semantic fingerprint. Run against
-- two builds and compare row-for-row; a top-level digest is only meaningful after the per-dimension
-- rows exist.
--
-- ★ NORMALIZATION: no OIDs, no raw relacl, no relfilenode, no timestamps, no physical order. Every
--   string_agg carries an explicit ORDER BY. ACLs are decoded via aclexplode, never compared as
--   text. Row-DML (SELECT/INSERT/UPDATE/DELETE) is kept separate from Dxtm
--   (TRUNCATE/REFERENCES/TRIGGER/MAINTAIN) throughout.
-- ★ UNITS ARE NAMED FOR WHAT THEY COUNT: enum_types vs enum_label_rows, publication_objects vs
--   publication_membership_rows, *_grant_rows. An earlier revision reported "enums = 3", which was
--   three labels of one type.
-- ★ extensions_all_recorded is PLATFORM_RECORDED_ONLY and is NOT an application gate; the
--   application gate is extensions_app_owned.
\pset tuples_only on
\pset format unaligned
\pset fieldsep '|'
with d(dim, n, fp) as (
 select 'tables_ordinary', count(*), md5(string_agg(x,',' order by x)) from (select c.relname||':'||pg_get_userbyid(c.relowner) x from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r') s
 union all select 'columns', count(*), md5(string_agg(x,',' order by x)) from (select table_name||'.'||column_name||':'||data_type||':'||is_nullable||':'||coalesce(column_default,'-')||':'||coalesce(is_identity,'-')||':'||coalesce(is_generated,'-') x from information_schema.columns where table_schema='public') s
 union all select 'primary_keys', count(*), md5(string_agg(x,',' order by x)) from (select con.conname||'@'||rel.relname||':'||pg_get_constraintdef(con.oid) x from pg_constraint con join pg_class rel on rel.oid=con.conrelid join pg_namespace n on n.oid=rel.relnamespace where n.nspname='public' and con.contype='p') s
 union all select 'unique_constraints', count(*), md5(string_agg(x,',' order by x)) from (select con.conname||'@'||rel.relname||':'||pg_get_constraintdef(con.oid) x from pg_constraint con join pg_class rel on rel.oid=con.conrelid join pg_namespace n on n.oid=rel.relnamespace where n.nspname='public' and con.contype='u') s
 union all select 'foreign_keys', count(*), md5(string_agg(x,',' order by x)) from (select con.conname||'@'||rel.relname||':'||pg_get_constraintdef(con.oid) x from pg_constraint con join pg_class rel on rel.oid=con.conrelid join pg_namespace n on n.oid=rel.relnamespace where n.nspname='public' and con.contype='f') s
 union all select 'check_constraints', count(*), md5(string_agg(x,',' order by x)) from (select con.conname||'@'||rel.relname||':'||pg_get_constraintdef(con.oid) x from pg_constraint con join pg_class rel on rel.oid=con.conrelid join pg_namespace n on n.oid=rel.relnamespace where n.nspname='public' and con.contype='c') s
 union all select 'indexes', count(*), md5(string_agg(x,',' order by x)) from (select c.relname||':'||pg_get_indexdef(i.indexrelid) x from pg_index i join pg_class c on c.oid=i.indrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and not exists (select 1 from pg_constraint k where k.conindid=i.indexrelid)) s
 union all select 'functions', count(*), md5(string_agg(x,',' order by x)) from (select p.proname||'('||pg_get_function_identity_arguments(p.oid)||')'||':'||pg_get_function_result(p.oid)||':'||l.lanname||':'||p.provolatile::text||':'||p.prosecdef::text||':'||p.proisstrict::text||':'||coalesce(array_to_string(p.proconfig,';'),'-')||':'||md5(coalesce(p.prosrc,'')) x from pg_proc p join pg_namespace n on n.oid=p.pronamespace join pg_language l on l.oid=p.prolang where n.nspname='public') s
 union all select 'policies', count(*), md5(string_agg(x,',' order by x)) from (select tablename||'.'||policyname||':'||cmd||':'||permissive||':'||array_to_string(roles,'+')||':'||coalesce(regexp_replace(qual,'\s+',' ','g'),'-')||':'||coalesce(regexp_replace(with_check,'\s+',' ','g'),'-') x from pg_policies where schemaname='public') s
 union all select 'triggers_public', count(*), md5(string_agg(x,',' order by x)) from (select c.relname||'.'||t.tgname||':'||t.tgtype::text||':'||t.tgenabled::text||':'||p.proname x from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace join pg_proc p on p.oid=t.tgfoid where n.nspname='public' and not t.tgisinternal) s
 union all select 'trigger_auth_users', count(*), md5(coalesce(string_agg(x,',' order by x),'NONE')) from (select t.tgname||':'||t.tgtype::text||':'||t.tgenabled::text||':'||p.proname x from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace join pg_proc p on p.oid=t.tgfoid where n.nspname='auth' and c.relname='users' and not t.tgisinternal) s
 union all select 'rls_state', count(*), md5(string_agg(x,',' order by x)) from (select c.relname||':'||c.relrowsecurity::text||':'||c.relforcerowsecurity::text x from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r') s
 union all select 'sequences', count(*), md5(coalesce(string_agg(x,',' order by x),'NONE')) from (select sequence_name||':'||data_type x from information_schema.sequences where sequence_schema='public') s
 union all select 'enum_label_rows', count(*), md5(coalesce(string_agg(x,',' order by x),'NONE')) from (select t.typname||':'||e.enumlabel||':'||e.enumsortorder::text x from pg_type t join pg_namespace n on n.oid=t.typnamespace join pg_enum e on e.enumtypid=t.oid where n.nspname='public') s
 union all select 'row_dml_acl_grant_rows', count(*), md5(coalesce(string_agg(x,',' order by x),'NONE')) from (select c.relname||'|'||pg_get_userbyid(a.grantee)||'|'||a.privilege_type x from pg_class c join pg_namespace n on n.oid=c.relnamespace, aclexplode(c.relacl) a where n.nspname='public' and c.relkind='r' and pg_get_userbyid(a.grantee) in ('anon','authenticated','service_role') and a.privilege_type in ('SELECT','INSERT','UPDATE','DELETE')) s
 union all select 'app_non_row_dml_acl_grant_rows', count(*), md5(coalesce(string_agg(x,',' order by x),'NONE')) from (select c.relname||'|'||pg_get_userbyid(a.grantee)||'|'||a.privilege_type x from pg_class c join pg_namespace n on n.oid=c.relnamespace, aclexplode(c.relacl) a where n.nspname='public' and c.relkind='r' and pg_get_userbyid(a.grantee) in ('anon','authenticated','service_role') and a.privilege_type in ('TRUNCATE','REFERENCES','TRIGGER','MAINTAIN')) s
 union all select 'app_creator_default_acl_rows', count(*), md5(coalesce(string_agg(x,',' order by x),'NONE')) from (select coalesce((select nspname from pg_namespace where oid=dd.defaclnamespace),'GLOBAL')||'|'||pg_get_userbyid(a.grantee)||'|'||a.privilege_type x from pg_default_acl dd, aclexplode(dd.defaclacl) a where dd.defaclobjtype='r' and pg_get_userbyid(dd.defaclrole)='postgres' and pg_get_userbyid(a.grantee) in ('anon','authenticated','service_role')) s
 union all select 'storage_policies', count(*), md5(coalesce(string_agg(x,',' order by x),'NONE')) from (select policyname||':'||cmd||':'||coalesce(regexp_replace(qual,'\s+',' ','g'),'-')||':'||coalesce(regexp_replace(with_check,'\s+',' ','g'),'-') x from pg_policies where schemaname='storage') s
 union all select 'event_triggers', count(*), md5(coalesce(string_agg(x,',' order by x),'NONE')) from (select evtname||':'||evtevent||':'||evtenabled::text||':'||coalesce(array_to_string(evttags,'+'),'-') x from pg_event_trigger) s
 union all select 'publication_membership_rows', count(*), md5(coalesce(string_agg(x,',' order by x),'NONE')) from (select pubname||':'||schemaname||'.'||tablename x from pg_publication_tables) s
 union all select 'extensions_app_owned', count(*), md5(coalesce(string_agg(x,',' order by x),'NONE')) from (select extname x from pg_extension where extname in ('pgcrypto','uuid-ossp')) s
 union all select 'enum_types', count(*), md5(coalesce(string_agg(x,',' order by x),'NONE')) from (select t.typname x from pg_type t join pg_namespace n on n.oid=t.typnamespace where n.nspname='public' and t.typtype='e') s
 union all select 'publication_objects', count(*), md5(coalesce(string_agg(x,',' order by x),'NONE')) from (select pubname x from pg_publication) s
 union all select 'extensions_all_recorded', count(*), md5(coalesce(string_agg(x,',' order by x),'NONE')) from (select extname x from pg_extension) s
)
select dim, n, fp from d order by dim;
