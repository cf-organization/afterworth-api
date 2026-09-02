-- U2 · SELECT-ONLY PRE-EXECUTION GATE.  PREPARED, NOT EXECUTED.
-- Target: afterworth-nonprod (qxzeougbaarecaiiqsay).  0 DDL · 0 DML · 0 GRANT/REVOKE · 0 SET ROLE.
--
-- ★ DUAL-PATH, and it gates on the SET of admissible prestates rather than one expected shape.
--   U1's first precheck gated on a single prestate and made its own RECOGNIZE path unreachable;
--   worse, five distinct states produced identical output. This reports WHICH state it found.
--     EXACT_PRESTATE   -> ELIGIBLE_APPLY
--     EXACT_POSTSTATE  -> ELIGIBLE_RECOGNIZE
--     anything else    -> HALT, naming the state
--
-- ★ ADVISORY ONLY. The migration re-classifies inside its own transaction under an ACCESS SHARE
--   lock and is the sole authority; a conflicting change between the two makes it HALT.
with p as (select pol.polname n, pol.polcmd::text cmd, pol.polpermissive perm, (pol.polroles = $${0}$$::oid[]) pub, coalesce(pg_catalog.pg_get_expr(pol.polqual,pol.polrelid),$$~$$) q, coalesce(pg_catalog.pg_get_expr(pol.polwithcheck,pol.polrelid),$$~$$) w from pg_catalog.pg_policy pol join pg_catalog.pg_class c on c.oid=pol.polrelid join pg_catalog.pg_namespace ns on ns.oid=c.relnamespace where ns.nspname=$$public$$ and c.relname=$$assets$$), agg as (select count(*) total, count(*) filter (where n=$$assets_read$$ and cmd=$$r$$ and perm and pub and q=$$((owner_id = auth.uid()) OR is_estate_member(estate_id))$$ and w=$$~$$) read_ok, count(*) filter (where n=$$assets_read$$) read_n, count(*) filter (where n=$$assets_write$$ and cmd=$$*$$ and perm and pub and q=$$(owner_id = auth.uid())$$ and w=$$(owner_id = auth.uid())$$) wpre, count(*) filter (where n=$$assets_write$$ and cmd=$$*$$ and perm and pub and q=$$(owner_id = auth.uid())$$ and w=$$((owner_id = auth.uid()) AND is_estate_owner(estate_id))$$) wpost, count(*) filter (where n=$$assets_write$$) write_n, count(*) filter (where n=$$assets_insert_require_estate_owner$$ and cmd=$$a$$ and not perm and pub and q=$$~$$ and w=$$is_estate_owner(estate_id)$$) ins_ok, count(*) filter (where n=$$assets_insert_require_estate_owner$$) ins_n, count(*) filter (where n=$$assets_update_require_estate_owner$$ and cmd=$$w$$ and not perm and pub and q=$$~$$ and w=$$is_estate_owner(estate_id)$$) upd_ok, count(*) filter (where n=$$assets_update_require_estate_owner$$) upd_n, count(*) filter (where n not in ($$assets_read$$,$$assets_write$$,$$assets_insert_require_estate_owner$$,$$assets_update_require_estate_owner$$)) alien from p), st as (select case when (select count(*) from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname=$$public$$ and c.relname=$$assets$$)<>1 or (select count(*) from pg_catalog.pg_proc pr join pg_catalog.pg_namespace n on n.oid=pr.pronamespace where n.nspname=$$public$$ and pr.proname in ($$is_estate_owner$$,$$is_estate_member$$))<>2 then $$INSTRUMENT_BROKEN$$ when alien>0 then $$DUPLICATE_OR_UNEXPECTED_ASSETS_POLICY$$ when read_n=0 then $$MISSING_ASSETS_READ$$ when write_n=0 then $$MISSING_ASSETS_WRITE$$ when read_ok<>1 then $$ASSETS_READ_DIFFERENT$$ when ins_n>0 and ins_ok=0 then $$INSERT_HARDENING_ALREADY_PRESENT_DIFFERENT$$ when upd_n>0 and upd_ok=0 then $$UPDATE_HARDENING_ALREADY_PRESENT_DIFFERENT$$ when wpre=1 and ins_n=0 and upd_n=0 and total=2 then $$EXACT_PRESTATE$$ when wpost=1 and ins_ok=1 and upd_ok=1 and total=4 then $$EXACT_POSTSTATE$$ when wpre=0 and wpost=0 then $$ASSETS_WRITE_DIFFERENT$$ else $$PARTIAL_HARDENING$$ end as state from agg), chk(class, check_name, expected, actual, gating) as (values
  ('CONTROL','pg_policy_readable',$$true$$,(select (count(*)>=0)::text from pg_catalog.pg_policy),true),
  ('CONTROL','assets_visible',$$1$$,(select count(*)::text from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='assets'),true),
  ('IDENTITY','current_user',$$postgres$$,current_user::text,true),
  ('PIN','target_project_ref',$$qxzeougbaarecaiiqsay$$,$$qxzeougbaarecaiiqsay$$,true),
  ('HELPER','is_estate_owner',$$1$$,(select count(*)::text from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='is_estate_owner'),true),
  ('HELPER','is_estate_member',$$1$$,(select count(*)::text from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='is_estate_member'),true),
  ('PRESTATE','policy_state_eligible',$$true$$,(select (state in ('EXACT_PRESTATE','EXACT_POSTSTATE'))::text from st),true),
  ('PRESTATE','policy_state',$$__RECORD__$$,(select state from st),false),
  ('PRESTATE','expected_migration_action',$$__RECORD__$$,(select case state when 'EXACT_PRESTATE' then 'APPLY' when 'EXACT_POSTSTATE' then 'RECOGNIZE' else 'NONE — HALT' end from st),false),
  ('PRESTATE','assets_policy_fingerprint',$$__RECORD__$$,(select coalesce(md5(string_agg(pol.polname||$$|$$||pol.polcmd::text||$$|$$||pol.polpermissive::text||$$|$$||(case when pol.polroles=$${0}$$::oid[] then $$PUBLIC$$ else coalesce(array_to_string(array(select rolname from pg_roles where oid=any(pol.polroles)),$$,$$),$$?$$) end)||$$|$$||coalesce(pg_catalog.pg_get_expr(pol.polqual,pol.polrelid),$$~$$)||$$|$$||coalesce(pg_catalog.pg_get_expr(pol.polwithcheck,pol.polrelid),$$~$$),$$,$$ order by pol.polname)),$$NONE$$) from pg_catalog.pg_policy pol join pg_catalog.pg_class c on c.oid=pol.polrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname=$$public$$ and c.relname=$$assets$$),false),
  ('RATCHET','client_row_dml_tables',$$0$$,(select count(*)::text from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace, (select rolname from pg_roles where rolname in ($$anon$$,$$authenticated$$,$$service_role$$)) r where n.nspname=$$public$$ and c.relname=$$assets$$ and (has_table_privilege(r.rolname,c.oid,$$SELECT$$) or has_table_privilege(r.rolname,c.oid,$$INSERT$$) or has_table_privilege(r.rolname,c.oid,$$UPDATE$$) or has_table_privilege(r.rolname,c.oid,$$DELETE$$))),true),
  ('METADATA','migration_metadata_tables',$$0$$,(select count(*)::text from information_schema.tables where table_schema='supabase_migrations'),true)
)
select class, check_name, expected, actual,
       case when not gating then 'RECORD' when actual is not distinct from expected then 'PASS' else 'FAIL' end as verdict
from chk
union all
select 'OVERALL','u2_precheck',$$PASS$$,
  (select case when count(*) filter (where gating and actual is distinct from expected)=0 then 'PASS' else 'FAIL:'||count(*) filter (where gating and actual is distinct from expected)::text end from chk),
  (select case when (select count(*) from chk where gating and actual is distinct from expected)>0 then 'HALT — state='||(select state from st)
               when (select state from st)='EXACT_PRESTATE' then 'ELIGIBLE_APPLY — pending explicit authorization'
               when (select state from st)='EXACT_POSTSTATE' then 'ELIGIBLE_RECOGNIZE — pending explicit authorization'
               else 'HALT' end);
