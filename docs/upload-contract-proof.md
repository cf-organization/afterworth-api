# Upload contract unification — proof

ONE server-driven contract (`public.upload_policy`) read by every consumer; serving switched to **streaming**
so the 25 MB upload limit is actually viewable (the 4.5 MB serving cap was Vercel's *buffered*-response limit,
which streaming does not hit). Migrations: `0032`.

## Environment

```bash
export URL=https://yiaavvkulrpqkkbqhwit.supabase.co
export PUB=sb_publishable_3H1FEeDBfP-ZBWer7f2gQA_xcLboYV2
export API=https://afterworth-api.vercel.app
export ESTATE=9add2645-b3ef-4c25-b315-63900833ba5a
tok(){ curl -s "$URL/auth/v1/token?grant_type=password" -H "apikey: $PUB" \
  -H 'Content-Type: application/json' -d "{\"email\":\"$1\",\"password\":\"$2\"}" | jq -r .access_token; }
```

## Apply (clobber discipline first)

`0032` REPLACES two shipped functions — diff live vs VC BEFORE applying (both were just shipped by me, so
expect NO diff):

```sql
-- live-vs-VC diff: paste each pg_get_functiondef and compare to db/functions/<name>.sql
select pg_get_functiondef('public.submit_claim_with_evidence(uuid,uuid,text,uuid,text)'::regprocedure);
select pg_get_functiondef('public.admin_authorize_claim_evidence(uuid,text)'::regprocedure);
```

Then apply `0032` (creates `upload_policy` + `get_upload_policy`; rewires `submit_claim_with_evidence` +
`admin_authorize_claim_evidence`). The bucket was already set to 25 MB + the MIME allowlist in the C1.6a
prereq — LEG (a) confirms it still matches.

---

## LEG (a) — ★ the three numbers AGREE (bucket == table == served)  [priority 1; SQL]

```sql
-- bucket config vs upload_policy
select
  b.file_size_limit                        as bucket_max_bytes,
  p.max_upload_bytes                       as policy_max_bytes,
  (b.file_size_limit = p.max_upload_bytes) as max_agrees,
  b.allowed_mime_types                     as bucket_mimes,
  p.allowed_mime_types                     as policy_mimes,
  (b.allowed_mime_types @> p.allowed_mime_types
   and p.allowed_mime_types @> b.allowed_mime_types) as mimes_agree
from storage.buckets b, public.upload_policy p
where b.id = 'documents' and p.id = 1;
-- expect: max_agrees = true, mimes_agree = true  (the DUALITY guardrail — a limit change needs BOTH edits)

-- served == stored (get_upload_policy returns the singleton verbatim)
select * from public.get_upload_policy();
-- expect: 26214400 / 2 / 52428800 / {application/pdf,image/jpeg,image/png,image/heic}
```

## LEG (d) — told == allowed (no drift between the client's view and the RPC)  [priority 1; SQL]

`get_upload_policy()` and `submit_claim_with_evidence` read the SAME table, so they cannot drift — this
confirms the values the client is told are exactly what the submit RPC enforces:

```sql
-- what the client is TOLD
select max_upload_bytes, max_files_per_claim, max_aggregate_bytes from public.get_upload_policy();
-- what submit ENFORCES (the source it reads)
select max_upload_bytes, max_files_per_claim, max_aggregate_bytes from public.upload_policy where id = 1;
-- expect: identical rows. (submit_claim_with_evidence reads upload_policy for its per-file/aggregate/count gates.)
```

## LEG (c) — > limit rejected at UPLOAD (earliest point, not accepted-then-unviewable)  [priority 2; curl]

The bucket rejects an oversized object at the door — so no 4–25 MB-gap data can ever be created:

```bash
EXEC=$(tok tekay58247@ocuser.com 'Hilton23Users!')
# make a 26MB file (content invalid is fine — the bucket rejects on SIZE before anything reads it)
dd if=/dev/zero of=/tmp/too_big.pdf bs=1m count=26 2>/dev/null
DC=$(uuidgen|tr 'A-F' 'a-f')
curl -s -w '\n%{http_code}\n' -X POST \
  "$URL/storage/v1/object/documents/estates/$ESTATE/claim-evidence/$DC.pdf" \
  -H "apikey: $PUB" -H "Authorization: Bearer $EXEC" -H "Content-Type: application/pdf" --data-binary @/tmp/too_big.pdf
# expect: 413 — the object is NEVER created (rejected at upload, the earliest point)
```

## LEG (b) — ★ a large object serves END-TO-END through both streaming hops  [priority 1; needs the deploy]

The leg that PROVES streaming lifted the cap — with a REAL object, not the Vercel docs. Requires the branch
deployed (`vercel --prod` from the api branch) + the console running the BFF change (`npm run build && start`,
`AFTERWORTH_API_URL` set). Use a **valid PDF well over the old 4.5 MB cap** (~10–24 MB — a high-res multipage
scan; must render, so a real PDF, not `/dev/zero`).

```bash
EXEC=$(tok tekay58247@ocuser.com 'Hilton23Users!')   # tekay is an active executor (C1.6a seed)
BIG=~/Documents/some-10-to-24MB.pdf                  # a real, valid PDF over 4.5MB
DC=$(uuidgen|tr 'A-F' 'a-f'); EX=$(uuidgen|tr 'A-F' 'a-f')
BASE="$URL/storage/v1/object/documents/estates/$ESTATE/claim-evidence"
curl -s -X POST "$BASE/$DC.pdf" -H "apikey: $PUB" -H "Authorization: Bearer $EXEC" -H "Content-Type: application/pdf" --data-binary @"$BIG"; echo
curl -s -X POST "$BASE/$EX.pdf" -H "apikey: $PUB" -H "Authorization: Bearer $EXEC" -H "Content-Type: application/pdf" --data-binary @"$BIG"; echo
CLAIM=$(curl -s "$URL/rest/v1/rpc/submit_claim_with_evidence" -H "apikey: $PUB" -H "Authorization: Bearer $EXEC" \
  -H "Content-Type: application/json" -d "{\"p_estate\":\"$ESTATE\",
  \"p_death_cert_doc_id\":\"$DC\",\"p_death_cert_path\":\"estates/$ESTATE/claim-evidence/$DC.pdf\",
  \"p_executor_id_doc_id\":\"$EX\",\"p_executor_id_path\":\"estates/$ESTATE/claim-evidence/$EX.pdf\"}" | tr -d '"'); echo "claim=$CLAIM"

# api HOP proof (admin aal2 JWT — mint per the C1.6b/test-estate reference): expect 200 + full Content-Length,
# NOT 413. Before this slice a >4.5MB object here returned FUNCTION_PAYLOAD_TOO_LARGE.
curl -s -D - -o /tmp/big_out.pdf "$API/api/claims/view_evidence" \
  -H "Authorization: Bearer $ADMIN_AAL2" -H "Content-Type: application/json" \
  -d "{\"claimId\":\"$CLAIM\",\"slot\":\"death_cert\"}" | grep -iE 'HTTP/|content-length'
ls -l /tmp/big_out.pdf   # size == the uploaded PDF (streamed through, not capped)
```

End-to-end: sign into the console → **Claims → Review** on `$CLAIM` → open the death certificate → **the large
PDF renders inline** (before: it would fail the 4 MB guard). That render is the both-hops-stream proof.

## Cleanup

```sql
delete from public.claim_packets where estate_id='9add2645-b3ef-4c25-b315-63900833ba5a' and status<>'rejected';
delete from public.documents where estate_id='9add2645-b3ef-4c25-b315-63900833ba5a' and title in ('Death Certificate','Executor ID');
-- delete the LEG-(b) storage objects via the Storage UI.
```

## Which legs need what

| Leg | Mechanism |
|---|---|
| (a) three numbers agree | SQL — no deploy |
| (d) told == allowed | SQL — no deploy |
| (c) >limit rejected at upload | curl to Storage — no deploy |
| (b) large object end-to-end | **deploy the api branch + run the console** (real >4.5MB PDF) |
