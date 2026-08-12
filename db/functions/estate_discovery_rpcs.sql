-- Estate-discovery RPCs — migration 0049 (Phase 10). Source of truth; re-apply on reset.
--
-- ★ THE WHOLE POINT: the client is never sent the estate and asked to hide things. These functions
-- decide, in the database, what one specific viewer may learn — and return only that.

-- ---------------------------------------------------------------------------------------------
-- create_asset_grant — widen the INLINE category list to admit `estate_inventory`
-- ---------------------------------------------------------------------------------------------
-- ★ A CHECK WIDENED WITHOUT THE DOOR WIDENED IS AN UNUSABLE CATEGORY. `create_asset_grant` carries
-- its own list as defence-in-depth ("the RPC is the security boundary and may be called directly"),
-- so migration 0049's constraint change alone would let the TABLE accept `estate_inventory` while the
-- only door that writes to it kept refusing. Both move together, and the authorization suite asserts
-- a grant can actually be created for the new category.
--
-- Only the list changes. The owner gate, the no-grants-to-owners rule, the write-time ceiling and the
-- unique-violation handling are untouched.
do $$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'create_asset_grant'
   limit 1;

  if v_src is null then
    raise exception 'create_asset_grant not found — apply migration 0008 first';
  end if;

  -- Idempotent: only rewrite when the new category is absent.
  if position('estate_inventory' in v_src) = 0 then
    v_src := replace(
      v_src,
      $old$('account_balances', 'institution_names', 'total_asset_value', 'linked_account_details')$old$,
      $new$('account_balances', 'institution_names', 'total_asset_value', 'linked_account_details', 'estate_inventory')$new$
    );
    if position('estate_inventory' in v_src) = 0 then
      -- ★ FAIL LOUDLY RATHER THAN SILENTLY NO-OP. If the literal ever changes shape, a quiet
      -- non-replacement would leave the category permanently ungrantable with everything green.
      raise exception 'could not widen create_asset_grant category list — the inline literal changed shape';
    end if;
    execute v_src;
  end if;
end $$;

-- ---------------------------------------------------------------------------------------------
-- estate_release_state(p_estate) -> text   — THE SEAM
-- ---------------------------------------------------------------------------------------------
-- Reports what the CLAIMS machinery already knows about this estate. It flips nothing and grants
-- nothing.
--
-- ★ IT DOES NOT ACTIVATE `after_verified_death_or_incapacity`. That condition stays default-deny
-- exactly as 0002 left it. This function exists so that Phase 11 ("Death Activation & Survivor Mode")
-- has ONE place to drive, instead of a release rule spreading across every read path — and so that
-- the survivor UI can honestly say "a claim is under review" today without any disclosure following
-- from it.
--
-- Values: 'active' (no claim), 'claim_submitted', 'claim_under_review', 'claim_approved',
--         'claim_rejected', 'released'.
create or replace function public.estate_release_state(p_estate uuid)
 returns text
 language sql
 stable
 security definer
 set search_path to 'public'
as $function$
  select coalesce(
    (select case c.status
              when 'submitted'    then 'claim_submitted'
              when 'under_review' then 'claim_under_review'
              when 'approved'     then 'claim_approved'
              when 'released'     then 'released'
              when 'rejected'     then 'claim_rejected'
            end
       from public.claim_packets c
      where c.estate_id = p_estate
      -- The one ACTIVE claim, if any; a rejected row is history and must not mask a later submission.
      order by (c.status <> 'rejected') desc, c.submitted_at desc
      limit 1),
    'active');
$function$;
revoke execute on function public.estate_release_state(uuid) from public, anon;
grant  execute on function public.estate_release_state(uuid) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- inventory_disclosure_tier(p_estate, p_uid) -> text   — the viewer's effective tier
-- ---------------------------------------------------------------------------------------------
-- ★ THE READ-TIME CEILING RE-CHECK IS AUTHORITATIVE, mirroring `list_estate_assets`. A grant created
-- before a ceiling tightening is clamped HERE, so tightening the policy takes effect immediately
-- rather than only for grants issued afterwards.
--
-- ★ RELEASE POLICY IS DECIDED BY THE CANONICAL PREDICATE, never by a local copy of it.
-- `public.release_condition_satisfied` under the `'standard'` policy accepts `immediately`, the two
-- approval-based conditions once approved, and — since Phase 11-D — `after_verified_death` exactly
-- while this estate's AUTHORITATIVE lifecycle is `death_verified` (resolved through
-- `estate_lifecycle_state`, the reader over the record whose only writer is the audited transition
-- routine). It is the identical rule the document path uses, because it is literally the same
-- function. Incapacity-conditioned and legacy fused grants disclose nothing under any lifecycle.
create or replace function public.inventory_disclosure_tier(p_estate uuid, p_uid uuid)
 returns text
 language plpgsql
 stable
 security definer
 set search_path to 'public'
as $function$
declare v_tier text; v_role text; v_cond text; v_approved timestamptz;
begin
  if p_uid is null then return 'hidden'; end if;
  if public.is_estate_owner(p_estate) then return 'full_detail'; end if;

  select g.visibility_tier, g.grantee_role, g.release_condition, g.approved_at
    into v_tier, v_role, v_cond, v_approved
    from public.access_grants g
   where g.estate_id = p_estate
     and g.grantee_user_id = p_uid
     and g.category = 'estate_inventory'
     and g.status = 'active'
   limit 1;

  if v_tier is null then return 'hidden'; end if;

  -- Release gate — the canonical predicate, which is what can_access_document calls too. Since
  -- 11-D it consumes THIS estate's authoritative lifecycle, resolved through the one sanctioned
  -- reader and passed as an ARGUMENT — never compared here: a death-conditioned inventory grant
  -- resolves its tier exactly while the estate is death_verified, and the ceiling clamp below
  -- still has the last word.
  if not public.release_condition_satisfied(v_cond, v_approved, 'standard',
                                            public.estate_lifecycle_state(p_estate)) then
    return 'hidden';
  end if;

  -- Read-time ceiling clamp (authoritative).
  if not public.asset_category_grantable(v_role, 'estate_inventory', v_tier) then
    return 'hidden';
  end if;

  return v_tier;
end;
$function$;
revoke execute on function public.inventory_disclosure_tier(uuid, uuid) from public, anon;
grant  execute on function public.inventory_disclosure_tier(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------------------------
-- get_estate_discovery(p_estate) -> jsonb   — THE PROJECTION
-- ---------------------------------------------------------------------------------------------
-- Returns ONLY what this viewer may presently discover.
--
-- Ladder, expressed with the EXISTING `visibility_tier` vocabulary:
--
--   hidden           → nothing. Not "categories: []" with a flag — the estate simply reports no
--                      inventory disclosure, because "there are categories you may not see" is a
--                      disclosure in itself.
--   range_only       → WHICH CATEGORIES EXIST. No counts, no labels, no institutions, no values.
--                      Existence is the disclosure.
--   category_summary → + item counts and a BRACKETED per-category total. Never an exact figure.
--   limited_detail   → + per-item labels and institution names. Still no exact value.
--   full_detail      → + exact values, reference hints and jurisdiction.
--
-- ★ ARCHIVED ASSETS ARE NEVER DISCLOSED TO A NON-OWNER. The owner removed them from the inventory;
-- surfacing them to a survivor would overstate the estate at the worst possible moment.
--
-- ★ NO UUID CROSSES THIS BOUNDARY BELOW `limited_detail`. Even at `limited_detail` the id returned is
-- the asset's own id within an estate the viewer is already authorized for — never a document id,
-- never an estate id belonging to anyone else.
create or replace function public.get_estate_discovery(p_estate uuid)
 returns jsonb
 language plpgsql
 stable
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid       uuid := auth.uid();
  v_tier      text;
  v_is_owner  boolean;
  v_member    boolean;
  v_categories jsonb;
  v_items      jsonb;
  v_docs       int;
begin
  -- ★ UNAUTHENTICATED GETS NOTHING, AND NOT AN ERROR EITHER. An error distinguishes "this estate
  -- exists" from "it does not"; an empty projection does not.
  if v_uid is null then
    return jsonb_build_object('authorized', false);
  end if;

  v_is_owner := public.is_estate_owner(p_estate);
  v_member   := public.is_estate_member(p_estate);

  -- ★ A GRANT ALONE IS ENOUGH — membership is not required. This mirrors the documents precedent: a
  -- grantee may hold a grant before or without an estate_memberships row, and refusing them here
  -- would make the grant unusable. Someone with neither gets the same empty answer as a stranger.
  v_tier := public.inventory_disclosure_tier(p_estate, v_uid);
  if not v_is_owner and not v_member and v_tier = 'hidden' then
    return jsonb_build_object('authorized', false);
  end if;

  -- Documents the viewer can actually reach, counted through the EXISTING document gate rather than
  -- a second rule invented here.
  select count(*) into v_docs
    from public.documents d
   where d.estate_id = p_estate
     and (v_is_owner or public.can_access_document(d.id));

  if v_tier = 'hidden' then
    -- Authorized to be here, but not to discover the inventory. Documents and release state are
    -- still honest answers, and the ABSENCE of a categories key says "not disclosed" without
    -- enumerating what is being withheld.
    return jsonb_build_object(
      'authorized', true,
      'is_owner', v_is_owner,
      'inventory_tier', 'hidden',
      'release_state', public.estate_release_state(p_estate),
      'document_count', v_docs
    );
  end if;

  -- ── categories ───────────────────────────────────────────────────────────────────────────────
  select coalesce(jsonb_agg(x order by x->>'sort_order'), '[]'::jsonb) into v_categories
  from (
    select jsonb_build_object(
             'category',     a.category,
             'display_name', c.display_name,
             'sort_order',   lpad(c.sort_order::text, 4, '0'),
             -- Counts begin at category_summary. At range_only the fact a category EXISTS is the
             -- entire disclosure.
             'item_count',   case when v_tier = 'range_only' then null else count(*) end,
             -- ★ EXACT TOTALS ONLY AT full_detail — AND THIS WAS A REAL LEAK.
             -- This read `v_tier in ('limited_detail','full_detail')`, so `limited_detail` withheld
             -- every per-item `value_cents` and then disclosed the exact CATEGORY TOTAL. For a
             -- category holding one asset the total IS that asset's withheld value, so the tier
             -- leaked precisely what it was suppressing one field away. Found by decoding a captured
             -- payload rather than by reading the code.
             --
             -- limited_detail now brackets, exactly as category_summary does: it adds labels and
             -- institutions over the tier below, and adds NO value precision.
             'total_cents',  case when v_tier = 'full_detail'
                                  then coalesce(sum(a.approximate_value_cents), 0) else null end,
             'range_low_cents',  case when v_tier in ('category_summary','limited_detail')
                                      then public.asset_bracket_low(coalesce(sum(a.approximate_value_cents), 0)::bigint) end,
             'range_high_cents', case when v_tier in ('category_summary','limited_detail')
                                      then public.asset_bracket_high(coalesce(sum(a.approximate_value_cents), 0)::bigint) end
           ) as x
      from public.estate_assets a
      join public.estate_asset_category c on c.value = a.category
     where a.estate_id = p_estate
       and a.archived_at is null
     group by a.category, c.display_name, c.sort_order
  ) s;

  -- ── items ────────────────────────────────────────────────────────────────────────────────────
  -- Nothing per-item below limited_detail.
  if v_tier in ('limited_detail','full_detail') then
    select coalesce(jsonb_agg(jsonb_build_object(
             'id',            a.id,
             'category',      a.category,
             'subtype',       a.subtype,
             'label',         a.label,
             'institution',   a.institution_name,
             'jurisdiction',  case when v_tier = 'full_detail' then a.jurisdiction end,
             'country_code',  case when v_tier = 'full_detail' then a.country_code end,
             -- ★ THE REFERENCE HINT IS full_detail ONLY. It is a fragment of an account identifier;
             -- a survivor who only needs to know an account EXISTS does not need its last four digits.
             'reference_hint', case when v_tier = 'full_detail' then a.reference_hint end,
             'value_cents',   case when v_tier = 'full_detail' then a.approximate_value_cents end,
             'currency',      a.currency,
             'verification_status', a.verification_status,
             'document_count', (select count(*) from public.estate_asset_documents l where l.asset_id = a.id)
           ) order by a.created_at desc), '[]'::jsonb) into v_items
      from public.estate_assets a
     where a.estate_id = p_estate
       and a.archived_at is null;
  else
    v_items := '[]'::jsonb;
  end if;

  return jsonb_build_object(
    'authorized', true,
    'is_owner', v_is_owner,
    'inventory_tier', v_tier,
    'release_state', public.estate_release_state(p_estate),
    'document_count', v_docs,
    'categories', v_categories,
    'items', v_items
  );
end;
$function$;
revoke execute on function public.get_estate_discovery(uuid) from public, anon;
grant  execute on function public.get_estate_discovery(uuid) to authenticated;
