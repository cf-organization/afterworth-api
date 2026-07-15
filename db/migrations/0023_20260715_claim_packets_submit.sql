-- 0023_20260715_claim_packets_submit — Slice C1 (part 1): activate claim_packets as a state machine, submit path.
--
-- claim_packets shipped as a DORMANT scaffold (Slice A capture): RLS enabled but NO client grants (no
-- PostgREST path), no writer, no transition enforcement. This migration wires the SUBMIT transition only:
-- a DESIGNATED EXECUTOR (authority from estate_designations via is_estate_executor — NEVER a membership
-- role) opens a claim through a SECURITY DEFINER RPC. Reviewer decisions are 0024 (Slice C1 part 2);
-- the RELEASE transition is Slice C5 (NOT here — no 'released' logic in this migration).
--
-- Access posture (consume the executor arc, don't rebuild):
--   * WRITES are RPC-only. submit_claim_packet is the sole submit door (gated inside, DEFINER-door
--     discipline); the table keeps NO client INSERT/UPDATE grant.
--   * READS are claimant-own via RLS: grant SELECT to authenticated + a claim_own_read policy
--     (requested_by = auth.uid()). Admins read via the DEFINER admin_list_claim_packets (0024), bypassing RLS.
--   * The two DORMANT capture-era policies are replaced: claim_estate_visible (owner OR any member — too
--     broad; a beneficiary must not see the executor's claim + its sensitive doc refs) and claim_insert_member
--     (moot — writes are RPC-only; a dead INSERT policy that looks like a gate is the anti-pattern). The
--     accurate live policy set becomes exactly one: claim_own_read.
--   * Idempotency: at most ONE ACTIVE (non-rejected) claim per estate — a partial-unique backstop for races
--     PLUS an in-RPC pre-check for a clean 'active_claim_exists' error. Rejected rows coexist (append-only
--     history — the revoked-designation precedent), so a rejected claim can be re-submitted.

begin;

-- ---- reads: claimant-own only (replace the over-broad / moot capture-era policies) ----
drop policy if exists claim_estate_visible on public.claim_packets;
drop policy if exists claim_insert_member  on public.claim_packets;
drop policy if exists claim_own_read       on public.claim_packets;  -- idempotent re-apply (no CREATE OR REPLACE POLICY)
create policy claim_own_read on public.claim_packets
  for select using (requested_by = auth.uid());
grant select on public.claim_packets to authenticated;   -- writes stay RPC-only (no insert/update grant)

-- ---- idempotency backstop: at most one non-rejected claim per estate ----
create unique index if not exists claim_packets_one_active_per_estate
  on public.claim_packets (estate_id) where status <> 'rejected';

-- ==================================================================================================
-- submit_claim_packet — a designated executor opens a claim. Gated inside; DEFINER (owner=postgres).
-- ==================================================================================================
create or replace function public.submit_claim_packet(
  p_estate                    uuid,
  p_death_certificate_doc_id  uuid default null,
  p_executor_id_doc_id        uuid default null
)
 returns uuid   -- claim_packets.id
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_uid uuid := auth.uid(); v_id uuid;
begin
  if v_uid is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;
  -- SUBMIT AUTHORITY = an ACTIVE executor/trustee DESIGNATION (never a membership role). is_estate_executor
  -- already requires status='active', so a revoked designee is rejected here just like at read time.
  if not public.is_estate_executor(p_estate, v_uid) then
    raise exception 'not_estate_executor' using errcode = '42501';
  end if;
  if not exists (select 1 from public.estates where id = p_estate) then
    raise exception 'estate_not_found' using errcode = 'P0002';
  end if;

  -- Structural binding: a supplied evidence doc must belong to THIS estate (blocks a cross-estate doc ref).
  if p_death_certificate_doc_id is not null
     and not exists (select 1 from public.documents d where d.id = p_death_certificate_doc_id and d.estate_id = p_estate) then
    raise exception 'doc_not_in_estate' using errcode = 'P0001';
  end if;
  if p_executor_id_doc_id is not null
     and not exists (select 1 from public.documents d where d.id = p_executor_id_doc_id and d.estate_id = p_estate) then
    raise exception 'doc_not_in_estate' using errcode = 'P0001';
  end if;

  -- Idempotency: at most one ACTIVE (non-rejected) claim per estate (clean error; the partial-unique backstops races).
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

commit;
