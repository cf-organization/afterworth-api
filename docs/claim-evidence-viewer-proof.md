# Slice C1.6b — evidence viewer + decide: proof

The console evidence-serving path (death cert / executor ID → admin) and the unlocked decide action.
Serving is **proxied bytes** (no signed URL): the api endpoint runs the admin gate INSIDE
`admin_authorize_claim_evidence`, resolves the storage_path from the named claim ONLY, writes the
`claim.evidence_viewed` audit, then service-role-downloads and streams the PDF. The console reaches it
only through its own same-origin BFF (`/api/claim-evidence`), so its CSP stays `connect-src 'self'`.

Built + proven against **hand-seeded** real PDFs (service-role serving bypasses the incoherent
`docs_owner_rw` storage RLS). Live iOS executor upload is **C1.6a** (separate, deferred).

## Environment

```bash
export URL=https://yiaavvkulrpqkkbqhwit.supabase.co
export PUB=sb_publishable_3H1FEeDBfP-ZBWer7f2gQA_xcLboYV2
export API=https://afterworth-api.vercel.app
export CLAIM=c1c6b000-0000-0000-0000-000000000001          # the seeded claim (below)
# Accounts: admin = the public.admins row (16db5021-…, has MFA); non-admin = tekay58247@ocuser.com.
```

---

## PREREQ — seed hand-placed evidence

The viewer needs a real object in the private `documents` bucket + a claim that references it.

### PART 1 — Storage UI

Upload two real PDFs (< 4 MB each) to the `documents` bucket at **exactly** these object names
(the claim-scoped shape C1.6a will use — testing resolution against the production path convention):

```
estates/9add2645-b3ef-4c25-b315-63900833ba5a/claims/c1c6b000-0000-0000-0000-000000000001/death_cert.pdf
estates/9add2645-b3ef-4c25-b315-63900833ba5a/claims/c1c6b000-0000-0000-0000-000000000001/executor_id.pdf
```

### PART 2 — SQL editor

Fixed ids let the object names above be known before the rows exist. `%type` inherits the exact
`doc_type` / `sensitivity` types + a CHECK-valid value from a real row (no vocabulary guessing).

```sql
do $$
declare
  v_estate      uuid := '9add2645-b3ef-4c25-b315-63900833ba5a';
  v_submitter   uuid := 'cb5edecc-b7b7-468a-ad4f-c378b43095c9';   -- tekay (has a profiles row → display)
  v_claim       uuid := 'c1c6b000-0000-0000-0000-000000000001';
  v_dc          uuid := 'd0c00001-0000-0000-0000-000000000001';
  v_ex          uuid := 'd0c00001-0000-0000-0000-000000000002';
  v_doc_type    public.documents.doc_type%type;
  v_sensitivity public.documents.sensitivity%type;
begin
  select doc_type, sensitivity into v_doc_type, v_sensitivity from public.documents limit 1;

  -- Append-only: free the one-active-per-estate slot by rejecting, never deleting.
  update public.claim_packets set status = 'rejected'
   where estate_id = v_estate and status <> 'rejected' and id <> v_claim;

  insert into public.documents
    (id, estate_id, owner_id, doc_type, title, storage_path, mime_type, size_bytes, is_encrypted, sensitivity)
  values
    (v_dc, v_estate, v_submitter, v_doc_type, 'TEST Death Certificate (C1.6b)',
     'estates/'||v_estate||'/claims/'||v_claim||'/death_cert.pdf', 'application/pdf', 1024, false, v_sensitivity),
    (v_ex, v_estate, v_submitter, v_doc_type, 'TEST Executor ID (C1.6b)',
     'estates/'||v_estate||'/claims/'||v_claim||'/executor_id.pdf', 'application/pdf', 1024, false, v_sensitivity)
  on conflict (id) do update
    set storage_path = excluded.storage_path, estate_id = excluded.estate_id, mime_type = excluded.mime_type;

  insert into public.claim_packets
    (id, estate_id, requested_by, status, submitted_at, death_certificate_doc_id, executor_id_doc_id)
  values (v_claim, v_estate, v_submitter, 'submitted', now(), v_dc, v_ex)
  on conflict (id) do update
    set status='submitted', death_certificate_doc_id=excluded.death_certificate_doc_id,
        executor_id_doc_id=excluded.executor_id_doc_id, decided_at=null, reviewer_id=null, review_notes=null;
end $$;
```

> If the `documents` insert errors on an unset NOT NULL / UNIQUE column (most likely `sha256`), add it to
> the column list with a per-doc value — `extensions.digest(id::text,'sha256')` (bytea) or its hex (text).

Verify the seed resolves:

```sql
select cp.id, cp.status, cp.death_certificate_doc_id, cp.executor_id_doc_id,
       d1.storage_path dc_path, d2.storage_path ex_path
from public.claim_packets cp
left join public.documents d1 on d1.id = cp.death_certificate_doc_id
left join public.documents d2 on d2.id = cp.executor_id_doc_id
where cp.id = 'c1c6b000-0000-0000-0000-000000000001';
-- expect: status submitted, both doc ids set, both *_path = the hand-placed object names.
```

---

## Mint tokens

```bash
tok() { curl -s "$URL/auth/v1/token?grant_type=password" -H "apikey: $PUB" \
  -H 'Content-Type: application/json' -d "{\"email\":\"$1\",\"password\":\"$2\"}" | jq -r .access_token; }

NONADMIN=$(tok tekay58247@ocuser.com 'Hilton23Users!')     # non-admin, aal1
ADMIN_AAL1=$(tok "$ADMIN_EMAIL" "$ADMIN_PASSWORD")          # admin, aal1 (pre-TOTP)
# ADMIN_AAL2: password-grant → factor challenge → verify (fresh TOTP) → decode to confirm aal=aal2.
# See afterworth-test-estate-curl-reference for the challenge/verify sequence. Export as $ADMIN_AAL2.
```

---

## Leg A — view_evidence BOTH DOORS

**A1 — RPC direct door** (`rest/v1/rpc/…`; the product interface for a raw caller — the gate must hold here):

```bash
# anon → 401 (no EXECUTE for anon; REVOKEd)
curl -s -o /dev/null -w '%{http_code}\n' "$URL/rest/v1/rpc/admin_authorize_claim_evidence" \
  -H "apikey: $PUB" -H 'Content-Type: application/json' \
  -d "{\"p_claim\":\"$CLAIM\",\"p_slot\":\"death_cert\"}"                          # expect 401

# non-admin aal1 → admin_required (42501)
curl -s "$URL/rest/v1/rpc/admin_authorize_claim_evidence" -H "apikey: $PUB" \
  -H "Authorization: Bearer $NONADMIN" -H 'Content-Type: application/json' \
  -d "{\"p_claim\":\"$CLAIM\",\"p_slot\":\"death_cert\"}"                          # expect {"message":"admin_required"}

# admin aal1 → mfa_required (42501, require_aal2)
curl -s "$URL/rest/v1/rpc/admin_authorize_claim_evidence" -H "apikey: $PUB" \
  -H "Authorization: Bearer $ADMIN_AAL1" -H 'Content-Type: application/json' \
  -d "{\"p_claim\":\"$CLAIM\",\"p_slot\":\"death_cert\"}"                          # expect {"message":"mfa_required"}

# admin aal2 fresh → resolves the row (storage_path + document_id + mime_type)
curl -s "$URL/rest/v1/rpc/admin_authorize_claim_evidence" -H "apikey: $PUB" \
  -H "Authorization: Bearer $ADMIN_AAL2" -H 'Content-Type: application/json' \
  -d "{\"p_claim\":\"$CLAIM\",\"p_slot\":\"death_cert\"}"                          # expect [{storage_path,…}]
```

**A2 — Vercel endpoint door** (`/api/claims/view_evidence`; the console's real path):

```bash
# non-admin → 403 (body carries the gate sentinel, not a generic forbidden)
curl -s -o /dev/null -w '%{http_code}\n' "$API/api/claims/view_evidence" \
  -H "Authorization: Bearer $NONADMIN" -H 'Content-Type: application/json' \
  -d "{\"claimId\":\"$CLAIM\",\"slot\":\"death_cert\"}"                            # expect 403

# admin aal1 → 403 mfa_required
curl -s "$API/api/claims/view_evidence" -H "Authorization: Bearer $ADMIN_AAL1" \
  -H 'Content-Type: application/json' -d "{\"claimId\":\"$CLAIM\",\"slot\":\"death_cert\"}"   # {"error":"mfa_required"}

# admin aal2 → 200 + PDF bytes
curl -s -D - -o /tmp/dc.pdf "$API/api/claims/view_evidence" \
  -H "Authorization: Bearer $ADMIN_AAL2" -H 'Content-Type: application/json' \
  -d "{\"claimId\":\"$CLAIM\",\"slot\":\"death_cert\"}" | grep -iE 'HTTP/|content-type'
file /tmp/dc.pdf   # expect: PDF document
```

---

## Leg B — anti-traversal (structural)

The endpoint accepts ONLY `{claimId, slot}` — there is **no path or document_id to inject**.

```bash
# forged slot → 400 (SLOTS allowlist + the RPC CHECK)
curl -s "$API/api/claims/view_evidence" -H "Authorization: Bearer $ADMIN_AAL2" \
  -H 'Content-Type: application/json' -d "{\"claimId\":\"$CLAIM\",\"slot\":\"../../etc\"}"    # {"error":"invalid_request"}

# a claim id that doesn't exist → 404 (claim_not_found)
curl -s "$API/api/claims/view_evidence" -H "Authorization: Bearer $ADMIN_AAL2" \
  -H 'Content-Type: application/json' \
  -d "{\"claimId\":\"00000000-0000-0000-0000-000000000000\",\"slot\":\"death_cert\"}"        # {"error":"evidence_not_found"}

# a claim whose slot has NO doc → 404 (evidence_not_found). Point CLAIM at a NULL-slot claim, or:
#   update public.claim_packets set executor_id_doc_id = null where id = '$CLAIM';  -- then request slot=executor_id
```

The only reachable objects are the two docs ON the named claim (admins are global reviewers by design).

---

## Leg C — audit on view (cross-surface)

Each successful A1/A2 aal2 view writes one row (inside the RPC, before the path leaves the DB):

```sql
select action, source, target_table, target_id, metadata
from public.audit_logs
where action = 'claim.evidence_viewed' order by created_at desc limit 4;
-- expect: source='admin', target_table='documents', target_id=<doc>,
--         metadata = {severity:'high', claim_id:<CLAIM>, document_id:<doc>, slot:'death_cert'|'executor_id'}
```

Cross-surface: the same rows appear in the console **Audit** tab (`claim.evidence_viewed`, admin, high).

---

## Leg D — decide (browser; admin_decide_claim_packet, already shipped)

On `/claims/<CLAIM>`, after opening the evidence:

- **Approve** → status → `approved`; a `claim.approved` (source admin, high) audit lands; the row shows
  **"release pending (C5)"** (approval does NOT release assets).
- **Reject** → status → `rejected` + `claim.rejected` audit.
- **Already-decided** → re-deciding the opposite way surfaces *"already decided elsewhere — reload"*
  (the RPC's `claim_already_decided`, P0001), never a silent flip. (Reset with the seed to re-run.)
- **Soft nudge** → open the decide dialog WITHOUT opening an attached doc → the amber
  *"you have not opened all attached evidence — decide anyway?"* nudge appears.

---

## Leg E — CSP (prod build)

```bash
cd afterworth-admin && npm run build && npm run start &   # prod build serves the STRICT CSP
curl -sI http://localhost:3000/claims/$CLAIM | grep -i content-security-policy
# expect the directive to include:  frame-src blob:   (and script-src 'nonce-…' 'strict-dynamic')
```

In the browser DevTools console on `/claims/<CLAIM>`, opening a PDF logs **zero** CSP violations
(the alarm channel stays silent on a real view).

---

## Leg F — size guard

```bash
# hand-place a > 4 MB object at a claim's slot path (or point a doc row at a large object), request it:
curl -s -o /dev/null -w '%{http_code}\n' "$API/api/claims/view_evidence" \
  -H "Authorization: Bearer $ADMIN_AAL2" -H 'Content-Type: application/json' \
  -d "{\"claimId\":\"$CLAIM\",\"slot\":\"death_cert\"}"                            # expect 413 (evidence_too_large)
```

---

## Deterministic supplement — crafted claims (SQL editor)

The endpoint + PostgREST doors need a REAL signed JWT (signature-verified), so crafted
`request.jwt.claims` can't drive them. But to exercise the **gate ladder** (incl. the stale-iat branch)
without a live TOTP, run the function directly in the SQL editor with crafted claims in a single DO block
(the editor autocommits each statement, so set_config + the call must share ONE block; clean up explicitly):

```sql
do $$
declare v_out record;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub','16db5021-4870-4d66-9d71-0b73d72363d0','role','authenticated',
                      'aal','aal2','iat', extract(epoch from now())::bigint)::text, true);
  select * into v_out from public.admin_authorize_claim_evidence('c1c6b000-0000-0000-0000-000000000001','death_cert');
  raise notice 'resolved path=% doc=%', v_out.storage_path, v_out.document_id;   -- Notices panel
end $$;
-- Variants: aal='aal1' → mfa_required; iat = now()-1000 → stale_token_reauth_required;
--           sub = a non-admin uid → admin_required. (is_admin() reads public.admins — crafted sub can't fake it.)
-- Cleanup the crafted claim.evidence_viewed audit rows the aal2 success writes:
--   delete from public.audit_logs where action='claim.evidence_viewed' and metadata->>'claim_id'='c1c6b000-0000-0000-0000-000000000001';
```
