# Vault document DELETE + REPLACE — proof matrix (migration 0039)

> ✅ **PROVEN GREEN against live — 2026-07-23.** create · replace · delete (hard, count 0, high-sev tombstone,
> outbox `document_deleted/pending`) · blocked-delete (`blocked_active_claim` / `blocked_legal_hold` /
> `blocked_retention`) · purge retry (`purged, attempts=2`) + idempotency (`outbox_not_found_or_purged`) ·
> rejected-claim delete (row persists `rejected`, `death_certificate_doc_id` → NULL) · client-immediate purge
> (`{"purged":true}`, download 400) · cron drain (`{"drained":1,"purged":1,"failed":0}`, no-secret 401) ·
> orphan-sweeper predicate unchanged (`candidates=22`). Byte deletion proven via BOTH the endpoint and the cron.

Prove the complete lifecycle against **live** before the PR. Christ runs these; Claude Code doesn't touch the DB.
Test estate (memory `afterworth-test-estate-curl-reference`):

- **Estate:** `9add2645-b3ef-4c25-b315-63900833ba5a`
- **Owner uid:** `77ef850e-6e12-449b-816e-d51f35332298` (`ckankeu2@gmail.com`)
- **Admin uid** (in `public.admins`): `16db5021-4870-4d66-9d71-0b73d72363d0`

**Two hosts — do NOT conflate them:** Supabase `SB=https://yiaavvkulrpqkkbqhwit.supabase.co` (storage + `/rest/v1/rpc`)
vs the Vercel api `API=https://afterworth-api.vercel.app` (`/api/claims/*`). **Discipline:** the SQL editor autocommits
each statement, so `set_config(...,true)` + the RPC call live in **ONE `DO` block** — **run the whole block, not a
selection.** `✅ CREATE / REPLACE / DELETE already proved green` in the first run; this doc fixes the claim/purge/curl
legs.

> Apply `0039_*.sql` (whole file) first. For the curl legs, deploy the api: `vercel --prod --yes`, and set `CRON_SECRET`.

```bash
# curl env (run once)
SB=https://yiaavvkulrpqkkbqhwit.supabase.co
API=https://afterworth-api.vercel.app
PUB=sb_publishable_3H1FEeDBfP-ZBWer7f2gQA_xcLboYV2
OWNER_JWT=$(curl -s -X POST "$SB/auth/v1/token?grant_type=password" -H "apikey: $PUB" \
  -H "Content-Type: application/json" -d '{"email":"ckankeu2@gmail.com","password":"<OWNER_PASSWORD>"}' \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")
echo "jwt=${OWNER_JWT:0:16}…"            # must be non-empty
CRON_SECRET='<the value you set in Vercel>'
```

Fixed ids: doc `dddddddd-0000-0000-0000-00000000d0c1`, rejected-claim `cccccccc-0000-0000-0000-0000000000c1`.

---

## Reset (clean any prior run) + Setup (seed object)

> NOTE: `storage.objects` rows can NOT be SQL-deleted — the `storage.protect_delete()` trigger blocks it (use the
> Storage API). This is by design (it's why byte purge goes through the api, not SQL). So the reset does NOT touch
> `storage.objects`; the seed `INSERT … ON CONFLICT DO NOTHING` is idempotent, so a leftover object row is harmless.

```sql
delete from public.claim_packets where id='cccccccc-0000-0000-0000-0000000000c1';
delete from public.storage_deletion_outbox where object_path like '%dddddddd-0000-0000-0000-00000000d0c1%';
delete from public.legal_holds where doc_id='dddddddd-0000-0000-0000-00000000d0c1';
delete from public.documents where id='dddddddd-0000-0000-0000-00000000d0c1';

-- Seed the metadata-only object row (INSERT is allowed; DELETE is not). Idempotent.
insert into storage.objects (bucket_id, name, owner, metadata) values
 ('documents','estates/9add2645-b3ef-4c25-b315-63900833ba5a/vault/dddddddd-0000-0000-0000-00000000d0c1.pdf',
  '77ef850e-6e12-449b-816e-d51f35332298', jsonb_build_object('size',12345,'mimetype','application/pdf'))
on conflict do nothing;
```

## Leg 1 — CREATE   ·   Leg 2 — REPLACE   (already green — re-run to restore state)

```sql
-- CREATE
do $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub','77ef850e-6e12-449b-816e-d51f35332298','role','authenticated')::text, true);
  perform public.create_vault_document('9add2645-b3ef-4c25-b315-63900833ba5a'::uuid,
    'dddddddd-0000-0000-0000-00000000d0c1'::uuid,
    'estates/9add2645-b3ef-4c25-b315-63900833ba5a/vault/dddddddd-0000-0000-0000-00000000d0c1.pdf',
    'Proof Doc','will','sealed');
end $$;

-- REPLACE (seed a distinct -v2 object first)
insert into storage.objects (bucket_id, name, owner, metadata) values
 ('documents','estates/9add2645-b3ef-4c25-b315-63900833ba5a/vault/dddddddd-0000-0000-0000-00000000d0c1-v2.pdf',
  '77ef850e-6e12-449b-816e-d51f35332298', jsonb_build_object('size',22222,'mimetype','application/pdf'))
on conflict do nothing;
do $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub','77ef850e-6e12-449b-816e-d51f35332298','role','authenticated')::text, true);
  perform public.replace_vault_document('dddddddd-0000-0000-0000-00000000d0c1'::uuid,
    'estates/9add2645-b3ef-4c25-b315-63900833ba5a/vault/dddddddd-0000-0000-0000-00000000d0c1-v2.pdf');
end $$;
```

## Leg 7 — ACTIVE-CLAIM REJECTION (non-destructive: repoint the EXISTING active claim, then restore)

The estate already has exactly one active claim (one-active-per-estate). Temporarily repoint its `executor_id_doc_id`
at our doc to prove the block, then restore — all in ONE block so the restore always lands.

```sql
do $$
declare v_claim uuid; v_orig uuid;
begin
  select id, executor_id_doc_id into v_claim, v_orig
    from public.claim_packets
   where estate_id='9add2645-b3ef-4c25-b315-63900833ba5a' and status <> 'rejected' limit 1;
  if v_claim is null then raise notice 'NO active claim in estate — skip (or insert a submitted one)'; return; end if;

  update public.claim_packets set executor_id_doc_id='dddddddd-0000-0000-0000-00000000d0c1' where id=v_claim;

  perform set_config('request.jwt.claims',
    json_build_object('sub','77ef850e-6e12-449b-816e-d51f35332298','role','authenticated')::text, true);
  begin
    perform public.delete_vault_document('dddddddd-0000-0000-0000-00000000d0c1'::uuid);
    raise notice 'FAIL: expected block';
  exception when others then raise notice 'blocked as expected: %', sqlerrm;   -- EXPECT: blocked_active_claim
  end;

  update public.claim_packets set executor_id_doc_id=v_orig where id=v_claim;   -- restore
end $$;
```

## Leg 4 — BLOCKED-DELETE (legal hold, then retention)

```sql
-- 4a. LEGAL HOLD (admin-gated; crafted admin claims w/ aal2 + fresh iat). Place -> delete blocked -> release.
do $$
declare v_hold uuid;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub','16db5021-4870-4d66-9d71-0b73d72363d0','role','authenticated',
                      'aal','aal2','iat',extract(epoch from now())::bigint)::text, true);
  v_hold := public.place_legal_hold('dddddddd-0000-0000-0000-00000000d0c1'::uuid,'litigation X');
  raise notice 'placed hold %', v_hold;
end $$;

do $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub','77ef850e-6e12-449b-816e-d51f35332298','role','authenticated')::text, true);
  begin
    perform public.delete_vault_document('dddddddd-0000-0000-0000-00000000d0c1'::uuid);
    raise notice 'FAIL: expected block';
  exception when others then raise notice 'blocked: %', sqlerrm;                -- EXPECT: blocked_legal_hold
  end;
end $$;

do $$
declare v_hold uuid;
begin
  select id into v_hold from public.legal_holds
   where doc_id='dddddddd-0000-0000-0000-00000000d0c1' and released_at is null limit 1;
  perform set_config('request.jwt.claims',
    json_build_object('sub','16db5021-4870-4d66-9d71-0b73d72363d0','role','authenticated',
                      'aal','aal2','iat',extract(epoch from now())::bigint)::text, true);
  perform public.release_legal_hold(v_hold);
end $$;

-- 4b. RETENTION
update public.documents set retention_until = now() + interval '1 year'
 where id='dddddddd-0000-0000-0000-00000000d0c1';
do $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub','77ef850e-6e12-449b-816e-d51f35332298','role','authenticated')::text, true);
  begin
    perform public.delete_vault_document('dddddddd-0000-0000-0000-00000000d0c1'::uuid);
    raise notice 'FAIL: expected block';
  exception when others then raise notice 'blocked: %', sqlerrm;                -- EXPECT: blocked_retention
  end;
end $$;
update public.documents set retention_until = null where id='dddddddd-0000-0000-0000-00000000d0c1';
```

## Leg 6 setup — insert a REJECTED claim pinning the doc (rejected does NOT conflict with the active one)

```sql
insert into public.claim_packets (id, estate_id, requested_by, status, death_certificate_doc_id)
values ('cccccccc-0000-0000-0000-0000000000c1','9add2645-b3ef-4c25-b315-63900833ba5a',
        '77ef850e-6e12-449b-816e-d51f35332298','rejected','dddddddd-0000-0000-0000-00000000d0c1');
```

## Leg 3 + 6 — DELETE succeeds (rejected claim doesn't block), row gone, tombstone, claim doc_id SET NULL

```sql
do $$
declare v_outbox uuid;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub','77ef850e-6e12-449b-816e-d51f35332298','role','authenticated')::text, true);
  v_outbox := public.delete_vault_document('dddddddd-0000-0000-0000-00000000d0c1'::uuid);
  raise notice 'deleted, outbox %', v_outbox;
end $$;
-- EXPECT:
select count(*) from public.documents where id='dddddddd-0000-0000-0000-00000000d0c1';          -- 0
select status, death_certificate_doc_id from public.claim_packets
 where id='cccccccc-0000-0000-0000-0000000000c1';                          -- rejected, doc_id NULL (SET NULL fired)
select reason, status from public.storage_deletion_outbox
 where object_path like '%dddddddd-0000-0000-0000-00000000d0c1-v2.pdf';    -- document_deleted / pending
select metadata->>'severity' from public.audit_logs
 where target_id='dddddddd-0000-0000-0000-00000000d0c1' and action='document.deleted';           -- high
```

## Leg 5a — PURGE retry + idempotency (SQL; run each DO block WHOLE)

```sql
-- fail then succeed on the pending delete-outbox row
do $$
declare v_id uuid;
begin
  select id into v_id from public.storage_deletion_outbox
   where object_path like '%dddddddd-0000-0000-0000-00000000d0c1-v2.pdf' and status <> 'purged' limit 1;
  perform set_config('request.jwt.claims',
    json_build_object('sub','77ef850e-6e12-449b-816e-d51f35332298','role','authenticated')::text, true);
  perform * from public.authorize_purge(v_id);
  perform public.record_purge_result(v_id, false, 'simulated transient error');
  perform * from public.authorize_purge(v_id);
  perform public.record_purge_result(v_id, true, null);
  raise notice 'drained %', v_id;
end $$;
select status, attempts, purged_at, last_error from public.storage_deletion_outbox
 where object_path like '%dddddddd-0000-0000-0000-00000000d0c1-v2.pdf';    -- purged, attempts>=2, last_error NULL

-- idempotency: a purged row cannot re-authorize
do $$
declare v_id uuid;
begin
  select id into v_id from public.storage_deletion_outbox
   where object_path like '%dddddddd-0000-0000-0000-00000000d0c1-v2.pdf' limit 1;
  perform set_config('request.jwt.claims',
    json_build_object('sub','77ef850e-6e12-449b-816e-d51f35332298','role','authenticated')::text, true);
  begin
    perform * from public.authorize_purge(v_id);
    raise notice 'FAIL: purged row re-authorized';
  exception when others then raise notice 'idempotent: %', sqlerrm;         -- EXPECT: outbox_not_found_or_purged
  end;
end $$;
```

## Leg 5b — real byte purge via the endpoint (curl; needs OWNER_JWT + deployed api)

```bash
DOC=eeeeeeee-0000-0000-0000-00000000d0c2
P="estates/9add2645-b3ef-4c25-b315-63900833ba5a/vault/$DOC.pdf"
printf '%PDF-1.4 test' > /tmp/p.pdf
# upload real bytes (Supabase host):
curl -s -o /dev/null -w "upload=%{http_code}\n" -X POST "$SB/storage/v1/object/documents/$P" \
  -H "apikey: $PUB" -H "Authorization: Bearer $OWNER_JWT" -H "Content-Type: application/pdf" --data-binary @/tmp/p.pdf
# create + delete via rest/v1/rpc (Supabase host):
curl -s -X POST "$SB/rest/v1/rpc/create_vault_document" -H "apikey: $PUB" -H "Authorization: Bearer $OWNER_JWT" \
  -H "Content-Type: application/json" \
  -d "{\"p_estate\":\"9add2645-b3ef-4c25-b315-63900833ba5a\",\"p_doc_id\":\"$DOC\",\"p_storage_path\":\"$P\",\"p_title\":\"purge me\",\"p_doc_subtype\":\"will\",\"p_sensitivity\":\"sealed\"}"; echo
OUTBOX=$(curl -s -X POST "$SB/rest/v1/rpc/delete_vault_document" -H "apikey: $PUB" -H "Authorization: Bearer $OWNER_JWT" \
  -H "Content-Type: application/json" -d "{\"p_doc_id\":\"$DOC\"}" | tr -d '"'); echo "outbox=$OUTBOX"
# client-immediate purge (Vercel api host):
curl -s -X POST "$API/api/claims/purge_document" -H "apikey: $PUB" -H "Authorization: Bearer $OWNER_JWT" \
  -H "Content-Type: application/json" -d "{\"outboxId\":\"$OUTBOX\"}"; echo         # EXPECT {"purged":true}
# bytes gone (Supabase host):
curl -s -o /dev/null -w "download=%{http_code}\n" "$SB/storage/v1/object/documents/$P" \
  -H "apikey: $PUB" -H "Authorization: Bearer $OWNER_JWT"                            # 400/404
```

## Leg 5c — cron drain (curl; Vercel api host + CRON_SECRET)

```bash
curl -s "$API/api/claims/drain_purge_outbox" -H "Authorization: Bearer $CRON_SECRET"; echo   # {"drained":N,"purged":N,"failed":0}
curl -s -o /dev/null -w "no-secret=%{http_code}\n" "$API/api/claims/drain_purge_outbox"       # 401
```

## Leg 8 — ORPHAN-SWEEPER predicate unchanged (admin-gated; smoke)

```sql
do $$
declare r record; n int := 0;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub','16db5021-4870-4d66-9d71-0b73d72363d0','role','authenticated',
                      'aal','aal2','iat',extract(epoch from now())::bigint)::text, true);
  for r in select * from public.list_orphan_storage_objects(0, 100) loop n := n + 1; end loop;
  raise notice 'sweeper returns % candidate(s); predicate unchanged', n;
end $$;
-- CONFIRM: git diff shows migration 0034 / list_orphan_storage_objects UNCHANGED.
```

## Cleanup

```sql
delete from public.claim_packets where id='cccccccc-0000-0000-0000-0000000000c1';
delete from public.storage_deletion_outbox where object_path like '%dddddddd-0000-0000-0000-00000000d0c1%';
delete from public.legal_holds where doc_id='dddddddd-0000-0000-0000-00000000d0c1';
delete from public.documents where id='dddddddd-0000-0000-0000-00000000d0c1';
-- storage.objects rows can't be SQL-deleted (protect_delete). The dddddddd metadata-only rows are harmless to
-- leave; to remove them use the Storage API, e.g.:
--   curl -s -X DELETE "$SB/storage/v1/object/documents/estates/9add2645-…/vault/dddddddd-…d0c1.pdf" \
--     -H "apikey: $PUB" -H "Authorization: Bearer $OWNER_JWT"
-- (Leg 5b's eeeeeeee doc/object were already deleted + purged by the flow.)
```

## Pass criteria
1. CREATE ✓ · 2. REPLACE ✓ · 3. DELETE (hard, tombstone high-sev) ✓ · 4. blocked_legal_hold + blocked_retention ✓ ·
5. purge retry→purged + idempotent + real byte removal + cron ✓ · 6. rejected-claim delete succeeds, doc_id nulled,
row persists ✓ · 7. blocked_active_claim ✓ · 8. sweeper predicate unchanged ✓.
