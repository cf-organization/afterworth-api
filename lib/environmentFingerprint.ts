/**
 * GET /api/environment — the deployment identity fingerprint.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ WHY THIS EXISTS: A MOBILE ACCEPTANCE RUN HAD NO WAY TO ASK A DEPLOYMENT WHICH DATABASE IT IS.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * MVP-FIX-02 halted before creating a single synthetic persona. The mobile client had been proved to
 * resolve its Supabase client to the non-production project, and then every invitation, grant,
 * access-request and document mutation was found to travel a SECOND path — `apiBaseUrl` — that
 * defaults to the deployed API bound to the application-facing database. Half the boundary was
 * closed and half was open, and nothing on either side could tell the difference, because this API
 * exposes twelve authenticated POST routes and no way whatsoever to ask it what it is attached to.
 *
 * A deployment that cannot state its own backend cannot be safely targeted by anything. This is the
 * missing half.
 *
 * ★ THE PROJECT REF IS THE AUTHORITY. `environment` IS ONLY A DECLARATION.
 *
 *   `supabaseProjectRef` is derived from the SUPABASE_URL this deployment actually constructs its
 *   clients from, so it is a fact about where writes land. `environment` is read from an operator-set
 *   marker and is therefore a CLAIM about intent — an operator can set it to "nonprod" on a
 *   deployment wired to the application-facing project, and it will say "nonprod" while every write
 *   goes to real users' data.
 *
 *   A consumer must gate on the REF. This module deliberately does not merge the two into one
 *   verdict, and deliberately does not infer either from the other: identity is never reconstructed
 *   from a neighbouring signal, it is asked of its authoritative source. The two fields are reported
 *   side by side precisely so a disagreement between them is VISIBLE rather than resolved here.
 *
 * ★ IT ANSWERS IN PRODUCTION TOO, AND THAT IS THE POINT. Suppressing it outside non-production would
 *   make "this is the production API" and "this deployment is too old to have the endpoint" the same
 *   observation — a 404 — so a client guard could not fail closed on the case that matters. The
 *   endpoint's value to a safety gate is its NEGATIVE answer.
 *
 * ★ WHAT IT MAY NEVER EMIT. No key material, no token, no header, no configuration dump, and not the
 *   Supabase URL itself — only the 20-character project ref parsed out of it. Everything returned is
 *   an identifier that already ships inside every published client bundle. `environmentFingerprint`
 *   builds its result from a CLOSED set of four derived fields rather than by filtering an
 *   environment object, so a newly added variable can never be swept into the response by accident.
 *
 * ★ UNAUTHENTICATED, BY NECESSITY. The client-side guard that consumes this runs BEFORE a session
 *   exists — refusing to talk to the wrong backend is the first thing it must do, not something it
 *   can do after signing a user in against it. It performs no I/O, touches no database, holds no
 *   module state and reads only four process variables, so it cannot be used to amplify anything.
 */

/**
 * The environments an AfterWorth API deployment may declare. There is deliberately no `dev` member:
 * the project NAMED "afterworth-dev" is the application-facing one, so a vocabulary offering a
 * soft-sounding third option is an invitation to select it. The mobile guard's `AppEnvironment`
 * omits it for the same reason.
 */
export type DeclaredEnvironment = "nonprod" | "production";

/** Vercel's own deployment target. Reported as context, never as environment authority. */
export type VercelEnvironment = "production" | "preview" | "development";

export interface EnvironmentFingerprint {
  /** The operator's DECLARATION. `null` when unset or unrecognised — never guessed, never defaulted. */
  environment: DeclaredEnvironment | null;
  /** The AUTHORITY: the project this deployment's Supabase clients are constructed against. */
  supabaseProjectRef: string | null;
  /** The exact commit this deployment was built from, when the platform supplies it. */
  sourceSha: string | null;
  /** Vercel's deployment target, for context. */
  vercelEnv: VercelEnvironment | null;
}

const DECLARED_ENVIRONMENTS: readonly DeclaredEnvironment[] = ["nonprod", "production"];
const VERCEL_ENVIRONMENTS: readonly VercelEnvironment[] = ["production", "preview", "development"];

/** Supabase project refs are exactly twenty lowercase letters. */
const PROJECT_REF = /^[a-z]{20}$/;

/**
 * PURE. The Supabase project ref inside a project URL, or `null`.
 *
 * ★ THE HOST IS MATCHED AT A LABEL BOUNDARY, NEVER AS A SUBSTRING. `https://qxzeougbaarecaiiqsay.
 *   supabase.co.attacker.test` CONTAINS the text that a careless `endsWith`/`includes` check would
 *   accept, and resolves to an attacker. So the URL is parsed, the hostname is split on `.`, and the
 *   shape must be exactly three labels — `<ref>.supabase.co` — with `<ref>` matching the ref
 *   alphabet. Anything else is `null`, which is a refusal and not a default.
 *
 * ★ HTTPS ONLY. A plaintext URL is not a project this deployment may be trusted to have used.
 */
export function parseSupabaseProjectRef(rawUrl: string | undefined | null): string | null {
  if (typeof rawUrl !== "string" || rawUrl.trim() === "") return null;
  let url: URL;
  try {
    url = new URL(rawUrl.trim());
  } catch {
    return null;
  }
  if (url.protocol !== "https:") return null;
  const labels = url.hostname.toLowerCase().split(".");
  if (labels.length !== 3) return null;
  if (labels[1] !== "supabase" || labels[2] !== "co") return null;
  return PROJECT_REF.test(labels[0]) ? labels[0] : null;
}

/**
 * PURE. Read the operator's declaration. Unset, misspelled or unknown all mean `null`.
 *
 * ★ THERE IS NO DEFAULT. A deployment that has not said what it is has not said what it is, and the
 *   honest answer to "which environment is this?" is that nobody wrote it down. Defaulting to
 *   "production" would look conservative and still be a fabrication; defaulting to "nonprod" would
 *   authorise writes. A consumer that requires a declaration refuses `null` at its own gate.
 */
export function parseDeclaredEnvironment(raw: string | undefined | null): DeclaredEnvironment | null {
  return DECLARED_ENVIRONMENTS.find((v) => v === raw) ?? null;
}

/** PURE. Vercel's target, or `null`. */
export function parseVercelEnvironment(raw: string | undefined | null): VercelEnvironment | null {
  return VERCEL_ENVIRONMENTS.find((v) => v === raw) ?? null;
}

/** PURE. A 40-character lowercase git SHA, or `null`. Anything shorter is not a commit identity. */
export function parseSourceSha(raw: string | undefined | null): string | null {
  const v = typeof raw === "string" ? raw.trim() : "";
  return /^[0-9a-f]{40}$/.test(v) ? v : null;
}

/**
 * PURE. Build the fingerprint from an environment mapping.
 *
 * ★ FOUR NAMED READS, NOT A FILTER OVER THE ENVIRONMENT. The difference matters: a deny-list
 *   ("everything except the secrets") leaks by default the moment a variable is added, whereas an
 *   allow-list of four explicit reads cannot. The caller passes `process.env`; only these four keys
 *   are ever touched, and each is narrowed through its own parser before it can reach the response.
 */
export function environmentFingerprint(env: Record<string, string | undefined>): EnvironmentFingerprint {
  return {
    environment: parseDeclaredEnvironment(env.AFTERWORTH_API_ENV),
    supabaseProjectRef: parseSupabaseProjectRef(env.SUPABASE_URL),
    sourceSha: parseSourceSha(env.VERCEL_GIT_COMMIT_SHA),
    vercelEnv: parseVercelEnvironment(env.VERCEL_ENV),
  };
}

/**
 * GET /api/environment (physically /api/invitations/environment — see the dispatcher).
 *
 * Always 200 for a GET: an incomplete fingerprint is reported as nulls rather than as an error,
 * because "this deployment declares nothing" is an ANSWER a guard must be able to act on, and a 500
 * is indistinguishable from a deployment that predates the endpoint.
 *
 * `no-store`, because a cached fingerprint would let a client believe an origin is something it was
 * only previously configured to be.
 */
export async function handle(req: Request): Promise<Response> {
  if (req.method !== "GET") {
    return new Response(JSON.stringify({ error: "method_not_allowed" }), {
      status: 405,
      headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
    });
  }
  return new Response(JSON.stringify(environmentFingerprint(process.env as Record<string, string | undefined>)), {
    status: 200,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}
