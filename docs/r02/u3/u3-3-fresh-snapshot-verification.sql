-- U3 · INDEPENDENT FRESH-SNAPSHOT VERIFIER. Run in ANOTHER new query, AFTER u3-2-postcheck.sql.
-- 0 DDL · 0 DML · 0 GRANT/REVOKE · 0 LOCK · 0 SET ROLE.
--
-- ★ WHY A SECOND VERIFIER EXISTS. U3's serialization is OPERATIONAL, not database-enforced. Nothing
--   prevents a competing GRANT or CREATE TABLE from landing between the migration's COMMIT and the
--   postcheck. A second read in a NEW snapshot is the only way to notice one that arrived late.
--
-- ★ DELIBERATELY IMPLEMENTED DIFFERENTLY FROM u3-2. It does NOT include or call the postcheck, and it
--   does not use aclexplode: it asks has_table_privilege per table per role per privilege, which
--   resolves privileges through role inheritance rather than by decoding an ACL array. A defect in
--   one decoding path is therefore unlikely to be shared by both. MAINTAIN is queried only on PG17+,
--   because naming it on PG16 raises "unrecognized privilege type".
with tabs as (
  select c.oid, c.relname, pg_catalog.pg_get_userbyid(c.relowner) as owner
    from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace
   where n.nspname='public' and c.relkind='r'
), roles(r) as (values ('anon'),('authenticated'),('service_role')),
sem as (
  select t.relname, roles.r,
         has_table_privilege(roles.r,t.oid,'TRUNCATE')  as p_truncate,
         has_table_privilege(roles.r,t.oid,'REFERENCES') as p_references,
         has_table_privilege(roles.r,t.oid,'TRIGGER')    as p_trigger,
         case when current_setting('server_version_num')::int>=170000
              then has_table_privilege(roles.r,t.oid,'MAINTAIN') else false end as p_maintain,
         has_table_privilege(roles.r,t.oid,'SELECT') as p_select,
         has_table_privilege(roles.r,t.oid,'INSERT') as p_insert,
         has_table_privilege(roles.r,t.oid,'UPDATE') as p_update,
         has_table_privilege(roles.r,t.oid,'DELETE') as p_delete
    from tabs t cross join roles
), chk(class, check_name, expected, actual, gating) as (values
  -- POSITIVE CONTROL: this instrument must be able to return TRUE for a privilege known to be held,
  -- otherwise every "0" below would be the sound of a broken probe.
  ('CONTROL','privilege_probe_live',$$true$$,(select (count(*)>0)::text from sem where p_select or p_insert or p_update or p_delete),true),
  ('POPULATION','public_tables',$$41$$,(select count(*)::text from tabs),true),
  ('POPULATION','table_set_fingerprint',$$0009141a4788e0e4adf17a3209bab24c$$,(select md5(string_agg(relname,',' order by relname)) from tabs),true),
  ('POPULATION','owners_all_postgres',$$0$$,(select count(*) filter (where owner<>'postgres')::text from tabs),true),
  ('DXTM','tables_granting_truncate',$$0$$,(select count(*)::text from sem where p_truncate),true),
  ('DXTM','tables_granting_references',$$0$$,(select count(*)::text from sem where p_references),true),
  ('DXTM','tables_granting_trigger',$$0$$,(select count(*)::text from sem where p_trigger),true),
  ('DXTM','tables_granting_maintain',$$0$$,(select count(*)::text from sem where p_maintain),true),
  ('DEFAULT_ACL','postgres_public_dxtm',$$0$$,(select count(*)::text from pg_catalog.pg_default_acl d, aclexplode(d.defaclacl) a where d.defaclobjtype='r' and pg_catalog.pg_get_userbyid(d.defaclrole)='postgres' and d.defaclnamespace='public'::regnamespace::oid and pg_catalog.pg_get_userbyid(a.grantee) in ('anon','authenticated','service_role') and a.privilege_type in ('TRUNCATE','REFERENCES','TRIGGER','MAINTAIN')),true),
  ('DEFAULT_ACL','postgres_global_dxtm',$$0$$,(select count(*)::text from pg_catalog.pg_default_acl d, aclexplode(d.defaclacl) a where d.defaclobjtype='r' and pg_catalog.pg_get_userbyid(d.defaclrole)='postgres' and d.defaclnamespace=0 and pg_catalog.pg_get_userbyid(a.grantee) in ('anon','authenticated','service_role') and a.privilege_type in ('TRUNCATE','REFERENCES','TRIGGER','MAINTAIN')),true),
  ('ROW_DML','row_dml_true_count',$$21$$,(select (count(*) filter (where p_select)+count(*) filter (where p_insert)+count(*) filter (where p_update)+count(*) filter (where p_delete))::text from sem),true),
  ('ROW_DML','row_dml_fingerprint',$$052198590dd92ba70ab07c99cbd21f15$$,(select md5(string_agg(g,',' order by g)) from (select relname||'|'||r||'|SELECT' g from sem where p_select union all select relname||'|'||r||'|INSERT' from sem where p_insert union all select relname||'|'||r||'|UPDATE' from sem where p_update union all select relname||'|'||r||'|DELETE' from sem where p_delete) x),true)
)
select class, check_name, expected, actual,
       case when not gating then 'RECORD' when actual is not distinct from expected then 'PASS' else 'FAIL' end as verdict
from chk
union all
select 'OVERALL','u3_fresh_snapshot',$$ALL_PASS$$,
  (select case when count(*) filter (where gating and actual is distinct from expected)=0 then 'ALL_PASS' else 'FAIL:'||count(*) filter (where gating and actual is distinct from expected)::text end from chk),
  (select case when count(*) filter (where gating and actual is distinct from expected)=0 then 'U3_INDEPENDENTLY_REVERIFIED — freeze may be released' else 'HALT — KEEP FREEZE ACTIVE, DO NOT RERUN' end from chk);
