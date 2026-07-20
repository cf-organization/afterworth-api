# get_my_estate_designations() — proof (Slice C1.6a-iOS executor signal)

The minimal iOS executor signal: the caller's own ACTIVE designations. Supabase-direct (no endpoint).

```bash
export URL=https://yiaavvkulrpqkkbqhwit.supabase.co
export PUB=sb_publishable_3H1FEeDBfP-ZBWer7f2gQA_xcLboYV2
tok(){ curl -s "$URL/auth/v1/token?grant_type=password" -H "apikey: $PUB" \
  -H 'Content-Type: application/json' -d "{\"email\":\"$1\",\"password\":\"$2\"}" | jq -r .access_token; }
```

Apply `0033`, then:

```bash
# An active executor (tekay, designated executor of the test estate 9add2645) sees their designation.
EXEC=$(tok tekay58247@ocuser.com 'Hilton23Users!')
curl -s "$URL/rest/v1/rpc/get_my_estate_designations" -H "apikey: $PUB" -H "Authorization: Bearer $EXEC"; echo
# expect: [{"estate_id":"9add2645-b3ef-4c25-b315-63900833ba5a","designation_type":"executor","status":"active"}]

# anon -> 401 (no EXECUTE for anon; REVOKEd).
curl -s -o /dev/null -w '%{http_code}\n' "$URL/rest/v1/rpc/get_my_estate_designations" -H "apikey: $PUB"
# expect: 401
```

Scoping check (a caller sees ONLY their own): a non-designee's token returns `[]`; there is no way to pass
another user's id (the RPC keys on `auth.uid()`, no params). Revoke the designation (`update
estate_designations set status='revoked' …`) → the row drops from the result (status filter), and the iOS
submit surface hides — access tracks the designation, matching the B3/B4 executor-arc invariant.
