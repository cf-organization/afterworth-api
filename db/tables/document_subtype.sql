-- public.document_subtype — created by 0035, EXTENDED by 0036. Source of truth for the PERSIST-BOTH taxonomy:
-- the fine-grained client subtype -> the coarse parent_doc_type (FK to public.document_type), with an is_active
-- gate + display metadata (server-authoritative rendering; SEMANTIC keys only — badge_color_key / icon_key,
-- NEVER hex/styling). The client (create_vault_document / update_vault_document) sends ONLY the subtype; the RPC
-- looks it up, DERIVES parent_doc_type, and persists BOTH (subtype-in / both-out). Unknown -> reject
-- (fail-closed); present-but-inactive -> reject.
--
-- 0036 changes: renamed doc_type -> parent_doc_type (now an FK to document_type(value), replacing the inline
-- CHECK); added display_name (NOT NULL, backfilled) / description / rank / sort_order / badge_color_key /
-- icon_key. Referenced by FK from documents.doc_subtype (nullable — claim rows stay coarse-only). Born clean:
-- RLS on, NO client grants (read via get_document_taxonomy). SEED + display backfill: migrations 0035 (132
-- subtypes) + 0036 (display metadata) — the single source; not duplicated here. FK order: needs document_type.

create table if not exists public.document_subtype (
  subtype         text primary key,
  parent_doc_type text not null references public.document_type(value),
  is_active       boolean     not null default true,
  created_at      timestamptz not null default now(),
  display_name    text        not null,
  description     text,
  rank            int         not null default 0,
  sort_order      int         not null default 0,
  badge_color_key text,
  icon_key        text
);

alter table public.document_subtype enable row level security;
-- NO client grants / policies (born clean). Read path = get_document_taxonomy(). Seed: migrations 0035 + 0036.
