-- public.get_upload_policy() -> TABLE(max_upload_bytes bigint, max_files_per_claim int,
--                                     max_aggregate_bytes bigint, allowed_mime_types text[])
--
-- Created by migration 0032 (upload contract unification). The CLIENT's read path for the evidence-upload
-- contract — called DIRECTLY via supabase-js (like submit_claim_with_evidence), so NO Vercel endpoint is
-- needed (api stays 12/12). Returns the singleton public.upload_policy row so C1.6a-iOS can warn BEFORE an
-- upload rather than after a rejection.
--
-- UX HONESTY ONLY — never the security boundary. The real gates are the bucket file_size_limit/MIME allowlist
-- (rejects at upload) and submit_claim_with_evidence's quotas (rejects at submit), both of which read/mirror
-- the SAME upload_policy values. DEFINER so authenticated reads the grant-less table. EXECUTE authenticated
-- only. Source of truth — re-apply on reset.

create or replace function public.get_upload_policy()
 returns table(max_upload_bytes bigint, max_files_per_claim int, max_aggregate_bytes bigint, allowed_mime_types text[])
 language sql
 security definer
 stable
 set search_path to 'public'
as $function$
  select p.max_upload_bytes, p.max_files_per_claim, p.max_aggregate_bytes, p.allowed_mime_types
  from public.upload_policy p where p.id = 1;
$function$;
revoke execute on function public.get_upload_policy() from public, anon;
grant  execute on function public.get_upload_policy() to authenticated;
