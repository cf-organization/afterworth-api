-- 0014_20260710_admin_foundation — the admin authorization primitive (Posture B).
--
-- Admin is a FOURTH actor class OUTSIDE the V1 role vocabulary (primary_user/beneficiary/
-- professional_delegate). Posture B: consumer RLS is UNTOUCHED; the admin capability is a separate
-- axis whose gate lives INSIDE every admin RPC (0015). This migration provides (1) the identity
-- table, (2) the is_admin() predicate, (3) audit provenance for admin-stamped rows.
--
-- BORN-CLEAN CLAIM (doubles as the 0012 default-priv proof): `admins` is the FIRST table created
-- after 0012's `ALTER DEFAULT PRIVILEGES FOR ROLE postgres … REVOKE ALL`. It must acquire NO
-- anon/authenticated/service_role grants at all. There is DELIBERATELY no belt-and-suspenders REVOKE
-- here — the born-clean claim must test ITSELF (verify post-create with aclexplode). If the
-- verification shows client grants, 0012's fix has a gap on this path — stop and investigate.

begin;

-- (1) admins — deny-all (RLS ENABLED, ZERO policies — the mfa_recovery_attempts precedent). Reads
--     happen ONLY inside is_admin() (SECURITY DEFINER). No grants added (born clean; see above).
create table if not exists public.admins (
  user_id    uuid primary key references auth.users(id),
  created_at timestamptz not null default now(),
  note       text
);
alter table public.admins enable row level security;

-- (2) is_admin() — the gate predicate. SECURITY DEFINER (reads admins bypassing its deny-all RLS as
--     the owner), STABLE, pinned search_path. Returns FALSE for non-admins (leaks nothing).
create or replace function public.is_admin()
 returns boolean
 language sql
 security definer
 stable
 set search_path to 'public'
as $function$
  select exists (select 1 from public.admins where user_id = auth.uid());
$function$;

-- EXECUTE: revoke the Postgres-default PUBLIC grant (load-bearing — the write_audit-forgery lesson)
-- + anon. GRANT to authenticated: the predicate leaks nothing (false for non-admins) AND the proof
-- matrix calls is_admin() DIRECTLY via PostgREST (probe g). The admin RPCs (0015) call is_admin()
-- INSIDE their own DEFINER bodies, so this grant serves the direct-probe path, not the RPC path.
revoke execute on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

-- (3) audit provenance: admit 'admin' as a source value (server-stamped INSIDE admin RPCs; never a
--     client parameter). Extends the 0011 CHECK ('server','ios_forward').
alter table public.audit_logs drop constraint if exists audit_logs_source_check;
alter table public.audit_logs add constraint audit_logs_source_check
  check (source in ('server', 'ios_forward', 'admin'));

commit;
