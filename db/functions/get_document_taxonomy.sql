-- public.get_document_taxonomy() -> jsonb
--
-- Migration 0036 — the CLIENT read path for the server-authoritative document taxonomy. Returns one payload:
--   { schema_version, vocabulary_version,
--     doc_types:     [{value, display_name, description, rank, sort_order, badge_color_key, icon_key}],
--     subtypes:      [{value, display_name, description, parent_doc_type, rank, sort_order, badge_color_key, icon_key}],
--     sensitivities: [{value, display_name, description, rank, sort_order, badge_color_key, icon_key}] }
-- ACTIVE values only (is_active). The client caches by vocabulary_version and refetches when it changes; it may
-- gate ONLY on schema_version. The taxonomy is NOT an attack map (generic category metadata; nothing sensitive
-- rides in `description`), so it is client-readable: EXECUTE authenticated, REVOKE public/anon. Supabase-direct
-- (no Vercel endpoint — the client calls it like get_upload_policy). Source of truth — re-apply on reset.

create or replace function public.get_document_taxonomy()
 returns jsonb
 language sql
 security definer
 stable
 set search_path to 'public'
as $function$
  select jsonb_build_object(
    'schema_version',     (select schema_version     from public.taxonomy_version where id = 1),
    'vocabulary_version', (select vocabulary_version from public.taxonomy_version where id = 1),
    'doc_types', coalesce((
      select jsonb_agg(jsonb_build_object(
        'value', value, 'display_name', display_name, 'description', description,
        'rank', rank, 'sort_order', sort_order, 'badge_color_key', badge_color_key, 'icon_key', icon_key)
        order by sort_order, value)
      from public.document_type where is_active), '[]'::jsonb),
    'subtypes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'value', subtype, 'display_name', display_name, 'description', description, 'parent_doc_type', parent_doc_type,
        'rank', rank, 'sort_order', sort_order, 'badge_color_key', badge_color_key, 'icon_key', icon_key)
        order by sort_order, subtype)
      from public.document_subtype where is_active), '[]'::jsonb),
    'sensitivities', coalesce((
      select jsonb_agg(jsonb_build_object(
        'value', value, 'display_name', display_name, 'description', description,
        'rank', rank, 'sort_order', sort_order, 'badge_color_key', badge_color_key, 'icon_key', icon_key)
        order by rank, value)
      from public.document_sensitivity where is_active), '[]'::jsonb)
  );
$function$;
revoke execute on function public.get_document_taxonomy() from public, anon;
grant  execute on function public.get_document_taxonomy() to authenticated;

-- Trigger fn: bumps taxonomy_version.vocabulary_version on any value change to the three taxonomy tables.
create or replace function public.bump_taxonomy_vocabulary_version()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  update public.taxonomy_version set vocabulary_version = vocabulary_version + 1, updated_at = now() where id = 1;
  return null;
end;
$function$;
-- Triggers (statement-level AFTER, created in 0036 AFTER the seed):
--   document_type_taxonomy_bump / document_subtype_taxonomy_bump / document_sensitivity_taxonomy_bump.
