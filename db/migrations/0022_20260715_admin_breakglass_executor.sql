-- 0022_20260715_admin_breakglass_executor — first BREAK-GLASS instance: admin-minted executor invitation.
--
-- Lets a platform ADMIN (no estate ownership) mint an executor/trustee invitation directly — the emergency
-- path when no owner is available to designate a fiduciary. Break-glass = HIGH accountability, so the RPC
-- layers a mandatory justification + self-assignment separation + a high-severity 'admin' audit on top of the
-- full admin gate, then mints through the CANONICAL create_invitation path (0021). The minted invitation
-- accepts via the unchanged accept_invitation / bind_invitation_token flow → stamps the designation.
--
-- LOCKED design:
--   * Dedicated RPC (not an overload of the owner path) so break-glass carries its own gate + audit.
--   * Gate: admin_require_gate() — auth -> is_admin -> require_aal2 -> 15-min iat freshness (reused verbatim).
--   * Justification: reason + case_ref BOTH mandatory (non-empty). A break-glass with no paper trail is the
--     thing we're defending against.
--   * Separation of duties: an admin may NOT name THEMSELVES the invitee (assert_not_self_invitee).
--   * Accountability: write_admin_breakglass_audit stamps ONE audit_logs row, source='admin' (already an
--     allowed source value — verified live 2026-07-15), metadata.severity='high' + reason + case_ref
--     (audit_logs has no severity column; it lives in metadata). "Immutable" = server-stamped actor +
--     append-only via grants (client UPDATE/DELETE revoked), not a trigger.
--   * Verification / notification: NO-OP seam (out-of-band; kept out of the tx to preserve atomicity).
--   * reason/case_ref, the self-assignment guard, and the high-sev audit are factored as REUSABLE primitives
--     so the next break-glass action (financial-reveal, etc.) composes them instead of re-deriving.
--
-- No audit_logs schema change: source CHECK already ⊇ {server,ios_forward,admin}. create_invitation's
-- invitation_write_gate re-checks admin+aal2+freshness (defense in depth); the admin caller passes.

begin;

-- ==================================================================================================
-- REUSABLE PRIMITIVE — mandatory break-glass justification (reason + case_ref). INTERNAL.
-- ==================================================================================================
create or replace function public.require_breakglass_justification(p_reason text, p_case_ref text)
 returns void
 language plpgsql
 set search_path to 'public'
as $function$
begin
  if p_reason is null or length(btrim(p_reason)) = 0 then
    raise exception 'breakglass_reason_required' using errcode = 'P0001';
  end if;
  if p_case_ref is null or length(btrim(p_case_ref)) = 0 then
    raise exception 'breakglass_case_ref_required' using errcode = 'P0001';
  end if;
end;
$function$;
revoke execute on function public.require_breakglass_justification(text, text) from public, anon, authenticated;

-- ==================================================================================================
-- REUSABLE PRIMITIVE — separation of duties: the caller may not name themselves the invitee. INTERNAL.
-- DEFINER so it can read the caller's own profiles row regardless of grants.
-- ==================================================================================================
create or replace function public.assert_not_self_invitee(p_invitee_email text, p_invitee_phone text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_email text; v_phone text;
begin
  select email, phone into v_email, v_phone from public.profiles where id = auth.uid();
  if (p_invitee_email is not null and lower(p_invitee_email) = lower(coalesce(v_email, '')))
     or (p_invitee_phone is not null and p_invitee_phone = coalesce(v_phone, '')) then
    raise exception 'breakglass_self_assignment' using errcode = 'P0001';
  end if;
end;
$function$;
revoke execute on function public.assert_not_self_invitee(text, text) from public, anon, authenticated;

-- ==================================================================================================
-- REUSABLE PRIMITIVE — high-severity 'admin' break-glass audit. INTERNAL. actor server-stamped.
-- ==================================================================================================
create or replace function public.write_admin_breakglass_audit(
  p_action   text,
  p_table    text,
  p_target   uuid,
  p_estate   uuid,
  p_reason   text,
  p_case_ref text,
  p_meta     jsonb default '{}'::jsonb
)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  insert into public.audit_logs(actor_id, estate_id, action, target_table, target_id, metadata, source)
  values (
    auth.uid(), p_estate, p_action, p_table, p_target,
    coalesce(p_meta, '{}'::jsonb)
      || jsonb_build_object('severity', 'high', 'breakglass', true, 'reason', p_reason, 'case_ref', p_case_ref),
    'admin'
  );
end;
$function$;
revoke execute on function public.write_admin_breakglass_audit(text, text, uuid, uuid, text, text, jsonb)
  from public, anon, authenticated;

-- ==================================================================================================
-- admin_create_executor_invitation — the break-glass RPC. Client-reachable (authenticated), gated inside.
-- ==================================================================================================
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

commit;
