/**
 * Rate-limit enforcement stub.
 *
 * Phase 1: Returns null (no rate limit applied).
 * Phase 3: Will check Upstash Redis and return a 429 Response if
 *          the request exceeds the configured limit for the bucket.
 */
export async function enforce(
  _req: Request,
  _bucket: string
): Promise<Response | null> {
  // Phase 1: no rate limiting. Real implementation in Phase 3.
  return null;
}
