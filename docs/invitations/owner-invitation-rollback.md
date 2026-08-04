# Migration 0042 — rollback

The migration is a single transaction, so a **failed** apply needs no rollback: nothing committed.

This procedure is for reverting a **successful** apply.

## Safety

0042 is purely additive. Reverting it removes the owner surface but **cannot break the recipient
flow or the operator console** — neither was modified.

## Order matters

```sql
begin;

-- 1 · consumer functions
drop function if exists public.request_invitation_redelivery(uuid, uuid);
drop function if exists public.extend_estate_invitation(uuid, uuid, int);
drop function if exists public.revoke_estate_invitation(uuid, uuid);
drop function if exists public.create_estate_invitation(uuid, text, text, text, boolean, boolean, int);
drop function if exists public.list_estate_invitations(uuid, int);

-- 2 · trusted worker surface
drop function if exists public.record_invitation_delivery_failure(uuid, text);
drop function if exists public.issue_invitation_delivery(uuid);

-- 3 · shared helpers
drop function if exists public.estate_owner_gate(uuid);
drop function if exists public.invitation_effective_status(text, timestamptz);

-- 4 · outbox (drops any queued deliveries with it)
drop table if exists public.invitation_delivery_outbox;

-- 5 · uniqueness
drop index if exists public.invitations_one_active_per_recipient_role;
drop index if exists public.invitations_one_active_per_phone_role;

commit;
```

## ★ Columns are deliberately NOT dropped

`declined_at`, `revoked_at`, `revoked_by`, `extended_at`, `extended_by` are left in place. They are
nullable and additive, nothing depends on their absence, and dropping them would **destroy audit
history** for any invitation revoked or extended while 0042 was live. Drop them only with a
deliberate decision and a backup.

## After rollback

- Recipient accept/decline: unaffected.
- Operator console `create_invitation` / `revoke_invitation` / `extend_invitation`: unaffected.
- Any invitation created through `create_estate_invitation` whose token was never issued becomes
  permanently unusable — which it already was. **Revoke such rows** rather than leaving them to
  occupy the 20-active cap:

```sql
-- non-production example; scope to the affected estate
update public.invitations set status = 'revoked', updated_at = now()
 where estate_id = :estate_id and status = 'pending'
   and id not in (select invitation_id from public.invitation_delivery_outbox where status = 'issued');
```
