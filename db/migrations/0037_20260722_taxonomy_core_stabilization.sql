-- 0037_20260722_taxonomy_core_stabilization — foundational document-taxonomy stabilization (before iOS wiring).
--
-- Rewrites the SUPERSEDED, NEVER-APPLIED draft (commit 46d1954, which proposed a generic `legal` + a mixed
-- `personal_legacy` + only financial/business). That draft never reached the DB, so this is a clean rewrite —
-- NOT a corrective migration. Extends the proven 0035/0036; purely ADDITIVE + re-point-only for the coarse
-- VALUES, so the claim path is untouched.
--
-- ★ REGRESSION GUARANTEE (load-bearing): the 11 existing coarse values are NEVER renamed or removed. `deed` is
--   RETIRED IN PLACE (is_active=false), not deleted — historical rows stay readable (the FK value persists), it
--   just leaves the picker + payload and can't be chosen for new writes. death_certificate + id_document are
--   untouched, so submit_claim_with_evidence (0031) stays valid + is NOT modified.
--
-- 1. PROMOTION 11 -> 17 (6 NEW coarse types): financial_account, business, legal_and_court, healthcare_record,
--    crypto_digital_asset, real_estate. Full display metadata; SEMANTIC keys only. Plus medical_directive is
--    RELABELLED "Medical Directive" -> "Medical Directives" (label-only; it was empty, now gets the 3 directives).
--
-- 2. DEED / REAL_ESTATE (approved Option A): `real_estate` is the broad property category; `propertyDeed` (a
--    SUBTYPE, not a category) moves from `deed` -> `real_estate` alongside the 8 other property subtypes; the
--    stable coarse `deed` value is RETIRED (is_active=false), preserving backward-compat for any historical row.
--
-- 3. RE-POINT: 55 subtypes move out of `other` to the 6 new parents + medical_directive; +propertyDeed moves
--    deed->real_estate. medical_directive gets DIRECTIVES ONLY (advanceHealthcareDirective/livingWill/
--    healthcareDirective) — kept SEPARATE from healthcare_record (medical records). Each re-pointed subtype's
--    badge/icon is refreshed to its new parent's (subtype-inherits-parent). `other` 95 -> 40.
--
-- 4. BACKFILL (deterministic CORRECTION): any documents row whose stored doc_type disagrees with its subtype's
--    NEW parent is re-derived from the parent — this fixes the existing propertyDeed row (deed -> real_estate).
--    Idempotent; CLAIM rows (doc_subtype NULL) are excluded by the join. Christ runs the PRE-FLIGHT COUNT
--    (docs/vault-document-upload-proof.md, "0037" section) BEFORE applying to report the exact affected count.
--
-- 5. VERSIONING: the coarse INSERT + medical relabel + deed retire + each re-point UPDATE fire the statement-level
--    bump trigger -> vocabulary_version advances per mutation (exact delta left to the trigger semantics).
--    schema_version is NOT bumped (payload shape identical — no client gate flip).
--
-- NOTE (deferred, not built here): an RPC guard that rejects deriving an INACTIVE parent is unnecessary today —
-- no ACTIVE subtype points to the only inactive coarse value (`deed`) after this migration (proven by P8). If a
-- future re-point ever aims an active subtype at an inactive parent, add the guard then.

begin;

-- ---- 1. Promotion: 6 new coarse types (additive; the 11 survive) ----
insert into public.document_type (value, display_name, description, rank, sort_order, badge_color_key, icon_key) values
  ('financial_account',    'Financial Accounts',      'Bank, brokerage, retirement, and other financial account records.',        11, 11, 'info',    'banknote.fill'),
  ('business',             'Business',                'Business formation, governance, ownership, tax, insurance, and succession records.', 12, 12, 'neutral', 'briefcase.fill'),
  ('legal_and_court',      'Legal & Court Documents', 'Court filings, agreements, and other legal documents.',                    13, 13, 'warning', 'building.columns'),
  ('healthcare_record',    'Healthcare Records',      'Medical records, prescriptions, and care information (not directives).',    14, 14, 'warning', 'heart.text.square.fill'),
  ('crypto_digital_asset', 'Crypto & Digital Assets', 'Crypto wallets, exchange accounts, and digital-asset records.',             15, 15, 'info',    'bitcoinsign.circle.fill'),
  ('real_estate',          'Real Estate & Property',  'Property deeds, titles, appraisals, and other real-estate records.',        16, 16, 'neutral', 'building.2.fill')
on conflict (value) do nothing;

-- ---- 2. Relabel medical_directive (label-only; now DIRECTIVES-only, kept separate from healthcare_record) ----
update public.document_type
  set display_name = 'Medical Directives',
      description  = 'Advance directives and other healthcare instruction instruments (not medical records).'
  where value = 'medical_directive';

-- ---- 3. Re-point subtypes (parent + refreshed inherited semantic keys) ----
update public.document_subtype
  set parent_doc_type = 'financial_account', badge_color_key = 'info', icon_key = 'banknote.fill'
  where subtype in ('bankStatement','brokerageStatement','retirementAccountStatement','document401k','iraDocument',
                    'plan529Document','pensionDocument','loanDocument','mortgageStatement','creditCardStatement',
                    'debtRecord','accountClosureInstruction');

update public.document_subtype
  set parent_doc_type = 'business', badge_color_key = 'neutral', icon_key = 'briefcase.fill'
  where subtype in ('businessFormationDocument','operatingAgreement','corporateBylaws','stockCertificate','capTable',
                    'businessTaxRecord','partnershipAgreement','buySellAgreement','businessInsuranceDocument',
                    'businessSuccessionPlan');

update public.document_subtype
  set parent_doc_type = 'legal_and_court', badge_color_key = 'warning', icon_key = 'building.columns'
  where subtype in ('courtOrder','settlementAgreement','legalAgreement','attorneyLetter','probateDocument',
                    'lettersTestamentary','notarizedDocument','contract');

update public.document_subtype
  set parent_doc_type = 'medical_directive', badge_color_key = 'warning', icon_key = 'cross.case.fill'
  where subtype in ('advanceHealthcareDirective','livingWill','healthcareDirective');

update public.document_subtype
  set parent_doc_type = 'healthcare_record', badge_color_key = 'warning', icon_key = 'heart.text.square.fill'
  where subtype in ('medicalRecord','prescriptionList','doctorContactList','insuranceCard',
                    'emergencyMedicalInformation','carePlan','disabilityRecord');

update public.document_subtype
  set parent_doc_type = 'crypto_digital_asset', badge_color_key = 'info', icon_key = 'bitcoinsign.circle.fill'
  where subtype in ('cryptoWalletInventory','hardwareWalletLocationReference','exchangeAccountStatement',
                    'digitalAssetInventory','nftOwnershipRecord','cryptoTaxReport','recoveryLocationReference');

update public.document_subtype
  set parent_doc_type = 'real_estate', badge_color_key = 'neutral', icon_key = 'building.2.fill'
  where subtype in ('mortgageDocument','leaseAgreement','propertyAppraisal','homeInventory','vehicleTitle',
                    'boatTitle','landOwnershipRecord','propertyInsuranceDocument','propertyDeed');

-- ---- 4. Retire `deed` (Option A): stable value kept for historical readability; excluded from payload + new writes.
--         (Done AFTER propertyDeed moved off it, so no active subtype points to an inactive parent — see P8.) ----
update public.document_type set is_active = false where value = 'deed';

-- ---- 5. Deterministic backfill: correct rows whose stored doc_type now disagrees with its subtype's parent
--         (fixes the propertyDeed row deed->real_estate). Idempotent; claim rows (doc_subtype NULL) excluded. ----
update public.documents d
  set doc_type = ds.parent_doc_type
  from public.document_subtype ds
  where ds.subtype = d.doc_subtype
    and d.doc_type <> ds.parent_doc_type;

commit;
