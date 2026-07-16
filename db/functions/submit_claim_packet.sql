-- public.submit_claim_packet(p_estate, p_death_certificate_doc_id, p_executor_id_doc_id) -> uuid (claim_packets.id)
--
-- Slice C1 (migration 0023). The SOLE submit door for a death claim: a DESIGNATED EXECUTOR opens a
-- claim_packet. SECURITY DEFINER, gated inside (the DEFINER-door discipline). Submit AUTHORITY = an ACTIVE
-- executor/trustee DESIGNATION via is_estate_executor — NEVER a membership role (consumes the executor arc's
-- invariant; a revoked designee is rejected here exactly as at read time). Writes status='submitted' only;
-- reviewer decisions are 0024, the RELEASE transition is C5 (no 'released' logic here).
--
-- Idempotency: at most ONE ACTIVE (non-rejected) claim per estate — an in-RPC pre-check for a clean
-- 'active_claim_exists' error, backstopped by the partial-unique claim_packets_one_active_per_estate for
-- races. Supplied evidence docs are estate-scoped (a cross-estate doc ref is rejected). Audit: claim.submitted
-- (source='server'). Client-reachable to authenticated (never public/anon). Source of truth — re-apply on reset.

create or replace function public.submit_claim_packet(
  p_estate                    uuid,
  p_death_certificate_doc_id  uuid default null,
  p_executor_id_doc_id        uuid default null
)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_uid uuid := auth.uid(); v_id uuid;
begin
  if v_uid is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;
  if not public.is_estate_executor(p_estate, v_uid) then
    raise exception 'not_estate_executor' using errcode = '42501';
  end if;
  if not exists (select 1 from public.estates where id = p_estate) then
    raise exception 'estate_not_found' using errcode = 'P0002';
  end if;

  if p_death_certificate_doc_id is not null
     and not exists (select 1 from public.documents d where d.id = p_death_certificate_doc_id and d.estate_id = p_estate) then
    raise exception 'doc_not_in_estate' using errcode = 'P0001';
  end if;
  if p_executor_id_doc_id is not null
     and not exists (select 1 from public.documents d where d.id = p_executor_id_doc_id and d.estate_id = p_estate) then
    raise exception 'doc_not_in_estate' using errcode = 'P0001';
  end if;

  if exists (select 1 from public.claim_packets c where c.estate_id = p_estate and c.status <> 'rejected') then
    raise exception 'active_claim_exists' using errcode = 'P0001';
  end if;

  insert into public.claim_packets
    (estate_id, requested_by, status, death_certificate_doc_id, executor_id_doc_id, submitted_at)
  values
    (p_estate, v_uid, 'submitted', p_death_certificate_doc_id, p_executor_id_doc_id, now())
  returning id into v_id;

  perform public.write_audit('claim.submitted', 'claim_packets', v_id, p_estate,
    jsonb_build_object('claim_id', v_id,
      'has_death_cert', p_death_certificate_doc_id is not null,
      'has_executor_id', p_executor_id_doc_id is not null));

  return v_id;
end;
$function$;
revoke execute on function public.submit_claim_packet(uuid, uuid, uuid) from public, anon;
grant  execute on function public.submit_claim_packet(uuid, uuid, uuid) to authenticated;
