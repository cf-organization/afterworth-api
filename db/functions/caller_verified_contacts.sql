-- public.caller_verified_contacts() -> (email text, phone text)
--
-- The ONE source of the authenticated caller's VERIFIED contacts, for every place an invitation is
-- matched to the person it was addressed to (resolve_membership's pending list, accept_invitation,
-- decline_invitation, bind_invitation_token).
--
-- ★ WHY NOT `public.profiles`. `profiles_self_update` lets a user change their own row, columns
--   included, and `handle_new_user` copies the address only at sign-up. A profile address is
--   therefore neither verified, nor immune to an ordinary edit, nor current after a contact change —
--   the three properties an invitation match needs. Four functions read it anyway; this helper
--   replaces all four reads.
--
-- ★ WHY `auth.users`. GoTrue owns it, no client role can write it, `email` and `phone` change only
--   through its own confirmation flows, and `email_confirmed_at` / `phone_confirmed_at` record that
--   the address was proven. A contact is eligible ONLY when its confirmation timestamp is set:
--   an unconfirmed email yields NULL, a missing or unconfirmed phone yields NULL, and each contact
--   is decided independently — a verified email keeps working without any phone.
--
-- ★ THE PHONE IS RETURNED AS A COMPARISON KEY, NOT A STRING (see invitation_phone_key.sql). GoTrue
--   stores E.164 digits without the "+"; the callers reduce the invitation side to the same key and
--   compare keys. A confirmed phone that is not E.164-shaped yields NULL and matches nothing.
--
-- ★ NULL MEANS "NO CONTACT", AND THE CALLERS TREAT IT AS "MATCHES NOTHING". No fallback to a profile,
--   a JWT claim, or a caller-supplied parameter. SECURITY DEFINER only so the definer can read
--   auth.users; the function returns the caller's OWN row and nothing else.
--
-- Source of truth for this function. Re-apply on any DB reset.

create or replace function public.caller_verified_contacts(out email text, out phone text)
 returns record
 language plpgsql
 stable
 security definer
 set search_path to 'public'
as $function$
declare
  v_user uuid := auth.uid();
begin
  email := null;
  phone := null;
  if v_user is null then
    return;
  end if;
  select
    case when u.email_confirmed_at is not null and nullif(btrim(u.email), '') is not null
         then lower(btrim(u.email)) end,
    case when u.phone_confirmed_at is not null
         then public.invitation_phone_key(btrim(u.phone), false) end
    into email, phone
    from auth.users u
   where u.id = v_user
     and u.deleted_at is null;
  return;
end
$function$;
revoke execute on function public.caller_verified_contacts() from public, anon;
grant  execute on function public.caller_verified_contacts() to authenticated;
