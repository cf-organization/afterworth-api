/**
 * The worker-side inviter sanitizer — the TypeScript twin of `public.safe_inviter_display_name(text)`.
 *
 * ★ TWO ORACLES, ONE LABELLED VECTOR SET. `db/tests/safe_inviter_display_name_assertions.sql` decides
 * every case INSIDE SQL (run by scripts/verifyInviterNamePrivacy.mjs and the cue capture). This file
 * decides the same cases in TypeScript. The bijection test below reads the SQL file's labels and demands
 * a TypeScript twin for every one of them, so adding a case to one table without the other fails here.
 * The expectations themselves are stated independently on each side — a shared helper would let one
 * wrong answer agree with itself.
 */
import { describe, expect, test } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { INVITER_NAME_MAX_LENGTH, safeInviterDisplayName } from "../lib/invitations/safeInviterDisplayName.js";

const SQL_VECTORS = readFileSync(join(__dirname, "..", "db/tests/safe_inviter_display_name_assertions.sql"), "utf8");

/** label → [input, expected], mirroring the SQL table row for row. */
const VECTORS: Record<string, [unknown, string | null]> = {
  "null": [null, null],
  "empty": ["", null],
  "spaces only": ["   ", null],
  "tabs and newlines only": ["\t\n\r\t", null],
  "vertical tab + form feed only": ["\u000b\u000c", null],
  "nonbreaking spaces only": ["  ", null],
  "zero-width no-break spaces only (BOM)": ["﻿﻿", null],
  "ideographic + Zs-block spaces only": ["　  ", null],
  "line separators only": ["  ", null],
  "valid name": ["Dana Hartley", "Dana Hartley"],
  "valid name padded with spaces": ["  Dana Hartley  ", "Dana Hartley"],
  "valid name padded with tabs/newlines": ["\t Dana Hartley \n", "Dana Hartley"],
  "valid name padded with NBSP": [" Dana Hartley ", "Dana Hartley"],
  "valid name padded with BOM": ["﻿Dana Hartley﻿", "Dana Hartley"],
  "inner whitespace is kept": ["Dana\tHartley", "Dana\tHartley"],
  "address-shaped": ["dana@example.test", null],
  "address inside a name": ["Dana <dana@example.test>", null],
  "address-shaped, padded": ["\t dana@example.test \n", null],
  "a lone @ is not address-shaped": ["@", "@"],
  "@ with space either side": ["a @ b", "a @ b"],
  "exactly 200 characters": ["x".repeat(200), "x".repeat(200)],
  "201 characters": ["x".repeat(201), null],
  "200 characters padded to 202": [" " + "x".repeat(200) + " ", "x".repeat(200)],
  "201 characters padded": [" " + "x".repeat(201) + " ", null],
  "200 non-ASCII characters": ["é".repeat(200), "é".repeat(200)],
  "201 non-ASCII characters": ["é".repeat(201), null],
  "internal NBSP on both sides of @": ["Dana @ Hartley", "Dana @ Hartley"],
  "internal NBSP before @ only": ["Dana @example.test", "Dana @example.test"],
  "ordinary space on both sides of @": ["Dana @ Hartley", "Dana @ Hartley"],
  "ordinary address control": ["dana@example.test", null],
  "address control with NBSP padding": [" dana@example.test ", null],
};

describe("0 · the vector set is real and complete", () => {
  test("★ every labelled SQL case has a TypeScript twin, and nothing extra", () => {
    const sqlLabels = [...SQL_VECTORS.matchAll(/^\s+\('([^']+)',/gm)].map((m) => m[1]);
    expect(sqlLabels.length).toBeGreaterThanOrEqual(30); // positive control: the parse found the table
    expect([...new Set(sqlLabels)].sort()).toEqual(Object.keys(VECTORS).sort());
  });
});

describe("1 · the rule, case by case", () => {
  test.each(Object.entries(VECTORS))("%s", (_label, [input, expected]) => {
    expect(safeInviterDisplayName(input)).toBe(expected);
  });
});

describe("2 · what no vector should need to say", () => {
  test("a non-string is null, never coerced", () => {
    for (const v of [undefined, 0, 42, true, {}, [], () => "x", Symbol("s")]) expect(safeInviterDisplayName(v)).toBeNull();
  });
  test("★ the length bound is counted in code points, as PostgreSQL counts — an astral character is ONE", () => {
    const astral = "\u{1F600}"; // UTF-16 length 2, code-point length 1
    expect(astral.length).toBe(2); // positive control for the distinction this test exists to pin
    expect(safeInviterDisplayName(astral.repeat(INVITER_NAME_MAX_LENGTH))).toBe(astral.repeat(INVITER_NAME_MAX_LENGTH));
    expect(safeInviterDisplayName(astral.repeat(INVITER_NAME_MAX_LENGTH + 1))).toBeNull();
    expect(INVITER_NAME_MAX_LENGTH).toBe(200);
  });
  test("★ null is the only fallback — no neutral phrase, no substitution", () => {
    const src = readFileSync(join(__dirname, "..", "lib/invitations/safeInviterDisplayName.ts"), "utf8");
    expect(src).not.toMatch(/An estate owner|Someone|Unknown/);
    expect(src).not.toMatch(/\?\?\s*"/); // no `?? "fallback"`
  });
  test("★ positive control — the address rule is the mobile client's, verbatim", () => {
    const clientRule = /\S@\S/; // features/invitations/model.ts: `if (/\S@\S/.test(trimmed)) return null;`
    expect(clientRule.test("dana@example.test")).toBe(true);
    expect(clientRule.test("Dana Hartley")).toBe(false);
    expect(clientRule.test("@")).toBe(false);
  });
});
