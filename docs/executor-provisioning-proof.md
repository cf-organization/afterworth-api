# Executor-provisioning — proof matrix (both doors)

Migration `0021_20260715_executor_provisioning` lets someone **become** an executor/trustee:
`create_invitation` accepts `kind=executor|trustee` (0016 guard lifted) and derives the GENERIC
`proposed_role='beneficiary'`; on accept **both** `accept_invitation` and `bind_invitation_token`
delegate to the shared `provision_from_invitation` helper, which reconciles the membership,
runs the beneficiary self-link, and stamps an `estate_designations` row — the **sole** source of
fiduciary truth. Executor authority is **never** inferred from the membership role.

This is the atomic fiduciary-state transaction, so it's proven **both doors**: a deterministic
SQL crafted-claims matrix (authoritative correctness) and the live PostgREST surface (grants +
enforcement). Verified **2026-07-15** on the live test estate `9add2645`.

## Prereqs

- Re-apply `db/migrations/0021_...sql` first (all idempotent `CREATE OR REPLACE`).
- Fixtures (see the test-estate reference): estate `9add2645-…`, owner `77ef850e-…`,
  exec `cb5edecc-…` (**already a beneficiary member** — exercises the reconcile branch),
  non-designee `fb97e207-…`.

## Door 1 — SQL crafted-claims matrix (authoritative correctness)

One self-cleaning transaction. `set_config('request.jwt.claims', …, true)` sets the caller
identity that `auth.uid()` reads (transaction-local — the SECURITY DEFINER RPCs read it for their
own gates even though the editor role is `postgres`). It creates its own invitations/designation/
instruction, asserts, and deletes everything it made; exec's pre-existing seed membership is never
touched. The full script:

```sql
create temp table if not exists _sr_verify(
  seq int, leg text, expect text, got text, pass boolean, note text
);
truncate _sr_verify;

do $$
declare
  c_estate uuid := '9add2645-b3ef-4c25-b315-63900833ba5a';
  c_owner  uuid := '77ef850e-6e12-449b-816e-d51f35332298';
  c_exec   uuid := 'cb5edecc-b7b7-468a-ad4f-c378b43095c9';   -- already a beneficiary member -> RECONCILE branch
  c_other  uuid := 'fb97e207-39d4-4411-8987-fbd7a0d2fb2e';   -- non-designee
  v_exec_email text; v_role text; v_mem uuid;
  v_inv_exec uuid; v_tok_exec text; v_inv_d uuid;
  v_inv_ben uuid; v_tok_ben text; v_inv_execb uuid; v_tok_execb text;
  v_instr uuid; v_grant boolean;
  v_desig_active int; v_mem_cnt int; v_ok boolean;
  v_pred boolean; v_desig_total_before int; v_desig_total_after int; v_audit int; v_desig_active_after int;
  s int := 0;
begin
  select email into v_exec_email from public.profiles where id = c_exec;
  delete from public.encrypted_instructions where estate_id = c_estate and title = '[SR-TEST] executor proof';

  -- BASELINE RESET (TEST estate/user ONLY): clear exec's executor/trustee designations for determinism.
  select count(*) into v_desig_active from public.estate_designations
    where estate_id=c_estate and user_id=c_exec and designation_type in ('executor','trustee');
  delete from public.estate_designations
    where estate_id=c_estate and user_id=c_exec and designation_type in ('executor','trustee');
  s:=s+1; insert into _sr_verify values(s,'P0 baseline reset (test estate/user)','clean start',
    v_desig_active::text||' prior designation(s) cleared', true,
    'deterministic baseline; TEST estate/user only — real executors go through the tested flow');

  -- LEG A — full executor loop via accept-by-id: mint (create-lift) -> accept -> BOTH rows
  perform set_config('request.jwt.claims', json_build_object('sub', c_owner, 'role','authenticated','aal','aal1')::text, true);
  select ci.invitation_id, ci.raw_token into v_inv_exec, v_tok_exec
    from public.create_invitation(c_estate,'executor','beneficiary', v_exec_email, null, false, false, 14) ci;
  s:=s+1; insert into _sr_verify values(s,'A0 create executor (0016 guard lifted)','minted',
    coalesce(v_inv_exec::text,'NULL'), v_inv_exec is not null, 'create_invitation accepted kind=executor');
  select proposed_role into v_role from public.invitations where id = v_inv_exec;
  s:=s+1; insert into _sr_verify values(s,'A0b proposed_role derived','beneficiary', v_role, v_role='beneficiary',
    'executor kind -> GENERIC access-class membership role');
  perform set_config('request.jwt.claims', json_build_object('sub', c_exec, 'role','authenticated','aal','aal1')::text, true);
  select ai.membership_id, ai.role into v_mem, v_role from public.accept_invitation(v_inv_exec) ai;
  s:=s+1; insert into _sr_verify values(s,'A1 membership reconciled','approved+beneficiary',
    'mem='||coalesce(v_mem::text,'NULL')||' role='||coalesce(v_role,'NULL'),
    v_mem is not null and v_role='beneficiary', 'reused pre-existing beneficiary membership (ON CONFLICT DO NOTHING)');
  select count(*) into v_desig_active from public.estate_designations
    where estate_id=c_estate and user_id=c_exec and designation_type='executor' and status='active';
  s:=s+1; insert into _sr_verify values(s,'A2 designation stamped','1 active executor', v_desig_active::text,
    v_desig_active=1, 'estate_designations = SOLE fiduciary truth');
  select public.is_estate_executor(c_estate, c_exec) into v_ok;
  s:=s+1; insert into _sr_verify values(s,'A3 is_estate_executor(exec)','true', v_ok::text, v_ok, 'canonical predicate true');
  s:=s+1; insert into _sr_verify values(s,'A4 membership role NOT executor','beneficiary', v_role, v_role='beneficiary',
    'CRITICAL INVARIANT: authority never inferred from membership role');

  -- LEG C — idempotency: double-accept (same user) -> graceful no-op (proves the accepted_by fix)
  begin
    perform public.accept_invitation(v_inv_exec);
    select count(*) into v_desig_active from public.estate_designations
      where estate_id=c_estate and user_id=c_exec and designation_type='executor' and status='active';
    select count(*) into v_mem_cnt from public.estate_memberships where estate_id=c_estate and user_id=c_exec;
    s:=s+1; insert into _sr_verify values(s,'C double-accept graceful','no raise; 1 desig,1 mem',
      'desig='||v_desig_active||' mem='||v_mem_cnt, v_desig_active=1 and v_mem_cnt=1,
      'self-heal keyed on invitations.accepted_by (NOT source_invitation_id)');
  exception when others then
    s:=s+1; insert into _sr_verify values(s,'C double-accept graceful','no raise',
      'RAISED '||sqlstate||': '||sqlerrm, false, 'REGRESSION: should be a graceful no-op');
  end;

  -- LEG B — encrypted_instructions invariant: released instr readable by executor; revoke kills read
  perform set_config('request.jwt.claims', json_build_object('sub', c_owner, 'role','authenticated','aal','aal1')::text, true);
  insert into public.encrypted_instructions
    (estate_id, owner_id, title, ciphertext, iv, wrapped_key, release_condition, released, released_at)
  values (c_estate, c_owner, '[SR-TEST] executor proof', '\x00'::bytea,'\x00'::bytea,'\x00'::bytea,'manual', true, now())
  returning id into v_instr;
  select has_table_privilege('authenticated','public.encrypted_instructions','select') into v_grant;
  s:=s+1; insert into _sr_verify values(s,'B0 client SELECT grant (fyi)', 'either', v_grant::text, true,
    case when v_grant then 'authenticated can hit the table; RLS predicate gates'
         else 'no client grant yet -> read path is a future RPC; the predicate below IS the gate' end);
  select (ei.released = true and public.is_estate_executor(c_estate, c_exec)) into v_pred
    from public.encrypted_instructions ei where ei.id = v_instr;
  s:=s+1; insert into _sr_verify values(s,'B1 executor CAN read released','true', v_pred::text, v_pred=true,
    'released instr + active designation -> RLS grants read');
  select (ei.released = true and public.is_estate_executor(c_estate, c_other)) into v_pred
    from public.encrypted_instructions ei where ei.id = v_instr;
  s:=s+1; insert into _sr_verify values(s,'B2 non-designee DENIED','false', v_pred::text, v_pred=false,
    'non-designee -> RLS denies even a released instr');
  update public.estate_designations set status='revoked', revoked_at=now()
    where estate_id=c_estate and user_id=c_exec and designation_type='executor' and status='active';
  select (ei.released = true and public.is_estate_executor(c_estate, c_exec)) into v_pred
    from public.encrypted_instructions ei where ei.id = v_instr;
  s:=s+1; insert into _sr_verify values(s,'B3 revoke KILLS read','false', v_pred::text, v_pred=false,
    'LOAD-BEARING: fiduciary access tracks the DESIGNATION, dies on revoke');
  select exists(select 1 from public.estate_memberships where estate_id=c_estate and user_id=c_exec) into v_ok;
  s:=s+1; insert into _sr_verify values(s,'B4 membership PERSISTS after revoke','true', v_ok::text, v_ok=true,
    'access-class membership survives; only fiduciary authority was revoked');

  -- LEG E — non-designee is not an executor
  select public.is_estate_executor(c_estate, c_other) into v_ok;
  s:=s+1; insert into _sr_verify values(s,'E is_estate_executor(non-designee)','false', v_ok::text, v_ok=false, '');

  -- LEG D — identity guard: a contact-mismatched caller cannot accept an executor invitation
  perform set_config('request.jwt.claims', json_build_object('sub', c_owner, 'role','authenticated','aal','aal1')::text, true);
  select ci.invitation_id into v_inv_d
    from public.create_invitation(c_estate,'executor','beneficiary', v_exec_email, null, false, false, 14) ci;
  perform set_config('request.jwt.claims', json_build_object('sub', c_other, 'role','authenticated','aal','aal1')::text, true);
  begin
    perform public.accept_invitation(v_inv_d);
    s:=s+1; insert into _sr_verify values(s,'D P0006 on contact mismatch','P0006','no exception', false,
      'SECURITY: mismatched accept must be rejected');
  exception
    when sqlstate 'P0006' then
      s:=s+1; insert into _sr_verify values(s,'D P0006 on contact mismatch','P0006','P0006', true,
        'identity guard rejects a non-invitee (no designation minted)');
    when others then
      s:=s+1; insert into _sr_verify values(s,'D P0006 on contact mismatch','P0006', sqlstate, false, sqlerrm);
  end;

  -- REGRESSION R1 — beneficiary BIND unchanged: membership approved+beneficiary, NO designation, bound audit
  perform set_config('request.jwt.claims', json_build_object('sub', c_owner, 'role','authenticated','aal','aal1')::text, true);
  select ci.invitation_id, ci.raw_token into v_inv_ben, v_tok_ben
    from public.create_invitation(c_estate,'beneficiary','beneficiary', v_exec_email, null, false, false, 14) ci;
  select count(*) into v_desig_total_before from public.estate_designations where estate_id=c_estate and user_id=c_exec;
  perform set_config('request.jwt.claims', json_build_object('sub', c_exec, 'role','authenticated','aal','aal1')::text, true);
  select bt.membership_id, bt.role into v_mem, v_role from public.bind_invitation_token(v_tok_ben) bt;
  s:=s+1; insert into _sr_verify values(s,'R1a beneficiary bind membership','approved+beneficiary',
    'mem='||coalesce(v_mem::text,'NULL')||' role='||coalesce(v_role,'NULL'),
    v_mem is not null and v_role='beneficiary', 'bind beneficiary path unchanged');
  select count(*) into v_desig_total_after from public.estate_designations where estate_id=c_estate and user_id=c_exec;
  s:=s+1; insert into _sr_verify values(s,'R1b beneficiary bind -> NO designation','delta 0',
    'delta='||(v_desig_total_after - v_desig_total_before), v_desig_total_after = v_desig_total_before,
    'kind=beneficiary never touches estate_designations');
  select count(*) into v_audit from public.audit_logs
    where estate_id=c_estate and action='invitation.bound' and (metadata->>'invitation_id')=v_inv_ben::text;
  s:=s+1; insert into _sr_verify values(s,'R1c invitation.bound audit','1', v_audit::text, v_audit=1, 'audit unchanged on bind');

  -- REGRESSION R2 — executor via BIND (asymmetry fix, end-to-end): designation stamped on token path
  perform set_config('request.jwt.claims', json_build_object('sub', c_owner, 'role','authenticated','aal','aal1')::text, true);
  select ci.invitation_id, ci.raw_token into v_inv_execb, v_tok_execb
    from public.create_invitation(c_estate,'executor','beneficiary', v_exec_email, null, false, false, 14) ci;
  perform set_config('request.jwt.claims', json_build_object('sub', c_exec, 'role','authenticated','aal','aal1')::text, true);
  perform public.bind_invitation_token(v_tok_execb);
  select count(*) into v_desig_active_after from public.estate_designations
    where estate_id=c_estate and user_id=c_exec and designation_type='executor' and status='active';
  select public.is_estate_executor(c_estate, c_exec) into v_ok;
  s:=s+1; insert into _sr_verify values(s,'R2 executor via BIND (asymmetry fix)','1 active + executor=true',
    'active='||v_desig_active_after||' is_exec='||v_ok, v_desig_active_after=1 and v_ok=true,
    'bind provisions executors too (designation on the token path)');

  -- CLEANUP — delete everything THIS script created; leave exec seed membership untouched.
  delete from public.audit_logs a
    where a.estate_id=c_estate and (a.metadata->>'invitation_id') in
      (v_inv_exec::text, v_inv_d::text, v_inv_ben::text, v_inv_execb::text);
  delete from public.estate_designations
    where estate_id=c_estate and user_id=c_exec and designation_type in ('executor','trustee');
  delete from public.estate_memberships
    where estate_id=c_estate and source_invitation_id in (v_inv_exec, v_inv_ben, v_inv_execb);
  delete from public.encrypted_instructions where id = v_instr;
  delete from public.invitations where id in (v_inv_exec, v_inv_d, v_inv_ben, v_inv_execb);
  perform set_config('request.jwt.claims', '', true);
end $$;

select seq, leg, expect, got, pass, note from _sr_verify order by seq;
```

### Captured verdicts — 19/19 pass (2026-07-15)

| seq | leg | got | pass |
|----|-----|-----|:----:|
| 1 | P0 baseline reset (test estate/user) | 0 prior designation(s) cleared | ✅ |
| 2 | A0 create executor (0016 guard lifted) | minted `d009afef-…` | ✅ |
| 3 | A0b proposed_role derived | `beneficiary` | ✅ |
| 4 | A1 membership reconciled | `mem=5f95358e-… role=beneficiary` | ✅ |
| 5 | A2 designation stamped | `1` active executor | ✅ |
| 6 | A3 is_estate_executor(exec) | `true` | ✅ |
| 7 | A4 membership role NOT executor | `beneficiary` | ✅ |
| 8 | C double-accept graceful | `desig=1 mem=1` (no raise) | ✅ |
| 9 | B0 client SELECT grant (fyi) | `false` — no client grant yet | ✅ |
| 10 | B1 executor CAN read released | `true` | ✅ |
| 11 | B2 non-designee DENIED | `false` | ✅ |
| 12 | **B3 revoke KILLS read** | `false` | ✅ |
| 13 | **B4 membership PERSISTS after revoke** | `true` | ✅ |
| 14 | E is_estate_executor(non-designee) | `false` | ✅ |
| 15 | D P0006 on contact mismatch | `P0006` | ✅ |
| 16 | R1a beneficiary bind membership | `mem=5f95358e-… role=beneficiary` | ✅ |
| 17 | R1b beneficiary bind → NO designation | `delta=0` | ✅ |
| 18 | R1c invitation.bound audit | `1` | ✅ |
| 19 | R2 executor via BIND (asymmetry fix) | `active=1 is_exec=true` | ✅ |

The load-bearing pair is **B3 + B4**: revoking the designation kills the executor's read of a
released instruction **while the access-class membership persists** — fiduciary authority tracks the
DESIGNATION, never the membership role.

## Door 2 — live PostgREST (grants + enforcement)

Client-reachable RPCs bypass any Vercel layer, so the gate must hold on the raw `rest/v1/rpc/…`
door. Verified with the publishable (anon) key — no user JWT needed for the security-critical axes.

**Grant catalog** (`has_function_privilege`, 2026-07-15):

| function | authenticated | anon |
|----------|:---:|:---:|
| `provision_from_invitation` (INTERNAL helper) | **false** | **false** |
| `create_invitation` | true | — |
| `accept_invitation` | true | — |
| `bind_invitation_token` | true | — |
| `is_estate_executor` | true | — |

**Live-door enforcement** (anon key):

```
POST /rest/v1/rpc/provision_from_invitation  -> 401 {"code":"42501","message":"permission denied for function provision_from_invitation"}
POST /rest/v1/rpc/create_invitation          -> 401 {"code":"42501","message":"permission denied for function create_invitation"}
```

The INTERNAL helper is unreachable and `create_invitation` is gated to `authenticated` on the real
door — the endpoint in front buys nothing extra; the grant IS the gate.

### Deferred — authenticated-JWT gate run

The full real-JWT curl (`scratchpad/executor_proof_both_doors.sh`: owner mints → wrong-person accept
→ P0006, right-person accept → provisions) is **deferred**: the test-account passwords weren't on
hand at proof time. It's not load-bearing — the SQL matrix already exercised those exact gates
deterministically (**D** = P0006 identity guard, **A0** = the owner path via `create_invitation`).
To run it later, set a known test password (`update auth.users set encrypted_password =
crypt('…', gen_salt('bf')) where email in (…)`), export `PW_OWNER/PW_EXEC/PW_OTHER`, and run the `.sh`.

## Notes

- **`encrypted_instructions` has no client GRANT yet** (B0=`false`) — the read path is a future
  SECURITY DEFINER RPC, so the invariant is proven at the **RLS predicate level**
  (`released = true AND is_estate_executor(estate, uid)`), which is exactly what the policy gates on.
  When a client read path lands, re-prove B1/B3 as a role-switched table read.
- **`invitation_write_gate`** (called by `create_invitation`) is still **live-only, not in VC** —
  capture it (`pg_get_functiondef`) into `db/functions/` as a follow-up (same live-only-object class
  as `handle_new_user` / `is_estate_owner`).
- **Key finding fixed during this proof**: the idempotency self-heal was keyed on the membership's
  `source_invitation_id`, which never matches for a reconciled membership (an executor who is already
  a beneficiary) — so a same-user double-accept spuriously `P0005`'d and a missing designation could
  never self-heal. Re-keyed on `invitations.accepted_by`; leg **C** proves it.
