// Shared shapes for the access-request endpoints (api/access-requests/*).
//
// The access_requests row (snake_case, as returned by the RPCs and the list select) is
// reshaped to a camelCase wire the iOS model decodes 1:1 — matching the api/beneficiaries
// + lib/grants convention.

export interface AccessRequestRow {
  id: string;
  estate_id: string;
  requester_user_id: string;
  requester_role: string | null;
  category: string;
  reason: string | null;
  status: string;
  created_at: string | null;
  resolved_at: string | null;
  resolved_by_user_id: string | null;
  resulting_grant_id: string | null;
}

export function toAccessRequestWire(r: AccessRequestRow): Record<string, unknown> {
  return {
    id: r.id,
    estateId: r.estate_id,
    requesterUserId: r.requester_user_id,
    requesterRole: r.requester_role,
    category: r.category,
    reason: r.reason,
    status: r.status,
    createdAt: r.created_at,
    resolvedAt: r.resolved_at,
    resolvedByUserId: r.resolved_by_user_id,
    resultingGrantId: r.resulting_grant_id,
  };
}

// Map an access-request RPC SQLSTATE to an HTTP response, passing the RPC's clean message
// through. 42501 -> 403 (not an eligible member / not owner; distinguished by message),
// 23505 -> 409 (a pending request already exists), P0001 -> 400 (unsupported category /
// not-found / not-pending / bad tier). Returns null for unmapped codes so the caller falls
// back to 502. Mirrors grantRpcErrorResponse.
export function accessRequestRpcErrorResponse(
  code: string | undefined,
  message: string,
): Response | null {
  const json = (status: number, tag: string): Response =>
    new Response(JSON.stringify({ error: tag, message }), {
      status,
      headers: { "Content-Type": "application/json" },
    });
  switch (code) {
    case "42501":
      return json(403, "forbidden");
    case "23505":
      return json(409, "duplicate_request");
    case "P0001":
      return json(400, "invalid_request");
    default:
      return null;
  }
}
