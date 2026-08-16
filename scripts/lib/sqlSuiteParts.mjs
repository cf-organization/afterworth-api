/**
 * WHAT THE SQL AUTHORIZATION SUITE LOADS, IN ORDER — single-sourced.
 *
 * ★ WHY THIS IS NOT JUST AN ARRAY IN THE VERIFIER. `mutateSqlAuthorization.mjs` must know whether a
 * mutated file actually REACHES the database the suite runs against. It used to answer that by
 * rebuilding the bundles and searching them for the mutated text — correct while bundles were the
 * only route in, and silently wrong the moment a part was loaded directly. A mutation in a file the
 * suite loads but no bundle contains would report `HARNESS_FAILURE: the mutation is in no rebuilt
 * bundle`, which is at least loud; the reverse — a runner that had defaulted to "carry on" — would
 * have reported NOT_DETECTED and sent someone to rewrite tests that were fine.
 *
 * Two consumers reading one list is the whole point. A copy here would drift from the verifier on
 * the first reordering, and the drift would be invisible: both files would still look right.
 */

/**
 * ★ PARTS THAT ARE PRODUCTION SOURCE BUT NOT IN A DEPLOY BUNDLE, AND WHY.
 *
 * `get_estate_net_worth` and `require_aal2` are loaded here from `db/functions/` directly rather
 * than through a paste-ready bundle. That is deliberate and it is a smaller claim, not a larger one:
 *
 *   · They MUST be loaded, because Phase 11-B found that FOUR of the seven release-condition copies
 *     had never executed in any test. `list_estate_assets` was created by the estate bundle and
 *     called by no assertion; `get_estate_net_worth` was not even installed, because it reads
 *     `normalized_assets` and the harness did not model that table. The suite was green and two
 *     whole disclosure surfaces had never been exercised. A centralization that rewires code nothing
 *     runs is a centralization nobody can trust.
 *
 *   · They are NOT added to a deploy bundle, because neither has ever shipped in one, and this
 *     repository has already come within one paste of REGRESSING production by re-applying a source
 *     file that was behind the deployed body (`create_asset_grant`, Phase 10-E). The
 *     source↔deployment reconciler cannot compare either of these — both read rows, so equal inputs
 *     legitimately differ. Putting an unreconciled SECURITY DEFINER body into an artifact whose
 *     header says "paste this and run it once" would be trading a known coverage gap for an unknown
 *     deployment risk.
 *
 * So: loaded for TESTING, not offered for DEPLOYMENT, and the difference is stated rather than
 * implied. Promoting them belongs with the evidence that source and deployment agree — which is a
 * Phase 11-C item, recorded as one.
 */
export const SQL_SUITE_PARTS = Object.freeze([
  'db/tests/preamble_real_auth.sql',
  // ★ FIRST AMONG THE BUNDLES (Phase 11-B). `notification_grant_is_live` is `language sql`, so its
  // body is resolved at CREATE time — the lifecycle bundle will not load at all against a database
  // without `release_condition_satisfied`. This is the order an operator uses.
  'db/bundles/release_conditions_bundle.sql',
  'db/bundles/estate_inventory_and_discovery_bundle.sql',
  'db/bundles/lifecycle_notifications_bundle.sql',
  // ★ LAST AMONG THE BUNDLES (Phase 11-C) — the operator order. It has no load-time dependency on
  // the other three (plpgsql throughout, except a `language sql` reader of a table it creates
  // itself), but it is the newest artifact and applies onto a database the others have shaped.
  'db/bundles/death_verification_bundle.sql',
  // ★ PHASE 11-K, AFTER the death bundle whose vocabulary it extends. It widens the
  // owner_notice_outbox status CHECK and adds the delivery recorder plus the two operator
  // projections — all of which read objects the death bundle creates above.
  'db/bundles/operator_console_bundle.sql',
  // ★ PHASE 11-OBR / OB-1, AFTER the operator console bundle that first ships `outbox_safety.sql`.
  // It adds `owner_notice_outbox.claimed_at` and re-pastes the file with the reclaim predicate that
  // reads it. Loaded here because §9 of the release-safety suite tests the reclaim contract against
  // a real database, and without this part the column does not exist and §9's own control fails
  // loudly rather than passing vacuously.
  'db/bundles/owner_notice_claim_visibility_bundle.sql',
  // ★ PHASE 11-L, LAST AMONG THE BUNDLES. It re-pastes `release_safety.sql` and
  // `lifecycle_notification_rpcs.sql` with the halt notification, so it must load AFTER
  // `release_conditions_bundle` (its functions call `release_condition_satisfied`, and
  // `notification_grant_is_live` is `language sql` — resolved at CREATE time, so a missing helper is
  // a load failure, not a degradation).
  //
  // ★ IT WAS DELIBERATELY LEFT OUT OF THIS LIST AND THAT WAS WRONG. The reasoning was that its two
  // inputs already reach the suite through the lifecycle and death bundles, so loading the same
  // bodies twice would only prove `create or replace` is idempotent. `releaseConditionCentralization`
  // §5 fired and was right: the invariant is about a FRESH database built from the artifacts alone,
  // where "some other bundle happens to carry that file" is not a load-order guarantee. Re-pasting
  // an overlapping module is also the established pattern — `operator_console_bundle` re-pastes
  // `outbox_safety.sql` after `death_verification_bundle` already loaded it.
  'db/bundles/halt_notification_bundle.sql',
  // Production source, loaded for coverage rather than offered for deployment — see the note above.
  'db/functions/require_aal2.sql',
  'db/functions/get_estate_net_worth.sql',
  // ★ ADDED IN PHASE 11-C, SAME POSTURE. The death-verification routines call all three at
  // execution time; production has carried them since 0014/0015 (admin gate, verified live
  // 2026-07-15) and 0026/0027 (policy engine, verified live 2026-07-16). None ships in a bundle —
  // promoting an unreconciled DEFINER body into a paste-ready artifact is the `create_asset_grant`
  // near-miss — so the suite loads the source files themselves.
  'db/functions/is_admin.sql',
  'db/functions/admin_require_gate.sql',
  'db/functions/required_verification_level.sql',
  'db/functions/preview_required_verification_level.sql',
  'db/functions/executor_workspace.sql',
  // ★ PHASE 11-MB. Loaded as source for the same reason as its neighbours above: it is offered for
  // deployment in its own artifact, and the suite needs the routine present to assert that DISCOVERY
  // moves while every disclosure projection does not.
  'db/functions/fiduciary_estate_discovery.sql',
  'db/tests/estate_assets_authorization.sql',
  'db/tests/estate_discovery_authorization.sql',
  'db/tests/estate_readiness_authorization.sql',
  'db/tests/professional_workspace_authorization.sql',
  'db/tests/lifecycle_notification_authorization.sql',
  'db/tests/release_condition_authorization.sql',
  // ★ AFTER every disclosure suite has proved its surface, BEFORE the exit matrix composes them:
  // the death-verification suite mutates the hidden world (cases, evidence, levels) and asserts
  // the surfaces the earlier files just proved do not move.
  'db/tests/death_verification_authorization.sql',
  // ★ PHASE 11-E, AFTER the verification suite and BEFORE the exit matrix. It walks the full
  // safety path (initiate → verify → window → release / challenge) on its own estates, reusing
  // `harness_dv`'s helpers, and it is the file that proves the ACTIVATION the verification suite
  // now deliberately refuses to see.
  'db/tests/release_safety_authorization.sql',
  // ★ PHASE 11-G, AFTER the safety suite (it reuses harness_dv/harness_rc helpers and needs the
  // release path proven) and BEFORE the exit matrix. It asserts the survivor-facing consequence of
  // everything above: six lifecycle states change nothing, `released` changes exactly what the
  // owner authored, and relationship never becomes a tier.
  'db/tests/survivor_mode_authorization.sql',
  'db/tests/fiduciary_capacity_authorization.sql',
  'db/tests/executor_workspace_authorization.sql',
  // ★ PHASE 11-K, AFTER the safety suite (it drives a case to `owner_notification_dispatched`
  // through the real doors) and BEFORE the exit matrix. It proves the operator READ doors refuse
  // every wrong actor and disclose the workflow without the estate.
  'db/tests/operator_console_authorization.sql',
  // ★ LAST, DELIBERATELY. The exit matrix asks whether the features above compose; it must run
  // after each of them has proved itself, so a failure here is a COMPOSITION failure rather than
  // an ambiguous mixture of the two.
  'db/tests/phase10_exit_matrix.sql',
]);

/** The rebuildable artifacts, paired with the builder that produces each. */
export const SQL_BUNDLES = Object.freeze([
  ['scripts/buildReleaseConditionBundle.mjs', 'db/bundles/release_conditions_bundle.sql'],
  ['scripts/buildEstateAssetBundle.mjs', 'db/bundles/estate_inventory_and_discovery_bundle.sql'],
  ['scripts/buildLifecycleNotificationBundle.mjs', 'db/bundles/lifecycle_notifications_bundle.sql'],
  ['scripts/buildDeathVerificationBundle.mjs', 'db/bundles/death_verification_bundle.sql'],
  ['scripts/buildExecutorWorkspaceBundle.mjs', 'db/bundles/executor_workspace_bundle.sql'],
  ['scripts/buildReleaseStateLockdownBundle.mjs', 'db/bundles/estate_release_state_lockdown_bundle.sql'],
  ['scripts/buildOperatorConsoleBundle.mjs', 'db/bundles/operator_console_bundle.sql'],
  // ★ PHASE 11-L. Registered so the atomicity verifier and every rebuild-before-trust step cover it.
  ['scripts/buildHaltNotificationBundle.mjs', 'db/bundles/halt_notification_bundle.sql'],
  // ★ PHASE 11-MB. One read-only routine; registered so the atomicity verifier and every
  // rebuild-before-trust step cover it.
  ['scripts/buildFiduciaryDiscoveryBundle.mjs', 'db/bundles/fiduciary_discovery_bundle.sql'],
  // ★ PHASE 11-MC. Registered so the atomicity verifier and every rebuild-before-trust step cover it.
  ['scripts/buildProvisioningCorrectionBundle.mjs', 'db/bundles/provisioning_correction_bundle.sql'],
  // ★ PHASE 11-NR. The FINDING 4 remediation: one part, `release_safety.sql`. Registered here so the
  // atomicity verifier and every rebuild-before-trust step cover it — including the mutation runner,
  // which rebuilds every registered artifact inside its worktree and would otherwise let a mutated
  // body reach the suite through one bundle while this one still carried the unmutated text.
  ['scripts/buildChallengeSettlementBundle.mjs', 'db/bundles/challenge_settlement_bundle.sql'],
  // ★ PHASE 11-OBR / OB-1. Registered so the atomicity verifier and every rebuild-before-trust step
  // cover it — including the mutation runner, which rebuilds every registered artifact inside its
  // worktree and would otherwise let a mutated body reach the suite through one bundle while this
  // one still carried the unmutated text.
  ['scripts/buildOwnerNoticeClaimVisibilityBundle.mjs',
    'db/bundles/owner_notice_claim_visibility_bundle.sql'],
]);

/**
 * Files the suite loads DIRECTLY (not via a bundle) — the routes a mutation can take into the test
 * database without appearing in any rebuilt artifact.
 */
export const SQL_DIRECT_PARTS = Object.freeze(
  SQL_SUITE_PARTS.filter((p) => !p.startsWith('db/bundles/'))
);
