-- public.is_estate_member(p_estate_id uuid) -> boolean — CAPTURED FROM LIVE 2026-07-10. LIVE AUTHORITATIVE.
--
-- True iff the caller (auth.uid()) holds an APPROVED membership in the estate. SECURITY DEFINER (reads
-- estate_memberships bypassing its RLS as the owner) + STABLE, search_path 'public'. Was live-only —
-- referenced by the captured `estates_member_read` / `invitations_member_read` policies, and
-- historically by the pre-tightening `documents_read` / `beneficiaries_read` quals (0001/0002 moved
-- those OFF this broad membership check to grant-based reads — see those migration comments; this
-- helper is deliberately NOT used for document/asset visibility any more). No drift vs the call sites.

create or replace function public.is_estate_member(p_estate_id uuid)
 returns boolean
 language sql
 stable
 security definer
 set search_path to 'public'
as $function$
  select exists (
    select 1 from estate_memberships
    where estate_id = p_estate_id
      and user_id = auth.uid()
      and status = 'approved'
  )
$function$;
