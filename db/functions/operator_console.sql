-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- PHASE 11-K · OPERATOR PROJECTIONS — the two READ doors that make nine deployed WRITE doors usable
-- ════════════════════════════════════════════════════════════════════════════════════════════════
--
-- ★ WHY THIS FILE EXISTS AT ALL. Phase 11 deployed nine admin-gated write routines and not one way
-- to see what they act on. `death_verification_cases`, `death_verification_evidence` and
-- `estate_lifecycle` were created with ZERO grants and ZERO policies (0052 asserts exactly that),
-- and no `admin_list_*`/`admin_get_*` routine was ever written for them. The consequence is sharper
-- than "unbound": an operator holding a valid AAL2 admin JWT can DECIDE a case, but has no way to
-- learn a case id, so there is nothing they can name. The lifecycle was unreachable by anyone.
--
-- ★ NOTHING HERE CREATES AUTHORITY. Both routines are STABLE reads behind the same
-- `admin_require_gate()` every other admin door uses — auth → is_admin → AAL2 → 15-minute freshness,
-- INSIDE the definer (the DEFINER-door discipline: a direct PostgREST caller hits the identical
-- checks, and the console buys no privilege the raw door does not already give). No lifecycle
-- moves, no level changes, no case is decided, no notice dispatches, no window opens, nothing
-- releases. Every one of those remains the deployed routine's own decision.
--
-- ★ AND THIS IS NOT AN ADMIN ESTATE DUMP. Administrative workflow authority and estate-content
-- disclosure are separate axes, and least disclosure applies to operators too. These projections
-- answer about the VERIFICATION WORKFLOW and carry, in neither routine:
--
--     no asset, no valuation, no net worth        no beneficiary, no membership roster
--     no designation list                          no access grant, no visibility tier
--     no document bytes, no storage path           no signed URL
--     no encrypted instruction                     NO OWNER EMAIL ADDRESS
--
-- The full field-by-field justification, with sensitivity and retention, is
-- `docs/phase11k-disclosure-census.md`. `test/operatorProjectionDisclosure.test.ts` pins the
-- absences against this source text with positive controls, so a future edit that adds one of them
-- fails rather than ships.
--
-- Source of truth — re-apply on DB reset. Deploys with `db/bundles/operator_console_bundle.sql`,
-- after migration 0056.

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- admin_list_death_verification_cases(...) → table                            [admin, AAL2+fresh]
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- THE OPERATOR QUEUE. What an operator needs to triage a list of cases, and nothing else.
--
-- ★ NO OWNER EMAIL, AND `owner_channel_resolvable` INSTEAD. The operator's workflow question is
-- "will dispatch succeed for this estate", not "what is this living person's address". The boolean
-- answers the first exactly and the second not at all — and `dispatch_owner_safety_notice` resolves
-- the real address itself, from `auth.users`, where no claimant can repoint it. An operator never
-- needs to see it, so this projection never has it to leak. A console that displayed the address
-- "for confirmation" would be a permanent, searchable copy of a living owner's contact detail in a
-- surface whose whole premise is that this person may be the victim of a false claim.
--
-- ★ THE REQUIRED LEVEL IS RE-DERIVED LIVE, matching `admin_decide_death_verification_case` exactly.
-- `required_level_at_initiation` is a record of what policy said when the case opened; showing THAT
-- as the bar would mislead whenever policy tightened mid-case — and the decision routine would then
-- refuse a `verify` the console had just shown as permitted. The console must not be able to
-- disagree with the door.
--
-- ★ INITIATOR IDENTITY IS WITHHELD HERE and disclosed only in the case file, where adjudicating a
-- specific claim actually requires it. A queue needs to know a case exists; it does not need to
-- name the person who opened it.
create or replace function public.admin_list_death_verification_cases(
  p_status           text        default null,
  p_before_initiated timestamptz default null,
  p_before_id        uuid        default null,
  p_limit            int         default 50
)
 returns table(
   case_id                  uuid,
   estate_id                uuid,
   estate_name              text,
   case_status              text,
   lifecycle_state          text,
   event_type               text,
   initiated_at             timestamptz,
   updated_at               timestamptz,
   initiator_capacity       text,
   jurisdiction_context     text,
   required_level           text,
   attained_level           text,
   evidence_total           int,
   evidence_awaiting_review int,
   owner_channel_resolvable boolean,
   decided_at               timestamptz
 )
 language plpgsql
 security definer
 stable
 set search_path to 'public'
as $function$
declare v_limit int;
begin
  perform public.admin_require_gate();
  -- The admin_list_claim_packets_enriched clamp, verbatim: a caller cannot ask for the whole table.
  v_limit := least(greatest(coalesce(p_limit, 50), 1), 200);

  return query
    select
      c.id,
      c.estate_id,
      e.name,
      c.status,
      -- An estate with no lifecycle row has never entered the machine; `active` is the same default
      -- `apply_estate_lifecycle_transition` and `estate_lifecycle_state` both use.
      coalesce(l.state, 'active'),
      c.event_type,
      c.created_at,
      c.updated_at,
      c.initiator_capacity,
      c.jurisdiction_context,
      public.required_verification_level(c.estate_id)::text,
      c.attained_level::text,
      coalesce(ev.total, 0)::int,
      coalesce(ev.awaiting, 0)::int,
      exists (
        select 1 from auth.users u
         where u.id = public.estate_owner_user_id(c.estate_id)
           and btrim(coalesce(u.email, '')) <> ''
      ),
      c.decided_at
    from public.death_verification_cases c
    left join public.estates e on e.id = c.estate_id
    left join public.estate_lifecycle l on l.estate_id = c.estate_id
    left join lateral (
      -- ★ A LATERAL AGGREGATE, NOT A JOINED GROUP BY. The 11-F census learned this the expensive
      -- way: a per-status GROUP BY joined laterally onto the row set multiplies rows, and the
      -- headline number silently triples. Scoped to `x.case_id = c.id`, this returns one row.
      select count(*)::int as total,
             count(*) filter (where x.review_status = 'received')::int as awaiting
        from public.death_verification_evidence x
       where x.case_id = c.id
    ) ev on true
   where (p_status is null or c.status = p_status)
     and (p_before_initiated is null
          or (c.created_at, c.id) < (p_before_initiated, coalesce(p_before_id, c.id)))
   order by c.created_at desc, c.id desc
   limit v_limit;
end $function$;
revoke execute on function public.admin_list_death_verification_cases(text, timestamptz, uuid, int)
  from public, anon;
grant  execute on function public.admin_list_death_verification_cases(text, timestamptz, uuid, int)
  to authenticated;

comment on function public.admin_list_death_verification_cases(text, timestamptz, uuid, int) is
  'The operator queue for death-verification cases (Phase 11-K). Workflow facts only: case status, '
  'lifecycle state, LIVE required level vs attained, evidence counts, and whether the owner channel '
  'RESOLVES — never the owner address. No asset, valuation, beneficiary, designation, grant, '
  'document byte or storage path. Admin-gated inside the definer; keyset paged; clamped to 200.';

-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- admin_get_death_verification_case(p_case) → jsonb                           [admin, AAL2+fresh]
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- THE CASE FILE. Everything the six lifecycle decisions actually turn on, assembled in ONE call so
-- the console cannot compose a wider view out of several narrow ones — and so there is a single
-- place to audit what an operator may see.
--
-- ★ `viewer_is_reviewer_a` IS DERIVED FROM auth.uid() INSIDE THIS DEFINER. That is the whole reason
-- it lives here rather than in the client. The console must be able to state that the signed-in
-- operator is ineligible to authorize this release; a client that computed it by comparing two
-- values it was handed could be made to compute it wrongly, and the failure would be silent and in
-- the operator's favour. The server answers it, the client renders it, and `authorize_release`
-- re-derives reviewer_a and re-checks distinctness independently regardless. This field makes the
-- affordance TRUTHFUL; it grants nothing. UI affordance is not permission.
--
-- ★ WINDOW FACTS ARE FACTS, NOT A COUNTDOWN. `release_eligible_at` and `elapsed` are what an
-- operator needs in order to know whether a release call will be refused. The duration is read LIVE
-- through `challenge_window_duration()`, the same way `authorize_release` reads it, so the console
-- cannot display a deadline the routine disagrees with. `elapsed` uses STRICT `>` for the same
-- reason the routine does: at the exact boundary instant release refuses and the owner's challenge
-- still succeeds, and a console that rounded the other way would offer an action that is refused.
-- Nothing here ranks, scores, urges, estimates, or performs urgency.
--
-- ★ DECISION AND REVIEW NOTES ARE INCLUDED, AS A WORKFLOW REQUIREMENT RATHER THAN A CONVENIENCE.
-- The second reviewer must form an independent judgement about what the FIRST reviewer concluded; a
-- two-person rule where reviewer B cannot read reviewer A's reasoning is a rubber stamp with extra
-- steps. These are operator-authored notes about a case, never estate content.
--
-- ★ REFUSAL SHAPE DIFFERS FROM THE CLIENT DOORS, DELIBERATELY. The client routines answer one
-- sentinel for missing-and-foreign alike, because case existence is itself protected from a probing
-- claimant (T9). An authenticated platform admin behind AAL2 + freshness is authorized to know that
-- a case does not exist — the same latitude `admin_review_death_evidence` already takes with
-- `evidence_not_found`. Copying the client's indistinguishability here would hide operator typos,
-- not protect anyone.
create or replace function public.admin_get_death_verification_case(p_case uuid)
 returns jsonb
 language plpgsql
 security definer
 stable
 set search_path to 'public'
as $function$
declare
  v_uid      uuid;
  v_c        public.death_verification_cases%rowtype;
  v_l        public.estate_lifecycle%rowtype;
  v_duration interval;
  v_out      jsonb;
begin
  perform public.admin_require_gate();
  v_uid := auth.uid();

  select * into v_c from public.death_verification_cases c where c.id = p_case;
  if not found then
    raise exception 'case_not_found' using errcode = 'P0002';
  end if;

  select * into v_l from public.estate_lifecycle l where l.estate_id = v_c.estate_id;
  v_duration := public.challenge_window_duration();

  select jsonb_build_object(
    'case', jsonb_build_object(
      'case_id',              v_c.id,
      'estate_id',            v_c.estate_id,
      'estate_name',          (select e.name from public.estates e where e.id = v_c.estate_id),
      'status',               v_c.status,
      'event_type',           v_c.event_type,
      'initiated_at',         v_c.created_at,
      'updated_at',           v_c.updated_at,
      'initiator_capacity',   v_c.initiator_capacity,
      'jurisdiction_context', v_c.jurisdiction_context,
      -- BOTH levels, both labelled. The live value is the bar the decision routine will apply; the
      -- snapshot is the case file's record of what policy said at initiation. Showing only one of
      -- them is how a console and a decision routine come to disagree in front of an operator.
      'required_level_at_initiation', v_c.required_level_at_initiation::text,
      'required_level_live',  public.required_verification_level(v_c.estate_id)::text,
      'attained_level',       v_c.attained_level::text,
      'decided_at',           v_c.decided_at,
      'decision_note',        v_c.decision_note
    ),
    -- Initiator identity: disclosed HERE and not in the queue, because adjudicating THIS case is
    -- the workflow that needs it — an operator judging whether a claimed fiduciary is legitimate.
    'initiator', jsonb_build_object(
      'user_id',  v_c.initiated_by,
      'email',    (select p.email     from public.profiles p where p.id = v_c.initiated_by),
      'name',     (select p.full_name from public.profiles p where p.id = v_c.initiated_by),
      'capacity', v_c.initiator_capacity
    ),
    'lifecycle', jsonb_build_object(
      'state',                       coalesce(v_l.state, 'active'),
      'owner_notified_at',           v_l.owner_notified_at,
      'challenge_window_started_at', v_l.challenge_window_started_at,
      'halted_at',                   v_l.halted_at,
      'released_at',                 v_l.released_at,
      'updated_at',                  v_l.updated_at
    ),
    'window', jsonb_build_object(
      'duration',            v_duration::text,
      -- NULL duration means NOT CONFIGURED, which means the window never elapses and release
      -- refuses. The console must be able to say that, rather than render a blank date.
      'configured',          v_duration is not null,
      'release_eligible_at', case when v_l.owner_notified_at is not null and v_duration is not null
                                  then v_l.owner_notified_at + v_duration end,
      'elapsed',             coalesce(now() > v_l.owner_notified_at + v_duration, false)
    ),
    'owner_notice', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id',            o.id,
               'channel',       o.channel,
               'notice_kind',   o.notice_kind,
               'status',        o.status,
               'requested_at',  o.requested_at,
               'dispatched_at', o.dispatched_at,
               'attempts',      o.attempts,
               'failure_class', o.failure_class
               -- `recipient` is NOT selected, here or anywhere in this file. An operator's workflow
               -- never requires a living owner's address, and a projection that never carries it
               -- cannot leak it through a log, a screenshot, or a future console feature.
             ) order by o.requested_at desc)
        from public.owner_notice_outbox o
       where o.estate_id = v_c.estate_id
    ), '[]'::jsonb),
    'evidence', coalesce((
      select jsonb_agg(jsonb_build_object(
               'evidence_id',   x.id,
               'document_id',   x.document_id,
               'title',         d.title,
               'doc_type',      d.doc_type,
               'uploaded_at',   d.created_at,
               'submitted_at',  x.submitted_at,
               'review_status', x.review_status,
               'reviewed_at',   x.reviewed_at,
               'review_note',   x.review_note
               -- No storage_path, no bytes, no signed URL. Evidence BYTES have their own separately
               -- gated door (the admin_authorize_claim_evidence pattern); metadata is what a review
               -- queue needs, and the two must not be conflated into one projection.
             ) order by x.submitted_at)
        from public.death_verification_evidence x
        left join public.documents d on d.id = x.document_id
       where x.case_id = v_c.id
    ), '[]'::jsonb),
    'release', jsonb_build_object(
      -- reviewer_a is the case DECIDER, derived exactly as authorize_release derives it. NULL until
      -- the case is decided — there is no first reviewer before there is a decision.
      'reviewer_a',           v_c.decided_by,
      'viewer_is_reviewer_a', v_c.decided_by is not null and v_c.decided_by = v_uid,
      'authorized', (
        select jsonb_build_object('authorized_at', ra.authorized_at,
                                  'reviewer_a',    ra.reviewer_a,
                                  'reviewer_b',    ra.reviewer_b,
                                  'audit_reason',  ra.audit_reason)
          from public.release_authorizations ra
         where ra.estate_id = v_c.estate_id
         order by ra.authorized_at desc
         limit 1
      )
    )
  ) into v_out;

  return v_out;
end $function$;
revoke execute on function public.admin_get_death_verification_case(uuid) from public, anon;
grant  execute on function public.admin_get_death_verification_case(uuid) to authenticated;

comment on function public.admin_get_death_verification_case(uuid) is
  'The operator case file (Phase 11-K): case facts, initiator identity, lifecycle timestamps, LIVE '
  'window facts, owner-notice dispatch status (NEVER the recipient address) and evidence METADATA. '
  'viewer_is_reviewer_a is derived from auth.uid() INSIDE this definer so the console can state '
  'release ineligibility truthfully — it grants nothing; authorize_release re-checks independently. '
  'Carries no asset, valuation, beneficiary, designation, grant, document byte or storage path.';
