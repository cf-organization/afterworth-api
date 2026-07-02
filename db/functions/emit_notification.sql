-- public.emit_notification(p_user_id, p_estate_id, p_category, p_title, p_body,
--                          p_deep_link default null, p_payload default '{}') -> uuid (the new id)
--
-- The ONLY way a notification row is created — the anti-forge boundary. SECURITY DEFINER so it
-- bypasses the notifications RLS + the missing INSERT grant (authenticated cannot insert), while a
-- client calling it directly can still only create a notification (it can't read others' — that's
-- RLS on SELECT). Event sources call this as a BEST-EFFORT side effect: the CALLER wraps it in a
-- begin/exception block so a notification failure NEVER fails the load-bearing event (a grant, a
-- request, ...). Kept intentionally generic (any category/title/body) so new emitters reuse it
-- without new plumbing.
--
-- Source of truth — re-apply on DB reset.

create or replace function public.emit_notification(
  p_user_id uuid,
  p_estate_id uuid,
  p_category text,
  p_title text,
  p_body text,
  p_deep_link text default null,
  p_payload jsonb default '{}'::jsonb
)
 returns uuid
 language plpgsql
 volatile
 security definer
 set search_path to 'public'
as $function$
declare
  v_id uuid;
begin
  -- Writes the RECONCILED live schema: the logical category maps to the existing `kind` column, and
  -- `read` (boolean) starts false (unread). See 0009_20260702_notifications.sql.
  insert into public.notifications
    (user_id, estate_id, kind, title, body, channel, action_deep_link, payload, read)
  values
    (p_user_id, p_estate_id, p_category, p_title, p_body, 'inApp', p_deep_link, coalesce(p_payload, '{}'::jsonb), false)
  returning id into v_id;
  return v_id;
end;
$function$;
