# R02 · PATH B raw evidence — chain of custody

```
SOURCE DIRECTORY   : $HOME/aw-schema-capture/   (machine-local, outside any Git tree)
CAPTURE PROVENANCE : supabase db dump, schema-only, source project afterworth-dev, 2026-08-27
                     catalog CSV captures (pg_event_trigger, pg_policies), 2026-08-28
                     established by R02_7; pinned at scripts/generateBootstrap.mjs:38-43 and
                     docs/r02/r02_7/r02_7-path-b-source-manifest.md
REVIEW DATE        : 2026-09-03
PRESERVATION DATE  : 2026-09-03
REVIEWER CONTEXT   : Claude Code, read-only inspection of the source directory at repository
                     main 953f123a5040841b3e25e61c604daf56d766e741. No source file was modified;
                     no hosted SQL was run; no capture byte left the machine before this commit.
DESTINATION        : cf-organization/afterworth-api · docs/r02/path-b-raw-evidence/
```

## Retained — five files, byte-for-byte

| # | filename | bytes | SHA256 |
|---|---|---|---|
| 1 | `live-schema-20260827.sql` | 487095 | `a21df219616e2f80e2885d3b29fb61723174300b6909af637bfa8c4f0ea1f8b7` |
| 2 | `event-trigger-bindings-20260828.csv` | 1655 | `e5c005cb27f959421a5f33c218eeb3c10819fd3c9b8070b2a31ce5681c1cb0a9` |
| 3 | `event-trigger-binding-controls-20260828.csv` | 50 | `7b1c894a4ea851eea768db2066c7be6e30b19aadda15d3a483e656009ed1f21c` |
| 4 | `storage-policies-20260828.csv` | 1018 | `7b0adbe21f95fc61ff1773c31a1a89b6cbbce27dd819d59f2548a7426c98f13e` |
| 5 | `storage-policy-controls-20260828.csv` | 135 | `7bfc85be19b07c0d1518dcbe9290322c2f99468777a9e099d4e6e8796bf422c4` |

```
PATH_B_RAW_EVIDENCE_MANIFEST_SHA256 = 9ceabf8ef0b0287b8a1cf80cafaecc2aa487aa1859b90db6826a86b365735b36
```

## Custody steps, in order

1. **Source hashes verified BEFORE copy** — all five hashed directly in
   `$HOME/aw-schema-capture/` against the values pinned in `scripts/generateBootstrap.mjs`.
   Result: 5/5 hash match, 5/5 byte-size match.
2. **Copy** — `shutil.copyfile` per file, binary, into `docs/r02/path-b-raw-evidence/`.
   No formatting, no newline normalization, no reserialization, no SQL cleanup.
3. **Destination hashes verified AFTER copy** — source SHA256 == destination SHA256 == authorized
   SHA256, and byte size exact, for all five. 5/5.
4. **Manifest** built from the destination bytes, then checked against the digest approved during
   assessment.
5. **Secret and disclosure recheck** run over the copied files, the manifest, this document, the
   README and the staged diff, with positive and mutation controls.
6. **Repository authority guards** re-verified on the staged state: VERSION 0060, 63 migrations,
   0061/0062/0063 unchanged, bootstrap 13/13 unchanged, no 0064, R02_7 package hashes unchanged.

## Reviewed and NOT retained

| excluded | reason |
|---|---|
| `event-triggers-20260828.csv` | superseded first-pass capture, not a pinned PATH B input |
| `event-trigger-controls-20260828.csv` | superseded first-pass capture, not a pinned PATH B input |
| `.DS_Store` | Finder metadata, not evidence |
| `supabase/.temp/**` (9 files) | Supabase CLI state, not evidence; operational project/organization metadata and a pooler endpoint. Deliberately excluded. |

Their bytes were not copied. No credential value appears in this record — the excluded operational
metadata is described here, never reproduced.

## Status

```
COMMIT SHA          : <PLACEHOLDER — recorded in this branch's commit; see PR>
PULL REQUEST        : <PLACEHOLDER — opened against main; MERGE NOT AUTHORIZED at time of writing>
RETAINED            : yes, five files, byte-for-byte
R02_7 STATUS        : CLOSED — not reopened by this package
DURABILITY RISK     : OPEN until this package is merged and merged main independently verified
```
