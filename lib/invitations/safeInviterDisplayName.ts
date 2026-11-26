/**
 * The inviter display name sanitizer — the worker-side twin of `public.safe_inviter_display_name(text)`
 * (migration 0068) and of the mobile client's `sanitizeInviterDisplayName`.
 *
 * ★ WHY A THIRD COPY EXISTS. The invitation email is composed in this process, from a value the
 * delivery-notice RPC returns RAW (it releases the column to the service-role worker, not to a
 * recipient). Both deployed create paths persisted `coalesce(nullif(full_name, ''), email)`, so a
 * row whose owner had no profile name carries an ADDRESS in `inviter_display_name` — and the template
 * printed it wherever the owner had chosen "show my name". Migration 0069 stops storing the address
 * and sanitizes every SQL release point; this function is the same rule at the one release point that
 * is not SQL. Rows written before 0069 keep their stored value, so this must hold for them forever.
 *
 * ★ THE RULE, identical on all three sides:
 *   · not a string → null;
 *   · trim ECMAScript WhiteSpace + LineTerminator — exactly what `String.prototype.trim()` strips, which
 *     is exactly the code-point set the SQL function spells out;
 *   · nothing left → null (missing);
 *   · anything EMAIL-SHAPED (`/\S@\S/`: an `@` with a non-whitespace character on both sides) → null;
 *   · more than 200 characters after trimming → null — counted in code points, as PostgreSQL's
 *     `length(text)` counts, so the two sides agree on astral characters too;
 *   · otherwise the trimmed value.
 *
 * ★ NULL MEANS "NO NAME", NEVER A SUBSTITUTE. No neutral phrase is produced here; the template owns the
 * neutral wording and the client owns its own. Nothing may derive a name from an address, a profile, an
 * id or another row when this returns null.
 *
 * Pinned to the SQL vector table (`db/tests/safe_inviter_display_name_assertions.sql`) by
 * test/safeInviterDisplayName.test.ts: every labelled SQL case has a TypeScript twin with the same
 * expected outcome, so the two tables cannot drift apart silently.
 */

export const INVITER_NAME_MAX_LENGTH = 200;

export function safeInviterDisplayName(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  if (trimmed.length === 0) return null;
  // Broader than RFC on purpose: "could a human read this as an address", not "is this deliverable".
  if (/\S@\S/.test(trimmed)) return null;
  if (Array.from(trimmed).length > INVITER_NAME_MAX_LENGTH) return null;
  return trimmed;
}
