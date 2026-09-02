-- U3 · SELECT-ONLY PRE-EXECUTION GATE.  PREPARED, NOT EXECUTED.
-- Target: afterworth-nonprod (qxzeougbaarecaiiqsay).  0 DDL · 0 DML · 0 GRANT/REVOKE · 0 LOCK · 0 SET ROLE.
--
-- ★ RUN ONLY WITH THE OPERATOR FREEZE ACTIVE. Serialization for U3 is OPERATIONAL, not
--   database-enforced: the hosted executor cannot lock pg_class / pg_default_acl, so nothing here or
--   in the migration prevents a competing GRANT or CREATE TABLE. See u3-operational-freeze-protocol.md.
--
-- ★ target_project_ref IS A RECORD, NOT A GATE. A Supabase project ref has no in-database source, so
--   this row cannot fail and must never be read as proof the right project was addressed. Confirm the
--   project in the dashboard first.
--
-- ★ APPLICATION-CREATOR vs PLATFORM. Gates apply ONLY to the postgres/public default ACL, because a
--   default ACL is chosen by the role CREATING the object and every application table is created by
--   postgres. supabase_admin's defaults are recorded, never gated — they are not ours to change.
with tabs as (
  select c.oid, c.relname, pg_catalog.pg_get_userbyid(c.relowner) as owner
    from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace
   where n.nspname='public' and c.relkind='r'
), dxtm as (
  select count(*) n from tabs t, aclexplode((select relacl from pg_catalog.pg_class where oid=t.oid)) a
   where pg_catalog.pg_get_userbyid(a.grantee) in ('anon','authenticated','service_role')
     and a.privilege_type in ('TRUNCATE','REFERENCES','TRIGGER','MAINTAIN')
), rowdml as (
  select count(*) n, coalesce(md5(string_agg(g, ',' order by g)),'NONE') fp from (
    select t.relname||'|'||pg_catalog.pg_get_userbyid(a.grantee)||'|'||a.privilege_type g
      from tabs t, aclexplode((select relacl from pg_catalog.pg_class where oid=t.oid)) a
     where pg_catalog.pg_get_userbyid(a.grantee) in ('anon','authenticated','service_role')
       and a.privilege_type in ('SELECT','INSERT','UPDATE','DELETE')) s
), adp as (
  select count(*) filter (where d.defaclnamespace='public'::regnamespace::oid and a.privilege_type in ('TRUNCATE','REFERENCES','TRIGGER','MAINTAIN')) pub_dxtm,
         count(*) filter (where d.defaclnamespace='public'::regnamespace::oid and a.privilege_type in ('SELECT','INSERT','UPDATE','DELETE')) pub_dml,
         count(*) filter (where d.defaclnamespace=0 and a.privilege_type in ('TRUNCATE','REFERENCES','TRIGGER','MAINTAIN')) glb_dxtm
    from pg_catalog.pg_default_acl d, aclexplode(d.defaclacl) a
   where d.defaclobjtype='r' and pg_catalog.pg_get_userbyid(d.defaclrole)='postgres'
     and pg_catalog.pg_get_userbyid(a.grantee) in ('anon','authenticated','service_role')
), st as (
  select case
    when (select count(*) from pg_catalog.pg_roles where rolname in ('anon','authenticated','service_role'))<>3
      or (select count(*) from pg_catalog.pg_namespace where nspname='public')<>1
      or (select n from rowdml)=0                                              then 'INSTRUMENT_BROKEN'
    when (select count(*) filter (where owner<>'postgres') from tabs)>0
      or (select count(distinct owner) from tabs)<>1                           then 'UNEXPECTED_PUBLIC_TABLE_OWNER'
    when (select count(*) from tabs)>41                                        then 'UNEXPECTED_PUBLIC_TABLE'
    when (select count(*) from tabs)<41                                        then 'MISSING_EXPECTED_PUBLIC_TABLE'
    when (select md5(string_agg(relname,',' order by relname)) from tabs) is distinct from '0009141a4788e0e4adf17a3209bab24c'
                                                                               then 'UNEXPECTED_PUBLIC_TABLE'
    when (select fp from rowdml) is distinct from '052198590dd92ba70ab07c99cbd21f15'
                                                                               then 'UNEXPECTED_ROW_DML_DRIFT'
    when (select glb_dxtm from adp)>0                                          then 'UNEXPECTED_POSTGRES_GLOBAL_DEFAULT_ACL'
    when (select pub_dml  from adp)>0                                          then 'UNEXPECTED_POSTGRES_PUBLIC_DEFAULT_ACL'
    when (select n from dxtm)=492 and (select pub_dxtm from adp)=12            then 'EXACT_PRESTATE'
    when (select n from dxtm)=0   and (select pub_dxtm from adp)=0             then 'EXACT_POSTSTATE'
    when (select n from dxtm)=0   and (select pub_dxtm from adp)>0             then 'PARTIAL_DEFAULT_ACL_HARDENING'
    when (select n from dxtm)>0   and (select pub_dxtm from adp)=0             then 'PARTIAL_TABLE_HARDENING'
    else 'UNEXPECTED_Dxtm_VARIANT' end as state
), chk(class, check_name, expected, actual, gating) as (values
  ('CONTROL','pg_class_readable',$$true$$,(select (count(*)>=0)::text from pg_catalog.pg_class),true),
  ('CONTROL','acl_decoder_live',$$true$$,(select ((select n from rowdml)>0)::text),true),
  ('IDENTITY','current_user',$$postgres$$,current_user::text,true),
  ('IDENTITY','server_version_supports_maintain',$$true$$,(current_setting('server_version_num')::int>=170000)::text,true),
  ('PIN','target_project_ref',$$__RECORD__$$,$$qxzeougbaarecaiiqsay$$,false),
  ('PIN','operator_project_identity_confirmation_required',$$__RECORD__$$,$$true — confirm in dashboard; not verifiable in SQL$$,false),
  ('PIN','operational_freeze_required',$$__RECORD__$$,$$true — DDL/ACL freeze must be ACTIVE; serialization is NOT database-enforced$$,false),
  ('POPULATION','public_tables',$$41$$,(select count(*)::text from tabs),true),
  ('POPULATION','table_set_fingerprint',$$0009141a4788e0e4adf17a3209bab24c$$,(select md5(string_agg(relname,',' order by relname)) from tabs),true),
  ('POPULATION','distinct_owners',$$1$$,(select count(distinct owner)::text from tabs),true),
  ('POPULATION','non_postgres_owned',$$0$$,(select count(*) filter (where owner<>'postgres')::text from tabs),true),
  ('POPULATION','public_functions',$$147$$,(select count(*)::text from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public'),true),
  ('POPULATION','public_policies',$$38$$,(select count(*)::text from pg_catalog.pg_policies where schemaname='public'),true),
  ('ROW_DML','row_dml_grant_rows',$$21$$,(select n::text from rowdml),true),
  ('ROW_DML','row_dml_fingerprint',$$052198590dd92ba70ab07c99cbd21f15$$,(select fp from rowdml),true),
  ('PRESTATE','existing_table_dxtm_rows',$$__RECORD__$$,(select n::text from dxtm),false),
  ('PRESTATE','postgres_public_default_dxtm',$$__RECORD__$$,(select pub_dxtm::text from adp),false),
  ('PRESTATE','postgres_global_default_dxtm',$$0$$,(select glb_dxtm::text from adp),true),
  ('PRESTATE','postgres_public_default_rowdml',$$0$$,(select pub_dml::text from adp),true),
  ('PLATFORM','platform_default_acls',$$__RECORD__$$,(select coalesce(string_agg(pg_catalog.pg_get_userbyid(d.defaclrole)||'/'||coalesce((select nspname from pg_catalog.pg_namespace where oid=d.defaclnamespace),'GLOBAL')||'/'||d.defaclobjtype::text,', ' order by 1),'(none)') from pg_catalog.pg_default_acl d where pg_catalog.pg_get_userbyid(d.defaclrole)<>'postgres'),false),
  ('STATE','policy_state',$$__RECORD__$$,(select state from st),false),
  ('STATE','expected_migration_action',$$__RECORD__$$,(select case state when 'EXACT_PRESTATE' then 'APPLY' when 'EXACT_POSTSTATE' then 'RECOGNIZE' else 'NONE — HALT' end from st),false),
  ('STATE','state_eligible',$$true$$,(select (state in ('EXACT_PRESTATE','EXACT_POSTSTATE'))::text from st),true)
)
select class, check_name, expected, actual,
       case when not gating then 'RECORD' when actual is not distinct from expected then 'PASS' else 'FAIL' end as verdict
from chk
union all
select 'OVERALL','u3_precheck',$$PASS$$,
  (select case when count(*) filter (where gating and actual is distinct from expected)=0 then 'PASS' else 'FAIL:'||count(*) filter (where gating and actual is distinct from expected)::text end from chk),
  (select case when (select count(*) from chk where gating and actual is distinct from expected)>0 then 'HALT — state='||(select state from st)
               when (select state from st)='EXACT_PRESTATE'  then 'ELIGIBLE_APPLY — freeze must be ACTIVE; pending explicit authorization'
               when (select state from st)='EXACT_POSTSTATE' then 'ELIGIBLE_RECOGNIZE — freeze must be ACTIVE; pending explicit authorization'
               else 'HALT' end);
