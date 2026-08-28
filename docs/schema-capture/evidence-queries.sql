-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- MODEL C FINAL EVIDENCE CAPTURE — READ-ONLY CATALOG QUERIES
--
-- RUN BY:      the user, manually, in the Supabase SQL Editor, project afterworth-dev
-- RUN BY AI:   NEVER. Nothing here has been executed.
-- WRITES:      none. Every statement is a SELECT against pg_catalog.
--
-- Purpose: close the two evidence gaps that block Model C implementation.
--   Q1  the event-trigger binding for public.rls_auto_enable  (absent from the schema dump)
--   Q2  the AfterWorth policies on storage.objects            (excluded from the schema dump)
--
-- Both gaps exist because `supabase db dump` excludes platform schemas and does not emit event
-- triggers. Their absence from the snapshot is therefore NOT evidence of absence in the database —
-- which is exactly why these queries exist rather than an inference.
-- ════════════════════════════════════════════════════════════════════════════════════════════════


-- ── Q1 · EVERY EVENT TRIGGER, NOT ONLY THE ONE WE EXPECT ────────────────────────────────────────
--
-- ★ IT DOES NOT ASSUME `rls_auto_enable` EXISTS. The query enumerates every event trigger in the
--   database and resolves each to its function. If the expected binding is absent, that absence is
--   then a fact about a complete listing rather than a failed lookup — the two are different
--   claims, and only the first can support "FUNCTION_ONLY_NO_BINDING".
--
-- ★ A ZERO-ROW RESULT IS AMBIGUOUS ON ITS OWN, so the query is paired with a positive control
--   (Q1b) proving the catalog is readable at all from the SQL Editor's role.
--
-- evtenabled decodes as:  O = enabled (origin)  ·  D = disabled  ·  R = replica  ·  A = always
select
  et.evtname                                        as event_trigger_name,
  et.evtevent                                       as event,
  et.evtenabled                                     as enabled_raw,
  case et.evtenabled
    when 'O' then 'enabled (origin)'
    when 'D' then 'DISABLED'
    when 'R' then 'enabled (replica only)'
    when 'A' then 'enabled (always)'
    else 'unknown'
  end                                               as enabled_state,
  et.evttags                                        as tag_filter,
  pg_catalog.pg_get_userbyid(et.evtowner)           as event_trigger_owner,
  et.evtfoid                                        as function_oid,
  fn_ns.nspname                                     as function_schema,
  fn.proname                                        as function_name,
  pg_catalog.pg_get_function_identity_arguments(fn.oid) as function_identity_args,
  lang.lanname                                      as function_language,
  fn.prosecdef                                      as security_definer,
  fn.proconfig                                      as function_config,
  pg_catalog.pg_get_userbyid(fn.proowner)           as function_owner,
  pg_catalog.pg_get_functiondef(fn.oid)             as function_definition
from pg_catalog.pg_event_trigger et
left join pg_catalog.pg_proc      fn     on fn.oid       = et.evtfoid
left join pg_catalog.pg_namespace fn_ns  on fn_ns.oid    = fn.pronamespace
left join pg_catalog.pg_language  lang   on lang.oid     = fn.prolang
order by et.evtname;


-- ── Q1b · POSITIVE CONTROL for Q1 ───────────────────────────────────────────────────────────────
--
-- ★ PROVE THE INSTRUMENT CAN SEE BEFORE TRUSTING THAT IT SAW NOTHING. If Q1 returns zero rows,
--   this distinguishes "there are no event triggers" from "this role cannot read the catalog".
--   The function is known to exist — it is in the verified snapshot — so a 0 here means the
--   control failed and Q1's emptiness proves nothing.
select
  (select count(*) from pg_catalog.pg_event_trigger)                       as total_event_triggers,
  (select count(*) from pg_catalog.pg_proc p
     join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'rls_auto_enable')          as rls_auto_enable_function_present,
  (select count(*) from pg_catalog.pg_proc p
     join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public')                                           as public_functions_visible,
  current_user                                                            as observed_as_role;


-- ── Q2 · EVERY POLICY ON storage.objects ────────────────────────────────────────────────────────
--
-- ★ ALL POLICIES ON THE TABLE, NOT ONLY THE TWO EXPECTED. Filtering to the two known names could
--   only ever confirm what we already believe; it could not reveal a third AfterWorth policy that
--   Model C would then silently omit. Completeness is the property being measured.
select
  p.schemaname,
  p.tablename,
  p.policyname,
  p.permissive,
  p.roles,
  p.cmd,
  p.qual,
  p.with_check
from pg_catalog.pg_policies p
where p.schemaname = 'storage'
  and p.tablename  = 'objects'
order by p.policyname;


-- ── Q2b · POSITIVE CONTROL + RLS ENABLE-STATE for storage.objects ────────────────────────────────
--
-- ★ POLICY EXISTENCE AND RLS ENFORCEMENT ARE TWO PROPERTIES. A table carrying policies with
--   rowsecurity = false enforces none of them. Both are captured, because Model C must reproduce
--   both and a bootstrap that restored policies onto an unenforced table would look correct.
select
  n.nspname                                          as schema_name,
  c.relname                                          as table_name,
  c.relrowsecurity                                   as rls_enabled,
  c.relforcerowsecurity                              as rls_forced,
  (select count(*) from pg_catalog.pg_policies pp
    where pp.schemaname = 'storage' and pp.tablename = 'objects')  as policy_count_on_objects,
  (select count(*) from pg_catalog.pg_policies pp
    where pp.schemaname = 'storage')                               as policy_count_whole_storage_schema
from pg_catalog.pg_class c
join pg_catalog.pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'storage' and c.relname = 'objects';
