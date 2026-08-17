/**
 * PHASE 11-OB PREP · THE READ-ONLY AUDIT — proving an instrument cannot mutate production.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ COMMENTS ARE STRIPPED. STRING LITERALS ARE NOT. THE TWO DECISIONS ARE OPPOSITE AND BOTH ARE LOAD-BEARING.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * An RPC name reaches the network AS A STRING LITERAL — `rpc/${name}`, `'authorize_release'`. Strip
 * strings and the audit is looking at a source with the evidence removed; that is precisely the
 * defect this repository already recorded, where a raw-hex rule ran against a string-stripped view
 * and every hex colour in React Native is a string.
 *
 * The mirror mistake is just as real: these files DISCUSS the routines they must not call. The
 * observer's own header names `claim_owner_notices`, `record_owner_notice_outcome` and
 * `purge_outbox_rows` while explaining that it never calls them. Leave comments in and the audit
 * condemns its own documentation.
 *
 * So: comments out, strings in — and `stripComments` is proven in both directions by test, including
 * that it does not mistake `https://` inside a string for a line comment.
 *
 * ★ AND THE SCAN SET IS ASSERTED BEFORE ANY RULE IS EVALUATED. A resolved path one directory short
 * once produced 63 assertions against empty strings. `auditReadOnlyScripts` refuses an empty file
 * list and refuses any file it cannot read.
 */
import { readFileSync } from 'node:fs';

/**
 * Every production routine that can WRITE. A read-only instrument may not name one outside a comment.
 * Derived from `db/functions/`; `noProductionMutation.test.ts` asserts each name is really a
 * `create or replace function` in source, so a typo cannot silently retire a rule.
 */
export const MUTATION_RPCS = Object.freeze([
  // death process
  'initiate_death_verification_case',
  'cancel_death_verification_case',
  'attach_death_verification_evidence',
  'admin_decide_death_verification_case',
  'admin_review_death_evidence',
  'admin_set_attained_verification_level',
  'dispatch_owner_safety_notice',
  'begin_challenge_window',
  'challenge_death_process',
  'authorize_release',
  'apply_estate_lifecycle_transition',
  // outbox / delivery
  'claim_owner_notices',
  'record_owner_notice_outcome',
  'purge_outbox_rows',
  // ★ PHASE 11-OC / PHASE C. The operator re-notice APPENDS a generation to a live safety queue and
  // writes an audit row. A read-only instrument that named it could queue mail to a living owner as
  // a side effect of measuring production — which is the failure this list exists to make unwritable
  // rather than merely discouraged. `owner_notice_reissue_assessment` is deliberately NOT here: it is
  // `stable`, so the engine itself forbids it a write, and it is the read a verifier legitimately
  // needs to report how many episodes are remediable.
  'reissue_owner_safety_notice',
  // grants
  'create_document_grant',
  'update_document_grant',
  'revoke_document_grant',
  'approve_document_grant',
  'create_asset_grant',
  'update_asset_grant',
  // invitations & provisioning
  'create_invitation',
  'accept_invitation',
  'decline_invitation',
  'admin_create_executor_invitation',
  'provision_from_invitation',
  // vault & assets
  'create_vault_document',
  'update_vault_document',
  'delete_vault_document',
  'replace_vault_document',
  'create_estate_asset',
  'update_estate_asset',
  'archive_estate_asset',
  'restore_estate_asset',
  // access requests, claims, holds, misc writes
  'create_access_request',
  'approve_access_request',
  'deny_access_request',
  'submit_claim_packet',
  'submit_claim_with_evidence',
  'admin_decide_claim_packet',
  'place_legal_hold',
  'release_legal_hold',
  'set_jurisdiction_floor',
  'generate_recovery_codes',
  'mark_recovery_code_used',
  'record_consent',
  'create_connection',
  'emit_notification',
]);

/** Tokens that would obtain elevated credentials. Their PRESENCE is the violation. */
export const FORBIDDEN_SECRET_TOKENS = Object.freeze([
  'CRON_SECRET',
  'SUPABASE_SECRET_KEY',
  'SERVICE_ROLE_KEY',
  'SUPABASE_SERVICE_ROLE',
]);

/** HTTP methods no read-only instrument has any use for. */
export const FORBIDDEN_METHODS = Object.freeze(['PATCH', 'PUT', 'DELETE']);

/**
 * ★ REGEX LITERALS ARE RECOGNISED, AND THE REASON IS A DEFECT THIS AUDIT ACTUALLY HAD.
 *
 * The first scanner tracked only quotes. `readFileSync(p, 'utf8')…replace(/^["']|["']$/g, '')` —
 * one ordinary line of env parsing, present in the observer — contains a `'` and a `"` INSIDE A
 * REGEX. The scanner read them as string delimiters and every quote after that line was paired one
 * off, so the state was inverted for the remaining 180 lines: comments were preserved as code and
 * strings were skipped as comments. It surfaced as two false positives, which is the lucky
 * direction; the same desynchronisation hides a real call just as easily.
 *
 * So the tokenizer distinguishes division from a regex the way a parser does — by the previous
 * significant token — and `noProductionMutation.test.ts` pins that exact line as a control.
 */
const REGEX_PRECEDERS = new Set(['(', ',', '=', ':', '[', '!', '&', '|', '?', '{', '}', ';', '+', '-', '*', '%', '^', '~', '<', '>', null]);
const REGEX_KEYWORDS = /(?:^|[^\w$])(return|typeof|instanceof|in|of|new|delete|void|case|do|else|yield|await)$/;

/** One pass: yields the source with comments removed, plus every string/template literal found. */
function scan(source) {
  let out = '';
  const literals = [];
  let i = 0;
  const n = source.length;
  let prev = null; // last significant character emitted as code

  const readString = (quote) => {
    const start = i;
    out += source[i];
    i += 1;
    while (i < n) {
      const c = source[i];
      if (c === '\\') {
        out += c + (source[i + 1] ?? '');
        i += 2;
        continue;
      }
      out += c;
      i += 1;
      if (c === quote) break;
    }
    literals.push({ quote, content: source.slice(start + 1, i - 1) });
  };

  while (i < n) {
    const c = source[i];
    const next = source[i + 1];

    if (c === "'" || c === '"' || c === '`') {
      readString(c);
      prev = c;
      continue;
    }
    if (c === '/' && next === '/') {
      while (i < n && source[i] !== '\n') i += 1;
      continue;
    }
    if (c === '/' && next === '*') {
      i += 2;
      while (i < n && !(source[i] === '*' && source[i + 1] === '/')) i += 1;
      i += 2;
      continue;
    }
    if (c === '/' && (REGEX_PRECEDERS.has(prev) || REGEX_KEYWORDS.test(out))) {
      // A regex literal. Emitted verbatim — a regex naming a mutation routine is still evidence.
      out += c;
      i += 1;
      let inClass = false;
      while (i < n) {
        const d = source[i];
        if (d === '\\') {
          out += d + (source[i + 1] ?? '');
          i += 2;
          continue;
        }
        out += d;
        i += 1;
        if (d === '[') inClass = true;
        else if (d === ']') inClass = false;
        else if (d === '/' && !inClass) break;
        else if (d === '\n') break; // unterminated — bail rather than swallow the file
      }
      while (i < n && /[a-z]/.test(source[i])) {
        out += source[i];
        i += 1;
      }
      prev = '/';
      continue;
    }
    out += c;
    if (!/\s/.test(c)) prev = c;
    i += 1;
  }
  return { out, literals };
}

/** Remove comments, preserve every string, template and regex literal. */
export function stripComments(source) {
  return scan(source).out;
}

/** Every string/template literal in a source, comments excluded. */
export function stringLiterals(source) {
  return scan(source).literals;
}

/**
 * The API namespaces a backend request can land in. A literal whose FIRST SEGMENT is one of these
 * is a claim about the network and must be on the allowlist.
 */
export const API_ROOTS = Object.freeze(['auth', 'rest', 'api', 'functions', 'storage', 'realtime', 'graphql', 'pg']);

/**
 * Network paths that appear as literals.
 *
 * ★ A TEMPLATE IS NORMALIZED WHOLE, NOT SEGMENT BY SEGMENT. Reading each run after a `${}` as its
 * own path reported `` `/auth/v1/factors/${factorId}/challenge` `` as the two paths `/auth/v1/factors/`
 * and `/challenge` — the second of which is on no allowlist and is not a path anyone requested.
 * Interpolations become `*`, so the literal is audited as the one route it actually is.
 *
 * ★ AND ONLY API-ROOTED PATHS ARE NETWORK CLAIMS. `${ENV_DIR}/.env` is a file, `./lib/x.mjs` is a
 * module specifier. Treating every `/…` substring as an endpoint would flag both, and an audit that
 * cries wolf on its own imports gets its allowlist widened until it means nothing.
 */
export function pathLiterals(source) {
  const found = [];
  for (const { quote, content } of stringLiterals(source)) {
    const normalized = quote === '`' ? content.replace(/\$\{[^}]*\}/g, '*') : content;
    const start = normalized.indexOf('/');
    if (start === -1) continue;
    // A plain string is a path only if it IS one; a template may be `<base>/path`.
    if (start !== 0 && !(quote === '`' && normalized[start - 1] === '*')) continue;
    const path = /^\/[A-Za-z0-9_\-.*/?=&]*/.exec(normalized.slice(start))?.[0] ?? '';
    const firstSegment = path.split('/')[1] ?? '';
    if (API_ROOTS.includes(firstSegment)) found.push(path);
  }
  return found;
}

/** An absolute URL in a network-capable instrument means the base is not coming from configuration. */
export function absoluteUrlLiterals(source) {
  return stringLiterals(source)
    .map(({ content }) => content)
    .filter((c) => /https?:\/\//.test(c));
}

const isNetworkCapable = (stripped) => /\bfetch\s*\(/.test(stripped);

/**
 * @param {object} input
 * @param {string} input.root
 * @param {string[]} input.files              repo-relative paths
 * @param {RegExp[]} [input.allowedPathPrefixes]
 * @param {(f:string)=>string[]} [input.readFile]  injectable for detection fixtures
 */
export function auditReadOnlyScripts({
  root,
  files,
  allowedPathPrefixes = [/^\/auth\/v1\//, /^\/rest\/v1\/rpc\//],
  readSource = (f) => readFileSync(`${root}/${f}`, 'utf8'),
}) {
  const violations = [];
  const scanned = [];

  // ★ THE SCAN SET, ASSERTED FIRST.
  if (!Array.isArray(files) || files.length === 0) {
    return { ok: false, scanned: [], violations: [{ file: '(scan set)', code: 'empty_file_list' }] };
  }

  let networkCapableCount = 0;
  for (const file of files) {
    let raw;
    try {
      raw = readSource(file);
    } catch {
      violations.push({ file, code: 'unreadable' });
      continue;
    }
    if (typeof raw !== 'string' || raw.trim().length === 0) {
      violations.push({ file, code: 'empty_source' });
      continue;
    }
    const stripped = stripComments(raw);
    scanned.push({ file, rawLength: raw.length, strippedLength: stripped.length });

    for (const rpc of MUTATION_RPCS) {
      if (new RegExp(`\\b${rpc}\\b`).test(stripped)) {
        violations.push({ file, code: 'mutation_rpc_named', detail: rpc });
      }
    }
    for (const token of FORBIDDEN_SECRET_TOKENS) {
      if (stripped.includes(token)) violations.push({ file, code: 'secret_token', detail: token });
    }
    for (const method of FORBIDDEN_METHODS) {
      if (new RegExp(`['"\`]${method}['"\`]`).test(stripped)) {
        violations.push({ file, code: 'mutating_http_method', detail: method });
      }
    }

    if (isNetworkCapable(stripped)) {
      networkCapableCount += 1;
      for (const p of pathLiterals(stripped)) {
        if (!allowedPathPrefixes.some((re) => re.test(p))) {
          violations.push({ file, code: 'disallowed_network_path', detail: p });
        }
      }
      for (const u of absoluteUrlLiterals(stripped)) {
        violations.push({ file, code: 'absolute_url_literal', detail: u });
      }
    }
  }

  return {
    ok: violations.length === 0,
    scanned,
    networkCapableCount,
    violations: violations.sort((a, b) => `${a.file}${a.code}${a.detail}`.localeCompare(`${b.file}${b.code}${b.detail}`)),
  };
}
