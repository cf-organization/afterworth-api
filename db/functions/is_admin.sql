-- public.is_admin() -> boolean
--
-- True iff the caller (auth.uid()) is a platform admin. SECURITY DEFINER so it reads public.admins
-- bypassing that table's deny-all RLS — callable from inside other DEFINER gates without any grant on admins.
-- The single site for the admin check; consumers (admin_require_gate, invitation_write_gate) never query
-- admins directly.
--
-- CAPTURED FROM LIVE 2026-07-15 — was live-only (admins itself is a live-only table, migration 0014, same
-- invisible-load-bearing-object class as handle_new_user / is_estate_owner). This file is now the VC record;
-- re-apply on DB reset.

create or replace function public.is_admin()
 returns boolean
 language sql
 stable
 security definer
 set search_path to 'public'
as $function$
  select exists (select 1 from public.admins where user_id = auth.uid());
$function$;
