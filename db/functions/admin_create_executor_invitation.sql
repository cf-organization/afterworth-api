-- public.admin_create_executor_invitation(p_estate, p_kind, p_invitee_email, p_invitee_phone,
--                                         p_reason, p_case_ref, p_expires_in_days)
--   -> TABLE(invitation_id uuid, raw_token text, token_fingerprint text, expires_at timestamptz)
--
-- BREAK-GLASS: a platform ADMIN (no estate ownership) mints an executor/trustee invitation directly — the
-- emergency path when no owner can designate a fiduciary. Gated inside (the DEFINER-door discipline): a
-- direct PostgREST caller hits the SAME gates. Order: admin_require_gate (auth -> is_admin -> aal2 ->
-- 15-min freshness) -> kind ∈ {executor,trustee} -> contact present -> mandatory reason+case_ref ->
-- separation-of-duties (no self-assignment) -> mint via canonical create_invitation -> HIGH-severity
-- 'admin' audit -> NO-OP notification seam. The minted invitation accepts via the unchanged
-- accept_invitation / bind_invitation_token flow (0021) and stamps the designation there.
--
-- Client-reachable (authenticated) — every trust decision is enforced here. Created by migration 0022.
-- Source of truth — re-apply on reset.

create or replace function public.admin_create_executor_invitation(
  p_estate         uuid,
  p_kind           text,
  p_invitee_email  text default null,
  p_invitee_phone  text default null,
  p_reason         text default null,
  p_case_ref       text default null,
  p_expires_in_days int  default 14
)
 returns table(invitation_id uuid, raw_token text, token_fingerprint text, expires_at timestamptz)
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_id uuid; v_tok text; v_fp text; v_exp timestamptz;
begin
  perform public.admin_require_gate();                        -- auth -> is_admin -> aal2 -> 15-min freshness

  if p_kind not in ('executor', 'trustee') then
    raise exception 'kind_not_supported' using errcode = 'P0001';   -- break-glass mints fiduciary roles ONLY
  end if;
  if p_invitee_email is null and p_invitee_phone is null then
    raise exception 'invitee_contact_required' using errcode = 'P0001';
  end if;
  perform public.require_breakglass_justification(p_reason, p_case_ref);
  perform public.assert_not_self_invitee(p_invitee_email, p_invitee_phone);

  -- Mint through the canonical path (derives proposed_role='beneficiary' for executor/trustee).
  -- invitation_write_gate re-checks admin+aal2+freshness (defense in depth); the admin caller passes.
  select ci.invitation_id, ci.raw_token, ci.token_fingerprint, ci.expires_at
    into v_id, v_tok, v_fp, v_exp
    from public.create_invitation(p_estate, p_kind, 'beneficiary', p_invitee_email, p_invitee_phone,
                                  false, false, p_expires_in_days) ci;

  -- HIGH-SEVERITY accountability record (separate from create_invitation's normal 'invitation.created').
  perform public.write_admin_breakglass_audit(
    'admin.breakglass.executor_invitation', 'invitations', v_id, p_estate, p_reason, p_case_ref,
    jsonb_build_object('kind', p_kind, 'invitation_id', v_id, 'token_fingerprint', v_fp));

  -- NOTIFICATION HOOK (NO-OP): out-of-band notify the invitee + a security channel later; kept out of the tx.

  return query select v_id, v_tok, v_fp, v_exp;
end;
$function$;
revoke execute on function public.admin_create_executor_invitation(uuid,text,text,text,text,text,int)
  from public, anon;
grant  execute on function public.admin_create_executor_invitation(uuid,text,text,text,text,text,int)
  to authenticated;
