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
    from: "  select p_status = 'active'\n     and public.release_condition_satisfied(p_release_condition, p_approved_at, 'standard');",
    to: "  select p_status = 'active'\n     and (p_release_condition is not null\n          or public.release_condition_satisfied(p_release_condition, p_approved_at, 'standard'));",
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
    from: "  if not public.release_condition_satisfied(v_cond, v_approved, 'standard') then",
    to: "  if not (v_cond = 'after_verified_death_or_incapacity'\n          or public.release_condition_satisfied(v_cond, v_approved, 'standard')) then",
  },

  /* ── PHASE 11-B · the canonical release-condition engine ──────────────────────────────────────
   * Centralization is only worth anything if the centre is guarded. Each mutation below is an edit
   * to the ONE file that now decides release, or an edit that routes around it — and each names the
   * instrument that must object. Together they answer the question the phase turns on: if somebody
   * activated a death condition in this codebase, would anything notice?
   */
  {
    id: 'p11b-death-satisfied-standard',
    why: 'THE PHASE 11 FAILURE, COMMITTED AT THE CENTRE. Admitting after_verified_death in the '
      + 'canonical predicate activates every death-conditioned grant on every surface at once — '
      + 'documents, inventory, notifications — from a one-line edit that looks like progress.',
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
    from: "    and public.release_condition_satisfied(g.release_condition, g.approved_at, 'legacy_immediate_only')\n  limit 1;",
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
    from: "  return public.release_condition_satisfied(g.release_condition, g.approved_at, 'standard');",
    to: "  return public.release_condition_satisfied(g.release_condition, g.approved_at, 'standard') or true;",
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
      from: "  return public.release_condition_satisfied(g.release_condition, g.approved_at, 'standard');",
      to: "  return public.release_condition_satisfied(g.release_condition, g.approved_at, 'standard') or true;",
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
  {
    id: 'p11-executor-gains-disclosure',
    target: 'npx',
    why: 'A fiduciary designation confers capacity, never disclosure. Granting a tier to an executor '
      + 'is the most natural-sounding Phase 11 mistake there is.',
    file: 'db/functions/estate_discovery_rpcs.sql',
    from: '  if public.is_estate_owner(p_estate) then return \'full_detail\'; end if;',
    to: '  if public.is_estate_owner(p_estate) then return \'full_detail\'; end if;\n  if public.is_estate_executor(p_estate, p_uid) then return \'full_detail\'; end if;',
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

function seed(wt) {
  if (workingPatch.length > 0) {
    execFileSync('git', ['apply', '--whitespace=nowarn', '-'], { cwd: wt, input: workingPatch });
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
    seed(wt);

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
