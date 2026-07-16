-- 0026_20260716_jurisdiction_policy — Slice C3 (part 1): the ordered verification-level type + the counsel-
-- owned jurisdiction floor config table + the admin write path.
--
-- This is COUNSEL'S table: engineering builds the MECHANISM, counsel populates the VALUES (real per-
-- jurisdiction floors) as approved rows LATER. It ships EMPTY — the "unmapped = maximum" default is a CODE
-- invariant in required_verification_level() (0027), NOT a seed row, so it can't be broken by deleting a row.
--
-- verification_level is a Postgres ENUM: the ordering IS the type (declaration order = rank), so GREATEST()
-- and comparisons are native and single-sourced — monotonicity can't drift from a separate rank mapping. A
-- new level slots in via `ALTER TYPE verification_level ADD VALUE '<x>' BEFORE/AFTER '<y>'` (positional).
--
-- is_counsel_approved is the DATA-GATE the release keystone (C5) reads: a row that exists but is unapproved
-- is NOT usable — the policy function treats it as unmapped -> enhanced_kyc.
--
-- RLS posture: the policy matrix is an ATTACK MAP (it tells an attacker which jurisdiction needs the least
-- verification) — it is world-UNREADABLE by clients. NO anon/authenticated grant. Reads happen only inside
-- the DEFINER policy function (owner=postgres, bypasses RLS) and admin RPCs. Writes are admin-only + audited
-- (changing a legal floor is high-consequence — reuse the break-glass-grade accountability).

begin;

-- Ordered verification level. attestation < kyc < enhanced_kyc (by declaration order).
do $$ begin
  if not exists (select 1 from pg_type where typname = 'verification_level') then
    create type public.verification_level as enum ('attestation', 'kyc', 'enhanced_kyc');
  end if;
end $$;

create table if not exists public.jurisdiction_policy (
  jurisdiction        text        not null,
  floor_level         public.verification_level not null,
  is_counsel_approved boolean     not null default false,
  notes               text,
  updated_by          uuid        references auth.users(id),
  updated_at          timestamptz not null default now(),
  created_at          timestamptz not null default now(),
  constraint jurisdiction_policy_pkey primary key (jurisdiction)
);

-- World-unreadable: RLS on, NO client grants (born clean). The DEFINER policy function + admin RPCs are the
-- ONLY readers; a direct client SELECT is denied at the grant layer (never reaches RLS).
alter table public.jurisdiction_policy enable row level security;
-- (intentionally no policies + no anon/authenticated grants — the matrix is not client-readable.)

-- ==================================================================================================
-- set_jurisdiction_floor — the ADMIN write path (upsert one jurisdiction's floor). Gated inside
-- (admin_require_gate) + mandatory justification (reason/case_ref) + a HIGH-severity source='admin' audit
-- carrying old->new. A counsel floor change is exactly the act you want an immutable trail of.
-- ==================================================================================================
create or replace function public.set_jurisdiction_floor(
  p_jurisdiction text,
  p_floor_level  public.verification_level,
  p_is_approved  boolean,
  p_notes        text,
  p_reason       text,
  p_case_ref     text
)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_old text;
begin
  perform public.admin_require_gate();                       -- auth -> is_admin -> aal2 -> 15-min freshness
  perform public.require_breakglass_justification(p_reason, p_case_ref);
  if p_jurisdiction is null or length(btrim(p_jurisdiction)) = 0 then
    raise exception 'jurisdiction_required' using errcode = 'P0001';
  end if;

  select floor_level::text into v_old from public.jurisdiction_policy where jurisdiction = p_jurisdiction;

  insert into public.jurisdiction_policy
    (jurisdiction, floor_level, is_counsel_approved, notes, updated_by, updated_at)
  values
    (p_jurisdiction, p_floor_level, p_is_approved, p_notes, auth.uid(), now())
  on conflict (jurisdiction) do update
    set floor_level         = excluded.floor_level,
        is_counsel_approved = excluded.is_counsel_approved,
        notes               = excluded.notes,
        updated_by          = excluded.updated_by,
        updated_at          = now();

  perform public.write_admin_breakglass_audit(
    'admin.jurisdiction_floor.set', 'jurisdiction_policy', null, null, p_reason, p_case_ref,
    jsonb_build_object('jurisdiction', p_jurisdiction, 'old_floor', v_old,
                       'new_floor', p_floor_level::text, 'is_counsel_approved', p_is_approved));
end;
$function$;
revoke execute on function public.set_jurisdiction_floor(text, public.verification_level, boolean, text, text, text)
  from public, anon;
grant  execute on function public.set_jurisdiction_floor(text, public.verification_level, boolean, text, text, text)
  to authenticated;

-- ==================================================================================================
-- admin_list_jurisdiction_policy — admins/counsel view the matrix (the ONLY read RPC; clients cannot).
-- ==================================================================================================
create or replace function public.admin_list_jurisdiction_policy()
 returns table(
   jurisdiction text, floor_level text, is_counsel_approved boolean,
   notes text, updated_by uuid, updated_at timestamptz
 )
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  perform public.admin_require_gate();
  return query
    select j.jurisdiction, j.floor_level::text, j.is_counsel_approved, j.notes, j.updated_by, j.updated_at
    from public.jurisdiction_policy j
    order by j.jurisdiction;
end;
$function$;
revoke execute on function public.admin_list_jurisdiction_policy() from public, anon;
grant  execute on function public.admin_list_jurisdiction_policy() to authenticated;

commit;
