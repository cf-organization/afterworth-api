-- 0030_20260719_claim_evidence_storage_rls — Slice C1.6a: storage.objects RLS rewrite + documents_write
-- tightening, so live executor evidence can flow from the app via DIRECT-TO-STORAGE upload (RLS is the gate;
-- no api endpoint → api stays 12/12). Lands WITH the upload (the docs_owner_rw bug was LATENT until a client
-- storage op existed; C1.6a is that op).
--
-- storage.objects: the only policy was docs_owner_rw — (storage.foldername(name))[1] = auth.uid() — which
-- matched NOBODY, because every real object is estates/<estate_id>/…  (first segment a literal, never a uid).
-- Replace it with estate-ANCHORED SELECT + INSERT policies: authorization derives from the PATH,
-- foldername[2] = the estate id. Owner reads/writes anywhere in their estate; an executor ONLY under the
-- claim-evidence subfolder (write-side traversal killed — an authenticated user cannot write into an estate
-- they are not owner/executor of, nor outside claim-evidence). ADMINS ARE NOT IN THESE POLICIES — they read
-- evidence via the C1.6b service-role endpoint (audited claim.evidence_viewed), keeping that the SOLE admin
-- door. UPDATE/DELETE ungranted: evidence is append-only, a re-upload is a new doc_id. A STRICT uuid regex
-- guards the ::uuid cast so a malformed path segment fails CLOSED (clean deny) instead of erroring the query.
--
-- public.documents: TIGHTEN — the live documents_write (ALL / owner_id = auth.uid(); a live-vs-VC divergence,
-- grants.sql did not reflect it) is DROPPED so there is NO client INSERT/UPDATE/DELETE path. ALL row creation
-- goes through DEFINER RPCs (submit_claim_with_evidence, migration 0031; the owner vault-doc RPC is the
-- fast-follow). Confirmed no live client write path: iOS uploadDocument/uploadClaimDocument are mock;
-- api/vault/documents.ts only .select. documents_read (can_access_document) is UNCHANGED — owner + grantee
-- SELECT still flow through it. The real documents RLS is captured into VC at db/tables/documents.sql.
--
-- PREREQ (dashboard, done by Christ before this migration): bucket documents file_size_limit = 25 MB; MIME
-- allowlist application/pdf, image/jpeg, image/png, image/heic; delete the 2 orphaned C1.6b seed objects at
-- the old claims/<claim>/ path (bytes outlived their rows; they don't match the new scheme).

begin;

drop policy if exists docs_owner_rw on storage.objects;

create policy documents_estate_read on storage.objects
  for select to authenticated
  using (
    bucket_id = 'documents'
    and (storage.foldername(name))[1] = 'estates'
    and (storage.foldername(name))[2] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and (
      public.is_estate_owner(((storage.foldername(name))[2])::uuid)
      or (
        public.is_estate_executor(((storage.foldername(name))[2])::uuid, auth.uid())
        and (storage.foldername(name))[3] = 'claim-evidence'
      )
    )
  );

create policy documents_estate_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'documents'
    and (storage.foldername(name))[1] = 'estates'
    and (storage.foldername(name))[2] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and (
      public.is_estate_owner(((storage.foldername(name))[2])::uuid)
      or (
        public.is_estate_executor(((storage.foldername(name))[2])::uuid, auth.uid())
        and (storage.foldername(name))[3] = 'claim-evidence'
      )
    )
  );

drop policy if exists documents_write on public.documents;

commit;
