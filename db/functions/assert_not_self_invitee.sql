-- public.assert_not_self_invitee(p_invitee_email text, p_invitee_phone text) -> void
--
-- REUSABLE break-glass primitive: separation of duties — the CALLER may not name THEMSELVES the invitee
-- (compares the invitee contact against the caller's own profiles row). SECURITY DEFINER so it can read the
-- caller's profile regardless of RLS. INTERNAL (client roles revoked). Error: 'breakglass_self_assignment'
-- (P0001). Created by migration 0022. Source of truth — re-apply on reset.

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
