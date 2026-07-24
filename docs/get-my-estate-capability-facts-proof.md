# get_my_estate_capability_facts — proof (migration 0041)

EstateRole Remap **Unit 2**, backend-first gate. Christ runs these against live before iOS wiring.

Test estate (memory `afterworth-test-estate-curl-reference`): Supabase
`https://yiaavvkulrpqkkbqhwit.supabase.co`, estate `9add2645-b3ef-4c25-b315-63900833ba5a`.
Accounts in that estate — owner `77ef850e-6e12-449b-816e-d51f35332298`, beneficiary
`cb5edecc-b7b7-468a-ad4f-c378b43095c9`, professional_delegate `fb97e207-39d4-4411-8987-fbd7a0d2fb2e`.
Platform admin `16db5021-4870-4d66-9d71-0b73d72363d0` is a NON-member of this estate (use it as the
"no membership" case).

**Discipline:** this RPC is `auth.uid()`-scoped with NO aal/admin gate, so crafted
`request.jwt.claims` in the SQL editor prove it fully — no passwords needed. `auth.uid()` reads
that GUC even inside a SECURITY DEFINER function (DEFINER changes the execution role, not the
claims). The SQL editor autocommits each top-level statement, so all crafted-claim legs live in
ONE `DO` block (the transaction-local `set_config` persists within it) and surface via a temp table.

> Apply `0041_20260724_get_my_estate_capability_facts.sql` first (SQL editor). Pure read — no
> table/policy/RPC changes.

## Leg 1–5 — facts per identity (one runnable block → results grid)

```sql
drop table if exists _facts_proof;
create temp table _facts_proof(leg text, expect text, result jsonb);

do $$
declare
  estate uuid := '9add2645-b3ef-4c25-b315-63900833ba5a';
  bogus  uuid := '00000000-0000-0000-0000-000000000000';
begin
  -- Leg 1 — OWNER
  perform set_config('request.jwt.claims',
    json_build_object('sub','77ef850e-6e12-449b-816e-d51f35332298','role','authenticated')::text, true);
  insert into _facts_proof values ('1 owner',
    'estate_exists=true, is_owner=true, role=primary_user, status=approved',
    public.get_my_estate_capability_facts(estate));

  -- Leg 2 — BENEFICIARY
  perform set_config('request.jwt.claims',
    json_build_object('sub','cb5edecc-b7b7-468a-ad4f-c378b43095c9','role','authenticated')::text, true);
  insert into _facts_proof values ('2 beneficiary',
    'is_owner=false, role=beneficiary, status=approved',
    public.get_my_estate_capability_facts(estate));

  -- Leg 3 — PROFESSIONAL_DELEGATE
  perform set_config('request.jwt.claims',
    json_build_object('sub','fb97e207-39d4-4411-8987-fbd7a0d2fb2e','role','authenticated')::text, true);
  insert into _facts_proof values ('3 professional',
    'is_owner=false, role=professional_delegate, status=approved',
    public.get_my_estate_capability_facts(estate));

  -- Leg 4 — NON-MEMBER (admin uid; not a member here) → membership not found (CONFIRMED negative)
  perform set_config('request.jwt.claims',
    json_build_object('sub','16db5021-4870-4d66-9d71-0b73d72363d0','role','authenticated')::text, true);
  insert into _facts_proof values ('4 non-member',
    'estate_exists=true, is_owner=false, role=null, status=null',
    public.get_my_estate_capability_facts(estate));

  -- Leg 5 — BOGUS estate → estate not found
  perform set_config('request.jwt.claims',
    json_build_object('sub','77ef850e-6e12-449b-816e-d51f35332298','role','authenticated')::text, true);
  insert into _facts_proof values ('5 bogus estate',
    'estate_exists=false, is_owner=false, role=null, status=null',
    public.get_my_estate_capability_facts(bogus));
end $$;

select * from _facts_proof order by leg;
```

**Expected grid:**

| leg | result |
|---|---|
| 1 owner | `is_owner=true, membership_role="primary_user", membership_status="approved", estate_exists=true` |
| 2 beneficiary | `is_owner=false, membership_role="beneficiary", membership_status="approved"` |
| 3 professional | `is_owner=false, membership_role="professional_delegate", membership_status="approved"` |
| 4 non-member | `is_owner=false, membership_role=null, membership_status=null, estate_exists=true` |
| 5 bogus estate | `estate_exists=false, is_owner=false, membership_role=null` |

(Leg 4 proves membership-not-found is a distinct fact from a fetch failure; Leg 5 proves estate-not-found.)

## Leg 6 — the grant (authenticated only; anon denied)

```sql
select
  has_function_privilege('authenticated','public.get_my_estate_capability_facts(uuid)','EXECUTE') as authenticated_can,
  has_function_privilege('anon',        'public.get_my_estate_capability_facts(uuid)','EXECUTE') as anon_can;
-- EXPECT: authenticated_can = true, anon_can = false
```

## Leg 7 — side-effect-free (unlike resolve_membership)

```sql
select count(*) as estates_count from public.estates;
-- Run this BEFORE and AFTER the Leg 1–5 block. The count MUST be identical — this RPC is STABLE
-- and never INSERTs (resolve_membership would bootstrap an estate for a caller with none; this must not).
```

## Leg 8 (optional) — real-JWT PostgREST door

Proves the `authenticated` grant + the live door end-to-end (Christ supplies the owner password at runtime):

```bash
URL=https://yiaavvkulrpqkkbqhwit.supabase.co
PUB=sb_publishable_3H1FEeDBfP-ZBWer7f2gQA_xcLboYV2
JWT=$(curl -s -X POST "$URL/auth/v1/token?grant_type=password" -H "apikey: $PUB" \
  -H "Content-Type: application/json" -d '{"email":"ckankeu2@gmail.com","password":"<owner-pw>"}' | jq -r .access_token)

# owner → facts
curl -s -X POST "$URL/rest/v1/rpc/get_my_estate_capability_facts" -H "apikey: $PUB" \
  -H "Authorization: Bearer $JWT" -H "Content-Type: application/json" \
  -d '{"p_estate":"9add2645-b3ef-4c25-b315-63900833ba5a"}'
# EXPECT: {"estate_id":"9add...","estate_exists":true,"is_owner":true,
#          "membership_role":"primary_user","membership_status":"approved"}

# anon door (no Authorization) → permission denied
curl -s -X POST "$URL/rest/v1/rpc/get_my_estate_capability_facts" -H "apikey: $PUB" \
  -H "Content-Type: application/json" -d '{"p_estate":"9add2645-b3ef-4c25-b315-63900833ba5a"}'
# EXPECT: 401 / permission denied (EXECUTE revoked from anon)
```

## Pass criteria
1. Legs 1–3: the three membership roles decode with `is_owner` correct (owner true, others false), status `approved`.
2. Leg 4: non-member → `membership_role=null` with `estate_exists=true` (confirmed negative, not a failure).
3. Leg 5: bogus estate → `estate_exists=false`.
4. Leg 6: `authenticated` can EXECUTE, `anon` cannot.
5. Leg 7: `estates` count unchanged (pure read, no bootstrap side effect).
6. Leg 8 (if run): owner JWT returns the same object via PostgREST; anon door denied.

---

## iOS mapping preview (for Phase B — not built until this is green)

The Swift DTO the live source will decode from the jsonb, and how it becomes `EstateCapabilities`:

```
EstateCapabilityFactsDTO { estate_id, estate_exists, is_owner, membership_role?, membership_status? }

isEstateOwner  = is_owner
accessClass    = (membership_status == "approved")
                   ? AccessClass.fromRawMembershipRole(membership_role)   // primary_user/beneficiary/
                                                                          // professional_delegate/unknown(raw)
                   : .notAMember                                          // null OR non-approved membership
fiduciary      = Set(get_my_estate_designations() rows for this estate → executor/trustee/unknown(raw))
EstateCapabilities.from(estateID, subjectUserID, isEstateOwner, accessClass, fiduciary)  // Unit 1 consistency rule

Failure semantics (source throws → store .unavailable, fail closed):
  facts RPC 401                 → authenticationFailed
  estate_exists == false        → estateNotFound
  EITHER RPC transport error    → factsUnavailable / designationsUnavailable   (partial-source → whole snapshot fails)
Confirmed negatives (source RESOLVES, fails closed per-affordance):
  membership_role == null       → accessClass .notAMember
  unrecognized role / type      → .unknown(raw)   (retained, diagnosable)
```

★ **Designation-failure decision (documented):** a designations-RPC failure **invalidates the entire
capability snapshot** (→ `.unavailable`), rather than yielding a resolved-membership-with-fiduciary-
unavailable partial. Rationale: "prefer correctness over UI continuity" — when fiduciary state can't be
determined, NOTHING resolves, so no fiduciary-dependent control can appear.
