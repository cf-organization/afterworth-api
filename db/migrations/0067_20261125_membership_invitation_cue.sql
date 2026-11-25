-- 0067_20261125_membership_invitation_cue.sql
-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- MEMBERSHIP INVITATION CUE — a recipient may keep seeing the safe inviter display name from the
-- invitation THEY accepted, on THEIR OWN active membership context.
--
-- ★ THE PRODUCT DECISION (2026-11-25). "An authenticated recipient may continue to see the safe
--   inviter display name associated with the invitation they accepted, for their own active
--   membership. This is an invitation cue, not a claim about the estate's current owner."
--
-- ★ WHY. `resolve_membership` bootstraps every owner's estate as "My Estate". A recipient invited
--   into two such estates with the same role holds two contexts that differ in nothing a person can
--   recognise: the switcher and the Vault's estate line (mobile #221) can only say "My Estate" twice.
--   The one cue that recipient was already shown — "<inviter> invited you to My Estate" on the
--   acceptance screen — is persisted on the invitation row, and the membership created at acceptance
--   points back at that row (`estate_memberships.source_invitation_id`). This migration re-releases
--   that cue on the membership context; it discloses nothing the recipient did not already possess.
--
-- ★ WHAT IS NOT DONE. No approval date, no contact detail, no nickname, no visible id, no neutral
--   "An estate owner" discriminator, no profile lookup. Two memberships may carry the same safe name;
--   the server never manufactures a distinction. The primary (owned) context carries no cue.
--
-- ★ SCHEMA UNCHANGED. Two function bodies only, both also under db/functions/ (source of truth):
--   · public.safe_inviter_display_name(text)  — NEW, the one server-side sanitizer;
--   · public.resolve_membership(text, text)   — additional contexts gain `inviterDisplayName`.
--
-- ★ ROLLOUT. Additive, nullable, optional. The mobile decoder (`estateContextWireSchema`, a non-strict
--   zod object) ignores unknown keys, verified against captured responses before this merged; a client
--   that renders the cue ships separately and tolerates its absence.
--
-- Idempotent: `create or replace` throughout. Re-apply on any DB reset AFTER the bootstrap.
-- ════════════════════════════════════════════════════════════════════════════════════════════════

-- ── 1 · the sanitizer ─────────────────────────────────────────────────────────────────────────────
-- public.safe_inviter_display_name(p_raw text) -> text
--
-- The ONE server-side sanitizer for an inviter display name that is released to a RECIPIENT after
-- acceptance (the membership-context cue in resolve_membership). It mirrors the client's acceptance
-- sanitizer (`sanitizeInviterDisplayName`: `raw.trim()`, empty → null, `/\S@\S/` → null, else the
-- trimmed value) so the server and the app cannot disagree about whether a stored value is a name:
--
--   · NULL → NULL (the function is STRICT);
--   · trim the SAME set JavaScript's String.prototype.trim() strips — ASCII whitespace, line
--     terminators (LF, CR, U+2028, U+2029), NO-BREAK SPACE U+00A0, U+1680, U+2000–U+200A, U+202F,
--     U+205F, U+3000 and the BOM U+FEFF. `btrim(text)` strips only ' ' and was the defect this file
--     once had: a tab-only or NBSP-only value survived as a "name";
--   · nothing left after trimming → NULL (missing);
--   · anything EMAIL-SHAPED (`\S@\S`, deliberately broader than RFC) → NULL (unsafe). Both deployed
--     invitation create paths persist `coalesce(nullif(full_name,''), email)`, so a row whose inviter
--     had no profile name carries an ADDRESS in this column. The server gates whether the column is
--     returned, never what it contains — until here;
--   · longer than 200 characters after trimming → NULL. ★ INTENTIONALLY STRICTER THAN THE CLIENT,
--     which has no length bound: a 200+ character value is not a name a person could recognise, and
--     a bound on what the server releases is cheaper than one on what the client renders.
--
-- ★ NULL MEANS "NO CUE", NEVER A SUBSTITUTE. No neutral phrase, no profile lookup, no owner name:
--   a caller that gets NULL shows nothing. The recipient-facing neutral wording is the client's.
--
-- Source of truth for this function. Re-apply on any DB reset.

create or replace function public.safe_inviter_display_name(p_raw text)
 returns text
 language sql
 immutable
 strict
 parallel safe
as $function$
  with trimmed as (
    select regexp_replace(
             p_raw,
             '^[\s\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+|[\s\u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+$',
             '', 'g') as v
  )
  select case
    when v = '' then null
    when v ~ '\S@\S' then null
    when length(v) > 200 then null
    else v
  end
  from trimmed
$function$;
revoke execute on function public.safe_inviter_display_name(text) from public, anon;
grant  execute on function public.safe_inviter_display_name(text) to authenticated;

-- ── 2 · resolve_membership with the cue ───────────────────────────────────────────────────────────
-- public.resolve_membership(p_email text, p_phone text) -> jsonb
--
-- Resolves the authenticated caller's membership context: their primary estate
-- (bootstrapped on first call if none exists), pending invitations matching
-- their email/phone, and additional (non-owned) estate memberships.
--
-- Each estate context includes ownerUserId (estates.owner_id) so the iOS legacy
-- estate-context layer has the real owner for both owned and beneficiary contexts.
--
-- ★ THE INVITATION CUE (2026-11-25). Each ADDITIONAL context (an approved, non-owned membership)
-- carries an optional, nullable `inviterDisplayName`: the safe inviter display name from the one
-- invitation THIS caller accepted to obtain THIS membership — an invitation cue, not a claim about
-- the estate's current owner. Why: every bootstrapped estate is named "My Estate", so a recipient
-- holding two memberships with the same role in two such estates had nothing to tell them apart
-- (mobile #221). The cue is released only when ALL of the following hold, otherwise it is NULL:
--   · the membership's `source_invitation_id` links an invitation (a reconciled membership has none);
--   · that invitation is for the SAME estate and was ACCEPTED BY THIS CALLER (`accepted_by = v_user`,
--     status 'accepted') — a mismatched or borrowed link releases nothing;
--   · the owner chose to show the inviter name at invitation time (`preview_visibility.showInviterName`),
--     i.e. the recipient already saw it on the acceptance screen — this re-releases, never discloses;
--   · the stored value passes `safe_inviter_display_name` (blank / email-shaped / over-long → NULL).
-- Never substituted from a profile, never an approval date, contact detail, nickname or id. Two
-- memberships may legitimately carry the SAME safe name; the server never manufactures a difference.
--
-- SECURITY DEFINER; relies on auth.uid(). Called from /api/invitations/resolve
-- with the caller's JWT forwarded (so auth.uid() is the real user).
--
-- Source of truth for this function. Re-apply on any DB reset.

CREATE OR REPLACE FUNCTION public.resolve_membership(p_email text, p_phone text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  v_user uuid := auth.uid();
  v_primary jsonb;
  v_pending jsonb;
  v_additional jsonb;
  v_primary_estate_id uuid;
begin
  -- Caller must be authenticated. Resolution has no meaning otherwise.
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;

  -- Look for the user's primary estate (one they own and that is
  -- marked as is_primary). If none exists, bootstrap one.
  select id into v_primary_estate_id
  from public.estates
  where owner_id = v_user
    and is_primary = true
  limit 1;

  if v_primary_estate_id is null then
    v_primary_estate_id := gen_random_uuid();
    insert into public.estates
      (id, owner_id, name, status, is_primary, created_at, updated_at)
    values
      (v_primary_estate_id, v_user, 'My Estate', 'active', true,
       now(), now());

    -- Note: NO insert into estate_memberships here. The trigger
    -- estates_ensure_primary_user_membership handles it with the
    -- correct V1 'primary_user' role.

    perform public.write_audit(
      'estate.primary_created',
      'estates',
      v_primary_estate_id,
      v_primary_estate_id,
      '{}'::jsonb
    );
  end if;

  -- Primary estate context: the user's own estate.
  select jsonb_build_object(
    'id', m.id,
    'estateId', e.id,
    'estateDisplayName', e.name,
    'ownerUserId', e.owner_id,
    'roleWithinEstate', m.role,
    'membershipStatus', m.status,
    'isPrimaryEstate', true
  )
  into v_primary
  from public.estate_memberships m
  join public.estates e on e.id = m.estate_id
  where m.user_id = v_user
    and e.is_primary = true
    and m.status = 'approved'
    and public.is_ownership_role(m.role)
  limit 1;

  -- Pending invitations matching the user's email or phone.
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', i.id,
    'estateId', i.estate_id,
    'estateDisplayName',
      case when (i.preview_visibility->>'showEstateName')::boolean
           then i.estate_display_name else null end,
    'inviterDisplayName',
      case when (i.preview_visibility->>'showInviterName')::boolean
           then i.inviter_display_name else null end,
    'invitationKind', i.kind,
    'proposedRole', i.proposed_role,
    'expiresAt', i.expires_at,
    'status', i.status
  )), '[]'::jsonb)
  into v_pending
  from public.invitations i
  where i.status in ('pending', 'matched')
    and i.expires_at > now()
    and (
      (p_email is not null
       and i.invitee_email is not null
       and lower(i.invitee_email) = lower(p_email))
      or
      (p_phone is not null
       and i.invitee_phone is not null
       and i.invitee_phone = p_phone)
    );

  -- Additional contexts: approved memberships in estates the user does NOT own.
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', m.id,
    'estateId', e.id,
    'estateDisplayName', e.name,
    'ownerUserId', e.owner_id,
    'roleWithinEstate', m.role,
    'membershipStatus', m.status,
    'isPrimaryEstate', false,
    -- The invitation cue (header note): bound to THIS membership, THIS estate and THIS caller's own
    -- acceptance, released only where the recipient already saw it, sanitized before serialization.
    -- A scalar subquery with no matching row is NULL — unlinked, mismatched and hidden all read as
    -- "no cue" without a branch per cause.
    'inviterDisplayName', (
      select public.safe_inviter_display_name(i.inviter_display_name)
        from public.invitations i
       where i.id = m.source_invitation_id
         and i.estate_id = m.estate_id
         and i.accepted_by = v_user
         and i.status = 'accepted'
         and coalesce((i.preview_visibility->>'showInviterName')::boolean, false)
    )
  )), '[]'::jsonb)
  into v_additional
  from public.estate_memberships m
  join public.estates e on e.id = m.estate_id
  where m.user_id = v_user
    and m.status = 'approved'
    and not public.is_ownership_role(m.role);

  return jsonb_build_object(
    'primaryEstateContext', v_primary,
    'pendingInvitations', v_pending,
    'additionalContexts', v_additional
  );
end;
$function$;
revoke execute on function public.resolve_membership(text, text) from public, anon;
grant  execute on function public.resolve_membership(text, text) to authenticated;
