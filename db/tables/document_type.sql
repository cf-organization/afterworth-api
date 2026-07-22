-- public.document_type — created by migration 0036. The COARSE 11-value document taxonomy, server-authoritative
-- (moved out of the old documents.doc_type inline CHECK). Client reads it via get_document_taxonomy() and renders
-- from the display metadata; the server says MEANING via SEMANTIC keys (badge_color_key ∈ neutral/info/warning/
-- critical, icon_key an SF-symbol-ish name) — NEVER hex colors or literal styling.
--
-- Referenced by FK from documents.doc_type and document_subtype.parent_doc_type (FK + is_active: the FK gives
-- integrity + RESTRICT-on-delete; is_active retires a value from NEW writes + the payload without deleting).
-- Born clean: RLS on, NO client grants (read only via the DEFINER get_document_taxonomy). SEED: 11 rows in
-- migration 0036; 0037 adds 6 more (financial_account/business/legal_and_court/healthcare_record/
-- crypto_digital_asset/real_estate) and RETIRES `deed` via is_active=false (kept for historical readability) —
-- net 16 active + deed inactive = 17 rows. Single source (not duplicated here). FK rebuild order: referenced BY
-- documents + document_subtype.

create table if not exists public.document_type (
  value           text        primary key,
  display_name    text        not null,
  description     text,
  rank            int         not null default 0,
  sort_order      int         not null default 0,
  badge_color_key text,
  icon_key        text,
  is_active       boolean     not null default true,
  created_at      timestamptz not null default now()
);

alter table public.document_type enable row level security;
-- NO client grants / policies (born clean). Read path = get_document_taxonomy(). Seed: migration 0036.
