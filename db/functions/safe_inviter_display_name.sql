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
