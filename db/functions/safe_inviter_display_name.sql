-- public.safe_inviter_display_name(p_raw text) -> text
--
-- The ONE server-side sanitizer for an inviter display name that is released to a RECIPIENT after
-- acceptance (the membership-context cue in resolve_membership). Mirrors the client's
-- `sanitizeInviterDisplayName` rule exactly, so the server and the app can never disagree about
-- whether a stored value is a name:
--
--   · NULL, blank, or whitespace-only → NULL (missing);
--   · anything EMAIL-SHAPED (`\S@\S`, deliberately broader than RFC) → NULL (unsafe). Both deployed
--     invitation create paths persist `coalesce(nullif(full_name,''), email)`, so a row whose inviter
--     had no profile name carries an ADDRESS in this column. The server gates whether the column is
--     returned, never what it contains — until here.
--   · longer than 200 characters → NULL (not a name a person could recognise; a bound, not a format).
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
  select case
    when btrim(p_raw) = '' then null
    when btrim(p_raw) ~ '\S@\S' then null
    when length(btrim(p_raw)) > 200 then null
    else btrim(p_raw)
  end
$function$;
revoke execute on function public.safe_inviter_display_name(text) from public, anon;
grant  execute on function public.safe_inviter_display_name(text) to authenticated;
