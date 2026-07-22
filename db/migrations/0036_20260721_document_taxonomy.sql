-- 0036_20260721_document_taxonomy — SERVER-AUTHORITATIVE document taxonomy (extends 0035, before iOS).
--
-- Moves the doc-type / subtype / sensitivity vocabularies OUT of inline CHECKs + Swift enums and INTO three
-- config tables the client reads at runtime — so the vocabulary can GROW WITHOUT AN APP RELEASE. The server
-- says MEANING (semantic keys: badge_color_key ∈ neutral/info/warning/critical, icon_key ∈ SF-symbol-ish
-- names); iOS maps meaning -> its design system. NEVER hex colors or literal styling in these tables.
--
-- SHAPE (all three): value/subtype PK, display_name, description, rank, sort_order, badge_color_key, icon_key,
-- is_active. document_subtype additionally keeps parent_doc_type (renamed from 0035's doc_type). Seeds: 11
-- doc_types, 5 sensitivities (low<medium<high<restricted<sealed by rank), and BACKFILL display metadata onto
-- the 132 subtypes already seeded by 0035. (Nothing sensitive rides in `description` — confirmed: they are
-- generic category blurbs; the taxonomy is NOT an attack map, so get_document_taxonomy is client-readable.)
--
-- CONSTRAINTS: documents.doc_type / documents.sensitivity and document_subtype.parent_doc_type now derive from
-- the tables via FOREIGN KEY (not inline CHECK). CHOSEN: FK + is_active over a CHECK-via-lookup. Justify: the FK
-- gives real referential integrity (a row can NEVER carry a value absent from the catalog) AND, on the default
-- RESTRICT, protects a value that has rows from deletion; `is_active` is the orthogonal LIFECYCLE lever — retire
-- a value by deactivating it (drops from the payload + rejected for NEW writes in-RPC) while existing rows keep
-- it (the FK is still satisfied). A CHECK-via-lookup can't express "referenced values can't vanish."
--
-- ★ REGRESSION (proven): existing 10+ documents rows + submit_claim_with_evidence's COARSE writes
--   (death_certificate / id_document, sensitivity DEFAULT 'sealed') stay valid — all those values are seeded
--   into the catalogs BEFORE the FKs are added, and 0031 is UNTOUCHED (its direct coarse insert only needs the
--   value to EXIST, which it does; it does not consult is_active).
--
-- ★ VERSIONING (taxonomy_version, single row):
--   • vocabulary_version — bumps on VALUE changes (new/edited/removed doc_type|subtype|sensitivity). This is a
--     CACHE-INVALIDATION signal ONLY. A client must NEVER gate behavior on it — gating would destroy the
--     "grow the taxonomy without an app release" property. Enforced by a TRIGGER on all three tables (a
--     statement-level AFTER trigger bumps it) — chosen over a documented convention because a trigger CANNOT be
--     forgotten by a future seeding migration. (The triggers are created AFTER the initial seed, so the seed
--     itself does not inflate the version — it stays at 1 post-migration.)
--   • schema_version — bumps ONLY when the get_document_taxonomy PAYLOAD STRUCTURE changes (a new field, a
--     removed field, a renamed key). This is the ONLY value a client may gate on. Rare by design; bumped by
--     hand in the migration that changes the payload, never by the trigger.
--
-- get_document_taxonomy() (DEFINER, authenticated, REVOKE public/anon) returns the whole payload (active values
-- only) so the client renders from server metadata + caches by vocabulary_version. create_vault_document /
-- update_vault_document validate against the TABLES (no inline lists), NO signature change. Supabase-direct
-- throughout (no endpoint, api stays 12/12). Captured to VC: db/tables/{document_type,document_sensitivity,
-- taxonomy_version,document_subtype}.sql, db/functions/{get_document_taxonomy,create_vault_document,
-- update_vault_document,bump_taxonomy_vocabulary_version}.sql.

begin;

-- ============================================================ 1. taxonomy_version + bump trigger fn ==========
create table if not exists public.taxonomy_version (
  id                 int         primary key default 1 check (id = 1),
  schema_version     int         not null default 1,
  vocabulary_version int         not null default 1,
  updated_at         timestamptz not null default now()
);
alter table public.taxonomy_version enable row level security;   -- born clean; read via get_document_taxonomy
insert into public.taxonomy_version (id, schema_version, vocabulary_version) values (1, 1, 1)
  on conflict (id) do nothing;

create or replace function public.bump_taxonomy_vocabulary_version()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
begin
  -- Statement-level AFTER trigger: any VALUE change to a taxonomy table invalidates client caches.
  update public.taxonomy_version set vocabulary_version = vocabulary_version + 1, updated_at = now() where id = 1;
  return null;
end;
$function$;

-- ============================================================ 2. document_type (coarse, 11 values) ==========
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
alter table public.document_type enable row level security;   -- born clean; read via get_document_taxonomy

insert into public.document_type (value, display_name, description, rank, sort_order, badge_color_key, icon_key) values
  ('will',              'Will',              'A legal will directing distribution of the estate.',      1,  1,  'neutral',  'doc.text.fill'),
  ('trust',             'Trust',             'A trust instrument holding or directing estate assets.',  2,  2,  'neutral',  'building.columns.fill'),
  ('power_of_attorney', 'Power of Attorney', 'Authority for an agent to act on the principal''s behalf.',3, 3,  'info',     'signature'),
  ('insurance_policy',  'Insurance Policy',  'An insurance policy or coverage document.',               4,  4,  'info',     'shield.lefthalf.filled'),
  ('deed',              'Deed',              'A property deed or title record.',                        5,  5,  'neutral',  'house.fill'),
  ('id_document',       'ID Document',       'A government or personal identity document.',             6,  6,  'warning',  'person.text.rectangle.fill'),
  ('tax_return',        'Tax Return',        'A tax return or related tax record.',                     7,  7,  'neutral',  'percent'),
  ('medical_directive', 'Medical Directive', 'A healthcare or medical directive.',                      8,  8,  'warning',  'cross.case.fill'),
  ('beneficiary_form',  'Beneficiary Form',  'A beneficiary designation form.',                         9,  9,  'info',     'person.2.fill'),
  ('death_certificate', 'Death Certificate', 'An official death certificate.',                          10, 10, 'critical', 'doc.badge.clock'),
  ('other',             'Other',             'A document that does not fit another category.',          99, 99, 'neutral',  'doc.fill')
on conflict (value) do nothing;

-- ============================================================ 3. document_sensitivity (5 levels, rank-ordered) =
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
alter table public.document_sensitivity enable row level security;   -- born clean; read via get_document_taxonomy

insert into public.document_sensitivity (value, display_name, description, rank, sort_order, badge_color_key, icon_key) values
  ('low',        'Low',        'Minimal sensitivity; broadly shareable within the estate.',   1, 1, 'neutral',  'lock.open'),
  ('medium',     'Medium',     'Moderate sensitivity; shared on a need-to-know basis.',       2, 2, 'info',     'lock'),
  ('high',       'High',       'High sensitivity; limited disclosure.',                       3, 3, 'warning',  'lock.fill'),
  ('restricted', 'Restricted', 'Restricted; disclosed only under explicit access conditions.',4, 4, 'critical', 'lock.shield'),
  ('sealed',     'Sealed',     'Sealed; not disclosed until release conditions are met.',     5, 5, 'critical', 'lock.shield.fill')
on conflict (value) do nothing;

-- ============================================================ 4. EXTEND document_subtype (from 0035) =========
alter table public.document_subtype
  add column if not exists display_name    text,
  add column if not exists description     text,
  add column if not exists rank            int  not null default 0,
  add column if not exists sort_order      int  not null default 0,
  add column if not exists badge_color_key text,
  add column if not exists icon_key        text;

-- Rename 0035's doc_type -> parent_doc_type (idempotent), drop its inline CHECK, add FK -> document_type.
do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema='public' and table_name='document_subtype' and column_name='doc_type')
     and not exists (select 1 from information_schema.columns
             where table_schema='public' and table_name='document_subtype' and column_name='parent_doc_type') then
    alter table public.document_subtype rename column doc_type to parent_doc_type;
  end if;
end $$;

do $$
declare c text;
begin
  for c in select conname from pg_constraint
             where conrelid='public.document_subtype'::regclass and contype='c'
               and pg_get_constraintdef(oid) ilike '%doc_type%'
  loop execute 'alter table public.document_subtype drop constraint '||quote_ident(c); end loop;
end $$;

alter table public.document_subtype
  add constraint document_subtype_parent_doc_type_fkey
    foreign key (parent_doc_type) references public.document_type(value);

-- Backfill display metadata onto the 132 subtypes (display_name humanized, semantic keys inherited from parent).
update public.document_subtype ds set
  display_name = v.display_name, sort_order = v.sort_order, rank = v.rank,
  badge_color_key = v.badge_color_key, icon_key = v.icon_key
from (values
  ('will', 'Will', 1, 1, 'neutral', 'doc.text.fill'),
  ('trustDocument', 'Trust Document', 2, 2, 'neutral', 'building.columns.fill'),
  ('medicalPowerOfAttorney', 'Medical Power Of Attorney', 3, 3, 'info', 'signature'),
  ('powerOfAttorney', 'Power Of Attorney', 4, 3, 'info', 'signature'),
  ('annuityContract', 'Annuity Contract', 5, 4, 'info', 'shield.lefthalf.filled'),
  ('autoInsurancePolicy', 'Auto Insurance Policy', 6, 4, 'info', 'shield.lefthalf.filled'),
  ('disabilityInsurancePolicy', 'Disability Insurance Policy', 7, 4, 'info', 'shield.lefthalf.filled'),
  ('healthInsurancePolicy', 'Health Insurance Policy', 8, 4, 'info', 'shield.lefthalf.filled'),
  ('homeownersInsurancePolicy', 'Homeowners Insurance Policy', 9, 4, 'info', 'shield.lefthalf.filled'),
  ('lifeInsurancePolicy', 'Life Insurance Policy', 10, 4, 'info', 'shield.lefthalf.filled'),
  ('longTermCarePolicy', 'Long Term Care Policy', 11, 4, 'info', 'shield.lefthalf.filled'),
  ('termLifePolicy', 'Term Life Policy', 12, 4, 'info', 'shield.lefthalf.filled'),
  ('umbrellaInsurancePolicy', 'Umbrella Insurance Policy', 13, 4, 'info', 'shield.lefthalf.filled'),
  ('wholeLifeCashValueStatement', 'Whole Life Cash Value Statement', 14, 4, 'info', 'shield.lefthalf.filled'),
  ('propertyDeed', 'Property Deed', 15, 5, 'neutral', 'house.fill'),
  ('adoptionRecords', 'Adoption Records', 16, 6, 'warning', 'person.text.rectangle.fill'),
  ('birthCertificate', 'Birth Certificate', 17, 6, 'warning', 'person.text.rectangle.fill'),
  ('divorceDecree', 'Divorce Decree', 18, 6, 'warning', 'person.text.rectangle.fill'),
  ('driversLicense', 'Drivers License', 19, 6, 'warning', 'person.text.rectangle.fill'),
  ('greenCard', 'Green Card', 20, 6, 'warning', 'person.text.rectangle.fill'),
  ('immigrationDocuments', 'Immigration Documents', 21, 6, 'warning', 'person.text.rectangle.fill'),
  ('marriageCertificate', 'Marriage Certificate', 22, 6, 'warning', 'person.text.rectangle.fill'),
  ('naturalizationCertificate', 'Naturalization Certificate', 23, 6, 'warning', 'person.text.rectangle.fill'),
  ('passport', 'Passport', 24, 6, 'warning', 'person.text.rectangle.fill'),
  ('socialSecurityCard', 'Social Security Card', 25, 6, 'warning', 'person.text.rectangle.fill'),
  ('stateID', 'State ID', 26, 6, 'warning', 'person.text.rectangle.fill'),
  ('cpaLetter', 'CPA Letter', 27, 7, 'neutral', 'percent'),
  ('estateTaxDocument', 'Estate Tax Document', 28, 7, 'neutral', 'percent'),
  ('form1099', '1099', 29, 7, 'neutral', 'percent'),
  ('giftTaxDocument', 'Gift Tax Document', 30, 7, 'neutral', 'percent'),
  ('irsNotice', 'IRS Notice', 31, 7, 'neutral', 'percent'),
  ('k1', 'K-1', 32, 7, 'neutral', 'percent'),
  ('propertyTaxRecord', 'Property Tax Record', 33, 7, 'neutral', 'percent'),
  ('taxPlanningNotes', 'Tax Planning Notes', 34, 7, 'neutral', 'percent'),
  ('taxReturn', 'Tax Return', 35, 7, 'neutral', 'percent'),
  ('w2', 'W-2', 36, 7, 'neutral', 'percent'),
  ('beneficiaryDesignationForm', 'Beneficiary Designation Form', 37, 9, 'info', 'person.2.fill'),
  ('accountClosureInstruction', 'Account Closure Instruction', 38, 99, 'neutral', 'doc.fill'),
  ('advanceHealthcareDirective', 'Advance Healthcare Directive', 39, 99, 'neutral', 'doc.fill'),
  ('attorneyLetter', 'Attorney Letter', 40, 99, 'neutral', 'doc.fill'),
  ('award', 'Award', 41, 99, 'neutral', 'doc.fill'),
  ('awardLetter', 'Award Letter', 42, 99, 'neutral', 'doc.fill'),
  ('bankStatement', 'Bank Statement', 43, 99, 'neutral', 'doc.fill'),
  ('beneficiaryID', 'Beneficiary ID', 44, 99, 'neutral', 'doc.fill'),
  ('boatTitle', 'Boat Title', 45, 99, 'neutral', 'doc.fill'),
  ('brokerageStatement', 'Brokerage Statement', 46, 99, 'neutral', 'doc.fill'),
  ('businessFormationDocument', 'Business Formation Document', 47, 99, 'neutral', 'doc.fill'),
  ('businessInsuranceDocument', 'Business Insurance Document', 48, 99, 'neutral', 'doc.fill'),
  ('businessMilestone', 'Business Milestone', 49, 99, 'neutral', 'doc.fill'),
  ('businessSuccessionPlan', 'Business Succession Plan', 50, 99, 'neutral', 'doc.fill'),
  ('businessTaxRecord', 'Business Tax Record', 51, 99, 'neutral', 'doc.fill'),
  ('buySellAgreement', 'Buy Sell Agreement', 52, 99, 'neutral', 'doc.fill'),
  ('capTable', 'Cap Table', 53, 99, 'neutral', 'doc.fill'),
  ('carePlan', 'Care Plan', 54, 99, 'neutral', 'doc.fill'),
  ('caregiverInstructions', 'Caregiver Instructions', 55, 99, 'neutral', 'doc.fill'),
  ('certificate', 'Certificate', 56, 99, 'neutral', 'doc.fill'),
  ('certificateOfAchievement', 'Certificate Of Achievement', 57, 99, 'neutral', 'doc.fill'),
  ('charityCommunityServiceRecord', 'Charity Community Service Record', 58, 99, 'neutral', 'doc.fill'),
  ('contract', 'Contract', 59, 99, 'neutral', 'doc.fill'),
  ('corporateBylaws', 'Corporate Bylaws', 60, 99, 'neutral', 'doc.fill'),
  ('courtOrder', 'Court Order', 61, 99, 'neutral', 'doc.fill'),
  ('creditCardStatement', 'Credit Card Statement', 62, 99, 'neutral', 'doc.fill'),
  ('cryptoTaxReport', 'Crypto Tax Report', 63, 99, 'neutral', 'doc.fill'),
  ('cryptoWalletInventory', 'Crypto Wallet Inventory', 64, 99, 'neutral', 'doc.fill'),
  ('customDocument', 'Custom Document', 65, 99, 'neutral', 'doc.fill'),
  ('dd214', 'DD214', 66, 99, 'neutral', 'doc.fill'),
  ('debtRecord', 'Debt Record', 67, 99, 'neutral', 'doc.fill'),
  ('dependentInformation', 'Dependent Information', 68, 99, 'neutral', 'doc.fill'),
  ('digitalAssetInventory', 'Digital Asset Inventory', 69, 99, 'neutral', 'doc.fill'),
  ('diploma', 'Diploma', 70, 99, 'neutral', 'doc.fill'),
  ('disabilityRecord', 'Disability Record', 71, 99, 'neutral', 'doc.fill'),
  ('doctorContactList', 'Doctor Contact List', 72, 99, 'neutral', 'doc.fill'),
  ('document401k', '401(k) Document', 73, 99, 'neutral', 'doc.fill'),
  ('emergencyContactList', 'Emergency Contact List', 74, 99, 'neutral', 'doc.fill'),
  ('emergencyMedicalInformation', 'Emergency Medical Information', 75, 99, 'neutral', 'doc.fill'),
  ('employmentContract', 'Employment Contract', 76, 99, 'neutral', 'doc.fill'),
  ('exchangeAccountStatement', 'Exchange Account Statement', 77, 99, 'neutral', 'doc.fill'),
  ('executorInstructions', 'Executor Instructions', 78, 99, 'neutral', 'doc.fill'),
  ('familyContactList', 'Family Contact List', 79, 99, 'neutral', 'doc.fill'),
  ('familyHistory', 'Family History', 80, 99, 'neutral', 'doc.fill'),
  ('funeralBurialInstructions', 'Funeral Burial Instructions', 81, 99, 'neutral', 'doc.fill'),
  ('governmentBenefitsLetter', 'Government Benefits Letter', 82, 99, 'neutral', 'doc.fill'),
  ('guardianshipInstructions', 'Guardianship Instructions', 83, 99, 'neutral', 'doc.fill'),
  ('hardwareWalletLocationReference', 'Hardware Wallet Location Reference', 84, 99, 'neutral', 'doc.fill'),
  ('healthcareDirective', 'Healthcare Directive', 85, 99, 'neutral', 'doc.fill'),
  ('homeInventory', 'Home Inventory', 86, 99, 'neutral', 'doc.fill'),
  ('insuranceCard', 'Insurance Card', 87, 99, 'neutral', 'doc.fill'),
  ('iraDocument', 'IRA Document', 88, 99, 'neutral', 'doc.fill'),
  ('landOwnershipRecord', 'Land Ownership Record', 89, 99, 'neutral', 'doc.fill'),
  ('leaseAgreement', 'Lease Agreement', 90, 99, 'neutral', 'doc.fill'),
  ('legacyMessage', 'Legacy Message', 91, 99, 'neutral', 'doc.fill'),
  ('legalAgreement', 'Legal Agreement', 92, 99, 'neutral', 'doc.fill'),
  ('letterOfInstruction', 'Letter Of Instruction', 93, 99, 'neutral', 'doc.fill'),
  ('lettersTestamentary', 'Letters Testamentary', 94, 99, 'neutral', 'doc.fill'),
  ('lifeStoryDocument', 'Life Story Document', 95, 99, 'neutral', 'doc.fill'),
  ('livingWill', 'Living Will', 96, 99, 'neutral', 'doc.fill'),
  ('loanDocument', 'Loan Document', 97, 99, 'neutral', 'doc.fill'),
  ('medicalRecord', 'Medical Record', 98, 99, 'neutral', 'doc.fill'),
  ('militaryID', 'Military ID', 99, 99, 'neutral', 'doc.fill'),
  ('minorChildInstructions', 'Minor Child Instructions', 100, 99, 'neutral', 'doc.fill'),
  ('miscellaneousRecord', 'Miscellaneous Record', 101, 99, 'neutral', 'doc.fill'),
  ('mortgageDocument', 'Mortgage Document', 102, 99, 'neutral', 'doc.fill'),
  ('mortgageStatement', 'Mortgage Statement', 103, 99, 'neutral', 'doc.fill'),
  ('nftOwnershipRecord', 'NFT Ownership Record', 104, 99, 'neutral', 'doc.fill'),
  ('notarizedDocument', 'Notarized Document', 105, 99, 'neutral', 'doc.fill'),
  ('operatingAgreement', 'Operating Agreement', 106, 99, 'neutral', 'doc.fill'),
  ('partnershipAgreement', 'Partnership Agreement', 107, 99, 'neutral', 'doc.fill'),
  ('patentDocument', 'Patent Document', 108, 99, 'neutral', 'doc.fill'),
  ('pensionBenefitsDocument', 'Pension Benefits Document', 109, 99, 'neutral', 'doc.fill'),
  ('pensionDocument', 'Pension Document', 110, 99, 'neutral', 'doc.fill'),
  ('personalLetter', 'Personal Letter', 111, 99, 'neutral', 'doc.fill'),
  ('personalValuesStatement', 'Personal Values Statement', 112, 99, 'neutral', 'doc.fill'),
  ('petCareInstructions', 'Pet Care Instructions', 113, 99, 'neutral', 'doc.fill'),
  ('photosMemorabiliaReference', 'Photos Memorabilia Reference', 114, 99, 'neutral', 'doc.fill'),
  ('plan529Document', '529 Plan Document', 115, 99, 'neutral', 'doc.fill'),
  ('prescriptionList', 'Prescription List', 116, 99, 'neutral', 'doc.fill'),
  ('probateDocument', 'Probate Document', 117, 99, 'neutral', 'doc.fill'),
  ('professionalLicense', 'Professional License', 118, 99, 'neutral', 'doc.fill'),
  ('professionalRecognition', 'Professional Recognition', 119, 99, 'neutral', 'doc.fill'),
  ('propertyAppraisal', 'Property Appraisal', 120, 99, 'neutral', 'doc.fill'),
  ('propertyInsuranceDocument', 'Property Insurance Document', 121, 99, 'neutral', 'doc.fill'),
  ('publishedWork', 'Published Work', 122, 99, 'neutral', 'doc.fill'),
  ('recoveryLocationReference', 'Recovery Location Reference', 123, 99, 'neutral', 'doc.fill'),
  ('referenceLetter', 'Reference Letter', 124, 99, 'neutral', 'doc.fill'),
  ('resume', 'Resume', 125, 99, 'neutral', 'doc.fill'),
  ('retirementAccountStatement', 'Retirement Account Statement', 126, 99, 'neutral', 'doc.fill'),
  ('settlementAgreement', 'Settlement Agreement', 127, 99, 'neutral', 'doc.fill'),
  ('socialSecurityBenefitsDocument', 'Social Security Benefits Document', 128, 99, 'neutral', 'doc.fill'),
  ('stockCertificate', 'Stock Certificate', 129, 99, 'neutral', 'doc.fill'),
  ('trainingCertificate', 'Training Certificate', 130, 99, 'neutral', 'doc.fill'),
  ('vehicleTitle', 'Vehicle Title', 131, 99, 'neutral', 'doc.fill'),
  ('veteransBenefitsDocument', 'Veterans Benefits Document', 132, 99, 'neutral', 'doc.fill')
) as v(subtype, display_name, sort_order, rank, badge_color_key, icon_key)
where ds.subtype = v.subtype;

-- Every seeded subtype is backfilled -> display_name is now mandatory.
alter table public.document_subtype alter column display_name set not null;

-- ============================================================ 5. documents FKs (replace inline CHECKs) =======
do $$
declare c text;
begin
  for c in select conname from pg_constraint
             where conrelid='public.documents'::regclass and contype='c'
               and pg_get_constraintdef(oid) ilike '%doc_type%'
  loop execute 'alter table public.documents drop constraint '||quote_ident(c); end loop;
  for c in select conname from pg_constraint
             where conrelid='public.documents'::regclass and contype='c'
               and pg_get_constraintdef(oid) ilike '%sensitivity%'
  loop execute 'alter table public.documents drop constraint '||quote_ident(c); end loop;
end $$;

alter table public.documents
  add constraint documents_doc_type_fkey    foreign key (doc_type)    references public.document_type(value),
  add constraint documents_sensitivity_fkey foreign key (sensitivity) references public.document_sensitivity(value);

-- ============================================================ 6. bump triggers (AFTER the seed, so seed=no bump)
create or replace trigger document_type_taxonomy_bump
  after insert or update or delete on public.document_type
  for each statement execute function public.bump_taxonomy_vocabulary_version();
create or replace trigger document_subtype_taxonomy_bump
  after insert or update or delete on public.document_subtype
  for each statement execute function public.bump_taxonomy_vocabulary_version();
create or replace trigger document_sensitivity_taxonomy_bump
  after insert or update or delete on public.document_sensitivity
  for each statement execute function public.bump_taxonomy_vocabulary_version();

-- ============================================================ 7. get_document_taxonomy() (client read path) ===
create or replace function public.get_document_taxonomy()
 returns jsonb
 language sql
 security definer
 stable
 set search_path to 'public'
as $function$
  select jsonb_build_object(
    'schema_version',     (select schema_version     from public.taxonomy_version where id = 1),
    'vocabulary_version', (select vocabulary_version from public.taxonomy_version where id = 1),
    'doc_types', coalesce((
      select jsonb_agg(jsonb_build_object(
        'value', value, 'display_name', display_name, 'description', description,
        'rank', rank, 'sort_order', sort_order, 'badge_color_key', badge_color_key, 'icon_key', icon_key)
        order by sort_order, value)
      from public.document_type where is_active), '[]'::jsonb),
    'subtypes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'value', subtype, 'display_name', display_name, 'description', description, 'parent_doc_type', parent_doc_type,
        'rank', rank, 'sort_order', sort_order, 'badge_color_key', badge_color_key, 'icon_key', icon_key)
        order by sort_order, subtype)
      from public.document_subtype where is_active), '[]'::jsonb),
    'sensitivities', coalesce((
      select jsonb_agg(jsonb_build_object(
        'value', value, 'display_name', display_name, 'description', description,
        'rank', rank, 'sort_order', sort_order, 'badge_color_key', badge_color_key, 'icon_key', icon_key)
        order by rank, value)
      from public.document_sensitivity where is_active), '[]'::jsonb)
  );
$function$;
revoke execute on function public.get_document_taxonomy() from public, anon;
grant  execute on function public.get_document_taxonomy() to authenticated;

-- ============================================================ 8. RPCs validate against the TABLES (no sig change)
create or replace function public.create_vault_document(
  p_estate       uuid,
  p_doc_id       uuid,
  p_storage_path text,
  p_title        text,
  p_doc_subtype  text,
  p_sensitivity  text default 'sealed'
)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid       uuid := auth.uid();
  v_doc_type  text;
  v_size      bigint;
  v_mime      text;
  v_max_bytes bigint;
  v_mimes     text[];
begin
  if v_uid is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;
  if not public.is_estate_owner(p_estate) then
    raise exception 'not_estate_owner' using errcode = '42501';
  end if;
  if not exists (select 1 from public.estates where id = p_estate) then
    raise exception 'estate_not_found' using errcode = 'P0002';
  end if;

  if p_title is null or length(btrim(p_title)) = 0 then
    raise exception 'title_required' using errcode = 'P0001';
  end if;
  if length(p_title) > 200 then
    raise exception 'title_too_long' using errcode = 'P0001';
  end if;

  -- subtype-in / both-out: derive parent_doc_type from the catalog (unknown vs inactive).
  select ds.parent_doc_type into v_doc_type
    from public.document_subtype ds
    where ds.subtype = p_doc_subtype and ds.is_active;
  if not found then
    if exists (select 1 from public.document_subtype where subtype = p_doc_subtype) then
      raise exception 'inactive_subtype' using errcode = 'P0001';
    else
      raise exception 'unknown_subtype' using errcode = 'P0001';
    end if;
  end if;

  -- sensitivity validated against the TABLE (active values only).
  if p_sensitivity is not null
     and not exists (select 1 from public.document_sensitivity where value = p_sensitivity and is_active) then
    raise exception 'invalid_sensitivity' using errcode = 'P0001';
  end if;

  if p_storage_path !~ ('^estates/' || p_estate::text || '/vault/' || p_doc_id::text || '\.[a-zA-Z0-9]+$') then
    raise exception 'vault_path_mismatch' using errcode = 'P0001';
  end if;

  select (o.metadata->>'size')::bigint, o.metadata->>'mimetype' into v_size, v_mime
    from storage.objects o where o.bucket_id = 'documents' and o.name = p_storage_path;
  if not found then
    raise exception 'vault_object_missing' using errcode = 'P0002';
  end if;

  select max_upload_bytes, allowed_mime_types into v_max_bytes, v_mimes
    from public.upload_policy where id = 1;
  if coalesce(v_size, 0) > v_max_bytes then
    raise exception 'vault_too_large' using errcode = 'P0001';
  end if;
  if v_mime is null or not (v_mime = any(v_mimes)) then
    raise exception 'vault_mime_rejected' using errcode = 'P0001';
  end if;

  insert into public.documents
    (id, estate_id, owner_id, doc_type, doc_subtype, title, storage_path, mime_type, size_bytes, is_encrypted, sensitivity)
  values
    (p_doc_id, p_estate, v_uid, v_doc_type, p_doc_subtype, btrim(p_title), p_storage_path, v_mime, v_size, false,
     coalesce(p_sensitivity, 'sealed'));

  perform public.write_audit('document.created', 'documents', p_doc_id, p_estate,
    jsonb_build_object('doc_id', p_doc_id, 'doc_type', v_doc_type, 'doc_subtype', p_doc_subtype,
                       'via', 'create_vault_document'));

  return p_doc_id;
end;
$function$;

create or replace function public.update_vault_document(
  p_doc_id      uuid,
  p_title       text default null,
  p_doc_subtype text default null,
  p_sensitivity text default null
)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid      uuid := auth.uid();
  v_estate   uuid;
  v_new_type text;
  v_changed  text[] := '{}';
begin
  if v_uid is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;

  select estate_id into v_estate from public.documents where id = p_doc_id;
  if not found then
    raise exception 'document_not_found' using errcode = 'P0002';
  end if;
  if not public.is_estate_owner(v_estate) then
    raise exception 'not_estate_owner' using errcode = '42501';
  end if;

  if p_title is null and p_doc_subtype is null and p_sensitivity is null then
    raise exception 'no_fields_to_update' using errcode = 'P0001';
  end if;

  if p_title is not null then
    if length(btrim(p_title)) = 0 then
      raise exception 'title_required' using errcode = 'P0001';
    end if;
    if length(p_title) > 200 then
      raise exception 'title_too_long' using errcode = 'P0001';
    end if;
    update public.documents set title = btrim(p_title) where id = p_doc_id;
    v_changed := array_append(v_changed, 'title');
  end if;

  if p_doc_subtype is not null then
    select ds.parent_doc_type into v_new_type
      from public.document_subtype ds
      where ds.subtype = p_doc_subtype and ds.is_active;
    if not found then
      if exists (select 1 from public.document_subtype where subtype = p_doc_subtype) then
        raise exception 'inactive_subtype' using errcode = 'P0001';
      else
        raise exception 'unknown_subtype' using errcode = 'P0001';
      end if;
    end if;
    update public.documents set doc_subtype = p_doc_subtype, doc_type = v_new_type where id = p_doc_id;
    v_changed := array_append(v_changed, 'doc_subtype');
    v_changed := array_append(v_changed, 'doc_type');
  end if;

  if p_sensitivity is not null then
    if not exists (select 1 from public.document_sensitivity where value = p_sensitivity and is_active) then
      raise exception 'invalid_sensitivity' using errcode = 'P0001';
    end if;
    update public.documents set sensitivity = p_sensitivity where id = p_doc_id;
    v_changed := array_append(v_changed, 'sensitivity');
  end if;

  perform public.write_audit('document.updated', 'documents', p_doc_id, v_estate,
    jsonb_build_object('doc_id', p_doc_id, 'changed', to_jsonb(v_changed), 'via', 'update_vault_document'));
end;
$function$;

commit;
