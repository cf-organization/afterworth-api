-- Professional-delegate workspace RPC — Phase 10-D. Source of truth; re-apply on reset.
--
-- Answers ONE question, from the delegate's side: **what has the owner of this estate authorized me
-- to see and to do?**
--
-- ★ IT IS NOT READINESS, AND IT MAY NOT BECOME READINESS. `get_estate_readiness` is a census of
-- everything the estate holds, derived WITHOUT applying any disclosure tier, because the owner is the
-- one viewer entitled to all of it. Reusing it here — or reimplementing a "gaps" list from the same
-- tables — would hand a non-owner precisely the reconstruction Phase 10-A spent its whole budget
-- withholding. Nothing below reads an asset or a document except through a gate that already exists.
--
-- ★ IT IS NOT AN OWNER DASHBOARD, AND THE OWNER IS REFUSED. The question this answers is meaningless
-- asked of oneself, and admitting the owner would make "documents shared with me" mean "every
-- document" and "the inventory I was granted" mean "all of it" — two sentences that are true for an
-- owner and false as descriptions of a delegation. The owner already has `get_estate_readiness` and a
-- full-detail `get_estate_discovery`.
--
-- ── AUTHORITY ───────────────────────────────────────────────────────────────────────────────────
--
-- ★ THE GATE IS AN APPROVED `professional_delegate` MEMBERSHIP, READ FROM THE MEMBERSHIP TABLE.
-- It is never inferred from a capability combination, never from the presence of a grant, and never
-- from a fiduciary designation. That direction of inference is what produced the `personaSummary`
-- defect on the client, where an all-false capability set was labelled "Professional delegate"
-- because owner and beneficiary had positive predicates and this role had none.
--
-- ★ A FIDUCIARY DESIGNATION DOES NOT OPEN THIS DOOR, AND MEMBERSHIP DOES NOT CONFER A CAPACITY.
-- An executor who holds no professional-delegate membership is REFUSED here — their surface is the
-- claim path, gated by `is_estate_executor`. A professional delegate who holds no designation
-- receives an EMPTY capacity list, not an absent key, because "we checked and there are none" and
-- "we did not check" are different answers and only one of them is true.
--
-- ★ EVERY DISCLOSURE IS DELEGATED TO THE GATE THAT ALREADY OWNS IT.
--   inventory  → `get_estate_discovery`, unchanged, called as this same caller
--   documents  → `can_access_document`, per document, unchanged
-- Re-deriving either here would create a SECOND disclosure authority, and the first time the two
-- disagreed the more permissive one would be a leak. This function composes; it does not decide.
--
-- ★ NO HIDDEN COUNT CROSSES THIS BOUNDARY. There is no total-minus-visible anywhere, no "documents
-- you cannot see", no count of categories withheld, no denominator. A delegate learns the SIZE of
-- what is being kept from them from exactly one place — a subtraction someone left in a payload — so
-- there is nothing here to subtract from.
--
-- ★ OWNER-DEPENDENCY IS REPORTED AS THE DELEGATE'S OWN STATE, NEVER AS THE ESTATE'S SHAPE.
-- `access_request_state` is the state of a request THIS caller made. It says "you asked and are
-- waiting" — a fact they already hold — and never "3 documents are locked", which would disclose
-- both that documents exist and how many.

create or replace function public.get_professional_workspace(p_estate uuid)
 returns jsonb
 language plpgsql
 stable
 security definer
 set search_path to 'public'
as $function$
declare
  v_uid        uuid := auth.uid();
  v_role       text;
  v_status     text;
  v_name       text;
  v_capacities jsonb;
  v_discovery  jsonb;
  v_docs       jsonb;
  v_doc_count  int;
  v_req_state  text;
  v_req_at     timestamptz;
  v_result     jsonb;
begin
  -- ★ ONE REFUSAL SHAPE, EMITTED BEFORE ANYTHING IS READ. Unauthenticated, non-member, beneficiary,
  -- owner, executor-without-delegation, revoked delegate, cross-estate and no-such-estate must all
  -- produce the IDENTICAL bytes. An error, a differing key set, or a `capacities: []` on one branch
  -- and not another would each turn this into an oracle for "does that estate exist / am I known
  -- there", which is exactly what the discovery refusal was designed to avoid.
  if v_uid is null then
    return jsonb_build_object('authorized', false);
  end if;

  select m.role, m.status
    into v_role, v_status
    from public.estate_memberships m
   where m.estate_id = p_estate
     and m.user_id = v_uid
     -- ★ THE ROLE IS PART OF THE LOOKUP, NOT A POST-FILTER. `estate_memberships` carries no
     -- (estate, user) uniqueness, so a user may hold several rows; selecting on status alone and
     -- checking the role afterwards could pick a beneficiary row and refuse someone who also holds
     -- a professional-delegate one. `list_estate_members` documents the same hazard.
     and m.role = 'professional_delegate'
     and m.status = 'approved'
   limit 1;

  if v_role is null then
    return jsonb_build_object('authorized', false);
  end if;

  -- ★ AND AN OWNER IS REFUSED EVEN IF SOMEONE MANAGES TO HOLD BOTH ROWS. `is_ownership_role` is the
  -- canonical predicate; this is defence in depth against a data state the invariants forbid, and it
  -- costs one boolean. A workspace that quietly served an owner would report "shared with you" over
  -- data nobody shared.
  if public.is_estate_owner(p_estate) then
    return jsonb_build_object('authorized', false);
  end if;

  -- ★ THE COLUMN IS `name`. A first draft wrote `display_name` because that is the spelling the
  -- WIRE uses (`estateDisplayName` in `resolve_membership`), and the two are deliberately different:
  -- the wire name is a presentation contract, the column is storage. Guessing one from the other is
  -- the same class of error as `is_estate_owner` vs the contract's `is_owner` key, which made an
  -- earlier fixture script report every estate as unowned.
  select e.name into v_name from public.estates e where e.id = p_estate;

  -- ── capacity ─────────────────────────────────────────────────────────────────────────────────
  -- ★ FROM DESIGNATIONS ONLY, AND ALWAYS PRESENT. An empty array is the honest answer to "what
  -- capacities do you hold" when the answer is none; omitting the key would make "none" and
  -- "not evaluated" indistinguishable to every client that reads it.
  select coalesce(jsonb_agg(d.designation_type order by d.designation_type), '[]'::jsonb)
    into v_capacities
    from public.estate_designations d
   where d.estate_id = p_estate
     and d.user_id = v_uid
     and d.designation_type in ('executor', 'trustee')
     and d.status = 'active';

  -- ── what the owner released: inventory ───────────────────────────────────────────────────────
  -- Delegated wholesale. Whatever `get_estate_discovery` decides this caller may see is what appears
  -- here, verbatim — including its decision to disclose nothing.
  v_discovery := public.get_estate_discovery(p_estate);

  -- ── what the owner released: documents ───────────────────────────────────────────────────────
  -- ★ THE FILTER IS THE PRODUCT'S OWN DOCUMENT GATE. A document the delegate cannot access is not
  -- counted, not summarised and not alluded to — it is simply not in the result, which is the only
  -- treatment that leaks nothing.
  select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'title', d.title) order by d.title), '[]'::jsonb),
         count(*)::int
    into v_docs, v_doc_count
    from public.documents d
   where d.estate_id = p_estate
     and public.can_access_document(d.id);

  -- ── what this delegate is waiting on ─────────────────────────────────────────────────────────
  -- ★ THEIR OWN REQUEST, AND NOTHING ELSE. This is a fact the caller supplied; returning it to them
  -- discloses nothing new. There is deliberately no view of anyone else's request, no count of
  -- outstanding requests on the estate, and no statement about what approving one would reveal.
  select r.status, r.created_at
    into v_req_state, v_req_at
    from public.access_requests r
   where r.estate_id = p_estate
     and r.requester_user_id = v_uid
     and r.category = 'estate_documents'
   order by r.created_at desc
   limit 1;

  v_result := jsonb_build_object(
    'authorized',           true,
    'estate_display_name',  v_name,
    -- The relationship, from the membership row that authorized this call. Not a capability
    -- combination, not a label, not a guess.
    'relationship',         v_role,
    'capacities',           v_capacities,
    'document_count',       v_doc_count,
    'documents',            v_docs,
    -- ★ 'none' IS A REAL STATE, NOT A NULL. It means "you have not asked", which the caller can
    -- already see, and it lets the client offer the action without a second round trip.
    'access_request_state', coalesce(v_req_state, 'none'),
    'access_request_at',    v_req_at,
    -- ★ THE ACTION IS OFFERED ONLY WHEN THE SERVER WOULD ACTUALLY HONOUR IT. `create_access_request`
    -- rejects a duplicate pending request with a 409; advertising the action anyway would produce a
    -- CTA whose only outcome is an error, which is worse than no CTA.
    'can_request_document_access', coalesce(v_req_state, 'none') <> 'pending'
  );

  -- ★ INVENTORY IS ADDED ONLY WHEN SOMETHING WAS RELEASED, AND ITS ABSENCE IS THE DISCLOSURE
  -- DECISION ITSELF. Emitting `inventory: null` or `inventory: {categories: []}` would tell the
  -- delegate that an inventory exists and is being withheld — the same distinction
  -- `get_estate_discovery` preserves by omitting `categories` rather than sending an empty array.
  if (v_discovery->>'authorized') = 'true' and (v_discovery->'categories') is not null then
    v_result := v_result || jsonb_build_object(
      'inventory', jsonb_build_object(
        'tier',       v_discovery->>'inventory_tier',
        'categories', v_discovery->'categories',
        'items',      coalesce(v_discovery->'items', '[]'::jsonb)
      )
    );
  end if;

  return v_result;
end;
$function$;

revoke execute on function public.get_professional_workspace(uuid) from public, anon;
grant  execute on function public.get_professional_workspace(uuid) to authenticated;

comment on function public.get_professional_workspace(uuid) is
  'Phase 10-D. The professional delegate''s view of ONE estate: their relationship, any fiduciary '
  'capacity, what the owner released to them (delegated to get_estate_discovery and '
  'can_access_document), and the state of their own access request. Gated on an APPROVED '
  'professional_delegate membership — never on a capability combination, a grant, or a designation. '
  'The owner is refused. Carries no readiness, no score, and no count of anything withheld.';
