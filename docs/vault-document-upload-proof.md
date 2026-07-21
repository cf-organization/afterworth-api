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

## Cleanup
```sql
delete from public.documents where estate_id = '9add2645-b3ef-4c25-b315-63900833ba5a'
  and storage_path like 'estates/%/vault/%';   -- test rows only (leave claim-evidence rows)
-- storage objects at estates/<estate>/vault/<id>.<ext> are reclaimed by the orphan sweeper (or delete via SVC).
```
