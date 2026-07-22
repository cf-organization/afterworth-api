-- public.document_sensitivity — created by migration 0036. The 5-level sensitivity taxonomy, server-authoritative
-- (moved out of the old documents.sensitivity inline CHECK). RANK is the ORDERING (low=1 < medium=2 < high=3 <
-- restricted=4 < sealed=5). Client reads via get_document_taxonomy() and renders from display metadata; SEMANTIC
-- keys only (badge_color_key, icon_key) — NEVER hex/styling.
--
-- Referenced by FK from documents.sensitivity (FK + is_active, same lifecycle posture as document_type).
-- Born clean: RLS on, NO client grants. SEED: 5 rows in migration 0036 (single source). FK order: referenced BY
-- documents. NOTE: submit_claim_with_evidence writes sensitivity='sealed' directly — 'sealed' is seeded, so the
-- FK is satisfied and the claim coarse path is unaffected.

create table if not exists public.document_sensitivity (
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

alter table public.document_sensitivity enable row level security;
-- NO client grants / policies (born clean). Read path = get_document_taxonomy(). Seed: migration 0036.
