-- 0025_20260715_consent_records — Slice C2: durable, versioned, append-only ACKNOWLEDGMENT consent.
--
-- Fixes the Slice-A mock-consent mislead: tax disclaimer / ToS / platform disclosure were Mock in-memory
-- (reset on relaunch). This makes acknowledgment-class consent a durable historical fact.
--
-- SCOPE = ACKNOWLEDGMENT class ONLY (user affirmed a versioned document at a server-stamped time). EXPLICITLY
-- NOT attestation-grade consent (identity-bound, non-repudiable, statutory, claim-bound, statement-capturing)
-- — that is a STRICTER class deferred to C4 under counsel (a separate estate_attestations record on this
-- pattern; do NOT overload this table with a penalty-of-perjury affirmation).
--
-- Design (LOCKED by recon):
--   * APPEND-ONLY / immutable: a consent is a historical fact. New consent = a NEW ROW, NEVER an update.
--     Enforced structurally by GRANTS — there is NO client UPDATE/DELETE (same immutability posture as
--     audit_logs). Writes flow ONLY through record_consent (DEFINER); reads are own-only via RLS.
--   * SERVER-STAMPED accepted_at: record_consent takes no timestamp — accepted_at defaults to now() server-side.
--     A client timestamp on a consent record is forgeable, so the client can never supply it (no INSERT grant;
--     the RPC never accepts an accepted_at param).
--   * VERSIONING is mandatory: document_version NOT NULL. The gate asks "has this user a row for type X at the
--     CURRENT version?"; a stale (older-version) acceptance re-prompts. Index (user_id, consent_type,
--     document_version) serves that gate.

begin;

create table if not exists public.consent_records (
  id               uuid        not null default uuid_generate_v4(),
  user_id          uuid        not null references auth.users(id) on delete cascade,
  consent_type     text        not null
                     check (consent_type in (
                       'terms_of_service', 'privacy_policy', 'data_sharing',
                       'beneficiary_disclosure', 'tax_disclaimer', 'platform_disclosure'
                     )),
  document_version text        not null,          -- versioning is mandatory
  accepted_at      timestamptz not null default now(),   -- SERVER-derived; never client-supplied
  created_at       timestamptz not null default now(),
  constraint consent_records_pkey primary key (id)
);

-- The "has user accepted type X at version V" gate query.
create index if not exists consent_records_user_type_version_idx
  on public.consent_records (user_id, consent_type, document_version);

alter table public.consent_records enable row level security;

-- Reads: own-only. Writes are RPC-only (no INSERT policy/grant); no UPDATE/DELETE (append-only).
create policy consent_own_read on public.consent_records
  for select using (user_id = auth.uid());
grant select on public.consent_records to authenticated;   -- SELECT only; no insert/update/delete grant

-- ==================================================================================================
-- record_consent — the SOLE write path. DEFINER, gated inside. Stamps user_id=auth.uid() (a client can
-- never record consent for another user — there is no p_user param) and accepted_at=now() server-side.
-- ==================================================================================================
create or replace function public.record_consent(p_type text, p_version text)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_uid uuid := auth.uid(); v_id uuid;
begin
  if v_uid is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;
  if p_version is null or length(btrim(p_version)) = 0 then
    raise exception 'version_required' using errcode = 'P0001';
  end if;
  -- consent_type is validated by the table CHECK (single source of truth for the acknowledgment vocabulary;
  -- a bad type raises check_violation). accepted_at/created_at are server defaults — the client cannot supply them.
  insert into public.consent_records (user_id, consent_type, document_version)
  values (v_uid, p_type, p_version)
  returning id into v_id;
  return v_id;
end;
$function$;
revoke execute on function public.record_consent(text, text) from public, anon;
grant  execute on function public.record_consent(text, text) to authenticated;

commit;
