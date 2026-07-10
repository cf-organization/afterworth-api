-- public.ensure_primary_user_membership() — CAPTURED FROM LIVE 2026-07-09. LIVE IS AUTHORITATIVE.
--
-- AFTER-INSERT trigger on public.estates: auto-provisions the owner's own `primary_user`/`approved`
-- membership the moment an estate is created, so an owner never lacks a membership row (Pattern B:
-- all access via estate_memberships). Was LIVE-ONLY (invisible-object class); re-apply the FUNCTION
-- on a DB reset. The trigger binding already exists live — do NOT recreate it on a live DB.
--
-- DEPENDENCY NOTE: uses gen_random_uuid() (pgcrypto, in the `extensions` schema), which is why the
-- function pins `search_path = 'public', 'extensions'` — dropping `extensions` from the path would
-- break the id default at runtime. `on conflict do nothing` makes it idempotent against the
-- estate_memberships UNIQUE(estate_id,user_id) + one_primary_user_per_estate constraints (a re-fire
-- or race can't create a duplicate primary membership). Pairs with check_primary_user_matches_owner
-- (which then verifies user_id = estates.owner_id for that primary row).

create or replace function public.ensure_primary_user_membership()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
begin
  insert into public.estate_memberships
    (id, estate_id, user_id, role, status, approved_at, created_at)
  values
    (gen_random_uuid(),
     new.id,
     new.owner_id,
     'primary_user',
     'approved',
     now(),
     now())
  on conflict do nothing;

  return new;
end;
$function$;

-- Trigger binding — already live; here for the from-scratch rebuild record only. Do NOT run on a DB
-- that already has the trigger.
--   create trigger estates_ensure_primary_user_membership
--     after insert on public.estates
--     for each row execute function public.ensure_primary_user_membership();
