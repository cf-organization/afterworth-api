// Shared shapes for the document-grant endpoints (api/vault/grants/*).
//
// The access_grants row (snake_case, as returned by create_document_grant /
// revoke_document_grant and the list select) is reshaped to a camelCase wire that the
// iOS DocumentGrant model decodes 1:1 — matching the api/beneficiaries convention.

export interface GrantRow {
  id: string;
  estate_id: string;
  grantee_user_id: string;
  grantee_role: string;
  professional_type: string | null;
  document_id: string | null;
  category: string | null;
  visibility_tier: string;
  release_condition: string;
  requires_step_up: boolean;
  status: string;
  granted_by_user_id: string;
  created_at: string | null;
  updated_at: string | null;
  revoked_at: string | null;
  revoked_by_user_id: string | null;
}

export function toGrantWire(r: GrantRow): Record<string, unknown> {
  return {
    id: r.id,
    estateId: r.estate_id,
    granteeUserId: r.grantee_user_id,
    granteeRole: r.grantee_role,
    professionalType: r.professional_type,
    documentId: r.document_id,
    category: r.category,
    visibilityTier: r.visibility_tier,
    releaseCondition: r.release_condition,
    requiresStepUp: r.requires_step_up,
    status: r.status,
    grantedByUserId: r.granted_by_user_id,
    createdAt: r.created_at,
    revokedAt: r.revoked_at,
  };
}

// Map a create/revoke RPC SQLSTATE to an HTTP response, passing the RPC's clean
// message through (decision D: the 403 ceiling/owner messages must reach iOS).
// 42501 -> 403 (not-owner OR ceiling; distinguished by message), 23505 -> 409
// (duplicate), P0001 -> 400 (owner-grant / not-found). Returns null for unmapped
// codes so the caller can fall back to 502. NOTE: the live RPCs raise 23505 + P0001
// (NOT P0010/P0011/P0002 — those were the pre-fix codes that returned 500).
export function grantRpcErrorResponse(
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
      return json(409, "duplicate_grant");
    case "P0001":
      return json(400, "invalid_grant");
    default:
      return null;
  }
}
