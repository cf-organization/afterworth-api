-- 0044_20260801_token_free_invitation_delivery — stop minting a secret to send an informational email.
--
-- 0042 AND 0043 ARE BOTH APPLIED AND ARE IMMUTABLE HISTORY. Nothing here edits or reapplies
-- either. This migration is purely additive: one new function, one new audit action, no column
-- change, no constraint change, no grant change to any existing object.
--
-- ★ WHY THIS EXISTS.
--
-- Recon of 0042 established that the raw invitation token is NOT an authorization credential.
-- accept_invitation, decline_invitation and bind_invitation_token all enforce the identical guard:
--
--     invitee_email matches the caller's verified email, OR invitee_phone matches their phone
--     (otherwise P0006 invitation_not_for_caller)
--
-- Authority is the authenticated caller's identity. Possession of a token confers nothing. And
-- POST /api/invitations/resolve already returns pendingInvitations matched by that same identity,
-- so an authenticated recipient reaches their invitation with no token at all.
--
-- The delivery email is therefore INFORMATIONAL: "you have an invitation waiting, open AfterWorth
-- and sign in". It needs no secret, so minting one is pure downside — a live credential sitting in
-- an inbox forever, for no capability. 0043's issue_invitation_delivery_token() overwrites
-- invitations.token_hash as a side effect of issuing, which also means every send silently
-- invalidated any previously issued link.
--
-- This migration adds the token-free equivalent. The worker calls it instead.
--
-- ★ WHAT IS DELIBERATELY LEFT ALONE (backward compatibility).
--
--   public.issue_invitation_delivery_token  (0043) — superseded, kept, service_role only
--   public.issue_invitation_delivery        (0042) — superseded, kept, service_role only
--   public.invitation_preview               (0016) — INTENTIONALLY UNUSED by this flow. It returns
--       estate name, inviter name, role and a masked contact hint to an UNAUTHENTICATED caller.
--       That is exactly the pre-authentication disclosure this architecture forbids. It stays live
--       for the operator console and the iOS reference app; the production mobile flow never
--       calls it.
--   public.bind_invitation_token            (0017) — INTENTIONALLY UNUSED by this flow. It ACCEPTS
--       and provisions membership as a side effect of inspection, and offers no decline. The
--       production flow uses accept_invitation / decline_invitation by id instead, which enforce
--       the same P0006 guard and support both outcomes.
--
-- None of these are dropped: they are reachable only by service_role or through their own gates,
-- and removing applied history to tidy an unused path would be a destructive change for no
-- security gain.
--
-- ★ WHAT DOES NOT CHANGE. claim_invitation_deliveries and record_invitation_delivery_outcome are
-- reused verbatim. The claim predicate, SKIP LOCKED behaviour, retry cap, generation guard, and
-- outcome vocabulary are all unchanged, so the 0043 verification harness still holds.

begin;

-- ============================================================================================
-- 1 · issue_invitation_delivery_notice — the token-free issue step
-- ============================================================================================
-- Same shape and same guarantees as 0043's issue_invitation_delivery_token, minus the secret:
--
--   * callable ONLY on a row this worker already holds in 'processing'
--   * advances delivery_generation, so the idempotency key is unique per attempt and the
--     generation guard in record_invitation_delivery_outcome keeps working unchanged
--   * returns the recipient address and the display fields the email needs
--   * ★ DOES NOT TOUCH invitations.token_hash — no secret is minted, and no previously issued
--     link is invalidated as a side effect of sending a notice
--   * returns NO token column at all, so a caller cannot accidentally forward one
--
-- The audit action is deliberately DIFFERENT from 'invitation.delivery_issued'. That action means
-- "a credential was minted"; this one means "a notice was prepared". Reusing it would make the
-- audit trail claim a token exists when none does.

create or replace function public.issue_invitation_delivery_notice(p_outbox_id uuid)
 returns table(
   invitation_id        uuid,
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
 set search_path to 'public'
as $function$
declare v_out record; v_inv record; v_gen int; v_key text;
begin
  select * into v_out from public.invitation_delivery_outbox
   where id = p_outbox_id and status = 'processing' for update;
  if not found then raise exception 'outbox_entry_not_claimed' using errcode = 'P0002'; end if;

  select * into v_inv from public.invitations where id = v_out.invitation_id for update;
  if not found then raise exception 'invitation_not_found' using errcode = 'P0002'; end if;

  -- The claim already excluded terminal invitations; this catches one that turned terminal in
  -- between, and settles the row rather than emailing about an invitation that no longer exists.
  if public.invitation_effective_status(v_inv.status, v_inv.expires_at) not in ('pending', 'matched') then
    update public.invitation_delivery_outbox
       set status = 'cancelled', last_outcome_at = now() where id = p_outbox_id;
    raise exception 'invitation_not_actionable' using errcode = 'P0005';
  end if;

  v_gen := v_out.delivery_generation + 1;
  -- Identical derivation to 0043: surrogate server identifiers only. Never a token (there is
  -- none), never the recipient address.
  v_key := 'afterworth/invitation/' || p_outbox_id::text || '/' || v_gen::text;

  update public.invitation_delivery_outbox
     set delivery_generation = v_gen,
         idempotency_key = v_key,
         provider_message_id = null,   -- a new generation has no provider handle yet
         failure_class = null
   where id = p_outbox_id;

  -- ★ NOTE WHAT IS ABSENT: no update to invitations.token_hash, and no token_fingerprint in the
  --   audit — because no secret was created. An auditor reading this row must not be able to
  --   conclude that a credential is in circulation.
  perform public.write_audit('invitation.delivery_notice_issued', 'invitations', v_inv.id, v_inv.estate_id,
    jsonb_build_object('invitation_id', v_inv.id, 'outbox_id', p_outbox_id,
                       'delivery_generation', v_gen));

  return query select v_inv.id, v_gen, v_key, v_inv.invitee_email,
                      v_inv.estate_display_name, v_inv.inviter_display_name,
                      v_inv.preview_visibility, v_inv.expires_at;
end;
$function$;
revoke execute on function public.issue_invitation_delivery_notice(uuid) from public, anon, authenticated;
grant  execute on function public.issue_invitation_delivery_notice(uuid) to service_role;

comment on function public.issue_invitation_delivery_notice(uuid) is
  'Token-free delivery issue step. Prepares an INFORMATIONAL notice: no secret is minted and '
  'invitations.token_hash is not touched. Supersedes issue_invitation_delivery_token for the '
  'production flow; that function is retained for backward compatibility.';

commit;
