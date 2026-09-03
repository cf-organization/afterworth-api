# R02_7 · semantic normalization specification

Every dimension below is compared **semantically**. Forbidden inputs, everywhere: OIDs, raw
`relacl`/`defaclacl` text, `relfilenode`, timestamps, physical/creation order, generated object ids.

Global rules:

- every `string_agg` carries an explicit `ORDER BY`, so row order cannot affect a fingerprint;
- ACLs are decoded with `aclexplode`, never compared as text;
- **row-DML** (`SELECT`/`INSERT`/`UPDATE`/`DELETE`) is kept separate from **Dxtm**
  (`TRUNCATE`/`REFERENCES`/`TRIGGER`/`MAINTAIN`) in every ACL dimension;
- `MAINTAIN` is queried only when `server_version_num >= 170000`;
- units are named for what they count.

| dimension | unit | catalog source | ownership | normalization / fingerprint input |
|---|---|---|---|---|
| `tables_ordinary` | tables | `pg_class` relkind='r' | APPLICATION | `relname:owner` |
| `columns` | columns | `information_schema.columns` | APPLICATION | `table.column:type:nullable:default:identity:generated` |
| `primary_keys` / `unique_constraints` / `foreign_keys` / `check_constraints` | constraints | `pg_constraint` | APPLICATION | `conname@relname:pg_get_constraintdef()` |
| `indexes` | indexes | `pg_index` (constraint-backed excluded) | APPLICATION | `relname:pg_get_indexdef()` |
| `functions` | functions | `pg_proc` | APPLICATION | `name(identity_args):result:lang:volatility:secdef:strict:proconfig:md5(prosrc)` |
| `policies` | policies | `pg_policies` schema='public' | APPLICATION | `table.policy:cmd:permissive:roles:qual:with_check` (whitespace-collapsed) |
| `triggers_public` | triggers | `pg_trigger` not internal | APPLICATION | `relname.tgname:tgtype:tgenabled:function` |
| `trigger_auth_users` | triggers | `pg_trigger` on `auth.users` | APPLICATION on a PLATFORM relation | same; `NONE` when absent |
| `rls_state` | tables | `pg_class` | APPLICATION | `relname:relrowsecurity:relforcerowsecurity` |
| `sequences` | sequences | `information_schema.sequences` | APPLICATION | `name:data_type` |
| `enum_types` | **types** | `pg_type` typtype='e' | APPLICATION | `typname` |
| `enum_label_rows` | **labels** | `pg_enum` | APPLICATION | `typname:label:sortorder` |
| `row_dml_acl_grant_rows` | grant rows | `aclexplode(relacl)` | APPLICATION | `relname\|grantee\|privilege`, row-DML only |
| `app_non_row_dml_acl_grant_rows` | grant rows | `aclexplode(relacl)` | APPLICATION | Dxtm only; expected 0 after U3 |
| `app_creator_default_acl_rows` | default-ACL rows | `pg_default_acl` grantor=`postgres` | APPLICATION | `scope\|grantee\|privilege`; expected 0 Dxtm after U3 |
| `storage_policies` | policies | `pg_policies` schema='storage' | APPLICATION on a PLATFORM relation | `policy:cmd:qual:with_check` |
| `event_triggers` | event triggers | `pg_event_trigger` | APPLICATION where owner=`postgres` | `name:event:enabled:tags` |
| `publication_objects` | **publications** | `pg_publication` | PLATFORM_RECORDED_ONLY | `pubname` |
| `publication_membership_rows` | **member tables** | `pg_publication_tables` | APPLICATION | `pubname:schema.table` |
| `extensions_app_owned` | extensions | `pg_extension` ∈ {pgcrypto, uuid-ossp} | APPLICATION — **gated** | `extname` |
| `extensions_all_recorded` | extensions | `pg_extension` | PLATFORM_RECORDED_ONLY — **not gated** | `extname` |

## Unit reconciliation

Earlier inventory language used units that a count alone cannot disambiguate. Reconciled:

| earlier phrasing | correct reading |
|---|---|
| "1 enum" | `enum_types = 1`, `enum_label_rows = 3` |
| "publication count = 1" | `publication_objects = 1` (platform), `publication_membership_rows = 0` (application) |
| "4 extensions as previously classified" | application-owned **2** (`pgcrypto`, `uuid-ossp`) + platform-provisioned **2** (`pg_stat_statements`, `supabase_vault`); `plpgsql` is PostgreSQL's default and present in every database |

## Platform classification

| state | class | gated? |
|---|---|---|
| `postgres`/`public` creator default ACL | APPLICATION_OWNED | yes |
| `supabase_admin` and other grantor default ACLs | PLATFORM_BASELINE | recorded |
| `supabase_vault`, `pg_stat_statements` | PLATFORM_RECORDED_ONLY | recorded |
| `supabase_realtime` publication object | PLATFORM_RECORDED_ONLY | recorded |
| event triggers owned by `supabase_admin` | PLATFORM_BASELINE | recorded |
| `auth.users`, `storage.objects`, client roles | PLATFORM_REQUIRED_FOR_APPLICATION_SEMANTICS | prerequisite |


---

## Column-contract versions

| version | column contract | status |
|---|---|---|
| **V1** | no column fingerprint; count only | executed hosted, partial coverage — 12 of 24 dimensions |
| **V2** | five rendered fields: `table.column:data_type:is_nullable:column_default` · canonical `4b5b967fcbb085db5e7ae4fd20a07653` | executed hosted, **SUPERSEDED**. False positive: `column_default` is search_path-sensitive (reproduced locally — the same schema yields `4b5b967f…` under `search_path=public` and `9521ca65…`, the exact hosted value, under `public,extensions`). False negatives: no typmod, identity, generated, collation or ordinal — `varchar(100)→varchar(500)` proven invisible. |
| **V3** | fourteen semantic fields (schema, table, column, ordinal, type namespace+name, format_type, typmod, typtype, base type, notnull, identity, generated, collation, default semantic identity) · canonical `e17e4f0e750680a8003f52cff1fa5a16` | **FINAL AUTHORITY** — hosted executed, ALL_PASS, HOSTED_POST0063_MATCHES_CANONICAL_V3 |

V1 and V2 results are historical and are **not** rewritten. V3's default semantics resolve
function defaults through `pg_depend → pg_proc` and sequence defaults through `pg_depend → pg_class`;
literals use a deterministic normalized expression with casts and qualification preserved.
