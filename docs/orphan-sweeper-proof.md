# Orphan-upload retention sweeper — proof

Reclaims `documents`-bucket objects with no authoritative row (interrupted-submit PII). Identify RPC
(`list_orphan_storage_objects`, admin-gated) + `sweep_orphans` action on the claims dispatcher (service-role
`storage.remove`; **byte deletion needs the storage API — a SQL row delete leaves the bytes**). Dry-run default;
`confirm:true` deletes; audited both modes; batch cap 100; NO undo.

## Environment

```bash
export URL=https://yiaavvkulrpqkkbqhwit.supabase.co
export PUB=sb_publishable_3H1FEeDBfP-ZBWer7f2gQA_xcLboYV2
export API=https://afterworth-api.vercel.app
export SVC='<service_role / sb_secret key>'   # for seeding orphans (bypasses storage RLS)
# ADMIN_AAL2 = the public.admins account's aal2 JWT (password → TOTP challenge/verify — see the test-estate ref).
```

Apply `0034`, deploy the api branch (`vercel --prod` from feature/orphan-sweeper), then:

## Seed an orphan (an object with NO documents row)

```bash
ORPHAN="estates/9add2645-b3ef-4c25-b315-63900833ba5a/claim-evidence/$(uuidgen|tr 'A-F' 'a-f').pdf"
curl -s -X POST "$URL/storage/v1/object/documents/$ORPHAN" \
  -H "apikey: $SVC" -H "Authorization: Bearer $SVC" -H "Content-Type: application/pdf" --data-binary @/tmp/big.pdf; echo
echo "seeded: $ORPHAN"
# a fresh object with no documents.storage_path referencing it → a genuine orphan (just <72h old).
```

## Leg A — a REFERENCED object is NEVER listed

The a3faab1b claim's two evidence objects have documents rows → they must NOT appear. With `graceHours:0` (lists
even fresh objects), the dry-run returns the seeded orphan but never a referenced object:

```bash
curl -s "$API/api/claims/sweep_orphans" -H "Authorization: Bearer $ADMIN_AAL2" -H "Content-Type: application/json" \
  -d '{"graceHours":0,"max":100}' | jq '{mode, count, names: [.orphans[].object_name]}'
# expect: mode "dry_run"; the seeded $ORPHAN present; NO estates/9add2645/.../<claim-doc>.jpeg (those are referenced).
```

## Leg B — DRY-RUN lists + audits, deletes nothing

The Leg-A call is the dry-run (no `confirm`). Confirm it deleted nothing + audited:
```bash
curl -s -o /dev/null -w '%{http_code}\n' "$URL/storage/v1/object/documents/$ORPHAN" -H "apikey: $SVC" -H "Authorization: Bearer $SVC"
# expect: 200 — the object still exists after a dry-run.
```
```sql
select metadata->>'mode', metadata->>'count', metadata->'paths'
from public.audit_logs where action='storage.orphans_swept' order by created_at desc limit 1;
-- expect: mode 'dry_run', count includes the orphan, paths lists it. source='admin', actor = the admin.
```

## Leg C — confirm:true DELETES + audits; the object is GONE

```bash
curl -s "$API/api/claims/sweep_orphans" -H "Authorization: Bearer $ADMIN_AAL2" -H "Content-Type: application/json" \
  -d '{"confirm":true,"graceHours":0,"max":100}' | jq '{mode, deleted}'
# expect: mode "delete", deleted >= 1
curl -s -o /dev/null -w '%{http_code}\n' "$URL/storage/v1/object/documents/$ORPHAN" -H "apikey: $SVC" -H "Authorization: Bearer $SVC"
# expect: 400/404 — the object is GONE from storage (bytes removed via the storage API).
```
```sql
select metadata->>'mode', metadata->>'count' from public.audit_logs
where action='storage.orphans_swept' order by created_at desc limit 1;   -- mode 'delete', count >= 1
```

## Leg D — idempotent re-run is a no-op

```bash
curl -s "$API/api/claims/sweep_orphans" -H "Authorization: Bearer $ADMIN_AAL2" -H "Content-Type: application/json" \
  -d '{"confirm":true,"graceHours":0,"max":100}' | jq '{mode, deleted}'
# expect: deleted 0 (the orphan is already gone; nothing else qualifies) — safe to re-run.
```

## Leg E — batch cap respected

Seed 101 orphans (loop the seed curl), then dry-run: `count` is capped at **100** (the RPC's `LIMIT least(...,100)`).
Re-running drains the remainder. (Or trust the cap: the RPC clamps `p_max` to 100 regardless of the request.)

## Leg F — gate: non-admin / aal1 denied BOTH doors

```bash
# Endpoint door — a non-admin (tekay) JWT:
NONADMIN=$(curl -s "$URL/auth/v1/token?grant_type=password" -H "apikey: $PUB" -H 'Content-Type: application/json' \
  -d '{"email":"tekay58247@ocuser.com","password":"Hilton23Users!"}' | jq -r .access_token)
curl -s -o /dev/null -w '%{http_code}\n' "$API/api/claims/sweep_orphans" -H "Authorization: Bearer $NONADMIN" \
  -H "Content-Type: application/json" -d '{}'                                   # expect 403 (admin_required)

# Direct RPC door — anon 401; non-admin admin_required:
curl -s -o /dev/null -w '%{http_code}\n' "$URL/rest/v1/rpc/list_orphan_storage_objects" -H "apikey: $PUB" \
  -H 'Content-Type: application/json' -d '{}'                                    # expect 401
curl -s "$URL/rest/v1/rpc/list_orphan_storage_objects" -H "apikey: $PUB" \
  -H "Authorization: Bearer $NONADMIN" -H 'Content-Type: application/json' -d '{}'   # {"message":"admin_required"}
```
Admin aal1 → `mfa_required`; stale token → `stale_token_reauth_required` (crafted-claims DO block if a real stale
token is inconvenient — the same `admin_require_gate` ladder as every other admin RPC).

## Cleanup

Any orphans seeded for the proof are removed by Leg C; delete leftover audit rows if desired:
`delete from public.audit_logs where action='storage.orphans_swept' and (metadata->>'grace_hours')='0';`
(The `graceHours:0` marker distinguishes test runs from real 72h sweeps.)
