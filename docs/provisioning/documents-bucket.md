# Standing up a new project: the two things SQL cannot do for you

A project built from `db/bootstrap` + `db/migrations/0061+` has a complete **schema**. It is not yet
able to accept a document upload, and both reasons are outside SQL's reach.

Observed on the nonprod project between 2026-09-24 and 2026-09-30: document upload and claims
evidence were dead on **both** mobile platforms, and the cause was never code.

---

## 1 · The `documents` storage bucket — platform-owned, dashboard-created

`storage.buckets` belongs to the Supabase platform. `00_platform_contract.sql` only *asserts* the
table exists, and `110_storage_policies.sql` creates the application's two policies **on**
`storage.objects` while stating plainly that the table is not created there. Nothing in `db/` inserts
a bucket, and migration `0030`'s own header records bucket creation as a manual prerequisite.

**A bootstrapped project is therefore born with no bucket at all.** Confirmed on nonprod on
2026-09-30: the Storage dashboard listed zero buckets.

Create it before the project is considered stood up:

```
name                  documents
public                NO  — reads must go through RLS on storage.objects
file size limit       25 MB   (26214400 bytes)
allowed MIME types    application/pdf, image/jpeg, image/png, image/heic
```

Also check the **project-wide** upload limit is at least 25 MB. It is a separate setting and the lower
of the two wins, so a project-wide 5 MB silently caps a 25 MB bucket.

### Verifying it — service role only

`storage.buckets` is not readable by `authenticated`, so this belongs in provisioning tooling rather
than in a migration:

```sql
do $$
declare b record;
begin
  select * into b from storage.buckets where id = 'documents';
  if not found then
    raise exception 'provisioning incomplete: the documents bucket does not exist';
  end if;
  if b.public then
    raise exception 'documents bucket is PUBLIC — reads must go through RLS';
  end if;
  if coalesce(b.file_size_limit, 0) <> 25 * 1024 * 1024 then
    raise exception 'documents bucket file_size_limit is %, expected 26214400', b.file_size_limit;
  end if;
end $$;
```

Mutation-prove it like anything else: create the bucket, confirm the check passes, flip `public` to
true and confirm it raises. A check that has never failed has not been verified.

---

## 2 · The `upload_policy` singleton — fixed, in migration 0065

This one **is** SQL's to do, and it now happens automatically:
`db/migrations/0065_20261001_upload_policy_seed.sql`.

The bootstrap creates the table, its primary key, RLS and the grants on `get_upload_policy()` — and
never inserts the `id = 1` row, because the seeding `INSERT` lives in historical migration `0032`,
which a virgin bootstrap deliberately does not replay. The result:

- `get_upload_policy()` returns **zero rows** → the mobile Vault refuses every upload, because a
  client that fails closed will not invent a limit it was never told;
- `submit_claim_with_evidence` raises `upload_policy_missing` → claims evidence is dead too.

`node scripts/verifyUploadPolicySeed.mjs` proves the whole thing against a throwaway container:
the defect reproduced on a fresh bootstrap, the seed fixing it, the **routine** answering (not just
the table), idempotence, an operator's tuned value surviving a re-run, and a mutation showing the
postcondition can fail.

### Two values, two places, still manual

Storage enforces the bucket's `file_size_limit` and MIME allowlist **independently** of
`public.upload_policy`. The numbers in 0065 mirror the bucket configuration above. **Changing a limit
means changing both** — there is no mechanism keeping them in step, and a mismatch shows up as an
upload the client happily starts and Storage rejects.

---

## Order

```
1  create the Supabase project
2  create the documents bucket (above) and check the project-wide limit
3  apply db/bootstrap/        (00 … 120, numeric order)
4  apply db/migrations/0061+  (includes 0065, which seeds the upload policy)
5  verify:  select count(*) from public.get_upload_policy();   -- must be 1
6  verify:  the bucket assertion above, as the service role
7  prove an actual upload from a device. Steps 5 and 6 passing is NOT that proof —
   a readable policy and a present bucket are prerequisites, not the journey.
```

Step 7 is deliberately last and deliberately separate. The nonprod outage was visible at step 5 and
invisible at every layer above it: the routine was deployed, owned, granted and callable the entire
time.
