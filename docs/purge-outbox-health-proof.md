# Purge-outbox health + debris cleanup — proof + operational steps (migration 0040)

Christ runs these against live. Test estate (memory `afterworth-test-estate-curl-reference`): Supabase
`https://yiaavvkulrpqkkbqhwit.supabase.co`, estate `9add2645-b3ef-4c25-b315-63900833ba5a`, admin uid
`16db5021-4870-4d66-9d71-0b73d72363d0` (the only `public.admins` row), owner uid `77ef850e-6e12-449b-816e-d51f35332298`.
**Discipline:** the SQL editor autocommits each statement, so `set_config('request.jwt.claims',…,true)` + the call
must be in ONE `DO` block; clean up test rows explicitly.

> Apply `0040_*.sql` first (SQL editor). It's a read-only RPC — no outbox/sweeper mechanics change.

## Leg 1 — health returns correct counts (seed → reflect → drain → clear)

```sql
-- Baseline read (crafted admin claims: is_admin reads the admins table, so success needs THIS uid + aal2 + fresh iat).
do $$
declare v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub','16db5021-4870-4d66-9d71-0b73d72363d0',
    'role','authenticated','aal','aal2','iat',extract(epoch from now())::bigint)::text, true);
  v := public.purge_outbox_health();
  raise notice 'baseline: %', v;
end $$;

-- Seed a PENDING outbox row (aged 27h so it also exercises the >26h threshold), then re-read.
insert into public.storage_deletion_outbox (id, estate_id, bucket, object_path, reason, requested_by, requested_at, status)
values ('aaaaaaaa-0000-0000-0000-00000000a001','9add2645-b3ef-4c25-b315-63900833ba5a','documents',
        'estates/9add2645-b3ef-4c25-b315-63900833ba5a/vault/_healthprobe.pdf','document_deleted',
        '77ef850e-6e12-449b-816e-d51f35332298', now() - interval '27 hours', 'pending');
do $$
declare v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub','16db5021-4870-4d66-9d71-0b73d72363d0',
    'role','authenticated','aal','aal2','iat',extract(epoch from now())::bigint)::text, true);
  v := public.purge_outbox_health();
  raise notice 'after seed: %', v;   -- EXPECT pending_count +1; oldest_pending_age_seconds ~ 97200 (27h)
end $$;

-- Drain it (mark purged) → re-read.
update public.storage_deletion_outbox set status='purged', purged_at=now()
 where id='aaaaaaaa-0000-0000-0000-00000000a001';
do $$
declare v jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub','16db5021-4870-4d66-9d71-0b73d72363d0',
    'role','authenticated','aal','aal2','iat',extract(epoch from now())::bigint)::text, true);
  v := public.purge_outbox_health();
  raise notice 'after drain: %', v;  -- EXPECT pending back to baseline; purged_last_24h +1; last_successful_drain_at now
end $$;

delete from public.storage_deletion_outbox where id='aaaaaaaa-0000-0000-0000-00000000a001';   -- cleanup
```

## Leg 2 — admin gate both doors

```sql
-- non-admin (owner uid) → admin_required
do $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub','77ef850e-6e12-449b-816e-d51f35332298',
    'role','authenticated','aal','aal2','iat',extract(epoch from now())::bigint)::text, true);
  begin perform public.purge_outbox_health(); raise notice 'FAIL: allowed';
  exception when others then raise notice 'denied: %', sqlerrm; end;   -- EXPECT admin_required
end $$;

-- admin at aal1 → mfa_required
do $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub','16db5021-4870-4d66-9d71-0b73d72363d0',
    'role','authenticated','aal','aal1','iat',extract(epoch from now())::bigint)::text, true);
  begin perform public.purge_outbox_health(); raise notice 'FAIL: allowed';
  exception when others then raise notice 'denied: %', sqlerrm; end;   -- EXPECT mfa_required
end $$;
```
Direct-PostgREST door (real JWTs): `curl -s -X POST "$SB/rest/v1/rpc/purge_outbox_health" -H "apikey: $PUB" -H "Authorization: Bearer <non-admin JWT>"` → 401/`admin_required` (the gate lives inside; the endpoint-less RPC buys no privilege).

## Leg 3 — thresholds render (console)

Seed an aged-27h pending row and LEAVE it (Leg 1 deletes its probe at the end, so it can't drive this):
```sql
insert into public.storage_deletion_outbox (id, estate_id, bucket, object_path, reason, requested_by, requested_at, status)
values ('aaaaaaaa-0000-0000-0000-00000000a003','9add2645-b3ef-4c25-b315-63900833ba5a','documents',
        'estates/9add2645-b3ef-4c25-b315-63900833ba5a/vault/_healthprobe3.pdf','document_deleted',
        '77ef850e-6e12-449b-816e-d51f35332298', now() - interval '27 hours', 'pending');
```
Then in the console: **Refresh** `/hygiene` → **"Purge queue — attention needed"** (red) + reason "Oldest pending
1d 3h — over 26h…" + PENDING 1 / OLDEST PENDING `1d 3h` in red. Clean up → Refresh → back to **"— healthy"**
(quiet — confirms no standing yellow):
```sql
delete from public.storage_deletion_outbox where id='aaaaaaaa-0000-0000-0000-00000000a003';
```

## Leg 4 — orphan count agrees with the list (grid output)

```sql
drop table if exists _leg4;
create temp table _leg4(source text, cnt bigint);
do $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub','16db5021-4870-4d66-9d71-0b73d72363d0',
    'role','authenticated','aal','aal2','iat',extract(epoch from now())::bigint)::text, true);
  insert into _leg4 values ('health',(public.purge_outbox_health()->>'orphan_candidate_count')::bigint),
                           ('list',(select count(*) from public.list_orphan_storage_objects(72,100)));
end $$;
select * from _leg4;   -- EXPECT both rows EQUAL (same predicate, same 100-cap)
```
(A `DO` block alone says "Success. No rows returned" — the `raise notice` would be in the Messages tab; the temp
table surfaces the two counts in the results grid.)

## Leg 5 — MOOT (the health count already excludes the <72h debris)

`orphan_candidate_count` uses `list_orphan_storage_objects(72, …)` — a 72h grace — so the ~22 debris objects
(younger than 72h) are NOT counted; the live count is already **0** (confirmed on-console). No debris cleanup is
needed for the health surface; the debris ages into a candidate at 72h and the normal /hygiene Preview→Delete
reclaims it. This leg is closed by construction.

---

# Unit 3 — debris cleanup (OPTIONAL — the health count already excludes it)

★ Not required for the hygiene surface: `orphan_candidate_count` uses a 72h grace, so the <72h test debris isn't
counted (live count is already 0). This is only "tidy the bucket" housekeeping. The seeded metadata-only test
objects have no `documents` row; a `storage.objects` row can't be SQL-deleted (`protect_delete`), so reclaim via
the storage service — easiest is to just let them age past 72h and use the console Preview→Delete.

### ★ RECOMMENDED — wait for 72h, then the /hygiene console (ZERO tokens)

The oldest debris is seeded ~2026-07-22/23; once it crosses the 72h grace (~2026-07-25) the existing **/hygiene
console → Preview → Delete** lists + removes it. The console is browser-authenticated (the admin's logged-in
session) and the service-role key stays server-side — **nothing is pasted or minted.** Given the terminal's
paste-mangling, this is the most reliable path; the debris count is cosmetic until then (the health RPC + panel
already work). Do Leg 5 after this.

### Alternative — the sweep endpoint with `graceHours: 0` (NO local service key)

The proven `sweep_orphans` endpoint already does service-role `storage.remove` SERVER-SIDE (its key lives in
Vercel, never exposed). The console hardcodes 72h, but the endpoint takes `graceHours` — `0` catches the <72h
debris (age > 0h). Needs an admin **aal2** JWT (the sweep is admin-gated; mint per the test-estate memo).

```bash
API=https://afterworth-api.vercel.app
PUB=sb_publishable_3H1FEeDBfP-ZBWer7f2gQA_xcLboYV2
# ADMIN_JWT = an aal2 admin JWT (admin uid 16db5021…). Dry-run lists ALL orphans; confirm removes them.
curl -s -X POST "$API/api/claims/sweep_orphans" -H "apikey: $PUB" -H "Authorization: Bearer $ADMIN_JWT" \
  -H "Content-Type: application/json" -d '{"confirm":false,"graceHours":0,"max":100}'   # dry-run: {count, orphans[]}
curl -s -X POST "$API/api/claims/sweep_orphans" -H "apikey: $PUB" -H "Authorization: Bearer $ADMIN_JWT" \
  -H "Content-Type: application/json" -d '{"confirm":true,"graceHours":0,"max":100}'    # {deleted: N}
```
(If you rotated the service key, first update `SUPABASE_SECRET_KEY` in the Vercel env + redeploy so the endpoint
uses the current key.)

Then re-run Leg 4/5: `orphan_candidate_count` drops to the genuine figure.

## Pass criteria
1. counts correct (seed→drain reflected) · 2. gate denies non-admin + aal1 (both doors) · 3. thresholds render
degraded then quiet · 4. orphan count == list count · 5. post-cleanup candidate count = genuine figure.
