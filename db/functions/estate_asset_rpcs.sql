-- Estate-asset RPCs — migration 0048 (Phase 9). Source of truth; re-apply on reset.
--
-- Owner-gated DEFINER doors for the MANUAL estate inventory. Every one of them:
--   * resolves the row FIRST and gates on the ROW's estate_id, never on a caller-supplied estate;
--   * raises machine-readable sentinels as the exception MESSAGE (errcode P0001/P0002/42501), the
--     same message-as-code convention as `unknown_subtype`;
--   * writes an audit entry naming the CHANGED FIELDS, never their values — an asset's value, notes
--     and reference hint must not be reconstructable from the audit log.
--
-- ★ THE CATEGORY IS DERIVED FROM THE SUBTYPE, NEVER ACCEPTED FROM THE CALLER. Taking both would let a
-- client persist a (category, subtype) pair the catalog contradicts — a persist-both taxonomy is only
-- trustworthy if exactly one of the pair is authoritative and the other is looked up.

-- ---------------------------------------------------------------------------------------------
-- get_estate_asset_taxonomy() -> jsonb  — the client read path for the asset vocabulary
-- ---------------------------------------------------------------------------------------------
-- ACTIVE values only, so presence in the payload IS the active-validation fact (no client is_active
-- check to forget). Shares `taxonomy_version` with the document catalogs so one version bump
-- invalidates one client cache.
create or replace function public.get_estate_asset_taxonomy()
 returns jsonb
 language sql
 security definer
 stable
 set search_path to 'public'
as $function$
  select jsonb_build_object(
    'schema_version',     (select schema_version     from public.taxonomy_version where id = 1),
    'vocabulary_version', (select vocabulary_version from public.taxonomy_version where id = 1),
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object(
        'value', value, 'display_name', display_name, 'description', description,
        'sort_order', sort_order, 'icon_key', icon_key, 'is_physical', is_physical)
        order by sort_order, value)
      from public.estate_asset_category where is_active), '[]'::jsonb),
    'subtypes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'value', subtype, 'display_name', display_name, 'description', description,
        'parent_category', parent_category, 'sort_order', sort_order, 'icon_key', icon_key)
        order by sort_order, subtype)
      from public.estate_asset_subtype where is_active), '[]'::jsonb)
  );
$function$;
revoke execute on function public.get_estate_asset_taxonomy() from public, anon;
grant  execute on function public.get_estate_asset_taxonomy() to authenticated;

-- ---------------------------------------------------------------------------------------------
-- create_estate_asset(...) -> uuid
-- ---------------------------------------------------------------------------------------------
create or replace function public.create_estate_asset(
  p_estate                  uuid,
  p_subtype                 text,
  p_label                   text,
  p_sensitivity             text    default null,
  p_owner_label             text    default null,
  p_country_code            text    default null,
  p_jurisdiction            text    default null,
  p_institution_name        text    default null,
  p_reference_hint          text    default null,
  p_approximate_value_cents bigint  default null,
  p_currency                text    default null,
  p_notes                   text    default null,
  p_beneficiary_note        text    default null
)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid      uuid := auth.uid();
  v_category text;
  v_sens     text;
  v_cur      text;
  v_id       uuid;
begin
  if v_uid is null then raise exception 'auth_required' using errcode = '42501'; end if;
  if not public.is_estate_owner(p_estate) then raise exception 'not_estate_owner' using errcode = '42501'; end if;

  if p_label is null or length(btrim(p_label)) = 0 then
    raise exception 'label_required' using errcode = 'P0001';
  end if;
  if length(p_label) > 200 then
    raise exception 'label_too_long' using errcode = 'P0001';
  end if;

  -- Catalog interrogation. An unknown or retired subtype is refused BEFORE any row exists — the
  -- Vault lesson: a rejection that lands after the write leaves an orphan behind.
  select s.parent_category into v_category
    from public.estate_asset_subtype s
    where s.subtype = p_subtype and s.is_active;
  if not found then
    if exists (select 1 from public.estate_asset_subtype where subtype = p_subtype) then
      raise exception 'inactive_subtype' using errcode = 'P0001';
    else
      raise exception 'unknown_subtype' using errcode = 'P0001';
    end if;
  end if;

  -- Sensitivity defaults to the most protective level, and an explicit value is validated against the
  -- SAME catalog documents use. There is no fallback: an unknown value is refused, never coerced.
  v_sens := coalesce(p_sensitivity, 'sealed');
  if not exists (select 1 from public.document_sensitivity where value = v_sens and is_active) then
    raise exception 'invalid_sensitivity' using errcode = 'P0001';
  end if;

  v_cur := upper(coalesce(p_currency, 'USD'));
  if v_cur !~ '^[A-Z]{3}$' then raise exception 'invalid_currency' using errcode = 'P0001'; end if;

  if p_approximate_value_cents is not null and p_approximate_value_cents < 0 then
    raise exception 'invalid_value' using errcode = 'P0001';
  end if;
  if p_reference_hint is not null and length(p_reference_hint) > 12 then
    -- The column CHECK would refuse this too; raising here turns a constraint violation into a
    -- sentinel the client can explain.
    raise exception 'reference_hint_too_long' using errcode = 'P0001';
  end if;

  -- ★ THIS CHECK WAS MISSING, AND ITS ABSENCE LEAKED THE WHOLE ROW. `update_estate_asset` validated
  -- the country code and this function did not, so a bad code fell through to the column CHECK —
  -- and a Postgres constraint violation carries `DETAIL: Failing row contains (…)`, i.e. the
  -- approximate value, the notes, the beneficiary note and the reference hint, into the server log
  -- and into any error telemetry downstream. The client maps the unrecognized message to `unknown`
  -- and shows nothing, which is exactly why this would never have been noticed from the app.
  --
  -- Every user-supplied field on this path is now validated BEFORE the insert, so a constraint
  -- violation here means a genuine bug rather than ordinary bad input.
  if p_country_code is not null and btrim(p_country_code) <> ''
     and upper(btrim(p_country_code)) !~ '^[A-Z]{2}$' then
    raise exception 'invalid_country_code' using errcode = 'P0001';
  end if;

  insert into public.estate_assets (
    estate_id, created_by, category, subtype, label, sensitivity, owner_label, country_code,
    jurisdiction, institution_name, reference_hint, approximate_value_cents, currency, notes,
    beneficiary_note
  ) values (
    p_estate, v_uid, v_category, p_subtype, btrim(p_label), v_sens, p_owner_label,
    nullif(upper(btrim(coalesce(p_country_code, ''))), ''), p_jurisdiction, p_institution_name,
    p_reference_hint, p_approximate_value_cents, v_cur, p_notes, p_beneficiary_note
  ) returning id into v_id;

  -- FIELD NAMES ONLY. An estate's asset values must not be reconstructable from audit_logs.
  perform public.write_audit('estate_asset.created', 'estate_assets', v_id, p_estate,
    jsonb_build_object('category', v_category, 'subtype', p_subtype, 'sensitivity', v_sens,
                       'via', 'create_estate_asset'));
  return v_id;
end;
$function$;
revoke execute on function public.create_estate_asset(uuid, text, text, text, text, text, text, text, text, bigint, text, text, text) from public, anon;
grant  execute on function public.create_estate_asset(uuid, text, text, text, text, text, text, text, text, bigint, text, text, text) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- update_estate_asset(...) -> void  — METADATA ONLY
-- ---------------------------------------------------------------------------------------------
-- ★ THE IMMUTABLE FIELDS ARE UNREPRESENTABLE. `estate_id`, `created_by` and `created_at` are not
-- parameters, so a caller cannot move an asset to another estate or rewrite its provenance — the
-- strongest form of "rejected", exactly as `update_vault_document` treats storage_path.
--
-- ★ NULL MEANS "LEAVE ALONE", so a client may send only what changed. The consequence is that a
-- nullable field cannot be CLEARED through this door; `p_clear` names the fields to blank, which
-- keeps "unset it" explicit instead of overloading NULL with two meanings.
create or replace function public.update_estate_asset(
  p_asset_id                uuid,
  p_subtype                 text    default null,
  p_label                   text    default null,
  p_sensitivity             text    default null,
  p_owner_label             text    default null,
  p_country_code            text    default null,
  p_jurisdiction            text    default null,
  p_institution_name        text    default null,
  p_reference_hint          text    default null,
  p_approximate_value_cents bigint  default null,
  p_currency                text    default null,
  p_notes                   text    default null,
  p_beneficiary_note        text    default null,
  p_verification_status     text    default null,
  p_clear                   text[]  default null
)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid      uuid := auth.uid();
  v_estate   uuid;
  v_arch     timestamptz;
  v_category text;
  v_changed  text[] := '{}';
  v_field    text;
begin
  if v_uid is null then raise exception 'auth_required' using errcode = '42501'; end if;

  select estate_id, archived_at into v_estate, v_arch from public.estate_assets where id = p_asset_id;
  if not found then raise exception 'asset_not_found' using errcode = 'P0002'; end if;
  if not public.is_estate_owner(v_estate) then raise exception 'not_estate_owner' using errcode = '42501'; end if;
  -- An archived asset is restored before it is edited. Editing something the owner has removed from
  -- the inventory would silently resurrect it in every list that filters on archived_at.
  if v_arch is not null then raise exception 'asset_archived' using errcode = 'P0001'; end if;

  if p_subtype is null and p_label is null and p_sensitivity is null and p_owner_label is null
     and p_country_code is null and p_jurisdiction is null and p_institution_name is null
     and p_reference_hint is null and p_approximate_value_cents is null and p_currency is null
     and p_notes is null and p_beneficiary_note is null and p_verification_status is null
     and (p_clear is null or array_length(p_clear, 1) is null) then
    raise exception 'no_fields_to_update' using errcode = 'P0001';
  end if;

  if p_label is not null then
    if length(btrim(p_label)) = 0 then raise exception 'label_required' using errcode = 'P0001'; end if;
    if length(p_label) > 200 then raise exception 'label_too_long' using errcode = 'P0001'; end if;
    update public.estate_assets set label = btrim(p_label) where id = p_asset_id;
    v_changed := array_append(v_changed, 'label');
  end if;

  if p_subtype is not null then
    select s.parent_category into v_category
      from public.estate_asset_subtype s where s.subtype = p_subtype and s.is_active;
    if not found then
      if exists (select 1 from public.estate_asset_subtype where subtype = p_subtype) then
        raise exception 'inactive_subtype' using errcode = 'P0001';
      else
        raise exception 'unknown_subtype' using errcode = 'P0001';
      end if;
    end if;
    -- The category is RE-DERIVED, never taken from the caller — the pair cannot be made inconsistent.
    update public.estate_assets set subtype = p_subtype, category = v_category where id = p_asset_id;
    v_changed := array_append(v_changed, 'subtype');
    v_changed := array_append(v_changed, 'category');
  end if;

  if p_sensitivity is not null then
    if not exists (select 1 from public.document_sensitivity where value = p_sensitivity and is_active) then
      raise exception 'invalid_sensitivity' using errcode = 'P0001';
    end if;
    update public.estate_assets set sensitivity = p_sensitivity where id = p_asset_id;
    v_changed := array_append(v_changed, 'sensitivity');
  end if;

  if p_verification_status is not null then
    if p_verification_status not in ('unverified','ownerAsserted','documented','verified') then
      raise exception 'invalid_verification_status' using errcode = 'P0001';
    end if;
    update public.estate_assets set verification_status = p_verification_status where id = p_asset_id;
    v_changed := array_append(v_changed, 'verification_status');
  end if;

  if p_currency is not null then
    if upper(p_currency) !~ '^[A-Z]{3}$' then raise exception 'invalid_currency' using errcode = 'P0001'; end if;
    update public.estate_assets set currency = upper(p_currency) where id = p_asset_id;
    v_changed := array_append(v_changed, 'currency');
  end if;

  if p_approximate_value_cents is not null then
    if p_approximate_value_cents < 0 then raise exception 'invalid_value' using errcode = 'P0001'; end if;
    update public.estate_assets set approximate_value_cents = p_approximate_value_cents where id = p_asset_id;
    v_changed := array_append(v_changed, 'approximate_value_cents');
  end if;

  if p_reference_hint is not null then
    if length(p_reference_hint) > 12 then raise exception 'reference_hint_too_long' using errcode = 'P0001'; end if;
    update public.estate_assets set reference_hint = p_reference_hint where id = p_asset_id;
    v_changed := array_append(v_changed, 'reference_hint');
  end if;

  if p_country_code is not null then
    if upper(btrim(p_country_code)) !~ '^[A-Z]{2}$' then
      raise exception 'invalid_country_code' using errcode = 'P0001';
    end if;
    update public.estate_assets set country_code = upper(btrim(p_country_code)) where id = p_asset_id;
    v_changed := array_append(v_changed, 'country_code');
  end if;

  if p_owner_label is not null then
    update public.estate_assets set owner_label = p_owner_label where id = p_asset_id;
    v_changed := array_append(v_changed, 'owner_label');
  end if;
  if p_jurisdiction is not null then
    update public.estate_assets set jurisdiction = p_jurisdiction where id = p_asset_id;
    v_changed := array_append(v_changed, 'jurisdiction');
  end if;
  if p_institution_name is not null then
    update public.estate_assets set institution_name = p_institution_name where id = p_asset_id;
    v_changed := array_append(v_changed, 'institution_name');
  end if;
  if p_notes is not null then
    update public.estate_assets set notes = p_notes where id = p_asset_id;
    v_changed := array_append(v_changed, 'notes');
  end if;
  if p_beneficiary_note is not null then
    update public.estate_assets set beneficiary_note = p_beneficiary_note where id = p_asset_id;
    v_changed := array_append(v_changed, 'beneficiary_note');
  end if;

  -- Explicit clearing. Only genuinely optional columns are clearable — `label`, `subtype`,
  -- `category`, `sensitivity` and `currency` are NOT NULL and are absent from this list by design.
  if p_clear is not null then
    foreach v_field in array p_clear loop
      case v_field
        when 'owner_label'             then update public.estate_assets set owner_label = null where id = p_asset_id;
        when 'country_code'            then update public.estate_assets set country_code = null where id = p_asset_id;
        when 'jurisdiction'            then update public.estate_assets set jurisdiction = null where id = p_asset_id;
        when 'institution_name'        then update public.estate_assets set institution_name = null where id = p_asset_id;
        when 'reference_hint'          then update public.estate_assets set reference_hint = null where id = p_asset_id;
        when 'approximate_value_cents' then update public.estate_assets set approximate_value_cents = null where id = p_asset_id;
        when 'notes'                   then update public.estate_assets set notes = null where id = p_asset_id;
        when 'beneficiary_note'        then update public.estate_assets set beneficiary_note = null where id = p_asset_id;
        else raise exception 'unclearable_field' using errcode = 'P0001';
      end case;
      v_changed := array_append(v_changed, 'cleared:' || v_field);
    end loop;
  end if;

  update public.estate_assets set updated_at = now() where id = p_asset_id;

  perform public.write_audit('estate_asset.updated', 'estate_assets', p_asset_id, v_estate,
    jsonb_build_object('changed', to_jsonb(v_changed), 'via', 'update_estate_asset'));
end;
$function$;
revoke execute on function public.update_estate_asset(uuid, text, text, text, text, text, text, text, text, bigint, text, text, text, text, text[]) from public, anon;
grant  execute on function public.update_estate_asset(uuid, text, text, text, text, text, text, text, text, bigint, text, text, text, text, text[]) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- archive_estate_asset / restore_estate_asset -> void  — the SOFT delete pair
-- ---------------------------------------------------------------------------------------------
-- ★ NOTHING IS DESTROYED AND NOTHING IS DETACHED. Archiving sets a timestamp; attached documents keep
-- their own hard-delete lifecycle untouched. This is the owner-approved asymmetry with documents: a
-- document's irreversibility is justified by a storage-byte purge, and an asset has no bytes.
create or replace function public.archive_estate_asset(p_asset_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid    uuid := auth.uid();
  v_estate uuid;
  v_arch   timestamptz;
begin
  if v_uid is null then raise exception 'auth_required' using errcode = '42501'; end if;
  select estate_id, archived_at into v_estate, v_arch from public.estate_assets where id = p_asset_id;
  if not found then raise exception 'asset_not_found' using errcode = 'P0002'; end if;
  if not public.is_estate_owner(v_estate) then raise exception 'not_estate_owner' using errcode = '42501'; end if;
  -- Idempotent by refusal rather than by silence: a no-op success would tell the client the state
  -- changed when it did not.
  if v_arch is not null then raise exception 'already_archived' using errcode = 'P0001'; end if;

  update public.estate_assets
     set archived_at = now(), archived_by = v_uid, updated_at = now()
   where id = p_asset_id;

  perform public.write_audit('estate_asset.archived', 'estate_assets', p_asset_id, v_estate,
    jsonb_build_object('via', 'archive_estate_asset'));
end;
$function$;
revoke execute on function public.archive_estate_asset(uuid) from public, anon;
grant  execute on function public.archive_estate_asset(uuid) to authenticated;

create or replace function public.restore_estate_asset(p_asset_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid    uuid := auth.uid();
  v_estate uuid;
  v_arch   timestamptz;
begin
  if v_uid is null then raise exception 'auth_required' using errcode = '42501'; end if;
  select estate_id, archived_at into v_estate, v_arch from public.estate_assets where id = p_asset_id;
  if not found then raise exception 'asset_not_found' using errcode = 'P0002'; end if;
  if not public.is_estate_owner(v_estate) then raise exception 'not_estate_owner' using errcode = '42501'; end if;
  if v_arch is null then raise exception 'not_archived' using errcode = 'P0001'; end if;

  update public.estate_assets
     set archived_at = null, archived_by = null, updated_at = now()
   where id = p_asset_id;

  perform public.write_audit('estate_asset.restored', 'estate_assets', p_asset_id, v_estate,
    jsonb_build_object('via', 'restore_estate_asset'));
end;
$function$;
revoke execute on function public.restore_estate_asset(uuid) from public, anon;
grant  execute on function public.restore_estate_asset(uuid) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- link_asset_document / unlink_asset_document -> void
-- ---------------------------------------------------------------------------------------------
-- ★ BOTH SIDES ARE OWNERSHIP-CHECKED, AND BOTH MUST BE THE SAME ESTATE. Checking only the asset would
-- let an owner attach a document from an estate they do not own — the join row itself grants nothing,
-- but it would leak the document's EXISTENCE into a surface they control.
create or replace function public.link_asset_document(p_asset_id uuid, p_doc_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid        uuid := auth.uid();
  v_asset_est  uuid;
  v_doc_est    uuid;
begin
  if v_uid is null then raise exception 'auth_required' using errcode = '42501'; end if;

  select estate_id into v_asset_est from public.estate_assets where id = p_asset_id;
  if not found then raise exception 'asset_not_found' using errcode = 'P0002'; end if;
  select estate_id into v_doc_est from public.documents where id = p_doc_id;
  if not found then raise exception 'document_not_found' using errcode = 'P0002'; end if;

  if not public.is_estate_owner(v_asset_est) then raise exception 'not_estate_owner' using errcode = '42501'; end if;
  if v_asset_est <> v_doc_est then raise exception 'cross_estate_link' using errcode = '42501'; end if;

  insert into public.estate_asset_documents (asset_id, doc_id, linked_by)
  values (p_asset_id, p_doc_id, v_uid)
  on conflict (asset_id, doc_id) do nothing;

  perform public.write_audit('estate_asset.document_linked', 'estate_assets', p_asset_id, v_asset_est,
    jsonb_build_object('doc_id', p_doc_id, 'via', 'link_asset_document'));
end;
$function$;
revoke execute on function public.link_asset_document(uuid, uuid) from public, anon;
grant  execute on function public.link_asset_document(uuid, uuid) to authenticated;

create or replace function public.unlink_asset_document(p_asset_id uuid, p_doc_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid       uuid := auth.uid();
  v_asset_est uuid;
begin
  if v_uid is null then raise exception 'auth_required' using errcode = '42501'; end if;
  select estate_id into v_asset_est from public.estate_assets where id = p_asset_id;
  if not found then raise exception 'asset_not_found' using errcode = 'P0002'; end if;
  if not public.is_estate_owner(v_asset_est) then raise exception 'not_estate_owner' using errcode = '42501'; end if;

  delete from public.estate_asset_documents where asset_id = p_asset_id and doc_id = p_doc_id;

  -- ★ UNLINKING DELETES NO BYTES AND NO DOCUMENT ROW. Detaching evidence from an asset is an
  -- organisational act; removing the document itself remains `delete_vault_document`, with its own
  -- blocking gauntlet and purge outbox.
  perform public.write_audit('estate_asset.document_unlinked', 'estate_assets', p_asset_id, v_asset_est,
    jsonb_build_object('doc_id', p_doc_id, 'via', 'unlink_asset_document'));
end;
$function$;
revoke execute on function public.unlink_asset_document(uuid, uuid) from public, anon;
grant  execute on function public.unlink_asset_document(uuid, uuid) to authenticated;
