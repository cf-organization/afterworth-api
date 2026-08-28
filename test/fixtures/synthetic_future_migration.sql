-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- SYNTHETIC FUTURE MIGRATION — TEST FIXTURE ONLY — NEVER A REAL MIGRATION
--
-- ★ THIS FILE MUST NEVER ENTER db/migrations/ AND MUST NEVER BE NUMBERED 0061.
--   It exists to prove ONE property: that a post-cutover migration applies identically to
--   (A) a database restored from the authoritative snapshot — i.e. the upgraded production shape —
--   and (B) a database built by the componentized Model C bootstrap.
--   If those two diverge, the bootstrap is not a substitute for the real schema and the cutover
--   contract is unsound. Nothing here is a product change.
-- ════════════════════════════════════════════════════════════════════════════════════════════════

alter table public.estates add column if not exists synthetic_probe_note text;

create index if not exists synthetic_probe_estates_idx on public.estates (synthetic_probe_note);

create or replace function public.synthetic_probe_fn(p_estate uuid)
  returns boolean
  language sql
  stable
  security definer
  set search_path to 'pg_catalog', 'public'
  as $$ select exists (select 1 from public.estates e where e.id = p_estate) $$;

create table if not exists public.synthetic_probe_table (
  id uuid primary key default extensions.uuid_generate_v4(),
  estate_id uuid not null references public.estates(id) on delete cascade,
  note text
);

alter table public.synthetic_probe_table enable row level security;

create policy synthetic_probe_read on public.synthetic_probe_table
  for select to authenticated
  using (public.is_estate_owner(estate_id));
