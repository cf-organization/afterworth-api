-- 0038_20260722_taxonomy_ia_refinement — user-facing information-architecture refinement of the residual `other`.
--
-- Extends the proven 0037. Purely ADDITIVE + re-point-only for coarse VALUES — the existing coarse values
-- (incl. death_certificate / id_document and the 0037 set) are NEVER renamed or removed, so the claim path
-- (0031) is untouched and NOT modified. schema_version is NOT bumped (payload shape identical).
--
-- ★ Splits the previously-considered mixed `personal_legacy` bucket into TWO cohesive concepts — it is NEVER
--   created here. Achievement/recognition records and legacy/family keepsakes get distinct parents (P13/P14).
--
-- 1. PROMOTION 17 -> 23 (6 NEW coarse types): legacy_and_family, achievements_and_recognition,
--    family_and_beneficiary, education_and_career, military_and_government, estate_planning. Full display
--    metadata; SEMANTIC keys only (badge_color_key ∈ neutral/info/warning/critical, icon_key SF-symbol-ish).
--
-- 2. RE-POINT 38 subtypes out of `other` (exact repository-derived memberships from iOS VaultDocumentType
--    .category, approved in recon). Locked assignments: charityCommunityServiceRecord + businessMilestone ->
--    achievements_and_recognition; militaryID -> military_and_government (the id_document cluster is untouched).
--    Each re-pointed subtype's badge/icon is refreshed to its new parent's (subtype-inherits-parent).
--
-- 3. TARGET POST-STATE: `other` contains ONLY the two true catch-alls — customDocument, miscellaneousRecord
--    (`other` 40 -> 2). No consciously-deferred clusters remain.
--
-- 4. BACKFILL (deterministic CORRECTION): any documents row whose stored doc_type disagrees with its subtype's
--    NEW parent is re-derived. Idempotent; CLAIM rows (doc_subtype NULL) excluded. Pre-flight COUNT (proof doc,
--    "0038" section) reports the exact affected rows BEFORE apply — expected 0 (no test row carries a
--    0038-re-pointed subtype).
--
-- 5. VERSIONING: the coarse INSERT + each re-point UPDATE fire the statement-level bump trigger ->
--    vocabulary_version advances per mutation (exact delta left to trigger semantics). schema_version NOT bumped.

begin;

-- ---- 1. Promotion: 6 new coarse types (additive) ----
insert into public.document_type (value, display_name, description, rank, sort_order, badge_color_key, icon_key) values
  ('legacy_and_family',            'Legacy & Family',             'Personal letters, family history, keepsakes, and legacy messages.',        17, 17, 'neutral', 'heart.circle.fill'),
  ('achievements_and_recognition', 'Achievements & Recognition',  'Awards, recognitions, publications, patents, and milestones.',             18, 18, 'neutral', 'rosette'),
  ('family_and_beneficiary',       'Family & Beneficiary',        'Beneficiary identity, family contacts, and dependent/care information.',    19, 19, 'info',    'person.2.fill'),
  ('education_and_career',         'Education & Career',          'Diplomas, licenses, employment, and career records.',                      20, 20, 'neutral', 'graduationcap.fill'),
  ('military_and_government',      'Military & Government',       'Military service, veteran, and government benefit records.',                21, 21, 'warning', 'shield.righthalf.filled'),
  ('estate_planning',             'Estate Planning Instructions', 'Letters of instruction, funeral/burial wishes, and executor/guardianship instructions.', 22, 22, 'info', 'list.bullet.rectangle.portrait.fill')
on conflict (value) do nothing;

-- ---- 2. Re-point subtypes (parent + refreshed inherited semantic keys) ----
-- legacy_and_family (6) — keepsakes / legacy, SEPARATE from achievements (P14).
update public.document_subtype
  set parent_doc_type = 'legacy_and_family', badge_color_key = 'neutral', icon_key = 'heart.circle.fill'
  where subtype in ('personalLetter','lifeStoryDocument','familyHistory','photosMemorabiliaReference',
                    'legacyMessage','personalValuesStatement');

-- achievements_and_recognition (7) — incl. charityCommunityServiceRecord + businessMilestone (locked).
update public.document_subtype
  set parent_doc_type = 'achievements_and_recognition', badge_color_key = 'neutral', icon_key = 'rosette'
  where subtype in ('award','certificateOfAchievement','professionalRecognition','publishedWork','patentDocument',
                    'businessMilestone','charityCommunityServiceRecord');

-- family_and_beneficiary (7) — beneficiaryID here is a beneficiary RECORD, distinct from beneficiary_form.
update public.document_subtype
  set parent_doc_type = 'family_and_beneficiary', badge_color_key = 'info', icon_key = 'person.2.fill'
  where subtype in ('beneficiaryID','familyContactList','dependentInformation','emergencyContactList',
                    'caregiverInstructions','minorChildInstructions','petCareInstructions');

-- education_and_career (8)
update public.document_subtype
  set parent_doc_type = 'education_and_career', badge_color_key = 'neutral', icon_key = 'graduationcap.fill'
  where subtype in ('diploma','certificate','professionalLicense','resume','employmentContract','awardLetter',
                    'referenceLetter','trainingCertificate');

-- military_and_government (6) — militaryID here (the id_document identity cluster is NOT touched).
update public.document_subtype
  set parent_doc_type = 'military_and_government', badge_color_key = 'warning', icon_key = 'shield.righthalf.filled'
  where subtype in ('militaryID','dd214','veteransBenefitsDocument','governmentBenefitsLetter',
                    'socialSecurityBenefitsDocument','pensionBenefitsDocument');

-- estate_planning (4) — the INSTRUCTIONS residual (will/trust/POA/beneficiary_form already have own types).
update public.document_subtype
  set parent_doc_type = 'estate_planning', badge_color_key = 'info', icon_key = 'list.bullet.rectangle.portrait.fill'
  where subtype in ('letterOfInstruction','funeralBurialInstructions','executorInstructions','guardianshipInstructions');

-- ---- 3. Deterministic backfill (idempotent; claim rows doc_subtype NULL excluded) ----
update public.documents d
  set doc_type = ds.parent_doc_type
  from public.document_subtype ds
  where ds.subtype = d.doc_subtype
    and d.doc_type <> ds.parent_doc_type;

commit;
