-- 0039_20260722_document_delete_replace — Vault document lifecycle: REPLACE + DELETE (recon-approved build).
--
-- LOCKED DESIGN (Christ, post-recon):
--  * HARD document deletion — the `documents` row is DELETEd (DEFINER, bypasses the 0030 write-lockdown). The
--    object then has no authoritative row, so the existing 72h orphan sweeper (0034) is the natural backstop —
--    ★ its predicate is UNCHANGED (we did NOT widen a proven security-adjacent mechanism).
--  * The authorized mutation + a durable purge-OUTBOX event commit in ONE tx (this function IS the tx). Byte
--    deletion runs POST-commit (client-immediate purge; a scheduled Vercel cron is the reliability backstop;
--    the 72h sweeper is the final catch-all). Sensitive bytes are NOT intentionally kept for the 72h window.
--  * Immutable audit TOMBSTONE (write_audit → append-only audit_logs, severity:high in metadata — audit_logs has
--    no severity column). The MUTABLE purge-status lifecycle lives in storage_deletion_outbox, NOT documents.
--  * REPLACE = atomically switch storage_path to the new object, THEN enqueue deletion of the FORMER object.
--    NO versioning — the old object is purged (a wrong replace is unrecoverable; the iOS slice warns).
--  * BLOCK permanent deletion (and replace, which also purges bytes) under: an ACTIVE CLAIM (claim_packets
--    evidence pin, status <> 'rejected'), a LEGAL HOLD (new legal_holds table), or MANDATORY RETENTION
--    (new documents.retention_until). Machine-readable reason codes: blocked_active_claim / blocked_legal_hold
--    / blocked_retention (raised as the exception MESSAGE, errcode P0001 — same message-as-code convention as
--    unknown_subtype). No block is a silent no-op: each queries a REAL, reachable source.
--  * ON DELETE SET NULL on the TWO claim_packets FKs ONLY — a REJECTED claim keeps its append-only history while
--    letting its (non-blocking) evidence doc be deleted; the RPC still rejects deletion for every ACTIVE state.
--
-- Endpoints: delete/replace/authorize_purge/record_purge_result/place_hold/release_hold are Supabase-direct
-- DEFINER RPCs (client.rpc), like create/update — NO new Vercel function (the api is 12/12). Byte purge needs the
-- service-role key (only the api holds it): a purge_document POST action + a GET cron drain ride the EXISTING
-- claims/[action].ts dispatcher (the sanctioned home for service-role storage ops — the sweep_orphans pattern).
--
-- Captured to VC: db/tables/{storage_deletion_outbox,legal_holds,documents(retention_until)}.sql,
-- db/functions/{delete_vault_document,replace_vault_document,authorize_purge,record_purge_result,
-- place_legal_hold,release_legal_hold}.sql.

begin;

-- ============================================================================================================
-- 1. storage_deletion_outbox — the durable purge queue + per-object purge-status lifecycle. Born clean (RLS on,
--    NO anon/authenticated grants). estate_id is DENORMALIZED so ownership survives the hard delete (the doc row
--    is gone). Drained by: (client) authorize_purge/record_purge_result DEFINER RPCs; (cron) service_role direct.
-- ============================================================================================================
create table if not exists public.storage_deletion_outbox (
  id           uuid        primary key default uuid_generate_v4(),
  estate_id    uuid        not null references public.estates(id) on delete cascade,
  bucket       text        not null default 'documents',
  object_path  text        not null,
  reason       text        not null check (reason in ('document_deleted','document_replaced')),
  requested_by uuid        not null references auth.users(id),
  requested_at timestamptz not null default now(),
  status       text        not null default 'pending' check (status in ('pending','purged','failed')),
  attempts     int         not null default 0,
  last_error   text,
  purged_at    timestamptz
);
-- Drain index: only rows still needing work (partial — purged rows drop out).
create index if not exists storage_deletion_outbox_unpurged_idx
  on public.storage_deletion_outbox (requested_at) where status <> 'purged';

alter table public.storage_deletion_outbox enable row level security;
-- Born clean: no anon/authenticated grants, no policies. The cron drains via service_role (explicit grant below);
-- the client path goes through the owner-gated DEFINER RPCs (which run as owner, independent of these grants).
grant select, update on public.storage_deletion_outbox to service_role;

-- ============================================================================================================
-- 2. legal_holds — append-only litigation-hold source. Born clean; placed/released via ADMIN-gated RPCs only
--    (the document owner must NOT be able to lift a hold against their own estate). "Active" = released_at IS
--    NULL. ON DELETE CASCADE: when a doc is legitimately deleted (no ACTIVE hold — the delete RPC guarantees it),
--    its released-hold history goes with it (the deletion is itself audited).
-- ============================================================================================================
create table if not exists public.legal_holds (
  id          uuid        primary key default uuid_generate_v4(),
  doc_id      uuid        not null references public.documents(id) on delete cascade,
  reason      text        not null,
  placed_by   uuid        not null references auth.users(id),
  placed_at   timestamptz not null default now(),
  released_at timestamptz,
  released_by uuid        references auth.users(id)
);
create index if not exists legal_holds_active_idx on public.legal_holds (doc_id) where released_at is null;

alter table public.legal_holds enable row level security;
-- Born clean: no client grants, no policies. Writes are DEFINER-RPC-only (place/release, admin-gated).

-- ============================================================================================================
-- 3. documents.retention_until — mandatory-retention floor. NULL = no retention (the common case). Deletion +
--    replace are blocked while retention_until > now(). Starts empty; a setter RPC/policy is a fast-follow — the
--    CHECK is a REAL, reachable predicate today (provable by setting the column), never a silent no-op.
-- ============================================================================================================
alter table public.documents add column if not exists retention_until timestamptz;

-- ============================================================================================================
-- 4. claim_packets FKs → ON DELETE SET NULL (the two evidence pins ONLY). A REJECTED claim (non-blocking) keeps
--    its history with a nulled evidence pointer when its doc is deleted; ACTIVE claims are rejected in the RPC
--    BEFORE any delete, so SET NULL never fires for them. Drop by catalog lookup (robust to the auto-gen name).
-- ============================================================================================================
do $$
declare v_con text;
begin
  select conname into v_con from pg_constraint
   where conrelid = 'public.claim_packets'::regclass and contype = 'f'
     and conkey = array[(select attnum from pg_attribute
                          where attrelid = 'public.claim_packets'::regclass and attname = 'death_certificate_doc_id')];
  if v_con is not null then execute format('alter table public.claim_packets drop constraint %I', v_con); end if;
end $$;
alter table public.claim_packets
  add constraint claim_packets_death_certificate_doc_id_fkey
  foreign key (death_certificate_doc_id) references public.documents(id) on delete set null;

do $$
declare v_con text;
begin
  select conname into v_con from pg_constraint
   where conrelid = 'public.claim_packets'::regclass and contype = 'f'
     and conkey = array[(select attnum from pg_attribute
                          where attrelid = 'public.claim_packets'::regclass and attname = 'executor_id_doc_id')];
  if v_con is not null then execute format('alter table public.claim_packets drop constraint %I', v_con); end if;
end $$;
alter table public.claim_packets
  add constraint claim_packets_executor_id_doc_id_fkey
  foreign key (executor_id_doc_id) references public.documents(id) on delete set null;

-- ============================================================================================================
-- 5. delete_vault_document — owner-gated HARD delete + blocking gauntlet + outbox enqueue + audit tombstone,
--    ALL in one tx. Returns the outbox id (for the client-immediate purge). Reason codes are the exception
--    MESSAGE (blocked_active_claim / blocked_legal_hold / blocked_retention).
-- ============================================================================================================
create or replace function public.delete_vault_document(p_doc_id uuid)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid    uuid := auth.uid();
  v_estate uuid;
  v_path   text;
  v_outbox uuid;
begin
  if v_uid is null then raise exception 'auth_required' using errcode = '42501'; end if;

  select estate_id, storage_path into v_estate, v_path from public.documents where id = p_doc_id;
  if not found then raise exception 'document_not_found' using errcode = 'P0002'; end if;
  if not public.is_estate_owner(v_estate) then raise exception 'not_estate_owner' using errcode = '42501'; end if;

  -- BLOCKING CONDITIONS (real sources; machine-readable messages). Order: active claim → legal hold → retention.
  if exists (select 1 from public.claim_packets c
             where (c.death_certificate_doc_id = p_doc_id or c.executor_id_doc_id = p_doc_id)
               and c.status <> 'rejected') then
    raise exception 'blocked_active_claim' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.legal_holds h where h.doc_id = p_doc_id and h.released_at is null) then
    raise exception 'blocked_legal_hold' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.documents d
             where d.id = p_doc_id and d.retention_until is not null and d.retention_until > now()) then
    raise exception 'blocked_retention' using errcode = 'P0001';
  end if;

  -- HARD delete (DEFINER = table owner → bypasses the RLS write-lockdown). Rejected-claim evidence FKs SET NULL.
  delete from public.documents where id = p_doc_id;

  -- Durable purge OUTBOX event — SAME TX (atomic with the delete). estate_id denormalized (doc row is gone).
  insert into public.storage_deletion_outbox (estate_id, bucket, object_path, reason, requested_by)
  values (v_estate, 'documents', v_path, 'document_deleted', v_uid)
  returning id into v_outbox;

  -- Immutable audit TOMBSTONE (high-sev). Metadata only — never document bytes.
  perform public.write_audit('document.deleted', 'documents', p_doc_id, v_estate,
    jsonb_build_object('severity', 'high', 'storage_path', v_path, 'reason', 'document_deleted',
                       'outbox_id', v_outbox, 'via', 'delete_vault_document'));

  return v_outbox;
end;
$function$;

revoke execute on function public.delete_vault_document(uuid) from public, anon;
grant  execute on function public.delete_vault_document(uuid) to authenticated;

-- ============================================================================================================
-- 6. replace_vault_document — atomically SWITCH storage_path to a new object (bytes-only: path/mime/size; title/
--    subtype/sensitivity untouched — use update_vault_document for those), THEN enqueue deletion of the FORMER
--    object. Same three blocks (replace PURGES the old bytes). New object: exists + policy-quota'd + path agrees
--    (estate + doc_id) + DIFFERS from the current object. Returns the outbox id.
-- ============================================================================================================
create or replace function public.replace_vault_document(
  p_doc_id           uuid,
  p_new_storage_path text
)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid       uuid := auth.uid();
  v_estate    uuid;
  v_old_path  text;
  v_size      bigint;
  v_mime      text;
  v_max_bytes bigint;
  v_mimes     text[];
  v_outbox    uuid;
begin
  if v_uid is null then raise exception 'auth_required' using errcode = '42501'; end if;

  select estate_id, storage_path into v_estate, v_old_path from public.documents where id = p_doc_id;
  if not found then raise exception 'document_not_found' using errcode = 'P0002'; end if;
  if not public.is_estate_owner(v_estate) then raise exception 'not_estate_owner' using errcode = '42501'; end if;

  -- Same blocking gauntlet (replace destroys the old bytes → an active claim / hold / retention must freeze them).
  if exists (select 1 from public.claim_packets c
             where (c.death_certificate_doc_id = p_doc_id or c.executor_id_doc_id = p_doc_id)
               and c.status <> 'rejected') then
    raise exception 'blocked_active_claim' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.legal_holds h where h.doc_id = p_doc_id and h.released_at is null) then
    raise exception 'blocked_legal_hold' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.documents d
             where d.id = p_doc_id and d.retention_until is not null and d.retention_until > now()) then
    raise exception 'blocked_retention' using errcode = 'P0001';
  end if;

  -- New path: estates/<estate>/vault/<doc_id>[-<token>].<ext>. Token allows a DISTINCT object so old+new coexist
  -- until the old is purged (kills traversal + ties the object to the doc). Must DIFFER from the current object.
  if p_new_storage_path !~ ('^estates/' || v_estate::text || '/vault/' || p_doc_id::text || '(-[a-zA-Z0-9]+)?\.[a-zA-Z0-9]+$') then
    raise exception 'vault_path_mismatch' using errcode = 'P0001';
  end if;
  if p_new_storage_path = v_old_path then
    raise exception 'replace_same_object' using errcode = 'P0001';
  end if;

  -- New object MUST already exist; size/mime authoritative from storage; policy quota (same source as create).
  select (o.metadata->>'size')::bigint, o.metadata->>'mimetype' into v_size, v_mime
    from storage.objects o where o.bucket_id = 'documents' and o.name = p_new_storage_path;
  if not found then raise exception 'vault_object_missing' using errcode = 'P0002'; end if;

  select max_upload_bytes, allowed_mime_types into v_max_bytes, v_mimes from public.upload_policy where id = 1;
  if coalesce(v_size, 0) > v_max_bytes then raise exception 'vault_too_large' using errcode = 'P0001'; end if;
  if v_mime is null or not (v_mime = any(v_mimes)) then raise exception 'vault_mime_rejected' using errcode = 'P0001'; end if;

  -- Atomically SWITCH to the new object (bytes-only).
  update public.documents
     set storage_path = p_new_storage_path, mime_type = v_mime, size_bytes = v_size
   where id = p_doc_id;

  -- Enqueue deletion of the FORMER object (same tx).
  insert into public.storage_deletion_outbox (estate_id, bucket, object_path, reason, requested_by)
  values (v_estate, 'documents', v_old_path, 'document_replaced', v_uid)
  returning id into v_outbox;

  perform public.write_audit('document.replaced', 'documents', p_doc_id, v_estate,
    jsonb_build_object('severity', 'high', 'old_path', v_old_path, 'new_path', p_new_storage_path,
                       'outbox_id', v_outbox, 'via', 'replace_vault_document'));

  return v_outbox;
end;
$function$;

revoke execute on function public.replace_vault_document(uuid, text) from public, anon;
grant  execute on function public.replace_vault_document(uuid, text) to authenticated;

-- ============================================================================================================
-- 7. authorize_purge — the CLIENT-immediate drain gate. Owner-gated on the outbox row's (denormalized) estate;
--    bumps attempts; returns the object to remove. Excludes already-purged rows (idempotency: a purged row can
--    never be re-authorized). Distinct OUT names (v_bucket/v_path) avoid the RETURNS TABLE column-shadow trap.
-- ============================================================================================================
create or replace function public.authorize_purge(p_outbox_id uuid)
 returns table(v_bucket text, v_path text)
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_estate uuid;
begin
  if auth.uid() is null then raise exception 'auth_required' using errcode = '42501'; end if;
  select o.estate_id into v_estate
    from public.storage_deletion_outbox o where o.id = p_outbox_id and o.status <> 'purged';
  if not found then raise exception 'outbox_not_found_or_purged' using errcode = 'P0002'; end if;
  if not public.is_estate_owner(v_estate) then raise exception 'not_estate_owner' using errcode = '42501'; end if;

  update public.storage_deletion_outbox set attempts = attempts + 1 where id = p_outbox_id;
  return query
    select o.bucket, o.object_path from public.storage_deletion_outbox o where o.id = p_outbox_id;
end;
$function$;

revoke execute on function public.authorize_purge(uuid) from public, anon;
grant  execute on function public.authorize_purge(uuid) to authenticated;

-- ============================================================================================================
-- 8. record_purge_result — the CLIENT-immediate drain result. Owner-gated. Idempotent: ok → purged; not-ok →
--    failed + last_error (re-drainable). "Object already gone" is treated as SUCCESS by the caller (storage
--    remove of a missing key is a no-op), so a purge that half-completed converges to 'purged' on retry.
-- ============================================================================================================
create or replace function public.record_purge_result(
  p_outbox_id uuid,
  p_ok        boolean,
  p_error     text default null
)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_estate uuid;
begin
  if auth.uid() is null then raise exception 'auth_required' using errcode = '42501'; end if;
  select estate_id into v_estate from public.storage_deletion_outbox where id = p_outbox_id;
  if not found then raise exception 'outbox_not_found' using errcode = 'P0002'; end if;
  if not public.is_estate_owner(v_estate) then raise exception 'not_estate_owner' using errcode = '42501'; end if;

  if p_ok then
    update public.storage_deletion_outbox
       set status = 'purged', purged_at = now(), last_error = null where id = p_outbox_id;
  else
    update public.storage_deletion_outbox
       set status = 'failed', last_error = left(coalesce(p_error, 'unknown'), 500) where id = p_outbox_id;
  end if;
end;
$function$;

revoke execute on function public.record_purge_result(uuid, boolean, text) from public, anon;
grant  execute on function public.record_purge_result(uuid, boolean, text) to authenticated;

-- ============================================================================================================
-- 9. place_legal_hold / release_legal_hold — ADMIN-gated (admin_require_gate: auth→is_admin→aal2→freshness).
--    The document owner must NOT lift a hold on their own estate. Both write a high-sev audit.
-- ============================================================================================================
create or replace function public.place_legal_hold(p_doc_id uuid, p_reason text)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_id uuid; v_estate uuid;
begin
  perform public.admin_require_gate();
  select estate_id into v_estate from public.documents where id = p_doc_id;
  if not found then raise exception 'document_not_found' using errcode = 'P0002'; end if;
  if p_reason is null or length(btrim(p_reason)) = 0 then raise exception 'reason_required' using errcode = 'P0001'; end if;

  insert into public.legal_holds (doc_id, reason, placed_by)
  values (p_doc_id, btrim(p_reason), auth.uid()) returning id into v_id;

  perform public.write_audit('document.legal_hold_placed', 'documents', p_doc_id, v_estate,
    jsonb_build_object('severity', 'high', 'hold_id', v_id, 'reason', btrim(p_reason)));
  return v_id;
end;
$function$;

revoke execute on function public.place_legal_hold(uuid, text) from public, anon;
grant  execute on function public.place_legal_hold(uuid, text) to authenticated;

create or replace function public.release_legal_hold(p_hold_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_doc uuid; v_estate uuid;
begin
  perform public.admin_require_gate();
  select doc_id into v_doc from public.legal_holds where id = p_hold_id and released_at is null;
  if not found then raise exception 'hold_not_found_or_released' using errcode = 'P0002'; end if;

  update public.legal_holds set released_at = now(), released_by = auth.uid() where id = p_hold_id;

  select estate_id into v_estate from public.documents where id = v_doc;
  perform public.write_audit('document.legal_hold_released', 'documents', v_doc, v_estate,
    jsonb_build_object('severity', 'high', 'hold_id', p_hold_id));
end;
$function$;

revoke execute on function public.release_legal_hold(uuid) from public, anon;
grant  execute on function public.release_legal_hold(uuid) to authenticated;

commit;
