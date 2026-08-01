-- 0043_20260801_invitation_delivery_worker — the delivery state machine 0042 left unbuilt.
--
-- 0042 IS APPLIED AND IS IMMUTABLE HISTORY. Nothing here edits or reapplies it. This migration is
-- additive: new columns, a widened status vocabulary, and worker-only functions. The one 0042
-- function that is REPLACED (list_estate_invitations) is replaced only to keep its documented
-- delivery_state contract truthful once the vocabulary widens — see §2.
--
-- ★ THE FINDING THIS MIGRATION EXISTS TO CORRECT.
--
-- 0042's issue_invitation_delivery() mints a fresh token and overwrites invitations.token_hash on
-- EVERY call — its header states this as intended ("Rotation is inherent"). That is right for a
-- deliberate redelivery and WRONG for a retry: a cron retry would silently invalidate a link that
-- may already be sitting in the recipient's inbox. So the fused operation is split here:
--
--     claim  — take a row, mint NOTHING
--     issue  — mint a token, and ONLY when a new generation is genuinely intended
--
-- 0042's function keeps its grants and keeps working. Nothing calls it. It is not dropped, because
-- dropping it would be a destructive edit to applied history for no benefit, and its service_role-
-- only grant already means no client can reach it.
--
-- ★ THE HARD CONSTRAINT EVERYTHING ELSE FOLLOWS FROM. The database stores only token_hash. A raw
-- token exists solely inside one worker invocation. Therefore a retry in a LATER invocation cannot
-- resend the same link — it is unreconstructable. A row left ambiguous by a dead process has two
-- honest futures: reconcile with the provider, or rest in outcomeUncertain until someone
-- deliberately reissues. It must NEVER quietly mint a second link.

begin;

-- ============================================================================================
-- 1 · Outbox lifecycle columns
-- ============================================================================================

-- Generation 0 means "no token has ever been issued for this row". create_estate_invitation stores
-- the hash of an immediately-discarded value, so a freshly created invitation is genuinely not yet
-- usable; the first issue takes it to generation 1.
alter table public.invitation_delivery_outbox
  add column if not exists delivery_generation int not null default 0;

-- The key actually sent to the provider for the CURRENT generation. Persisted rather than
-- recomputed so a same-generation retry provably reuses it.
alter table public.invitation_delivery_outbox
  add column if not exists idempotency_key text;

-- Server-confined. Never returned to any client, never logged.
alter table public.invitation_delivery_outbox
  add column if not exists provider_message_id text;

-- Closed vocabulary. Replaces free-text last_error as the thing anything downstream may read.
alter table public.invitation_delivery_outbox
  add column if not exists failure_class text;

alter table public.invitation_delivery_outbox
  add column if not exists next_attempt_at timestamptz;
alter table public.invitation_delivery_outbox
  add column if not exists claimed_at timestamptz;
alter table public.invitation_delivery_outbox
  add column if not exists last_outcome_at timestamptz;

alter table public.invitation_delivery_outbox
  drop constraint if exists invitation_delivery_outbox_failure_class_check;
alter table public.invitation_delivery_outbox
  add constraint invitation_delivery_outbox_failure_class_check
  check (failure_class is null or failure_class in (
    'provider_rejected', 'provider_unavailable', 'rate_limited',
    'invalid_recipient', 'configuration', 'timeout', 'unknown'
  ));

comment on column public.invitation_delivery_outbox.delivery_generation is
  'Increments ONLY on deliberate token issuance. Half of the provider idempotency key. A retry '
  'reuses the generation; a reissue increments it and invalidates the previous link.';
comment on column public.invitation_delivery_outbox.provider_message_id is
  'Server-confined provider handle. NEVER returned to a client and NEVER logged.';
comment on column public.invitation_delivery_outbox.failure_class is
  'Sanitized classification. Raw provider text is not retained here — it can carry recipient PII.';

-- ============================================================================================
-- 2 · Honest outcome vocabulary
-- ============================================================================================
-- 0042 allowed pending/issued/failed, which cannot express the two states that actually matter:
-- "the provider accepted it" and "we genuinely do not know". The table is EMPTY (verified against
-- the live database before writing this), so the remap below is a safety net, not a data
-- migration.
--
-- ★ THERE IS STILL NO `delivered`. Nothing in this system can observe delivery, receipt, opening,
-- or viewing. providerAccepted is the strongest claim any subsystem is permitted to make.

update public.invitation_delivery_outbox
   set status = case status
     when 'pending' then 'queued'
     when 'issued'  then 'providerAccepted'
     when 'failed'  then 'retryPending'
     else status
   end
 where status in ('pending', 'issued', 'failed');

alter table public.invitation_delivery_outbox
  drop constraint if exists invitation_delivery_outbox_status_check;
alter table public.invitation_delivery_outbox
  add constraint invitation_delivery_outbox_status_check
  check (status in (
    'queued',            -- created, never attempted
    'processing',        -- claimed by a worker right now
    'providerAccepted',  -- provider returned a message id. NOT delivered.
    'outcomeUncertain',  -- request left this process, acceptance unconfirmed. May or may not have gone.
    'retryPending',      -- DEFINITIVE transient refusal; safe to retry on the same generation
    'failedPermanent',   -- retry cap exhausted, or a permanent classification
    'cancelled'          -- invitation became terminal before it could be sent
  ));

alter table public.invitation_delivery_outbox alter column status set default 'queued';

-- Drives the claim scan.
create index if not exists invitation_delivery_outbox_claimable_idx
  on public.invitation_delivery_outbox (requested_at)
  where status in ('queued', 'retryPending');

-- ============================================================================================
-- 3 · list_estate_invitations — keep the owner-facing contract truthful
-- ============================================================================================
-- REPLACED, not because 0042 was wrong, but because widening the vocabulary in §2 would otherwise
-- leak raw worker states ('processing', 'retryPending') through a contract that documents
-- none|queued|issued|failed. The owner surface does not benefit from worker mechanics, so the
-- states are projected down: anything still in flight reads as 'queued'.
--
-- Body is otherwise IDENTICAL to 0042 — same gate, same 90-day window, same display-safe columns.
-- No client consumes this yet (the owner list UI is unbuilt), so the projection breaks nothing.

create or replace function public.list_estate_invitations(
  p_estate uuid,
  p_limit  int default 50
)
 returns table(
   invitation_id      uuid,
   kind               text,
   proposed_role      text,
   status             text,
   invitee_email_hint text,
   invitee_phone_hint text,
   token_fingerprint  text,
   created_at         timestamptz,
   expires_at         timestamptz,
   accepted_at        timestamptz,
   declined_at        timestamptz,
   revoked_at         timestamptz,
   delivery_state     text,
   can_revoke         boolean,
   can_extend         boolean,
   can_redeliver      boolean
 )
 language plpgsql
 security definer
 stable
 set search_path to 'public'
as $function$
declare v_limit int;
begin
  perform public.estate_owner_gate(p_estate);
  v_limit := least(greatest(coalesce(p_limit, 50), 1), 100);

  return query
  with projected as (
    select
      i.id, i.kind, i.proposed_role,
      public.invitation_effective_status(i.status, i.expires_at) as eff_status,
      i.invitee_email_hint, i.invitee_phone_hint,
      substr(i.token_hash, 1, 12) as fingerprint,
      i.created_at, i.expires_at, i.accepted_at, i.declined_at, i.revoked_at,
      coalesce(
        (select o.status from public.invitation_delivery_outbox o
          where o.invitation_id = i.id
          order by o.requested_at desc limit 1),
        'none'
      ) as raw_delivery
    from public.invitations i
    where i.estate_id = p_estate
  )
  select
    p.id, p.kind, p.proposed_role, p.eff_status,
    p.invitee_email_hint, p.invitee_phone_hint, p.fingerprint,
    p.created_at, p.expires_at, p.accepted_at, p.declined_at, p.revoked_at,
    -- Worker mechanics collapse to 'queued'; the honest outcomes pass through unchanged.
    case p.raw_delivery
      when 'queued'       then 'queued'
      when 'processing'   then 'queued'
      when 'retryPending' then 'queued'
      else p.raw_delivery
    end,
    (p.eff_status in ('pending', 'matched')),
    (p.eff_status in ('pending', 'matched')),
    (p.eff_status in ('pending', 'matched'))
  from projected p
  where p.eff_status in ('pending', 'matched')
     or coalesce(p.revoked_at, p.declined_at, p.accepted_at, p.expires_at) > now() - interval '90 days'
  order by p.created_at desc, p.id desc
  limit v_limit;
end;
$function$;
revoke execute on function public.list_estate_invitations(uuid, int) from public, anon;
grant  execute on function public.list_estate_invitations(uuid, int) to authenticated;

-- ============================================================================================
-- 4 · claim_invitation_deliveries — the ONLY way work enters a worker
-- ============================================================================================
-- Mints nothing. Bounded batch. `for update skip locked` is what makes two concurrent drains safe:
-- the second sees the first's rows as locked and skips them rather than blocking or double-sending.
--
-- Terminal invitations are settled to 'cancelled' HERE rather than being handed to the worker, so a
-- revoked invitation can never reach the send path at all.

-- p_outbox_id targets ONE row — the immediate post-create attempt, which must attend to the
-- invitation the owner just made rather than whatever happens to be oldest. Null means "the
-- ordinary oldest-first batch", which is what the cron drain passes. Both paths run the identical
-- eligibility predicate and the identical lock, so the fast path can never bypass a guard.

create or replace function public.claim_invitation_deliveries(
  p_max       int  default 25,
  p_outbox_id uuid default null
)
 returns table(
   outbox_id           uuid,
   invitation_id       uuid,
   delivery_generation int,
   attempts            int
 )
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_max int;
begin
  v_max := case when p_outbox_id is not null then 1
                else least(greatest(coalesce(p_max, 25), 1), 100) end;

  return query
  with candidate as (
    select o.id
      from public.invitation_delivery_outbox o
     where (p_outbox_id is null or o.id = p_outbox_id)
       and ((o.status = 'queued')
         or (o.status = 'retryPending' and coalesce(o.next_attempt_at, o.requested_at) <= now()))
     order by o.requested_at
     limit v_max
     for update skip locked            -- ★ concurrency spine: never block, never hand out twice
  ),
  -- Settle anything whose invitation is no longer actionable. It never reaches the worker.
  cancelled as (
    update public.invitation_delivery_outbox o
       set status = 'cancelled',
           failure_class = null,
           last_outcome_at = now()
      from public.invitations i
     where o.id in (select c.id from candidate c)
       and i.id = o.invitation_id
       and public.invitation_effective_status(i.status, i.expires_at) not in ('pending', 'matched')
    returning o.id
  ),
  claimed as (
    update public.invitation_delivery_outbox o
       set status = 'processing',
           attempts = o.attempts + 1,
           claimed_at = now()
     where o.id in (select c.id from candidate c)
       and o.id not in (select x.id from cancelled x)
    returning o.id, o.invitation_id, o.delivery_generation, o.attempts
  )
  select cl.id, cl.invitation_id, cl.delivery_generation, cl.attempts from claimed cl;
end;
$function$;
revoke execute on function public.claim_invitation_deliveries(int, uuid) from public, anon, authenticated;
grant  execute on function public.claim_invitation_deliveries(int, uuid) to service_role;

-- ============================================================================================
-- 5 · issue_invitation_delivery_token — the ONLY minting site, and the ONLY raw-token return
-- ============================================================================================
-- Callable solely on a row this worker already holds in 'processing'. Increments the generation,
-- mints a secret, stores ONLY its hash, and returns the raw value transiently so a link can be
-- built. The secret is never persisted anywhere, never enters the outbox, and never enters an
-- audit row — the audit records a 12-char fingerprint of the HASH.
--
-- ★ Calling this AGAIN is a deliberate reissue: it invalidates the previous link by overwriting the
-- hash, bumps the generation, and therefore produces a NEW idempotency key. That is exactly what a
-- reissue should do, and exactly what a retry must not do.

create or replace function public.issue_invitation_delivery_token(p_outbox_id uuid)
 returns table(
   invitation_id        uuid,
   raw_token            text,   -- transient. NEVER persisted, NEVER returned to a client.
   delivery_generation  int,
   idempotency_key      text,
   invitee_email        text,
   estate_display_name  text,
   inviter_display_name text,
   preview_visibility   jsonb,
   expires_at           timestamptz
 )
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare v_out record; v_inv record; v_raw text; v_hash text; v_gen int; v_key text;
begin
  select * into v_out from public.invitation_delivery_outbox
   where id = p_outbox_id and status = 'processing' for update;
  if not found then raise exception 'outbox_entry_not_claimed' using errcode = 'P0002'; end if;

  select * into v_inv from public.invitations where id = v_out.invitation_id for update;
  if not found then raise exception 'invitation_not_found' using errcode = 'P0002'; end if;

  -- Belt and braces: the claim already excluded terminal invitations, but never mint a secret for
  -- one that turned terminal in between.
  if public.invitation_effective_status(v_inv.status, v_inv.expires_at) not in ('pending', 'matched') then
    update public.invitation_delivery_outbox
       set status = 'cancelled', last_outcome_at = now() where id = p_outbox_id;
    raise exception 'invitation_not_actionable' using errcode = 'P0005';
  end if;

  v_gen  := v_out.delivery_generation + 1;
  v_raw  := encode(gen_random_bytes(32), 'hex');      -- 64 hex chars, inside bind/preview's 16..512
  v_hash := encode(digest(v_raw, 'sha256'), 'hex');   -- ONLY the hash is stored
  -- Derived from surrogate server identifiers ONLY — never the raw token, never the recipient.
  v_key  := 'afterworth/invitation/' || p_outbox_id::text || '/' || v_gen::text;

  update public.invitations set token_hash = v_hash, updated_at = now() where id = v_inv.id;
  update public.invitation_delivery_outbox
     set delivery_generation = v_gen,
         idempotency_key = v_key,
         provider_message_id = null,   -- a new generation has no provider handle yet
         failure_class = null
   where id = p_outbox_id;

  perform public.write_audit('invitation.delivery_issued', 'invitations', v_inv.id, v_inv.estate_id,
    jsonb_build_object('invitation_id', v_inv.id, 'outbox_id', p_outbox_id,
                       'delivery_generation', v_gen,
                       'token_fingerprint', substr(v_hash, 1, 12)));

  return query select v_inv.id, v_raw, v_gen, v_key, v_inv.invitee_email,
                      v_inv.estate_display_name, v_inv.inviter_display_name,
                      v_inv.preview_visibility, v_inv.expires_at;
end;
$function$;
revoke execute on function public.issue_invitation_delivery_token(uuid) from public, anon, authenticated;
grant  execute on function public.issue_invitation_delivery_token(uuid) to service_role;

-- ============================================================================================
-- 6 · record_invitation_delivery_outcome — the single write-back door
-- ============================================================================================
-- Generation-guarded: a worker that stalled through a reissue cannot stamp its stale verdict onto
-- the newer generation. A mismatched generation is a silent no-op, not an error — the stale worker
-- has nothing useful to say and should not fail loudly for it.

create or replace function public.record_invitation_delivery_outcome(
  p_outbox_id           uuid,
  p_delivery_generation int,
  p_outcome             text,
  p_provider_message_id text default null,
  p_failure_class       text default null
)
 returns table(outbox_id uuid, status text, attempts int)
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_out record; v_status text; v_next timestamptz; v_class text;
  c_max_attempts constant int := 5;
begin
  if p_outcome not in ('providerAccepted', 'outcomeUncertain', 'retryPending', 'failedPermanent', 'cancelled') then
    raise exception 'invalid_outcome' using errcode = 'P0001';
  end if;

  select * into v_out from public.invitation_delivery_outbox where id = p_outbox_id for update;
  if not found then raise exception 'outbox_entry_not_found' using errcode = 'P0002'; end if;

  -- Stale worker: its generation has been superseded by a reissue. Report current state, change nothing.
  if v_out.delivery_generation <> p_delivery_generation then
    return query select v_out.id, v_out.status, v_out.attempts;
    return;
  end if;

  -- Already settled to an accepted state: a duplicate result is a no-op, never a second send.
  if v_out.status in ('providerAccepted', 'cancelled') then
    return query select v_out.id, v_out.status, v_out.attempts;
    return;
  end if;

  v_class := case when p_outcome in ('retryPending', 'failedPermanent') then p_failure_class else null end;
  v_status := p_outcome;
  v_next := null;

  -- ★ THE RETRY CAP. An exhausted row becomes failedPermanent rather than cycling forever.
  if p_outcome = 'retryPending' then
    if v_out.attempts >= c_max_attempts then
      v_status := 'failedPermanent';
    else
      v_next := now() + make_interval(hours => least(v_out.attempts, 12));
    end if;
  end if;

  update public.invitation_delivery_outbox
     set status = v_status,
         -- A provider handle is only meaningful when the provider actually accepted.
         provider_message_id = case when p_outcome = 'providerAccepted'
                                    then nullif(btrim(coalesce(p_provider_message_id, '')), '')
                                    else provider_message_id end,
         failure_class = v_class,
         -- Deliberately NOT the provider's raw text: it can echo the recipient address.
         last_error = v_class,
         next_attempt_at = v_next,
         last_outcome_at = now(),
         issued_at = case when p_outcome = 'providerAccepted' then now() else issued_at end
   where id = p_outbox_id;

  perform public.write_audit('invitation.delivery_outcome', 'invitations', v_out.invitation_id, v_out.estate_id,
    jsonb_build_object('outbox_id', p_outbox_id, 'delivery_generation', p_delivery_generation,
                       'outcome', v_status, 'failure_class', v_class, 'attempts', v_out.attempts));

  return query select v_out.id, v_status, v_out.attempts;
end;
$function$;
revoke execute on function public.record_invitation_delivery_outcome(uuid, int, text, text, text) from public, anon, authenticated;
grant  execute on function public.record_invitation_delivery_outcome(uuid, int, text, text, text) to service_role;

-- ============================================================================================
-- 7 · Operational heartbeat
-- ============================================================================================
-- A daily cron's failure mode is SILENCE (0040's exact rationale). This is the invitation-side
-- heartbeat, shaped like purge_outbox_health and gated identically.
--
-- ★ COUNTS AND AGES ONLY. No email, no hint, no invitation id, no estate id, no token, no provider
-- message id. Nothing here is PII, and nothing here is a secret.

create or replace function public.invitation_delivery_health()
 returns jsonb
 language plpgsql
 security definer
 stable
 set search_path to 'public'
as $function$
declare v_result jsonb;
begin
  perform public.admin_require_gate();

  select jsonb_build_object(
    'queued_count',            count(*) filter (where status = 'queued'),
    'processing_count',        count(*) filter (where status = 'processing'),
    'retry_pending_count',     count(*) filter (where status = 'retryPending'),
    'outcome_uncertain_count', count(*) filter (where status = 'outcomeUncertain'),
    'failed_permanent_count',  count(*) filter (where status = 'failedPermanent'),
    'provider_accepted_last_24h',
        count(*) filter (where status = 'providerAccepted' and issued_at > now() - interval '24 hours'),
    -- headline signal: how long the oldest un-dispatched row has waited.
    'oldest_pending_age_seconds',
        coalesce(extract(epoch from (now() - min(requested_at)
          filter (where status in ('queued', 'retryPending', 'processing'))))::bigint, 0),
    'max_attempts_seen',       coalesce(max(attempts) filter (where status <> 'providerAccepted'), 0),
    'last_provider_acceptance_at', max(issued_at) filter (where status = 'providerAccepted')
  )
  into v_result
  from public.invitation_delivery_outbox;

  return v_result;
end;
$function$;
revoke execute on function public.invitation_delivery_health() from public, anon;
grant  execute on function public.invitation_delivery_health() to authenticated;

-- Surface it on the EXISTING heartbeat too, additively. Existing consumers read named keys, so a
-- new key breaks nothing; the nested gate call is idempotent (0040 already nests one this way).
create or replace function public.purge_outbox_health()
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_result jsonb;
begin
  perform public.admin_require_gate();

  select jsonb_build_object(
    'pending_count',              count(*) filter (where status = 'pending'),
    'failed_count',               count(*) filter (where status = 'failed'),
    'purged_last_24h',            count(*) filter (where status = 'purged' and purged_at > now() - interval '24 hours'),
    'oldest_pending_age_seconds', coalesce(extract(epoch from (now() - min(requested_at)
                                    filter (where status <> 'purged')))::bigint, 0),
    'max_attempts_seen',          coalesce(max(attempts) filter (where status <> 'purged'), 0),
    'last_successful_drain_at',   max(purged_at),
    'orphan_candidate_count',     (select count(*) from public.list_orphan_storage_objects(72, 100)),
    -- ADDITIVE (0043): the invitation-delivery heartbeat, same gate, counts and ages only.
    'invitation_delivery',        public.invitation_delivery_health()
  )
  into v_result
  from public.storage_deletion_outbox;

  return v_result;
end;
$function$;
revoke execute on function public.purge_outbox_health() from public, anon;
grant  execute on function public.purge_outbox_health() to authenticated;

commit;
