-- public.list_estate_members(p_estate_id uuid)
--   -> TABLE(user_id uuid, role text, status text, email text)
--
-- Owner-facing listing of an estate's NON-OWNER members (the grantable / request-eligible
-- set: beneficiary + professional_delegate). Two consumers, both owner-side:
--   (a) owner-review: resolve a request's requester_user_id -> a display label (email);
--   (b) grant UI grantee picker: enumerate professionals (and beneficiaries) to grant.
-- See docs/live-data-migration.md Appendix A + PROGRESS.md (members-endpoint slice).
--
-- WHY AN RPC, NOT A PLAIN SELECT (unlike grants/list): the display label is the member's
-- email, which lives on public.profiles — a user CANNOT read another user's profiles row
-- under RLS. So the listing must cross the profiles RLS boundary, which a plain authed
-- select can't. SECURITY DEFINER runs as the table owner and BYPASSES RLS, making the
-- estate_memberships x profiles join readable. Because DEFINER bypasses RLS, the explicit
-- is_estate_owner(p_estate_id) check below IS the access boundary (the FIRST check after the
-- auth.uid() null-guard) — without it ANY authenticated user could enumerate another
-- estate's member emails. A non-owner / non-member fails the gate -> 42501 -> 403 (the
-- endpoint reveals nothing, not even emptiness). The owner already knows these emails (they
-- invited by email), so this is owner-scoped disclosure of data the owner already holds.
--
-- EMAIL-AS-LABEL (honest interim): there is NO real "name" for a member in the schema —
-- beneficiaries carry beneficiaries.full_name (owner-provided), but estate_memberships has
-- no name and profiles has email/phone, no name. So email is the display label; the iOS
-- picker falls back to a uid-prefix only if email is null. A proper name needs a
-- profiles.name column (a separate concern, NOT this slice). professional_type is NOT on
-- estate_memberships (it lives only on access_grants, chosen at grant time), so it is not
-- returned here — the grant RPC accepts p_professional_type when the owner grants.
--
-- NON-OWNER + APPROVED + DISTINCT: filtered to status='approved' AND
-- not is_ownership_role(role) — the same canonical "eligible non-owner member" predicate
-- create_access_request gates on. The ownership exclusion stays IN the WHERE (not a post
-- filter): estate_memberships has NO (estate,user) uniqueness, so a user may hold multiple
-- approved rows; SELECT DISTINCT collapses duplicate (user_id, role) pairs so a member with
-- two beneficiary rows appears once, while a genuine dual-role member (beneficiary AND
-- professional_delegate) correctly appears as two distinct pickable entries (the role drives
-- the ceiling). Owners are excluded — they have inherent access and the grant RPC rejects
-- owner grantees anyway.
--
-- Error codes (SQLSTATE -> PostgREST HTTP status):
--   42501 -> 403  unauthenticated (no auth.uid) / not_estate_owner (the privilege gate)
--
-- SECURITY DEFINER; relies on auth.uid(). Default EXECUTE is PUBLIC (matches the other
-- DEFINER RPCs — no explicit grant captured in VC; the gate, not the grant, is the
-- boundary). Source of truth — re-apply on DB reset.

create or replace function public.list_estate_members(p_estate_id uuid)
 returns table(user_id uuid, role text, status text, email text)
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare
  v_user uuid := auth.uid();
begin
  -- Auth null-guard.
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;

  -- SECURITY SPINE. SECURITY DEFINER bypasses RLS, so this explicit owner-check IS the
  -- access boundary and MUST precede the read.
  if not public.is_estate_owner(p_estate_id) then
    raise exception 'not estate owner' using errcode = '42501';
  end if;

  return query
    select distinct m.user_id, m.role, m.status, p.email
    from public.estate_memberships m
    join public.profiles p on p.id = m.user_id
    where m.estate_id = p_estate_id
      and m.status = 'approved'
      and not public.is_ownership_role(m.role)
    order by p.email;
end;
$function$;
