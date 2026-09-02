-- U3 · SELECT-ONLY POSTCONDITION. Run in a NEW query/fresh snapshot after a U3 execution attempt.
-- 0 DDL · 0 DML · 0 GRANT/REVOKE · 0 LOCK · 0 SET ROLE.  Passes identically after APPLIED and RECOGNIZED.
--
-- ★ GATES THE APPLICATION-CREATOR STATE ONLY. supabase_admin and other platform default ACLs are
--   RECORDED, never gated: a default ACL is selected by the role CREATING the object, every
--   application table is created by postgres, and those platform rows are not ours to change.
--   Asserting "no Dxtm default anywhere" would fail on hosted for a reason U3 must not try to fix.
-- ★ NO RAW ACL-STRING EQUALITY. Raw relacl is platform- and PG-version dependent (MAINTAIN is PG17+),
--   so every assertion below is semantic, via aclexplode.
with tabs as (
  select c.oid, c.relname, pg_catalog.pg_get_userbyid(c.relowner) as owner
    from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace
   where n.nspname='public' and c.relkind='r'
), gr as (
  select t.relname, pg_catalog.pg_get_userbyid(a.grantee) grantee, a.privilege_type
    from tabs t, aclexplode((select relacl from pg_catalog.pg_class where oid=t.oid)) a
   where pg_catalog.pg_get_userbyid(a.grantee) in ('anon','authenticated','service_role')
), adp as (
  select coalesce((select nspname from pg_catalog.pg_namespace where oid=d.defaclnamespace),'GLOBAL') scope,
         pg_catalog.pg_get_userbyid(a.grantee) grantee, a.privilege_type
    from pg_catalog.pg_default_acl d, aclexplode(d.defaclacl) a
   where d.defaclobjtype='r' and pg_catalog.pg_get_userbyid(d.defaclrole)='postgres'
     and pg_catalog.pg_get_userbyid(a.grantee) in ('anon','authenticated','service_role')
), chk(class, check_name, expected, actual, gating) as (values
  ('CONTROL','pg_class_readable',$$true$$,(select (count(*)>=0)::text from pg_catalog.pg_class),true),
  ('CONTROL','acl_decoder_live',$$true$$,(select (count(*)>0)::text from gr where privilege_type in ('SELECT','INSERT','UPDATE','DELETE')),true),
  ('POPULATION','public_tables',$$41$$,(select count(*)::text from tabs),true),
  ('POPULATION','table_set_fingerprint',$$0009141a4788e0e4adf17a3209bab24c$$,(select md5(string_agg(relname,',' order by relname)) from tabs),true),
  ('POPULATION','distinct_owners',$$1$$,(select count(distinct owner)::text from tabs),true),
  ('POPULATION','non_postgres_owned',$$0$$,(select count(*) filter (where owner<>'postgres')::text from tabs),true),
  ('POPULATION','public_functions',$$147$$,(select count(*)::text from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public'),true),
  ('POPULATION','public_policies',$$38$$,(select count(*)::text from pg_catalog.pg_policies where schemaname='public'),true),
  ('DELTA','existing_table_dxtm_total',$$0$$,(select count(*)::text from gr where privilege_type in ('TRUNCATE','REFERENCES','TRIGGER','MAINTAIN')),true),
  ('DELTA','existing_table_dxtm_anon',$$0$$,(select count(*)::text from gr where grantee='anon' and privilege_type in ('TRUNCATE','REFERENCES','TRIGGER','MAINTAIN')),true),
  ('DELTA','existing_table_dxtm_authenticated',$$0$$,(select count(*)::text from gr where grantee='authenticated' and privilege_type in ('TRUNCATE','REFERENCES','TRIGGER','MAINTAIN')),true),
  ('DELTA','existing_table_dxtm_service_role',$$0$$,(select count(*)::text from gr where grantee='service_role' and privilege_type in ('TRUNCATE','REFERENCES','TRIGGER','MAINTAIN')),true),
  ('DELTA','postgres_public_default_dxtm',$$0$$,(select count(*)::text from adp where scope='public' and privilege_type in ('TRUNCATE','REFERENCES','TRIGGER','MAINTAIN')),true),
  ('DELTA','postgres_global_default_dxtm',$$0$$,(select count(*)::text from adp where scope='GLOBAL' and privilege_type in ('TRUNCATE','REFERENCES','TRIGGER','MAINTAIN')),true),
  ('DELTA','postgres_public_default_rowdml',$$0$$,(select count(*)::text from adp where scope='public' and privilege_type in ('SELECT','INSERT','UPDATE','DELETE')),true),
  ('RATCHET','row_dml_grant_rows',$$21$$,(select count(*)::text from gr where privilege_type in ('SELECT','INSERT','UPDATE','DELETE')),true),
  ('RATCHET','row_dml_fingerprint',$$052198590dd92ba70ab07c99cbd21f15$$,(select md5(string_agg(relname||'|'||grantee||'|'||privilege_type,',' order by relname||'|'||grantee||'|'||privilege_type)) from gr where privilege_type in ('SELECT','INSERT','UPDATE','DELETE')),true),
  ('RATCHET','row_dml_inventory',$$__RECORD__$$,(select string_agg(relname||'|'||grantee||'|'||privilege_type,', ' order by relname||'|'||grantee||'|'||privilege_type) from gr where privilege_type in ('SELECT','INSERT','UPDATE','DELETE')),false),
  ('PLATFORM','supabase_admin_default_acl',$$__RECORD__$$,(select coalesce(string_agg(distinct coalesce((select nspname from pg_catalog.pg_namespace where oid=d.defaclnamespace),'GLOBAL')||':'||d.defaclobjtype::text,', '),'(none)') from pg_catalog.pg_default_acl d where pg_catalog.pg_get_userbyid(d.defaclrole)='supabase_admin'),false),
  ('PLATFORM','other_grantor_default_acls',$$__RECORD__$$,(select coalesce(string_agg(distinct pg_catalog.pg_get_userbyid(d.defaclrole),', '),'(none)') from pg_catalog.pg_default_acl d where pg_catalog.pg_get_userbyid(d.defaclrole) not in ('postgres','supabase_admin')),false),
  ('PLATFORM','serialization_model',$$__RECORD__$$,$$OPERATOR_ENFORCED_DDL_ACL_FREEZE — database-enforced serialization unavailable$$,false)
)
select class, check_name, expected, actual,
       case when not gating then 'RECORD' when actual is not distinct from expected then 'PASS' else 'FAIL' end as verdict
from chk
union all
select 'OVERALL','u3_postcheck',$$ALL_PASS$$,
  (select case when count(*) filter (where gating and actual is distinct from expected)=0 then 'ALL_PASS' else 'FAIL:'||count(*) filter (where gating and actual is distinct from expected)::text end from chk),
  (select case when count(*) filter (where gating and actual is distinct from expected)=0 then 'U3_APPLIED_AND_VERIFIED' else 'HALT — INVESTIGATE, KEEP FREEZE ACTIVE' end from chk);
