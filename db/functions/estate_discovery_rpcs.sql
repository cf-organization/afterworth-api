-- ★ 0066 (2026-11-19): get_estate_discovery BODY MIRRORED FROM
-- db/migrations/0066_20261119_beneficiary_connector_disclosure.sql — connector keys added
-- (connected_categories / connected_institutions / connected_total), inventory semantics unchanged.
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
-- ★ LOCKED HELPER (Phase 11-I hotfix). This is SECURITY DEFINER, takes an arbitrary estate id, and
-- its body contains NO authorization gate — it is a bare read of `claim_packets` filtered only by
-- `estate_id`. While it was granted to `authenticated`, any signed-in user could pass any estate id
-- and learn that estate's claim/release state (`claim_submitted`, `under_review`, `claim_approved`,
-- `released`, `claim_rejected`) for an estate they have no relationship to.
--
-- ★ THE FIX IS A REVOKE, NOT A GATE, AND THAT IS DERIVED RATHER THAN PREFERRED. Adding
-- `is_estate_owner()` would be wrong: the sole production caller is `get_estate_discovery`, which is
-- SECURITY DEFINER and serves NON-owner disclosure paths (beneficiaries, professional delegates), so
-- an ownership gate would break exactly the readers this helper exists for. No client calls it
-- directly — the mobile app has no production reference — so the direct client contract is dead
-- surface, and removing it costs nothing.
--
-- Same posture as `estate_lifecycle_state` and `required_verification_level`: privileged internal
-- helpers, reachable only through a DEFINER routine that has already authorized the caller.
revoke execute on function public.estate_release_state(uuid) from public, anon, authenticated;

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
  v_uid        uuid := auth.uid();
  v_tier       text;
  v_is_owner   boolean;
  v_member     boolean;
  v_categories jsonb;
  v_items      jsonb;
  v_docs       int;
  v_bal        text;
  v_inst       text;
  v_det        text;
  v_tot_gate   text;
  v_aal2       boolean;
  v_exact      boolean;
  v_det_shows  boolean;
  v_groups     jsonb := null;
  v_conn       jsonb := null;
  v_total      jsonb := null;
begin
  if v_uid is null then
    return jsonb_build_object('authorized', false);
  end if;

  v_is_owner := public.is_estate_owner(p_estate);
  v_member   := public.is_estate_member(p_estate);
  v_tier     := public.inventory_disclosure_tier(p_estate, v_uid);

  -- ── connector tiers, resolved for THIS estate only ─────────────────────────────────────────────
  if v_is_owner then
    v_bal := 'full_detail'; v_inst := 'full_detail'; v_det := 'full_detail'; v_tot_gate := 'full_detail';
  else
    -- ★ THE SAME EFFECTIVE TIER THE TOTAL READER USES (exact degrades to the bracket without aal2).
    v_bal      := public.effective_balance_tier(p_estate, v_uid);
    v_inst     := public.connector_disclosure_tier(p_estate, v_uid, 'institution_names');
    v_det      := public.connector_disclosure_tier(p_estate, v_uid, 'linked_account_details');
    v_tot_gate := public.connector_disclosure_tier(p_estate, v_uid, 'total_asset_value');  -- gate only
  end if;
  -- ★ ACCOUNT DETAILS DISCLOSE AT limited_detail / full_detail ONLY — the threshold list_estate_assets uses.
  v_det_shows := v_det in ('limited_detail', 'full_detail');

  -- ★ aal2 satisfies an authentication requirement; it never creates a grant. The owner's exact view
  --   degrades to the category bracket without a current aal2 session — it never raises.
  v_aal2 := public.aal2_is_current();
  if v_is_owner and not v_aal2 then
    v_bal := 'category_summary';
  end if;
  v_exact := v_bal in ('limited_detail', 'full_detail');

  -- ★ THE GATE: a grant on THIS estate alone is sufficient; nothing elsewhere is.
  if not v_is_owner and not v_member and v_tier = 'hidden'
     and v_bal = 'hidden' and v_inst = 'hidden' and not v_det_shows and v_tot_gate = 'hidden' then
    return jsonb_build_object('authorized', false);
  end if;

  -- ── connected categories (the ONLY place a non-owner sees a connector amount) ───────────────────
  if v_bal <> 'hidden' then
    select coalesce(jsonb_agg(jsonb_build_object(
             'asset_group',      g.asset_group,
             'total_cents',      case when v_exact then g.sum_cents end,
             'range_low_cents',  case when v_bal = 'category_summary'
                                      then public.asset_bracket_low(g.sum_cents) end,
             'range_high_cents', case when v_bal = 'category_summary'
                                      then public.asset_bracket_high(g.sum_cents) end
           ) order by g.asset_group), '[]'::jsonb) into v_groups
      from (select n.asset_group, coalesce(sum(n.balance_cents), 0)::bigint as sum_cents
              from public.normalized_assets n
             where n.estate_id = p_estate
             group by n.asset_group) g;
  end if;

  -- ── connected institutions (rows exist only because a descriptive grant or an exact tier says so)
  if v_exact or v_inst <> 'hidden' or v_det_shows then
    select coalesce(jsonb_agg(jsonb_build_object(
             'id',                n.id,
             'asset_group',       n.asset_group,
             'currency',          n.currency,
             'last_sync_status',  n.last_sync_status,
             'institution',       case when v_inst <> 'hidden' then n.institution_name end,
             'masked_identifier', case when v_det_shows then n.masked_identifier end,
             'balance_cents',     case when v_exact then n.balance_cents end,
             -- ★ COMPATIBILITY KEYS, ALWAYS NULL. The pilot client installed before this migration
             --   REQUIRES these two keys on a row (its decoder refuses the whole payload without them)
             --   and renders nothing for a null. They carry no figure and will be dropped once that
             --   client is retired.
             'range_low_cents',   null,
             'range_high_cents',  null
           ) order by n.institution_name nulls last, n.id), '[]'::jsonb) into v_conn
      from public.normalized_assets n
     where n.estate_id = p_estate;
  end if;

  -- ── estate total — the reader's row, verbatim; its suppression rule is its own ─────────────────
  begin
    select jsonb_build_object(
             'total_cents',             w.total_cents,
             'range_low_cents',         w.range_low_cents,
             'range_high_cents',        w.range_high_cents,
             'resolved_tier',           w.resolved_tier,
             'currency',                w.currency,
             'suppressed_by_breakdown', w.suppressed_by_breakdown
           ) into v_total
      from public.get_estate_net_worth(p_estate) w
     limit 1;
  exception
    when insufficient_privilege then   -- the reader's aal2 refusal, and ONLY that
      v_total := null;
  end;

  select count(*) into v_docs
    from public.documents d
   where d.estate_id = p_estate
     and (v_is_owner or public.can_access_document(d.id));

  if v_tier = 'hidden' then
    -- ★ ABSENT, NOT NULL, for an undisclosed connector key — appended conditionally, never by
    --   stripping nulls globally, which would also erase the nested nulls the client relies on.
    return jsonb_build_object(
      'authorized', true,
      'is_owner', v_is_owner,
      'inventory_tier', 'hidden',
      'release_state', public.estate_release_state(p_estate),
      'document_count', v_docs,
      'connected_total', v_total
    )
    || case when v_groups is null then '{}'::jsonb else jsonb_build_object('connected_categories', v_groups) end
    || case when v_conn   is null then '{}'::jsonb else jsonb_build_object('connected_institutions', v_conn) end;
  end if;

  -- ── inventory categories (UNCHANGED from 0049) ─────────────────────────────────────────────────
  select coalesce(jsonb_agg(x order by x->>'sort_order'), '[]'::jsonb) into v_categories
  from (
    select jsonb_build_object(
             'category',     a.category,
             'display_name', c.display_name,
             'sort_order',   lpad(c.sort_order::text, 4, '0'),
             'item_count',   case when v_tier = 'range_only' then null else count(*) end,
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

  -- ── inventory items (UNCHANGED from 0049) ──────────────────────────────────────────────────────
  if v_tier in ('limited_detail','full_detail') then
    select coalesce(jsonb_agg(jsonb_build_object(
             'id',            a.id,
             'category',      a.category,
             'subtype',       a.subtype,
             'label',         a.label,
             'institution',   a.institution_name,
             'jurisdiction',  case when v_tier = 'full_detail' then a.jurisdiction end,
             'country_code',  case when v_tier = 'full_detail' then a.country_code end,
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

  -- ★ ABSENT, NOT NULL, for an undisclosed connector key — appended conditionally, never by
  --   stripping nulls globally, which would also erase the nested nulls the client relies on.
  return jsonb_build_object(
    'authorized', true,
    'is_owner', v_is_owner,
    'inventory_tier', v_tier,
    'release_state', public.estate_release_state(p_estate),
    'document_count', v_docs,
    'categories', v_categories,
    'items', v_items,
    'connected_total', v_total
  )
  || case when v_groups is null then '{}'::jsonb else jsonb_build_object('connected_categories', v_groups) end
  || case when v_conn   is null then '{}'::jsonb else jsonb_build_object('connected_institutions', v_conn) end;
end;
$function$;
revoke execute on function public.get_estate_discovery(uuid) from public, anon;
grant  execute on function public.get_estate_discovery(uuid) to authenticated;
