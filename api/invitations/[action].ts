/**
 * /api/invitations/[action]
 *
 *   POST  action ∈ {accept, bind, decline, preview, resolve, create_owner}
 *   GET   action ∈ {drain_email_outbox}
 *
 * ONE serverless function serving every invitation route — consolidated to reclaim Vercel Hobby
 * 12-function-per-deployment headroom (the grants/[action].ts + access-requests/[action].ts
 * pattern). The public URLs are UNCHANGED (/api/invitations/{accept,bind,decline,preview,resolve});
 * each of those handlers moved BYTE-IDENTICAL to lib/invitations/<action>.ts, so the iOS callers
 * need NO change.
 *
 * ★ ADDING ACTIONS HERE COSTS NOTHING. Vercel counts FILES under api/, not exported methods, and
 * the deployment is at 12/12 — api/claims/[action].ts calls itself "the LAST Vercel Hobby function
 * slot". create_owner and drain_email_outbox therefore ride this dispatcher rather than taking
 * slots that do not exist. The count is 12 before this change and 12 after; a test asserts it.
 *
 * ★ WHY THE CRON LIVES HERE AND NOT IN api/claims. The claims dispatcher already owns an unrelated
 * cron (drain_purge_outbox). Putting invitation delivery there would make one function the drain
 * for two unrelated subsystems, so a claims deploy could break invitation delivery and a reader
 * looking for invitation code would have no reason to open a file named claims. The invitation
 * dispatcher exists and had room, so the conversion the brief anticipated was never needed.
 *
 * This dispatcher ONLY routes by the {action} URL segment and forwards the request — it never reads
 * the body (each handler owns its own method/auth/body handling; e.g. preview has no method guard
 * by design). Auth differs per action and is enforced INSIDE each handler: a user JWT for the five
 * original actions and create_owner, and CRON_SECRET for drain_email_outbox.
 */

import { handle as accept } from "../../lib/invitations/accept.js";
import { handle as bind } from "../../lib/invitations/bind.js";
import { handle as createOwner } from "../../lib/invitations/createOwner.js";
import { handle as decline } from "../../lib/invitations/decline.js";
import { handle as drainEmailOutbox } from "../../lib/invitations/drainEmailOutbox.js";
import { handle as preview } from "../../lib/invitations/preview.js";
import { handle as resolve } from "../../lib/invitations/resolve.js";

const POST_HANDLERS: Record<string, (req: Request) => Promise<Response>> = {
  accept,
  bind,
  create_owner: createOwner,
  decline,
  preview,
  resolve,
};

const GET_HANDLERS: Record<string, (req: Request) => Promise<Response>> = {
  drain_email_outbox: drainEmailOutbox,
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

function notFound(): Response {
  return new Response(JSON.stringify({ error: "not_found" }), {
    status: 404,
    headers: { "Content-Type": "application/json" },
  });
}

export async function POST(req: Request): Promise<Response> {
  const handler = POST_HANDLERS[actionFromUrl(req.url)];
  if (!handler) return notFound();
  return handler(req);
}

export async function GET(req: Request): Promise<Response> {
  const handler = GET_HANDLERS[actionFromUrl(req.url)];
  if (!handler) return notFound();
  return handler(req);
}
