/**
 * CURRENT AUTHORITATIVE SCHEMA SNAPSHOT — the parser.
 *
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 * ★ WHY THIS IS A PARSER AND NOT A SET OF GREPS.
 * ════════════════════════════════════════════════════════════════════════════════════════════════
 *
 * The Supabase CLI dumps with --quote-all-identifiers, so every name arrives as "public"."estates".
 * The first greps written against this file returned ZERO schema-qualified objects and the honest
 * reading of that was "my matcher is broken", not "the file has no objects". This repository has
 * shipped that exact mistake before (a private-palette rule that could not see `export const`), so
 * the inventory is built by splitting real statements, not by pattern-spotting lines.
 *
 * ★ DOLLAR-QUOTED BODIES ARE THE REASON A LINE-BASED SPLIT CANNOT WORK. 147 function bodies in this
 *   snapshot contain semicolons, `create policy` in raise messages, and regex literals holding `\.`
 *   — five of which a naive data-detector flagged as COPY terminators. Statement splitting therefore
 *   tracks $tag$ ... $tag$, single quotes and double quotes.
 *
 * ★ PARSE FAILURE IS NEVER "CLEAN". Every extractor returns its unparsed remainder, and the caller
 *   is expected to assert the remainder is empty. An inventory that quietly skipped what it could
 *   not understand would report a smaller schema than exists, which is the vacuous-audit shape.
 *
 * PURE. No filesystem, no clock, no network. The caller supplies SQL text.
 */


/**
 * PURE. Remove SQL comments for CLASSIFICATION ONLY. String literals are preserved.
 *
 * ★ THIS IS THE BUG THAT MADE THE PARSER LOOK CORRECT. The Supabase CLI strips `--` lines from its
 *   dump, so on the snapshot every statement began with its verb and `^CREATE TABLE` matched. Every
 *   file in db/ carries a comment header, so the SAME parser saw `-- public.estates ...\ncreate
 *   table ...` as one statement, failed the anchor, and reported 201/201 files unparseable with
 *   `db/tables/` covering exactly ONE live table. Believing that would have published a fabricated
 *   bootstrap gap of 293 objects.
 *
 * ★ COMMENTS OUT, STRINGS IN — the asymmetry every scanner in this repository uses. A `create table`
 *   discussed in a header comment creates nothing; a table named inside a policy predicate is real.
 */
export function stripComments(sql) {
  const s = String(sql ?? '');
  let out = '', i = 0, inS = false, inD = false, dollar = null;
  while (i < s.length) {
    const c = s[i], n = s[i + 1];
    if (dollar) { if (s.startsWith(dollar, i)) { out += dollar; i += dollar.length; dollar = null; continue; } out += c; i += 1; continue; }
    if (inS) { if (c === "'" && n === "'") { out += "''"; i += 2; continue; } out += c; if (c === "'") inS = false; i += 1; continue; }
    if (inD) { if (c === '"' && n === '"') { out += '""'; i += 2; continue; } out += c; if (c === '"') inD = false; i += 1; continue; }
    const dq = /^\$[A-Za-z_0-9]*\$/.exec(s.slice(i));
    if (dq) { dollar = dq[0]; out += dollar; i += dollar.length; continue; }
    if (c === "'") { inS = true; out += c; i += 1; continue; }
    if (c === '"') { inD = true; out += c; i += 1; continue; }
    if (c === '-' && n === '-') { while (i < s.length && s[i] !== '\n') i += 1; continue; }
    if (c === '/' && n === '*') { i += 2; while (i < s.length && !(s[i] === '*' && s[i + 1] === '/')) i += 1; i += 2; out += ' '; continue; }
    out += c; i += 1;
  }
  return out;
}

/** Statement splitter that respects dollar-quoting, '...' and "..." . */
export function splitStatements(sql) {
  const s = String(sql ?? '');
  const out = [];
  let buf = '';
  let i = 0;
  let inSingle = false, inDouble = false, inLine = false, inBlock = false, dollar = null;

  while (i < s.length) {
    const c = s[i], next = s[i + 1];

    if (inLine) { buf += c; if (c === '\n') inLine = false; i += 1; continue; }
    if (inBlock) { buf += c; if (c === '*' && next === '/') { buf += next; i += 2; inBlock = false; continue; } i += 1; continue; }
    if (dollar) {
      if (s.startsWith(dollar, i)) { buf += dollar; i += dollar.length; dollar = null; continue; }
      buf += c; i += 1; continue;
    }
    if (inSingle) { if (c === "'" && next === "'") { buf += "''"; i += 2; continue; } buf += c; if (c === "'") inSingle = false; i += 1; continue; }
    if (inDouble) { if (c === '"' && next === '"') { buf += '""'; i += 2; continue; } buf += c; if (c === '"') inDouble = false; i += 1; continue; }

    if (c === '-' && next === '-') { buf += c; inLine = true; i += 1; continue; }
    if (c === '/' && next === '*') { buf += c; inBlock = true; i += 1; continue; }
    if (c === "'") { buf += c; inSingle = true; i += 1; continue; }
    if (c === '"') { buf += c; inDouble = true; i += 1; continue; }

    const dq = /^\$[A-Za-z_0-9]*\$/.exec(s.slice(i));
    if (dq) { dollar = dq[0]; buf += dollar; i += dollar.length; continue; }

    if (c === ';') { const t = buf.trim(); if (t) out.push(t); buf = ''; i += 1; continue; }
    // ★ psql META-COMMANDS END AT THE NEWLINE, NOT AT A SEMICOLON. `\echo 'x'` followed by real
    //   DDL was being absorbed into one statement, so the DDL after it vanished from the inventory.
    //   Only db/tests and db/verification use these, which is precisely why it went unnoticed —
    //   the swallowed statements were in files that carry no bootstrap authority.
    if (c === '\\' && /^[a-zA-Z]/.test(next ?? '') && buf.trim() === '') {
      const nl = s.indexOf('\n', i);
      const end = nl === -1 ? s.length : nl;
      out.push(s.slice(i, end).trim());
      i = end + 1; buf = ''; continue;
    }
    buf += c; i += 1;
  }
  const tail = buf.trim();
  if (tail) out.push(tail);
  return out;
}

/** `"public"."estates"` / `public.estates` / `"estates"` -> {schema, name}. */
export function parseQualified(raw) {
  if (!raw) return null;
  const parts = String(raw).trim().match(/(?:"(?:[^"]|"")*"|[A-Za-z_][A-Za-z_0-9$]*)/g);
  if (!parts || parts.length === 0) return null;
  const unq = (p) => (p.startsWith('"') ? p.slice(1, -1).replace(/""/g, '"') : p.toLowerCase());
  if (parts.length === 1) return { schema: null, name: unq(parts[0]) };
  return { schema: unq(parts[parts.length - 2]), name: unq(parts[parts.length - 1]) };
}

const QN = '(?:"(?:[^"]|"")*"|[A-Za-z_][A-Za-z_0-9$]*)';
const QUAL = `(?:${QN}\\s*\\.\\s*)*${QN}`;

/**
 * PURE. The roles a policy applies to.
 *
 * ★ THIS FIELD FAILED OPEN AND IT IS SECURITY-RELEVANT. The first version embedded `${QN}` inside a
 *   REGEX LITERAL, where it is not interpolated — so the match never succeeded and every policy fell
 *   through to the `'public'` default. All 36 policies reported role `public` while the snapshot
 *   plainly says `TO "authenticated"`. Reported as-is that is a fabricated critical finding.
 *
 * ★ ABSENT AND UNPARSEABLE ARE DIFFERENT. A policy with NO `TO` clause genuinely applies to PUBLIC —
 *   that is Postgres semantics, not a guess. A policy WITH a `TO` clause the matcher cannot read is
 *   an instrument failure and returns `['?unparsed']`, which no caller may treat as a role.
 */

/** PURE. The command a policy applies to. Absent FOR => ALL (Postgres). Unreadable FOR => failure. */
export function policyCommand(maskedRest) {
  const m = /\bFOR\s+([A-Za-z]+)/i.exec(maskedRest);
  if (!m) return 'ALL';
  const c = m[1].toUpperCase();
  return ['ALL', 'SELECT', 'INSERT', 'UPDATE', 'DELETE'].includes(c) ? c : '?unparsed';
}

/**
 * PURE. The attribute header of a function: everything after RETURNS up to the body delimiter.
 * ★ The body is EXCLUDED deliberately — see the call site. Literals in the header are masked so a
 *   default value like `DEFAULT 'SECURITY DEFINER'` cannot forge an attribute either.
 */
export function functionHeader(afterReturns) {
  const s = String(afterReturns ?? '');
  const dq = /\$[A-Za-z_0-9]*\$/.exec(s);
  const cut = dq ? s.slice(0, dq.index) : s;
  return maskLiterals(cut);
}

export function parseRoles(rest) {
  if (typeof rest !== 'string' || rest.trim() === '') return ['?unparsed'];
  // ★ MASK STRING LITERALS BEFORE LOOKING FOR KEYWORDS. `USING (note = 'TO PUBLIC')` matched the
  //   `TO` inside a string and reported role PUBLIC for a policy that has no TO clause at all.
  const masked = maskLiterals(rest);
  const to = /\bTO\b/i.exec(masked);
  if (!to) return ['public'];                       // no TO clause: Postgres semantics, PUBLIC.

  // ★ THE CLAUSE ENDS AT THE NEXT TOP-LEVEL KEYWORD, and the WHOLE region must be consumed.
  //   The previous grammar matched a PREFIX and discarded the remainder, so
  //   `TO "authenticated", 99999` returned ["authenticated"] — dropping a role it could not read
  //   and understating who the policy applies to. A partial parse is a parse FAILURE.
  // ★ BOUNDARIES ARE INDICES INTO THE MASKED VIEW, NEVER THE LENGTH OF A TRIMMED STRING.
  //   The first attempt sliced the original using the trimmed region's length, so every role came
  //   back one character short — "public" as "publi", "anon" as "ano". A parser that silently
  //   truncates identifiers is worse than one that fails: the names still look plausible.
  const base = to.index + to[0].length;
  const after = masked.slice(base);
  const stop = /\b(USING|WITH\s+CHECK|AS\s+(?:PERMISSIVE|RESTRICTIVE)|FOR\s+(?:ALL|SELECT|INSERT|UPDATE|DELETE))\b/i.exec(after);
  const end = base + (stop ? stop.index : after.length);
  const src = rest.slice(base, end).replace(/;\s*$/, '');
  if (src.trim() === '') return ['?unparsed'];

  const parts = src.split(',');
  if (parts.some((t) => t.trim() === '')) return ['?unparsed'];   // leading/trailing/double comma

  const ROLE = new RegExp(`^(?:${QN}|PUBLIC|CURRENT_USER|SESSION_USER|CURRENT_ROLE)$`, 'i');
  const out = [];
  for (const t of parts) {
    const tok = t.trim();
    if (!ROLE.test(tok)) return ['?unparsed'];       // ANY unreadable token fails the whole clause
    const q = parseQualified(tok);
    if (!q || !q.name) return ['?unparsed'];
    out.push(q.name);
  }
  return out.length ? out : ['?unparsed'];
}

/**
 * PURE. Replace the CONTENTS of string literals with spaces, preserving length and every other
 * character. Used only to locate keywords — never to extract values.
 *
 * ★ Length preservation is what lets a caller map an index found in the masked view back onto the
 *   original text, which is how the role region is sliced from the real source rather than the mask.
 */
export function maskLiterals(sql) {
  const s = String(sql ?? '');
  let out = '', i = 0, inS = false, dollar = null;
  while (i < s.length) {
    const c = s[i];
    if (dollar) { if (s.startsWith(dollar, i)) { out += dollar; i += dollar.length; dollar = null; continue; } out += ' '; i += 1; continue; }
    if (inS) { if (c === "'" && s[i + 1] === "'") { out += '  '; i += 2; continue; } if (c === "'") { inS = false; out += c; i += 1; continue; } out += ' '; i += 1; continue; }
    const dq = /^\$[A-Za-z_0-9]*\$/.exec(s.slice(i));
    if (dq) { dollar = dq[0]; out += dollar; i += dollar.length; continue; }
    if (c === "'") { inS = true; out += c; i += 1; continue; }
    out += c; i += 1;
  }
  return out;
}


/** Normalize a statement's leading keywords for classification (whitespace + case). */
export function head(stmt, words = 4) {
  return String(stmt).replace(/\s+/g, ' ').trim().split(' ').slice(0, words).join(' ').toUpperCase();
}

/**
 * Build the inventory. Returns objects plus `unclassified` — statements no rule claimed.
 * ★ `unclassified` is the instrument's own honesty check and must be asserted empty by the caller.
 */
export function inventory(sql) {
  const statements = splitStatements(sql);
  const inv = {
    tables: [], columns: [], functions: [], policies: [], indexes: [], triggers: [],
    types: [], sequences: [], extensions: [], schemas: [], views: [],
    rlsEnabled: [], rlsForced: [], grants: [], revokes: [], defaultPrivileges: [],
    constraints: [], comments: [], alterTables: [], sets: [], publications: [], drops: [], doBlocks: [], transactionControl: [], psqlMeta: [], dml: [], unclassified: [],
  };

  for (const raw of statements) {
    // ★ Classify the comment-stripped form; keep `raw` for evidence output.
    const stmt = stripComments(raw).trim();
    if (!stmt) continue;
    const h = head(stmt, 5);
    let m;

    if (/^SET /.test(h) || /^SELECT PG_CATALOG.SET_CONFIG/.test(h)) { inv.sets.push(stmt); continue; }

    if ((m = new RegExp(`^CREATE\\s+TABLE\\s+(?:IF\\s+NOT\\s+EXISTS\\s+)?(${QUAL})\\s*\\(([\\s\\S]*)\\)\\s*$`, 'i').exec(stmt))) {
      const q = parseQualified(m[1]);
      inv.tables.push({ ...q, sql: stmt });
      for (const col of splitTopLevel(m[2])) {
        const cm = new RegExp(`^(${QN})\\s+([\\s\\S]+)$`).exec(col.trim());
        if (!cm) continue;
        const nameTok = parseQualified(cm[1]);
        if (/^(CONSTRAINT|PRIMARY|UNIQUE|CHECK|FOREIGN|EXCLUDE|LIKE)$/i.test(nameTok.name)) {
          // * INLINE CONSTRAINTS ARE NAMED CONSTRAINTS. `CONSTRAINT "x_check" CHECK (...)` inside a
          //   CREATE TABLE produces a real, named pg_constraint row. Recording them anonymously made
          //   the authoritative constraint set 126 when the database holds 176, so a correct
          //   bootstrap looked like it had invented 50 constraints. The object existed all along;
          //   only the parser's view of it was impoverished.
          const cn = new RegExp(`^CONSTRAINT\\s+(${QN})`, 'i').exec(col.trim());
          inv.constraints.push({
            table: q.name, schema: q.schema, inline: true,
            name: cn ? parseQualified(cn[1]).name : null,
            kind: /PRIMARY\s+KEY/i.test(col) ? 'p' : /FOREIGN\s+KEY/i.test(col) ? 'f' : /UNIQUE/i.test(col) ? 'u' : /CHECK/i.test(col) ? 'c' : 'other',
            sql: col.trim(),
          });
          continue;
        }
        const rest = cm[2].trim();
        inv.columns.push({
          schema: q.schema, table: q.name, name: nameTok.name,
          type: rest.replace(/\s+(NOT\s+NULL|NULL|DEFAULT[\s\S]*|GENERATED[\s\S]*|PRIMARY\s+KEY|UNIQUE|REFERENCES[\s\S]*|CHECK[\s\S]*|COLLATE\s+\S+)\s*$/gi, '').trim(),
          notNull: /\bNOT\s+NULL\b/i.test(rest),
          default: (/\bDEFAULT\s+([\s\S]*?)(?=\s+(?:NOT\s+NULL|NULL|GENERATED|PRIMARY\s+KEY|UNIQUE|REFERENCES|CHECK|COLLATE)\b|$)/i.exec(rest) || [])[1]?.trim() ?? null,
          generated: /\bGENERATED\b/i.test(rest),
          raw: rest,
        });
        // ★ `bigserial` IS a sequence. pg_dump expands it into an explicit CREATE SEQUENCE +
        //   ALTER SEQUENCE OWNED BY + SET DEFAULT, so the snapshot shows three statements where
        //   the repository shows one word. Matching only the explicit spelling reported
        //   `audit_logs_id_seq` as having no repository definition — a false gap, since
        //   migration 0011 declares `id bigserial primary key`. Same object, two spellings.
        if (/^(big|small)?serial\b/i.test(rest)) {
          inv.sequences.push({ schema: q.schema, name: `${q.name}_${nameTok.name}_seq`, implicit: true, sql: col.trim() });
        }
      }
      continue;
    }

    if ((m = new RegExp(`^CREATE\\s+(?:OR\\s+REPLACE\\s+)?FUNCTION\\s+(${QUAL})\\s*\\(([\\s\\S]*?)\\)\\s*RETURNS([\\s\\S]*)$`, 'i').exec(stmt))) {
      const q = parseQualified(m[1]);
      // ★ ATTRIBUTES COME FROM THE HEADER, NOT THE BODY. Reading them from the whole statement
      //   let a function whose BODY contains the string 'SECURITY DEFINER' report as SECURITY
      //   DEFINER — and, far worse, let a body mentioning `set search_path` satisfy the
      //   `setsSearchPath` check. That is the exact property the security review relied on when it
      //   reported "all 131 SECURITY DEFINER functions set an explicit search_path". An attribute
      //   scanner that reads function bodies cannot support that claim.
      const header = functionHeader(m[3]);
      inv.functions.push({
        ...q, args: m[2].trim(),
        language: (/LANGUAGE\s+"?([a-z_]+)"?/i.exec(header) || [])[1]?.toLowerCase() ?? null,
        securityDefiner: /\bSECURITY\s+DEFINER\b/i.test(header),
        securityInvoker: /\bSECURITY\s+INVOKER\b/i.test(header),
        setsSearchPath: /\bSET\s+"?search_path"?\s*(?:TO|=)/i.test(header),
        volatility: (/\b(IMMUTABLE|STABLE|VOLATILE)\b/i.exec(header) || [])[1]?.toLowerCase() ?? null,
        sql: stmt,
      });
      continue;
    }

    if ((m = new RegExp(`^CREATE\\s+POLICY\\s+(${QN})\\s+ON\\s+(${QUAL})([\\s\\S]*)$`, 'i').exec(stmt))) {
      const t = parseQualified(m[2]);
      const rest = m[3];
      inv.policies.push({
        name: parseQualified(m[1]).name, schema: t.schema, table: t.name,
        // ★ AN UNREADABLE `FOR` MUST NOT BECOME `ALL`. Absent FOR legitimately means ALL; a FOR
        //   clause naming something this parser does not know is a parse failure, and defaulting it
        //   to the MOST PERMISSIVE command is the worst possible direction to be wrong in.
        command: policyCommand(maskLiterals(rest)),
        // PERMISSIVE is the Postgres default; RESTRICTIVE policies AND with the permissive set and
        // are how this schema pins AAL2. Collapsing the two would misread the security model.
        restrictive: /\bAS\s+RESTRICTIVE\b/i.test(rest),
        roles: parseRoles(rest),
        using: (/\bUSING\s*\(([\s\S]*?)\)\s*(?:WITH\s+CHECK|$)/i.exec(rest) || [])[1]?.trim() ?? null,
        withCheck: (/\bWITH\s+CHECK\s*\(([\s\S]*)\)\s*$/i.exec(rest) || [])[1]?.trim() ?? null,
        sql: stmt,
      });
      continue;
    }

    if ((m = new RegExp(`^CREATE\\s+(UNIQUE\\s+)?INDEX\\s+(?:CONCURRENTLY\\s+)?(?:IF\\s+NOT\\s+EXISTS\\s+)?(${QN})\\s+ON\\s+(${QUAL})([\\s\\S]*)$`, 'i').exec(stmt))) {
      const t = parseQualified(m[3]);
      inv.indexes.push({ name: parseQualified(m[2]).name, schema: t.schema, table: t.name, unique: Boolean(m[1]), sql: stmt });
      continue;
    }

    if ((m = new RegExp(`^CREATE\\s+(?:OR\\s+REPLACE\\s+)?(?:CONSTRAINT\\s+)?TRIGGER\\s+(${QN})\\s+([\\s\\S]*?)\\s+ON\\s+(${QUAL})([\\s\\S]*)$`, 'i').exec(stmt))) {
      const t = parseQualified(m[3]);
      inv.triggers.push({
        name: parseQualified(m[1]).name, schema: t.schema, table: t.name, timing: m[2].trim(),
        executes: (new RegExp(`EXECUTE\\s+(?:PROCEDURE|FUNCTION)\\s+(${QUAL})`, 'i').exec(m[4]) || [])[1] ?? null,
        sql: stmt,
      });
      continue;
    }

    if ((m = new RegExp(`^CREATE\\s+TYPE\\s+(${QUAL})([\\s\\S]*)$`, 'i').exec(stmt))) {
      const q = parseQualified(m[1]);
      inv.types.push({ ...q, kind: /AS\s+ENUM/i.test(m[2]) ? 'enum' : /AS\s+RANGE/i.test(m[2]) ? 'range' : 'composite', sql: stmt });
      continue;
    }
    if ((m = new RegExp(`^CREATE\\s+(?:MATERIALIZED\\s+)?VIEW\\s+(${QUAL})`, 'i').exec(stmt))) {
      inv.views.push({ ...parseQualified(m[1]), materialized: /MATERIALIZED/i.test(stmt), sql: stmt }); continue;
    }
    if ((m = new RegExp(`^CREATE\\s+SEQUENCE\\s+(?:IF\\s+NOT\\s+EXISTS\\s+)?(${QUAL})`, 'i').exec(stmt))) {
      inv.sequences.push({ ...parseQualified(m[1]), sql: stmt }); continue;
    }
    if ((m = new RegExp(`^CREATE\\s+EXTENSION\\s+(?:IF\\s+NOT\\s+EXISTS\\s+)?(${QN})([\\s\\S]*)$`, 'i').exec(stmt))) {
      inv.extensions.push({
        name: parseQualified(m[1]).name,
        schema: (new RegExp(`WITH\\s+SCHEMA\\s+(${QN})`, 'i').exec(m[2]) || [])[1]?.replace(/"/g, '') ?? null, sql: stmt,
      });
      continue;
    }
    if ((m = new RegExp(`^CREATE\\s+SCHEMA\\s+(?:IF\\s+NOT\\s+EXISTS\\s+)?(${QN})`, 'i').exec(stmt))) {
      inv.schemas.push({ name: parseQualified(m[1]).name, sql: stmt }); continue;
    }

    if (/^ALTER\s+TABLE/i.test(stmt)) {
      const tm = new RegExp(`^ALTER\\s+TABLE\\s+(?:ONLY\\s+)?(${QUAL})([\\s\\S]*)$`, 'i').exec(stmt);
      if (tm) {
        const t = parseQualified(tm[1]); const rest = tm[2];
        if (/\bENABLE\s+ROW\s+LEVEL\s+SECURITY\b/i.test(rest)) { inv.rlsEnabled.push({ ...t }); continue; }
        if (/\bFORCE\s+ROW\s+LEVEL\s+SECURITY\b/i.test(rest)) { inv.rlsForced.push({ ...t }); continue; }
        const cm = new RegExp(`ADD\\s+CONSTRAINT\\s+(${QN})\\s+([\\s\\S]*)$`, 'i').exec(rest);
        if (cm) {
          inv.constraints.push({
            schema: t.schema, table: t.name, name: parseQualified(cm[1]).name, inline: false,
            kind: /PRIMARY\s+KEY/i.test(cm[2]) ? 'p' : /FOREIGN\s+KEY/i.test(cm[2]) ? 'f' : /UNIQUE/i.test(cm[2]) ? 'u' : /CHECK/i.test(cm[2]) ? 'c' : 'other',
            references: (new RegExp(`REFERENCES\\s+(${QUAL})`, 'i').exec(cm[2]) || [])[1] ?? null,
            sql: stmt,
          });
          continue;
        }
        inv.alterTables.push({ ...t, sql: stmt }); continue;
      }
    }
    if (/^ALTER\s+(FUNCTION|TYPE|SEQUENCE|SCHEMA|VIEW|INDEX)/i.test(stmt)) { inv.alterTables.push({ owner: true, sql: stmt }); continue; }
    if (/^ALTER\s+DEFAULT\s+PRIVILEGES/i.test(stmt)) { inv.defaultPrivileges.push({ sql: stmt }); continue; }
    if (/^(CREATE|ALTER|DROP)\s+PUBLICATION/i.test(stmt)) {
      const pm = new RegExp(`PUBLICATION\\s+(${QN})`, 'i').exec(stmt);
      inv.publications.push({ name: parseQualified(pm?.[1] ?? '')?.name ?? null, sql: stmt }); continue;
    }
    if (/^GRANT\b/i.test(stmt)) { inv.grants.push({ sql: stmt }); continue; }
    if (/^REVOKE\b/i.test(stmt)) { inv.revokes.push({ sql: stmt }); continue; }
    if (/^COMMENT\s+ON/i.test(stmt)) { inv.comments.push({ sql: stmt }); continue; }
    // ★ DROP is a DELTA, never a base definition. `drop policy if exists X` before `create policy X`
    //   is the idempotent-replace idiom throughout db/ — recording it as a create would let a file
    //   that only drops an object appear to define it.
    if (/^DROP\s+/i.test(stmt)) { inv.drops.push({ sql: stmt }); continue; }
    // ★ NON-DDL IS CATEGORIZED, NOT DISCARDED. `unclassified` must mean "the parser does not
    //   understand this", never "the parser chose to ignore this". Transaction control, psql
    //   meta-commands and DML are all real statements with no schema effect; naming them is what
    //   lets `unclassified.length === 0` be a meaningful assertion instead of a swept floor.
    if (/^(COMMIT|ROLLBACK|BEGIN|START\s+TRANSACTION|SAVEPOINT|END)\b/i.test(stmt)) { inv.transactionControl.push({ sql: stmt }); continue; }
    if (/^\\[a-z]/i.test(stmt)) { inv.psqlMeta.push({ sql: stmt }); continue; }
    if (/^(INSERT|UPDATE|DELETE|TRUNCATE|WITH|SELECT|VALUES|ANALYZE|VACUUM|REFRESH)\b/i.test(stmt)) { inv.dml.push({ sql: stmt }); continue; }
    if (/^CREATE\s+(TEMP|TEMPORARY|UNLOGGED)\s/i.test(stmt)) { inv.dml.push({ transient: true, sql: stmt }); continue; }
    if (/^DO\s*\$/i.test(stmt) || /^BEGIN$|^END$|^DECLARE$/i.test(h)) {
      inv.doBlocks.push({ sql: stmt });
      // ★ DDL INSIDE A `do` BLOCK IS STILL DDL, AND THIS REPOSITORY RELIES ON IT.
      //   `db/tables/jurisdiction_policy.sql` creates the `verification_level` enum as
      //   `do $$ ... if not exists (...) then create type ... end if; $$` — the guarded-create
      //   idiom. Treating the block as opaque reported that type as having NO repository
      //   definition anywhere, which was false and would have inflated the published gap.
      //   Recorded as `conditional`, because a guarded create is real but order-sensitive.
      for (const d of doBlockCreates(stmt)) {
        if (d.kind === 'type') inv.types.push({ schema: d.schema, name: d.name, conditional: true, sql: stmt });
        if (d.kind === 'table') inv.tables.push({ schema: d.schema, name: d.name, conditional: true, sql: stmt });
        if (d.kind === 'index') inv.indexes.push({ schema: d.schema, name: d.name, conditional: true, sql: stmt });
        if (d.kind === 'policy') inv.policies.push({ schema: d.schema, name: d.name, table: d.table, conditional: true, roles: ['?inblock'], sql: stmt });
        if (d.kind === 'trigger') inv.triggers.push({ schema: d.schema, name: d.name, table: d.table, conditional: true, sql: stmt });
      }
      continue;
    }

    inv.unclassified.push(stmt);
  }
  return inv;
}


/**
 * PURE. CREATE statements nested inside a `do $$ ... $$` block.
 *
 * ★ Guarded creates are a real creation path here, not a curiosity. Returns them flagged
 *   `conditional` so a caller can tell "this repository can build it" from "this repository builds
 *   it unconditionally" — the two matter differently for a virgin bootstrap.
 */
export function doBlockCreates(stmt) {
  const body = stripComments(stmt);
  const out = [];
  const re = new RegExp(
    `\\bcreate\\s+(?:or\\s+replace\\s+)?(type|table|index|unique\\s+index|policy|trigger)\\s+(?:if\\s+not\\s+exists\\s+)?(${QUAL})(?:\\s+on\\s+(${QUAL}))?`,
    'gi');
  for (const m of body.matchAll(re)) {
    const kindRaw = m[1].toLowerCase().replace(/\s+/g, ' ');
    const kind = kindRaw.includes('index') ? 'index' : kindRaw;
    const q = parseQualified(m[2]);
    const on = m[3] ? parseQualified(m[3]) : null;
    out.push({ kind, schema: q.schema, name: q.name, table: on?.name ?? null });
  }
  return out;
}

/** Split a parenthesised column list on top-level commas. */
export function splitTopLevel(body) {
  const out = []; let depth = 0, buf = '', inS = false, inD = false;
  for (let i = 0; i < body.length; i += 1) {
    const c = body[i];
    if (inS) { buf += c; if (c === "'" && body[i + 1] !== "'") inS = false; continue; }
    if (inD) { buf += c; if (c === '"') inD = false; continue; }
    if (c === "'") { inS = true; buf += c; continue; }
    if (c === '"') { inD = true; buf += c; continue; }
    if (c === '(') depth += 1;
    if (c === ')') depth -= 1;
    if (c === ',' && depth === 0) { out.push(buf); buf = ''; continue; }
    buf += c;
  }
  if (buf.trim()) out.push(buf);
  return out;
}

/** Stable key for diffing. */
export const keyOf = (o) => `${o.schema ?? '-'}.${o.table ? `${o.table}.` : ''}${o.name}`;
