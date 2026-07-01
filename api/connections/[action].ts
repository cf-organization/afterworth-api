/**
 * POST /api/connections/[action]   where action ∈ {create_link_token, exchange, refresh, list}
 *
 * ONE serverless function serving all four account-aggregation routes — consolidated to fit the
 * Vercel Hobby 12-function-per-deployment cap (the vault/grants/[action].ts + access-requests
 * pattern already in prod). Public URLs are /api/connections/{create_link_token,exchange,refresh,
 * list}; the iOS caller needs one base path.
 *
 * PROVIDER CONTAINMENT: every Plaid specific lives in lib/plaid.ts. This endpoint speaks only the
 * provider-agnostic surface (createLinkToken / exchangePublicToken / fetchAccounts /
 * normalizeAccounts) + a 'plaid' tag, so swapping to MX/Finicity changes lib/<provider>.ts ONLY.
 *
 * TOKEN CONTAINMENT: the access_token never touches the client. `exchange` hands it to the
 * create_connection DEFINER RPC, which stores it in the grant-less connection_secrets table;
 * `refresh` reads it back via the get_connection_access_token DEFINER RPC and uses it SERVER-SIDE
 * only. The client only ever sees the reference_token handle + normalized balances.
 *
 * Bodies:
 *   create_link_token    {}                                                -> { linkToken }
 *   sandbox_public_token { institutionId? }  (B3a TEMPORARY; strip at B3b)  -> { publicToken }
 *   exchange             { estateId, publicToken, institutionId?,
 *                          institutionName? }                              -> { connection }   (no token)
 *   refresh              { connectionId }                                  -> { assets: [] }
 *   list                 { estateId }                                      -> { connections: [], assets: [] }
 * Errors: RPC SQLSTATE -> HTTP (42501->403, P0001->400, else 502); Plaid 4xx -> 400, else 502.
 *   401 auth, 400 bad body, 404 unknown action, 405 method.
 */

import { enforce } from "../../lib/rateLimit.js";
import { verifyJwt, getAuthedSupabaseClient, AuthError } from "../../lib/auth.js";
import {
  createLinkToken,
  sandboxCreatePublicToken,
  exchangePublicToken,
  fetchAccounts,
  fetchHoldings,
  normalizeAccounts,
  PlaidError,
} from "../../lib/plaid.js";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// NOTE — sandbox_public_token is a TRACKED-TEMPORARY B3a helper: the iOS MockLinkHandler mints a
// sandbox public_token SERVER-SIDE here (Plaid secret stays in Vercel, never on device) to prove the
// create->exchange->reload loop without the LinkKit SDK. STRIP at B3b, when the real native LinkKit
// produces the public_token. Auth-gated + self-disables when PLAID_ENV=production.
const ACTIONS = new Set(["create_link_token", "sandbox_public_token", "exchange", "refresh", "list"]);

const CONNECTION_COLUMNS =
  "id, estate_id, provider, institution_id, institution_name, reference_token, status, created_at, updated_at";
const ASSET_COLUMNS =
  "id, estate_id, connection_id, institution_name, provider_name, asset_group, asset_category, " +
  "asset_subtype, source_type, masked_identifier, balance_cents, currency, holdings, " +
  "refresh_timestamp, last_sync_status, confidence_level, verification_status, created_at";

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
function errorResponse(status: number, code: string): Response {
  return jsonResponse(status, { error: code });
}
function authErrorResponse(err: AuthError): Response {
  switch (err.kind) {
    case "missing": return errorResponse(401, "missing_token");
    case "malformed": return errorResponse(401, "malformed_token");
    case "expired": return errorResponse(401, "expired_token");
    case "invalid": return errorResponse(401, "invalid_token");
  }
}
// RPC SQLSTATE -> HTTP. 42501 (owner-gate / unauth) -> 403; P0001 (raised) -> 400; else 502.
function rpcErrorResponse(code: string | undefined, message: string, fn: string): Response {
  if (code === "42501") return errorResponse(403, "forbidden");
  if (code === "P0001") return jsonResponse(400, { error: "bad_request", message });
  console.error(`${fn} raised (unmapped):`, code, message);
  return errorResponse(502, "upstream_error");
}
// Plaid 4xx (bad token/input) -> 400; everything else -> 502 upstream.
function plaidErrorResponse(err: PlaidError): Response {
  console.error("Plaid error:", err.status, err.code, err.message);
  if (err.status >= 400 && err.status < 500) {
    return jsonResponse(400, { error: "provider_request_error", code: err.code });
  }
  return jsonResponse(502, { error: "provider_error", code: err.code });
}

function actionFromUrl(rawUrl: string): string {
  let path = rawUrl;
  try {
    path = new URL(rawUrl).pathname;
  } catch {
    /* rawUrl may already be a path */
  }
  path = path.replace(/[?#].*$/, "").replace(/\/+$/, "");
  return path.slice(path.lastIndexOf("/") + 1);
}

/* eslint-disable @typescript-eslint/no-explicit-any */
function toConnectionWire(r: any) {
  return {
    id: r.id,
    estateId: r.estate_id,
    provider: r.provider,
    institutionId: r.institution_id,
    institutionName: r.institution_name,
    referenceToken: r.reference_token,
    status: r.status,
    createdAt: r.created_at,
    updatedAt: r.updated_at,
  };
}
function toAssetWire(r: any) {
  return {
    id: r.id,
    estateId: r.estate_id,
    connectionId: r.connection_id,
    institutionName: r.institution_name,
    providerName: r.provider_name,
    assetGroup: r.asset_group,
    assetCategory: r.asset_category,
    assetSubtype: r.asset_subtype,
    sourceType: r.source_type,
    maskedIdentifier: r.masked_identifier,
    balanceCents: r.balance_cents,
    currency: r.currency,
    holdings: r.holdings,
    refreshTimestamp: r.refresh_timestamp,
    lastSyncStatus: r.last_sync_status,
    confidenceLevel: r.confidence_level,
    verificationStatus: r.verification_status,
    createdAt: r.created_at,
  };
}
/* eslint-enable @typescript-eslint/no-explicit-any */

export async function POST(req: Request): Promise<Response> {
  if (req.method !== "POST") {
    return errorResponse(405, "method_not_allowed");
  }

  const action = actionFromUrl(req.url);
  if (!ACTIONS.has(action)) {
    return errorResponse(404, "not_found");
  }

  let user;
  try {
    user = await verifyJwt(req);
  } catch (err) {
    if (err instanceof AuthError) return authErrorResponse(err);
    console.error("Unexpected auth error:", err);
    return errorResponse(502, "auth_upstream_error");
  }

  let raw: unknown;
  try {
    raw = await req.json();
  } catch {
    // create_link_token needs no body — tolerate an empty/absent one.
    raw = {};
  }
  if (raw === null || typeof raw !== "object") {
    return errorResponse(400, "invalid_request");
  }
  const o = raw as Record<string, unknown>;

  const rateLimitResponse = await enforce(req, `connections_${action}`);
  if (rateLimitResponse) {
    return rateLimitResponse;
  }

  const supabase = getAuthedSupabaseClient(user.jwt);

  // ----- sandbox_public_token: TRACKED-TEMPORARY B3a helper (strip at B3b). Mints a Plaid sandbox
  //       public_token SERVER-SIDE so the iOS MockLinkHandler never touches the Plaid secret.
  //       Auth-gated (verifyJwt above); disabled when PLAID_ENV=production. -----
  if (action === "sandbox_public_token") {
    if (process.env.PLAID_ENV === "production") return errorResponse(404, "not_found");
    const institutionId = typeof o.institutionId === "string" ? o.institutionId : undefined;
    try {
      const publicToken = await sandboxCreatePublicToken(institutionId);
      return jsonResponse(200, { publicToken });
    } catch (err) {
      if (err instanceof PlaidError) return plaidErrorResponse(err);
      console.error("sandbox_public_token error:", err);
      return errorResponse(502, "provider_error");
    }
  }

  // ----- create_link_token: ask Plaid for a Link token (no DB touch) -----
  if (action === "create_link_token") {
    try {
      const linkToken = await createLinkToken(user.userId);
      return jsonResponse(200, { linkToken });
    } catch (err) {
      if (err instanceof PlaidError) return plaidErrorResponse(err);
      console.error("create_link_token error:", err);
      return errorResponse(502, "provider_error");
    }
  }

  // ----- exchange: public_token -> access_token -> store server-only via create_connection RPC -----
  if (action === "exchange") {
    const estateId = typeof o.estateId === "string" ? o.estateId.trim() : "";
    const publicToken = typeof o.publicToken === "string" ? o.publicToken.trim() : "";
    if (!UUID_RE.test(estateId) || publicToken.length === 0) {
      return errorResponse(400, "invalid_request");
    }
    const institutionId = typeof o.institutionId === "string" ? o.institutionId : null;
    const institutionName = typeof o.institutionName === "string" ? o.institutionName : null;

    let accessToken: string;
    let itemId: string;
    try {
      ({ accessToken, itemId } = await exchangePublicToken(publicToken));
    } catch (err) {
      if (err instanceof PlaidError) return plaidErrorResponse(err);
      console.error("exchange error:", err);
      return errorResponse(502, "provider_error");
    }

    // The access_token lands ONLY in connection_secrets (grant-less); the client gets back the
    // reference_token (= the opaque Plaid item id), NEVER the access_token.
    const { data, error } = await supabase.rpc("create_connection", {
      p_estate_id: estateId,
      p_provider: "plaid",
      p_institution_id: institutionId,
      p_institution_name: institutionName,
      p_reference_token: itemId,
      p_access_token: accessToken,
    });
    if (error) return rpcErrorResponse(error.code, error.message, "create_connection");
    if (!Array.isArray(data) || data.length === 0) {
      console.error("create_connection returned unexpected shape:", data);
      return errorResponse(502, "upstream_unexpected_shape");
    }
    return jsonResponse(200, { connection: toConnectionWire(data[0]) });
  }

  // ----- refresh: server-only token read -> Plaid fetch -> normalize -> replace normalized_assets -----
  if (action === "refresh") {
    const connectionId = typeof o.connectionId === "string" ? o.connectionId.trim() : "";
    if (!UUID_RE.test(connectionId)) return errorResponse(400, "invalid_request");

    // Resolve the connection's estate/institution (RLS-scoped: caller must be a member).
    const { data: connRow, error: connErr } = await supabase
      .from("connections")
      .select(CONNECTION_COLUMNS)
      .eq("id", connectionId)
      .maybeSingle();
    if (connErr) {
      console.error("connections lookup error:", connErr);
      return errorResponse(502, "upstream_error");
    }
    if (!connRow) return errorResponse(404, "not_found");
    const conn = toConnectionWire(connRow);

    // SERVER-ONLY token read (owner-gated DEFINER RPC). Never returned to the client.
    const { data: tokenData, error: tokenErr } = await supabase.rpc("get_connection_access_token", {
      p_connection_id: connectionId,
    });
    if (tokenErr) return rpcErrorResponse(tokenErr.code, tokenErr.message, "get_connection_access_token");
    const accessToken = typeof tokenData === "string" ? tokenData : "";
    if (accessToken.length === 0) return errorResponse(404, "not_found");

    // Plaid fetch + normalize (the firewall — nothing Plaid-shaped past this point). Pull BOTH
    // shapes: cash balances (all accounts) AND investment holdings (brokerage/retirement positions).
    let normalized;
    try {
      const accounts = await fetchAccounts(accessToken);
      const { holdings, securities } = await fetchHoldings(accessToken);
      normalized = normalizeAccounts(accounts, holdings, securities);
    } catch (err) {
      if (err instanceof PlaidError) return plaidErrorResponse(err);
      console.error("refresh fetch error:", err);
      return errorResponse(502, "provider_error");
    }

    // Replace this connection's normalized rows (authed write, owner RLS policy). Idempotent refresh.
    const { error: delErr } = await supabase
      .from("normalized_assets")
      .delete()
      .eq("connection_id", connectionId);
    if (delErr) {
      console.error("normalized_assets delete error:", delErr);
      return errorResponse(502, "upstream_error");
    }

    const nowIso = new Date().toISOString();
    const rows = normalized.map((n) => ({
      estate_id: conn.estateId,
      connection_id: connectionId,
      institution_name: conn.institutionName,
      provider_name: conn.provider,
      asset_group: n.asset_group,
      asset_category: n.asset_category,
      asset_subtype: n.asset_subtype,
      source_type: n.source_type,
      masked_identifier: n.masked_identifier,
      balance_cents: n.balance_cents,
      currency: n.currency,
      holdings: n.holdings,
      refresh_timestamp: nowIso,
      last_sync_status: "live_connected",
    }));

    if (rows.length === 0) return jsonResponse(200, { assets: [] });

    const { data: inserted, error: insErr } = await supabase
      .from("normalized_assets")
      .insert(rows)
      .select(ASSET_COLUMNS);
    if (insErr) {
      console.error("normalized_assets insert error:", insErr);
      return errorResponse(502, "upstream_error");
    }
    return jsonResponse(200, { assets: (inserted ?? []).map(toAssetWire) });
  }

  // ----- list: RLS-scoped connections + normalized_assets for an estate -----
  const estateId = typeof o.estateId === "string" ? o.estateId.trim() : "";
  if (!UUID_RE.test(estateId)) return errorResponse(400, "invalid_request");

  const { data: connections, error: connErr } = await supabase
    .from("connections")
    .select(CONNECTION_COLUMNS)
    .eq("estate_id", estateId)
    .order("created_at", { ascending: false });
  if (connErr) {
    console.error("connections list error:", connErr);
    return errorResponse(502, "upstream_error");
  }

  const { data: assets, error: assetErr } = await supabase
    .from("normalized_assets")
    .select(ASSET_COLUMNS)
    .eq("estate_id", estateId)
    .order("created_at", { ascending: false });
  if (assetErr) {
    console.error("normalized_assets list error:", assetErr);
    return errorResponse(502, "upstream_error");
  }

  return jsonResponse(200, {
    connections: (connections ?? []).map(toConnectionWire),
    assets: (assets ?? []).map(toAssetWire),
  });
}
