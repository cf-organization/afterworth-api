-- R02_7 · HOSTED UUID DEFAULT BINDING DIAGNOSTIC.  PREPARED, NOT EXECUTED.
-- Target: afterworth-nonprod (qxzeougbaarecaiiqsay).
-- SELECT-only: 0 DDL · 0 DML · 0 GRANT/REVOKE · 0 LOCK · 0 SET ROLE · 0 transaction control · 0 DO.
--
-- ★ WHY. The hosted column forensic (sha 90998117…758f) found exactly 14 differences, all
--   DEFAULT_MISMATCH, all the same shape:
--       expected  extensions.uuid_generate_v4()
--       hosted    uuid_generate_v4()
--   with hosted session search_path = "$user", public, extensions. No other V2-normalized column
--   attribute differed. That is consistent with a rendering difference — but a rendered string is
--   not a binding. This proves WHICH FUNCTION THE STORED DEFAULT ACTUALLY DEPENDS ON.
--
-- ★ IT DOES NOT COMPARE TEXT. PostgreSQL records the dependency in pg_depend
--   (classid = pg_attrdef, refclassid = pg_proc, deptype 'n'); measured on the canonical build there
--   are exactly 14 such rows, matching the 14 affected columns. Section 1 resolves that dependency
--   to a namespace-qualified function identity. Spelling, search_path and mere function existence
--   are never treated as evidence of binding.
--
-- ★ OIDs APPEAR FOR TRACING ONLY. `to_regprocedure('extensions.uuid_generate_v4()')` is compared to
--   the bound function OID to establish same-catalog identity *within this one database*. No OID is
--   used in any durable fingerprint or carried between databases.

-- ── 0 · OPERATOR PIN ─────────────────────────────────────────────────────────────────────────
select 'PIN' as class, 'target_project_ref' as k, 'qxzeougbaarecaiiqsay' as v
union all select 'PIN','operator_project_identity_confirmation_required','true — confirm in dashboard; not verifiable in SQL'
union all select 'PIN','expected_binding','extensions.uuid_generate_v4() returns uuid, no arguments'
union all select 'PIN','rendering_observed','hosted uuid_generate_v4() vs canonical extensions.uuid_generate_v4()';

-- ── 1 · PER-COLUMN SEMANTIC BINDING ─────────────────────────────────────────────────────────
-- One row per column default that depends on a function. Verdict is decided by namespace+name+
-- identity-args+return-type, and corroborated by OID identity within this database.
select 'BINDING' as class,
       n.nspname::text                                        as schema_name,
       c.relname::text                                        as table_name,
       a.attname::text                                        as column_name,
       ad.oid::text                                           as pg_attrdef_oid_trace_only,
       pg_catalog.pg_get_expr(ad.adbin, ad.adrelid)           as rendered_default,
       pn.nspname::text                                       as bound_function_schema,
       p.proname::text                                        as bound_function_name,
       pg_catalog.pg_get_function_identity_arguments(p.oid)   as bound_identity_args,
       pg_catalog.pg_get_function_result(p.oid)               as bound_return_type,
       l.lanname::text                                        as bound_language,
       p.oid::text                                            as bound_function_oid_trace_only,
       coalesce(to_regprocedure('extensions.uuid_generate_v4()')::oid::text,'(absent)')
                                                              as expected_function_oid_trace_only,
       (p.oid = to_regprocedure('extensions.uuid_generate_v4()')::oid)
                                                              as oid_identity_same_catalog,
       case when pn.nspname = 'extensions'
             and p.proname  = 'uuid_generate_v4'
             and pg_catalog.pg_get_function_identity_arguments(p.oid) = ''
             and pg_catalog.pg_get_function_result(p.oid) = 'uuid'
            then 'PASS' else 'FAIL' end                       as semantic_binding_verdict
  from pg_catalog.pg_depend d
  join pg_catalog.pg_attrdef ad on ad.oid = d.objid
  join pg_catalog.pg_class    c on c.oid = ad.adrelid
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  join pg_catalog.pg_attribute a on a.attrelid = ad.adrelid and a.attnum = ad.adnum
  join pg_catalog.pg_proc     p on p.oid = d.refobjid
  join pg_catalog.pg_namespace pn on pn.oid = p.pronamespace
  join pg_catalog.pg_language l on l.oid = p.prolang
 where d.classid = 'pg_catalog.pg_attrdef'::regclass
   and d.refclassid = 'pg_catalog.pg_proc'::regclass
   and n.nspname = 'public'
 order by 2, 3;

-- ── 2 · SHADOWING CONTROL — every visible uuid_generate_v4(), in ANY schema ──────────────────
-- Absence of a shadow is asserted, never assumed. If a same-signature function exists outside
-- `extensions`, it is listed here and section 1 still decides the binding.
select 'SHADOW_CANDIDATE' as class,
       pn.nspname::text                                      as function_schema,
       p.proname::text                                       as function_name,
       pg_catalog.pg_get_function_identity_arguments(p.oid)  as identity_args,
       pg_catalog.pg_get_function_result(p.oid)              as return_type,
       p.oid::text                                           as function_oid_trace_only,
       (pn.nspname = 'extensions')                           as is_expected_binding_target,
       current_setting('search_path')                        as session_search_path
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace pn on pn.oid = p.pronamespace
 where p.proname = 'uuid_generate_v4'
 order by 2, 1;

-- ── 3 · EXPECTED FUNCTION IDENTITY ──────────────────────────────────────────────────────────
select 'EXPECTED_FUNCTION' as class,
       pn.nspname::text                                      as namespace,
       p.proname::text                                       as name,
       pg_catalog.pg_get_function_identity_arguments(p.oid)  as identity_args,
       pg_catalog.pg_get_function_result(p.oid)              as result_type,
       l.lanname::text                                       as language,
       coalesce(e.extname::text,'(not an extension member)')  as provided_by_extension
  from pg_catalog.pg_proc p
  join pg_catalog.pg_namespace pn on pn.oid = p.pronamespace
  join pg_catalog.pg_language l on l.oid = p.prolang
  left join pg_catalog.pg_depend de on de.objid = p.oid and de.refclassid = 'pg_catalog.pg_extension'::regclass
  left join pg_catalog.pg_extension e on e.oid = de.refobjid
 where pn.nspname = 'extensions' and p.proname = 'uuid_generate_v4';

-- ── 4 · SUMMARY — with live controls, so a clean result cannot be a blind one ────────────────
with b as (
  select case when pn.nspname='extensions' and p.proname='uuid_generate_v4'
               and pg_catalog.pg_get_function_identity_arguments(p.oid)=''
               and pg_catalog.pg_get_function_result(p.oid)='uuid'
              then 1 else 0 end as ok
    from pg_catalog.pg_depend d
    join pg_catalog.pg_attrdef ad on ad.oid = d.objid
    join pg_catalog.pg_class c on c.oid = ad.adrelid
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    join pg_catalog.pg_proc p on p.oid = d.refobjid
    join pg_catalog.pg_namespace pn on pn.oid = p.pronamespace
   where d.classid='pg_catalog.pg_attrdef'::regclass
     and d.refclassid='pg_catalog.pg_proc'::regclass and n.nspname='public'
)
select 'SUMMARY' as class, k as check_name, e as expected, a as actual,
       case when e is not distinct from a then 'PASS' else 'FAIL' end as verdict
from (values
  ('ctl_function_dependency_rows_visible','14',(select count(*)::text from b)),
  ('ctl_expected_function_resolvable','true',(select (to_regprocedure('extensions.uuid_generate_v4()') is not null)::text)),
  ('ctl_shadow_candidates_enumerated','true',(select (count(*)>0)::text from pg_catalog.pg_proc p where p.proname='uuid_generate_v4')),
  ('bindings_to_extensions_uuid_generate_v4','14',(select sum(ok)::text from b)),
  ('bindings_elsewhere','0',(select (count(*)-sum(ok))::text from b))
) t(k,e,a);
