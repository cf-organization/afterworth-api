// lib/plaid.ts — THE ONLY Plaid-aware backend module.
//
// All Plaid specifics (base URL, token semantics, raw account/balance JSON) live here. The
// normalizer (`normalizeAccounts`) is the FIREWALL: Plaid-raw -> NormalizedAssetRecord rows, so
// ONLY normalized records + a provider tag + the opaque token leave this module. Swapping to
// MX/Finicity = a sibling lib/<provider>.ts implementing the same surface — the schema, the RPCs,
// and api/connections/[action].ts do NOT change.
//
// Credentials/secret: PLAID_CLIENT_ID + PLAID_SECRET (env, server-only, gitignored — the
// SUPABASE_SECRET_KEY discipline). Sandbox base URL by default.

const PLAID_BASE = process.env.PLAID_ENV === "production"
  ? "https://production.plaid.com"
  : process.env.PLAID_ENV === "development"
    ? "https://development.plaid.com"
    : "https://sandbox.plaid.com";

function plaidCreds(): { client_id: string; secret: string } {
  const client_id = process.env.PLAID_CLIENT_ID;
  const secret = process.env.PLAID_SECRET;
  if (!client_id || !secret) throw new Error("PLAID_CLIENT_ID / PLAID_SECRET not configured");
  return { client_id, secret };
}

async function plaidPost<T>(path: string, body: Record<string, unknown>): Promise<T> {
  const res = await fetch(`${PLAID_BASE}${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ ...plaidCreds(), ...body }),
  });
  const json = (await res.json()) as Record<string, unknown>;
  if (!res.ok) {
    const code = (json.error_code as string) ?? "plaid_error";
    const msg = (json.error_message as string) ?? `Plaid ${path} failed (${res.status})`;
    throw new PlaidError(res.status, code, msg);
  }
  return json as T;
}

export class PlaidError extends Error {
  constructor(public status: number, public code: string, message: string) {
    super(message);
    this.name = "PlaidError";
  }
}

// --- Link / token flow ---

export async function createLinkToken(clientUserId: string): Promise<string> {
  const data = await plaidPost<{ link_token: string }>("/link/token/create", {
    user: { client_user_id: clientUserId },
    client_name: "AfterWorth",
    // investments -> brokerage/retirement HOLDINGS (/investments/holdings/get) — a brokerage acct's
    //                value IS its holdings, not a cash balance, so investments is what makes those
    //                account types meaningful. No "transactions" (no spending analytics this slice).
    // NB: "balance" is NOT a requestable Link product (→ INVALID_PRODUCT). Cash balances come from
    //     /accounts/balance/get, which works on ANY item without being listed here.
    products: ["investments"],
    country_codes: ["US"],
    language: "en",
  });
  return data.link_token;
}

/** SANDBOX-ONLY: mint a public_token with NO Link UI, so the flow is curl-provable.
 *  NOT wired to any deployed route — the sandbox_public_token endpoint was intentionally removed so
 *  prod carries no token-minting surface. This is the re-proof building block: to re-run the curl
 *  matrix, temporarily wire it to an action (or hit /sandbox/public_token/create directly).
 *  Defaults to the `investments` product on First Platypus Bank, so the sandbox item carries
 *  investment accounts WITH holdings — the proof must exercise holdings, not just cash. */
export async function sandboxCreatePublicToken(
  institutionId = "ins_109508",          // Plaid sandbox "First Platypus Bank" (supports investments)
  products: string[] = ["investments"],
): Promise<string> {
  const data = await plaidPost<{ public_token: string }>("/sandbox/public_token/create", {
    institution_id: institutionId,
    initial_products: products,
  });
  return data.public_token;
}

export async function exchangePublicToken(
  publicToken: string,
): Promise<{ accessToken: string; itemId: string }> {
  const data = await plaidPost<{ access_token: string; item_id: string }>(
    "/item/public_token/exchange",
    { public_token: publicToken },
  );
  return { accessToken: data.access_token, itemId: data.item_id };
}

// --- Fetch + normalize (the firewall) ---

interface PlaidAccount {
  account_id: string;
  name: string;
  official_name?: string | null;
  type: string;              // depository | investment | credit | loan | ...
  subtype?: string | null;   // checking | savings | ira | 401k | brokerage | ...
  mask?: string | null;
  balances: { current?: number | null; available?: number | null; iso_currency_code?: string | null };
}

export async function fetchAccounts(accessToken: string): Promise<PlaidAccount[]> {
  const data = await plaidPost<{ accounts: PlaidAccount[] }>("/accounts/balance/get", {
    access_token: accessToken,
  });
  return data.accounts ?? [];
}

// /investments/holdings/get shape — DIFFERENT from /accounts/balance/get: positions live in
// `holdings[]` (account_id + security_id + quantity + value), descriptions in `securities[]`.
interface PlaidHolding {
  account_id: string;
  security_id: string;
  quantity?: number | null;
  institution_price?: number | null;
  institution_value?: number | null;     // Plaid's computed market value of the position
  cost_basis?: number | null;
  iso_currency_code?: string | null;
}
interface PlaidSecurity {
  security_id: string;
  name?: string | null;
  ticker_symbol?: string | null;
  type?: string | null;                   // equity | etf | mutual fund | cash | ...
  iso_currency_code?: string | null;
}

// An institution with no investment accounts (or that doesn't support the product) is NORMAL — the
// connection still has cash balances. These codes mean "no holdings here"; anything else rethrows.
const NO_INVESTMENTS_CODES = new Set([
  "PRODUCTS_NOT_SUPPORTED", "NO_INVESTMENT_ACCOUNTS", "NO_ACCOUNTS",
]);

export async function fetchHoldings(
  accessToken: string,
): Promise<{ holdings: PlaidHolding[]; securities: PlaidSecurity[] }> {
  try {
    const data = await plaidPost<{ holdings: PlaidHolding[]; securities: PlaidSecurity[] }>(
      "/investments/holdings/get",
      { access_token: accessToken },
    );
    return { holdings: data.holdings ?? [], securities: data.securities ?? [] };
  } catch (err) {
    if (err instanceof PlaidError && NO_INVESTMENTS_CODES.has(err.code)) {
      return { holdings: [], securities: [] };
    }
    throw err;
  }
}

const RETIREMENT_SUBTYPES = new Set([
  "ira", "roth", "roth 401k", "401k", "401a", "403b", "457b", "sep ira", "simple ira",
  "pension", "retirement", "keogh", "tsp",
]);

/** Map a Plaid account to our asset_group (the swap-later-stable taxonomy). null = skip (out of
 *  scope for this slice — credit/loan/crypto/insurance handled separately). */
function assetGroupFor(type: string, subtype: string | null | undefined): string | null {
  const s = (subtype ?? "").toLowerCase();
  switch (type) {
    case "depository": return "cashBank";
    case "investment":
    case "brokerage":  return RETIREMENT_SUBTYPES.has(s) ? "retirement" : "investmentBrokerage";
    default:           return null;   // credit / loan / other — not in the banks/brokerage/retirement scope
  }
}

// Provider-AGNOSTIC normalized position (no Plaid field names leak past the firewall).
export interface NormalizedHolding {
  name: string;
  ticker: string | null;
  type: string | null;                  // equity | etf | mutual fund | cash | ...
  quantity: number;
  value_cents: number;
  cost_basis_cents: number | null;
  currency: string;
}

export interface NormalizedRow {
  asset_group: string;
  asset_category: string;
  asset_subtype: string;
  source_type: string;
  masked_identifier: string;
  balance_cents: number;
  currency: string;
  holdings: NormalizedHolding[];
}

/**
 * THE FIREWALL: Plaid-raw -> NormalizedAssetRecord rows. Handles BOTH product shapes:
 *   - balance (/accounts/balance/get): every account's total value (cash for depository; for an
 *     investment account `balances.current` IS Plaid's computed market value) -> balance_cents.
 *   - investments (/investments/holdings/get): per-account positions joined holdings⋈securities ->
 *     the `holdings` jsonb slot. Without this, brokerage/retirement HOLDINGS would drop silently.
 * The `accounts` array is the spine (it carries every account incl. investment totals); holdings
 * are attached by account_id. Nothing Plaid-shaped escapes.
 */
export function normalizeAccounts(
  accounts: PlaidAccount[],
  holdings: PlaidHolding[] = [],
  securities: PlaidSecurity[] = [],
): NormalizedRow[] {
  const securityById = new Map(securities.map((s) => [s.security_id, s]));
  const holdingsByAccount = new Map<string, PlaidHolding[]>();
  for (const h of holdings) {
    const list = holdingsByAccount.get(h.account_id) ?? [];
    list.push(h);
    holdingsByAccount.set(h.account_id, list);
  }

  const rows: NormalizedRow[] = [];
  for (const a of accounts) {
    const group = assetGroupFor(a.type, a.subtype);
    if (group === null) continue;       // out of scope (credit/loan/etc.)
    const currency = a.balances.iso_currency_code ?? "USD";
    const dollars = a.balances.current ?? a.balances.available ?? 0;

    const positions: NormalizedHolding[] = (holdingsByAccount.get(a.account_id) ?? []).map((h) => {
      const sec = securityById.get(h.security_id);
      const value = h.institution_value
        ?? ((h.quantity ?? 0) * (h.institution_price ?? 0));
      return {
        name: sec?.name ?? sec?.ticker_symbol ?? "Holding",
        ticker: sec?.ticker_symbol ?? null,
        type: sec?.type ?? null,
        quantity: h.quantity ?? 0,
        value_cents: Math.round(value * 100),
        cost_basis_cents: h.cost_basis != null ? Math.round(h.cost_basis * 100) : null,
        currency: h.iso_currency_code ?? sec?.iso_currency_code ?? currency,
      };
    });

    rows.push({
      asset_group: group,
      asset_category: a.type === "depository" ? "Bank" : group === "retirement" ? "Retirement" : "Brokerage",
      asset_subtype: a.subtype ?? a.type,
      source_type: "aggregator",
      masked_identifier: a.mask ? `****${a.mask}` : (a.name ?? ""),
      // balance_cents = Plaid's account total (for investment accounts this already reflects the
      // holdings' market value); `holdings` carries the position-level breakdown.
      balance_cents: Math.round(dollars * 100),
      currency,
      holdings: positions,
    });
  }
  return rows;
}
