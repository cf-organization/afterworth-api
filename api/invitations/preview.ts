// CLOUDFLARE WAF RULES (deferred to Phase 5, kept for documentation):
//   Rule 1: Bot Fight Mode ON for /api/invitations/*
//   Rule 2: Managed Challenge if rate(/api/invitations/preview, 1m) > 30
//   Rule 3: Block if rate(/api/invitations/preview, 1h) > 500 per IP
//   Rule 4: Block requests with content-length > 2KB on this path
//   Rule 5: Block requests where JSON body's "token" exceeds 512 chars

import { createClient } from "@supabase/supabase-js";
import { enforce } from "../../lib/rateLimit.js";

const supabase = createClient(
  process.env.SUPABASE_URL!,
  process.env.SUPABASE_PUBLISHABLE_KEY!,
  { auth: { persistSession: false } },
);

export default async function handler(req: Request) {
  if (req.method !== "POST") {
    return new Response("method not allowed", { status: 405 });
  }

  const limited = await enforce(req, "invitationPreview");
  if (limited) return limited;

  let body: { token?: string };
  try {
    body = await req.json();
  } catch {
    return new Response("bad json", { status: 400 });
  }

  const token = body.token?.trim();
  if (!token || token.length < 16 || token.length > 512) {
    return Response.json({ preview: null }, { status: 200 });
  }

  const { data, error } = await supabase.rpc("invitation_preview", {
    p_token: token,
  });

  if (error) {
    console.error("invitation_preview rpc error", error.code);
    return Response.json({ preview: null }, { status: 200 });
  }

  if (!data || data.length === 0) {
    return Response.json({ preview: null }, { status: 200 });
  }

  const row = data[0];
  return Response.json({
    preview: {
      tokenFingerprint: row.token_fingerprint,
      invitationKind: row.invitation_kind,
      proposedRole: row.proposed_role,
      estateDisplayName: row.estate_display_name,
      inviterDisplayName: row.inviter_display_name,
      inviteeEmailHint: row.invitee_email_hint,
      inviteePhoneHint: row.invitee_phone_hint,
      expiresAt: row.expires_at,
      isExpired: row.is_expired,
      isRevoked: row.is_revoked,
    },
  });
}
