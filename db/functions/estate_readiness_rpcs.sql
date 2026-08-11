-- Estate-readiness RPC — Phase 10-C. Source of truth; re-apply on reset.
--
-- Answers ONE question: **what factual gaps exist in the information the owner has entered into
-- AfterWorth?**
--
-- ★ IT IS NOT A SCORE, A GRADE, A PERCENTAGE OR A HEALTH RATING, AND THE SHAPE MAKES THAT TRUE.
-- There is no numerator, no denominator and no weighting anywhere below — only a list of findings,
-- each naming the object it concerns and the fact that is missing. A score would be a legal-adjacent
-- conclusion this product has no basis to draw: "82% ready" implies someone assessed sufficiency,
-- and nobody did.
--
-- ★ EVERY FINDING IS PROVABLE FROM THE SCHEMA. Nothing here says an insurance policy "needs a
-- beneficiary" — the system holds no authoritative per-asset beneficiary data, so that would be an
-- invented legal requirement dressed as a fact. It says only what the rows can prove: no document is
-- linked, no location is recorded, no value is recorded, sharing is not configured.
--
-- ★ OWNER-ONLY, ENFORCED HERE RATHER THAN BY ROUTING. Readiness is derived from the COMPLETE estate:
-- it counts assets and documents without applying any disclosure tier, because the owner is the one
-- viewer entitled to all of it. That is exactly why a non-owner must never receive it — a readiness
-- list is a census of everything the estate holds, and would reconstruct precisely what
-- `get_estate_discovery` spent Phase 10-A withholding.
--
-- A membership, a professional-delegate role and an executor/trustee designation each confer
-- NOTHING here. 10-D owns the professional workspace and may define its own, differently-scoped
-- projection; it may not reuse this one.

create or replace function public.get_estate_readiness(p_estate uuid)
 returns jsonb
 language plpgsql
 stable
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid      uuid := auth.uid();
  v_findings jsonb;
begin
  -- ★ THE SAME REFUSAL SHAPE AS DISCOVERY, FOR THE SAME REASON. An error would distinguish "this
  -- estate exists but is not yours" from "no such estate"; a bare `authorized:false` does not.
  if v_uid is null then
    return jsonb_build_object('authorized', false);
  end if;
  if not public.is_estate_owner(p_estate) then
    return jsonb_build_object('authorized', false);
  end if;

  select coalesce(jsonb_agg(f order by f->>'sort_key'), '[]'::jsonb) into v_findings
  from (
    -- ── an asset with no supporting evidence ────────────────────────────────────────────────────
    -- The category rides along so the client can word it naturally ("no policy document is linked"
    -- for insurance) WITHOUT the server encoding a legal expectation about what each category
    -- requires. The FACT is identical in every category: nothing is attached.
    select jsonb_build_object(
             'kind',          'missing_evidence',
             'subject_kind',  'asset',
             'subject_id',    a.id,
             'subject_label', a.label,
             'category',      a.category,
             'category_label', c.display_name,
             'sort_key',      '1' || lpad(c.sort_order::text, 4, '0') || a.label
           ) as f
      from public.estate_assets a
      join public.estate_asset_category c on c.value = a.category
     where a.estate_id = p_estate
       -- ★ ARCHIVED ASSETS CONTRIBUTE NOTHING. The owner removed them from the inventory; reporting
       -- a gap on something they deliberately archived would be asking them to fix a record they
       -- have already retired.
       and a.archived_at is null
       and not exists (select 1 from public.estate_asset_documents l where l.asset_id = a.id)

    union all

    -- ── an asset with no location or custodian recorded ─────────────────────────────────────────
    -- A survivor's first question about an account is WHERE it is. This is provable and
    -- jurisdiction-neutral: it states that nothing was recorded, not that anything is required.
    select jsonb_build_object(
             'kind',          'missing_location',
             'subject_kind',  'asset',
             'subject_id',    a.id,
             'subject_label', a.label,
             'category',      a.category,
             'category_label', c.display_name,
             'sort_key',      '2' || lpad(c.sort_order::text, 4, '0') || a.label
           )
      from public.estate_assets a
      join public.estate_asset_category c on c.value = a.category
     where a.estate_id = p_estate
       and a.archived_at is null
       and coalesce(nullif(btrim(a.institution_name), ''), nullif(btrim(a.jurisdiction), ''),
                    nullif(btrim(a.country_code), '')) is null

    union all

    -- ── an asset with no approximate value recorded ─────────────────────────────────────────────
    -- ★ NULL IS THE FINDING, ZERO IS NOT. A recorded zero is a statement the owner made; a null is
    -- the absence of one. Treating them alike would nag an owner about a figure they already gave.
    select jsonb_build_object(
             'kind',          'missing_value',
             'subject_kind',  'asset',
             'subject_id',    a.id,
             'subject_label', a.label,
             'category',      a.category,
             'category_label', c.display_name,
             'sort_key',      '3' || lpad(c.sort_order::text, 4, '0') || a.label
           )
      from public.estate_assets a
      join public.estate_asset_category c on c.value = a.category
     where a.estate_id = p_estate
       and a.archived_at is null
       and a.approximate_value_cents is null

    union all

    -- ── a document whose sharing has never been configured ──────────────────────────────────────
    -- ★ FACTUAL, NOT PRESCRIPTIVE. `sealed` is the level at which `document_grantable` refuses every
    -- role, so "this document cannot currently be shared with anyone" is a property of the data, not
    -- an opinion about what the owner SHOULD do. There is an open product decision about default
    -- sensitivity; this reports the state and takes no position on it, changes nothing, and creates
    -- no grant.
    select jsonb_build_object(
             'kind',          'sharing_not_configured',
             'subject_kind',  'document',
             'subject_id',    d.id,
             'subject_label', d.title,
             'category',      null,
             'category_label', null,
             'sort_key',      '4' || d.title
           )
      from public.documents d
     where d.estate_id = p_estate
       and d.sensitivity = 'sealed'
  ) s;

  return jsonb_build_object(
    'authorized', true,
    'findings', v_findings,
    -- A plain count of the list the OWNER is already holding in full. It is not a score: it has no
    -- denominator, no weighting and no ceiling, and it cannot disclose anything, because every
    -- finding it counts is already in the same payload.
    'finding_count', jsonb_array_length(v_findings)
  );
end;
$function$;
revoke execute on function public.get_estate_readiness(uuid) from public, anon;
grant  execute on function public.get_estate_readiness(uuid) to authenticated;
