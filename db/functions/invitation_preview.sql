-- public.invitation_preview(p_token text)
--   -> TABLE(token_fingerprint text, invitation_kind text, proposed_role text,
--            estate_display_name text, inviter_display_name text,
--            invitee_email_hint text, invitee_phone_hint text,
--            expires_at timestamptz, is_expired boolean, is_revoked boolean)
--
-- Unauthenticated, read-only preview of an invitation by plaintext token, for
-- the pre-sign-in deep-link flow. Returns only privacy-safe denormalized fields
-- (display names gated by preview_visibility; masked hints). Returns no row for
-- a missing token (does not leak existence). Does not raise on expired/revoked —
-- returns them as booleans so the client can render gracefully.
--
-- Called from api/invitations/preview.ts with an anon client (no JWT).
-- SECURITY DEFINER. Source of truth — re-apply on DB reset.
--
-- ★ 0069 (2026-11-26): the released inviter name passes `safe_inviter_display_name`; a legacy row holding an
-- address returns NULL. The showInviterName gate and the estate-name gate are unchanged. Body identical to 0069.

create or replace function public.invitation_preview(p_token text)
 returns table(token_fingerprint text, invitation_kind text, proposed_role text, estate_display_name text, inviter_display_name text, invitee_email_hint text, invitee_phone_hint text, expires_at timestamp with time zone, is_expired boolean, is_revoked boolean)
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_hash text;
  v_fp text;
  v_inv record;
begin
  -- Validate input shape early to avoid spending DB time on garbage.
  if p_token is null or length(p_token) < 16 or length(p_token) > 512 then
    return;
  end if;

  v_hash := encode(digest(p_token, 'sha256'), 'hex');

  -- Use first 12 hex chars to match iOS fingerprint length.
  -- The iOS InvitationToken.fingerprint uses SHA256 truncated to 12 chars.
  v_fp := substr(v_hash, 1, 12);

  select * into v_inv
  from public.invitations
  where token_hash = v_hash
  limit 1;

  if not found then
    return; -- empty result set; do not leak existence
  end if;

  return query select
    v_fp,
    v_inv.kind::text,
    v_inv.proposed_role::text,
    case when (v_inv.preview_visibility->>'showEstateName')::boolean is true
         then v_inv.estate_display_name else null end,
    -- ★ 0069: the owner's choice gates WHETHER a name is released; the sanitizer decides whether the
    --   stored value IS one. A legacy row holding an address releases NULL here, as it does everywhere.
    case when (v_inv.preview_visibility->>'showInviterName')::boolean is true
         then public.safe_inviter_display_name(v_inv.inviter_display_name) else null end,
    v_inv.invitee_email_hint,
    v_inv.invitee_phone_hint,
    v_inv.expires_at,
    (v_inv.expires_at < now()),
    (v_inv.status = 'revoked');
end;
$function$;
