#!/usr/bin/env node
/**
 * Security mutation harness for the SQL authorization suite.
 *
 * ★ WHY THIS EXISTS. `verifySqlAuthorization.mjs` reports "104 assertions passed". That sentence is
 * only worth anything if the assertions can FAIL. An authorization suite that cannot detect a
 * deleted authorization check is indistinguishable, from the outside, from one that checks nothing —
 * and this repository has shipped that exact failure more than once (a Dashboard audit with 63
 * assertions against an empty file list; a private-palette matcher that halved its own count).
 *
 * So each mutation below DELETES or WEAKENS one real authorization decision and requires the suite
 * to fail. `NOT_DETECTED` is the finding; a pass here is the harness reporting on itself.
 *
 * ★ IT NEVER WRITES TO YOUR CHECKOUT. Every mutation happens inside a throwaway `git worktree`
 * seeded from the current HEAD, for the reason recorded in the mobile repo's `scripts/mutate.js`:
 * cleanup discipline failed twice, once destroying uncommitted work via a file-level
 * `git checkout`, once stranding three mutated production files after a crash. The developer's
 * working tree is not the thing being mutated, so no crash can strand a mutation in it.
 *
 * ★ AND IT PROVES THE MUTATION ACTUALLY APPLIED. A replacement whose `from` string no longer matches
 * silently mutates nothing, and the suite then passes for the most misleading possible reason: the
 * code under test was never changed. Every mutation asserts the substitution occurred before the
 * suite runs, and a miss is `HARNESS_FAILURE`, never `DETECTED`.
 *
 * Usage:  node scripts/mutateSqlAuthorization.mjs [--only <id>]
 * Exit:   0 every mutation was detected · 1 a mutation survived · 2 the harness could not run
 */
import { execFileSync, spawnSync } from 'node:child_process';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SQL_BUNDLES, SQL_DIRECT_PARTS } from './lib/sqlSuiteParts.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const VERDICT = Object.freeze({
  DETECTED: 'DETECTED',
  NOT_DETECTED: 'NOT_DETECTED',
  HARNESS_FAILURE: 'HARNESS_FAILURE',
});

/**
 * One mutation = one file, one exact replacement, one expectation.
 *
 * `from` is matched EXACTLY and must occur exactly once. Requiring uniqueness is deliberate: a
 * `from` that matches twice would mutate an arbitrary one of them and the verdict would describe a
 * different edit than the one written here.
 */
const MUTATIONS = Object.freeze([
  {
    id: 'ownership-check-deleted',
    why: 'An owner must be refused the professional projection BY THE OWNERSHIP CHECK. The suite '
      + 'constructs the only data state where that check is load-bearing (an owner who also holds '
      + 'an approved professional_delegate row); without that case this mutation survives.',
    file: 'db/functions/professional_workspace_rpcs.sql',
    from: '  if public.is_estate_owner(p_estate) then',
    to: '  if false then',
  },
  {
    id: 'membership-status-ignored',
    why: 'A REVOKED delegate must lose the workspace. Dropping the status predicate makes any '
      + 'membership row — pending, revoked, expired — sufficient.',
    file: 'db/functions/professional_workspace_rpcs.sql',
    from: "     and m.status = 'approved'",
    to: "     and m.status is not null",
  },
  {
    id: 'role-filter-widened',
    why: 'Membership alone must not confer the workspace — a beneficiary holds a membership row too. '
      + 'Widening the role predicate is the single edit that turns delegation into membership.',
    file: 'db/functions/professional_workspace_rpcs.sql',
    from: "     and m.role = 'professional_delegate'",
    to: "     and m.role is not null",
  },

  /* ── PHASE 10-E · lifecycle notifications ──────────────────────────────────────────────────────
   * Eight mutations, one per way a notification can become a disclosure channel. Each is written as
   * the edit a well-meaning contributor would actually make — a widened predicate, a helpful detail
   * added to copy, a link where there was none — not as obvious sabotage. A mutation nobody would
   * plausibly write does not tell you anything about the tests.
   */
  {
    id: 'recipient-check-removed',
    why: 'The OWNER is notified of a new access request. Redirecting the recipient to the requester '
      + 'is the shape of "who should get this?" being answered by the wrong authority — and it must '
      + 'fail on BOTH halves: the owner stops receiving it and someone else starts.',
    file: 'db/functions/create_access_request.sql',
    from: '    public.estate_owner_user_id(p_estate_id),\n    p_estate_id,',
    to: '    v_user,\n    p_estate_id,',
  },
  {
    id: 'emit-before-state-transition',
    why: 'Emission must be DOWNSTREAM of the state change. Moved above the insert, a refused '
      + 'duplicate request still notifies the owner — the state never changed and the notification '
      + 'says it did. This is the mutation the one-pending index exists to make observable.',
    file: 'db/functions/create_access_request.sql',
    from: '  -- Insert. requester_user_id + requester_role STAMPED server-side (never params). The',
    to: '  perform public.emit_lifecycle_notification(\n'
      + '    public.estate_owner_user_id(p_estate_id), p_estate_id, \'access_request.created\',\n'
      + "    'afterworth://owner-review');\n"
      + '  -- Insert. requester_user_id + requester_role STAMPED server-side (never params). The',
  },
  {
    id: 'hidden-detail-in-copy',
    why: 'The revoke copy must name nothing. Appending the document title is the single most '
      + 'natural "helpful" edit anyone would make here, and it re-discloses a title the person has '
      + 'just lost the right to see, in a row that outlives the grant.',
    file: 'db/functions/lifecycle_notification_rpcs.sql',
    from: "     'Your access to shared estate information has changed.'),",
    to: "     'Your access to Fixture statement has changed.'),",
  },
  {
    id: 'hidden-count-in-copy',
    why: 'A count leaks inventory shape even when every item stays hidden. "3 new items" is exactly '
      + 'the disclosure the whole discovery ladder exists to prevent.',
    file: 'db/functions/lifecycle_notification_rpcs.sql',
    from: "     'You have access to shared estate information.'),",
    to: "     'You have access to 3 shared estate items.'),",
  },
  {
    id: 'death-firewall-disabled',
    why: 'A death-conditioned grant must stay dormant and silent. Accepting every release condition '
      + 'turns grant creation into the release announcement Phase 11 has not built. Re-anchored in '
      + '11-B: the inline rule became a delegation, so the modern form of this edit is widening the '
      + 'delegation — "active is enough" — rather than widening a literal list.',
    file: 'db/functions/lifecycle_notification_rpcs.sql',
    from: "  select p_status = 'active'\n     and public.release_condition_satisfied(p_release_condition, p_approved_at, 'standard', 'active');",
    to: "  select p_status = 'active'\n     and (p_release_condition is not null\n          or public.release_condition_satisfied(p_release_condition, p_approved_at, 'standard', 'active'));",
  },
  {
    id: 'revoke-link-restored',
    why: 'A revoke notification must not offer a way back in. A deep link here cannot lead anywhere '
      + 'but a refusal, and it invites the reader to believe the access is still there.',
    file: 'db/functions/revoke_document_grant.sql',
    from: "    'access_grant.revoked',\n    null   -- nothing to open; a link here would lead to a refusal",
    to: "    'access_grant.revoked',\n    public.notification_estate_home(v_estate, (select g.grantee_user_id from public.access_grants g where g.id = p_grant_id))",
  },
  {
    id: 'forgery-lock-removed',
    why: 'THE HOLE THIS PHASE FOUND. Restoring EXECUTE to `authenticated` lets any signed-in user '
      + 'plant an arbitrary notification, with an arbitrary deep link, in ANY other user inbox.',
    file: 'db/migrations/0050_20260811_lifecycle_notifications.sql',
    from: 'revoke execute on function public.emit_notification(uuid, uuid, text, text, text, text, jsonb) from authenticated;',
    to: 'grant execute on function public.emit_notification(uuid, uuid, text, text, text, text, jsonb) to authenticated;',
  },
  {
    id: 'invitation-emit-above-idempotency-guard',
    why: 'decline_invitation treats an already-declined invitation as a successful NO-OP. An emitter '
      + 'placed above that guard notifies the owner on every repeat CALL rather than once per EVENT, '
      + 'and nothing else in the system would notice. This is the mutation that justifies modelling '
      + 'the invitations table in the harness at all.',
    file: 'db/functions/decline_invitation.sql',
    from: '  -- Idempotent: already declined is a successful no-op.',
    to: "  perform public.emit_lifecycle_notification(\n"
      + "    public.estate_owner_user_id(v_inv.estate_id), v_inv.estate_id, 'invitation.declined', null);\n"
      + '  -- Idempotent: already declined is a successful no-op.',
  },
  {
    id: 'cross-estate-recipient',
    why: 'Recipient resolution must be scoped to the estate the event happened on. Dropping the '
      + 'estate predicate makes the "owner" an arbitrary owner, which is a cross-estate leak that '
      + 'reads like a harmless simplification.',
    file: 'db/functions/lifecycle_notification_rpcs.sql',
    from: '  select owner_id from public.estates where id = p_estate_id;',
    to: '  select owner_id from public.estates order by id limit 1;',
  },

  /* ── PHASE 10-F · the composed system ─────────────────────────────────────────────────────────
   * These aim at the exit matrix rather than at any single feature. Each is an edit that leaves
   * every FEATURE suite green — which is precisely why the composed suite had to exist.
   */
  {
    id: 'aggregate-leaks-exact-value',
    why: 'THE DEFECT 10-A ACTUALLY SHIPPED. Collapsing the bracket so low = high republishes the '
      + 'exact category total under a different field name. Every field is still correctly nulled; '
      + 'the value is disclosed anyway.',
    file: 'db/functions/list_estate_assets.sql',
    from: '    when p < 1000000    then 1000000       when p < 5000000    then 5000000',
    to: '    when p < 1000000    then p              when p < 5000000    then p',
  },
  {
    id: 'withheld-count-revealed',
    why: 'At range_only a viewer receives category NAMES and nothing quantitative. Publishing '
      + 'item_count at that tier hands them the inventory shape they were rationed out of.',
    file: 'db/functions/estate_discovery_rpcs.sql',
    from: "             'item_count',   case when v_tier = 'range_only' then null else count(*) end,",
    to: "             'item_count',   count(*),",
  },
  {
    id: 'archived-assets-rejoin-aggregates',
    why: 'An archived asset is withdrawn material. Dropping the archived filter puts it back into '
      + 'every count and bracket, so deleting something becomes observable to anyone with a tier.',
    file: 'db/functions/estate_discovery_rpcs.sql',
    from: '       and a.archived_at is null\n     group by a.category',
    to: '       and (a.archived_at is null or true)\n     group by a.category',
  },
  {
    id: 'refusal-shape-differs-by-cause',
    why: 'A refusal that names its cause is an oracle: "not a member" versus "no such estate" '
      + 'confirms the estate exists. The composed matrix compares four causes byte for byte.',
    file: 'db/functions/estate_discovery_rpcs.sql',
    from: "  if not v_is_owner and not v_member and v_tier = 'hidden' then\n    return jsonb_build_object('authorized', false);",
    to: "  if not v_is_owner and not v_member and v_tier = 'hidden' then\n    return jsonb_build_object('authorized', false, 'reason', case when v_member then 'no_grant' else 'not_a_member' end);",
  },
  {
    id: 'denial-revokes-prior-grant',
    why: 'THE FIXTURE INVARIANT PHASE 10-E LEFT BEHIND. Denying a LATER access request must not '
      + 'touch an EARLIER grant. Revoking here would silently strip access the owner never withdrew.',
    file: 'db/functions/deny_access_request.sql',
    from: "  update public.access_requests\n     set status = 'denied',",
    to: "  update public.access_grants set status = 'revoked' where estate_id = v_estate and grantee_user_id = v_requester;\n  update public.access_requests\n     set status = 'denied',",
  },
  {
    id: 'readiness-leaks-into-discovery',
    why: 'Readiness is an owner-only judgement. Surfacing its finding count in the discovery '
      + 'payload would tell every tiered viewer how incomplete the estate is.',
    file: 'db/functions/estate_discovery_rpcs.sql',
    from: "      'release_state', public.estate_release_state(p_estate),\n      'document_count', v_docs",
    to: "      'release_state', public.estate_release_state(p_estate),\n      'finding_count', (select count(*) from public.documents d2 where d2.estate_id = p_estate),\n      'document_count', v_docs",
  },
  {
    id: 'drift-reconciler-goes-blind',
    target: 'scripts/verifySourceDeploymentDrift.mjs',
    why: 'THE RECONCILER MUST DETECT DEPLOYMENT-AHEAD-OF-SOURCE. Narrowing the source ceiling so it '
      + 'refuses a category production still grants is exactly the create_asset_grant near-miss, and '
      + 'the reconciler exists to make that loud instead of silent.',
    file: 'db/migrations/0049_20260811_estate_discovery.sql',
    from: "    when p_category in ('account_balances', 'total_asset_value', 'estate_inventory') then",
    to: "    when p_category in ('account_balances', 'total_asset_value') then",
  },

  /* ── PHASE 11-A · firewall tripwires ──────────────────────────────────────────────────────────
   * These do not test the product. They test whether `test/phase11Firewall.test.ts` would NOTICE
   * the three ways Phase 11 could cross the boundary by accident. A tripwire nobody has tripped is
   * indistinguishable from a wire that is not connected.
   */
  {
    id: 'p11-release-seam-consulted',
    target: 'npx',
    why: 'The release seam is REPORTED, never CONSULTED. Wiring estate_release_state into a '
      + 'disclosure decision is the single most likely way Phase 11 crosses the boundary early.',
    file: 'db/functions/estate_discovery_rpcs.sql',
    from: "  if v_tier = 'hidden' then",
    to: "  if public.estate_release_state(p_estate) = 'released' then v_tier := 'full_detail'; end if;\n  if v_tier = 'hidden' then",
  },
  {
    id: 'p11-death-condition-admitted',
    target: 'npx',
    why: 'Death-conditioned grants are dormant at every evaluation site. Admitting one at a single '
      + 'site is exactly the partial wiring the duplicated rule invites. Re-anchored in 11-B: the '
      + 'site no longer spells the rule out, so the mutation is now the local RE-INTRODUCTION of a '
      + 'release comparison beside the canonical call — which is the same accident, and the form it '
      + 'will actually take now that a predicate exists to bypass.',
    file: 'db/functions/estate_discovery_rpcs.sql',
    from: "  if not public.release_condition_satisfied(v_cond, v_approved, 'standard',\n                                            public.estate_lifecycle_state(p_estate)) then",
    to: "  if not (v_cond = 'after_verified_death_or_incapacity'\n          or public.release_condition_satisfied(v_cond, v_approved, 'standard',\n                                                public.estate_lifecycle_state(p_estate))) then",
  },

  /* ── PHASE 11-B · the canonical release-condition engine ──────────────────────────────────────
   * Centralization is only worth anything if the centre is guarded. Each mutation below is an edit
   * to the ONE file that now decides release, or an edit that routes around it — and each names the
   * instrument that must object. Together they answer the question the phase turns on: if somebody
   * activated a death condition in this codebase, would anything notice?
   */
  {
    id: 'p11b-death-satisfied-standard',
    why: 'THE PHASE 11 FAILURE, COMMITTED AT THE CENTRE — 11-D form: death satisfied at EVERY '
      + 'lifecycle, not only death_verified. Folding the condition into the unconditional list is '
      + 'the one-line edit that looks like tidying the death arm away, and it activates every '
      + 'death-conditioned grant on every standard surface while the owner is alive.',
    file: 'db/functions/release_conditions.sql',
    from: "      when 'standard' then\n        p_release_condition = 'immediately'",
    to: "      when 'standard' then\n        p_release_condition in ('immediately', 'after_verified_death')",
  },
  {
    id: 'p11b-incapacity-satisfied',
    why: 'Incapacity is NOT death, and its workflow does not exist. A split that made the new '
      + 'incapacity condition live would disclose an estate while its owner is alive — the worst '
      + 'available outcome, reached by the edit that looks most like completing the split.',
    file: 'db/functions/release_conditions.sql',
    from: "      when 'legacy_immediate_only' then\n        p_release_condition = 'immediately'",
    to: "      when 'legacy_immediate_only' then\n        p_release_condition in ('immediately', 'after_verified_incapacity')",
  },
  {
    id: 'p11b-unknown-condition-fails-open',
    why: 'THE THREE-VALUED TRAP. `null = immediately` is NULL, not false, and a gate returning '
      + 'NULL is not refused by `if not (…)` — that branch simply does not execute. Flipping the '
      + 'coalesce default is the whole difference between fail-closed and fail-silent, and it is '
      + 'invisible in every test that only passes known values.',
    file: 'db/functions/release_conditions.sql',
    from: '    end,\n    false);',
    to: '    end,\n    true);',
  },
  {
    id: 'p11b-unknown-policy-fails-open',
    why: 'A consumer that names a policy this module has never heard of must be REFUSED, not given '
      + 'the wider rule. `else true` is how a typo in one call site silently becomes the most '
      + 'permissive answer available.',
    file: 'db/functions/release_conditions.sql',
    from: '      -- Unknown policy -> refused. No `else true`, ever.\n      else false',
    to: '      -- Unknown policy -> refused. No `else true`, ever.\n      else true',
  },
  {
    id: 'p11b-consumer-skips-the-predicate',
    why: 'CENTRALIZATION IS ONLY REAL IF EVERY CONSUMER STILL CALLS IN. Dropping the predicate from '
      + 'the net-worth grant lookup makes a `never` grant — and a death-conditioned one — disclose '
      + 'the estate total. The edit reads as removing a redundant filter.',
    file: 'db/functions/get_estate_net_worth.sql',
    from: "    and public.release_condition_satisfied(g.release_condition, g.approved_at, 'legacy_immediate_only',\n                                           public.estate_lifecycle_state(p_estate_id))\n  limit 1;",
    to: '  limit 1;',
  },
  {
    id: 'p11b-document-gate-skips-the-predicate',
    why: 'The document gate is the only thing between a non-owner and a document row. Making the '
      + 'predicate advisory — "or true" — is the shape of "the release condition is redundant '
      + 'here" and releases every dormant grant. Written to PRESERVE the call so the bundle\'s '
      + 'delegation control still passes: this mutation tests the RUNTIME layer, and a form the '
      + 'bundler refuses to build would prove the bundler instead (it has its own control).',
    file: 'db/functions/can_access_document.sql',
    from: "  return public.release_condition_satisfied(\n    g.release_condition, g.approved_at, 'standard', public.estate_lifecycle_state(v_estate));",
    to: "  return public.release_condition_satisfied(\n    g.release_condition, g.approved_at, 'standard', public.estate_lifecycle_state(v_estate)) or true;",
    /**
     * ★ THE SAME EDIT LANDS IN THE PREAMBLE'S VERBATIM COPY, and this is what `also` exists for.
     *
     * `can_access_document` is byte-compared between `db/functions/` and the harness preamble
     * (PREAMBLE_DISPOSITION: VERBATIM). Mutating only the source file makes the verifier exit 2 —
     * "declared VERBATIM but has DRIFTED" — before any assertion runs. That refusal is correct
     * behaviour for real drift, but here it means the anti-drift layer testifies INSTEAD of the
     * authorization suite, and nothing ever proves the runtime layer would catch the weakened gate.
     * Moving both copies together is what a contributor editing the gate would produce after the
     * drift guard sent them to "fix" the preamble, so it is also the more realistic mutation.
     */
    also: [{
      file: 'db/tests/preamble_real_auth.sql',
      from: "  return public.release_condition_satisfied(\n    g.release_condition, g.approved_at, 'standard', public.estate_lifecycle_state(v_estate));",
      to: "  return public.release_condition_satisfied(\n    g.release_condition, g.approved_at, 'standard', public.estate_lifecycle_state(v_estate)) or true;",
    }],
  },
  {
    id: 'p11b-claim-approval-satisfies-a-condition',
    why: 'CLAIM APPROVAL IS NOT DEATH VERIFICATION AND NEITHER IS RELEASE. Admitting '
      + 'after_claim_case_approval once approved_at is set connects the claim workflow to disclosure '
      + 'directly — the exact wire Phase 11-A pinned as absent, drawn through the new centre.',
    file: 'db/functions/release_conditions.sql',
    from: "        or (p_release_condition in ('after_owner_approval', 'after_access_request_approval')\n            and p_approved_at is not null)",
    to: "        or (p_release_condition in ('after_owner_approval', 'after_access_request_approval', 'after_claim_case_approval')\n            and p_approved_at is not null)",
  },
  {
    id: 'p11b-legacy-fused-becomes-writable',
    why: 'THE SPLIT UNDONE BY ADDING A LINE. Restoring the fused value to the write gate lets new '
      + 'rows keep carrying an ambiguity the product has deprecated, and looks like fixing an '
      + 'omission. The split is only real while new data cannot express it.',
    file: 'db/functions/release_conditions.sql',
    from: "    'after_claim_case_approval'\n    -- 'after_verified_death_or_incapacity' is DELIBERATELY ABSENT",
    to: "    'after_claim_case_approval',\n    'after_verified_death_or_incapacity'\n    -- 'after_verified_death_or_incapacity' is DELIBERATELY ABSENT",
  },
  {
    id: 'p11b-legacy-rows-orphaned',
    why: 'THE OTHER DIRECTION, AND THE ONE THAT LOOKS LIKE TIDYING. Dropping the deprecated value '
      + 'from the CHECK makes every stored fused grant unreadable and unupdatable — a migration '
      + 'that "completes the split" by invalidating the rows it was written to protect.',
    file: 'db/migrations/0051_20260812_release_condition_engine.sql',
    from: "      'after_verified_death_or_incapacity',\n      'after_claim_case_approval'",
    to: "      'after_claim_case_approval'",
  },
  {
    id: 'p11b-cross-estate-grant-satisfies',
    why: 'A grant belongs to ONE estate. Dropping the estate predicate from the inventory tier '
      + 'lookup lets a grant on estate B decide a viewer tier on estate A — cross-estate isolation '
      + 'failing through a lookup rather than through an authorization check.',
    file: 'db/functions/estate_discovery_rpcs.sql',
    from: '   where g.estate_id = p_estate\n     and g.grantee_user_id = p_uid',
    to: '   where g.estate_id is not null\n     and g.grantee_user_id = p_uid',
  },
  {
    id: 'p11b-local-policy-reintroduced-in-neighbour',
    target: 'npx',
    spec: 'test/releaseConditionCentralization.test.ts',
    why: 'THE REGRESSION THIS PHASE EXISTS TO MAKE IMPOSSIBLE. A contributor adds one more local '
      + 'release comparison — here in the professional workspace, which today delegates entirely — '
      + 'and the codebase quietly has two authorities again. It changes no behaviour, so no '
      + 'behavioural test can see it; only the centralization audit can.',
    file: 'db/functions/professional_workspace_rpcs.sql',
    from: '     and public.can_access_document(d.id);',
    to: "     and public.can_access_document(d.id)\n     and exists (select 1 from public.access_grants g2 where g2.estate_id = p_estate\n                   and g2.release_condition = 'immediately');",
  },
  // ══ PHASE 11-K · the operator control plane ═════════════════════════════════════════════════
  {
    id: 'p11k-projection-gate-deleted',
    why: 'THE WHOLE POINT OF STAGE 14. Deleting the admin gate from the operator QUEUE turns a '
      + 'staff-only workflow surface into a list of every death-verification case in the product, '
      + 'readable by any authenticated user — an owner, a beneficiary, a stranger.',
    file: 'db/functions/operator_console.sql',
    from: "as $function$\ndeclare v_limit int;\nbegin\n  perform public.admin_require_gate();",
    to: "as $function$\ndeclare v_limit int;\nbegin",
  },
  {
    id: 'p11k-case-file-gate-deleted',
    why: 'The same deletion on the CASE FILE, which carries initiator identity, evidence metadata '
      + 'and decision notes. A missing gate here discloses far more than the queue does.',
    file: 'db/functions/operator_console.sql',
    from: "  perform public.admin_require_gate();\n  v_uid := auth.uid();",
    to: "  v_uid := auth.uid();",
  },
  {
    id: 'p11k-owner-address-projected',
    why: 'THE DISCLOSURE THIS PROJECTION EXISTS TO AVOID. Adding the recipient to the owner-notice '
      + 'arm hands every operator a living owner\'s email address — the address of the person the '
      + 'challenge window exists to protect, on the surface used by whoever is adjudicating a '
      + 'claim that they are dead.',
    file: 'db/functions/operator_console.sql',
    from: "               'failure_class', o.failure_class",
    to: "               'failure_class', o.failure_class,\n               'recipient', o.recipient",
  },
  {
    id: 'p11k-reviewer-a-read-off-the-row',
    why: 'THE TWO-PERSON RULE, MISREPRESENTED. Hardcoding viewer_is_reviewer_a to false tells the '
      + 'first reviewer they are eligible to authorize their own release. The DOOR still refuses, '
      + 'so nothing unsafe commits — but the console would present an action that always fails, '
      + 'and an operator who trusts it would conclude the two-person rule is broken rather than '
      + 'that they are the wrong person.',
    file: 'db/functions/operator_console.sql',
    from: "      'viewer_is_reviewer_a', v_c.decided_by is not null and v_c.decided_by = v_uid,",
    to: "      'viewer_is_reviewer_a', false,",
  },
  {
    id: 'p11k-worker-pair-client-reachable',
    why: 'Granting the claim routine to `authenticated` lets any signed-in user move a live owner '
      + 'safety notice into `processing`, where it is never sent and the stale sweep later burns '
      + 'it. A silent, client-triggerable way to ensure an owner is never warned.',
    file: 'db/functions/outbox_safety.sql',
    from: "grant  execute on function public.claim_owner_notices(int) to service_role;",
    to: "grant  execute on function public.claim_owner_notices(int) to service_role, authenticated;",
  },
  {
    id: 'p11-executor-gains-disclosure',
    target: 'npx',
    why: 'A fiduciary designation confers capacity, never disclosure. Granting a tier to an executor '
      + 'is the most natural-sounding Phase 11 mistake there is.',
    file: 'db/functions/estate_discovery_rpcs.sql',
    from: '  if public.is_estate_owner(p_estate) then return \'full_detail\'; end if;',
    to: '  if public.is_estate_owner(p_estate) then return \'full_detail\'; end if;\n  if public.is_estate_executor(p_estate, p_uid) then return \'full_detail\'; end if;',
  },
  /* ── PHASE 11-C · the death-verification foundation ───────────────────────────────────────────
   * A case model that records facts about a death must be UNABLE to act on them. Each mutation
   * below is the edit a well-meaning contributor would actually make — widening a gate, "helpfully"
   * activating a grant on verification, copying the requirement into the attainment, enriching a
   * refusal message — and each names the instrument that must object. #16 of the phase matrix
   * (mobile derives release readiness) is killed on the mobile side by
   * `features/grants/__tests__/releaseAuthorityAbsence.test.ts`, which carries its own
   * detection-sanity fixtures; #7 (approved claim satisfies a grant) and #21 (fiduciary role
   * becomes tier) were killed in 11-B/11-A above and stay in force unchanged.
   */
  {
    id: 'p11c-beneficiary-initiates',
    why: 'D2: initiation is DESIGNEE-only. Widening the gate to approved members is the most '
      + 'natural-looking wrong edit — a beneficiary could then open a death case against a living '
      + 'owner (T1).',
    file: 'db/functions/death_verification.sql',
    from: "  if not public.is_estate_executor(p_estate, v_uid) then\n    raise exception 'not_authorized' using errcode = '42501';\n  end if;",
    to: "  if not (public.is_estate_executor(p_estate, v_uid)\n          or exists (select 1 from public.estate_memberships m\n                      where m.estate_id = p_estate and m.user_id = v_uid and m.status = 'approved')) then\n    raise exception 'not_authorized' using errcode = '42501';\n  end if;",
  },
  {
    id: 'p11c-delegate-initiates',
    why: 'A professional delegate WITHOUT a designation is a service provider, not a fiduciary (T2). '
      + 'Admitting the delegate role specifically is the "the professional is handling the estate '
      + 'anyway" edit.',
    file: 'db/functions/death_verification.sql',
    from: "  if not public.is_estate_executor(p_estate, v_uid) then\n    raise exception 'not_authorized' using errcode = '42501';\n  end if;",
    to: "  if not (public.is_estate_executor(p_estate, v_uid)\n          or exists (select 1 from public.estate_memberships m\n                      where m.estate_id = p_estate and m.user_id = v_uid\n                        and m.role = 'professional_delegate' and m.status = 'approved')) then\n    raise exception 'not_authorized' using errcode = '42501';\n  end if;",
  },
  {
    id: 'p11c-any-authenticated-initiates',
    why: 'The gate hollowed out: any signed-in account — a foreign owner, a stranger — can open '
      + 'a death case against any estate (T6). The cross-estate and foreign-owner refusal rows must '
      + 'object. (The predicate CALL survives the mutation so the bundle control cannot be the '
      + 'thing that objects — the SUITE must be.)',
    file: 'db/functions/death_verification.sql',
    from: "  if not public.is_estate_executor(p_estate, v_uid) then\n    raise exception 'not_authorized' using errcode = '42501';\n  end if;",
    to: "  if not (v_uid is not null or public.is_estate_executor(p_estate, v_uid)) then\n    raise exception 'not_authorized' using errcode = '42501';\n  end if;",
  },
  {
    id: 'p11c-initiation-activates-death-grants',
    why: 'CASE CREATION IS NOT DEATH VERIFICATION IS NOT RELEASE. A case that flips dormant death '
      + 'grants live on filing turns an unverified attestation into disclosure — the composed '
      + 'equivalence firewall must see the delegate payload move.',
    file: 'db/functions/death_verification.sql',
    from: '  returning id into v_case;',
    to: "  returning id into v_case;\n  update public.access_grants set release_condition = 'immediately'\n   where estate_id = p_estate and release_condition = 'after_verified_death';",
  },
  {
    id: 'p11c-evidence-activates-death-grants',
    why: 'FILE UPLOAD IS NOT DOCUMENT VERIFICATION (§13). Receiving a PDF must strengthen nothing; '
      + 'an attach routine that touches grants is releasing on unreviewed bytes (T4).',
    file: 'db/functions/death_verification.sql',
    from: '  returning id into v_evidence;',
    to: "  returning id into v_evidence;\n  update public.access_grants set release_condition = 'immediately'\n   where estate_id = v_estate and release_condition = 'after_verified_death';",
  },
  {
    id: 'p11c-attained-activates-death-grants',
    why: 'ATTAINMENT IS A FACT, RELEASE IS A DECISION NOBODY CAN TAKE YET (D3/T16). The attained '
      + 'level reaching any value must move no grant.',
    file: 'db/functions/death_verification.sql',
    from: '     set attained_level = p_level, updated_at = now()\n   where id = p_case;',
    to: "     set attained_level = p_level, updated_at = now()\n   where id = p_case;\n  update public.access_grants set release_condition = 'immediately'\n   where estate_id = v_estate and release_condition = 'after_verified_death';",
  },
  {
    id: 'p11c-verified-releases-instructions',
    target: 'npx',
    why: 'DEATH VERIFIED IS NOT ESTATE RELEASED (D5/T16). Unsealing encrypted_instructions on the '
      + 'verify decision is the premature-release edit in its most literal form; the firewall pin '
      + '"no function sets encrypted_instructions.released" must object.',
    file: 'db/functions/death_verification.sql',
    from: '         decision_note = p_note, updated_at = now()\n   where id = p_case;',
    to: "         decision_note = p_note, updated_at = now()\n   where id = p_case;\n  update public.encrypted_instructions set released = true where estate_id = v_estate;",
  },
  {
    id: 'p11c-required-copied-into-attained',
    why: 'REQUIRED IS WHAT POLICY DEMANDS; ATTAINED IS WHAT ACTUALLY HAPPENED (§10/11). Seeding the '
      + 'attained level from the requirement makes every case verifiable at birth — the suite pins '
      + 'the NULL baseline.',
    file: 'db/functions/death_verification.sql',
    from: "    (estate_id, event_type, status, initiated_by, initiator_designation_id, initiator_capacity,\n     jurisdiction_context, required_level_at_initiation)\n  values\n    (p_estate, 'death', 'open', v_uid, v_designation, v_capacity, v_juris, v_required)",
    to: "    (estate_id, event_type, status, initiated_by, initiator_designation_id, initiator_capacity,\n     jurisdiction_context, required_level_at_initiation, attained_level)\n  values\n    (p_estate, 'death', 'open', v_uid, v_designation, v_capacity, v_juris, v_required, v_required)",
  },
  {
    id: 'p11c-unknown-jurisdiction-lowers',
    why: 'UNKNOWN JURISDICTION FAILS CLOSED TO THE MAXIMUM (T13). Flipping the code default to the '
      + 'minimum silently makes every unmapped country the easiest place to verify a death.',
    file: 'db/functions/required_verification_level.sql',
    from: "    v_floor := 'enhanced_kyc';",
    to: "    v_floor := 'attestation';",
  },
  {
    id: 'p11c-attained-vocabulary-widens-to-text',
    why: 'THE ENUM IS THE VOCABULARY GUARD (T14). A text parameter reopens the door to levels the '
      + 'policy engine has never heard of; the suite resolves the enum signature before asserting '
      + 'anything.',
    file: 'db/functions/death_verification.sql',
    from: '  p_level public.verification_level,',
    to: '  p_level text,',
  },
  {
    id: 'p11c-refusal-leaks-evidence-count',
    why: 'REFUSAL SHAPE IS AN ORACLE IF IT VARIES (T9/§20). An error message enriched with an '
      + 'evidence count tells an unauthorized caller that a case exists and is progressing; the '
      + 'suite demands the EXACT sentinel bytes.',
    file: 'db/functions/death_verification.sql',
    from: "  if v_estate is null or not public.is_estate_executor(v_estate, v_uid) then\n    raise exception 'not_authorized' using errcode = '42501';\n  end if;",
    to: "  if v_estate is null or not public.is_estate_executor(v_estate, v_uid) then\n    raise exception 'not_authorized (evidence on file: %)',\n      (select count(*) from public.death_verification_evidence e where e.case_id = p_case)\n      using errcode = '42501';\n  end if;",
  },
  {
    id: 'p11c-nonexistent-estate-distinguishable',
    why: 'A DISTINCT not-found REFUSAL CONFIRMS ESTATE EXISTENCE (T9). The byte-identical matrix '
      + 'includes a nonexistent estate precisely so this pre-check cannot arrive.',
    file: 'db/functions/death_verification.sql',
    from: "  if not public.is_estate_executor(p_estate, v_uid) then\n    raise exception 'not_authorized' using errcode = '42501';\n  end if;",
    to: "  if not exists (select 1 from public.estates e where e.id = p_estate) then\n    raise exception 'estate_not_found' using errcode = 'P0002';\n  end if;\n  if not public.is_estate_executor(p_estate, v_uid) then\n    raise exception 'not_authorized' using errcode = '42501';\n  end if;",
  },
  {
    id: 'p11c-refusal-leaks-claimant',
    why: 'CLAIMANT IDENTITY IS PROTECTED FROM UNAUTHORIZED VIEWERS (T10). A refusal naming the '
      + 'initiator hands an attacker the fiduciary to target.',
    file: 'db/functions/death_verification.sql',
    from: "  if v_estate is null\n     or v_initiated_by <> v_uid\n     or not public.is_estate_executor(v_estate, v_uid) then\n    raise exception 'not_authorized' using errcode = '42501';\n  end if;",
    to: "  if v_estate is null\n     or v_initiated_by <> v_uid\n     or not public.is_estate_executor(v_estate, v_uid) then\n    raise exception 'not_authorized (case initiated by %)', v_initiated_by using errcode = '42501';\n  end if;",
  },
  {
    id: 'p11c-claim-status-becomes-lifecycle',
    target: 'npx',
    why: 'THE LIFECYCLE IS AUTHORITATIVE; THE CLAIM PROJECTION IS A LABEL (D7). Falling back to '
      + 'estate_release_state re-couples the new record to claim_packets.status — the carrier the '
      + 'phase exists to retire. The seam pin (one caller, ever) must object. (The reader moved to '
      + 'its own source file in 11-D; the mutation moved with it.)',
    file: 'db/functions/estate_lifecycle_state.sql',
    from: "  select coalesce(\n    (select l.state from public.estate_lifecycle l where l.estate_id = p_estate),\n    'active');",
    to: "  select coalesce(\n    (select l.state from public.estate_lifecycle l where l.estate_id = p_estate),\n    public.estate_release_state(p_estate));",
  },
  {
    id: 'p11c-audit-loses-estate-attribution',
    why: 'AN AUDIT ROW WITHOUT ESTATE CONTEXT CANNOT BE RECONSTRUCTED (§21). The trail assertions '
      + 'require actor AND estate on every case event.',
    file: 'db/functions/death_verification.sql',
    from: "  perform public.write_audit(\n    'death_case.initiated', 'death_verification_cases', v_case, p_estate,",
    to: "  perform public.write_audit(\n    'death_case.initiated', 'death_verification_cases', v_case, null,",
  },
  {
    id: 'p11c-local-policy-in-decision',
    why: 'A LOCAL REQUIREMENT CONSTANT BESIDE THE CENTRAL ENGINE IS THE 11-B DEFECT REBORN (§18 of '
      + 'the matrix). It is even "safe" today — the constant matches the common answer — which is '
      + 'exactly why only the live-derivation test (tighten, refuse; restore, pass) can kill it.',
    file: 'db/functions/death_verification.sql',
    from: '    v_required := public.required_verification_level(v_estate);',
    to: "    v_required := 'enhanced_kyc';",
  },
  {
    id: 'p11c-death-incapacity-refused',
    why: 'DEATH AND INCAPACITY ARE DISTINCT EVENTS (D9). Re-fusing them for new rows resurrects the '
      + 'vocabulary 11-B split; the closed-set catalog assertion must count exactly one legal value.',
    file: 'db/migrations/0052_20260812_death_verification_foundation.sql',
    from: "    check (event_type in ('death')),",
    to: "    check (event_type in ('death', 'death_or_incapacity')),",
  },
  {
    id: 'p11c-notification-composes-evidence',
    why: 'NO EMITTER-COMPOSED PROSE, NO EVIDENCE DETAILS IN COPY (§22, Phase 10-E rule). Any '
      + 'notification born from the case flow — let alone one naming a document — must trip the '
      + 'zero-notification firewall.',
    file: 'db/functions/death_verification.sql',
    from: '  returning id into v_evidence;',
    to: "  returning id into v_evidence;\n  insert into public.notifications (user_id, estate_id, kind, title)\n  values (v_uid, v_estate, 'death_evidence', 'Evidence ' || p_document || ' received for review');",
  },
  {
    id: 'p11c-case-creates-grant',
    why: 'A CASE IS A RECORD, NEVER AN ACCESS INSTRUMENT (§7). Initiation manufacturing a grant — '
      + 'even to the fiduciary "who will need it" — is disclosure authority leaking out of the '
      + "owner's hands; the whole-flow grants bracket must object.",
    file: 'db/functions/death_verification.sql',
    from: '  returning id into v_case;',
    to: "  returning id into v_case;\n  insert into public.access_grants\n    (estate_id, grantee_user_id, grantee_role, category, visibility_tier, release_condition, status, granted_by_user_id)\n  values (p_estate, v_uid, 'beneficiary', 'estate_inventory', 'full_detail', 'immediately', 'active', v_uid);",
  },
  {
    id: 'p11c-case-raises-tier',
    why: 'A CASE MUST NOT TOUCH A VISIBILITY TIER (§7, matrix #23). Raising existing grants "in '
      + "preparation\" moves the beneficiary's live payload — the composed firewall must see it.",
    file: 'db/functions/death_verification.sql',
    from: '     set attained_level = p_level, updated_at = now()\n   where id = p_case;',
    to: "     set attained_level = p_level, updated_at = now()\n   where id = p_case;\n  update public.access_grants set visibility_tier = 'full_detail' where estate_id = v_estate;",
  },
  {
    id: 'p11c-released-becomes-reachable',
    target: 'npx',
    spec: 'test/deathVerificationFoundation.test.ts',
    why: 'RELEASED IS NOT A STATE THIS PHASE CAN STORE, LET ALONE REACH (§6, matrix #24). Widening '
      + 'the transition map is the first half of that accident; the closed-map pin must object '
      + 'before the CHECK ever gets its say.',
    file: 'db/functions/death_verification.sql',
    from: "    or (v_from = 'death_verification_pending' and p_to = 'death_verified')",
    to: "    or (v_from = 'death_verification_pending' and p_to = 'death_verified')\n    or (v_from = 'death_verified' and p_to = 'released')",
  },

  /* ── PHASE 11-D · lifecycle-aware release activation ──────────────────────────────────────────
   * The predicate now has a satisfying death arm, so the mutation surface inverts: 11-B/11-C asked
   * "would anything notice death becoming satisfiable?"; 11-D must ask "would anything notice the
   * CONJUNCTION weakening?" — satisfied too early, satisfied under the wrong policy, satisfied for
   * the wrong estate, or activation acquiring side effects (a grant row, a tier, a membership, an
   * announcement). Each mutation is the edit a contributor would actually make, and each names the
   * instrument that must object.
   */
  {
    id: 'p11d-death-satisfied-while-pending',
    why: 'A PENDING VERIFICATION IS NOT A VERIFIED DEATH (§14). Adding a second arm for the pending '
      + 'state releases on the strength of an OPEN case — an unreviewed attestation becomes '
      + 'disclosure. Written to PRESERVE the conjunct the bundler control requires, so the '
      + 'RUNTIME layer testifies rather than the build refusing (the Stage-17 masking shape).',
    file: 'db/functions/release_conditions.sql',
    from: "        or (p_release_condition = 'after_verified_death'\n            and p_lifecycle_state = 'released')",
    to: "        or (p_release_condition = 'after_verified_death'\n            and p_lifecycle_state = 'released')\n        or (p_release_condition = 'after_verified_death'\n            and p_lifecycle_state = 'challenge_window')",
  },
  {
    id: 'p11d-death-ignores-lifecycle',
    why: 'THE CONJUNCTION IS THE FIREWALL (matrix #11). Dropping the lifecycle conjunct satisfies '
      + 'the death condition unconditionally under standard — the argument is still accepted, '
      + 'still passed by every consumer, and decides nothing. The edit reads as simplifying a '
      + 'redundant check, and the truth table must be what objects (the bundler deliberately '
      + 'carries no needle for the conjunction, so this layer stays testable).',
    file: 'db/functions/release_conditions.sql',
    from: "        or (p_release_condition = 'after_verified_death'\n            and p_lifecycle_state = 'released')",
    to: "        or p_release_condition = 'after_verified_death'",
  },
  {
    id: 'p11d-unknown-lifecycle-fails-open',
    why: 'AN OUT-OF-VOCABULARY LIFECYCLE MUST REFUSE EVERYTHING (matrix #9). Softening the validity '
      + 'gate to a not-equals makes any miswired consumer — one passing a label, a claim state, a '
      + 'typo — evaluate as though the lifecycle were fine. Fail-closed on this axis is what makes '
      + 'a wiring mistake loud instead of permissive.',
    file: 'db/functions/release_conditions.sql',
    from: "    p_lifecycle_state in ('active', 'death_verification_pending', 'death_verified',\n                          'owner_notification_dispatched',\n                          'challenge_window', 'challenge_halted', 'released')",
    to: "    p_lifecycle_state is distinct from 'released'",
  },
  {
    id: 'p11d-policies-silently-harmonized',
    why: 'R12 AS A MUTATION (matrix #14). Giving the legacy arm the same death clause as standard '
      + 'is the "complete the feature" edit — and it changes what a survivor sees on the asset '
      + 'surfaces, which is a priced product decision, not a tidy-up. The truth table pins the '
      + 'legacy cell false; the surface matrix pins asset rows dormant at death_verified.',
    file: 'db/functions/release_conditions.sql',
    from: "      when 'legacy_immediate_only' then\n        p_release_condition = 'immediately'",
    to: "      when 'legacy_immediate_only' then\n        p_release_condition = 'immediately'\n        or (p_release_condition = 'after_verified_death'\n            and p_lifecycle_state = 'released')",
  },
  {
    id: 'p11d-never-satisfied-at-death',
    why: 'NEVER MEANS NEVER, INCLUDING AFTER A VERIFIED DEATH (matrix #7). Folding never into the '
      + 'death arm is the shape of "the owner is gone, surely the block lapses" — it does not: '
      + 'never is the owner\'s standing refusal, and death does not rewrite owner intent (R3/R4).',
    file: 'db/functions/release_conditions.sql',
    from: "        or (p_release_condition = 'after_verified_death'\n            and p_lifecycle_state = 'released')",
    to: "        or (p_release_condition in ('after_verified_death', 'never')\n            and p_lifecycle_state = 'released')",
  },
  {
    id: 'p11d-consumer-pins-lifecycle',
    why: 'THE SEAM IS THE ONLY LIFECYCLE A CONSUMER MAY PASS (matrix #19). Pinning death_verified '
      + 'at one call site activates that surface\'s death grants for every estate, verified or not '
      + '— the per-estate fact replaced by a constant that happens to be true somewhere. The '
      + 'pre-activation dormancy matrix must see estate A\'s grant go live.',
    file: 'db/functions/estate_discovery_rpcs.sql',
    from: "  if not public.release_condition_satisfied(v_cond, v_approved, 'standard',\n                                            public.estate_lifecycle_state(p_estate)) then",
    to: "  if not public.release_condition_satisfied(v_cond, v_approved, 'standard',\n                                            coalesce('death_verified', public.estate_lifecycle_state(p_estate))) then",
  },
  {
    id: 'p11d-local-lifecycle-comparison',
    target: 'npx',
    spec: 'test/deathVerificationFoundation.test.ts',
    why: 'RELEASE POLICY MUST NOT LEAK BACK OUT OF THE CANONICAL MODULE ONE `if` AT A TIME (matrix '
      + '#13). A consumer short-circuiting on its own lifecycle comparison bypasses the predicate '
      + 'AND the ceiling clamp below it. The only-as-argument pin must object — this edit changes '
      + 'no behaviour in the fixture\'s pre-verification world, so only structure can catch it early.',
    file: 'db/functions/estate_discovery_rpcs.sql',
    from: "  -- Read-time ceiling clamp (authoritative).\n  if not public.asset_category_grantable(v_role, 'estate_inventory', v_tier) then",
    to: "  if public.estate_lifecycle_state(p_estate) = 'death_verified' then\n    return v_tier;\n  end if;\n  -- Read-time ceiling clamp (authoritative).\n  if not public.asset_category_grantable(v_role, 'estate_inventory', v_tier) then",
  },
  {
    id: 'p11d-seam-loses-estate-scope',
    why: 'ONE ESTATE\'S DEATH IS NOT EVERY ESTATE\'S DEATH (matrix #30, §12). Dropping the estate '
      + 'predicate from the reader makes the most recently moved lifecycle answer for every estate '
      + '— the cross-estate matrix (a dormant grant on active estate A while estate D is verified) '
      + 'must object.',
    file: 'db/functions/estate_lifecycle_state.sql',
    from: "    (select l.state from public.estate_lifecycle l where l.estate_id = p_estate),",
    to: "    (select l.state from public.estate_lifecycle l order by l.updated_at desc limit 1),",
  },
  {
    id: 'p11d-attained-becomes-lifecycle',
    why: 'ATTAINMENT IS A FACT, THE LIFECYCLE IS A DECISION (matrix #4, §14). A reader that treats '
      + '"attained level present on an open case" as death_verified releases on the reviewer\'s '
      + 'data-entry, before any decision ran H2. The stage firewall (attained set, payload frozen) '
      + 'must object.',
    file: 'db/functions/estate_lifecycle_state.sql',
    from: "    (select l.state from public.estate_lifecycle l where l.estate_id = p_estate),",
    to: "    (select case when l.state = 'death_verification_pending'\n                  and exists (select 1 from public.death_verification_cases c\n                               where c.estate_id = p_estate and c.status = 'open'\n                                 and c.attained_level is not null)\n                 then 'death_verified' else l.state end\n       from public.estate_lifecycle l where l.estate_id = p_estate),",
  },
  {
    id: 'p11d-decision-skips-lifecycle-transition',
    why: 'THE DECISION AND THE LIFECYCLE MOVE ATOMICALLY OR THE BOUNDARY IS FICTION (§14: "case '
      + 'verified but lifecycle not transitioned"). A decision routine that stamps the case and '
      + 'forgets the transition leaves the predicate blind to a verification that "happened" — the '
      + 'activation assertion (delegate payload MUST move at death_verified) is what notices the '
      + 'seam went dead.',
    file: 'db/functions/death_verification.sql',
    from: "  perform public.apply_estate_lifecycle_transition(\n    v_estate,\n    case when p_decision = 'verify' then 'death_verified' else 'active' end,\n    p_case,\n    'case_' || v_target);",
    to: "  -- transition deferred to a follow-up job\n  perform 1;",
  },
  {
    id: 'p11d-verify-manufactures-grant',
    why: 'ACTIVATION IS EVALUATIVE, NEVER A WRITE (matrix #15, R3). Verifying a death must not '
      + 'insert a grant — even for the fiduciary "who will need it". The grants bracket (byte-'
      + 'identical access_grants across the flow) must object.',
    file: 'db/functions/death_verification.sql',
    from: "  update public.death_verification_cases\n     set status = v_target, decided_by = v_uid, decided_at = now(),\n         decision_note = p_note, updated_at = now()\n   where id = p_case;",
    to: "  update public.death_verification_cases\n     set status = v_target, decided_by = v_uid, decided_at = now(),\n         decision_note = p_note, updated_at = now()\n   where id = p_case;\n  insert into public.access_grants\n    (estate_id, grantee_user_id, grantee_role, category, visibility_tier, release_condition, status, granted_by_user_id)\n  select v_estate, c.initiated_by, 'beneficiary', 'estate_inventory', 'full_detail', 'immediately', 'active', v_uid\n    from public.death_verification_cases c where c.id = p_case and p_decision = 'verify';",
  },
  {
    id: 'p11d-verify-raises-tier',
    why: 'A VERIFIED DEATH MUST NOT TOUCH A TIER (matrix #16, R9). Raising existing grants "so the '
      + 'survivors can see what they need" rewrites owner-authored disclosure at the worst moment. '
      + 'The grants bracket and the beneficiary equivalence row must object.',
    file: 'db/functions/death_verification.sql',
    from: "  update public.death_verification_cases\n     set status = v_target, decided_by = v_uid, decided_at = now(),\n         decision_note = p_note, updated_at = now()\n   where id = p_case;",
    to: "  update public.death_verification_cases\n     set status = v_target, decided_by = v_uid, decided_at = now(),\n         decision_note = p_note, updated_at = now()\n   where id = p_case;\n  update public.access_grants set visibility_tier = 'full_detail'\n   where estate_id = v_estate and p_decision = 'verify';",
  },
  {
    id: 'p11d-verify-creates-membership',
    why: 'DEATH VERIFICATION MANUFACTURES NO RELATIONSHIP (matrix #17, R3). Materializing a '
      + 'membership for the initiator turns a capacity gate into an identity writer — the '
      + 'membership bracket must object.',
    file: 'db/functions/death_verification.sql',
    from: "  update public.death_verification_cases\n     set status = v_target, decided_by = v_uid, decided_at = now(),\n         decision_note = p_note, updated_at = now()\n   where id = p_case;",
    to: "  update public.death_verification_cases\n     set status = v_target, decided_by = v_uid, decided_at = now(),\n         decision_note = p_note, updated_at = now()\n   where id = p_case;\n  insert into public.estate_memberships (estate_id, user_id, role, status)\n  select v_estate, c.initiated_by, 'beneficiary', 'approved'\n    from public.death_verification_cases c where c.id = p_case and p_decision = 'verify';",
  },
  {
    id: 'p11d-verify-creates-designation',
    why: 'DEATH VERIFICATION CONFERS NO FIDUCIARY POWER EITHER (matrix #18). Stamping the decider '
      + 'as executor is authority manufacturing itself an author — the designation bracket must '
      + 'object.',
    file: 'db/functions/death_verification.sql',
    from: "  update public.death_verification_cases\n     set status = v_target, decided_by = v_uid, decided_at = now(),\n         decision_note = p_note, updated_at = now()\n   where id = p_case;",
    to: "  update public.death_verification_cases\n     set status = v_target, decided_by = v_uid, decided_at = now(),\n         decision_note = p_note, updated_at = now()\n   where id = p_case;\n  insert into public.estate_designations (estate_id, user_id, designation_type, status)\n  select v_estate, c.initiated_by, 'executor', 'active'\n    from public.death_verification_cases c where c.id = p_case and p_decision = 'verify';",
  },
  {
    id: 'p11d-notification-pin-becomes-death',
    why: 'EMISSION IS PINNED TO THE BASE LIFECYCLE, AND THE PIN IS LOAD-BEARING (§16, R11). '
      + 'Repointing the literal at death_verified makes every grant-creation emitter announce '
      + 'death-conditioned grants as live access — the release announcement 11-F owns, emitted as '
      + 'a side effect. The notification firewall row must object.',
    file: 'db/functions/lifecycle_notification_rpcs.sql',
    from: "     and public.release_condition_satisfied(p_release_condition, p_approved_at, 'standard', 'active');",
    to: "     and (public.release_condition_satisfied(p_release_condition, p_approved_at, 'standard', 'active')\n          or public.release_condition_satisfied(p_release_condition, p_approved_at, 'standard', 'released'));",
  },
  {
    id: 'p11d-notification-copy-death-language',
    why: 'NOTIFICATION COPY DISCLOSES NO DEATH OR RELEASE FACT (matrix #22, §16). Enriching the '
      + 'grant-created copy with release language turns a routine heads-up into the announcement '
      + 'this phase must not make; the exit matrix\'s language scan over emitted rows must object.',
    file: 'db/functions/lifecycle_notification_rpcs.sql',
    from: "     'You have access to shared estate information.'),",
    to: "     'The estate has been released to you.'),",
  },
  {
    id: 'p11d-revoked-death-grant-activates',
    why: 'REVOCATION SURVIVES DEATH (matrix #27). Softening the status filter lets a revoked '
      + 'death-conditioned grant come back to life at death_verified — the owner withdrew it while '
      + 'alive, and the withdrawal is exactly as authoritative as the grant was. The revoked-grant '
      + 'row of the activation matrix must object.',
    file: 'db/functions/estate_discovery_rpcs.sql',
    from: "     and g.category = 'estate_inventory'\n     and g.status = 'active'",
    to: "     and g.category = 'estate_inventory'\n     and g.status is not null",
  },
  {
    id: 'p11d-ceiling-clamp-bypassed',
    why: 'ACTIVATION FEEDS THE CEILING, IT DOES NOT OUTRANK IT (matrix #28). Disabling the '
      + 'read-time clamp lets an over-ceiling death grant deliver full_detail the moment the '
      + 'condition is satisfied — the over-ceiling row of the activation matrix must object.',
    file: 'db/functions/estate_discovery_rpcs.sql',
    from: "  if not public.asset_category_grantable(v_role, 'estate_inventory', v_tier) then\n    return 'hidden';\n  end if;",
    to: "  if not public.asset_category_grantable(v_role, 'estate_inventory', v_tier) and v_tier <> 'full_detail' then\n    return 'hidden';\n  end if;",
  },
  {
    id: 'p11d-equivalence-instrument-frozen',
    why: 'AN INSTRUMENT THAT CANNOT SEE CHANGE PROVES NOTHING (matrix #29). Freezing the composed '
      + 'helper to a constant makes every byte-identity assertion vacuously true — and the suite '
      + 'must FAIL anyway, because its positive controls demand that authorized changes and the '
      + '11-D activation itself visibly move the payload. A green run with a frozen instrument '
      + 'would mean the controls are decorative.',
    file: 'db/tests/death_verification_authorization.sql',
    from: "  ) into v;\n  reset role;\n  return v;\nexception when others then",
    to: "  ) into v;\n  reset role;\n  return '{}'::jsonb;\nexception when others then",
  },

  /* ── PHASE 11-E · the challenge window and the release seam ───────────────────────────────────
   * The safety seam only means something if every way around it is loud. These aim at the four
   * shapes that would each silently restore the 11-D behaviour or defeat the owner's protection:
   * satisfying the death condition too early, releasing without the guards, taking the owner's
   * challenge away, and leaking who challenged.
   */
  {
    id: 'p11e-death-satisfied-at-verified',
    why: 'THE 11-E REVERSAL, UNDONE (matrix #1). Re-pointing the death arm at death_verified is '
      + 'literally the 11-D behaviour, and it deletes the owner-challenge window from the product '
      + 'without touching a single safety routine — the whole seam bypassed by one word.',
    file: 'db/functions/release_conditions.sql',
    from: "        or (p_release_condition = 'after_verified_death'\n            and p_lifecycle_state = 'released')",
    to: "        or (p_release_condition = 'after_verified_death'\n            and p_lifecycle_state = 'death_verified')",
  },
  {
    id: 'p11e-death-satisfied-during-window',
    why: 'THE WINDOW MUST NOT DISCLOSE (matrix #2). Admitting challenge_window means the estate is '
      + 'read while the owner still has time to object — the protection is a countdown that already '
      + 'gave the information away.',
    file: 'db/functions/release_conditions.sql',
    from: "        or (p_release_condition = 'after_verified_death'\n            and p_lifecycle_state = 'released')",
    to: "        or (p_release_condition = 'after_verified_death'\n            and p_lifecycle_state in ('released', 'challenge_window'))",
  },
  {
    id: 'p11e-death-satisfied-at-halted',
    why: 'A HALTED PROCESS RELEASES NOTHING (matrix #3). Admitting challenge_halted turns the '
      + 'owner saying "I am alive" into the disclosure they were trying to stop — the worst '
      + 'available outcome in the whole phase.',
    file: 'db/functions/release_conditions.sql',
    from: "        or (p_release_condition = 'after_verified_death'\n            and p_lifecycle_state = 'released')",
    to: "        or (p_release_condition = 'after_verified_death'\n            and p_lifecycle_state in ('released', 'challenge_halted'))",
  },
  {
    id: 'p11e-release-skips-window',
    why: 'RELEASE MUST PASS THROUGH THE WINDOW (matrix #5). Admitting death_verified as a release '
      + 'source state lets an accepted verification go straight to disclosure. Aimed at the MAP '
      + 'AUDIT deliberately: release_estate carries its own state guard, so widening the map alone '
      + 'moves no runtime fixture — the two layers are independent, and this proves the structural '
      + 'one fires on its own rather than being carried by the behavioural one.',
    target: 'npx',
    spec: 'test/deathVerificationFoundation.test.ts',
    file: 'db/functions/death_verification.sql',
    from: "    or (v_from = 'challenge_window'           and p_to = 'released')",
    to: "    or (v_from = 'challenge_window'           and p_to = 'released')\n    or (v_from = 'death_verified'             and p_to = 'released')",
  },
  {
    id: 'p11e-halted-can-be-reopened',
    why: 'CHALLENGE_HALTED IS TERMINAL IN 11-E (matrix #43). An edge back to the window is the '
      + '"surely an admin can resume it after review" edit — and resuming a halted process is a '
      + 'product decision nobody has taken, taken silently in a map.',
    file: 'db/functions/death_verification.sql',
    from: "    or (v_from = 'challenge_window'           and p_to = 'challenge_halted')",
    to: "    or (v_from = 'challenge_window'           and p_to = 'challenge_halted')\n    or (v_from = 'challenge_halted'           and p_to = 'challenge_window')",
  },
  {
    id: 'p11e-release-before-window-elapses',
    why: 'THE WINDOW IS THE PROTECTION (matrix #5). Dropping the elapsed check releases the instant '
      + 'the window opens — the owner is notified and disclosed in the same breath.',
    file: 'db/functions/release_safety.sql',
    from: "  if not coalesce(now() > v_row.owner_notified_at + v_duration, false) then\n    raise exception 'release_window_not_elapsed' using errcode = 'P0001';\n  end if;",
    to: "  if false then\n    raise exception 'release_window_not_elapsed' using errcode = 'P0001';\n  end if;",
  },
  {
    id: 'p11e-challenge-loses-the-tie',
    why: 'THE TIE BELONGS TO THE OWNER (matrix #8, R14). `>` becoming `>=` is a ONE-CHARACTER edit '
      + 'that hands the exact boundary instant to release instead of the challenge. No behavioural '
      + 'test that samples times either side of the boundary can see it; only the exact-instant '
      + 'fixture can.',
    file: 'db/functions/release_safety.sql',
    from: "  if not coalesce(now() > v_row.owner_notified_at + v_duration, false) then",
    to: "  if not coalesce(now() >= v_row.owner_notified_at + v_duration, false) then",
  },
  {
    id: 'p11e-release-without-owner-notice',
    why: 'THE WINDOW MAY NOT BEGIN UN-NOTIFIED (§9, matrix #6). Dropping the committed-notice guard '
      + 'lets a window that never reached the owner still elapse into disclosure — the safety '
      + 'precondition becomes decorative.',
    file: 'db/functions/release_safety.sql',
    from: "  if v_row.owner_notified_at is null or v_row.safety_notification_id is null then\n    raise exception 'owner_not_notified' using errcode = 'P0001';\n  end if;\n  if not exists (\n    select 1 from public.owner_notice_outbox o\n     where o.estate_id = p_estate and o.channel = 'email' and o.status <> 'cancelled'\n  ) then\n    raise exception 'owner_channel_unreachable' using errcode = 'P0001';\n  end if;\n\n  select c.id, c.decided_by",
    to: "  if false then\n    raise exception 'owner_not_notified' using errcode = 'P0001';\n  end if;\n  if not exists (\n    select 1 from public.owner_notice_outbox o\n     where o.estate_id = p_estate and o.channel = 'email' and o.status <> 'cancelled'\n  ) then\n    raise exception 'owner_channel_unreachable' using errcode = 'P0001';\n  end if;\n\n  select c.id, c.decided_by",
  },
  {
    id: 'p11e-window-opens-without-notifying',
    why: 'THE INVERTED EMITTER TRADE IS THE SAFETY CONTRACT (§9). Swallowing a failed notice — the '
      + 'DEFAULT behaviour everywhere else in the product, which is why this is the natural edit — '
      + 'starts the release clock on an owner who was never told. Aimed at the STRUCTURAL audit '
      + 'deliberately: the happy path still commits a notice, so no runtime fixture distinguishes '
      + 'this weakening without breaking the catalog to force an emit failure. The instrument that '
      + 'can see it is the one that reads the error path.',
    target: 'npx',
    spec: 'test/deathVerificationFoundation.test.ts',
    file: 'db/functions/release_safety.sql',
    from: "  if v_notice is null then\n    raise exception 'owner_notification_failed' using errcode = 'P0001';\n  end if;",
    to: "  if v_notice is null then\n    v_notice := gen_random_uuid();\n  end if;",
  },
  {
    id: 'p11e-non-owner-can-challenge',
    why: 'THE CHALLENGE IS OWNER-ONLY (matrix #12-14). Widening to approved members lets the '
      + 'claimant halt — or, read the other way, lets a beneficiary interfere with a legitimate '
      + 'process. Both directions are wrong, and the byte-identical refusal matrix must object.',
    file: 'db/functions/release_safety.sql',
    from: "  if not public.is_estate_owner(p_estate) then\n    raise exception 'not_authorized' using errcode = '42501';\n  end if;\n\n  select l.state into v_state\n    from public.estate_lifecycle l\n   where l.estate_id = p_estate\n   for update;",
    to: "  if not (public.is_estate_owner(p_estate)\n          or exists (select 1 from public.estate_memberships m\n                      where m.estate_id = p_estate and m.user_id = v_uid and m.status = 'approved')) then\n    raise exception 'not_authorized' using errcode = '42501';\n  end if;\n\n  select l.state into v_state\n    from public.estate_lifecycle l\n   where l.estate_id = p_estate\n   for update;",
  },
  {
    id: 'p11e-challenge-requires-designation',
    why: 'THE CHALLENGE MUST BE CHEAPER THAN THE CLAIM (R13, matrix #10). Requiring a designation '
      + 'means an owner who never named an executor cannot object to their own death — the exact '
      + 'population most exposed to a false claim.',
    file: 'db/functions/release_safety.sql',
    from: "  if not public.is_estate_owner(p_estate) then\n    raise exception 'not_authorized' using errcode = '42501';\n  end if;\n\n  select l.state into v_state\n    from public.estate_lifecycle l\n   where l.estate_id = p_estate\n   for update;",
    to: "  if not public.is_estate_owner(p_estate)\n     or not exists (select 1 from public.estate_designations d\n                     where d.estate_id = p_estate and d.status = 'active') then\n    raise exception 'not_authorized' using errcode = '42501';\n  end if;\n\n  select l.state into v_state\n    from public.estate_lifecycle l\n   where l.estate_id = p_estate\n   for update;",
  },
  {
    id: 'p11e-challenge-requires-window-open',
    why: 'THE OWNER MAY OBJECT AT ANY PRE-RELEASE STAGE (§7). Narrowing to challenge_window alone '
      + 'means an owner who learns of a pending case cannot stop it until the platform decides to '
      + 'open a window — the protection arrives only when the claimant has already succeeded.',
    file: 'db/functions/release_safety.sql',
    from: "  if v_state = 'active' then\n    raise exception 'nothing_to_challenge' using errcode = 'P0001';\n  end if;",
    to: "  if v_state <> 'challenge_window' then\n    raise exception 'nothing_to_challenge' using errcode = 'P0001';\n  end if;",
  },
  {
    id: 'p11e-release-proceeds-after-challenge',
    why: 'A HALTED PROCESS CAN NEVER RELEASE (matrix #7). Accepting challenge_halted as a release '
      + 'source is the "the review concluded anyway" edit — it overrides a living owner with a '
      + 'workflow.',
    file: 'db/functions/release_safety.sql',
    from: "  if v_row.state is distinct from 'challenge_window' then",
    to: "  if v_row.state not in ('challenge_window', 'challenge_halted') then",
  },
  {
    id: 'p11e-window-duration-seeded',
    why: 'THE WINDOW DURATION IS A PRODUCT DECISION, NOT A DEFAULT (§30). A migration seeding one '
      + 'hour makes every deployment silently agree to a challenge period nobody approved — and '
      + 'the fail-closed "never elapses" property disappears with it.',
    target: 'npx',
    spec: 'test/deathVerificationFoundation.test.ts',
    file: 'db/migrations/0054_20260812_challenge_window_release_seam.sql',
    from: "alter table public.release_safety_policy enable row level security;",
    to: "alter table public.release_safety_policy enable row level security;\ninsert into public.release_safety_policy (id, challenge_window) values (true, interval '1 hour') on conflict (id) do nothing;",
  },
  {
    id: 'p11e-challenge-audit-leaks-provenance',
    why: 'CHALLENGE PROVENANCE IS INFORMATION ABOUT A LIVING OWNER (§17, matrix #32). Recording the '
      + 'channel that responded tells anyone with audit access which of the owner\'s devices or '
      + 'addresses is alive — a targeting aid, added in the name of forensics.',
    file: 'db/functions/release_safety.sql',
    from: "    jsonb_build_object('severity', 'high', 'from_state', v_state));",
    to: "    jsonb_build_object('severity', 'high', 'from_state', v_state,\n                      'channel', 'in_app', 'device', current_setting('request.headers', true)));",
  },
  {
    id: 'p11e-release-manufactures-grant',
    why: 'RELEASE IS EVALUATIVE, NEVER A WRITE (matrix #20, R6). Inserting a grant "so the survivor '
      + 'can see something" at the moment of release is disclosure authority leaving the owner\'s '
      + 'hands at exactly the point nobody can take it back.',
    file: 'db/functions/release_safety.sql',
    from: "  perform public.apply_estate_lifecycle_transition(\n    p_estate, 'released', v_case, 'two_person_release');",
    to: "  perform public.apply_estate_lifecycle_transition(\n    p_estate, 'released', v_case, 'two_person_release');\n  insert into public.access_grants\n    (estate_id, grantee_user_id, grantee_role, category, visibility_tier, release_condition, status, granted_by_user_id)\n  select p_estate, c.initiated_by, 'beneficiary', 'estate_inventory', 'full_detail', 'immediately', 'active', c.initiated_by\n    from public.death_verification_cases c where c.id = v_case;",
  },
  {
    id: 'p11e-release-raises-tier',
    why: 'RELEASE MUST NOT TOUCH A TIER (matrix #21, R6). Raising existing grants at release '
      + 'rewrites owner-authored disclosure at the worst possible moment, and the composed '
      + 'equivalence matrix must see the delegate move beyond what the owner authored.',
    file: 'db/functions/release_safety.sql',
    from: "  update public.estate_lifecycle\n     set released_at = now()\n   where estate_id = p_estate;",
    to: "  update public.estate_lifecycle\n     set released_at = now()\n   where estate_id = p_estate;\n  update public.access_grants set visibility_tier = 'full_detail' where estate_id = p_estate;",
  },
  {
    id: 'p11e-release-creates-membership',
    why: 'RELEASE MANUFACTURES NO RELATIONSHIP (matrix #22, R6). Materializing a membership for the '
      + 'claimant makes the release event an identity writer — the bracket over memberships must '
      + 'object.',
    file: 'db/functions/release_safety.sql',
    from: "  update public.estate_lifecycle\n     set released_at = now()\n   where estate_id = p_estate;",
    to: "  update public.estate_lifecycle\n     set released_at = now()\n   where estate_id = p_estate;\n  insert into public.estate_memberships (estate_id, user_id, role, status)\n  select p_estate, c.initiated_by, 'beneficiary', 'approved'\n    from public.death_verification_cases c where c.id = v_case;",
  },
  {
    id: 'p11e-safety-notice-asserts-death',
    why: 'THE COPY MAY NOT ASSERT A DEATH (§18, matrix #33). "We have confirmed your death" to a '
      + 'living owner is both false and cruel, and it is the most natural wording anyone would '
      + 'reach for when describing what happened.',
    target: 'npx',
    spec: 'test/deathVerificationFoundation.test.ts',
    file: 'db/functions/lifecycle_notification_rpcs.sql',
    from: "     'A release process is waiting on your estate. You can review and halt it now.')",
    to: "     'We have verified your death and will release your estate. Halt this if you are alive.')",
  },
  {
    id: 'p11e-owner-status-leaks-lifecycle',
    why: 'THE OWNER SURFACE IS A CLOSED PRESENTATION UNION (§5). Returning the raw lifecycle hands '
      + 'the client machine internals to branch on — the first step toward a client that decides '
      + 'release eligibility for itself.',
    file: 'db/functions/release_safety.sql',
    from: "  return case v_state\n    when 'death_verification_pending'    then 'challengeable'",
    to: "  return case v_state\n    when 'death_verification_pending'    then v_state\n    when 'aw_never' then 'challengeable'",
  },
  {
    id: 'p11e-status-read-loses-owner-gate',
    why: 'ONLY THE OWNER MAY ASK ABOUT THEIR OWN ESTATE (§16). Dropping the gate turns the safety '
      + 'status into a death-process oracle for any authenticated user against any estate id.',
    file: 'db/functions/release_safety.sql',
    from: "  if not public.is_estate_owner(p_estate) then\n    raise exception 'not_authorized' using errcode = '42501';\n  end if;\n\n  v_state := public.estate_lifecycle_state(p_estate);",
    to: "  if false then\n    raise exception 'not_authorized' using errcode = '42501';\n  end if;\n\n  v_state := public.estate_lifecycle_state(p_estate);",
  },

  /* ── PHASE 11-F · two-person release, owner-liveness delivery, outbox safety ──────────────────
   * The five approved decisions each have a one-edit undo. These are those edits, written as the
   * change a well-meaning contributor would actually make — a relaxed comparison, a "helpful"
   * fallback, an optional notice, a reviewer parameter — and each names the instrument that must
   * object.
   */

  /* ── PHASE 11-G · survivor mode ───────────────────────────────────────────────────────────────
   * Survivor Mode consumes the release architecture rather than adding one, so its mutations aim at
   * the two ways that claim could quietly become false: a lifecycle state other than `released`
   * starting to disclose, and a RELATIONSHIP starting to decide a TIER.
   */
  {
    id: 'p11g-relationship-becomes-tier',
    why: 'G3 IN ONE EDIT. Giving an approved beneficiary membership a tier when no grant resolves '
      + 'one is the most natural-sounding survivor bug there is — "they are a beneficiary, show them '
      + 'the estate" — and it converts a relationship into disclosure the owner never authored.',
    file: 'db/functions/estate_discovery_rpcs.sql',
    from: "  if v_tier is null then return 'hidden'; end if;",
    to: "  if v_tier is null then\n    if exists (select 1 from public.estate_memberships m\n                where m.estate_id = p_estate and m.user_id = p_uid\n                  and m.role = 'beneficiary' and m.status = 'approved')\n    then return 'category_summary'; end if;\n    return 'hidden';\n  end if;",
  },
  {
    id: 'p11g-executor-capacity-becomes-tier',
    why: 'G3, THE FIDUCIARY VARIANT. "The executor is administering the estate, so show them the '
      + 'estate" is the single most plausible Phase 11 mistake — and capacity is not a disclosure '
      + 'tier. The survivor matrix puts an executor with NO grant in front of a RELEASED estate '
      + 'precisely so this cannot pass.',
    file: 'db/functions/estate_discovery_rpcs.sql',
    from: "  if public.is_estate_owner(p_estate) then return 'full_detail'; end if;",
    to: "  if public.is_estate_owner(p_estate) then return 'full_detail'; end if;\n  if public.is_estate_executor(p_estate, p_uid) then return 'limited_detail'; end if;",
  },
  {
    id: 'p11g-archived-assets-rejoin-released-aggregate',
    why: 'WITHDRAWN MATERIAL MUST STAY WITHDRAWN, INCLUDING AFTER RELEASE. An owner who archived an '
      + 'asset removed it from the inventory; surfacing it to a survivor would overstate the estate '
      + 'at the worst possible moment, and would make deletion observable to a third party.',
    file: 'db/functions/estate_discovery_rpcs.sql',
    from: "       and a.archived_at is null\n     group by a.category",
    to: "       and (a.archived_at is null or a.archived_at is not null)\n     group by a.category",
  },

  /* ── PHASE 11-H · fiduciary capacity is not a disclosure tier ──────────────────────────────── */
  {
    id: 'p11h-membership-opens-fiduciary-workflow',
    why: 'THE CONVERSE LAUNDERING. "This person is an approved member of the estate, so let them '
      + 'report a death" turns a relationship into workflow authority. Death verification is the '
      + 'most consequential process in the product and it is opened by DESIGNATION, never by '
      + 'membership — an owner chooses who may start it.',
    file: 'db/functions/death_verification.sql',
    from: "  if not public.is_estate_executor(p_estate, v_uid) then",
    to: "  if not (public.is_estate_executor(p_estate, v_uid)\n          or exists (select 1 from public.estate_memberships m\n                      where m.estate_id = p_estate and m.user_id = v_uid and m.status = 'approved')) then",
  },

  /* ── PHASE 11-I · the fiduciary workflow read ──────────────────────────────────────────────── */
  {
    id: 'p11i-workspace-ungated',
    why: 'THE WHOLE GATE. Without it this is a SECURITY DEFINER reader of death-verification and '
      + 'claim rows exposed to every authenticated user on every estate — the worst possible '
      + 'outcome of adding a definer projection, and the one a refactor is most likely to cause by '
      + 'moving the gate below the first read.',
    file: 'db/functions/executor_workspace.sql',
    from: "  if not public.is_estate_executor(p_estate, v_uid) then\n    return jsonb_build_object('authorized', false);\n  end if;",
    to: "  if false then\n    return jsonb_build_object('authorized', false);\n  end if;",
  },
  {
    id: 'p11i-workspace-ignores-designation',
    why: 'THE MIRROR FAILURE: a projection that authorizes NOBODY. It would pass every "capacity '
      + 'discloses nothing" assertion perfectly, because a function that returns a refusal to all '
      + 'callers leaks nothing. The invariant needs both halves, and this is the mutation that '
      + 'proves the second half is actually being measured.',
    file: 'db/functions/executor_workspace.sql',
    from: "  if not public.is_estate_executor(p_estate, v_uid) then",
    to: "  if true or not public.is_estate_executor(p_estate, v_uid) then",
  },
  {
    id: 'p11i-workspace-leaks-asset-count',
    why: 'THE MOST TEMPTING ADDITION IN THE PRODUCT. "The executor is administering the estate, so '
      + 'show them how many assets there are" turns a workflow surface into an inventory oracle — '
      + 'and a count is a disclosure even when no name or value is attached, because it moves when '
      + 'the estate does.',
    file: 'db/functions/executor_workspace.sql',
    from: "    'actions', v_actions\n  );",
    to: "    'actions', v_actions,\n    'asset_count', (select count(*) from public.estate_assets a where a.estate_id = p_estate)\n  );",
  },
  {
    id: 'p11i-workspace-leaks-beneficiary-count',
    why: 'A HIDDEN-PARTY COUNT. It tells a fiduciary how many people the owner named without naming '
      + 'them, which reads as anonymised and is not: it moves the moment the owner adds anyone, so '
      + 'repeated reads reconstruct the owner private decisions over time.',
    file: 'db/functions/executor_workspace.sql',
    from: "    'actions', v_actions\n  );",
    to: "    'actions', v_actions,\n    'beneficiary_count', (select count(*) from public.beneficiaries b where b.estate_id = p_estate)\n  );",
  },
  {
    id: 'p11i-workspace-leaks-net-worth',
    why: 'THE SINGLE MOST SENSITIVE FIGURE IN THE ESTATE, attached to a workflow payload because it '
      + 'is convenient for a header. Capacity is not a disclosure tier, and a total is the whole '
      + 'inventory compressed into one number.',
    file: 'db/functions/executor_workspace.sql',
    from: "    'actions', v_actions\n  );",
    to: "    'actions', v_actions,\n    'net_worth_cents', (select coalesce(sum(a.value_cents), 0) from public.estate_assets a where a.estate_id = p_estate and a.archived_at is null)\n  );",
  },
  {
    id: 'p11i-workspace-reveals-initiator',
    why: 'ANOTHER FIDUCIARY, DISCLOSED. A case is one-per-estate, so returning who opened it tells '
      + 'fiduciary B that fiduciary A exists — a fact about a person, not about B own work. The '
      + 'case STATE is legitimately returned; the identity behind it is not, and the difference is '
      + 'exactly the line this projection is drawn along.',
    file: 'db/functions/executor_workspace.sql',
    from: "      'decided_at',     v_case.decided_at\n    ),",
    to: "      'decided_at',     v_case.decided_at,\n      'initiated_by',   (select c.initiated_by from public.death_verification_cases c where c.estate_id = p_estate order by c.created_at desc limit 1)\n    ),",
  },
  {
    id: 'p11i-instructions-reach-workspace',
    why: 'THE DORMANT SECOND RELEASE ENGINE, WIRED IN. `encrypted_instructions` carries its own '
      + 'release vocabulary (on_death / on_executor_claim / manual) and its own `released` boolean, '
      + 'neither of which the canonical predicate has ever seen. Letting it influence this '
      + 'projection would make a second authority source real, and it would look like enabling a '
      + 'feature that was already built.',
    file: 'db/functions/executor_workspace.sql',
    from: "      'release_completed',     v_lifecycle = 'released'",
    to: "      'release_completed',     v_lifecycle = 'released' or exists (select 1 from public.encrypted_instructions i where i.estate_id = p_estate and i.released = true and i.release_condition = 'on_death')",
  },

  /* ── HOTFIX · estate_release_state lockdown ────────────────────────────────────────────────── */
  {
    id: 'hotfix-release-state-regranted',
    why: 'THE DEFECT, RESTORED. Re-granting EXECUTE to `authenticated` lets any signed-in user pass '
      + 'any estate id to a SECURITY DEFINER helper with no gate in its body, and learn whether a '
      + 'death claim has been filed on a stranger estate and whether it was approved. Estate ids '
      + 'travel in deep links and invitations; they are not secrets.',
    file: 'db/functions/estate_discovery_rpcs.sql',
    from: 'revoke execute on function public.estate_release_state(uuid) from public, anon, authenticated;',
    to: 'grant  execute on function public.estate_release_state(uuid) to authenticated;',
  },
  {
    id: 'hotfix-release-state-anon-granted',
    why: 'THE SAME HOLE WITHOUT A LOGIN. Granting the helper to `anon` makes a foreign estate claim '
      + 'state readable with no session at all — the worst reachable form of this defect.',
    file: 'db/functions/estate_discovery_rpcs.sql',
    from: 'revoke execute on function public.estate_release_state(uuid) from public, anon, authenticated;',
    to: 'revoke execute on function public.estate_release_state(uuid) from public, authenticated;\ngrant  execute on function public.estate_release_state(uuid) to anon;',
  },
  /**
   * ★ A MUTATION DELIBERATELY NOT WRITTEN, AND WHY. Two attempts to model "the lockdown breaks its
   * own consumer" both SURVIVED — revoking from `postgres`, and dropping SECURITY DEFINER from the
   * helper. Neither is a harness defect: `get_estate_discovery` is itself SECURITY DEFINER, so the
   * nested call resolves under the owner's identity regardless of what client roles hold, and
   * regardless of the helper's own security mode.
   *
   * That is not a coverage hole — it is the property that makes this hotfix safe, and forcing a
   * third variant until something finally failed would have been manufacturing a red result to
   * decorate the matrix. The consumer is asserted DIRECTLY instead:
   * `executor_workspace_authorization.sql` §7 calls `get_estate_discovery` through the product path
   * as a non-owner beneficiary and requires `release_state` to still resolve. That assertion fails
   * if the consumer ever does break, which is the guarantee the mutation was reaching for.
   */
  {
    id: 'p11f-same-reviewer-allowed',
    why: 'D1 IN ONE CHARACTER. Turning the two-person comparison into an inequality that can never '
      + 'fire lets the operator who verified the death authorize its release — one person, start to '
      + 'finish, which is the entire decision undone.',
    file: 'db/functions/release_safety.sql',
    from: "  if v_uid = v_reviewer_a then\n    raise exception 'two_person_rule_violated' using errcode = 'P0001';\n  end if;",
    to: "  if false then\n    raise exception 'two_person_rule_violated' using errcode = 'P0001';\n  end if;",
  },
  {
    id: 'p11f-reviewer-a-supplied-not-derived',
    why: 'D1 DEFEATED WITHOUT TOUCHING THE COMPARISON. Reading reviewer_a from the estate owner '
      + 'instead of the case decider means the check compares the admin against someone who never '
      + 'reviewed anything — the rule passes and one operator still released alone.',
    file: 'db/functions/release_safety.sql',
    from: "  select c.id, c.decided_by, c.decided_at into v_case, v_reviewer_a, v_verified",
    to: "  select c.id, public.estate_owner_user_id(p_estate), c.decided_at into v_case, v_reviewer_a, v_verified",
  },
  {
    id: 'p11f-two-person-constraint-dropped',
    target: 'npx',
    spec: 'test/deathVerificationFoundation.test.ts',
    why: 'THE WALL BEHIND THE DOOR (D1). Removing the table CHECK leaves the routine check standing '
      + 'and looks harmless — until any other writer, a future admin tool or a repair script, '
      + 'records a single-reviewer release that no code path refused.',
    file: 'db/migrations/0055_20260812_release_authorization.sql',
    from: "  constraint release_authorizations_two_person check (reviewer_a <> reviewer_b)",
    to: "  constraint release_authorizations_two_person check (reviewer_a is not null)",
  },
  {
    id: 'p11f-notification-optional',
    why: 'D4 MADE ADVISORY. Softening the unreachable-owner refusal to a queued row with no '
      + 'recipient starts a seven-day clock on a person nobody can reach — the exact population a '
      + 'false death process succeeds against.',
    file: 'db/functions/release_safety.sql',
    from: "  if v_recipient is null or btrim(v_recipient) = '' then\n    raise exception 'owner_channel_unreachable' using errcode = 'P0001';\n  end if;",
    to: "  if v_recipient is null or btrim(v_recipient) = '' then\n    v_recipient := 'unknown@invalid';\n  end if;",
  },
  {
    id: 'p11f-notification-failure-ignored',
    why: 'THE INVERTED EMITTER TRADE, RE-BROKEN AT THE IN-APP CHANNEL. Swallowing a failed emit — '
      + 'the default behaviour everywhere else, which is why this is the natural edit — dispatches '
      + 'a window on one channel while claiming two. Aimed at the STRUCTURAL audit deliberately: '
      + 'the happy path still commits a notice, so no runtime fixture separates this from correct '
      + 'code without breaking the catalog to force an emit failure.',
    target: 'npx',
    spec: 'test/deathVerificationFoundation.test.ts',
    file: 'db/functions/release_safety.sql',
    from: "  v_notice := public.emit_lifecycle_notification(\n    v_owner, p_estate, 'death_process.window_opened', 'afterworth://challenge');\n  if v_notice is null then\n    raise exception 'owner_notification_failed' using errcode = 'P0001';\n  end if;",
    to: "  v_notice := public.emit_lifecycle_notification(\n    v_owner, p_estate, 'death_process.window_opened', 'afterworth://challenge');\n  if v_notice is null then\n    v_notice := gen_random_uuid();\n  end if;",
  },
  {
    id: 'p11f-release-skips-dispatch-check',
    why: 'D4 AT THE RELEASE DOOR. Dropping the email-channel precondition lets an estate whose '
      + 'notice was cancelled — or never really addressed — elapse into disclosure anyway.',
    file: 'db/functions/release_safety.sql',
    from: "  if not exists (\n    select 1 from public.owner_notice_outbox o\n     where o.estate_id = p_estate and o.channel = 'email' and o.status <> 'cancelled'\n  ) then\n    raise exception 'owner_channel_unreachable' using errcode = 'P0001';\n  end if;\n\n  select c.id, c.decided_by, c.decided_at into v_case, v_reviewer_a, v_verified",
    to: "  select c.id, c.decided_by, c.decided_at into v_case, v_reviewer_a, v_verified",
  },
  {
    id: 'p11f-window-opens-without-dispatch',
    target: 'npx',
    spec: 'test/deathVerificationFoundation.test.ts',
    why: 'THE DELETED EDGE, RESTORED (D2). Re-adding death_verified -> challenge_window lets a '
      + 'window open on an owner who was never told, and it reads like restoring a transition '
      + 'somebody removed by mistake. The map audit must object.',
    file: 'db/functions/death_verification.sql',
    from: "    or (v_from = 'death_verified'             and p_to = 'owner_notification_dispatched')",
    to: "    or (v_from = 'death_verified'             and p_to = 'owner_notification_dispatched')\n    or (v_from = 'death_verified'             and p_to = 'challenge_window')",
  },
  {
    id: 'p11f-window-duration-shortened',
    why: 'D2 IS SEVEN DAYS, NOT SEVEN HOURS. A shortened window is the edit that looks like a '
      + 'configuration tweak and is actually a decision about how long a living owner has to notice '
      + 'and object.',
    file: 'db/migrations/0055_20260812_release_authorization.sql',
    from: "values (true, interval '7 days')",
    to: "values (true, interval '7 hours')",
  },
  {
    id: 'p11f-age-gate-removed',
    why: 'STAGE 3: A STALE SAFETY NOTICE MUST NOT BE SENT. Aimed at the STALE-MARKING update, which '
      + 'is the load-bearing layer: the claim SELECT carries the same bound as defence in depth, so '
      + 'mutating THAT proved nothing — the marking pass settled the row either way, one layer '
      + 'masking the other. Widening the marking bound lets a month-old notice stay queued and go '
      + 'out describing a window that closed weeks ago.',
    file: 'db/functions/outbox_safety.sql',
    from: "   where o.status in ('queued', 'processing')\n     and o.requested_at < now() - v_gate;",
    to: "   where o.status in ('queued', 'processing')\n     and o.requested_at < now() - interval '100 years';",
  },
  {
    id: 'p11f-purge-writes-no-audit',
    why: 'STAGE 3: NEVER SILENTLY DELETE. Moving the audit insert after the delete makes it a step '
      + 'a failure can skip — rows gone, no record of who removed them or why. The purge assertions '
      + 'require the audit row to exist alongside the deletion.',
    file: 'db/functions/outbox_safety.sql',
    from: "  insert into public.outbox_purge_audit\n    (outbox_name, actor_id, row_count, oldest_row_at, newest_row_at, reason)\n  values (p_outbox, v_uid, v_count, v_oldest, v_newest, p_reason)\n  returning id into v_audit;",
    to: "  v_audit := gen_random_uuid();",
  },
  {
    id: 'p11f-purge-takes-inflight-rows',
    why: 'AN IN-FLIGHT SAFETY MESSAGE IS NOT HOUSEKEEPING. Widening the purge to queued rows deletes '
      + 'an owner\'s warning while it is still on its way to them.',
    file: 'db/functions/outbox_safety.sql',
    from: "  delete from public.owner_notice_outbox\n   where status in ('dispatched', 'failedPermanent', 'cancelled')\n     and requested_at < p_before;",
    to: "  delete from public.owner_notice_outbox\n   where requested_at < p_before;",
  },
  {
    id: 'p11f-release-manufactures-membership',
    why: 'D5 — RELEASE UNLOCKS OWNER-AUTHORED INTENT AND NOTHING ELSE. Materializing a membership '
      + 'for the case initiator at the moment of release makes the release event an identity '
      + 'writer; the authority bracket must object.',
    file: 'db/functions/release_safety.sql',
    from: "  update public.estate_lifecycle\n     set released_at = now()\n   where estate_id = p_estate;",
    to: "  update public.estate_lifecycle\n     set released_at = now()\n   where estate_id = p_estate;\n  insert into public.estate_memberships (estate_id, user_id, role, status)\n  select p_estate, c.initiated_by, 'beneficiary', 'approved'\n    from public.death_verification_cases c where c.id = v_case;",
  },
  {
    id: 'p11f-release-elevates-tier',
    why: 'D5 AT THE TIER. Raising existing grants during release rewrites owner-authored disclosure '
      + 'at the one moment nobody can take it back.',
    file: 'db/functions/release_safety.sql',
    from: "  perform public.apply_estate_lifecycle_transition(\n    p_estate, 'released', v_case, 'two_person_release');",
    to: "  perform public.apply_estate_lifecycle_transition(\n    p_estate, 'released', v_case, 'two_person_release');\n  update public.access_grants set visibility_tier = 'full_detail' where estate_id = p_estate;",
  },
  {
    id: 'p11f-audit-reason-optional',
    why: 'STAGE 5: THE AUDIT REASON IS THE RECONSTRUCTABLE PART. Accepting a blank reason leaves the '
      + 'release record technically complete and forensically useless a year later, when someone is '
      + 'asking why this estate was opened.',
    file: 'db/functions/release_safety.sql',
    from: "  if p_reason is null or btrim(p_reason) = '' then\n    raise exception 'audit_reason_required' using errcode = 'P0001';\n  end if;",
    to: "  if false then\n    raise exception 'audit_reason_required' using errcode = 'P0001';\n  end if;",
  },
  {
    id: 'p11f-dispatched-state-satisfies-death',
    why: 'THE SEVENTH STATE MUST DISCLOSE NOTHING. Telling the owner is not telling everyone else — '
      + 'admitting owner_notification_dispatched into the death arm would disclose at the exact '
      + 'moment the owner has only just been warned.',
    file: 'db/functions/release_conditions.sql',
    from: "        or (p_release_condition = 'after_verified_death'\n            and p_lifecycle_state = 'released')",
    to: "        or (p_release_condition = 'after_verified_death'\n            and p_lifecycle_state in ('released', 'owner_notification_dispatched'))",
  },
  {
    id: 'p11e-release-lever-granted-to-clients',
    why: 'AN INTERNAL DELIVERY ROUTINE IS NOT A CLIENT SURFACE. Re-anchored in 11-F: the one-person '
      + '`release_estate` lever no longer exists, so the equivalent mistake is granting EXECUTE on '
      + 'the internal owner-notice claim routine — which hands every signed-in account the ability '
      + 'to drain, and therefore to settle, another owner\'s safety notices.',
    file: 'db/functions/outbox_safety.sql',
    from: "revoke execute on function public.claim_owner_notices(int) from public, anon, authenticated;",
    to: "grant execute on function public.claim_owner_notices(int) to authenticated;",
  },

  /* ══ PHASE 11-L · the halt notification to the initiating fiduciary ═══════════════════════════ */
  {
    id: 'p11l-halt-notification-omitted',
    why: 'THE PHASE, DELETED. A halt that tells nobody leaves the fiduciary who started the process '
      + 'watching a workflow that has silently stopped, with no signal that it did. They would '
      + 'reasonably conclude the product is broken and try again.\n'
      + '      ★ EXPRESSED AS AN UNREACHABLE GUARD RATHER THAN A DELETED CALL, AND THAT IS THE '
      + 'POINT. Deleting the `perform` outright removes the string `death_process.halted` from '
      + 'release_safety.sql, which the bundle\'s own absence control pins — so the first version of '
      + 'this mutation died at BUILD time with HARNESS_FAILURE and proved nothing about whether the '
      + 'SQL suite can see a missing notification. Same shape as '
      + '`p11b-legacy-fused-becomes-writable`, and as the two 11-K grant controls. `if false` keeps '
      + 'the artifact intact and the emission unreachable, so the RUNTIME layer is what is on trial. '
      + 'The build control still fails on a genuinely absent phase; that is a different question and '
      + 'it keeps its own answer.',
    file: 'db/functions/release_safety.sql',
    from: "  if v_initiator is not null and v_initiator <> v_uid then\n    perform public.emit_lifecycle_notification(",
    to: "  if false then\n    perform public.emit_lifecycle_notification(",
  },
  {
    id: 'p11l-notification-precedes-the-halt',
    why: 'EMISSION LIFTED ABOVE THE STATE CHECKS, so a REFUSED halt notifies anyway. The initiating '
      + 'fiduciary is told their process stopped while it is still running — and on an `active` '
      + 'estate, where no process exists at all. A notification must never describe a transition '
      + 'that did not happen.',
    file: 'db/functions/release_safety.sql',
    from: "  if v_state = 'challenge_halted' then\n    return 'challenge_halted'; -- idempotent replay: no re-stamp, no re-audit\n  end if;",
    to: "  perform public.emit_lifecycle_notification(\n    (select initiated_by from public.death_verification_cases where estate_id = p_estate limit 1),\n    p_estate, 'death_process.halted', null);\n  if v_state = 'challenge_halted' then\n    return 'challenge_halted';\n  end if;",
  },
  {
    id: 'p11l-wrong-fiduciary-notified',
    why: 'THE RECIPIENT, TAKEN FROM THE WRONG CASE. Notifying some other estate\'s initiator tells '
      + 'a stranger that a death process exists and has halted — a death-process oracle aimed at '
      + 'someone with no relationship to the estate at all — while the person actually owed the '
      + 'message gets nothing.',
    file: 'db/functions/release_safety.sql',
    from: "      v_initiator, p_estate, 'death_process.halted', null);",
    to: "      (select initiated_by from public.death_verification_cases\n        where estate_id <> p_estate order by created_at limit 1),\n      p_estate, 'death_process.halted', null);",
  },
  {
    id: 'p11l-owner-also-notified',
    why: 'CLAIMANT-FACING COPY SENT TO THE OWNER. "The estate process you initiated has been '
      + 'halted" is addressed to the person who STARTED the process. Sent to the owner who just '
      + 'stopped it, it reads as a stranger narrating their own death process back to them.',
    file: 'db/functions/release_safety.sql',
    from: "    perform public.emit_lifecycle_notification(\n      v_initiator, p_estate, 'death_process.halted', null);",
    to: "    perform public.emit_lifecycle_notification(\n      v_initiator, p_estate, 'death_process.halted', null);\n    perform public.emit_lifecycle_notification(\n      v_uid, p_estate, 'death_process.halted', null);",
  },
  {
    id: 'p11l-owner-exclusion-guard-removed',
    why: 'THE GUARD ITSELF. Only observable on an estate whose owner is ALSO the designated '
      + 'initiator, which §7 builds deliberately (estate S) — on every other fixture the initiator '
      + 'is not the owner and deleting this comparison changes nothing. A control that cannot fail '
      + 'is not a control, so the fixture exists to make this one fail.',
    file: 'db/functions/release_safety.sql',
    from: "  if v_initiator is not null and v_initiator <> v_uid then",
    to: "  if v_initiator is not null then",
  },
  {
    id: 'p11l-duplicate-on-idempotent-replay',
    why: 'THE REPLAY GUARD, REMOVED TOGETHER WITH THE STATUS SCOPE — both are needed to actually '
      + 'produce a duplicate, which is why this is one compound edit rather than two. A second '
      + 'challenge then re-halts an already-halted case and emits again, telling the fiduciary '
      + 'twice that a process stopped once. Repeated notifications about a death process read as '
      + 'repeated events.',
    file: 'db/functions/release_safety.sql',
    from: "  if v_state = 'challenge_halted' then\n    return 'challenge_halted'; -- idempotent replay: no re-stamp, no re-audit\n  end if;",
    to: "  if v_state = 'challenge_halted' then\n    update public.death_verification_cases\n       set status = 'halted', updated_at = now()\n     where estate_id = p_estate and status = 'halted'\n    returning initiated_by into v_initiator;\n    if v_initiator is not null then\n      perform public.emit_lifecycle_notification(\n        v_initiator, p_estate, 'death_process.halted', null);\n    end if;\n    return 'challenge_halted';\n  end if;",
  },
  {
    id: 'p11l-copy-reveals-owner-channel',
    why: 'THE COPY DISCLOSING HOW THE OWNER ANSWERED. Naming the channel tells a possibly-hostile '
      + 'claimant which address or device reached a living owner — provenance about a person the '
      + 'challenge window exists to protect, handed to the one party with a motive to use it.',
    file: 'db/functions/lifecycle_notification_rpcs.sql',
    from: "     'The estate process you initiated has been halted.')",
    to: "     'The estate process you initiated has been halted by the owner via email.')",
  },
  {
    id: 'p11l-copy-reveals-reason',
    why: 'THE COPY EXPLAINING WHY. A reason is either a disclosure about the owner\'s state of mind '
      + 'or an accusation against the recipient, and this routine cannot tell a good-faith '
      + 'claimant from a bad-faith one — so it must say the same sentence to both.',
    file: 'db/functions/lifecycle_notification_rpcs.sql',
    from: "     'The estate process you initiated has been halted.')",
    to: "     'The estate process you initiated has been halted because the evidence was rejected.')",
  },
  {
    id: 'p11l-freeform-copy-bypasses-catalog',
    why: 'TEXT COMPOSED AT THE EMISSION SITE. The catalog is the ONLY place notification copy '
      + 'exists precisely so disclosure review has one file to read. A caller that composes its own '
      + 'string moves user-facing copy — and every disclosure decision in it — out of review.',
    file: 'db/functions/release_safety.sql',
    from: "    perform public.emit_lifecycle_notification(\n      v_initiator, p_estate, 'death_process.halted', null);",
    to: "    perform public.emit_notification(\n      v_initiator, p_estate, 'claimUpdate', 'Estate process halted',\n      'The owner challenged your claim on this estate.', null, '{}'::jsonb);",
  },
  {
    id: 'p11l-deep-link-attached',
    why: 'A ROUTE THAT DOES NOT EXIST IN THE CLIENT ALLOWLIST. `afterworth://executor` resolves to '
      + 'null in `features/notifications/actions.ts`, so this cannot navigate — but shipping it '
      + 'asserts a destination the product has not wired, and the next person to add the allowlist '
      + 'entry would wire it without re-examining whether a halted claimant should be sent there.',
    file: 'db/functions/release_safety.sql',
    from: "      v_initiator, p_estate, 'death_process.halted', null);",
    to: "      v_initiator, p_estate, 'death_process.halted', 'afterworth://executor');",
  },
  {
    id: 'p11l-unrelated-estate-notified',
    why: 'THE ESTATE SCOPE, DROPPED. One owner\'s challenge then halts EVERY open case in the '
      + 'product and notifies every initiator — mass disclosure plus mass corruption of unrelated '
      + 'workflows, from a single authorized action on a single estate.',
    file: 'db/functions/release_safety.sql',
    from: "   where estate_id = p_estate and status in ('open', 'verified')\n  returning initiated_by into v_initiator;",
    to: "   where status in ('open', 'verified')\n  returning initiated_by into v_initiator;",
  },

  /* ══ PHASE 11-NR · the settlement predicate — the Branch A production defect ═══════════════════ */
  {
    /**
     * ★ THE EXACT REGRESSION. This is the pre-11-NR source, character for character, and it is the
     * defect the Branch A production fire drill measured on a real estate: lifecycle
     * challenge_halted, case row still 'verified', v_initiator NULL, zero halt notifications, and
     * the settled case still answering the operator's `verified` filter.
     *
     * ★ IT MUST BE KILLED BY §8 AND NOT BY §7. §7 halts from `death_verification_pending`, where the
     * case IS 'open' — this mutation is invisible there, which is precisely why the defect shipped
     * green and survived a whole phase sign-off.
     */
    id: 'p11nr-settlement-narrowed-to-open',
    why: 'THE BRANCH A DEFECT, RESTORED. `status = \'open\'` is the case status at exactly ONE of the '
      + 'four lifecycle states the owner challenge is reachable from. On every operator-driven '
      + 'process — verify → dispatch → window → challenge — the case is \'verified\', the UPDATE '
      + 'matches nothing, and the entire Phase 11-L halt notification is silently never emitted. The '
      + 'estate halts while its case row and the operator queue both still say a death verification '
      + 'is standing.',
    file: 'db/functions/release_safety.sql',
    from: "   where estate_id = p_estate and status in ('open', 'verified')",
    to: "   where estate_id = p_estate and status = 'open'",
  },
  {
    /**
     * ★ THE OPPOSITE ERROR, AND THE REASON THE SET IS CLOSED RATHER THAN "ANY ROW". The obvious
     * over-correction for the mutation above is to stop filtering on status at all. §8 carries a
     * REJECTED historical case on the same estate, initiated by a different fiduciary, so this edit
     * overwrites an operator adjudication that really happened AND makes two rows eligible to supply
     * the recipient — which `into` then chooses between arbitrarily.
     */
    id: 'p11nr-settlement-widened-to-every-case',
    why: 'THE SETTLEMENT SET, OPENED. Halting now overwrites REJECTED and CANCELLED historical cases '
      + 'on the same estate — destroying the record that an operator rejected a prior claim, or that '
      + 'a fiduciary withdrew one — and lets more than one row satisfy the RETURNING, so the '
      + 'notification recipient becomes whichever row the executor happened to reach first.',
    file: 'db/functions/release_safety.sql',
    from: "   where estate_id = p_estate and status in ('open', 'verified')",
    to: '   where estate_id = p_estate and status is not null',
  },
  {
    /**
     * ★ PROVENANCE RECOVERED BY A SECOND LOOKUP INSTEAD OF FROM THE TRANSITION. This is the shape
     * the routine's own comment forbids, and §8 is the fixture that can finally see it: the estate
     * carries an older REJECTED case whose initiator is a DIFFERENT person, and `order by created_at`
     * reaches that one first. The halt then tells the wrong fiduciary their process stopped.
     */
    id: 'p11nr-recipient-from-a-later-select',
    why: 'THE RECIPIENT, RE-DERIVED AFTER THE FACT. A SELECT that runs beside the UPDATE rather than '
      + 'inside it can name a case this call did not settle — here, a prior REJECTED attempt by a '
      + 'different fiduciary. The person owed the message gets nothing and a stranger to this '
      + 'process is told a death process concerning them has halted.',
    file: 'db/functions/release_safety.sql',
    from: "   where estate_id = p_estate and status in ('open', 'verified')\n  returning initiated_by into v_initiator;",
    to: "   where estate_id = p_estate and status in ('open', 'verified');\n  select initiated_by into v_initiator from public.death_verification_cases\n   where estate_id = p_estate order by created_at limit 1;",
  },
  {
    /**
     * ★ THE LIFECYCLE MOVES AND THE CASE DOES NOT — the divergence itself, injected directly rather
     * than as a side effect of the predicate. The notification still fires (the row still matches,
     * so RETURNING still yields the initiator), which is what makes this distinct from the narrowing
     * above: it isolates the CASE-CLASSIFICATION half of the defect from the NOTIFICATION half.
     */
    id: 'p11nr-case-status-not-settled',
    why: 'THE CASE IS NEVER SETTLED. The lifecycle reaches challenge_halted while the case row keeps '
      + 'whatever status it had, so the operator queue continues to present a halted estate as live '
      + 'verification work and a `halted` filter can never find it — the exact operational '
      + 'consequence measured on the Branch A drill estate.',
    file: 'db/functions/release_safety.sql',
    from: "     set status = 'halted', updated_at = now()",
    to: '     set updated_at = now()',
  },
  {
    /**
     * ★ THE REPLAY GUARD NEUTERED FROM THE INSIDE, AND THE SHAPE IS DELIBERATE. The obvious edit —
     * replacing the `if` line with `if false` — is refused at BUILD time, because
     * `buildHaltNotificationBundle.mjs` pins `if v_state = 'challenge_halted' then` as a standing
     * artifact control. A mutation that dies there proves only that the builder is watching, which
     * is the one thing this harness must never accept as evidence (the `p11b-legacy-fused` lesson,
     * and the four 11-L needles removed for exactly this reason).
     *
     * So the pinned line is left EXACTLY as it is and the RETURN inside it becomes a no-op. The
     * artifact still contains everything the builder asserts; the behaviour is gone; the runtime
     * layer is what votes. Replay then falls through to a challenge_halted → challenge_halted
     * transition, which the closed map has no edge for, so the owner's second halt RAISES.
     */
    id: 'p11nr-idempotent-replay-guard-neutered',
    why: 'THE REPLAY GUARD, MADE UNREACHABLE FROM THE INSIDE. A second owner challenge stops '
      + 'returning cleanly and falls into a transition the map does not have, so it raises. An owner '
      + 'who taps halt twice — or whose client retries — is told their protective action failed on a '
      + 'process that has in fact already been halted, which is the one message this surface must '
      + 'never send.',
    file: 'db/functions/release_safety.sql',
    from: "    return 'challenge_halted'; -- idempotent replay: no re-stamp, no re-audit",
    to: '    null; -- mutation: the replay falls through instead of returning',
  },

  /* ══ PHASE 11-OBR · OB-1 claim visibility + OB-4 the settle audit ═════════════════════════════ */
  {
    /**
     * ★ THE PRODUCTION DEFECT, RESTORED. This is the pre-OB-1 claim set, character for character.
     * It is killed by §9's crash-window case and by nothing else in the suite — every other outbox
     * assertion works on `queued` rows, which is exactly why the defect shipped.
     */
    id: 'p11obr-reclaim-removed',
    why: 'THE BRANCH A DEFECT, RESTORED. Claiming only `queued` rows means a notice whose worker '
      + 'died between claim and settle is never handed out again. The owner\'s single independent '
      + 'warning that their estate is being released is lost silently, and the only remaining '
      + 'transition marks it failed a DAY AFTER the release window it protects has elapsed.',
    file: 'db/functions/outbox_safety.sql',
    from: "       and (\n         -- A · the ordinary queue\n         (o.status = 'queued'\n          and (o.next_attempt_at is null or o.next_attempt_at <= now()))\n         -- B · an abandoned claim\n         or (o.status = 'processing'\n             and (o.claimed_at is null or o.claimed_at < now() - v_visibility))\n       )",
    to: "       and o.status = 'queued'\n       and (o.next_attempt_at is null or o.next_attempt_at <= now())",
  },
  {
    id: 'p11obr-claimed-at-not-stamped',
    why: 'THE CLAIM CLOCK, NEVER STARTED. Without the stamp every reclaimed row keeps a NULL '
      + 'claimed_at, which the contract reads as infinitely stale — so the row becomes eligible '
      + 'again on the very next drain and the owner is mailed once per drain until the age gate.',
    file: 'db/functions/outbox_safety.sql',
    from: '         claimed_at = now()',
    to: '         claimed_at = o.claimed_at',
  },
  {
    id: 'p11obr-timeout-predicate-removed',
    why: 'THE VISIBILITY TIMEOUT, DELETED. Every `processing` row becomes claimable immediately, so '
      + 'a second drain reclaims a notice a LIVE worker is still sending — manufacturing exactly the '
      + 'duplicate mail about a living owner\'s death process that this module exists to avoid.',
    file: 'db/functions/outbox_safety.sql',
    from: "         or (o.status = 'processing'\n             and (o.claimed_at is null or o.claimed_at < now() - v_visibility))",
    to: "         or o.status = 'processing'",
  },
  {
    id: 'p11obr-timeout-direction-reversed',
    why: 'THE COMPARISON, INVERTED. Fresh claims are reclaimed and genuinely abandoned ones are not '
      + '— the worst of both: duplicates for live work, permanent strands for dead work. A reversed '
      + 'inequality is the single most likely typo in this predicate, which is why it is on trial.',
    file: 'db/functions/outbox_safety.sql',
    from: 'o.claimed_at < now() - v_visibility',
    to: 'o.claimed_at > now() - v_visibility',
  },
  {
    id: 'p11obr-attempts-not-incremented',
    why: 'THE ATTEMPT COUNTER, FROZEN ON RECLAIM. `record_owner_notice_outcome` gives up after three '
      + 'attempts; a reclaim that does not count means the cap can never be reached, so a '
      + 'permanently undeliverable notice is retried every drain until the age gate instead of '
      + 'settling as failed.',
    file: 'db/functions/outbox_safety.sql',
    from: '         attempts   = o.attempts + 1,',
    to: '         attempts   = o.attempts,',
  },
  {
    id: 'p11obr-settled-row-reclaimed',
    why: 'A SETTLED NOTICE, MADE RE-SENDABLE. `outcomeUncertain` and `dispatched` are terminal '
      + 'precisely because the message may already be in the owner\'s inbox. Admitting them to the '
      + 'claim set sends a second copy of a notice about someone\'s own death on the strength of a '
      + 'lost HTTP response — the exact trade 11-K refused to make.',
    file: 'db/functions/outbox_safety.sql',
    from: "         (o.status = 'queued'\n          and (o.next_attempt_at is null or o.next_attempt_at <= now()))",
    to: "         (o.status in ('queued', 'outcomeUncertain', 'failedPermanent')\n          and (o.next_attempt_at is null or o.next_attempt_at <= now()))",
  },
  {
    /**
     * ★ OB-4, CAUGHT BY THE MIGRATION'S OWN EXECUTION PROBE. Narrowing the vocabulary back to three
     * values is refused by 0057's probe, which does not read the constraint text — it INSERTS a
     * worker-sourced row and catches `check_violation`. That is a database-layer detection, not a
     * static one: the regression is caught by the same mechanism that would catch it at paste time
     * against production, which is where it matters most.
     *
     * It is deliberately NOT the only voter. `p11obr-settle-audit-source-unwritable` below reaches
     * the same defect by a route the migration cannot see, so the RUNTIME assertion in §9 has to
     * carry it alone — the two together stop either layer from taking the credit for the other.
     */
    id: 'p11obr-audit-source-narrowed',
    why: 'THE ROOT CAUSE OF THE BRANCH A STRAND, RESTORED. `record_owner_notice_outcome` writes '
      + '`source = \'worker\'`; with the constraint back at three values that insert raises '
      + 'check_violation on EVERY call, the drain swallows the error, and every claimed owner notice '
      + 'strands in `processing` forever. The delivery pipeline cannot settle anything at all.',
    file: 'db/migrations/0057_20260816_owner_notice_claim_visibility.sql',
    from: "  check (source in ('server', 'ios_forward', 'admin', 'worker'));",
    to: "  check (source in ('server', 'ios_forward', 'admin'));",
  },
  {
    /**
     * ★ THE SAME DEFECT, BY A ROUTE THE MIGRATION CANNOT SEE — so §9 is the sole voter.
     *
     * The constraint keeps all four values and 0057's probe still inserts `'worker'` successfully,
     * so the migration passes cleanly. What changes is the value the SETTLE writes: `'cron'`, which
     * the constraint refuses. The failure is therefore invisible to every static and migration-time
     * check and shows up only where the production defect showed up — a notice that cannot settle.
     */
    id: 'p11obr-settle-audit-source-unwritable',
    why: 'THE SETTLE WRITES AN UNSTORABLE AUDIT SOURCE. Exactly the Branch A failure with a '
      + 'different spelling: record_owner_notice_outcome raises check_violation on its final '
      + 'statement, drain.ts swallows the RPC error, and the notice strands in `processing` with '
      + 'attempts incremented and nothing recorded. The owner is never confirmed reached.',
    file: 'db/functions/outbox_safety.sql',
    from: "          'worker');",
    to: "          'cron');",
  },

  /* ══ PHASE 11-MB · fiduciary estate discovery ═════════════════════════════════════════════════ */
  {
    id: 'p11mb-discovery-enumerates-other-users',
    why: 'THE ROUTINE BECOMES A MAP OF WHO IS EXECUTOR OF WHAT. Dropping the auth.uid() predicate lets '
      + 'any authenticated caller enumerate every fiduciary relationship in the product — a question '
      + 'this product refuses everywhere else, answered in one call.',
    file: 'db/functions/fiduciary_estate_discovery.sql',
    from: "   where d.user_id = auth.uid()\n     and d.status = 'active'",
    to: "   where d.status = 'active'",
  },
  {
    id: 'p11mb-revoked-designation-enumerated',
    why: 'A REVOKED FIDUCIARY KEEPS THE ESTATE IN THEIR SELECTOR. Their workspace correctly refuses, so '
      + 'the estate would appear and then answer "not available" — and worse, an owner who revoked a '
      + 'designee to stop them would still see them holding the estate in their list.',
    file: 'db/functions/fiduciary_estate_discovery.sql',
    from: "     and d.status = 'active'\n     and d.designation_type in ('executor', 'trustee')",
    to: "     and d.designation_type in ('executor', 'trustee')",
  },
  {
    id: 'p11mb-discovery-leaks-estate-contents',
    why: 'DISCOVERY BECOMES DISCLOSURE. Adding an asset count tells a fiduciary — who holds NO grant, '
      + 'no tier and no membership — how much is in the estate. That is the precise line this routine '
      + 'exists on the safe side of, and a count is disclosure just as much as a value is.',
    file: 'db/functions/fiduciary_estate_discovery.sql',
    from: "  select d.estate_id,\n         e.name,\n         min(d.designation_type)",
    to: "  select d.estate_id,\n         e.name,\n         min(d.designation_type) || ' · assets=' || (select count(*) from public.normalized_assets na where na.estate_id = d.estate_id)::text",
  },
  {
    id: 'p11mb-discovery-granted-to-anon',
    why: 'THE FIRST OF TWO REFUSAL LAYERS, REMOVED. auth.uid() is NULL for anon so the predicate still '
      + 'matches nothing — which is exactly why the grant must be asserted SEPARATELY. A widened grant '
      + 'with an intact predicate leaks nothing today and everything the day the predicate changes.\n'
      + '      ★ EXPRESSED AS AN ADDITIVE GRANT, not a replaced revoke, so the artifact control still '
      + 'finds both privilege lines and the mutation reaches Postgres. A later widening is also the '
      + 'more realistic shape of this defect than someone deleting the revoke.',
    file: 'db/functions/fiduciary_estate_discovery.sql',
    from: "grant  execute on function public.get_my_fiduciary_estates() to authenticated;",
    to: "grant  execute on function public.get_my_fiduciary_estates() to authenticated;\ngrant  execute on function public.get_my_fiduciary_estates() to anon;",
  },
  {
    id: 'p11mb-dual-capacity-duplicates-estate',
    why: 'ONE ESTATE, TWO SELECTOR ROWS. A person holding executor AND trustee on one estate is '
      + 'representable (the unique index is per designation_type), so without the aggregate the estate '
      + 'is listed twice — two rows, two cache keys, two accessibility announcements for one estate.',
    file: 'db/functions/fiduciary_estate_discovery.sql',
    from: "   group by d.estate_id, e.name;",
    to: ";",
  },

  /* ══ PHASE 11-MC · fiduciary provisioning creates no disclosure class ═════════════════════════ */
  {
    id: 'p11mc-executor-forces-beneficiary-again',
    why: 'THE DEFECT, RESTORED. Every new executor and trustee silently receives an approved beneficiary '
      + 'membership — workflow capacity manufacturing a disclosure class, which is the entire authority '
      + 'model this phase exists to separate.',
    file: 'db/functions/provision_from_invitation.sql',
    from: "  v_is_fiduciary := coalesce(v_inv.kind in ('executor', 'trustee'), false);",
    to: '  v_is_fiduciary := false;',
  },
  {
    id: 'p11mc-trustee-still-forces-beneficiary',
    why: 'HALF THE DEFECT, RESTORED — and the half a reviewer is least likely to check. Executor is '
      + 'corrected and trustee is not, so the two fiduciary capacities diverge in what they grant the '
      + 'recipient while every executor-shaped test stays green.',
    file: 'db/functions/provision_from_invitation.sql',
    from: "coalesce(v_inv.kind in ('executor', 'trustee'), false)",
    to: "coalesce(v_inv.kind in ('executor'), false)",
  },
  {
    id: 'p11mc-null-kind-skips-membership',
    why: 'THE NULL-SAFETY REMOVED. `NULL in (...)` is NULL, so `not v_is_fiduciary` becomes `not NULL` '
      + 'and an ORDINARY beneficiary acceptance provisions nothing at all. Production declares '
      + '`invitations.kind` NOT NULL, but the conservative default for an unrecognised invitation must be '
      + 'the path that existed before this change — never the one that creates no membership.',
    file: 'db/functions/provision_from_invitation.sql',
    from: "coalesce(v_inv.kind in ('executor', 'trustee'), false)",
    to: "v_inv.kind in ('executor', 'trustee')",
  },
  {
    id: 'p11mc-designation-not-stamped',
    why: 'THE OTHER HALF OF THE CORRECTION, DELETED. Removing the membership side effect AND the '
      + 'designation leaves a fiduciary with NEITHER authority — strictly worse than the defect, because '
      + 'the recipient now has no route to the workflow at all and nothing says so.',
    file: 'db/functions/provision_from_invitation.sql',
    from: "  if v_inv.kind in ('executor','trustee') then\n    v_desig_id := null;",
    to: "  if false then\n    v_desig_id := null;",
  },
  {
    id: 'p11mc-fiduciary-replaces-existing-membership',
    why: 'AN INDEPENDENTLY-HELD ACCESS CLASS OVERWRITTEN. A person who is already a professional '
      + 'delegate accepts an executor invitation and is silently downgraded to beneficiary — authority '
      + 'laundering between two axes that are supposed to compose, not replace.',
    file: 'db/functions/provision_from_invitation.sql',
    from: "    select em.id into v_membership_id from public.estate_memberships em\n     where em.estate_id = v_inv.estate_id and em.user_id = p_user;\n  end if;",
    to: "    update public.estate_memberships set role = v_inv.proposed_role\n     where estate_id = v_inv.estate_id and user_id = p_user\n    returning id into v_membership_id;\n  end if;",
  },
  {
    id: 'p11mc-provenance-lost',
    why: 'THE PROVENANCE THAT MAKES LEGACY CLEANUP POSSIBLE. `source_invitation_id` is the only way to '
      + 'tell a mechanically-manufactured beneficiary membership from an independently intended one. '
      + 'Losing it on the designation removes the audit trail for which invitation granted the capacity.',
    file: 'db/functions/provision_from_invitation.sql',
    from: '      (estate_id, user_id, designation_type, status, source_invitation_id, granted_by)',
    to: '      (estate_id, user_id, designation_type, status, granted_by)',
  },
  /* ── §11-MF · the cancel handle and the advisory-list scoping ──────────────────────────────── */
  {
    id: 'mf-cancel-refused-to-initiator-only-undone',
    why: 'The over-promise restored: attach and cancel emitted as ONE literal again. They do not '
      + 'share a gate — attach needs any active executor, cancel needs initiated_by = auth.uid() — '
      + 'so a co-fiduciary is offered a cancel the door refuses. Requires the TWO-executor fixture; '
      + 'with one executor the initiator IS every executor and this survives.',
    file: 'db/functions/executor_workspace.sql',
    from: "  if v_case_state = 'open' and v_is_initiator then\n    v_actions := v_actions || '[\"cancel_verification\"]'::jsonb;\n  end if;",
    to: "  if v_case_state = 'open' then\n    v_actions := v_actions || '[\"cancel_verification\"]'::jsonb;\n  end if;",
  },
  {
    id: 'mf-case-handle-unscoped',
    why: 'The case handle published to every executor rather than the one who can use it. Proves the '
      + 'scoping is asserted, not incidental.',
    file: 'db/functions/executor_workspace.sql',
    from: "      'case_id',        case when v_is_initiator then v_case.case_id else null end,",
    to: "      'case_id',        v_case.case_id,",
  },
  {
    id: 'mf-case-handle-withheld',
    why: 'The defect itself: the workspace answers questions about a case without naming it, so '
      + 'cancel_death_verification_case(p_case) is unreachable from any read and an initiator who '
      + 'restarts the app can never cancel. Killed by the assertion that cancels using the '
      + 'WORKSPACE-published handle rather than initiate\'s return value.',
    file: 'db/functions/executor_workspace.sql',
    from: "      'case_id',        case when v_is_initiator then v_case.case_id else null end,",
    to: "      'case_id',        null,",
  },
  {
    id: 'mf-is-initiator-fails-open',
    why: 'Absence read as authority: no case becomes "you initiated it". A fail-open default on a '
      + 'caller-scoped authority fact is how a cancel affordance appears for a process that does '
      + 'not exist.',
    file: 'db/functions/executor_workspace.sql',
    from: '  v_is_initiator := coalesce(v_case.is_initiator, false);',
    to: '  v_is_initiator := coalesce(v_case.is_initiator, true);',
  },
]);

const only = process.argv.includes('--only') ? process.argv[process.argv.indexOf('--only') + 1] : null;
const selected = only ? MUTATIONS.filter((m) => m.id === only) : MUTATIONS;
if (selected.length === 0) {
  console.error(`✗ CANNOT RUN — no mutation named "${only}". Known: ${MUTATIONS.map((m) => m.id).join(', ')}`);
  process.exit(2);
}

function git(args, cwd = ROOT) {
  return execFileSync('git', args, { cwd, encoding: 'utf8' }).trim();
}

/**
 * The same call WITHOUT `.trim()`, for output whose trailing whitespace is load-bearing.
 *
 * ★ TRIMMING A PATCH CORRUPTS IT, INTERMITTENTLY, WHICH IS THE WORST KIND. A unified diff represents
 * an unchanged blank line as a context line containing exactly ONE SPACE. When the last line of the
 * working diff is such a line, `.trim()` deletes it, the final hunk is then one line shorter than
 * its `@@` header promises, and `git apply` reports `corrupt patch at line N`. The mobile repo's
 * `scripts/mutate.js` carries the same note for the same reason — it worked for months and then
 * failed on a diff that merely added an exported keyword.
 */
function gitRaw(args, cwd = ROOT) {
  return execFileSync('git', args, { cwd, encoding: 'utf8' });
}

/** The working tree's state, captured before and compared after — the anti-collateral-damage check. */
const treeBefore = git(['status', '--porcelain']);

/**
 * ★ THE WORKTREE IS SEEDED WITH THE WORKING STATE, NOT WITH HEAD.
 *
 * A worktree at bare HEAD tests the last commit, which is exactly the code you are NOT trying to
 * validate: the whole point of running mutations is to check work that is still in progress. The
 * first run of this harness against Phase 10-E did precisely that and reported eleven
 * HARNESS_FAILUREs whose real cause was `ENOENT` on files that existed in the developer's checkout
 * and not in the commit.
 *
 * That failure mode is instructive rather than embarrassing: it failed LOUDLY, as ENOENT and
 * "anchor occurs 0 times", instead of quietly mutating nothing and reporting NOT_DETECTED. A harness
 * that had defaulted to "no anchor found, carry on" would have reported eleven surviving mutations
 * and sent someone to rewrite perfectly good tests.
 *
 * Untracked files are included deliberately — a new SQL function is untracked until it is added, and
 * that is the most likely thing to be under test.
 */
const untracked = git(['ls-files', '--others', '--exclude-standard']).split('\n').filter(Boolean);
const workingPatch = gitRaw(['diff', 'HEAD']);

/**
 * ★ THE PATCH GOES VIA A FILE, NOT VIA STDIN — AND THAT IS A FIX, NOT A STYLE CHOICE.
 *
 * This used to be `execFileSync('git', ['apply', '-'], { input: workingPatch })`. It worked for
 * every phase up to 11-E and then HUNG for 96 minutes on the first 11-F run: the working patch had
 * grown to ~252 KB, and piping that much into a child's stdin deadlocked — the parent blocked
 * writing stdin while the child was not draining it, and neither side moved again. The symptom was
 * the worst kind: not a crash, not a failure, just an attestation frozen at 39/110 that would have
 * looked like "still running" indefinitely.
 *
 * Writing the patch to a file inside the throwaway temp dir removes the pipe entirely, so the
 * failure class cannot recur at any patch size. The temp dir is already per-mutation and already
 * deleted in the `finally`, so this adds no cleanup obligation.
 */
function seed(wt, dir) {
  if (workingPatch.length > 0) {
    const patchFile = join(dir, 'working.patch');
    writeFileSync(patchFile, workingPatch, 'utf8');
    execFileSync('git', ['apply', '--whitespace=nowarn', patchFile], { cwd: wt });
  }
  for (const f of untracked) {
    const dest = join(wt, f);
    mkdirSync(dirname(dest), { recursive: true });
    copyFileSync(join(ROOT, f), dest);
  }
}

const results = [];
for (const m of selected) {
  const dir = mkdtempSync(join(tmpdir(), 'aw-sqlmut-'));
  const wt = join(dir, 'wt');
  let verdict = VERDICT.HARNESS_FAILURE;
  let detail = '';
  try {
    git(['worktree', 'add', '--detach', wt, 'HEAD']);
    seed(wt, dir);

    /**
     * ★ A MUTATION MAY NAME COMPANION EDITS (`also`) that must land in the same worktree — the case
     * that forced this is a body held VERBATIM in two places, where mutating one copy makes the
     * anti-drift guard exit 2 and testify in place of the suite under test. Every edit, primary and
     * companion, gets the same anchor discipline: exactly one occurrence, proven applied.
     */
    const edits = [{ file: m.file, from: m.from, to: m.to }, ...(m.also ?? [])];
    for (const e of edits) {
      const target = join(wt, e.file);
      const original = readFileSync(target, 'utf8');
      const occurrences = original.split(e.from).length - 1;
      if (occurrences !== 1) {
        detail = `the mutation anchor in ${e.file} occurs ${occurrences} time(s), expected exactly 1 — `
          + 'the harness would have mutated nothing (or the wrong site), and the suite would then '
          + 'pass for a reason that has nothing to do with authorization.';
        throw new Error('anchor');
      }
      const mutated = original.replace(e.from, e.to);

      // ★ PROVE THE EDIT LANDED. This is the check whose absence makes a mutation suite a no-op.
      if (mutated === original || !mutated.includes(e.to)) {
        detail = `the replacement did not change ${e.file}`;
        throw new Error('noop');
      }
      writeFileSync(target, mutated, 'utf8');
    }
    const target = join(wt, m.file);
    /**
     * ★ RE-READ FROM DISK AND CONFIRM THE MUTATION IS THERE — but only that.
     *
     * This also asserted `!reread.includes(m.from)`, i.e. that the anchor was GONE. That is wrong
     * for any mutation that INSERTS around its anchor rather than replacing it, and it produced a
     * HARNESS_FAILURE on `emit-before-state-transition`, whose whole technique is to prepend an
     * emit above an untouched line. The harness was reporting "the mutation did not apply" about a
     * mutation that had applied perfectly.
     *
     * Worth noting which direction that error ran in: it refused to trust a mutation it had made,
     * rather than trusting one it had not. That is the correct way for this check to be wrong.
     */
    const reread = readFileSync(target, 'utf8');
    if (!reread.includes(m.to)) {
      detail = 'the mutation was not present on re-read from disk';
      throw new Error('unverified');
    }

    /**
     * ★ EVERY BUNDLE IS REBUILT, AND THE MUTATION MUST LAND IN AT LEAST ONE OF THEM.
     *
     * The suite loads BUNDLES, not part files. A mutation applied to a source file that no bundle
     * includes would leave the suite running clean SQL and passing — reported as NOT_DETECTED,
     * blamed on the tests, when in fact the code under test was never changed. So the rebuilt
     * bundles are searched for the mutated text, and a miss is a HARNESS_FAILURE.
     *
     * A build failure is also a harness failure rather than a detection: a mutation that breaks a
     * positive control in the bundler has proved nothing about the authorization suite.
     */
    let landed = false;
    for (const [builder, artifact] of SQL_BUNDLES) {
      const build = spawnSync('node', [builder], { cwd: wt, encoding: 'utf8' });
      if (build.status !== 0) {
        detail = `${builder} failed inside the worktree: ${(build.stderr || build.stdout || '').slice(0, 300)}`;
        throw new Error('bundle');
      }
      if (readFileSync(join(wt, artifact), 'utf8').includes(m.to)) landed = true;
    }
    /**
     * ★ A BUNDLE IS NOT THE ONLY ROUTE INTO THE TEST DATABASE (Phase 11-B).
     *
     * The suite also loads some parts directly — the preamble, the test files, and two production
     * function sources that ship in no deploy bundle. Checking bundles ALONE was correct while
     * bundles were the only route, and became wrong the moment one was not: a mutation to
     * `get_estate_net_worth.sql` reaches the database perfectly well and would have been reported
     * `HARNESS_FAILURE — the mutation is in no rebuilt bundle`, which is a true sentence about the
     * bundles and a false one about the run.
     *
     * The question the check exists to answer is "does the mutated text reach the database the suite
     * runs against", so it is now asked about every route, and the parts list is single-sourced with
     * the verifier so the two cannot disagree.
     */
    if (!landed) {
      landed = SQL_DIRECT_PARTS.some(
        (p) => p === m.file && readFileSync(join(wt, p), 'utf8').includes(m.to)
      );
    }
    if (!landed) {
      detail = 'the mutation reaches the database by no route — it is in no rebuilt bundle and in no '
        + 'directly-loaded suite part, so the suite would load clean SQL and pass for a reason that '
        + 'has nothing to do with the tests';
      throw new Error('bundle-clean');
    }

    /**
     * ★ EACH MUTATION NAMES THE INSTRUMENT THAT MUST CATCH IT.
     *
     * Defaulting everything to the SQL suite would quietly report NOT_DETECTED for a mutation the
     * suite was never meant to see — and the reader would blame the tests rather than notice the
     * mutation was aimed at a different instrument. `target` makes the pairing explicit, so a
     * failure means "this instrument missed the thing it exists to catch".
     */
    const verifier = m.target ?? 'scripts/verifySqlAuthorization.mjs';
    /**
     * ★ `spec` NAMES THE FILE, AND DEFAULTS TO THE FIREWALL RATHER THAN TO "ALL TESTS".
     *
     * Running the whole vitest suite would make every source-audit mutation look DETECTED as soon as
     * ANY unrelated test broke, which is the pairing this block exists to keep honest: a mutation
     * must be caught by the instrument written for it, not by collateral damage somewhere else.
     */
    const spec = m.spec ?? 'test/phase11Firewall.test.ts';
    const run = verifier === 'npx'
      ? spawnSync('npx', ['vitest', 'run', spec], { cwd: wt, encoding: 'utf8' })
      : spawnSync('node', [verifier], { cwd: wt, encoding: 'utf8' });
    const out = `${run.stdout ?? ''}${run.stderr ?? ''}`;
    if (run.status === 2) {
      detail = 'the suite could not verify (exit 2) — that is a harness failure, never a detection';
      throw new Error('cannot-verify');
    }
    verdict = run.status === 0 ? VERDICT.NOT_DETECTED : VERDICT.DETECTED;
    detail = (out.match(/FAIL: [^\n]*/) ?? [''])[0].slice(0, 200)
      || (verdict === VERDICT.DETECTED ? 'suite exited non-zero' : 'suite still passed');
  } catch (e) {
    if (!detail) detail = e?.message ?? 'unknown harness failure';
  } finally {
    try {
      git(['worktree', 'remove', '--force', wt]);
    } catch {
      /* the temp dir goes next regardless */
    }
    rmSync(dir, { recursive: true, force: true });
  }
  results.push({ ...m, verdict, detail });
  console.log(`${verdict === VERDICT.DETECTED ? '✓' : '✗'} ${m.id.padEnd(28)} ${verdict}`);
  if (verdict !== VERDICT.DETECTED) console.log(`    ${detail}`);
}

// ★ THE CHECKOUT MUST BE BYTE-IDENTICAL TO HOW WE FOUND IT.
const treeAfter = git(['status', '--porcelain']);
if (treeAfter !== treeBefore) {
  console.error('\n✗ HARNESS FAILURE — the working tree changed during the run. Inspect before trusting anything above.');
  process.exit(2);
}
console.log('\nworking tree unchanged (verified, not assumed)');

const survived = results.filter((r) => r.verdict !== VERDICT.DETECTED);
if (survived.length) {
  console.error(`\n✗ ${survived.length} mutation(s) were not killed:`);
  for (const s of survived) console.error(`    ${s.id} — ${s.why}`);
  process.exit(survived.some((s) => s.verdict === VERDICT.HARNESS_FAILURE) ? 2 : 1);
}
console.log(`✓ ALL ${results.length} SECURITY MUTATIONS KILLED — the authorization suite can fail.`);
