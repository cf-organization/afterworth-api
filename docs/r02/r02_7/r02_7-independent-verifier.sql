-- R02_7 · INDEPENDENT EQUIVALENCE VERIFIER.  SELECT-only.
--
-- ★ DELIBERATELY NOT THE PRIMARY COMPARATOR. It shares no CTE, view or normalization function with
--   r02_7-equivalence-verifier.sql. Where the primary builds md5 digests over string_agg of catalog
--   rows, this asserts named objects and decoded privileges directly:
--     · triggers      → pg_get_triggerdef() text, not tgtype bit arithmetic
--     · policies      → per-policy pg_get_expr assertions, not one aggregated digest
--     · privileges    → has_table_privilege(), not aclexplode over relacl
--     · tables/columns→ information_schema counts + explicit named-object existence
--   A defect in one decoding path is therefore unlikely to be shared by both.
--
-- ★ EVERY EXPECTED-EMPTY FAMILY IS PAIRED WITH A POSITIVE CONTROL. A verifier that returns zero
--   because it cannot see anything is indistinguishable from one that returns zero correctly.
with chk(class, check_name, expected, actual, gating) as (values
  -- ── POSITIVE CONTROLS: prove each instrument family is live ────────────────────────────────
  ('CONTROL','ctl_table_probe',$$1$$,(select count(*)::text from information_schema.tables where table_schema='public' and table_name='assets'),true),
  ('CONTROL','ctl_function_probe',$$1$$,(select count(*)::text from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='handle_new_user'),true),
  ('CONTROL','ctl_policy_probe',$$1$$,(select count(*)::text from pg_catalog.pg_policies where schemaname='public' and policyname='assets_read'),true),
  ('CONTROL','ctl_trigger_probe',$$1$$,(select count(*)::text from pg_catalog.pg_trigger t join pg_catalog.pg_class c on c.oid=t.tgrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='auth' and c.relname='users' and t.tgname='on_auth_user_created'),true),
  ('CONTROL','ctl_fk_probe',$$true$$,(select (count(*)>0)::text from pg_catalog.pg_constraint con join pg_catalog.pg_class c on c.oid=con.conrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and con.contype='f' and c.relname='assets'),true),
  ('CONTROL','ctl_index_probe',$$true$$,(select (count(*)>0)::text from pg_catalog.pg_indexes where schemaname='public'),true),
  ('CONTROL','ctl_privilege_probe',$$true$$,(select has_table_privilege('authenticated','public.estate_assets','SELECT')::text),true),
  -- ── POPULATION, via information_schema rather than pg_class digests ────────────────────────
  ('POP','ordinary_tables',$$41$$,(select count(*)::text from information_schema.tables where table_schema='public' and table_type='BASE TABLE'),true),
  ('POP','columns',$$415$$,(select count(*)::text from information_schema.columns where table_schema='public'),true),
  ('POP','functions',$$147$$,(select count(*)::text from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public'),true),
  ('POP','policies',$$38$$,(select count(*)::text from pg_catalog.pg_policies where schemaname='public'),true),
  ('POP','non_postgres_owned_tables',$$0$$,(select count(*)::text from pg_catalog.pg_tables where schemaname='public' and tableowner<>'postgres'),true),
  ('POP','foreign_keys',$$83$$,(select count(*)::text from pg_catalog.pg_constraint con join pg_catalog.pg_class c on c.oid=con.conrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and con.contype='f'),true),
  ('POP','rls_enabled_tables',$$41$$,(select count(*)::text from pg_catalog.pg_tables where schemaname='public' and rowsecurity),true),
  ('POP','storage_policies',$$2$$,(select count(*)::text from pg_catalog.pg_policies where schemaname='storage'),true),
  -- ── U1, via pg_get_triggerdef text ─────────────────────────────────────────────────────────
  ('U1','trigger_definition',$$CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION handle_new_user()$$,
      (select pg_catalog.pg_get_triggerdef(t.oid) from pg_catalog.pg_trigger t join pg_catalog.pg_class c on c.oid=t.tgrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='auth' and c.relname='users' and t.tgname='on_auth_user_created'),true),
  ('U1','trigger_enabled',$$O$$,(select t.tgenabled::text from pg_catalog.pg_trigger t join pg_catalog.pg_class c on c.oid=t.tgrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='auth' and c.relname='users' and t.tgname='on_auth_user_created'),true),
  ('U1','no_duplicate_auth_triggers',$$1$$,(select count(*)::text from pg_catalog.pg_trigger t join pg_catalog.pg_class c on c.oid=t.tgrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='auth' and c.relname='users' and not t.tgisinternal),true),
  -- ── U2, one assertion per policy ───────────────────────────────────────────────────────────
  ('U2','assets_policy_count',$$4$$,(select count(*)::text from pg_catalog.pg_policies where schemaname='public' and tablename='assets'),true),
  ('U2','assets_read',$$SELECT|PERMISSIVE|((owner_id = auth.uid()) OR is_estate_member(estate_id))|-$$,(select cmd||'|'||permissive||'|'||coalesce(qual,'-')||'|'||coalesce(with_check,'-') from pg_catalog.pg_policies where schemaname='public' and policyname='assets_read'),true),
  ('U2','assets_write',$$ALL|PERMISSIVE|(owner_id = auth.uid())|((owner_id = auth.uid()) AND is_estate_owner(estate_id))$$,(select cmd||'|'||permissive||'|'||coalesce(qual,'-')||'|'||coalesce(with_check,'-') from pg_catalog.pg_policies where schemaname='public' and policyname='assets_write'),true),
  ('U2','assets_insert_restrictive',$$INSERT|RESTRICTIVE|-|is_estate_owner(estate_id)$$,(select cmd||'|'||permissive||'|'||coalesce(qual,'-')||'|'||coalesce(with_check,'-') from pg_catalog.pg_policies where schemaname='public' and policyname='assets_insert_require_estate_owner'),true),
  ('U2','assets_update_restrictive',$$UPDATE|RESTRICTIVE|-|is_estate_owner(estate_id)$$,(select cmd||'|'||permissive||'|'||coalesce(qual,'-')||'|'||coalesce(with_check,'-') from pg_catalog.pg_policies where schemaname='public' and policyname='assets_update_require_estate_owner'),true),
  -- ── U3, via has_table_privilege rather than aclexplode ─────────────────────────────────────
  ('U3','anon_truncate_tables',$$0$$,(select count(*)::text from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r' and has_table_privilege('anon',c.oid,'TRUNCATE')),true),
  ('U3','authenticated_references_tables',$$0$$,(select count(*)::text from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r' and has_table_privilege('authenticated',c.oid,'REFERENCES')),true),
  ('U3','service_role_trigger_tables',$$0$$,(select count(*)::text from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r' and has_table_privilege('service_role',c.oid,'TRIGGER')),true),
  ('U3','any_client_maintain_tables',$$0$$,(select count(*)::text from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace, (values('anon'),('authenticated'),('service_role')) r(rn) where n.nspname='public' and c.relkind='r' and current_setting('server_version_num')::int>=170000 and has_table_privilege(r.rn,c.oid,'MAINTAIN')),true),
  ('U3','postgres_public_default_dxtm',$$0$$,(select count(*)::text from pg_catalog.pg_default_acl d, aclexplode(d.defaclacl) a where d.defaclobjtype='r' and pg_catalog.pg_get_userbyid(d.defaclrole)='postgres' and d.defaclnamespace='public'::regnamespace::oid and pg_catalog.pg_get_userbyid(a.grantee) in ('anon','authenticated','service_role') and a.privilege_type in ('TRUNCATE','REFERENCES','TRIGGER','MAINTAIN')),true),
  ('U3','postgres_global_default_dxtm',$$0$$,(select count(*)::text from pg_catalog.pg_default_acl d, aclexplode(d.defaclacl) a where d.defaclobjtype='r' and pg_catalog.pg_get_userbyid(d.defaclrole)='postgres' and d.defaclnamespace=0 and pg_catalog.pg_get_userbyid(a.grantee) in ('anon','authenticated','service_role') and a.privilege_type in ('TRUNCATE','REFERENCES','TRIGGER','MAINTAIN')),true),
  ('U3','client_row_dml_true_count',$$21$$,(select (count(*) filter (where has_table_privilege(r.rn,c.oid,'SELECT'))+count(*) filter (where has_table_privilege(r.rn,c.oid,'INSERT'))+count(*) filter (where has_table_privilege(r.rn,c.oid,'UPDATE'))+count(*) filter (where has_table_privilege(r.rn,c.oid,'DELETE')))::text from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace, (values('anon'),('authenticated'),('service_role')) r(rn) where n.nspname='public' and c.relkind='r'),true),
  ('V3COL','col_exact_type_typmod',$$numeric(5,2)$$,(select pg_catalog.format_type(a.atttypid,a.atttypmod) from pg_catalog.pg_attribute a join pg_catalog.pg_class c on c.oid=a.attrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='beneficiaries' and a.attname='allocation_percent'),true),
  ('V3COL','col_nullability_sample',$$true$$,(select a.attnotnull::text from pg_catalog.pg_attribute a join pg_catalog.pg_class c on c.oid=a.attrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='assets' and a.attname='estate_id'),true),
  ('V3COL','uuid_semantic_bindings',$$14$$,(select count(*)::text from pg_catalog.pg_depend d join pg_catalog.pg_attrdef ad on ad.oid=d.objid join pg_catalog.pg_class c on c.oid=ad.adrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace join pg_catalog.pg_proc p on p.oid=d.refobjid join pg_catalog.pg_namespace pn on pn.oid=p.pronamespace where d.classid='pg_catalog.pg_attrdef'::regclass and d.refclassid='pg_catalog.pg_proc'::regclass and n.nspname='public' and pn.nspname='extensions' and p.proname='uuid_generate_v4' and pg_catalog.pg_get_function_result(p.oid)='uuid'),true),
  ('V3COL','sequence_default_binding',$$public.audit_logs_id_seq$$,(select sqn.nspname||'.'||sq.relname from pg_catalog.pg_depend d join pg_catalog.pg_attrdef ad on ad.oid=d.objid join pg_catalog.pg_class c on c.oid=ad.adrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace join pg_catalog.pg_class sq on sq.oid=d.refobjid and sq.relkind='S' join pg_catalog.pg_namespace sqn on sqn.oid=sq.relnamespace where d.classid='pg_catalog.pg_attrdef'::regclass and n.nspname='public'),true),
  ('V3COL','identity_columns',$$0$$,(select count(*)::text from pg_catalog.pg_attribute a join pg_catalog.pg_class c on c.oid=a.attrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r' and a.attnum>0 and not a.attisdropped and a.attidentity<>''),true),
  ('V3COL','generated_columns',$$0$$,(select count(*)::text from pg_catalog.pg_attribute a join pg_catalog.pg_class c on c.oid=a.attrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relkind='r' and a.attnum>0 and not a.attisdropped and a.attgenerated<>''),true),
  ('V3COL','non_default_collations',$$0$$,(select count(*)::text from pg_catalog.pg_attribute a join pg_catalog.pg_class c on c.oid=a.attrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace join pg_catalog.pg_collation cl on cl.oid=a.attcollation where n.nspname='public' and c.relkind='r' and a.attnum>0 and not a.attisdropped and cl.collname<>'default'),true),
  ('PLATFORM','platform_default_acl_grantors',$$__RECORD__$$,(select coalesce(string_agg(distinct pg_catalog.pg_get_userbyid(d.defaclrole),', '),'(none)') from pg_catalog.pg_default_acl d where pg_catalog.pg_get_userbyid(d.defaclrole)<>'postgres'),false),
  ('PLATFORM','all_extensions',$$__RECORD__$$,(select string_agg(extname,', ' order by extname) from pg_catalog.pg_extension),false)
)
select class, check_name, expected, actual,
       case when not gating then 'RECORD' when actual is not distinct from expected then 'PASS' else 'FAIL' end as verdict
from chk
union all
select 'OVERALL','r02_7_independent',$$ALL_PASS$$,
  (select case when count(*) filter (where gating and actual is distinct from expected)=0 then 'ALL_PASS' else 'FAIL:'||count(*) filter (where gating and actual is distinct from expected)::text end from chk),
  (select case when count(*) filter (where gating and actual is distinct from expected)=0 then 'R02_7_INDEPENDENTLY_VERIFIED' else 'HALT — INVESTIGATE' end from chk);
