# Account aggregation — sandbox re-proof recipe

The Plaid sandbox account-aggregation flow (`api/connections/[action].ts`) was curl-proven 16/16.
There is intentionally **no deployed `sandbox_public_token` endpoint** — prod carries no
token-minting surface. To re-prove the flow, mint the `public_token` with the **local recipe**
below (a direct call to `sandbox.plaid.com`), then drive the four real actions.

## Prereqs

- Sandbox `PLAID_CLIENT_ID` + `PLAID_SECRET`. These are **write-only in Vercel** (`vercel env pull`
  returns them empty by design), so supply them locally for the re-proof — they are NOT recoverable
  from the deployment:
  ```bash
  export PLAID_CLIENT_ID=...        # sandbox client id
  export PLAID_SECRET=...           # sandbox secret
  ```
- An owner JWT for the test estate (password-grant against Supabase) in `$OJWT`, plus
  `API=https://afterworth-api.vercel.app`, the publishable key in `$PUB`, and the estate id in
  `$ESTATE`.

## 1. Mint a public_token — THE LOCAL RECIPE (no deployed endpoint)

```bash
PUBLIC_TOKEN=$(curl -s -X POST https://sandbox.plaid.com/sandbox/public_token/create \
  -H "Content-Type: application/json" \
  -d "{\"client_id\":\"$PLAID_CLIENT_ID\",\"secret\":\"$PLAID_SECRET\",
       \"institution_id\":\"ins_109508\",\"initial_products\":[\"investments\"]}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['public_token'])")
```
`ins_109508` (First Platypus Bank) supports investments, so the item carries brokerage/retirement
accounts **with holdings** — the proof must exercise holdings, not just cash balances.
(`lib/plaid.ts` exports `sandboxCreatePublicToken`, the same call, if you prefer to re-wire it to a
temporary action instead.)

## 2. Drive the four deployed actions

```bash
post(){ curl -s -X POST "$API/api/connections/$1" \
  -H "apikey: $PUB" -H "Authorization: Bearer $OJWT" -H "Content-Type: application/json" -d "$2"; }

post create_link_token '{}'                                    # -> { linkToken: "link-sandbox-…" }
post exchange "{\"estateId\":\"$ESTATE\",\"publicToken\":\"$PUBLIC_TOKEN\",
                \"institutionId\":\"ins_109508\",\"institutionName\":\"First Platypus Bank\"}"
                                                               # -> { connection }  (NO access_token)
post refresh "{\"connectionId\":\"<id from exchange>\"}"        # -> { assets: [...] }  (with holdings)
post list "{\"estateId\":\"$ESTATE\"}"                          # -> { connections, assets }
```

## What to assert

- `exchange` / `list` responses contain **no `access_token`** (only the `referenceToken` handle).
- `refresh` yields ≥1 asset with `assetGroup ∈ {investmentBrokerage, retirement}` and a non-empty
  `holdings` array with `value_cents > 0` (the investments-shape normalization, not just cash).
- A direct REST `SELECT` on `connection_secrets` (owner OR non-owner JWT) is **denied (42501)** — the
  access_token is reachable only through the `get_connection_access_token` DEFINER RPC, server-side.

See `lib/plaid.ts` (the only Plaid-aware module) and `db/migrations/0007_20260630_connections.sql`.
