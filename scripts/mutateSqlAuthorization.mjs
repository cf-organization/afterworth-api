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
      + 'turns grant creation into the release announcement Phase 11 has not built.',
    file: 'db/functions/lifecycle_notification_rpcs.sql',
    from: "  select p_status = 'active'\n     and (\n       p_release_condition = 'immediately'",
    to: "  select p_status = 'active'\n     and (\n       p_release_condition is not null",
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
    id: 'cross-estate-recipient',
    why: 'Recipient resolution must be scoped to the estate the event happened on. Dropping the '
      + 'estate predicate makes the "owner" an arbitrary owner, which is a cross-estate leak that '
      + 'reads like a harmless simplification.',
    file: 'db/functions/lifecycle_notification_rpcs.sql',
    from: '  select owner_id from public.estates where id = p_estate_id;',
    to: '  select owner_id from public.estates order by id limit 1;',
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

    const target = join(wt, m.file);
    const original = readFileSync(target, 'utf8');
    const occurrences = original.split(m.from).length - 1;
    if (occurrences !== 1) {
      detail = `the mutation anchor occurs ${occurrences} time(s), expected exactly 1 — the harness `
        + 'would have mutated nothing (or the wrong site), and the suite would then pass for a '
        + 'reason that has nothing to do with authorization.';
      throw new Error('anchor');
    }
    const mutated = original.replace(m.from, m.to);

    // ★ PROVE THE EDIT LANDED. This is the check whose absence makes a mutation suite a no-op.
    if (mutated === original || !mutated.includes(m.to)) {
      detail = 'the replacement did not change the file';
      throw new Error('noop');
    }
    writeFileSync(target, mutated, 'utf8');
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
    const BUNDLES = [
      ['scripts/buildEstateAssetBundle.mjs', 'db/bundles/estate_inventory_and_discovery_bundle.sql'],
      ['scripts/buildLifecycleNotificationBundle.mjs', 'db/bundles/lifecycle_notifications_bundle.sql'],
    ];
    let landed = false;
    for (const [builder, artifact] of BUNDLES) {
      const build = spawnSync('node', [builder], { cwd: wt, encoding: 'utf8' });
      if (build.status !== 0) {
        detail = `${builder} failed inside the worktree: ${(build.stderr || build.stdout || '').slice(0, 300)}`;
        throw new Error('bundle');
      }
      if (readFileSync(join(wt, artifact), 'utf8').includes(m.to)) landed = true;
    }
    if (!landed) {
      detail = 'the mutation is in no rebuilt bundle — the suite would load clean SQL and pass for a '
        + 'reason that has nothing to do with the tests';
      throw new Error('bundle-clean');
    }

    const run = spawnSync('node', ['scripts/verifySqlAuthorization.mjs'], { cwd: wt, encoding: 'utf8' });
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
