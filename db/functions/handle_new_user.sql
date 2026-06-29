-- public.handle_new_user()  — the auth.users AFTER INSERT trigger function that creates the
-- public.profiles row for a newly-signed-up user.
--
-- THE FIX (and this file's reason for existing): the live function inserted only (id, email)
-- and DISCARDED the display name that signup captures into auth metadata —
-- SupabaseAuthService.signUp seeds data:["full_name": …] → auth.users.raw_user_meta_data
-- ->>'full_name'. It now copies full_name into public.profiles.full_name, so REAL signups
-- populate the name the read surface consumes (list_estate_members → /api/vault/members →
-- iOS). Users seeded WITHOUT that metadata (SQL fixtures) get NULL full_name → correct email
-- fallback. (Backfill recovers names already sitting in auth metadata for pre-fix signups.)
--
-- This trigger was previously LIVE-ONLY (not version-controlled) — exactly the invisibility
-- that let the name-drop persist undetected. Captured here now. Re-apply the FUNCTION on a DB
-- reset; the trigger binding (below) already exists live — do NOT re-create it on a live DB
-- (a second trigger would double-insert and fail on the profiles PK).
--
-- CONFIRM-AGAINST-LIVE before applying: this is the standard Supabase pattern. Verify the
-- function body matches your live `prosrc` except the added full_name column/value — in
-- particular `set search_path`, `security definer`, and any `on conflict` / extra columns.
--
-- SECURITY DEFINER (writes public.profiles from an auth.users trigger). Source of truth.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  insert into public.profiles (id, email, full_name)
  values (new.id, new.email, new.raw_user_meta_data ->> 'full_name');
  return new;
end;
$function$;

-- Trigger binding — UNCHANGED by this fix (already live; here for the from-scratch rebuild
-- record only). Do NOT run on a DB that already has the trigger. Confirm the name/timing
-- against your pg_get_triggerdef output before relying on this for a rebuild:
--   create trigger on_auth_user_created
--     after insert on auth.users
--     for each row execute function public.handle_new_user();
