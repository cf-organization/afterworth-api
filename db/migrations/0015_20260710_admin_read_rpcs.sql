-- 0015_20260710_admin_read_rpcs — the two admin READ RPCs + keyset indexes (Posture B).
--
-- Client-reachable via PostgREST rest/v1/rpc/... (there is NO Vercel endpoint this slice — the
-- console, Slice 3, will front these; PostgREST-direct IS the product interface until then, which is
-- exactly why the gate lives INSIDE each function, curl-proven at the raw door). Both RPCs run the
-- SAME gate preamble via admin_require_gate() before any read.

begin;

-- ---------------------------------------------------------------------------------------------------
-- Shared gate — enforced INSIDE both RPCs (a direct PostgREST caller cannot skip it). Order matters.
-- ---------------------------------------------------------------------------------------------------
create or replace function public.admin_require_gate()
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  -- (a) authenticated at all?
  if auth.uid() is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;
  -- (b) an admin? (is_admin() is DEFINER — reads admins bypassing its deny-all RLS)
  if not public.is_admin() then
    raise exception 'admin_required' using errcode = '42501';
  end if;
  -- (c) MFA / aal2 — reuse the shared financial gate verbatim (raises 'mfa_required' / 42501).
  perform public.require_aal2();
  -- (d) token freshness: `iat` is a Unix-epoch INTEGER (verified live 2026-07-10 by decoding a real
  --     JWT — not trusted from a doc). Deny a token issued more than 15 min ago. FAIL-CLOSED on a
  --     missing iat (coalesce -> 0 -> ancient -> stale).
  if extract(epoch from now())::bigint - coalesce((auth.jwt() ->> 'iat')::bigint, 0) > 900 then
    raise exception 'stale_token_reauth_required' using errcode = '42501';
  end if;
end;
$function$;
-- internal only: the DEFINER RPCs call it AS the owner; no client needs EXECUTE.
revoke execute on function public.admin_require_gate() from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------
-- admin_list_audit — keyset-paginated full audit read (admins see full rows — that IS the job).
-- Keyset on (created_at, id) DESC (expanded form, NULL-safe). LIMIT clamped to [1,200], default 50.
-- DISPLAY-LAYER WARNING (console, Slice 3): rows with source='ios_forward' carry CLIENT-supplied
-- metadata + user_agent — the renderer MUST escape them (never treat ios_forward as trusted). This
-- RPC returns raw rows by design; escaping is the console's responsibility.
-- ---------------------------------------------------------------------------------------------------
create or replace function public.admin_list_audit(
  p_before_created timestamptz default null,
  p_before_id      bigint      default null,
  p_limit          int         default 50,
  p_estate         uuid        default null,
  p_actor          uuid        default null,
  p_action         text        default null,
  p_source         text        default null
)
 returns setof public.audit_logs
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  perform public.admin_require_gate();
  return query
    select *
    from public.audit_logs a
    where (p_estate is null or a.estate_id = p_estate)
      and (p_actor  is null or a.actor_id = p_actor)
      and (p_action is null or a.action  = p_action)
      and (p_source is null or a.source  = p_source)
      and (
        p_before_created is null
        or a.created_at < p_before_created
        or (a.created_at = p_before_created and a.id < coalesce(p_before_id, 9223372036854775807))
      )
    order by a.created_at desc, a.id desc
    limit least(greatest(coalesce(p_limit, 50), 1), 200);
end;
$function$;
revoke execute on function public.admin_list_audit(timestamptz, bigint, int, uuid, uuid, text, text) from public, anon;
grant  execute on function public.admin_list_audit(timestamptz, bigint, int, uuid, uuid, text, text) to authenticated;

-- ---------------------------------------------------------------------------------------------------
-- admin_reconciliation_report — the member/designation/grant integrity detector (productionized).
-- ---------------------------------------------------------------------------------------------------
create or replace function public.admin_reconciliation_report()
 returns table (issue text, estate_id uuid, ref_id uuid, detail jsonb)
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  perform public.admin_require_gate();
  return query
  -- (1) beneficiary designation with a stamped user_id but NO approved membership in that estate
  select 'designation_without_membership'::text, b.estate_id, b.id,
         jsonb_build_object('user_id', b.user_id, 'email', b.email, 'name', b.full_name)
  from public.beneficiaries b
  where b.user_id is not null
    and not exists (select 1 from public.estate_memberships m
                    where m.estate_id = b.estate_id and m.user_id = b.user_id and m.status = 'approved')
  union all
  -- (2) active grant whose grantee has NO approved membership in that estate
  select 'grant_without_membership'::text, g.estate_id, g.id,
         jsonb_build_object('grantee_user_id', g.grantee_user_id, 'grantee_role', g.grantee_role)
  from public.access_grants g
  where g.status = 'active'
    and not exists (select 1 from public.estate_memberships m
                    where m.estate_id = g.estate_id and m.user_id = g.grantee_user_id and m.status = 'approved')
  union all
  -- (3) MIS-STAMP (fixture #1's shape): a beneficiary row whose stamped user_id's profile email
  --     differs from the designation email — the self-link landed on the wrong user.
  select 'email_user_id_mismatch'::text, b.estate_id, b.id,
         jsonb_build_object('beneficiary_email', b.email, 'stamped_user_id', b.user_id, 'profile_email', p.email)
  from public.beneficiaries b
  join public.profiles p on p.id = b.user_id
  where b.user_id is not null
    and b.email is not null
    and lower(p.email) <> lower(b.email)
  union all
  -- (4) INVARIANT CANARY: duplicate (estate,user) memberships — MUST return 0 rows (the UNIQUE
  --     constraint captured in Slice 0 makes this structurally impossible; kept as a live tripwire).
  select 'duplicate_membership_CANARY'::text, m.estate_id, m.user_id,
         jsonb_build_object('count', count(*))
  from public.estate_memberships m
  group by m.estate_id, m.user_id
  having count(*) > 1;
end;
$function$;
revoke execute on function public.admin_reconciliation_report() from public, anon;
grant  execute on function public.admin_reconciliation_report() to authenticated;

-- ---------------------------------------------------------------------------------------------------
-- Indexes — plain CREATE INDEX: audit_logs is tiny + pre-launch, so no CONCURRENTLY ceremony (that
-- only matters to avoid an ACCESS EXCLUSIVE lock on a hot production table). (created_at, id) serves
-- the global keyset feed; (source, created_at) serves the source-facet filter.
-- ---------------------------------------------------------------------------------------------------
create index if not exists audit_logs_created_at_id_idx    on public.audit_logs (created_at desc, id desc);
create index if not exists audit_logs_source_created_at_idx on public.audit_logs (source, created_at desc);

commit;
