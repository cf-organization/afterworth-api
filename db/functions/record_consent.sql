-- public.record_consent(p_type text, p_version text) -> uuid (consent_records.id)
--
-- Slice C2 (migration 0025). The SOLE write path for acknowledgment-class consent. SECURITY DEFINER, gated
-- inside. Stamps user_id = auth.uid() (a client can NEVER record consent for another user — there is no
-- p_user param) and accepted_at = now() server-side (a client consent timestamp is forgeable). consent_type
-- is validated by the consent_records CHECK (single source of truth for the acknowledgment vocabulary).
--
-- Append-only: each call inserts a NEW row (a new affirmation fact); the caller cannot update/delete. The
-- gate reads own consent_records via RLS ("has this user a row for type X at the CURRENT version?").
-- EXECUTE to authenticated only. Source of truth — re-apply on reset.

create or replace function public.record_consent(p_type text, p_version text)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_uid uuid := auth.uid(); v_id uuid;
begin
  if v_uid is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;
  if p_version is null or length(btrim(p_version)) = 0 then
    raise exception 'version_required' using errcode = 'P0001';
  end if;
  insert into public.consent_records (user_id, consent_type, document_version)
  values (v_uid, p_type, p_version)
  returning id into v_id;
  return v_id;
end;
$function$;
revoke execute on function public.record_consent(text, text) from public, anon;
grant  execute on function public.record_consent(text, text) to authenticated;
