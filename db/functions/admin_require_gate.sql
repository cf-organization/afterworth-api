-- public.admin_require_gate() -> void   (raises 42501 on any failed check)
--
-- The shared ADMIN gate for the operator-console RPCs. Ordered auth -> is_admin -> aal2 -> token-freshness
-- (the SAME order the console middleware mirrors — a divergent order misreports WHY a caller is denied;
-- see the Slice-3 gate-order lesson). Reused verbatim by admin_list_invitations and
-- admin_create_executor_invitation. Client-reachable RPCs put this gate INSIDE the function (the DEFINER-door
-- discipline) — a direct PostgREST caller hits the exact same checks.
--
-- Sentinels: 'auth_required' / 'admin_required' / 'mfa_required' (via require_aal2) / 'stale_token_reauth_required'.
-- Freshness: `iat` is a Unix-epoch INTEGER (verified live by decoding a real JWT, not doc-trusted); deny a
-- token issued >15 min ago, FAIL-CLOSED on a missing iat (coalesce -> 0 -> ancient -> stale).
--
-- CAPTURED FROM LIVE 2026-07-15 — was live-only (migration 0015). This file is now the VC record; re-apply
-- on DB reset.

create or replace function public.admin_require_gate()
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  if auth.uid() is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;
  if not public.is_admin() then
    raise exception 'admin_required' using errcode = '42501';
  end if;
  perform public.require_aal2();
  if extract(epoch from now())::bigint - coalesce((auth.jwt() ->> 'iat')::bigint, 0) > 900 then
    raise exception 'stale_token_reauth_required' using errcode = '42501';
  end if;
end;
$function$;
