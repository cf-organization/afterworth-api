# Owner vault-document upload — proof (create + update)

**PROVEN GREEN (2026-07-21, curl matrix):** happy-path create (doc_type DERIVED from subtype, size/mime
SERVER-read, is_encrypted=false, title trimmed) · path-mismatch · non-owner · object-missing · over-limit
(policy-lower) · unknown-subtype · inactive-subtype · claim coarse-only regression (doc_subtype NULL) ·
update title+subtype (doc_type re-derived, audit changed-fields) · non-owner update denied · immutable-field
rejected (PGRST202, no param) · no-op update rejected. On-device relaunch persistence pending the iOS slice.

`create_vault_document` / `update_vault_document` (migration 0035). Owner uploads bytes direct-to-storage
(RLS 0030 allows the owner anywhere under `estates/<estate>/`), THEN calls the DEFINER RPC. Persist-both
taxonomy: client sends the fine `doc_subtype`; the RPC derives + persists the coarse `doc_type` from the
`document_subtype` catalog. Gate = `is_estate_owner` (aal1 is enough — NOT aal2). No Vercel endpoint (api 12/12).

## Environment
```bash
export URL=https://yiaavvkulrpqkkbqhwit.supabase.co
export PUB=sb_publishable_3H1FEeDBfP-ZBWer7f2gQA_xcLboYV2
export ESTATE=9add2645-b3ef-4c25-b315-63900833ba5a
export SVC='<service_role JWT>'    # legacy service_role JWT (a JWT — sb_secret fails storage "Invalid Compact JWS")
# Owner (ckankeu2@gmail.com, uid 77ef850e-6e12-449b-816e-d51f35332298) aal1 JWT:
OWNER=$(curl -s "$URL/auth/v1/token?grant_type=password" -H "apikey: $PUB" -H 'Content-Type: application/json' \
  -d '{"email":"ckankeu2@gmail.com","password":"<owner pw>"}' | jq -r .access_token)
# Non-owner (beneficiary tekay) aal1 JWT:
NONOWNER=$(curl -s "$URL/auth/v1/token?grant_type=password" -H "apikey: $PUB" -H 'Content-Type: application/json' \
  -d '{"email":"tekay58247@ocuser.com","password":"Hilton23Users!"}' | jq -r .access_token)
rpc() { curl -s "$URL/rest/v1/rpc/$1" -H "apikey: $PUB" -H "Authorization: Bearer ${2}" -H 'Content-Type: application/json' -d "$3"; echo; }
```
Apply `0035`; deploy the api branch (for the read-path `doc_subtype` change) with `vercel --prod`.

## CREATE — Leg 1: happy path (subtype persisted + doc_type DERIVED + size/mime SERVER-READ)
```bash
DOC=$(uuidgen | tr 'A-F' 'a-f'); PATH1="estates/$ESTATE/vault/$DOC.pdf"
# owner uploads their own object (storage RLS 0030 allows owner anywhere under estates/<estate>/):
curl -s -X POST "$URL/storage/v1/object/documents/$PATH1" -H "apikey: $PUB" -H "Authorization: Bearer $OWNER" \
  -H "Content-Type: application/pdf" --data-binary @/tmp/small.pdf; echo
rpc create_vault_document "$OWNER" "{\"p_estate\":\"$ESTATE\",\"p_doc_id\":\"$DOC\",\"p_storage_path\":\"$PATH1\",\"p_title\":\"  My Life Policy  \",\"p_doc_subtype\":\"lifeInsurancePolicy\",\"p_sensitivity\":\"high\"}"
# -> returns "$DOC". Verify the row (SQL editor):
#   select doc_type, doc_subtype, title, mime_type, size_bytes, is_encrypted, sensitivity, owner_id
#   from documents where id = '$DOC';
# EXPECT: doc_type='insurance_policy' (DERIVED from the subtype), doc_subtype='lifeInsurancePolicy',
#         title='My Life Policy' (trimmed), mime_type='application/pdf' + size_bytes = the object's (SERVER-read),
#         is_encrypted=false, sensitivity='high', owner_id='77ef850e-...'.
# Audit: select action, metadata from audit_logs where target_id='$DOC' order by created_at desc limit 1;
#         -> 'document.created', metadata.doc_type='insurance_policy', doc_subtype='lifeInsurancePolicy'.
```

## CREATE — Leg 2: path mismatch -> `vault_path_mismatch`
```bash
D2=$(uuidgen|tr 'A-F' 'a-f')
# wrong subfolder (claim-evidence, not vault) — object need not exist; the path check fires first:
rpc create_vault_document "$OWNER" "{\"p_estate\":\"$ESTATE\",\"p_doc_id\":\"$D2\",\"p_storage_path\":\"estates/$ESTATE/claim-evidence/$D2.pdf\",\"p_title\":\"x\",\"p_doc_subtype\":\"will\"}"
# EXPECT: {"code":"P0001","message":"vault_path_mismatch"}   (also try a path whose estate != $ESTATE)
```

## CREATE — Leg 3: non-owner -> `not_estate_owner`
```bash
D3=$(uuidgen|tr 'A-F' 'a-f')
rpc create_vault_document "$NONOWNER" "{\"p_estate\":\"$ESTATE\",\"p_doc_id\":\"$D3\",\"p_storage_path\":\"estates/$ESTATE/vault/$D3.pdf\",\"p_title\":\"x\",\"p_doc_subtype\":\"will\"}"
# EXPECT: {"code":"42501","message":"not_estate_owner"}
```

## CREATE — Leg 4: object missing -> `vault_object_missing`
```bash
D4=$(uuidgen|tr 'A-F' 'a-f')   # NO upload — path is well-formed but the object doesn't exist
rpc create_vault_document "$OWNER" "{\"p_estate\":\"$ESTATE\",\"p_doc_id\":\"$D4\",\"p_storage_path\":\"estates/$ESTATE/vault/$D4.pdf\",\"p_title\":\"x\",\"p_doc_subtype\":\"will\"}"
# EXPECT: {"code":"P0002","message":"vault_object_missing"}
```

## CREATE — Leg 5: over-limit -> `vault_too_large`  (and MIME reject, bonus)
The bucket `file_size_limit` (25MB) REJECTS a >25MB object at UPLOAD, so it can never exist to exercise the RPC's
cap directly. Instead, temporarily LOWER `upload_policy` to prove the RPC enforces the policy number (this also
proves `size_bytes` is SERVER-read: a 4096-byte object trips a 1024-byte cap):
```bash
# SQL editor: update public.upload_policy set max_upload_bytes = 1024 where id = 1;
D5=$(uuidgen|tr 'A-F' 'a-f'); P5="estates/$ESTATE/vault/$D5.pdf"
curl -s -X POST "$URL/storage/v1/object/documents/$P5" -H "apikey: $PUB" -H "Authorization: Bearer $OWNER" -H "Content-Type: application/pdf" --data-binary @/tmp/small.pdf; echo
rpc create_vault_document "$OWNER" "{\"p_estate\":\"$ESTATE\",\"p_doc_id\":\"$D5\",\"p_storage_path\":\"$P5\",\"p_title\":\"x\",\"p_doc_subtype\":\"will\"}"
# EXPECT: {"code":"P0001","message":"vault_too_large"}
# SQL editor RESTORE: update public.upload_policy set max_upload_bytes = 26214400 where id = 1;   -- 25 MB
# MIME reject (bonus): upload a .txt object with Content-Type text/plain (if the bucket allows) -> vault_mime_rejected.
```

## CREATE — Leg 6/7: unknown + inactive subtype rejected
```bash
D6=$(uuidgen|tr 'A-F' 'a-f')
rpc create_vault_document "$OWNER" "{\"p_estate\":\"$ESTATE\",\"p_doc_id\":\"$D6\",\"p_storage_path\":\"estates/$ESTATE/vault/$D6.pdf\",\"p_title\":\"x\",\"p_doc_subtype\":\"notARealSubtype\"}"
# EXPECT: {"code":"P0001","message":"unknown_subtype"}  (subtype check fires before object-exists)
# inactive: DEACTIVATE FIRST in the SQL editor (else 'will' is active and the call falls through to the
# object-exists check). No object upload is needed — the subtype check fires BEFORE object-exists.
#   SQL editor: update public.document_subtype set is_active=false where subtype='will';
D7=$(uuidgen|tr 'A-F' 'a-f')
rpc create_vault_document "$OWNER" "{\"p_estate\":\"$ESTATE\",\"p_doc_id\":\"$D7\",\"p_storage_path\":\"estates/$ESTATE/vault/$D7.pdf\",\"p_title\":\"x\",\"p_doc_subtype\":\"will\"}"
# EXPECT: {"code":"P0001","message":"inactive_subtype"}
#   SQL editor RESTORE: update public.document_subtype set is_active=true where subtype='will';
```

## CREATE — Leg 8: claim coarse-only REGRESSION (submit_claim_with_evidence unaffected; doc_subtype NULL)
```bash
# Run the existing claim submit (or inspect existing claim rows). Verify claim evidence rows are coarse-only:
#   select id, doc_type, doc_subtype from documents where doc_type in ('death_certificate','id_document')
#     and estate_id='$ESTATE' order by created_at desc limit 4;
# EXPECT: doc_subtype IS NULL for every claim-evidence row (the coarse door is untouched by 0035).
```

## UPDATE — Leg 9: owner edits title+subtype -> doc_type RE-DERIVED + audit changed fields
```bash
# use $DOC from Leg 1 (currently insurance_policy / lifeInsurancePolicy):
rpc update_vault_document "$OWNER" "{\"p_doc_id\":\"$DOC\",\"p_title\":\"Deed of the House\",\"p_doc_subtype\":\"propertyDeed\"}"
# Verify (SQL): select title, doc_subtype, doc_type from documents where id='$DOC';
# EXPECT: title='Deed of the House', doc_subtype='propertyDeed', doc_type='deed' (RE-DERIVED).
# Audit: select metadata->'changed' from audit_logs where target_id='$DOC' and action='document.updated' order by created_at desc limit 1;
# EXPECT: ["title","doc_subtype","doc_type"]   (names only, no values).
```

## UPDATE — Leg 10: non-owner -> denied
```bash
rpc update_vault_document "$NONOWNER" "{\"p_doc_id\":\"$DOC\",\"p_title\":\"hijack\"}"
# EXPECT: {"code":"42501","message":"not_estate_owner"}   (gate on the ROW's estate_id)
```

## UPDATE — Leg 11: immutable field attempt -> REJECTED (unrepresentable)
```bash
# estate_id/owner_id/storage_path/mime_type/size_bytes/is_encrypted/created_at are NOT parameters:
rpc update_vault_document "$OWNER" "{\"p_doc_id\":\"$DOC\",\"p_estate\":\"$ESTATE\",\"p_storage_path\":\"estates/$ESTATE/vault/evil.pdf\"}"
# EXPECT: PostgREST 404 "Could not find the function public.update_vault_document(p_doc_id, p_estate, p_storage_path)
#         in the schema cache" — the immutable fields have no param, so the call itself is rejected.
# no_fields_to_update: rpc update_vault_document "$OWNER" "{\"p_doc_id\":\"$DOC\"}"  -> {"code":"P0001","message":"no_fields_to_update"}
```

## RELAUNCH PERSISTENCE (on device — iOS, both create + edit)
After wiring iOS (behind `useLiveVaultService`): create a doc (real file + title + subtype), force-quit, relaunch →
the doc is present in the Vault list with its title + subtype (served by `/api/vault/documents`, now carrying
`documentSubtype`). Edit its title + subtype, force-quit, relaunch → the edit persists. This is the proof the
surface is no longer fake-durable.

## 0036 — Taxonomy config proof (after applying 0036)

```bash
# T1: get_document_taxonomy returns all three vocabularies + both versions; authenticated allowed, anon denied.
rpc get_document_taxonomy "$OWNER" '{}' | jq '{schema_version, vocabulary_version, doc_types: (.doc_types|length), subtypes: (.subtypes|length), sensitivities: (.sensitivities|length), sample_subtype: .subtypes[0]}'
# EXPECT: schema_version 1, vocabulary_version 1, doc_types 11, subtypes 132, sensitivities 5,
#         sample has value/display_name/description/parent_doc_type/rank/sort_order/badge_color_key/icon_key.
curl -s -o /dev/null -w '%{http_code}\n' "$URL/rest/v1/rpc/get_document_taxonomy" -H "apikey: $PUB" -H 'Content-Type: application/json' -d '{}'   # anon -> 401
```
```sql
-- T2: seeding a NEW subtype bumps vocabulary_version AND appears in the payload with NO function change.
select vocabulary_version from public.taxonomy_version where id=1;   -- note N
insert into public.document_subtype (subtype, parent_doc_type, display_name, sort_order, rank, badge_color_key, icon_key)
  values ('testProofSubtype','other','Test Proof Subtype',999,99,'neutral','doc.fill');
select vocabulary_version from public.taxonomy_version where id=1;   -- EXPECT N+1 (trigger fired)
```
```bash
rpc get_document_taxonomy "$OWNER" '{}' | jq '.vocabulary_version, (.subtypes[] | select(.value=="testProofSubtype"))'
# EXPECT: N+1, and the testProofSubtype object present — WITHOUT redeploying/altering any function.
```
```sql
-- T3: deactivating a value removes it from the payload, but existing rows carrying it stay valid.
update public.document_subtype set is_active=false where subtype='testProofSubtype';   -- bumps version again
-- (payload no longer lists it — verify via get_document_taxonomy); a documents row already carrying a now-inactive
-- subtype is untouched (is_active gates NEW writes only, the FK keeps the value present). Cleanup: delete it:
delete from public.document_subtype where subtype='testProofSubtype';

-- T4 REGRESSION: submit_claim_with_evidence still writes coarse death_certificate + sealed (0031 untouched).
--   Re-run a claim submit (executor path) OR confirm the existing claim rows still validate under the new FKs:
select doc_type, doc_subtype, sensitivity from public.documents
  where doc_type in ('death_certificate','id_document') order by created_at desc limit 4;
-- EXPECT: rows present, doc_subtype NULL, sensitivity 'sealed' — all FK-valid (death_certificate/id_document +
-- sealed are seeded in document_type/document_sensitivity).

-- T6: every existing documents row satisfies the new FKs (no orphan doc_type/sensitivity):
select count(*) as bad_doc_type   from public.documents d left join public.document_type t on t.value=d.doc_type where t.value is null;
select count(*) as bad_sensitivity from public.documents d left join public.document_sensitivity s on s.value=d.sensitivity where s.value is null;
-- EXPECT: both 0.
```
```bash
# T5: create/update still reject unknown + inactive subtypes (unchanged behavior, now table-sourced).
D=$(uuidgen|tr 'A-F' 'a-f')
rpc create_vault_document "$OWNER" "{\"p_estate\":\"$ESTATE\",\"p_doc_id\":\"$D\",\"p_storage_path\":\"estates/$ESTATE/vault/$D.pdf\",\"p_title\":\"x\",\"p_doc_subtype\":\"noSuchSubtype\"}"   # unknown_subtype
# invalid sensitivity now table-checked: rpc create_vault_document ... p_sensitivity 'nope' -> invalid_sensitivity
```

## 0037 — Core taxonomy stabilization proof (P1–P12)

**P1 — PRE-FLIGHT affected-row count (run BEFORE applying 0037; report the exact number).**
The backfill runs AFTER the re-points, so it compares each row's `doc_type` to the subtype's NEW parent. A
row is backfilled iff its `doc_subtype` is one 0037 RE-POINTS (its coarse changes). Match against the exact
re-pointed set (below) — NOT against the current parent (which is trivially consistent pre-migration and would
falsely report 0). Claim rows (`doc_subtype` NULL) are excluded.
```sql
with repointed(subtype) as (values
  ('bankStatement'),('brokerageStatement'),('retirementAccountStatement'),('document401k'),('iraDocument'),
  ('plan529Document'),('pensionDocument'),('loanDocument'),('mortgageStatement'),('creditCardStatement'),
  ('debtRecord'),('accountClosureInstruction'),
  ('businessFormationDocument'),('operatingAgreement'),('corporateBylaws'),('stockCertificate'),('capTable'),
  ('businessTaxRecord'),('partnershipAgreement'),('buySellAgreement'),('businessInsuranceDocument'),('businessSuccessionPlan'),
  ('courtOrder'),('settlementAgreement'),('legalAgreement'),('attorneyLetter'),('probateDocument'),
  ('lettersTestamentary'),('notarizedDocument'),('contract'),
  ('advanceHealthcareDirective'),('livingWill'),('healthcareDirective'),
  ('medicalRecord'),('prescriptionList'),('doctorContactList'),('insuranceCard'),('emergencyMedicalInformation'),
  ('carePlan'),('disabilityRecord'),
  ('cryptoWalletInventory'),('hardwareWalletLocationReference'),('exchangeAccountStatement'),('digitalAssetInventory'),
  ('nftOwnershipRecord'),('cryptoTaxReport'),('recoveryLocationReference'),
  ('mortgageDocument'),('leaseAgreement'),('propertyAppraisal'),('homeInventory'),('vehicleTitle'),('boatTitle'),
  ('landOwnershipRecord'),('propertyInsuranceDocument'),('propertyDeed'))
select d.doc_type as current_coarse, d.doc_subtype, count(*)
from public.documents d join repointed r on r.subtype = d.doc_subtype
group by 1,2 order by 3 desc;
-- bare count (the authoritative will-backfill number):
with repointed(subtype) as (values
  ('bankStatement'),('brokerageStatement'),('retirementAccountStatement'),('document401k'),('iraDocument'),
  ('plan529Document'),('pensionDocument'),('loanDocument'),('mortgageStatement'),('creditCardStatement'),
  ('debtRecord'),('accountClosureInstruction'),('businessFormationDocument'),('operatingAgreement'),
  ('corporateBylaws'),('stockCertificate'),('capTable'),('businessTaxRecord'),('partnershipAgreement'),
  ('buySellAgreement'),('businessInsuranceDocument'),('businessSuccessionPlan'),('courtOrder'),
  ('settlementAgreement'),('legalAgreement'),('attorneyLetter'),('probateDocument'),('lettersTestamentary'),
  ('notarizedDocument'),('contract'),('advanceHealthcareDirective'),('livingWill'),('healthcareDirective'),
  ('medicalRecord'),('prescriptionList'),('doctorContactList'),('insuranceCard'),('emergencyMedicalInformation'),
  ('carePlan'),('disabilityRecord'),('cryptoWalletInventory'),('hardwareWalletLocationReference'),
  ('exchangeAccountStatement'),('digitalAssetInventory'),('nftOwnershipRecord'),('cryptoTaxReport'),
  ('recoveryLocationReference'),('mortgageDocument'),('leaseAgreement'),('propertyAppraisal'),('homeInventory'),
  ('vehicleTitle'),('boatTitle'),('landOwnershipRecord'),('propertyInsuranceDocument'),('propertyDeed'))
select count(*) as will_backfill from public.documents d join repointed r on r.subtype = d.doc_subtype;
```
Expected: the `propertyDeed` row(s) your update-legs set to `doc_type='deed'` (→ `real_estate`); ≈1–2. The other
55 re-pointed subtypes have no rows in the test data, so they contribute 0.

**Apply `0037`, then:**
```sql
-- P2: new coarse rows exist with correct metadata; medical_directive relabelled; deed retired.
select value, display_name, is_active, badge_color_key, icon_key from public.document_type
  where value in ('financial_account','business','legal_and_court','healthcare_record','crypto_digital_asset','real_estate','medical_directive','deed')
  order by sort_order;
-- EXPECT: the 6 new = active with the metadata; medical_directive display 'Medical Directives'; deed is_active=false.

-- P3: every moved subtype has the intended parent (spot the 7 groups; count per new parent).
select parent_doc_type, count(*) from public.document_subtype
  where parent_doc_type in ('financial_account','business','legal_and_court','healthcare_record','crypto_digital_asset','real_estate','medical_directive')
  group by 1 order by 1;
-- EXPECT: financial_account 12, business 10, legal_and_court 8, healthcare_record 7, crypto_digital_asset 7,
--         real_estate 9 (incl propertyDeed), medical_directive 3.

-- P6: post-backfill mismatch count is ZERO.
select count(*) as mismatches from public.documents d join public.document_subtype ds on ds.subtype=d.doc_subtype
  where d.doc_type <> ds.parent_doc_type;   -- 0

-- P7: no duplicate ACTIVE identifiers (coarse + subtype are PKs, so this is belt-and-suspenders).
select value, count(*) from public.document_type where is_active group by value having count(*) > 1;   -- 0 rows
select subtype, count(*) from public.document_subtype where is_active group by subtype having count(*) > 1; -- 0 rows

-- P8: no invalid parent references — NO active subtype points to an inactive/nonexistent parent.
select count(*) as active_subtype_inactive_parent from public.document_subtype ds
  left join public.document_type dt on dt.value = ds.parent_doc_type
  where ds.is_active and (dt.value is null or not dt.is_active);   -- 0

-- P9: vocabulary_version advanced (note the pre-0037 value first). schema_version UNCHANGED.
select schema_version, vocabulary_version from public.taxonomy_version where id=1;   -- schema_version still 1; vocab higher

-- P12: rows NOT targeted are unchanged — a will/insurance row keeps its coarse type.
select doc_type, doc_subtype from public.documents where doc_subtype in ('will','lifeInsurancePolicy') limit 4;
-- EXPECT: will->will, lifeInsurancePolicy->insurance_policy (untouched — those subtypes weren't re-pointed).
```
```bash
# P4: a representative subtype from EACH new category derives the correct coarse type on create.
for pair in "bankStatement:financial_account" "stockCertificate:business" "courtOrder:legal_and_court" \
            "medicalRecord:healthcare_record" "nftOwnershipRecord:crypto_digital_asset" "vehicleTitle:real_estate" \
            "livingWill:medical_directive"; do
  sub="${pair%%:*}"; exp="${pair##*:}"; D=$(uuidgen|tr 'A-F' 'a-f'); P="estates/$ESTATE/vault/$D.pdf"
  curl -s -X POST "$URL/storage/v1/object/documents/$P" -H "apikey: $PUB" -H "Authorization: Bearer $OWNER" -H "Content-Type: application/pdf" --data-binary @/tmp/small.pdf >/dev/null
  got=$(rpc create_vault_document "$OWNER" "{\"p_estate\":\"$ESTATE\",\"p_doc_id\":\"$D\",\"p_storage_path\":\"$P\",\"p_title\":\"$sub\",\"p_doc_subtype\":\"$sub\"}")
  echo "$sub -> created $got  (verify doc_type='$exp' in SQL)"
done
# Then: select doc_subtype, doc_type from documents where doc_subtype in
#   ('bankStatement','stockCertificate','courtOrder','medicalRecord','nftOwnershipRecord','vehicleTitle','livingWill');
# EXPECT each derives its new parent (financial_account/business/legal_and_court/healthcare_record/
#         crypto_digital_asset/real_estate/medical_directive). ALSO: creating with p_doc_subtype='propertyDeed'
#         now derives 'real_estate' (not 'deed').

# P5 ★ CLAIM REGRESSION — coarse values intact; submit_claim_with_evidence still works.
#   (values still present + claim rows still valid; the 0031 RPC is byte-for-byte unchanged.)
#   SQL: select value,is_active from document_type where value in ('death_certificate','id_document'); -> both present+active
#        select doc_type,doc_subtype from documents where doc_type in ('death_certificate','id_document') limit 4; -> coarse, NULL subtype

# P10: get_document_taxonomy payload — 16 ACTIVE doc_types (deed excluded), new ones present, deed absent.
rpc get_document_taxonomy "$OWNER" '{}' | jq '{doc_types_active: (.doc_types|length), has_deed: ([.doc_types[].value] | index("deed") != null), new_present: ([.doc_types[].value] | map(select(. == "financial_account" or . == "real_estate"))), realestate_subtypes: ([.subtypes[] | select(.parent_doc_type=="real_estate") | .value] | length)}'
# EXPECT: doc_types_active 16, has_deed false, new_present ["financial_account","real_estate"], realestate_subtypes 9.

# P11: unauthorized users cannot mutate the taxonomy tables (no client grants).
curl -s -o /dev/null -w '%{http_code}\n' -X POST "$URL/rest/v1/document_type" -H "apikey: $PUB" -H "Authorization: Bearer $OWNER" -H "Content-Type: application/json" -d '{"value":"hack","display_name":"Hack"}'
# EXPECT: 401/403/404 (permission denied / not exposed) — NOT 201. Taxonomy is DEFINER-RPC-read-only.
```

## 0038 — IA refinement proof (P1–P12 + P13–P16)

**P1 — PRE-FLIGHT (run BEFORE applying 0038; rows carrying a subtype 0038 RE-POINTS will backfill).**
```sql
with repointed(subtype) as (values
  ('personalLetter'),('lifeStoryDocument'),('familyHistory'),('photosMemorabiliaReference'),('legacyMessage'),
  ('personalValuesStatement'),('award'),('certificateOfAchievement'),('professionalRecognition'),('publishedWork'),
  ('patentDocument'),('businessMilestone'),('charityCommunityServiceRecord'),('beneficiaryID'),('familyContactList'),
  ('dependentInformation'),('emergencyContactList'),('caregiverInstructions'),('minorChildInstructions'),
  ('petCareInstructions'),('diploma'),('certificate'),('professionalLicense'),('resume'),('employmentContract'),
  ('awardLetter'),('referenceLetter'),('trainingCertificate'),('militaryID'),('dd214'),('veteransBenefitsDocument'),
  ('governmentBenefitsLetter'),('socialSecurityBenefitsDocument'),('pensionBenefitsDocument'),('letterOfInstruction'),
  ('funeralBurialInstructions'),('executorInstructions'),('guardianshipInstructions'))
select d.doc_type as current_coarse, d.doc_subtype, count(*)
from public.documents d join repointed r on r.subtype = d.doc_subtype group by 1,2 order by 3 desc;
-- Expected: 0 rows (no test row carries a 0038 subtype). If any appear, report the count before applying.
```

**Apply `0038`, then:**
```sql
-- P2: the 6 new coarse rows exist, active, correct metadata.
select value, display_name, is_active, badge_color_key, icon_key from public.document_type
  where value in ('legacy_and_family','achievements_and_recognition','family_and_beneficiary','education_and_career','military_and_government','estate_planning')
  order by sort_order;   -- all 6 active with the metadata

-- P3: every approved subtype has the expected parent (counts per new parent).
select parent_doc_type, count(*) from public.document_subtype
  where parent_doc_type in ('legacy_and_family','achievements_and_recognition','family_and_beneficiary','education_and_career','military_and_government','estate_planning')
  group by 1 order by 1;
-- EXPECT: legacy_and_family 6, achievements_and_recognition 7, family_and_beneficiary 7, education_and_career 8,
--         military_and_government 6, estate_planning 4.

-- P6 post-backfill mismatch = 0 · P7 no dup active ids · P8 no active-subtype->inactive-parent.
select count(*) as mismatches from public.documents d join public.document_subtype ds on ds.subtype=d.doc_subtype where d.doc_type <> ds.parent_doc_type;   -- 0
select value, count(*) from public.document_type where is_active group by value having count(*)>1;      -- 0 rows
select subtype, count(*) from public.document_subtype where is_active group by subtype having count(*)>1; -- 0 rows
select count(*) as active_subtype_inactive_parent from public.document_subtype ds
  left join public.document_type dt on dt.value=ds.parent_doc_type where ds.is_active and (dt.value is null or not dt.is_active);  -- 0

-- P9 versioning: vocab advanced; schema_version STILL 1.
select schema_version, vocabulary_version from public.taxonomy_version where id=1;

-- P13: personal_legacy is ABSENT (never created).
select count(*) as personal_legacy_rows from public.document_type where value='personal_legacy';   -- 0

-- P14: legacy vs achievement records SEPARATED (distinct parents; no overlap).
select parent_doc_type, string_agg(subtype, ', ' order by subtype) from public.document_subtype
  where parent_doc_type in ('legacy_and_family','achievements_and_recognition') group by 1;
-- EXPECT: legacy_and_family = personal/family keepsakes; achievements_and_recognition = award/patent/…/businessMilestone/charityCommunityServiceRecord — no value in both.

-- P15: exact memberships match the approved recon.
select parent_doc_type, string_agg(subtype, ', ' order by subtype) from public.document_subtype
  where parent_doc_type in ('family_and_beneficiary','education_and_career','military_and_government','estate_planning')
  group by 1 order by 1;
-- EXPECT (exact):
--  family_and_beneficiary: beneficiaryID, caregiverInstructions, dependentInformation, emergencyContactList, familyContactList, minorChildInstructions, petCareInstructions
--  education_and_career:    awardLetter, certificate, diploma, employmentContract, professionalLicense, referenceLetter, resume, trainingCertificate
--  military_and_government: dd214, governmentBenefitsLetter, militaryID, pensionBenefitsDocument, socialSecurityBenefitsDocument, veteransBenefitsDocument
--  estate_planning:         executorInstructions, funeralBurialInstructions, guardianshipInstructions, letterOfInstruction

-- P16: `other` contains ONLY the two approved catch-alls.
select subtype from public.document_subtype where parent_doc_type='other' order by subtype;   -- EXACTLY: customDocument, miscellaneousRecord
select count(*) as other_count from public.document_subtype where parent_doc_type='other';     -- 2
```
```bash
# P4: deterministic create derivation for each new category.
for pair in "legacyMessage:legacy_and_family" "patentDocument:achievements_and_recognition" "beneficiaryID:family_and_beneficiary" \
            "diploma:education_and_career" "dd214:military_and_government" "executorInstructions:estate_planning"; do
  sub="${pair%%:*}"; exp="${pair##*:}"; D=$(uuidgen|tr 'A-F' 'a-f'); P="estates/$ESTATE/vault/$D.pdf"
  curl -s -X POST "$URL/storage/v1/object/documents/$P" -H "apikey: $PUB" -H "Authorization: Bearer $OWNER" -H "Content-Type: application/pdf" --data-binary @/tmp/small.pdf >/dev/null
  echo "$sub -> $(rpc create_vault_document "$OWNER" "{\"p_estate\":\"$ESTATE\",\"p_doc_id\":\"$D\",\"p_storage_path\":\"$P\",\"p_title\":\"$sub\",\"p_doc_subtype\":\"$sub\"}")  (want $exp)"
done
# Then: select doc_subtype, doc_type from documents where doc_subtype in
#   ('legacyMessage','patentDocument','beneficiaryID','diploma','dd214','executorInstructions'); -> each = its new parent.
# P5 also via update: rpc update_vault_document "$OWNER" '{"p_doc_id":"<a doc>","p_doc_subtype":"militaryID"}' -> doc_type military_and_government.

# P5 ★ CLAIM REGRESSION — unchanged (0031 untouched):
#   select value,is_active from document_type where value in ('death_certificate','id_document'); -> both present+active
#   select doc_type,doc_subtype from documents where doc_type in ('death_certificate','id_document') limit 4; -> coarse, NULL

# P10: payload = 22 ACTIVE doc_types (deed still excluded), new ones present.
rpc get_document_taxonomy "$OWNER" '{}' | jq '{doc_types_active:(.doc_types|length), has_personal_legacy:([.doc_types[].value]|index("personal_legacy")!=null), new6:([.doc_types[].value]|map(select(.=="legacy_and_family" or .=="estate_planning"))), other_subtypes:([.subtypes[]|select(.parent_doc_type=="other")|.value])}'
# EXPECT: doc_types_active 22, has_personal_legacy false, new6 present, other_subtypes ["customDocument","miscellaneousRecord"].

# P11: unauthorized taxonomy mutation denied.
curl -s -o /dev/null -w '%{http_code}\n' -X POST "$URL/rest/v1/document_type" -H "apikey: $PUB" -H "Authorization: Bearer $OWNER" -H "Content-Type: application/json" -d '{"value":"hack2","display_name":"Hack"}'   # 401/403
```
**P12** — untargeted rows unchanged: any pre-existing 0037-category row (e.g. `bankStatement→financial_account`) keeps its coarse type (0038 doesn't touch it).

## Cleanup
```sql
delete from public.documents where estate_id = '9add2645-b3ef-4c25-b315-63900833ba5a'
  and storage_path like 'estates/%/vault/%';   -- test rows only (leave claim-evidence rows)
-- storage objects at estates/<estate>/vault/<id>.<ext> are reclaimed by the orphan sweeper (or delete via SVC).
```
