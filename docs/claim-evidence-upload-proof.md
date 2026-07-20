# Slice C1.6a (backend) — evidence upload: proof

The storage-RLS rewrite (0030) + the atomic four-way-agreement submit RPC (0031). Built so the executor can
upload evidence DIRECT-TO-STORAGE (RLS is the gate; no api endpoint → api stays 12/12), then submit atomically.
iOS is a separate slice (C1.6a-iOS: no file-bytes/picker exists yet — see PROGRESS).

Prereq (done): dashboard bucket `documents` file_size_limit=25MB + MIME allowlist (pdf/jpeg/png/heic);
orphaned C1.6b objects deleted; migrations `0030` + `0031` applied.

## Environment

```bash
export URL=https://yiaavvkulrpqkkbqhwit.supabase.co
export PUB=sb_publishable_3H1FEeDBfP-ZBWer7f2gQA_xcLboYV2
export ESTATE=9add2645-b3ef-4c25-b315-63900833ba5a
tok(){ curl -s "$URL/auth/v1/token?grant_type=password" -H "apikey: $PUB" \
  -H 'Content-Type: application/json' -d "{\"email\":\"$1\",\"password\":\"$2\"}" | jq -r .access_token; }
EXEC=$(tok tekay58247@ocuser.com 'Hilton23Users!')   # tekay — the acting EXECUTOR (real JWT, aal1 is fine)
```

Accounts (test estate): owner `77ef850e` · executor **tekay `cb5edecc`** · professional-member `fb97e207` ·
stranger/admin `16db5021`. Only tekay has a known password → tekay drives the **real-door** legs; owner /
member / stranger cells are proven by **crafted-claims predicate evaluation** in the SQL editor (deterministic,
no passwords). Storage HTTP legs REQUIRE a real signed JWT — crafted claims do NOT reach the storage API.

## Executor designation seed (SQL editor)

```sql
insert into public.estate_designations (estate_id, user_id, designation_type, status, granted_by)
select '9add2645-b3ef-4c25-b315-63900833ba5a', 'cb5edecc-b7b7-468a-ad4f-c378b43095c9', 'executor', 'active',
       '77ef850e-6e12-449b-816e-d51f35332298'
where not exists (
  select 1 from public.estate_designations
  where estate_id='9add2645-b3ef-4c25-b315-63900833ba5a' and user_id='cb5edecc-b7b7-468a-ad4f-c378b43095c9'
    and designation_type='executor' and status='active'
);
select public.is_estate_executor('9add2645-b3ef-4c25-b315-63900833ba5a','cb5edecc-b7b7-468a-ad4f-c378b43095c9') as exec;
-- expect: exec = true
```

---

## LEG 0 — storage RLS matrix, crafted-claims predicate eval (SQL editor; fastest signal, all 8 cells)

Evaluates the EXACT policy predicate per-principal (`is_estate_owner` inlined as `estates.owner_id = uid`;
`is_estate_executor` with the explicit uid arg). RESULT-SET queries — the verdict shows in the grid (a `do`
block with `raise notice` returns no grid rows; its output is in the Messages/Notices panel — the crafted-
claims gotcha). No passwords, no uploads.

```sql
-- READ: owner ✓ / executor ✓ / professional-member ✗ / stranger ✗  (a claim-evidence object)
with t(label, uid) as (values
  ('owner 77ef',       '77ef850e-6e12-449b-816e-d51f35332298'::uuid),
  ('executor cb5e',    'cb5edecc-b7b7-468a-ad4f-c378b43095c9'::uuid),
  ('prof-member fb97', 'fb97e207-39d4-4411-8987-fbd7a0d2fb2e'::uuid),
  ('stranger 16db',    '16db5021-4870-4d66-9d71-0b73d72363d0'::uuid)
), obj(name) as (values ('estates/9add2645-b3ef-4c25-b315-63900833ba5a/claim-evidence/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.pdf'))
select t.label,
  ( exists (select 1 from public.estates e where e.id = ((storage.foldername(o.name))[2])::uuid and e.owner_id = t.uid)
    or (public.is_estate_executor(((storage.foldername(o.name))[2])::uuid, t.uid)
        and (storage.foldername(o.name))[3] = 'claim-evidence') ) as read_allowed
from t cross join obj o;
-- expect: owner true / executor true / prof-member false / stranger false

-- WRITE (executor cb5e): own claim-evidence ✓ / outside ✗ / another estate ✗
with t(label, name) as (values
  ('own claim-evidence',    'estates/9add2645-b3ef-4c25-b315-63900833ba5a/claim-evidence/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.pdf'),
  ('outside claim-evidence','estates/9add2645-b3ef-4c25-b315-63900833ba5a/other/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.pdf'),
  ('another estate',        'estates/11111111-1111-1111-1111-111111111111/claim-evidence/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.pdf')
)
select t.label,
  ( exists (select 1 from public.estates e where e.id = ((storage.foldername(t.name))[2])::uuid and e.owner_id = 'cb5edecc-b7b7-468a-ad4f-c378b43095c9')
    or (public.is_estate_executor(((storage.foldername(t.name))[2])::uuid, 'cb5edecc-b7b7-468a-ad4f-c378b43095c9')
        and (storage.foldername(t.name))[3] = 'claim-evidence') ) as write_allowed
from t;
-- expect: own true / outside false / another false
```

## LEG 1 — storage RLS, REAL door (executor JWT + anon)

Confirms the actual storage API enforces the policy for the executor (the security-critical new write path).
Real signed JWT required. **Re-mint `$EXEC` immediately before running** — password-grant tokens last ~1h and
`"exp" claim timestamp check failed` means it aged out. **Deny codes:** a storage RLS denial returns
**HTTP 400 with a body `{"statusCode":"403",…,"row-level security"…}`** — judge the ✗ legs by the *body*
(`403 / row-level security`), not the HTTP code; the ✓ legs return `{"Key":…}` / `200`. `DC` / `EX` are two
client-generated doc_ids (keep them for LEG 3).

```bash
EXEC=$(tok tekay58247@ocuser.com 'Hilton23Users!'); echo "${EXEC:0:8}…"   # fresh; must be eyJ…, not null
DC=$(uuidgen | tr 'A-F' 'a-f'); EX=$(uuidgen | tr 'A-F' 'a-f')
BASE="$URL/storage/v1/object/documents/estates/$ESTATE/claim-evidence"
PDF=$(ls ~/Downloads/*.pdf ~/Documents/*.pdf 2>/dev/null | head -1)

# executor writes own claim-evidence ✓  (expect {"Key":...})
curl -s -X POST "$BASE/$DC.pdf" -H "apikey: $PUB" -H "Authorization: Bearer $EXEC" \
  -H "Content-Type: application/pdf" --data-binary @"$PDF"; echo
curl -s -X POST "$BASE/$EX.pdf" -H "apikey: $PUB" -H "Authorization: Bearer $EXEC" \
  -H "Content-Type: application/pdf" --data-binary @"$PDF"; echo

# executor writes OUTSIDE claim-evidence ✗  (expect 403 / row-level security)
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  "$URL/storage/v1/object/documents/estates/$ESTATE/other/$DC.pdf" \
  -H "apikey: $PUB" -H "Authorization: Bearer $EXEC" -H "Content-Type: application/pdf" --data-binary @"$PDF"

# executor writes ANOTHER estate ✗  (expect 403)
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  "$URL/storage/v1/object/documents/estates/11111111-1111-1111-1111-111111111111/claim-evidence/$DC.pdf" \
  -H "apikey: $PUB" -H "Authorization: Bearer $EXEC" -H "Content-Type: application/pdf" --data-binary @"$PDF"

# executor reads own ✓  (expect 200)
curl -s -o /dev/null -w '%{http_code}\n' "$BASE/$DC.pdf" -H "apikey: $PUB" -H "Authorization: Bearer $EXEC"

# anon ✗  (no token → expect 400/401)
curl -s -o /dev/null -w '%{http_code}\n' "$BASE/$DC.pdf" -H "apikey: $PUB"
```

## LEG 2 — ★ client INSERT into documents now DENIED (the CQ3 tightening)

`documents_write` dropped + no INSERT grant → a direct PostgREST insert must fail.

```bash
curl -s -w '\n%{http_code}\n' -X POST "$URL/rest/v1/documents" \
  -H "apikey: $PUB" -H "Authorization: Bearer $EXEC" -H "Content-Type: application/json" \
  -d "{\"estate_id\":\"$ESTATE\",\"owner_id\":\"cb5edecc-b7b7-468a-ad4f-c378b43095c9\",\"doc_type\":\"other\",\"title\":\"x\",\"storage_path\":\"estates/$ESTATE/claim-evidence/$DC.pdf\"}"
# expect: 401/403 — "permission denied for table documents" (no client INSERT path; row creation is RPC-only)
```

## LEG 3 — ★ RPC four-way agreement (submit_claim_with_evidence)

⚠️ **ORDER MATTERS** — `active_claim_exists` is checked BEFORE the path/object checks, so run the mismatch/gate
legs on a **claim-free** estate (i.e. BEFORE the happy path, or after deleting its claim). Otherwise every
mismatch leg raises `active_claim_exists` and masks its real sentinel. (This ordering is by design — a
duplicate submit is rejected early — and is itself the `active_claim_exists` proof.)

**Mismatch / gate legs — crafted claims** (SQL editor; each RAISEs its sentinel and rolls back → no residue).
Each is a single DO block: `set_config` the executor identity, then call with the bad argument.

```sql
-- (a)≠(b) path-estate ≠ p_estate  → evidence_path_mismatch
do $$ begin
  perform set_config('request.jwt.claims', json_build_object('sub','cb5edecc-b7b7-468a-ad4f-c378b43095c9','role','authenticated')::text, true);
  perform public.submit_claim_with_evidence(
    '9add2645-b3ef-4c25-b315-63900833ba5a',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'estates/11111111-1111-1111-1111-111111111111/claim-evidence/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.pdf',
    'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'estates/9add2645-b3ef-4c25-b315-63900833ba5a/claim-evidence/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb.pdf');
end $$;   -- ERROR: evidence_path_mismatch

-- path OUTSIDE claim-evidence → evidence_path_mismatch
do $$ begin
  perform set_config('request.jwt.claims', json_build_object('sub','cb5edecc-b7b7-468a-ad4f-c378b43095c9','role','authenticated')::text, true);
  perform public.submit_claim_with_evidence('9add2645-b3ef-4c25-b315-63900833ba5a',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'estates/9add2645-b3ef-4c25-b315-63900833ba5a/other/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.pdf',
    'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'estates/9add2645-b3ef-4c25-b315-63900833ba5a/claim-evidence/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb.pdf');
end $$;   -- ERROR: evidence_path_mismatch

-- (d) non-executor caller → not_estate_executor  (sub = the professional-member, not an executor)
do $$ begin
  perform set_config('request.jwt.claims', json_build_object('sub','fb97e207-39d4-4411-8987-fbd7a0d2fb2e','role','authenticated')::text, true);
  perform public.submit_claim_with_evidence('9add2645-b3ef-4c25-b315-63900833ba5a',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'estates/9add2645-b3ef-4c25-b315-63900833ba5a/claim-evidence/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.pdf',
    'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'estates/9add2645-b3ef-4c25-b315-63900833ba5a/claim-evidence/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb.pdf');
end $$;   -- ERROR: not_estate_executor

-- object missing (well-formed path, nothing uploaded there) → evidence_object_missing
do $$ begin
  perform set_config('request.jwt.claims', json_build_object('sub','cb5edecc-b7b7-468a-ad4f-c378b43095c9','role','authenticated')::text, true);
  perform public.submit_claim_with_evidence('9add2645-b3ef-4c25-b315-63900833ba5a',
    'cccccccc-cccc-cccc-cccc-cccccccccccc', 'estates/9add2645-b3ef-4c25-b315-63900833ba5a/claim-evidence/cccccccc-cccc-cccc-cccc-cccccccccccc.pdf',
    'dddddddd-dddd-dddd-dddd-dddddddddddd', 'estates/9add2645-b3ef-4c25-b315-63900833ba5a/claim-evidence/dddddddd-dddd-dddd-dddd-dddddddddddd.pdf');
end $$;   -- ERROR: evidence_object_missing
```

**Happy path — REAL JWT** (run AFTER the mismatch legs; needs the two LEG-1 objects to exist; estate claim-free):

```bash
curl -s "$URL/rest/v1/rpc/submit_claim_with_evidence" -H "apikey: $PUB" \
  -H "Authorization: Bearer $EXEC" -H "Content-Type: application/json" -d "{
    \"p_estate\":\"$ESTATE\",
    \"p_death_cert_doc_id\":\"$DC\",  \"p_death_cert_path\":\"estates/$ESTATE/claim-evidence/$DC.pdf\",
    \"p_executor_id_doc_id\":\"$EX\", \"p_executor_id_path\":\"estates/$ESTATE/claim-evidence/$EX.pdf\"}"; echo
# expect: a claim uuid. Verify: 2 documents rows (is_encrypted=false, sensitivity='sealed') + 1 claim
# (status submitted, both doc ids) + a claim.submitted audit (metadata.via='submit_claim_with_evidence').
```

**second submit → active_claim_exists** — re-run the happy-path curl (the estate now has the active claim):
`{"...":"active_claim_exists"}` (P0001 → PostgREST 400). Real JWT or crafted.

## Cleanup (after proof)

```sql
-- remove the happy-path claim + its 2 documents rows + audit (test data), and delete the LEG-1 objects via
-- the Storage UI / DELETE. (estate_designations executor row can stay — it's the intended fiduciary state.)
delete from public.claim_packets where estate_id='9add2645-b3ef-4c25-b315-63900833ba5a' and status='submitted';
delete from public.documents where estate_id='9add2645-b3ef-4c25-b315-63900833ba5a' and doc_type in ('death_certificate','id_document') and title in ('Death Certificate','Executor ID');
```

## Which legs need what

| Leg | Mechanism |
|---|---|
| LEG 0 storage matrix (8 cells) | crafted claims (predicate eval) — SQL editor |
| LEG 1 storage real door (executor + anon) | **real signed JWT** (tekay) — storage API |
| LEG 2 client-INSERT-denied | real JWT — PostgREST |
| LEG 3 happy path | **real JWT** + the two real uploaded objects |
| LEG 3 mismatch/gate legs | crafted claims — SQL editor (each RAISEs + rolls back) |
