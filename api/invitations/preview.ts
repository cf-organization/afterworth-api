import { createClient } from "@supabase/supabase-js";
import { clientKey, isRateLimited } from "../../lib/rateLimit";

type PreviewRequest = {
  token?: unknown;
};

type InvitationPreview = {
  tokenFingerprint: string;
  invitationKind: string;
  proposedRole: string;
  estateDisplayName: string | null;
  inviterDisplayName: string | null;
  inviteeEmailHint: string | null;
  inviteePhoneHint: string | null;
  expiresAt: string;
  isExpired: boolean;
  isRevoked: boolean;
};

const jsonHeaders = {
  "Content-Type": "application/json",
};

export default async function handler(request: Request): Promise<Response> {
  if (request.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  if (isRateLimited(clientKey(request), { limit: 30, windowMs: 60_000 })) {
    return json({ error: "rate_limited" }, 429);
  }

  const body = await parseBody(request);
  const token = body?.token;

  if (typeof token !== "string" || token.length < 16 || token.length > 512) {
    return json({ preview: null }, 200);
  }

  const supabaseUrl = requiredEnv("SUPABASE_URL");
  const publishableKey = requiredEnv("SUPABASE_PUBLISHABLE_KEY");
  if (!supabaseUrl || !publishableKey) {
    return json({ error: "server_not_configured" }, 500);
  }

  const supabase = createClient(supabaseUrl, publishableKey, {
    auth: { persistSession: false },
  });

  const { data, error } = await supabase.rpc("invitation_preview", {
    p_token: token,
  });

  if (error) {
    return json({ error: "preview_failed" }, 500);
  }

  const preview = normalizePreview(data);
  return json({ preview }, 200);
}

async function parseBody(request: Request): Promise<PreviewRequest | null> {
  try {
    return (await request.json()) as PreviewRequest;
  } catch {
    return null;
  }
}

function normalizePreview(data: unknown): InvitationPreview | null {
  const record = firstRecord(data);
  if (!record) {
    return null;
  }

  const tokenFingerprint = stringValue(record, "tokenFingerprint", "token_fingerprint");
  const invitationKind = stringValue(record, "invitationKind", "invitation_kind");
  const proposedRole = stringValue(record, "proposedRole", "proposed_role");
  const expiresAt = stringValue(record, "expiresAt", "expires_at");

  if (!tokenFingerprint || !invitationKind || !proposedRole || !expiresAt) {
    return null;
  }

  return {
    tokenFingerprint,
    invitationKind,
    proposedRole,
    estateDisplayName: nullableStringValue(record, "estateDisplayName", "estate_display_name"),
    inviterDisplayName: nullableStringValue(record, "inviterDisplayName", "inviter_display_name"),
    inviteeEmailHint: nullableStringValue(record, "inviteeEmailHint", "invitee_email_hint"),
    inviteePhoneHint: nullableStringValue(record, "inviteePhoneHint", "invitee_phone_hint"),
    expiresAt,
    isExpired: booleanValue(record, "isExpired", "is_expired"),
    isRevoked: booleanValue(record, "isRevoked", "is_revoked"),
  };
}

function firstRecord(data: unknown): Record<string, unknown> | null {
  if (Array.isArray(data)) {
    return data.length > 0 ? firstRecord(data[0]) : null;
  }

  if (isRecord(data)) {
    if ("preview" in data) {
      return firstRecord(data.preview);
    }
    return data;
  }

  return null;
}

function stringValue(
  record: Record<string, unknown>,
  camelKey: string,
  snakeKey: string
): string | null {
  const value = record[camelKey] ?? record[snakeKey];
  return typeof value === "string" && value.length > 0 ? value : null;
}

function nullableStringValue(
  record: Record<string, unknown>,
  camelKey: string,
  snakeKey: string
): string | null {
  const value = record[camelKey] ?? record[snakeKey];
  return typeof value === "string" ? value : null;
}

function booleanValue(
  record: Record<string, unknown>,
  camelKey: string,
  snakeKey: string
): boolean {
  const value = record[camelKey] ?? record[snakeKey];
  return typeof value === "boolean" ? value : false;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function requiredEnv(name: string): string | null {
  const value = process.env[name];
  return value && value.length > 0 ? value : null;
}

function json(payload: unknown, status: number): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: jsonHeaders,
  });
}
