-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- U3 · BLOCKER-CLOSURE DIAGNOSTIC — DEFAULT ACL PROVENANCE + CATALOG-LOCK CAPABILITY
--
-- STATUS:   PREPARED, NOT EXECUTED.  EXECUTED BY: the user, manually, in the SQL Editor.
-- TARGET:   afterworth-nonprod (qxzeougbaarecaiiqsay).
--           NOT afterworth-dev. NOT afterworth-prod.
--
-- ★ SELECT-ONLY. 0 DDL · 0 DML · 0 GRANT/REVOKE · 0 ALTER DEFAULT PRIVILEGES · 0 SET ROLE ·
--   0 LOCK · 0 BEGIN/COMMIT/ROLLBACK.  Every catalog helper is called in SELECT position only.
--
-- ★ NO LOCK IS ATTEMPTED HERE. Statement 3 measures the PRIVILEGE BITS that decide whether a
--   catalog LOCK could succeed. It never issues LOCK TABLE — a capability question is answered by
--   reading a privilege, never by attempting the operation and observing the failure.
--
-- WHY THIS EXISTS. Two facts decide whether U3 can be built at all, and neither is in the
-- repository:
--
--   1. WHICH default ACL grants Dxtm, and AT WHAT SCOPE. Proven on PG17: per-schema defaults are
--      ADDED to global defaults, and a REVOKE cannot subtract across scopes. A global GRANT with an
--      `IN SCHEMA public` REVOKE leaves new tables fully privileged and reports success. Migration
--      0012 used the schema-scoped form. If the hosted default is global, that form is a NO-OP.
--
--   2. WHETHER THE EXECUTOR MAY LOCK THE CATALOGS. The only proven serialization for U3 is
--      LOCK TABLE on pg_default_acl and pg_class in SHARE MODE. SHARE requires UPDATE / DELETE /
--      TRUNCATE / MAINTAIN on the catalog, or ownership. Measured locally: a NOSUPERUSER role with
--      pg_read_all_data is DENIED ("permission denied for table pg_class") and can take only
--      ACCESS SHARE, which does not conflict and therefore does not serialize.
-- ════════════════════════════════════════════════════════════════════════════════════════════════


-- ── STATEMENT 1 · CONTROLS — READ FIRST ──────────────────────────────────────────────────────
-- If verdict <> INSTRUMENT_OK, statements 2-3 mean nothing. A privilege of `false` from a session
-- that cannot see the catalog is not evidence of anything.
select current_user::text                                            as current_user_name,
       session_user::text                                            as session_user_name,
       current_database()                                            as database_name,
       current_setting('server_version')                             as server_version,
       current_setting('server_version_num')::int                    as server_version_num,
       (current_setting('server_version_num')::int >= 170000)         as maintain_privilege_exists,
       (select rolsuper      from pg_roles where rolname = current_user) as is_superuser,
       (select rolbypassrls  from pg_roles where rolname = current_user) as bypasses_rls,
       (select count(*) from pg_roles
         where rolname in ('anon','authenticated','service_role'))    as client_roles_visible,
       (select count(*) from pg_default_acl)                          as default_acl_rows_visible,
       case when (select count(*) from pg_roles
                   where rolname in ('anon','authenticated','service_role')) = 3
             and (select count(*) from pg_namespace where nspname = 'public') = 1
            then 'INSTRUMENT_OK'
            else 'INSTRUMENT_BROKEN — DO NOT CONCLUDE ABSENT' end     as verdict;


-- ── STATEMENT 2 · DEFAULT ACL PROVENANCE — DELIBERATELY UNFILTERED ───────────────────────────
-- ★ NOT filtered to the three client roles, nor to the four Dxtm privileges, nor to schema public.
--   The whole question is WHICH grantor and WHICH scope establish these defaults; a filter written
--   around what we expect could conceal exactly the row that matters. Read `grantor_role` and
--   `scope_class` together — those two decide which ALTER DEFAULT PRIVILEGES statement, if any,
--   could remove the grant, and whether the executor would need membership in another role.
select pg_get_userbyid(d.defaclrole)                    as grantor_role,
       d.defaclnamespace                                as defaclnamespace_oid,
       coalesce(n.nspname, '(none — global)')           as schema_name,
       case when d.defaclnamespace = 0 then 'GLOBAL (all schemas)'
            else 'SCHEMA-SCOPED' end                    as scope_class,
       case d.defaclobjtype
         when 'r' then 'table' when 'S' then 'sequence' when 'f' then 'function'
         when 'T' then 'type'  when 'n' then 'schema'
         else d.defaclobjtype::text end                 as object_type,
       coalesce(a.grantee_role, '(none)')               as grantee_role,
       coalesce(a.privilege_type, '(none)')             as privilege_type,
       a.is_grantable                                   as grant_option,
       case when a.privilege_type in ('TRUNCATE','REFERENCES','TRIGGER','MAINTAIN')
             and a.grantee_role in ('anon','authenticated','service_role')
            then 'U3_TARGET'
            when a.privilege_type in ('SELECT','INSERT','UPDATE','DELETE')
             and a.grantee_role in ('anon','authenticated','service_role')
            then 'ROW_DML — NOT U3 TARGET, MUST NOT BE REMOVED'
            else 'other' end                            as u3_classification
from pg_default_acl d
left join pg_namespace n on n.oid = d.defaclnamespace
left join lateral (
  select case when x.grantee = 0 then 'PUBLIC' else pg_get_userbyid(x.grantee) end as grantee_role,
         x.privilege_type, x.is_grantable
  from aclexplode(d.defaclacl) x
) a on true
order by grantor_role, scope_class, object_type, grantee_role, privilege_type;


-- ── STATEMENT 3 · CATALOG-LOCK CAPABILITY — PRIVILEGE BITS ONLY, NO LOCK ATTEMPTED ───────────
-- SHARE MODE on a relation requires UPDATE, DELETE, TRUNCATE or MAINTAIN on it, or ownership, or
-- superuser. ACCESS SHARE requires only SELECT — but ACCESS SHARE does NOT conflict with the
-- RowExclusiveLock that GRANT / REVOKE / ALTER DEFAULT PRIVILEGES / CREATE TABLE take on these
-- catalogs, so it cannot serialize them. `share_mode_predicted` is therefore the decisive column.
select c.relname::text                                                        as catalog_relation,
       pg_get_userbyid(c.relowner)                                            as catalog_owner,
       (pg_get_userbyid(c.relowner) = current_user)                           as executor_is_owner,
       pg_has_role(current_user, c.relowner, 'MEMBER')                        as executor_in_owner_role,
       has_table_privilege(current_user, c.oid, 'SELECT')                     as priv_select,
       has_table_privilege(current_user, c.oid, 'UPDATE')                     as priv_update,
       has_table_privilege(current_user, c.oid, 'DELETE')                     as priv_delete,
       has_table_privilege(current_user, c.oid, 'TRUNCATE')                   as priv_truncate,
       case when current_setting('server_version_num')::int >= 170000
            then has_table_privilege(current_user, c.oid, 'MAINTAIN')
            else null end                                                     as priv_maintain,
       has_table_privilege(current_user, c.oid, 'SELECT')                     as access_share_predicted,
       ( (select rolsuper from pg_roles where rolname = current_user)
         or pg_get_userbyid(c.relowner) = current_user
         or pg_has_role(current_user, c.relowner, 'MEMBER')
         or has_table_privilege(current_user, c.oid, 'UPDATE')
         or has_table_privilege(current_user, c.oid, 'DELETE')
         or has_table_privilege(current_user, c.oid, 'TRUNCATE')
         or (current_setting('server_version_num')::int >= 170000
             and has_table_privilege(current_user, c.oid, 'MAINTAIN')) )      as share_mode_predicted
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'pg_catalog'
  and c.relname in ('pg_class','pg_default_acl','pg_namespace')
order by c.relname;
