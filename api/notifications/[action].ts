/**
 * POST /api/notifications/[action]   where action ∈ {list, mark_read, mark_all_read, unread_count}
 *
 * The notifications-center read surface. SELF-SCOPED by RLS (user_id = auth.uid()) — read/mark-read
 * are plain RLS-scoped queries through the authed client (no RPCs, like grants/list). Emission is
 * NOT here: notifications are created only by the SECURITY DEFINER emit_notification (called by event
 * sources); a client has no INSERT privilege/policy, so it cannot forge notifications.
 *
 * Bodies:
 *   list          {}       -> { notifications: [] }   (self, newest first)
 *   mark_read     { id }   -> { notification }         (sets read_at; 404 if not mine/not found)
 *   mark_all_read {}       -> { updated: n }           (all my unread)
 *   unread_count  {}       -> { count }                (my unread)
 */

import { enforce } from "../../lib/rateLimit.js";
import { verifyJwt, getAuthedSupabaseClient, AuthError } from "../../lib/auth.js";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ACTIONS = new Set(["list", "mark_read", "mark_all_read", "unread_count"]);
// The reconciled live schema keeps `kind` (logical category) + `read` (boolean); see migration 0009.
const NOTIF_COLUMNS =
  "id, user_id, estate_id, kind, title, body, channel, action_deep_link, " +
  "related_document_id, payload, read, created_at";

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
// notifications row -> the iOS AppNotification wire (camelCase; isRead derived from read_at).
function toNotificationWire(r: any) {
  return {
    id: r.id,
    estateId: r.estate_id,
    userId: r.user_id,
    title: r.title,
    body: r.body,
    channel: r.channel ?? "inApp",
    category: r.kind,                 // wire.category <- column.kind (reconciled schema)
    isRead: r.read === true,          // wire.isRead   <- column.read (boolean)
    createdAt: r.created_at,
    actionDeepLink: r.action_deep_link,
    relatedDocumentId: r.related_document_id,
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
    raw = {};
  }
  const o = (raw && typeof raw === "object" ? raw : {}) as Record<string, unknown>;

  const rateLimitResponse = await enforce(req, `notifications_${action}`);
  if (rateLimitResponse) {
    return rateLimitResponse;
  }

  const supabase = getAuthedSupabaseClient(user.jwt);

  // ----- list: self-scoped (RLS), newest first -----
  if (action === "list") {
    const { data, error } = await supabase
      .from("notifications")
      .select(NOTIF_COLUMNS)
      .order("created_at", { ascending: false });
    if (error) {
      console.error("notifications list error:", error);
      return errorResponse(502, "upstream_error");
    }
    return jsonResponse(200, {
      notifications: ((data ?? []) as unknown as Record<string, unknown>[]).map(toNotificationWire),
    });
  }

  // ----- unread_count: my unread (RLS-scoped) -----
  if (action === "unread_count") {
    const { count, error } = await supabase
      .from("notifications")
      .select("id", { count: "exact", head: true })
      .eq("read", false);
    if (error) {
      console.error("notifications unread_count error:", error);
      return errorResponse(502, "upstream_error");
    }
    return jsonResponse(200, { count: count ?? 0 });
  }

  // ----- mark_all_read: set read_at on all my unread -----
  if (action === "mark_all_read") {
    const { data, error } = await supabase
      .from("notifications")
      .update({ read: true })
      .eq("read", false)
      .select("id");
    if (error) {
      console.error("notifications mark_all_read error:", error);
      return errorResponse(502, "upstream_error");
    }
    return jsonResponse(200, { updated: (data ?? []).length });
  }

  // ----- mark_read: set read_at on one of MY notifications (RLS scopes to self) -----
  // action === "mark_read"
  const id = typeof o.id === "string" ? o.id.trim() : "";
  if (!UUID_RE.test(id)) return errorResponse(400, "invalid_request");

  const { data, error } = await supabase
    .from("notifications")
    .update({ read: true })
    .eq("id", id)
    .select(NOTIF_COLUMNS);
  if (error) {
    console.error("notifications mark_read error:", error);
    return errorResponse(502, "upstream_error");
  }
  const row = ((data ?? []) as unknown as Record<string, unknown>[])[0];
  if (!row) return errorResponse(404, "not_found");   // not mine (RLS) or nonexistent
  return jsonResponse(200, { notification: toNotificationWire(row) });
}
