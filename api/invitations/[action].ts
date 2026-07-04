/**
 * POST /api/invitations/[action]   where action ∈ {accept, bind, decline, preview, resolve}
 *
 * ONE serverless function serving all five invitation routes — consolidated to reclaim Vercel Hobby
 * 12-function-per-deployment headroom (the grants/[action].ts + access-requests/[action].ts pattern).
 * The public URLs are UNCHANGED (/api/invitations/{accept,bind,decline,preview,resolve}); each handler
 * moved BYTE-IDENTICAL to lib/invitations/<action>.ts (only import depth + the export name changed), so
 * the iOS callers need NO change.
 *
 * This dispatcher ONLY routes by the {action} URL segment and forwards the request — it never reads the
 * body (each handler owns method/auth/body handling; e.g. preview has no method guard by design). Only
 * POST is exported, so a non-POST request 405s exactly as the original file-based routes did.
 */

import { handle as accept } from "../../lib/invitations/accept.js";
import { handle as bind } from "../../lib/invitations/bind.js";
import { handle as decline } from "../../lib/invitations/decline.js";
import { handle as preview } from "../../lib/invitations/preview.js";
import { handle as resolve } from "../../lib/invitations/resolve.js";

const HANDLERS: Record<string, (req: Request) => Promise<Response>> = {
  accept,
  bind,
  decline,
  preview,
  resolve,
};

// Resolve the {action} segment from the request URL (robust to absolute URL or bare path, query
// strings, and trailing slashes) — identical to grants/[action].ts.
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

export async function POST(req: Request): Promise<Response> {
  const handler = HANDLERS[actionFromUrl(req.url)];
  if (!handler) {
    return new Response(JSON.stringify({ error: "not_found" }), {
      status: 404,
      headers: { "Content-Type": "application/json" },
    });
  }
  return handler(req);
}
