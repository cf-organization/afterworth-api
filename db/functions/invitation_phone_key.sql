-- public.invitation_phone_key(p_raw text, p_require_plus boolean) -> text
--
-- THE ONE comparison key for a phone number on the invitation path. Both sides of every phone match
-- (resolve_membership's pending list, accept_invitation, decline_invitation, bind_invitation_token)
-- are reduced to this key and compared with plain equality — never a raw string against a raw string.
--
-- ★ WHY. GoTrue stores a confirmed phone as international DIGITS ("15555550100"); the owner paths
--   store the invitee phone as the owner typed it, conventionally with a leading "+" ("+15555550100").
--   A raw equality never matched the two, so a confirmed phone could not see or accept an invitation
--   addressed to it. The key is the E.164 digit string, derived strictly:
--
--   · p_require_plus = true  (the INVITATION side): accepted only as "+" followed by E.164 digits
--     (`^\+[1-9][0-9]{7,14}$`). A number written without the "+" has no country-code marker and is
--     ambiguous, so it NEVER matches — existing rows written with "+" are covered without a backfill;
--   · p_require_plus = false (the AUTH side): the same digits with or without the "+", as GoTrue
--     writes them (`^\+?[1-9][0-9]{7,14}$`);
--   · anything else — spaces, dashes, parentheses, letters, a leading zero, too short, too long,
--     NULL — yields NULL, and a NULL key matches nothing.
--
-- ★ STRICT ON PURPOSE. No digit stripping, no "best effort" normalisation: a malformed value is a
--   value nobody verified, and the cost of refusing it is one re-issued invitation.
--
-- Source of truth for this function. Re-apply on any DB reset.

create or replace function public.invitation_phone_key(p_raw text, p_require_plus boolean)
 returns text
 language sql
 immutable
 strict
 parallel safe
as $function$
  select case
    when p_require_plus and p_raw ~ '^\+[1-9][0-9]{7,14}$' then substr(p_raw, 2)
    when not p_require_plus and p_raw ~ '^\+[1-9][0-9]{7,14}$' then substr(p_raw, 2)
    when not p_require_plus and p_raw ~ '^[1-9][0-9]{7,14}$' then p_raw
    else null
  end
$function$;
revoke execute on function public.invitation_phone_key(text, boolean) from public, anon;
grant  execute on function public.invitation_phone_key(text, boolean) to authenticated;
