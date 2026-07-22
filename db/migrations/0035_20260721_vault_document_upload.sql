-- 0035_20260721_vault_document_upload — owner vault-document CREATE + UPDATE, made REAL (direct-to-Supabase).
--
-- Makes owner vault uploads durable. The owner uploads bytes direct-to-storage (RLS-gated by 0030 —
-- documents_estate_insert lets the OWNER write anywhere under estates/<estate_id>/, no subfolder limit), THEN
-- calls create_vault_document, which validates + creates the documents row. INHERITS, unchanged:
--   * storage RLS (0030): owner-writes-anywhere-in-own-estate — NO storage-policy change needed here.
--   * documents_write tightening (0030): NO client INSERT/UPDATE/DELETE — row mutation is DEFINER-RPC-ONLY.
--   * ★ the 72h forward-compat invariant (0034 orphan sweeper): the row MUST exist within the grace window or
--     the sweeper reclaims the object. This flow is upload→immediately-RPC (seconds), NO draft/staging/resumable
--     step — so the row always lands well inside the window. Any future vault writer stays bound by this.
--
-- ★ PERSIST-BOTH TAXONOMY (lookup-table validated, subtype-in / both-out). The client's picker vocabulary is
--   fine-grained (~132 VaultDocumentType subtypes); public.documents.doc_type is a COARSE 11-value CHECK. So:
--   (1) public.document_subtype is the server catalog: subtype -> coarse doc_type (+ is_active gate), seeded from
--       the iOS VaultDocumentType.legacyCategory mapping (the SINGLE source of the derivation — the client never
--       sends doc_type). (2) The client sends ONLY the subtype; the RPC LOOKS IT UP (unknown -> unknown_subtype;
--       present-but-inactive -> inactive_subtype), DERIVES the coarse doc_type, and PERSISTS BOTH (doc_subtype =
--       the fine value, doc_type = the derived coarse value). documents.doc_subtype is NULLABLE + FK to the
--       catalog: claim evidence rows (submit_claim_with_evidence) stay COARSE-ONLY (doc_subtype NULL, doc_type
--       set directly) — the coarse door is unaffected. Drift note: the catalog is seeded to equal the iOS enum;
--       a client subtype absent from the catalog fails CLOSED (reject), so an enum that outgrows the catalog is
--       safe (a re-seed migration widens it). A get_document_subtypes() client read is a deferred nicety.
--
-- ★ MULTI-SOURCE AGREEMENT (create, the security core — same discipline as submit_claim_with_evidence 0031).
--   Independently-derived estate facts must ALL agree or reject — without it an owner of estate A could upload
--   under A (storage allows) then create the row under B, smuggling a doc across estates:
--     (a) p_estate                        — the parameter
--     (b) the estate in p_storage_path    — strict regex: exactly estates/<p_estate>/vault/<p_doc_id>.<ext>
--                                            (kills traversal + ties the row id to the object)
--     (c) the row's estate_id             — written = p_estate
--     (d) is_estate_owner(p_estate)       — ownership (estates.owner_id = auth.uid())
--   size/mime are read from storage.objects (authoritative — the client's are never trusted); the object MUST
--   already exist (upload→RPC order → no orphan ROWS). Per-file limit + MIME allowlist come from upload_policy
--   (the SAME row get_upload_policy returns to the client — "told == enforced", the C1.6a lesson).
--
-- ★ UPDATE is METADATA-ONLY, and the IMMUTABLE fields are UNREPRESENTABLE — update_vault_document accepts ONLY
--   p_title / p_doc_subtype / p_sensitivity. estate_id, owner_id, storage_path, mime_type, size_bytes,
--   is_encrypted, created_at are NOT parameters, so they cannot be touched (the strongest "rejected/ignored":
--   there is no param to send). Owner gate is on the ROW's estate_id. A subtype change RE-DERIVES doc_type from
--   the catalog (same unknown/inactive rejections). Audit records the CHANGED FIELD NAMES, never the values.
--
-- Endpoint? NO — create/update are Supabase-direct DEFINER RPCs (client.rpc), like the claim path → api stays
-- 12/12. is_encrypted = false (V1; real envelope encryption is a deferred master-key-custody question — the
-- encrypted path is the separate encrypted_instructions table). EXECUTE authenticated, gate inside, REVOKE
-- public/anon. Captured to VC: db/tables/document_subtype.sql, db/tables/documents.sql (doc_subtype note),
-- db/functions/create_vault_document.sql, db/functions/update_vault_document.sql.
--
-- NEXT SLICE (recon-first, NOT built here): vault document lifecycle — REPLACE + DELETE. Locked constraints:
-- the authorized DB mutation + a durable storage-deletion OUTBOX event commit in ONE tx (byte deletion runs
-- post-commit, retried on failure); the orphan sweeper is the BACKSTOP, not the primary path (sensitive bytes
-- aren't intentionally kept 72h); immutable audit TOMBSTONE + purge status per object; replace = atomically
-- switch to the new object THEN enqueue deletion of the former; BLOCK permanent deletion under legal hold, an
-- ACTIVE CLAIM (claim_packets.death_certificate_doc_id / executor_id_doc_id pin their evidence), or a mandatory
-- retention policy. Open: who drains the outbox (this project has no scheduled runtime; the sweeper is
-- admin-triggered) + the claim-reference check.

begin;

-- ---- 1. document_subtype: the server catalog (subtype -> coarse doc_type; is_active gate). Born clean:
--         RLS on, NO client grants — validated/read inside the DEFINER RPCs only. ----
create table if not exists public.document_subtype (
  subtype    text primary key,
  doc_type   text not null
               check (doc_type in ('will','trust','power_of_attorney','insurance_policy','deed',
                      'id_document','tax_return','medical_directive','beneficiary_form','death_certificate','other')),
  is_active  boolean     not null default true,
  created_at timestamptz not null default now()
);

alter table public.document_subtype enable row level security;
-- No client GRANTS and no policies (born clean): the DEFINER RPCs read it as owner; no client read path in V1.

-- Seed = iOS VaultDocumentType.legacyCategory (EstateDocument.swift). subtype-in/both-out derives doc_type here.
insert into public.document_subtype (subtype, doc_type) values
  ('will', 'will'),
  ('trustDocument', 'trust'),
  ('powerOfAttorney', 'power_of_attorney'),
  ('medicalPowerOfAttorney', 'power_of_attorney'),
  ('beneficiaryDesignationForm', 'beneficiary_form'),
  ('driversLicense', 'id_document'),
  ('passport', 'id_document'),
  ('stateID', 'id_document'),
  ('birthCertificate', 'id_document'),
  ('socialSecurityCard', 'id_document'),
  ('marriageCertificate', 'id_document'),
  ('divorceDecree', 'id_document'),
  ('adoptionRecords', 'id_document'),
  ('immigrationDocuments', 'id_document'),
  ('greenCard', 'id_document'),
  ('naturalizationCertificate', 'id_document'),
  ('lifeInsurancePolicy', 'insurance_policy'),
  ('wholeLifeCashValueStatement', 'insurance_policy'),
  ('termLifePolicy', 'insurance_policy'),
  ('healthInsurancePolicy', 'insurance_policy'),
  ('disabilityInsurancePolicy', 'insurance_policy'),
  ('longTermCarePolicy', 'insurance_policy'),
  ('autoInsurancePolicy', 'insurance_policy'),
  ('homeownersInsurancePolicy', 'insurance_policy'),
  ('umbrellaInsurancePolicy', 'insurance_policy'),
  ('annuityContract', 'insurance_policy'),
  ('taxReturn', 'tax_return'),
  ('w2', 'tax_return'),
  ('form1099', 'tax_return'),
  ('k1', 'tax_return'),
  ('propertyTaxRecord', 'tax_return'),
  ('estateTaxDocument', 'tax_return'),
  ('giftTaxDocument', 'tax_return'),
  ('irsNotice', 'tax_return'),
  ('cpaLetter', 'tax_return'),
  ('taxPlanningNotes', 'tax_return'),
  ('propertyDeed', 'deed'),
  ('advanceHealthcareDirective', 'other'),
  ('livingWill', 'other'),
  ('letterOfInstruction', 'other'),
  ('funeralBurialInstructions', 'other'),
  ('executorInstructions', 'other'),
  ('guardianshipInstructions', 'other'),
  ('bankStatement', 'other'),
  ('brokerageStatement', 'other'),
  ('retirementAccountStatement', 'other'),
  ('document401k', 'other'),
  ('iraDocument', 'other'),
  ('plan529Document', 'other'),
  ('pensionDocument', 'other'),
  ('loanDocument', 'other'),
  ('mortgageStatement', 'other'),
  ('creditCardStatement', 'other'),
  ('debtRecord', 'other'),
  ('accountClosureInstruction', 'other'),
  ('mortgageDocument', 'other'),
  ('leaseAgreement', 'other'),
  ('propertyAppraisal', 'other'),
  ('homeInventory', 'other'),
  ('vehicleTitle', 'other'),
  ('boatTitle', 'other'),
  ('landOwnershipRecord', 'other'),
  ('propertyInsuranceDocument', 'other'),
  ('businessFormationDocument', 'other'),
  ('operatingAgreement', 'other'),
  ('corporateBylaws', 'other'),
  ('stockCertificate', 'other'),
  ('capTable', 'other'),
  ('businessTaxRecord', 'other'),
  ('partnershipAgreement', 'other'),
  ('buySellAgreement', 'other'),
  ('businessInsuranceDocument', 'other'),
  ('businessSuccessionPlan', 'other'),
  ('cryptoWalletInventory', 'other'),
  ('hardwareWalletLocationReference', 'other'),
  ('exchangeAccountStatement', 'other'),
  ('digitalAssetInventory', 'other'),
  ('nftOwnershipRecord', 'other'),
  ('cryptoTaxReport', 'other'),
  ('recoveryLocationReference', 'other'),
  ('medicalRecord', 'other'),
  ('prescriptionList', 'other'),
  ('doctorContactList', 'other'),
  ('healthcareDirective', 'other'),
  ('insuranceCard', 'other'),
  ('emergencyMedicalInformation', 'other'),
  ('carePlan', 'other'),
  ('disabilityRecord', 'other'),
  ('courtOrder', 'other'),
  ('settlementAgreement', 'other'),
  ('legalAgreement', 'other'),
  ('attorneyLetter', 'other'),
  ('probateDocument', 'other'),
  ('lettersTestamentary', 'other'),
  ('notarizedDocument', 'other'),
  ('contract', 'other'),
  ('beneficiaryID', 'other'),
  ('familyContactList', 'other'),
  ('dependentInformation', 'other'),
  ('emergencyContactList', 'other'),
  ('caregiverInstructions', 'other'),
  ('minorChildInstructions', 'other'),
  ('petCareInstructions', 'other'),
  ('diploma', 'other'),
  ('certificate', 'other'),
  ('professionalLicense', 'other'),
  ('resume', 'other'),
  ('employmentContract', 'other'),
  ('awardLetter', 'other'),
  ('referenceLetter', 'other'),
  ('trainingCertificate', 'other'),
  ('militaryID', 'other'),
  ('dd214', 'other'),
  ('veteransBenefitsDocument', 'other'),
  ('governmentBenefitsLetter', 'other'),
  ('socialSecurityBenefitsDocument', 'other'),
  ('pensionBenefitsDocument', 'other'),
  ('award', 'other'),
  ('certificateOfAchievement', 'other'),
  ('professionalRecognition', 'other'),
  ('publishedWork', 'other'),
  ('patentDocument', 'other'),
  ('businessMilestone', 'other'),
  ('charityCommunityServiceRecord', 'other'),
  ('personalLetter', 'other'),
  ('lifeStoryDocument', 'other'),
  ('familyHistory', 'other'),
  ('photosMemorabiliaReference', 'other'),
  ('legacyMessage', 'other'),
  ('personalValuesStatement', 'other'),
  ('customDocument', 'other'),
  ('miscellaneousRecord', 'other')
on conflict (subtype) do nothing;

-- ---- 2. documents.doc_subtype — the persisted FINE value (nullable; claim rows stay coarse-only = NULL).
--         FK to the catalog for referential integrity (a bogus subtype can never land, even from a future
--         writer). is_active is orthogonal: existing rows keep a now-inactive subtype; new create/update reject
--         inactive in-RPC. ----
alter table public.documents
  add column if not exists doc_subtype text references public.document_subtype(subtype);

-- ---- 3. create_vault_document — owner-gated, agreement-verified, object-exists, policy-quota'd, ONE row. ----
create or replace function public.create_vault_document(
  p_estate       uuid,
  p_doc_id       uuid,
  p_storage_path text,
  p_title        text,
  p_doc_subtype  text,
  p_sensitivity  text default 'sealed'
)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid       uuid := auth.uid();
  v_doc_type  text;
  v_size      bigint;
  v_mime      text;
  v_max_bytes bigint;
  v_mimes     text[];
begin
  -- (d) auth + ownership.
  if v_uid is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;
  if not public.is_estate_owner(p_estate) then
    raise exception 'not_estate_owner' using errcode = '42501';
  end if;
  if not exists (select 1 from public.estates where id = p_estate) then
    raise exception 'estate_not_found' using errcode = 'P0002';
  end if;

  -- Title (attacker-influenced text, but the owner's own doc; stored as text, rendered escaped). Trim + bound.
  if p_title is null or length(btrim(p_title)) = 0 then
    raise exception 'title_required' using errcode = 'P0001';
  end if;
  if length(p_title) > 200 then
    raise exception 'title_too_long' using errcode = 'P0001';
  end if;

  -- subtype-in / both-out: derive the coarse doc_type from the catalog; distinguish unknown vs inactive.
  select ds.doc_type into v_doc_type
    from public.document_subtype ds
    where ds.subtype = p_doc_subtype and ds.is_active;
  if not found then
    if exists (select 1 from public.document_subtype where subtype = p_doc_subtype) then
      raise exception 'inactive_subtype' using errcode = 'P0001';
    else
      raise exception 'unknown_subtype' using errcode = 'P0001';
    end if;
  end if;

  -- sensitivity: server 5-value vocabulary (the CHECK backstops; the client maps its own scale to this).
  if p_sensitivity is not null
     and p_sensitivity not in ('low','medium','high','restricted','sealed') then
    raise exception 'invalid_sensitivity' using errcode = 'P0001';
  end if;

  -- (a)==(b) path agreement + traversal kill + doc_id<->object linkage: exactly estates/<p_estate>/vault/<p_doc_id>.<ext>
  if p_storage_path !~ ('^estates/' || p_estate::text || '/vault/' || p_doc_id::text || '\.[a-zA-Z0-9]+$') then
    raise exception 'vault_path_mismatch' using errcode = 'P0001';
  end if;

  -- Object MUST already exist (upload->RPC → no orphan rows); size/mime read from storage (never trusted).
  select (o.metadata->>'size')::bigint, o.metadata->>'mimetype' into v_size, v_mime
    from storage.objects o where o.bucket_id = 'documents' and o.name = p_storage_path;
  if not found then
    raise exception 'vault_object_missing' using errcode = 'P0002';
  end if;

  -- Policy quota (from upload_policy — the SAME row the client is told via get_upload_policy).
  select max_upload_bytes, allowed_mime_types into v_max_bytes, v_mimes
    from public.upload_policy where id = 1;
  if coalesce(v_size, 0) > v_max_bytes then
    raise exception 'vault_too_large' using errcode = 'P0001';
  end if;
  if v_mime is null or not (v_mime = any(v_mimes)) then
    raise exception 'vault_mime_rejected' using errcode = 'P0001';
  end if;

  -- (c) estate_id = p_estate. Persist BOTH doc_type (derived) + doc_subtype (fine). owner_id server-stamped.
  insert into public.documents
    (id, estate_id, owner_id, doc_type, doc_subtype, title, storage_path, mime_type, size_bytes, is_encrypted, sensitivity)
  values
    (p_doc_id, p_estate, v_uid, v_doc_type, p_doc_subtype, btrim(p_title), p_storage_path, v_mime, v_size, false,
     coalesce(p_sensitivity, 'sealed'));

  perform public.write_audit('document.created', 'documents', p_doc_id, p_estate,
    jsonb_build_object('doc_id', p_doc_id, 'doc_type', v_doc_type, 'doc_subtype', p_doc_subtype,
                       'via', 'create_vault_document'));

  return p_doc_id;
end;
$function$;

revoke execute on function public.create_vault_document(uuid, uuid, text, text, text, text) from public, anon;
grant  execute on function public.create_vault_document(uuid, uuid, text, text, text, text) to authenticated;

-- ---- 4. update_vault_document — METADATA-ONLY. Immutable fields are UNREPRESENTABLE (not params). Owner gate
--         on the ROW's estate_id. Subtype change re-derives doc_type. Audit = changed field NAMES only. ----
create or replace function public.update_vault_document(
  p_doc_id      uuid,
  p_title       text default null,
  p_doc_subtype text default null,
  p_sensitivity text default null
)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid         uuid := auth.uid();
  v_estate      uuid;
  v_new_type    text;
  v_changed     text[] := '{}';
begin
  if v_uid is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;

  -- Resolve the row + gate on ITS estate_id (never a param — the row is authoritative).
  select estate_id into v_estate from public.documents where id = p_doc_id;
  if not found then
    raise exception 'document_not_found' using errcode = 'P0002';
  end if;
  if not public.is_estate_owner(v_estate) then
    raise exception 'not_estate_owner' using errcode = '42501';
  end if;

  if p_title is null and p_doc_subtype is null and p_sensitivity is null then
    raise exception 'no_fields_to_update' using errcode = 'P0001';
  end if;

  if p_title is not null then
    if length(btrim(p_title)) = 0 then
      raise exception 'title_required' using errcode = 'P0001';
    end if;
    if length(p_title) > 200 then
      raise exception 'title_too_long' using errcode = 'P0001';
    end if;
    update public.documents set title = btrim(p_title) where id = p_doc_id;
    v_changed := array_append(v_changed, 'title');
  end if;

  if p_doc_subtype is not null then
    select ds.doc_type into v_new_type
      from public.document_subtype ds
      where ds.subtype = p_doc_subtype and ds.is_active;
    if not found then
      if exists (select 1 from public.document_subtype where subtype = p_doc_subtype) then
        raise exception 'inactive_subtype' using errcode = 'P0001';
      else
        raise exception 'unknown_subtype' using errcode = 'P0001';
      end if;
    end if;
    update public.documents set doc_subtype = p_doc_subtype, doc_type = v_new_type where id = p_doc_id;
    v_changed := array_append(v_changed, 'doc_subtype');
    v_changed := array_append(v_changed, 'doc_type');   -- re-derived from the subtype
  end if;

  if p_sensitivity is not null then
    if p_sensitivity not in ('low','medium','high','restricted','sealed') then
      raise exception 'invalid_sensitivity' using errcode = 'P0001';
    end if;
    update public.documents set sensitivity = p_sensitivity where id = p_doc_id;
    v_changed := array_append(v_changed, 'sensitivity');
  end if;

  perform public.write_audit('document.updated', 'documents', p_doc_id, v_estate,
    jsonb_build_object('doc_id', p_doc_id, 'changed', to_jsonb(v_changed), 'via', 'update_vault_document'));
end;
$function$;

revoke execute on function public.update_vault_document(uuid, text, text, text) from public, anon;
grant  execute on function public.update_vault_document(uuid, text, text, text) to authenticated;

commit;
