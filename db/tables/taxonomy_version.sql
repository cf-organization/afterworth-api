-- public.taxonomy_version — created by migration 0036. Single row (id=1). Two DISTINCT version counters with
-- DIFFERENT contracts (this distinction is load-bearing — do not conflate them):
--
--   • vocabulary_version — bumps on any VALUE change to document_type / document_subtype / document_sensitivity
--     (new/edited/removed row), via the bump_taxonomy_vocabulary_version() statement-level AFTER trigger on all
--     three tables. It is a CACHE-INVALIDATION signal ONLY: the client refetches get_document_taxonomy() when it
--     changes. A client must NEVER gate behavior on it — gating would destroy the "grow the taxonomy without an
--     app release" property this whole design exists for.
--
--   • schema_version — bumps ONLY when the get_document_taxonomy() PAYLOAD STRUCTURE changes (a field added /
--     removed / renamed). It is the ONLY value a client may gate on. Rare by design; bumped BY HAND in the
--     migration that changes the payload — never by the trigger.
--
-- The initial seed sets both = 1; the triggers are created AFTER the 0036 seed, so seeding does not inflate the
-- counter. Born clean: RLS on, NO client grants (surfaced only inside get_document_taxonomy). FK order: none.

create table if not exists public.taxonomy_version (
  id                 int         primary key default 1 check (id = 1),
  schema_version     int         not null default 1,
  vocabulary_version int         not null default 1,
  updated_at         timestamptz not null default now()
);

alter table public.taxonomy_version enable row level security;
-- NO client grants / policies (born clean). Read path = get_document_taxonomy(). Seed: migration 0036 (id=1,1,1).
