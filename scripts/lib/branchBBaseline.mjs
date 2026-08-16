/**
 * PHASE 11-OB PREP · THE IMMUTABLE BRANCH B BASELINE.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ WHAT A BASELINE IS FOR, AND WHY IT MUST BE HASHED.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * Branch B runs for seven days across at least two sessions. At the end, someone has to be able to
 * say what the world looked like at the start — not from memory, not from a report written
 * afterwards, but from an artifact captured before anything moved. The digest is what makes the
 * artifact answerable: a baseline that can be edited after the fact to agree with the outcome proves
 * nothing about the outcome.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ THE ALLOWLIST IS THE CONTAINMENT MECHANISM, NOT THE COMMENT ABOVE IT.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * "Collect only approved non-secret fields" is an instruction a future collector will follow right
 * up until the day a wider projection is convenient. So the field set is CLOSED — an unknown key is
 * a build failure — and every value is additionally scanned for address-shaped and secret-shaped
 * strings before a digest is computed. Two independent mechanisms, because the estate designator
 * field would happily hold an email address and satisfy the allowlist.
 *
 * ★ IDENTITIES ARE UIDS, NEVER ADDRESSES. A uid is not a credential — `verifyOperatorAdmitPath.mjs`
 * makes the same call and gives the same reason: `public.admins` membership can only be granted by a
 * human running SQL, so a uid discloses nothing an attacker can use. An email address identifies a
 * living person and is exactly what the device-evidence rule exists to keep out of retained artifacts.
 *
 * ★ IT DOES NOT COLLECT. This module is PURE: it validates, canonicalizes and hashes a record the
 * caller assembled. Nothing here opens a socket, so nothing here can be pointed at production by
 * accident.
 */
import { canonicalDigest } from './canonicalJson.mjs';

export const BASELINE_VERSION = 1;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const SHA1_RE = /^[0-9a-f]{40}$/;
const SHA256_RE = /^[0-9a-f]{64}$/;
const DESIGNATOR_RE = /^[A-Z][A-Z0-9_-]{2,63}$/;
const SENTINEL_RE = /^\d{1,4}\/\d{1,4}$/;
const INSTANT_RE = /^\d{4}-\d{2}-\d{2}T/;

/** ★ Two independent shapes, both refused anywhere in the payload, at any depth. */
export const EMAIL_SHAPED = /[\w.+-]+@[\w-]+\.[\w-]+/;
export const SECRET_SHAPED = /sb_secret|service_role|eyJ[A-Za-z0-9_-]{20,}|-----BEGIN|BEARER\s|PASSWORD|TOTP_SECRET/i;

const isInstant = (v) => typeof v === 'string' && INSTANT_RE.test(v) && !Number.isNaN(Date.parse(v));
const isCensus = (v) =>
  v !== null &&
  typeof v === 'object' &&
  !Array.isArray(v) &&
  Object.values(v).every((n) => Number.isInteger(n) && n >= 0);

/**
 * The closed field set. Every entry is either a scalar with a shape, or a counts-only census whose
 * values are all non-negative integers — there is no field a document title, an estate name or a
 * free-text note could occupy.
 */
const FIELDS = Object.freeze({
  baseline_version: (v) => (v === BASELINE_VERSION ? null : `must be ${BASELINE_VERSION}`),
  captured_at: (v) => (isInstant(v) ? null : 'must be an ISO-8601 instant'),

  api_sha: (v) => (SHA1_RE.test(String(v)) ? null : 'must be a full 40-hex commit sha'),
  mobile_sha: (v) => (SHA1_RE.test(String(v)) ? null : 'must be a full 40-hex commit sha'),
  admin_sha: (v) => (SHA1_RE.test(String(v)) ? null : 'must be a full 40-hex commit sha'),

  estate_designator: (v) => (DESIGNATOR_RE.test(String(v)) ? null : 'must be an uppercase designator'),
  estate_uuid: (v) => (UUID_RE.test(String(v)) ? null : 'must be a lowercase uuid'),

  owner_uid: (v) => (UUID_RE.test(String(v)) ? null : 'must be a lowercase uuid'),
  fiduciary_uid: (v) => (UUID_RE.test(String(v)) ? null : 'must be a lowercase uuid'),
  operator_a_uid: (v) => (UUID_RE.test(String(v)) ? null : 'must be a lowercase uuid'),
  operator_b_uid: (v) => (UUID_RE.test(String(v)) ? null : 'must be a lowercase uuid'),

  // ★ Identity and relationship come from their authoritative sources, spelled as closed unions —
  //   never reconstructed from a capability combination.
  designation_role: (v) => (['executor', 'trustee', 'none'].includes(v) ? null : 'closed vocabulary'),
  designation_status: (v) => (['active', 'revoked', 'none'].includes(v) ? null : 'closed vocabulary'),
  membership_posture: (v) =>
    ['none', 'beneficiary', 'professional_delegate', 'owner'].includes(v) ? null : 'closed vocabulary',

  grant_id: (v) => (v === null || UUID_RE.test(String(v)) ? null : 'must be null or a lowercase uuid'),
  grant_fingerprint: (v) => (v === null || SHA256_RE.test(String(v)) ? null : 'must be null or a 64-hex digest'),
  release_condition: (v) =>
    v === null || ['immediately', 'after_verified_death', 'after_owner_approval', 'never'].includes(v)
      ? null
      : 'closed vocabulary',
  disclosure_hash: (v) => (SHA256_RE.test(String(v)) ? null : 'must be a 64-hex digest'),

  lifecycle: (v) =>
    [
      'active', 'death_verification_pending', 'death_verified', 'owner_notification_dispatched',
      'challenge_window', 'challenge_halted', 'released',
    ].includes(v)
      ? null
      : 'must be a deployed lifecycle state',
  case_uuid: (v) => (v === null || UUID_RE.test(String(v)) ? null : 'must be null or a lowercase uuid'),
  case_status: (v) =>
    v === null || ['open', 'verified', 'rejected', 'cancelled'].includes(v) ? null : 'closed vocabulary',

  outbox_census: (v) => (isCensus(v) ? null : 'must be an object of non-negative integer counts'),
  notification_census: (v) => (isCensus(v) ? null : 'must be an object of non-negative integer counts'),
  release_authorizations_count: (v) => (Number.isInteger(v) && v >= 0 ? null : 'must be a non-negative integer'),

  standing_fixture_sentinel: (v) => (SENTINEL_RE.test(String(v)) ? null : "must read '<passed>/<total>'"),
  fixture_lock: (v) => (['free', 'held'].includes(v) ? null : "must be 'free' or 'held'"),
});

export const BASELINE_FIELDS = Object.freeze(Object.keys(FIELDS));

/** Deep scan for anything that must never be retained in an artifact. Returns dotted paths. */
export function findForbiddenStrings(value, path = '$', out = []) {
  if (typeof value === 'string') {
    if (EMAIL_SHAPED.test(value)) out.push(`${path}: address-shaped`);
    if (SECRET_SHAPED.test(value)) out.push(`${path}: secret-shaped`);
  } else if (Array.isArray(value)) {
    value.forEach((v, i) => findForbiddenStrings(v, `${path}[${i}]`, out));
  } else if (value !== null && typeof value === 'object') {
    for (const [k, v] of Object.entries(value)) {
      if (EMAIL_SHAPED.test(k) || SECRET_SHAPED.test(k)) out.push(`${path}.${k}: key`);
      findForbiddenStrings(v, `${path}.${k}`, out);
    }
  }
  return out;
}

/**
 * Validate, canonicalize and hash. Returns `{ ok, artifact, digest }` or `{ ok: false, errors }`.
 *
 * The digest covers the record WITHOUT `baseline_sha256`, so the artifact can carry its own digest
 * without the digest depending on itself.
 */
export function buildBaseline(record) {
  const errors = [];
  if (record === null || typeof record !== 'object' || Array.isArray(record)) {
    return { ok: false, errors: ['baseline must be a JSON object'] };
  }
  for (const key of Object.keys(record)) {
    if (!(key in FIELDS)) errors.push(`unknown field: ${key}`);
  }
  for (const [key, check] of Object.entries(FIELDS)) {
    if (!(key in record)) {
      errors.push(`missing field: ${key}`);
      continue;
    }
    const problem = check(record[key]);
    if (problem) errors.push(`${key}: ${problem}`);
  }
  const forbidden = findForbiddenStrings(record);
  for (const f of forbidden) errors.push(`forbidden content at ${f}`);
  if (errors.length) return { ok: false, errors: errors.sort() };

  const digest = canonicalDigest(record);
  return {
    ok: true,
    digest,
    artifact: Object.freeze({ ...record, baseline_sha256: digest }),
  };
}

/** Re-derive the digest of a written artifact and compare. The tamper check. */
export function verifyBaseline(artifact) {
  if (!artifact || typeof artifact !== 'object' || typeof artifact.baseline_sha256 !== 'string') {
    return { ok: false, errors: ['artifact carries no baseline_sha256'] };
  }
  const { baseline_sha256: claimed, ...record } = artifact;
  const rebuilt = buildBaseline(record);
  if (!rebuilt.ok) return rebuilt;
  return rebuilt.digest === claimed
    ? { ok: true, digest: claimed }
    : { ok: false, errors: [`digest mismatch: claimed ${claimed}, recomputed ${rebuilt.digest}`] };
}

/**
 * `phase11ob-baseline-<compact-utc>.json`.
 *
 * ★ THE TIMESTAMP IS AN ARGUMENT. A filename minted from an internal clock cannot be asserted by a
 * test without either freezing time or matching a pattern — and a pattern match would accept a
 * filename built from the wrong clock entirely.
 */
export function baselineFilename(capturedAt) {
  if (!isInstant(capturedAt)) return null;
  return `phase11ob-baseline-${new Date(capturedAt).toISOString().replace(/[:.]/g, '-').replace(/Z$/, 'Z')}.json`;
}
