-- public.is_ownership_role(p_role text) -> boolean — CAPTURED FROM LIVE 2026-07-10. LIVE AUTHORITATIVE.
--
-- Centralizes the V1 "ownership role" definition so consumers never scatter role literals. V1: ONLY
-- 'primary_user' is an ownership role. The V2 expansion (co_owner / joint_tenant / trustee_owner)
-- extends the IN list HERE and nowhere else — that is the whole point of the helper. IMMUTABLE (pure).
-- Was live-only (referenced 9× across db/functions + the captured policies, never defined in VC).
--
-- Consumers: `is_ownership_role(m.role)` = "the owner row" (create_document_grant / create_asset_grant /
-- resolve_membership primary bucket); `not is_ownership_role(m.role)` = "eligible non-owner member"
-- i.e. beneficiary / professional_delegate (list_estate_members, create/approve_access_request,
-- resolve_membership non-owner bucket). Behaviour matches every call site — no drift.
--
-- CAPTURE NOTE: search_path pins 'public','extensions' though the body (a trivial IN test) needs
-- neither — harmless, kept verbatim as live.

create or replace function public.is_ownership_role(p_role text)
 returns boolean
 language sql
 immutable
 set search_path to 'public', 'extensions'
as $function$
  SELECT p_role IN ('primary_user');
$function$;
