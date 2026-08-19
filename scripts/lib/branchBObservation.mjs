/**
 * PHASE 11-P.5 · THE SESSION-2 PROVENANCE COLLECTOR — READ ONLY.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ WHY A COLLECTOR EXISTS AT ALL: THE OLD CONTRACT HAD NO PRODUCER.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * `evaluateResume` has exactly one kind of caller in the repository, and it is a test. Nothing
 * committed ever CONSTRUCTED the `observed` object, so "where does `observed.admin_sha` come from?"
 * had no answer in code — it lived in whatever the operator did at the keyboard that day. That is
 * how a gate ends up green over the wrong console: the cheapest keystroke, `git rev-parse HEAD`,
 * reads the one source that is not provenance.
 *
 * ★ SO THE SOURCE IS CODE, NOT A HABIT. Each collector below hard-wires one source kind and LABELS
 *   what it read. A collector cannot return a value without saying where it came from, and
 *   `compareProvenance` refuses on the label before it ever looks at the sha.
 *
 * ★ NOTHING HERE WRITES. Two external commands are used, both read-only: `gh api` (GET) and, for the
 *   deliberately-labelled local reader, `git rev-parse`. There is no path from this module to
 *   `authorize_release`, to a drain, to a deploy, or to any DML.
 *
 * ★ UNAVAILABLE IS NEVER "UNCHANGED". Every failure returns `null`, and a null observation fails its
 *   gate by name. There is no degraded mode in which a missing observation is read as agreement —
 *   that substitution is the exact shape this repository has shipped before, and it is why the
 *   selectors below refuse rather than guess.
 */
import { execFileSync } from 'node:child_process';
import { SOURCE_KINDS } from './branchBProvenance.mjs';

const SHA1_RE = /^[0-9a-f]{40}$/;

/** Default read-only `gh api` runner. Injected in tests; the CLI runs the real one. */
export const defaultGh = (args) =>
  execFileSync('gh', ['api', ...args], { encoding: 'utf8', maxBuffer: 16 * 1024 * 1024 });

/** Default read-only `git` runner. */
export const defaultGit = (args) =>
  execFileSync('git', args, { encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 });

/**
 * PURE. Resolve a git ref payload to a commit sha.
 *
 * ★ THE REF IS RE-CHECKED AGAINST THE ONE THAT WAS ASKED FOR. GitHub resolves a partial ref name to
 *   whatever it matches, so a request for `heads/main` that comes back describing `heads/main-old`
 *   must be refused rather than trusted — otherwise the collector reports a sha for a ref nobody
 *   requested and the gate compares the right value from the wrong branch.
 *
 * ★ AND THE OBJECT TYPE IS CHECKED. An annotated tag ref resolves to a `tag` object whose sha is the
 *   TAG's, not the commit's. Accepting it would return a 40-hex string that is not a commit.
 */
export function selectRefSha(payload, expectedRef) {
  if (payload === null || typeof payload !== 'object' || Array.isArray(payload)) return null;
  if (payload.ref !== expectedRef) return null;
  const obj = payload.object;
  if (obj === null || typeof obj !== 'object') return null;
  if (obj.type !== 'commit') return null;
  return SHA1_RE.test(String(obj.sha)) ? obj.sha : null;
}

/**
 * PURE. Choose the most recent deployment that is BOTH in the requested environment AND successful.
 *
 * ★ THE TWO CONDITIONS ARE INDEPENDENT AND BOTH REQUIRED. A successful Preview deployment and a
 *   failed Production deployment are different mistakes; collapsing them into one "latest
 *   deployment" lookup lets either through. The status is consulted per deployment rather than
 *   assumed from its existence — a created deployment is not a deployed one.
 *
 * ★ ORDERING IS NOT ASSUMED. The list is sorted by `created_at` here rather than trusting the API to
 *   return newest-first, because a transformation that happens to agree with its input proves
 *   nothing and would break silently if the API paged differently.
 */
export function selectSuccessfulProductionDeployment(deployments, statusesById, environment) {
  if (!Array.isArray(deployments) || typeof environment !== 'string' || environment === '') return null;
  const candidates = deployments
    .filter((d) => d !== null && typeof d === 'object' && d.environment === environment)
    .filter((d) => SHA1_RE.test(String(d.sha)))
    .slice()
    .sort((a, b) => Date.parse(b.created_at) - Date.parse(a.created_at));

  for (const d of candidates) {
    const statuses = statusesById?.[String(d.id)];
    if (!Array.isArray(statuses) || statuses.length === 0) continue;
    const latest = statuses
      .slice()
      .sort((a, b) => Date.parse(b.created_at) - Date.parse(a.created_at))[0];
    if (latest?.state !== 'success') continue;
    return {
      sha: d.sha,
      environment: d.environment,
      state: latest.state,
      deployment_id: String(d.id),
      created_at: d.created_at,
    };
  }
  return null;
}

/**
 * Collect a SOURCE REVISION from the authoritative remote ref.
 *
 * ★ IT ASKS THE REMOTE, NOT THE LOCAL MIRROR. `refs/remotes/origin/main` is only as current as the
 *   last fetch, and a stale mirror answering confidently is exactly the failure mode being fixed.
 */
export function collectSourceRevision({ repo, ref, gh = defaultGh }) {
  const short = ref.replace(/^refs\//, '');
  let payload;
  try {
    payload = JSON.parse(gh([`repos/${repo}/git/ref/${short}`]));
  } catch {
    return null; // unavailable, never "unchanged"
  }
  const sha = selectRefSha(payload, ref);
  if (sha === null) return null;
  return Object.freeze({ sha, source_kind: SOURCE_KINDS.SOURCE_REVISION, repo, ref });
}

/** Collect a PRODUCTION DEPLOYMENT revision from deployment metadata plus its status. */
export function collectProductionDeployment({ repo, environment, gh = defaultGh, pageSize = 30 }) {
  let deployments;
  try {
    deployments = JSON.parse(
      gh([`repos/${repo}/deployments?environment=${encodeURIComponent(environment)}&per_page=${pageSize}`])
    );
  } catch {
    return null;
  }
  if (!Array.isArray(deployments)) return null;
  const statusesById = {};
  for (const d of deployments.slice(0, pageSize)) {
    if (d === null || typeof d !== 'object') continue;
    try {
      statusesById[String(d.id)] = JSON.parse(gh([`repos/${repo}/deployments/${d.id}/statuses?per_page=10`]));
    } catch {
      // Leave absent. `selectSuccessfulProductionDeployment` skips a deployment whose status could
      // not be read rather than assuming it succeeded.
    }
  }
  const chosen = selectSuccessfulProductionDeployment(deployments, statusesById, environment);
  if (chosen === null) return null;
  return Object.freeze({
    sha: chosen.sha,
    source_kind: SOURCE_KINDS.PRODUCTION_DEPLOYMENT,
    repo,
    environment: chosen.environment,
    state: chosen.state,
    deployment_id: chosen.deployment_id,
  });
}

/**
 * PURE. Decide whether a compare payload proves the reviewed revision is in the branch's lineage.
 *
 * ★ `behind_by === 0` IS THE LOAD-BEARING CONDITION, NOT THE STATUS STRING. GitHub reports `ahead`
 *   when the branch has advanced past the reviewed commit and `identical` when they are equal; both
 *   mean the commit is an ancestor. `diverged` and `behind` mean it is NOT — it sits on a line the
 *   branch never took, which is exactly a parked or force-pushed commit. Reading only the status
 *   word would admit `diverged`, whose `ahead_by` is also positive.
 */
export function selectLineage(payload, expectedSha) {
  if (payload === null || typeof payload !== 'object' || Array.isArray(payload)) return null;
  const base = payload.base_commit;
  if (base === null || typeof base !== 'object' || !SHA1_RE.test(String(base.sha))) return null;
  if (base.sha !== expectedSha) return null;
  const inLineage =
    (payload.status === 'ahead' || payload.status === 'identical') && payload.behind_by === 0;
  return { sha: base.sha, in_lineage: inLineage };
}

/**
 * Collect a REVIEWED REVISION: prove the commit EXISTS in the repo and lies in the branch's lineage.
 *
 * ★ IT DOES NOT SIMPLY ECHO THE EXPECTED SHA. The value returned is the one GitHub resolved for the
 *   commit in THAT repository, so a sha that does not exist there fails the request outright rather
 *   than being handed back as though it had been verified.
 */
export function collectReviewedRevision({ repo, sha, ancestorOf, gh = defaultGh }) {
  const branch = ancestorOf.replace(/^refs\/heads\//, '');
  let payload;
  try {
    payload = JSON.parse(gh([`repos/${repo}/compare/${sha}...${branch}`]));
  } catch {
    return null; // the commit does not exist in this repo, or the API was unreachable
  }
  const r = selectLineage(payload, sha);
  if (r === null) return null;
  return Object.freeze({
    sha: r.sha,
    source_kind: SOURCE_KINDS.REVIEWED_REVISION,
    repo,
    ancestor_of: ancestorOf,
    in_lineage: r.in_lineage,
  });
}

/**
 * Collect a LOCAL WORKING-TREE HEAD, labelled honestly as such.
 *
 * ★ THIS EXISTS SO THE WRONG ANSWER CAN BE SAID OUT LOUD. It is never valid as provenance — the
 *   addendum schema cannot express a `local_checkout` expectation — but a collector that is
 *   mis-wired to a working tree must return something a gate can REFUSE by name. Delete this and the
 *   same mis-wiring simply reappears mislabelled as `source_revision`, which is undetectable.
 */
export function collectLocalCheckout({ repoPath, repo, git = defaultGit }) {
  let out;
  try {
    out = git(['-C', repoPath, 'rev-parse', 'HEAD']);
  } catch {
    return null;
  }
  const sha = String(out).trim();
  if (!SHA1_RE.test(sha)) return null;
  return Object.freeze({ sha, source_kind: SOURCE_KINDS.LOCAL_CHECKOUT, repo, repoPath });
}

/**
 * Collect every component the addendum expects, driven BY THE ADDENDUM.
 *
 * ★ THE EXPECTATION CHOOSES THE COLLECTOR, so the two can never disagree about which source was
 *   meant to be read. An expectation whose source kind has no collector returns `null` rather than
 *   falling back to one that happens to be available.
 */
export function collectSession2Provenance({ addendum, gh = defaultGh }) {
  const out = {};
  for (const [name, expected] of Object.entries(addendum.session2_provenance)) {
    if (expected.source_kind === SOURCE_KINDS.REVIEWED_REVISION) {
      out[name] = collectReviewedRevision({
        repo: expected.repo, sha: expected.sha, ancestorOf: expected.ancestor_of, gh,
      });
    } else if (expected.source_kind === SOURCE_KINDS.SOURCE_REVISION) {
      out[name] = collectSourceRevision({ repo: expected.repo, ref: expected.ref, gh });
    } else if (expected.source_kind === SOURCE_KINDS.PRODUCTION_DEPLOYMENT) {
      out[name] = collectProductionDeployment({ repo: expected.repo, environment: expected.environment, gh });
    } else {
      out[name] = null;
    }
  }
  if (addendum.resume_instrument !== null) {
    const e = addendum.resume_instrument;
    out.resume_instrument =
      e.source_kind === SOURCE_KINDS.REVIEWED_REVISION
        ? collectReviewedRevision({ repo: e.repo, sha: e.sha, ancestorOf: e.ancestor_of, gh })
        : e.source_kind === SOURCE_KINDS.SOURCE_REVISION
          ? collectSourceRevision({ repo: e.repo, ref: e.ref, gh })
          : collectProductionDeployment({ repo: e.repo, environment: e.environment, gh });
  }
  return out;
}
