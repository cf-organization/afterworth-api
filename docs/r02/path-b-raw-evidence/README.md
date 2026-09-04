# R02 · PATH B raw source evidence — durable preservation

```
PURPOSE                  : durable preservation of the five exact PATH B raw inputs used by R02_7
SOURCE                   : $HOME/aw-schema-capture/   (machine-local, outside any Git tree)
SOURCE PROJECT PROVENANCE: afterworth-dev
CAPTURE DATES            : 2026-08-27 (schema dump) · 2026-08-28 (catalog CSVs)
REASON FOR PRESERVATION  : remove machine-local reproducibility risk
R02_7 STATUS             : CLOSED — this package does not reopen it
```

R02_7 proved `PATH A == PATH B == hosted afterworth-nonprod, post-0063`. PATH A is wholly in-repo.
PATH B's raw inputs were not: they lived on one machine, recorded here only by hash. The repository
could therefore **authenticate** the evidence but not **reproduce** it, and if that directory were
lost R02_7 would become unreproducible. These files close that gap by carrying the bytes themselves.

Nothing here is an input to a build, a migration, or a test. It is evidence.

## The five retained inputs

| filename | bytes | SHA256 |
|---|---|---|
| `live-schema-20260827.sql` | 487095 | `a21df219616e2f80e2885d3b29fb61723174300b6909af637bfa8c4f0ea1f8b7` |
| `event-trigger-bindings-20260828.csv` | 1655 | `e5c005cb27f959421a5f33c218eeb3c10819fd3c9b8070b2a31ce5681c1cb0a9` |
| `event-trigger-binding-controls-20260828.csv` | 50 | `7b1c894a4ea851eea768db2066c7be6e30b19aadda15d3a483e656009ed1f21c` |
| `storage-policies-20260828.csv` | 1018 | `7b0adbe21f95fc61ff1773c31a1a89b6cbbce27dd819d59f2548a7426c98f13e` |
| `storage-policy-controls-20260828.csv` | 135 | `7bfc85be19b07c0d1518dcbe9290322c2f99468777a9e099d4e6e8796bf422c4` |

```
PATH_B_RAW_EVIDENCE_MANIFEST_SHA256 = 9ceabf8ef0b0287b8a1cf80cafaecc2aa487aa1859b90db6826a86b365735b36
```

`MANIFEST.txt` holds exactly those five lines: `<filename>  <sha256>  <bytes>`, sorted by filename,
LF endings, one trailing LF. The digest above is taken over those bytes, so the manifest **data**
digest and the manifest **file** digest coincide by byte contract — not because either was adjusted
to match the other.

## Relationship to the closed R02_7 package

`docs/r02/r02_7/r02_7-path-b-source-manifest.md` remains the authority on **what PATH B is** and why
each input exists — including input 6, the U1 `auth.users` trigger supplement, which is in-repo and
is therefore not duplicated here. `scripts/generateBootstrap.mjs` remains the authority on **which
bytes are admissible**: it refuses any file whose hash does not match its pin.

This directory changes neither. It supplies the bytes those two documents describe, and the five
hashes above are the same values both already record. The eleven files under `docs/r02/r02_7/` are
closed and unmodified.

## Disclosure classification

```
RAW_EVIDENCE_CLASS               = SCHEMA_METADATA_ONLY
ACTUAL_SECRET_FINDINGS           = 0
APPLICATION_DATA_FINDINGS        = 0
REPOSITORY VISIBILITY AT REVIEW  = PUBLIC
```

Reviewed 2026-09-03, file by file. No row data, no email addresses, no personal names, no phone
numbers, no addresses, no application-record UUIDs, no tokens, keys, JWTs, passwords, connection
strings, private keys, OAuth or session material. The dump contains **zero UUID literals of any
kind**, so the schema-metadata-UUID versus application-record-UUID question does not arise.

Publication adds essentially nothing that was not already published: `db/bootstrap` was generated
*from* this snapshot and is in this same public repository. Measured — every table, function and
policy name, all 54 `COMMENT ON` payloads and all 147 function bodies already appear in
`db/bootstrap` + `db/migrations`; only 12 of 7884 non-blank lines (0.2%) are not already verbatim
public, and those are `pg_dump` headers, one `GRANT`, and two DDL fragments.

## Structural facts about `live-schema-20260827.sql`

```
ROW_DATA_PAYLOAD                   = NONE
COPY_STATEMENTS                    = 0
TOP_LEVEL_INSERT_STATEMENTS        = 0
IN_FUNCTION_BODY_INSERT_STATEMENTS = 51
```

State it this way and not as "COPY/INSERT = 0". The shorter phrasing is false as a statement count:
the file holds 51 `INSERT INTO` statements. All 51 sit **inside dollar-quoted PostgreSQL function
bodies** — they are executable function source code (trigger and RPC logic), not captured table
rows. A line-anchored grep cannot tell the two apart; dollar-quote state can, and it puts every one
of the 51 inside a body and none at top level.

The distinction matters because "this dump contains INSERT statements" and "this dump contains data"
are different claims, and only the first is true.

## Excluded from preservation

Reviewed in the same pass and deliberately **not** retained:

| excluded | reason |
|---|---|
| `event-triggers-20260828.csv` | superseded first-pass capture (00:41), not a pinned PATH B input |
| `event-trigger-controls-20260828.csv` | superseded first-pass capture (00:42), not a pinned PATH B input |
| `.DS_Store` | Finder metadata, not evidence |
| `supabase/.temp/**` | Supabase CLI state, not evidence; holds operational project/organization metadata and a pooler endpoint. Excluded regardless of repository visibility. |

The pooler endpoint was structurally parsed and carries **no password component**; it is excluded
because it is not evidence, not because it was found to be dangerous. No value from any excluded
file is reproduced anywhere in this package.

## Durability status

Preserving these bytes does not by itself close the finding. Until this package is merged to `main`
and merged `main` independently verified:

```
PATH_B_RAW_EVIDENCE_DURABILITY_RISK = OPEN
```
