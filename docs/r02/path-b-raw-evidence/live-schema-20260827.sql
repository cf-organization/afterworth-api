


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE TYPE "public"."verification_level" AS ENUM (
    'attestation',
    'kyc',
    'enhanced_kyc'
);


ALTER TYPE "public"."verification_level" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."accept_invitation"("p_invitation_id" "uuid") RETURNS TABLE("membership_id" "uuid", "estate_id" "uuid", "estate_display_name" "text", "role" "text", "status" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_user uuid := auth.uid();
  v_inv record; v_user_email text; v_user_phone text; v_membership_id uuid;
begin
  if v_user is null then raise exception 'unauthenticated' using errcode = '42501'; end if;
  select * into v_inv from public.invitations where id = p_invitation_id for update;
  if not found then raise exception 'invitation_not_found' using errcode = 'P0002'; end if;
  if v_inv.expires_at < now() then raise exception 'invitation_expired' using errcode = 'P0003'; end if;
  if v_inv.status = 'revoked' then raise exception 'invitation_revoked' using errcode = 'P0004'; end if;
  if v_inv.status = 'declined' then raise exception 'invitation_declined' using errcode = 'P0007'; end if;

  select profiles.email, profiles.phone into v_user_email, v_user_phone from public.profiles where profiles.id = v_user;
  if not ((v_inv.invitee_email is not null and lower(v_inv.invitee_email) = lower(coalesce(v_user_email,'')))
       or (v_inv.invitee_phone is not null and v_inv.invitee_phone = coalesce(v_user_phone,''))) then
    raise exception 'invitation_not_for_caller' using errcode = 'P0006';
  end if;

  -- Idempotency keys on the invitation's OWN accepted_by (authoritative), NOT the membership's
  -- source_invitation_id: a reconciled membership (an executor who was already a beneficiary member) has a
  -- different/NULL source, so keying on source would (a) spuriously P0005 a same-user re-accept AND (b)
  -- NEVER self-heal a missing designation — the silent-authority-void the shared helper exists to prevent.
  if v_inv.status = 'accepted' then
    if v_inv.accepted_by = v_user then
      perform public.provision_from_invitation(v_inv.id, v_user);   -- idempotent self-heal (re-stamps a missing designation)
      select em.id into v_membership_id from public.estate_memberships em
       where em.estate_id = v_inv.estate_id and em.user_id = v_user;
          -- ★ PHASE 11-MC: A FIDUCIARY ACCEPTANCE HAS NO MEMBERSHIP, SO IT REPORTS NONE.
      -- `provision_from_invitation` no longer creates a membership for an executor/trustee invitation,
      -- so `v_membership_id` is NULL for a recipient who holds no independent access class. Returning
      -- the invitation's stale `proposed_role` and a hardcoded 'approved' would assert an approved
      -- beneficiary membership that does not exist — the exact fiction this phase removes, restated on
      -- the way out. Role and status are NULL together with the membership id; the fiduciary authority
      -- is reported by `get_my_fiduciary_estates`, which is the surface that owns it.
  return query select v_membership_id, v_inv.estate_id,
        (select e.name from public.estates e where e.id = v_inv.estate_id),
        case when v_membership_id is null then null else v_inv.proposed_role::text end,
        case when v_membership_id is null then null else 'approved'::text end;
      return;
    else
      raise exception 'invitation_already_accepted' using errcode = 'P0005';
    end if;
  end if;

  update public.invitations set status='accepted', accepted_by=v_user, accepted_at=now(), updated_at=now() where id=v_inv.id;
  v_membership_id := public.provision_from_invitation(v_inv.id, v_user);
  perform public.write_audit('invitation.accepted', 'estate_memberships', v_membership_id, v_inv.estate_id,
    jsonb_build_object('invitation_id', v_inv.id, 'via', 'accept_by_id'));

  -- ★ PHASE 10-E — the OWNER learns their invitation was accepted. Deliberately BELOW the idempotent
  -- re-accept branch above, which returns early: a self-heal re-accept must not tell the owner a
  -- second time that someone joined.
  --
  -- The copy says "someone you invited", never who. The owner issued the invitation and already
  -- knows the invitee, so this says strictly LESS than they know — which is the correct direction
  -- for a surface whose whole job is to avoid becoming a disclosure channel. It also never names the
  -- accepted ROLE: a membership role is a relationship, and relationships are stated by the
  -- authoritative surfaces that already gate them, not by a heads-up.
  perform public.emit_lifecycle_notification(
    public.estate_owner_user_id(v_inv.estate_id),
    v_inv.estate_id,
    'invitation.accepted',
    'afterworth://owner-invitations'
  );
  return query select v_membership_id, v_inv.estate_id,
    (select e.name from public.estates e where e.id = v_inv.estate_id),
    case when v_membership_id is null then null else v_inv.proposed_role::text end,
    case when v_membership_id is null then null else 'approved'::text end;
end;
$$;


ALTER FUNCTION "public"."accept_invitation"("p_invitation_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_authorize_claim_evidence"("p_claim" "uuid", "p_slot" "text") RETURNS TABLE("storage_path" "text", "document_id" "uuid", "mime_type" "text", "max_upload_bytes" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid    uuid := auth.uid();
  v_estate uuid;
  v_doc    uuid;
  v_path   text;
  v_mime   text;
  v_max    bigint;
begin
  perform public.admin_require_gate();

  if p_slot not in ('death_cert', 'executor_id') then
    raise exception 'invalid_slot' using errcode = 'P0001';
  end if;

  select c.estate_id,
         case p_slot when 'death_cert' then c.death_certificate_doc_id
                     else c.executor_id_doc_id end
    into v_estate, v_doc
    from public.claim_packets c
   where c.id = p_claim;
  if not found then
    raise exception 'claim_not_found' using errcode = 'P0002';
  end if;
  if v_doc is null then
    raise exception 'evidence_not_found' using errcode = 'P0002';
  end if;

  select d.storage_path, d.mime_type
    into v_path, v_mime
    from public.documents d
   where d.id = v_doc;
  if not found then
    raise exception 'evidence_not_found' using errcode = 'P0002';
  end if;

  -- Serving guard ceiling, sourced from policy (defensive; streaming lifts the real cap). Generous fallback
  -- only if the seeded singleton is somehow absent — never a hardcoded contract number.
  v_max := coalesce((select p.max_upload_bytes from public.upload_policy p where p.id = 1), 25 * 1024 * 1024);

  insert into public.audit_logs(actor_id, estate_id, action, target_table, target_id, metadata, source)
  values (
    v_uid, v_estate, 'claim.evidence_viewed', 'documents', v_doc,
    jsonb_build_object('severity', 'high', 'claim_id', p_claim, 'document_id', v_doc, 'slot', p_slot),
    'admin'
  );

  return query select v_path, v_doc, v_mime, v_max;
end;
$$;


ALTER FUNCTION "public"."admin_authorize_claim_evidence"("p_claim" "uuid", "p_slot" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_create_executor_invitation"("p_estate" "uuid", "p_kind" "text", "p_invitee_email" "text" DEFAULT NULL::"text", "p_invitee_phone" "text" DEFAULT NULL::"text", "p_reason" "text" DEFAULT NULL::"text", "p_case_ref" "text" DEFAULT NULL::"text", "p_expires_in_days" integer DEFAULT 14) RETURNS TABLE("invitation_id" "uuid", "raw_token" "text", "token_fingerprint" "text", "expires_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_id uuid; v_tok text; v_fp text; v_exp timestamptz;
begin
  perform public.admin_require_gate();                        -- auth -> is_admin -> aal2 -> 15-min freshness

  if p_kind not in ('executor', 'trustee') then
    raise exception 'kind_not_supported' using errcode = 'P0001';   -- break-glass mints fiduciary roles ONLY
  end if;
  if p_invitee_email is null and p_invitee_phone is null then
    raise exception 'invitee_contact_required' using errcode = 'P0001';
  end if;
  perform public.require_breakglass_justification(p_reason, p_case_ref);
  perform public.assert_not_self_invitee(p_invitee_email, p_invitee_phone);

  -- Mint through the canonical path (derives proposed_role='beneficiary' for executor/trustee).
  select ci.invitation_id, ci.raw_token, ci.token_fingerprint, ci.expires_at
    into v_id, v_tok, v_fp, v_exp
    from public.create_invitation(p_estate, p_kind, 'beneficiary', p_invitee_email, p_invitee_phone,
                                  false, false, p_expires_in_days) ci;

  -- HIGH-SEVERITY accountability record (separate from create_invitation's normal 'invitation.created').
  perform public.write_admin_breakglass_audit(
    'admin.breakglass.executor_invitation', 'invitations', v_id, p_estate, p_reason, p_case_ref,
    jsonb_build_object('kind', p_kind, 'invitation_id', v_id, 'token_fingerprint', v_fp));

  -- NOTIFICATION HOOK (NO-OP): out-of-band notify the invitee + a security channel later; kept out of the tx.

  return query select v_id, v_tok, v_fp, v_exp;
end;
$$;


ALTER FUNCTION "public"."admin_create_executor_invitation"("p_estate" "uuid", "p_kind" "text", "p_invitee_email" "text", "p_invitee_phone" "text", "p_reason" "text", "p_case_ref" "text", "p_expires_in_days" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_decide_claim_packet"("p_claim_id" "uuid", "p_decision" "text", "p_review_notes" "text" DEFAULT NULL::"text") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_uid uuid := auth.uid(); v_estate uuid; v_status text; v_target text;
begin
  perform public.admin_require_gate();

  if p_decision not in ('approve', 'reject') then
    raise exception 'invalid_decision' using errcode = 'P0001';
  end if;
  v_target := case p_decision when 'approve' then 'approved' else 'rejected' end;

  select estate_id, status into v_estate, v_status from public.claim_packets where id = p_claim_id for update;
  if not found then
    raise exception 'claim_not_found' using errcode = 'P0002';
  end if;

  -- Idempotent replay: already at the requested terminal -> graceful no-op (no re-stamp, no re-audit).
  if v_status = v_target then
    return v_status;
  end if;
  -- Contradictory re-decision (approve<->reject) or a terminal/released state -> explicit rejection, no silent flip.
  if v_status not in ('submitted', 'under_review') then
    raise exception 'claim_already_decided' using errcode = 'P0001';
  end if;

  update public.claim_packets
     set status = v_target, reviewer_id = v_uid, decided_at = now(), review_notes = p_review_notes
   where id = p_claim_id;

  insert into public.audit_logs(actor_id, estate_id, action, target_table, target_id, metadata, source)
  values (
    v_uid, v_estate, 'claim.' || v_target, 'claim_packets', p_claim_id,
    jsonb_build_object('severity', 'high', 'claim_id', p_claim_id, 'decision', p_decision,
                       'reviewer_id', v_uid, 'review_notes', p_review_notes),
    'admin'
  );

  return v_target;
end;
$$;


ALTER FUNCTION "public"."admin_decide_claim_packet"("p_claim_id" "uuid", "p_decision" "text", "p_review_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_decide_death_verification_case"("p_case" "uuid", "p_decision" "text", "p_note" "text" DEFAULT NULL::"text") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid      uuid;
  v_estate   uuid;
  v_status   text;
  v_attained public.verification_level;
  v_required public.verification_level;
  v_target   text;
begin
  perform public.admin_require_gate();
  v_uid := auth.uid();

  if p_decision not in ('verify', 'reject') then
    raise exception 'invalid_decision' using errcode = 'P0001';
  end if;
  v_target := case p_decision when 'verify' then 'verified' else 'rejected' end;

  select c.estate_id, c.status, c.attained_level
    into v_estate, v_status, v_attained
    from public.death_verification_cases c
   where c.id = p_case
   for update;
  if v_estate is null then
    raise exception 'case_not_found' using errcode = 'P0002';
  end if;

  if v_status = v_target then
    return v_status; -- idempotent replay: no re-stamp, no re-audit
  end if;
  if v_status <> 'open' then
    raise exception 'case_already_decided' using errcode = 'P0001';
  end if;

  if p_decision = 'verify' then
    -- LIVE requirement, not the snapshot: a policy tightened mid-case tightens the case.
    v_required := public.required_verification_level(v_estate);
    if not coalesce(v_attained >= v_required, false) then
      raise exception 'verification_level_insufficient' using errcode = 'P0001';
    end if;
  end if;

  update public.death_verification_cases
     set status = v_target, decided_by = v_uid, decided_at = now(),
         decision_note = p_note, updated_at = now()
   where id = p_case;

  perform public.apply_estate_lifecycle_transition(
    v_estate,
    case when p_decision = 'verify' then 'death_verified' else 'active' end,
    p_case,
    'case_' || v_target);

  insert into public.audit_logs (actor_id, estate_id, action, target_table, target_id, metadata, source)
  values (v_uid, v_estate, 'death_case.' || v_target, 'death_verification_cases', p_case,
          jsonb_build_object('severity', 'high', 'case_id', p_case, 'decision', p_decision,
                            'required_level', v_required::text, 'attained_level', v_attained::text,
                            'reviewer_id', v_uid),
          'admin');
  return v_target;
end $$;


ALTER FUNCTION "public"."admin_decide_death_verification_case"("p_case" "uuid", "p_decision" "text", "p_note" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_get_death_verification_case"("p_case" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid      uuid;
  v_c        public.death_verification_cases%rowtype;
  v_l        public.estate_lifecycle%rowtype;
  v_duration interval;
  v_auth     jsonb;
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
  -- ★ PHASE D — ONE CONSULTATION, TWO CONSUMERS BELOW. Both `window` and `release_authority` read
  -- this single verdict, so the dates the console renders and the verdict it acts on can never
  -- describe different evaluations of the same estate.
  v_auth := public.owner_notice_release_authority(p_case);

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
    -- ────────────────────────────────────────────────────────────────────────────────────────
    -- ★ PHASE 11-OC / PHASE D — THE WINDOW FACTS COME FROM THE RELEASE AUTHORITY, NOT FROM HERE.
    -- ────────────────────────────────────────────────────────────────────────────────────────
    --
    -- This object used to compute its own clock: `owner_notified_at + duration`, and `elapsed` from
    -- the same anchor. That was a faithful mirror of the pre-Phase-D door — and being a faithful
    -- mirror is exactly the problem, because it was a SECOND implementation of the release clock.
    -- When Phase D re-anchored the door on `notice_accepted_at`, a console still computing from
    -- `owner_notified_at` would have shown an eligibility date up to several days too early and
    -- offered AUTHORIZE RELEASE on an estate the server refuses.
    --
    -- So both fields are now read from `owner_notice_release_authority` — the SAME function
    -- `authorize_release` consults — and this projection performs no clock arithmetic of its own.
    -- The `viewer_is_reviewer_a` discipline applied to a date: the server answers, the client
    -- renders, and the routine re-checks independently regardless.
    --
    -- ★ THE SHAPE IS PRESERVED so an older console keeps parsing. `duration`, `configured`,
    -- `release_eligible_at` and `elapsed` all still exist and still mean what their names say —
    -- they are simply now computed once, in the authority, from the acceptance fact.
    'window', jsonb_build_object(
      'duration',            v_duration::text,
      -- NULL duration means NOT CONFIGURED, which means the window never elapses and release
      -- refuses. The console must be able to say that, rather than render a blank date.
      'configured',          v_duration is not null,
      -- NULL until there is an acceptance fact to anchor on. A console must render that as "not yet
      -- eligible", never as a blank it fills in from provenance.
      'release_eligible_at', v_auth -> 'release_eligible_at',
      'elapsed',             coalesce((v_auth ->> 'elapsed')::boolean, false)
    ),
    -- ────────────────────────────────────────────────────────────────────────────────────────
    -- ★ PHASE 11-OC / PHASE D — RELEASE AUTHORITY IS THE SERVER'S ANSWER, NOT THE CLIENT'S GUESS.
    -- ────────────────────────────────────────────────────────────────────────────────────────
    --
    -- The console must offer AUTHORIZE RELEASE exactly when `authorize_release` would accept it on
    -- owner-notice grounds. That rule is not a status list: it turns on the CURRENT case episode, on
    -- the CURRENT generation, on the acceptance FACT rather than the status, and on a strict clock
    -- anchored to that fact. A TypeScript mirror of it would be a second policy governing an
    -- IRREVERSIBLE act — the highest-stakes place in this product for a console and a door to drift.
    --
    -- It carries a NAMED refusal code rather than a sentence, so the console owns the operator copy
    -- and the server owns the policy. No address, no owner identity, on any branch.
    --
    -- ★ IT IS NOT A PERMISSION. The two-person rule, the admin gate, the lifecycle state and the
    -- audit reason are all re-checked inside `authorize_release` every single time. This field makes
    -- the affordance TRUTHFUL; it grants nothing.
    'release_authority', v_auth,
    -- ────────────────────────────────────────────────────────────────────────────────────────
    -- ★ PHASE 11-OC — THE EPISODE, NOT JUST A LIST OF ROWS.
    -- ────────────────────────────────────────────────────────────────────────────────────────
    --
    -- Phase A gave a notice an episode (`case_id`), a position in it (`generation`), a retirement
    -- link (`superseded_by`) and the one fact release turns on (`notice_accepted_at`). Without those
    -- four the console can render only a status — and a status is precisely what this phase proved is
    -- not enough: `dispatched` means "provider accepted" for a row written after Phase A and means
    -- "we do not know" for a row written before it. A console that labelled both the same way would
    -- state, on the one screen where it matters, that a living owner was reached when nobody knows.
    --
    -- `is_current` is projected rather than left to the client to derive from `superseded_by`,
    -- because a retired generation and a live one must never be shown with the same weight, and a
    -- null-check is exactly the kind of derivation a UI gets wrong once and then keeps.
    --
    -- ★ STILL NO ADDRESS. `recipient` is NOT selected, here or anywhere in this file. An operator's
    -- workflow never requires a living owner's address, and a projection that never carries it cannot
    -- leak it through a log, a screenshot, or a future console feature. Every field added here is a
    -- workflow fact about a queue row; none of them is contact detail.
    'owner_notice', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id',            o.id,
               'channel',       o.channel,
               'notice_kind',   o.notice_kind,
               'status',        o.status,
               'requested_at',  o.requested_at,
               'dispatched_at', o.dispatched_at,
               'attempts',      o.attempts,
               'failure_class', o.failure_class,
               -- The episode this row belongs to. NULL on a pre-Phase-A row, which is the honest
               -- answer: those belong to no provable episode and are never guessed into one.
               'case_id',            o.case_id,
               'generation',         o.generation,
               'superseded_by',      o.superseded_by,
               'is_current',         o.superseded_by is null,
               -- THE FACT. NULL is a real answer and the console must render it as one.
               'notice_accepted_at', o.notice_accepted_at,
               'claimed_at',         o.claimed_at
             ) order by o.requested_at desc)
        from public.owner_notice_outbox o
       where o.estate_id = v_c.estate_id
    ), '[]'::jsonb),
    -- ────────────────────────────────────────────────────────────────────────────────────────
    -- ★ PHASE 11-OC / PHASE C — ACTION AVAILABILITY IS THE SERVER'S ANSWER, NOT THE CLIENT'S GUESS.
    -- ────────────────────────────────────────────────────────────────────────────────────────
    --
    -- The console must offer "Re-send owner safety notice" exactly when
    -- `reissue_owner_safety_notice` would accept it. The eligibility rule is not a status list — it
    -- turns on the lifecycle state, on whether this case is still the CURRENT episode, on the
    -- acceptance FACT (not the status), and on whether an address resolves. A TypeScript mirror of
    -- that would be a second policy, and the first time the two drifted an operator would either be
    -- offered a control the door refuses or denied one an estate needs.
    --
    -- So the verdict comes from `owner_notice_reissue_assessment`, the SAME function the door
    -- consults, and the console renders it. This is the `viewer_is_reviewer_a` discipline applied to
    -- an action: the server answers, the client displays, and the routine re-checks independently
    -- regardless. UI affordance is not permission — this grants nothing.
    --
    -- It carries a NAMED refusal code rather than a sentence, so the console owns the operator copy
    -- and the server owns the policy. Counts and codes only; no address on any branch.
    'owner_notice_reissue', public.owner_notice_reissue_assessment(v_c.id),
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
end $$;


ALTER FUNCTION "public"."admin_get_death_verification_case"("p_case" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."admin_get_death_verification_case"("p_case" "uuid") IS 'The operator case file (Phase 11-K): case facts, initiator identity, lifecycle timestamps, LIVE window facts, owner-notice dispatch status (NEVER the recipient address) and evidence METADATA. viewer_is_reviewer_a is derived from auth.uid() INSIDE this definer so the console can state release ineligibility truthfully — it grants nothing; authorize_release re-checks independently. Phase 11-OC/D: `window` and `release_authority` both come from owner_notice_release_authority, the SAME verdict the release door consults, so the console performs no notice qualification, no episode matching and no clock arithmetic of its own. Carries no asset, valuation, beneficiary, designation, grant, document byte or storage path.';


SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."audit_logs" (
    "id" bigint NOT NULL,
    "actor_id" "uuid",
    "estate_id" "uuid",
    "action" "text" NOT NULL,
    "target_table" "text",
    "target_id" "uuid",
    "ip" "inet",
    "user_agent" "text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "source" "text" DEFAULT 'server'::"text" NOT NULL,
    CONSTRAINT "audit_logs_source_check" CHECK (("source" = ANY (ARRAY['server'::"text", 'ios_forward'::"text", 'admin'::"text", 'worker'::"text"])))
);


ALTER TABLE "public"."audit_logs" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_list_audit"("p_before_created" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_before_id" bigint DEFAULT NULL::bigint, "p_limit" integer DEFAULT 50, "p_estate" "uuid" DEFAULT NULL::"uuid", "p_actor" "uuid" DEFAULT NULL::"uuid", "p_action" "text" DEFAULT NULL::"text", "p_source" "text" DEFAULT NULL::"text") RETURNS SETOF "public"."audit_logs"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  perform public.admin_require_gate();
  return query
    select *
    from public.audit_logs a
    where (p_estate is null or a.estate_id = p_estate)
      and (p_actor  is null or a.actor_id = p_actor)
      and (p_action is null or a.action  = p_action)
      and (p_source is null or a.source  = p_source)
      and (
        p_before_created is null
        or a.created_at < p_before_created
        or (a.created_at = p_before_created and a.id < coalesce(p_before_id, 9223372036854775807))
      )
    order by a.created_at desc, a.id desc
    limit least(greatest(coalesce(p_limit, 50), 1), 200);
end;
$$;


ALTER FUNCTION "public"."admin_list_audit"("p_before_created" timestamp with time zone, "p_before_id" bigint, "p_limit" integer, "p_estate" "uuid", "p_actor" "uuid", "p_action" "text", "p_source" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_list_claim_packets"("p_estate" "uuid" DEFAULT NULL::"uuid", "p_status" "text" DEFAULT NULL::"text", "p_before_submitted" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_before_id" "uuid" DEFAULT NULL::"uuid", "p_limit" integer DEFAULT 50) RETURNS TABLE("id" "uuid", "estate_id" "uuid", "requested_by" "uuid", "status" "text", "death_certificate_doc_id" "uuid", "executor_id_doc_id" "uuid", "reviewer_id" "uuid", "review_notes" "text", "submitted_at" timestamp with time zone, "decided_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  perform public.admin_require_gate();
  return query
    select c.id, c.estate_id, c.requested_by, c.status,
           c.death_certificate_doc_id, c.executor_id_doc_id, c.reviewer_id,
           c.review_notes, c.submitted_at, c.decided_at
    from public.claim_packets c
    where (p_estate is null or c.estate_id = p_estate)
      and (p_status is null or c.status = p_status)
      and (
        p_before_submitted is null
        or c.submitted_at < p_before_submitted
        or (c.submitted_at = p_before_submitted and c.id < p_before_id)
      )
    order by c.submitted_at desc, c.id desc
    limit least(greatest(coalesce(p_limit, 50), 1), 200);
end;
$$;


ALTER FUNCTION "public"."admin_list_claim_packets"("p_estate" "uuid", "p_status" "text", "p_before_submitted" timestamp with time zone, "p_before_id" "uuid", "p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_list_claim_packets_enriched"("p_estate" "uuid" DEFAULT NULL::"uuid", "p_status" "text" DEFAULT NULL::"text", "p_before_submitted" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_before_id" "uuid" DEFAULT NULL::"uuid", "p_limit" integer DEFAULT 50) RETURNS TABLE("id" "uuid", "estate_id" "uuid", "estate_name" "text", "requested_by" "uuid", "submitter_email" "text", "submitter_name" "text", "status" "text", "submitted_at" timestamp with time zone, "decided_at" timestamp with time zone, "reviewer_id" "uuid", "reviewer_email" "text", "review_notes" "text", "death_certificate_doc_id" "uuid", "death_cert_title" "text", "death_cert_doc_type" "text", "death_cert_uploaded_at" timestamp with time zone, "executor_id_doc_id" "uuid", "executor_id_title" "text", "executor_id_doc_type" "text", "executor_id_uploaded_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  perform public.admin_require_gate();
  return query
    select
      c.id, c.estate_id, e.name, c.requested_by, ps.email, ps.full_name,
      c.status, c.submitted_at, c.decided_at, c.reviewer_id, pr.email, c.review_notes,
      c.death_certificate_doc_id, dc.title, dc.doc_type, dc.created_at,
      c.executor_id_doc_id,       de.title, de.doc_type, de.created_at
    from public.claim_packets c
    left join public.estates   e  on e.id  = c.estate_id
    left join public.profiles  ps on ps.id = c.requested_by
    left join public.profiles  pr on pr.id = c.reviewer_id
    left join public.documents dc on dc.id = c.death_certificate_doc_id
    left join public.documents de on de.id = c.executor_id_doc_id
    where (p_estate is null or c.estate_id = p_estate)
      and (p_status is null or c.status = p_status)
      and (
        p_before_submitted is null
        or c.submitted_at < p_before_submitted
        or (c.submitted_at = p_before_submitted and c.id < p_before_id)
      )
    order by c.submitted_at desc, c.id desc
    limit least(greatest(coalesce(p_limit, 50), 1), 200);
end;
$$;


ALTER FUNCTION "public"."admin_list_claim_packets_enriched"("p_estate" "uuid", "p_status" "text", "p_before_submitted" timestamp with time zone, "p_before_id" "uuid", "p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_list_death_verification_cases"("p_status" "text" DEFAULT NULL::"text", "p_before_initiated" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_before_id" "uuid" DEFAULT NULL::"uuid", "p_limit" integer DEFAULT 50) RETURNS TABLE("case_id" "uuid", "estate_id" "uuid", "estate_name" "text", "case_status" "text", "lifecycle_state" "text", "event_type" "text", "initiated_at" timestamp with time zone, "updated_at" timestamp with time zone, "initiator_capacity" "text", "jurisdiction_context" "text", "required_level" "text", "attained_level" "text", "evidence_total" integer, "evidence_awaiting_review" integer, "owner_channel_resolvable" boolean, "decided_at" timestamp with time zone)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
end $$;


ALTER FUNCTION "public"."admin_list_death_verification_cases"("p_status" "text", "p_before_initiated" timestamp with time zone, "p_before_id" "uuid", "p_limit" integer) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."admin_list_death_verification_cases"("p_status" "text", "p_before_initiated" timestamp with time zone, "p_before_id" "uuid", "p_limit" integer) IS 'The operator queue for death-verification cases (Phase 11-K). Workflow facts only: case status, lifecycle state, LIVE required level vs attained, evidence counts, and whether the owner channel RESOLVES — never the owner address. No asset, valuation, beneficiary, designation, grant, document byte or storage path. Admin-gated inside the definer; keyset paged; clamped to 200.';



CREATE OR REPLACE FUNCTION "public"."admin_list_invitations"("p_estate" "uuid" DEFAULT NULL::"uuid", "p_status" "text" DEFAULT NULL::"text", "p_before_created" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_before_id" "uuid" DEFAULT NULL::"uuid", "p_limit" integer DEFAULT 50) RETURNS TABLE("id" "uuid", "estate_id" "uuid", "estate_display_name" "text", "kind" "text", "proposed_role" "text", "status" "text", "invitee_email_hint" "text", "invitee_phone_hint" "text", "inviter_display_name" "text", "expires_at" timestamp with time zone, "is_expired" boolean, "created_at" timestamp with time zone, "accepted_at" timestamp with time zone, "accepted_by" "uuid", "token_fingerprint" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  perform public.admin_require_gate();
  return query
    select
      i.id, i.estate_id, i.estate_display_name, i.kind, i.proposed_role, i.status,
      i.invitee_email_hint, i.invitee_phone_hint, i.inviter_display_name,
      i.expires_at, (i.expires_at < now()) as is_expired,
      i.created_at, i.accepted_at, i.accepted_by,
      substr(i.token_hash, 1, 12) as token_fingerprint
    from public.invitations i
    where (p_estate is null or i.estate_id = p_estate)
      and (p_status is null or i.status = p_status)
      and (
        p_before_created is null
        or i.created_at < p_before_created
        or (i.created_at = p_before_created and i.id < p_before_id)
      )
    order by i.created_at desc, i.id desc
    limit least(greatest(coalesce(p_limit, 50), 1), 200);
end;
$$;


ALTER FUNCTION "public"."admin_list_invitations"("p_estate" "uuid", "p_status" "text", "p_before_created" timestamp with time zone, "p_before_id" "uuid", "p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_list_jurisdiction_policy"() RETURNS TABLE("jurisdiction" "text", "floor_level" "text", "is_counsel_approved" boolean, "notes" "text", "updated_by" "uuid", "updated_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  perform public.admin_require_gate();
  return query
    select j.jurisdiction, j.floor_level::text, j.is_counsel_approved, j.notes, j.updated_by, j.updated_at
    from public.jurisdiction_policy j
    order by j.jurisdiction;
end;
$$;


ALTER FUNCTION "public"."admin_list_jurisdiction_policy"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_reconciliation_report"() RETURNS TABLE("issue" "text", "estate_id" "uuid", "ref_id" "uuid", "detail" "jsonb")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  perform public.admin_require_gate();
  return query
  -- (1) beneficiary designation with a stamped user_id but NO approved membership in that estate
  select 'designation_without_membership'::text, b.estate_id, b.id,
         jsonb_build_object('user_id', b.user_id, 'email', b.email, 'name', b.full_name)
  from public.beneficiaries b
  where b.user_id is not null
    and not exists (select 1 from public.estate_memberships m
                    where m.estate_id = b.estate_id and m.user_id = b.user_id and m.status = 'approved')
  union all
  -- (2) active grant whose grantee has NO approved membership in that estate
  select 'grant_without_membership'::text, g.estate_id, g.id,
         jsonb_build_object('grantee_user_id', g.grantee_user_id, 'grantee_role', g.grantee_role)
  from public.access_grants g
  where g.status = 'active'
    and not exists (select 1 from public.estate_memberships m
                    where m.estate_id = g.estate_id and m.user_id = g.grantee_user_id and m.status = 'approved')
  union all
  -- (3) MIS-STAMP (fixture #1's shape): a beneficiary row whose stamped user_id's profile email
  --     differs from the designation email — the self-link landed on the wrong user.
  select 'email_user_id_mismatch'::text, b.estate_id, b.id,
         jsonb_build_object('beneficiary_email', b.email, 'stamped_user_id', b.user_id, 'profile_email', p.email)
  from public.beneficiaries b
  join public.profiles p on p.id = b.user_id
  where b.user_id is not null
    and b.email is not null
    and lower(p.email) <> lower(b.email)
  union all
  -- (4) INVARIANT CANARY: duplicate (estate,user) memberships — MUST return 0 rows (the UNIQUE
  --     constraint captured in Slice 0 makes this structurally impossible; kept as a live tripwire).
  select 'duplicate_membership_CANARY'::text, m.estate_id, m.user_id,
         jsonb_build_object('count', count(*))
  from public.estate_memberships m
  group by m.estate_id, m.user_id
  having count(*) > 1;
end;
$$;


ALTER FUNCTION "public"."admin_reconciliation_report"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_require_gate"() RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  -- (a) authenticated at all?
  if auth.uid() is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;
  -- (b) an admin? (is_admin() is DEFINER — reads admins bypassing its deny-all RLS)
  if not public.is_admin() then
    raise exception 'admin_required' using errcode = '42501';
  end if;
  -- (c) MFA / aal2 — reuse the shared financial gate verbatim (raises 'mfa_required' / 42501).
  perform public.require_aal2();
  -- (d) token freshness: `iat` is a Unix-epoch INTEGER (verified live 2026-07-10 by decoding a real
  --     JWT — not trusted from a doc). Deny a token issued more than 15 min ago. FAIL-CLOSED on a
  --     missing iat (coalesce -> 0 -> ancient -> stale).
  if extract(epoch from now())::bigint - coalesce((auth.jwt() ->> 'iat')::bigint, 0) > 900 then
    raise exception 'stale_token_reauth_required' using errcode = '42501';
  end if;
end;
$$;


ALTER FUNCTION "public"."admin_require_gate"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_review_death_evidence"("p_evidence" "uuid", "p_outcome" "text", "p_note" "text" DEFAULT NULL::"text") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid     uuid;
  v_case    uuid;
  v_estate  uuid;
  v_status  text;
begin
  perform public.admin_require_gate();
  v_uid := auth.uid();

  if p_outcome not in ('reviewed_accepted', 'reviewed_rejected') then
    raise exception 'invalid_review_outcome' using errcode = 'P0001';
  end if;

  select e.case_id, e.estate_id, e.review_status
    into v_case, v_estate, v_status
    from public.death_verification_evidence e
   where e.id = p_evidence
   for update;
  if v_case is null then
    raise exception 'evidence_not_found' using errcode = 'P0002';
  end if;

  if v_status = p_outcome then
    return v_status; -- idempotent replay: no re-stamp, no re-audit
  end if;
  if v_status <> 'received' then
    raise exception 'evidence_already_reviewed' using errcode = 'P0001';
  end if;

  update public.death_verification_evidence
     set review_status = p_outcome, reviewed_by = v_uid, reviewed_at = now(), review_note = p_note
   where id = p_evidence;

  -- Direct insert, source='admin', severity high — the admin_decide_claim_packet precedent.
  -- Metadata names ids and the outcome; never document contents, titles, or claimant identity.
  insert into public.audit_logs (actor_id, estate_id, action, target_table, target_id, metadata, source)
  values (v_uid, v_estate, 'death_case.evidence_reviewed', 'death_verification_evidence', p_evidence,
          jsonb_build_object('severity', 'high', 'case_id', v_case,
                            'evidence_id', p_evidence, 'outcome', p_outcome),
          'admin');
  return p_outcome;
end $$;


ALTER FUNCTION "public"."admin_review_death_evidence"("p_evidence" "uuid", "p_outcome" "text", "p_note" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_set_attained_verification_level"("p_case" "uuid", "p_level" "public"."verification_level", "p_basis" "text" DEFAULT NULL::"text") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid    uuid;
  v_estate uuid;
  v_status text;
  v_old    public.verification_level;
begin
  perform public.admin_require_gate();
  v_uid := auth.uid();

  if p_level is null then
    raise exception 'invalid_verification_level' using errcode = 'P0001';
  end if;

  select c.estate_id, c.status, c.attained_level
    into v_estate, v_status, v_old
    from public.death_verification_cases c
   where c.id = p_case
   for update;
  if v_estate is null then
    raise exception 'case_not_found' using errcode = 'P0002';
  end if;
  if v_status <> 'open' then
    raise exception 'case_not_open' using errcode = 'P0001';
  end if;

  if v_old is not distinct from p_level then
    return p_level::text; -- idempotent replay: no re-stamp, no re-audit
  end if;

  update public.death_verification_cases
     set attained_level = p_level, updated_at = now()
   where id = p_case;

  insert into public.audit_logs (actor_id, estate_id, action, target_table, target_id, metadata, source)
  values (v_uid, v_estate, 'death_case.attained_level_set', 'death_verification_cases', p_case,
          jsonb_build_object('severity', 'high', 'case_id', p_case,
                            'old_level', v_old::text, 'new_level', p_level::text,
                            'basis', p_basis),
          'admin');
  return p_level::text;
end $$;


ALTER FUNCTION "public"."admin_set_attained_verification_level"("p_case" "uuid", "p_level" "public"."verification_level", "p_basis" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."apply_estate_lifecycle_transition"("p_estate" "uuid", "p_to" "text", "p_case" "uuid", "p_reason" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_from text;
begin
  select l.state into v_from
    from public.estate_lifecycle l
   where l.estate_id = p_estate
   for update;
  if v_from is null then
    v_from := 'active';
  end if;

  -- The closed map. An unknown current state is unreachable (table CHECK) but still refused here:
  -- unknown state fails closed, it is never a wildcard. challenge_halted and released have NO
  -- outbound edges, deliberately (see the header).
  if not (
       (v_from = 'active'                     and p_to = 'death_verification_pending')
    or (v_from = 'death_verification_pending' and p_to = 'active')
    or (v_from = 'death_verification_pending' and p_to = 'death_verified')
    or (v_from = 'death_verified'             and p_to = 'owner_notification_dispatched')
    or (v_from = 'owner_notification_dispatched' and p_to = 'challenge_window')
    or (v_from = 'death_verification_pending' and p_to = 'challenge_halted')
    or (v_from = 'death_verified'             and p_to = 'challenge_halted')
    or (v_from = 'owner_notification_dispatched' and p_to = 'challenge_halted')
    or (v_from = 'challenge_window'           and p_to = 'challenge_halted')
    or (v_from = 'challenge_window'           and p_to = 'released')
  ) then
    raise exception 'invalid_lifecycle_transition' using errcode = 'P0001';
  end if;

  insert into public.estate_lifecycle (estate_id, state, updated_at, updated_case_id)
  values (p_estate, p_to, now(), p_case)
  on conflict (estate_id) do update
    set state = excluded.state,
        updated_at = excluded.updated_at,
        updated_case_id = excluded.updated_case_id;

  perform public.write_audit(
    'estate_lifecycle.transition', 'estate_lifecycle', p_case, p_estate,
    jsonb_build_object('from_state', v_from, 'to_state', p_to,
                       'case_id', p_case, 'reason', p_reason));
end $$;


ALTER FUNCTION "public"."apply_estate_lifecycle_transition"("p_estate" "uuid", "p_to" "text", "p_case" "uuid", "p_reason" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."access_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "estate_id" "uuid" NOT NULL,
    "requester_user_id" "uuid" NOT NULL,
    "category" "text" NOT NULL,
    "reason" "text",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "resolved_at" timestamp with time zone,
    "resolved_by_user_id" "uuid",
    "resulting_grant_id" "uuid",
    "requester_role" "text",
    CONSTRAINT "access_requests_category_check" CHECK (("category" = 'estate_documents'::"text")),
    CONSTRAINT "access_requests_requester_role_check" CHECK ((("requester_role" IS NULL) OR ("requester_role" = ANY (ARRAY['beneficiary'::"text", 'professional_delegate'::"text"])))),
    CONSTRAINT "access_requests_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'denied'::"text"])))
);


ALTER TABLE "public"."access_requests" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."approve_access_request"("p_request_id" "uuid", "p_visibility_tier" "text" DEFAULT 'limited_detail'::"text") RETURNS SETOF "public"."access_requests"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_user      uuid := auth.uid();
  v_estate    uuid;
  v_requester uuid;
  v_category  text;
  v_status    text;
  v_role      text;
  v_grant_id  uuid;
begin
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;

  -- Lock the request row for the txn (no concurrent double-approve).
  select estate_id, requester_user_id, category, status
    into v_estate, v_requester, v_category, v_status
  from public.access_requests
  where id = p_request_id
  for update;

  if v_estate is null then
    raise exception 'request_not_found';  -- P0001 -> 400
  end if;

  -- SECURITY SPINE (privilege gate): owner-only, BEFORE any mutation.
  if not public.is_estate_owner(v_estate) then
    raise exception 'not estate owner' using errcode = '42501';
  end if;

  -- Only a pending request can be approved (prevents double-approve / duplicate grant).
  if v_status is distinct from 'pending' then
    raise exception 'request_not_pending';  -- P0001 -> 400
  end if;

  -- Owner-chosen disclosure tier; restrict to the two document-meaningful tiers (mirrors
  -- the grant UI's tierOptions). Avoids a raw CHECK violation (500) on a bad tier.
  if p_visibility_tier not in ('full_detail','limited_detail') then
    raise exception 'unsupported visibility tier';  -- P0001 -> 400
  end if;

  -- Resolve the requester's CURRENT NON-OWNERSHIP role in the estate (for grantee_role + the
  -- ceiling matrix). The ownership exclusion stays IN the WHERE (mirrors create_access_request):
  -- a (estate, user) may have >1 approved membership (no (estate,user) uniqueness — accept_
  -- invitation keys idempotency on source_invitation_id; V2 adds ownership roles). A status-only
  -- lookup could grab an OWNERSHIP row and stamp grantee_role='primary_user', which the
  -- access_grants.grantee_role CHECK rejects -> a 500 on approval. Filtering here keeps
  -- grantee_role valid AND resolves the role the SAME way the request's requester_role was stamped.
  select m.role into v_role
  from public.estate_memberships m
  where m.estate_id = v_estate
    and m.user_id = v_requester
    and m.status = 'approved'
    and not public.is_ownership_role(m.role)
  limit 1;

  -- Null = the requester is no longer an approved non-ownership member (revoked between request
  -- and approval, or now only an ownership role). Clean 400 with a readable message — NOT a 500.
  if v_role is null then
    raise exception 'requester is no longer an eligible member of this estate';  -- P0001 -> 400
  end if;

  -- Create the ALREADY-APPROVED category grant (inline; create_document_grant is doc-only).
  -- enforce_grant_ceiling no-ops here (document_id null). The one-active-category-grant
  -- unique index may fire -> already-granted path in the handler below.
  begin
    insert into public.access_grants
      (estate_id, grantee_user_id, grantee_role, professional_type,
       document_id, category, visibility_tier, release_condition,
       requires_step_up, status, granted_by_user_id,
       approved_at, approved_by_user_id)
    values
      (v_estate, v_requester, v_role, null,
       null, v_category, p_visibility_tier, 'after_access_request_approval',
       false, 'active', v_user,
       now(), v_user)
    returning id into v_grant_id;
  exception
    when unique_violation then
      -- Already-granted: an active category grant exists for this grantee. Link it, mark
      -- the request approved, no duplicate, no error (idempotent).
      select g.id into v_grant_id
      from public.access_grants g
      where g.estate_id = v_estate
        and g.grantee_user_id = v_requester
        and g.category = v_category
        and g.status = 'active'
      limit 1;
  end;

  update public.access_requests
     set status = 'approved',
         resolved_at = now(),
         resolved_by_user_id = v_user,
         resulting_grant_id = v_grant_id
   where id = p_request_id;

  perform public.write_audit(
    'access_request.approved',
    'access_requests',
    p_request_id,
    v_estate,
    jsonb_build_object(
      'grant_id', v_grant_id,
      'category', v_category,
      'grantee_user_id', v_requester,
      'visibility_tier', p_visibility_tier
    )
  );

  -- ★ PHASE 10-E — the REQUESTER learns the outcome of THEIR OWN request, and nothing else. The copy
  -- says the request was approved; it does not say what became visible, which tier was chosen, or
  -- what the estate contains. One notification, not two: the grant created above deliberately does
  -- NOT also emit `access_grant.created`, because a person who asked one question should get one
  -- answer.
  perform public.emit_lifecycle_notification(
    v_requester,
    v_estate,
    'access_request.approved',
    public.notification_estate_home(v_estate, v_requester)
  );

  return query select r.* from public.access_requests r where r.id = p_request_id;
end;
$$;


ALTER FUNCTION "public"."approve_access_request"("p_request_id" "uuid", "p_visibility_tier" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."access_grants" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "estate_id" "uuid" NOT NULL,
    "grantee_user_id" "uuid" NOT NULL,
    "grantee_role" "text" NOT NULL,
    "professional_type" "text",
    "document_id" "uuid",
    "category" "text",
    "visibility_tier" "text" NOT NULL,
    "release_condition" "text" NOT NULL,
    "requires_step_up" boolean DEFAULT false NOT NULL,
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "granted_by_user_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "revoked_at" timestamp with time zone,
    "revoked_by_user_id" "uuid",
    "approved_at" timestamp with time zone,
    "approved_by_user_id" "uuid",
    CONSTRAINT "access_grants_category_check" CHECK ((("category" IS NULL) OR ("category" = ANY (ARRAY['estate_documents'::"text", 'account_balances'::"text", 'institution_names'::"text", 'total_asset_value'::"text", 'linked_account_details'::"text", 'estate_inventory'::"text"])))),
    CONSTRAINT "access_grants_grantee_role_check" CHECK (("grantee_role" = ANY (ARRAY['beneficiary'::"text", 'professional_delegate'::"text"]))),
    CONSTRAINT "access_grants_release_condition_check" CHECK (("release_condition" = ANY (ARRAY['never'::"text", 'immediately'::"text", 'after_owner_approval'::"text", 'after_identity_verification'::"text", 'after_access_request_approval'::"text", 'after_verified_death'::"text", 'after_verified_incapacity'::"text", 'after_verified_death_or_incapacity'::"text", 'after_claim_case_approval'::"text"]))),
    CONSTRAINT "access_grants_scope_xor" CHECK ((("document_id" IS NOT NULL) <> ("category" IS NOT NULL))),
    CONSTRAINT "access_grants_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'revoked'::"text"]))),
    CONSTRAINT "access_grants_visibility_tier_check" CHECK (("visibility_tier" = ANY (ARRAY['hidden'::"text", 'range_only'::"text", 'category_summary'::"text", 'limited_detail'::"text", 'full_detail'::"text"])))
);


ALTER TABLE "public"."access_grants" OWNER TO "postgres";


COMMENT ON TABLE "public"."access_grants" IS 'Scope-polymorphic access grants for NON-OWNERS (beneficiary, professional_delegate). Owners are inherent via membership and have no grant row. document_id XOR category. See docs/live-data-migration.md Appendix A.';



COMMENT ON COLUMN "public"."access_grants"."approved_at" IS 'When this grant was approved (null = pending/unapproved). Generic approval state: after_owner_approval passes only when set; reused by after_access_request_approval later. Set by approve_document_grant (owner-gated). See docs/live-data-migration.md A.4.';



CREATE OR REPLACE FUNCTION "public"."approve_document_grant"("p_grant_id" "uuid") RETURNS SETOF "public"."access_grants"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_user uuid := auth.uid();
  v_estate uuid;
  v_approved timestamptz;
begin
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;

  -- Read-only lookup to resolve the grant's estate for the owner-check. No mutation yet.
  select estate_id, approved_at into v_estate, v_approved
  from public.access_grants
  where id = p_grant_id;

  if v_estate is null then
    raise exception 'grant_not_found';  -- P0001 -> 400
  end if;

  -- SECURITY SPINE (privilege-escalation gate): must precede the UPDATE.
  if not public.is_estate_owner(v_estate) then
    raise exception 'not estate owner' using errcode = '42501';
  end if;

  -- Idempotent: already approved -> return as-is, no duplicate audit.
  if v_approved is not null then
    return query select g.* from public.access_grants g where g.id = p_grant_id;
    return;
  end if;

  -- The enforce_grant_ceiling trigger re-fires on this UPDATE and re-reads the document's
  -- CURRENT sensitivity; a doc reclassified above the grantee's ceiling raises 42501 here,
  -- so approval cannot become a ceiling bypass.
  update public.access_grants
     set approved_at = now(),
         approved_by_user_id = v_user,
         updated_at = now()
   where id = p_grant_id;

  perform public.write_audit(
    'access_grant.approved',
    'access_grants',
    p_grant_id,
    v_estate,
    jsonb_build_object('approved_by_user_id', v_user)
  );

  -- ★ PHASE 10-E — approval is the moment an approval-conditioned grant becomes real, so this is
  -- where its grantee is told. Emitted after the UPDATE and after the idempotent early-return, so
  -- re-approving an already-approved grant says nothing a second time.
  --
  -- Still gated: the ceiling trigger re-fires on the UPDATE above and can leave the grant
  -- unusable, and a death- or claim-conditioned grant is not made live merely by being approved.
  -- The gate asks the row what it now IS rather than assuming approval means released.
  if exists (
    select 1 from public.access_grants g
    where g.id = p_grant_id
      and public.notification_grant_is_live(g.status, g.release_condition, g.approved_at)
  ) then
    perform public.emit_lifecycle_notification(
      (select g.grantee_user_id from public.access_grants g where g.id = p_grant_id),
      v_estate,
      'access_grant.created',
      public.notification_estate_home(
        v_estate,
        (select g.grantee_user_id from public.access_grants g where g.id = p_grant_id)
      )
    );
  end if;

  return query select g.* from public.access_grants g where g.id = p_grant_id;
end;
$$;


ALTER FUNCTION "public"."approve_document_grant"("p_grant_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."archive_estate_asset"("p_asset_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid    uuid := auth.uid();
  v_estate uuid;
  v_arch   timestamptz;
begin
  if v_uid is null then raise exception 'auth_required' using errcode = '42501'; end if;
  select estate_id, archived_at into v_estate, v_arch from public.estate_assets where id = p_asset_id;
  if not found then raise exception 'asset_not_found' using errcode = 'P0002'; end if;
  if not public.is_estate_owner(v_estate) then raise exception 'not_estate_owner' using errcode = '42501'; end if;
  -- Idempotent by refusal rather than by silence: a no-op success would tell the client the state
  -- changed when it did not.
  if v_arch is not null then raise exception 'already_archived' using errcode = 'P0001'; end if;

  update public.estate_assets
     set archived_at = now(), archived_by = v_uid, updated_at = now()
   where id = p_asset_id;

  perform public.write_audit('estate_asset.archived', 'estate_assets', p_asset_id, v_estate,
    jsonb_build_object('via', 'archive_estate_asset'));
end;
$$;


ALTER FUNCTION "public"."archive_estate_asset"("p_asset_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."assert_grant_updatable"("p_grant_id" "uuid") RETURNS "public"."access_grants"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid uuid := auth.uid();
  v_row public.access_grants;
begin
  if v_uid is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;

  select * into v_row from public.access_grants where id = p_grant_id;
  if not found or v_row.status <> 'active' then
    raise exception 'grant not found or not active';  -- P0001 -> 400
  end if;

  -- SECURITY SPINE: only the estate owner may edit a grant (DEFINER bypasses RLS, so this explicit
  -- check IS the access boundary). Self/owner-reject isn't re-checked — the row already passed it at
  -- create; an update only changes the tier, never the grantee.
  if not public.is_estate_owner(v_row.estate_id) then
    raise exception 'not estate owner' using errcode = '42501';
  end if;

  return v_row;
end;
$$;


ALTER FUNCTION "public"."assert_grant_updatable"("p_grant_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."assert_not_self_invitee"("p_invitee_email" "text", "p_invitee_phone" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_email text; v_phone text;
begin
  select email, phone into v_email, v_phone from public.profiles where id = auth.uid();
  if (p_invitee_email is not null and lower(p_invitee_email) = lower(coalesce(v_email, '')))
     or (p_invitee_phone is not null and p_invitee_phone = coalesce(v_phone, '')) then
    raise exception 'breakglass_self_assignment' using errcode = 'P0001';
  end if;
end;
$$;


ALTER FUNCTION "public"."assert_not_self_invitee"("p_invitee_email" "text", "p_invitee_phone" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."asset_bracket_high"("p" bigint) RETURNS bigint
    LANGUAGE "sql" IMMUTABLE
    AS $_$
  select case
    when p < 1000000    then 1000000       when p < 5000000    then 5000000
    when p < 10000000   then 10000000      when p < 25000000   then 25000000
    when p < 50000000   then 50000000      when p < 100000000  then 100000000
    when p < 500000000  then 500000000     when p < 1000000000 then 1000000000
    else null end;   -- top bracket ($10M+): open-ended
$_$;


ALTER FUNCTION "public"."asset_bracket_high"("p" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."asset_bracket_low"("p" bigint) RETURNS bigint
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select case
    when p < 1000000    then 0             when p < 5000000    then 1000000
    when p < 10000000   then 5000000       when p < 25000000   then 10000000
    when p < 50000000   then 25000000      when p < 100000000  then 50000000
    when p < 500000000  then 100000000     when p < 1000000000 then 500000000
    else 1000000000 end;
$$;


ALTER FUNCTION "public"."asset_bracket_low"("p" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."asset_category_grantable"("p_role" "text", "p_category" "text", "p_tier" "text") RETURNS boolean
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select case
    when p_tier = 'hidden' then true
    when p_category in ('account_balances', 'total_asset_value', 'estate_inventory') then
      case p_role
        when 'professional_delegate' then true                          -- up to full_detail
        when 'beneficiary'           then p_tier in ('range_only', 'category_summary')
        else false
      end
    when p_category in ('institution_names', 'linked_account_details') then
      p_role in ('beneficiary', 'professional_delegate')                -- up to full_detail
    else false                                                          -- unknown category -> deny
  end;
$$;


ALTER FUNCTION "public"."asset_category_grantable"("p_role" "text", "p_category" "text", "p_tier" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."asset_category_grantable"("p_role" "text", "p_category" "text", "p_tier" "text") IS 'Asset-disclosure ceiling: max grantable visibility_tier per (role, category). The $ categories — including estate_inventory (0049) — cap beneficiaries below exact value; professionals may reach full_detail. THE POLICY KNOB. Mirrors document_grantable for the category path.';



CREATE OR REPLACE FUNCTION "public"."asset_grant_tier"("p_estate" "uuid", "p_uid" "uuid", "p_category" "text") RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select g.visibility_tier
  from public.access_grants g
  where g.estate_id = p_estate
    and g.grantee_user_id = p_uid
    and g.category = p_category
    and g.status = 'active'
    -- ★ PHASE 11-B — the canonical predicate. `legacy_immediate_only` is this surface's answer
    -- carried forward verbatim: the asset-value paths have never honoured an approval-conditioned
    -- grant, and 11-B centralizes the AUTHORITY without spending a product decision on the POLICY.
    -- 11-D wires the authoritative lifecycle through as an argument like every consumer — and under
    -- THIS policy it changes nothing: death-conditioned grants stay dormant on the asset surfaces
    -- even at death_verified (R12 keeps the policies distinct). Signal-based conditions and 'never'
    -- stay dormant-deny (A.4); an unknown condition or lifecycle refuses.
    and public.release_condition_satisfied(g.release_condition, g.approved_at, 'legacy_immediate_only',
                                           public.estate_lifecycle_state(p_estate))
  limit 1;
$$;


ALTER FUNCTION "public"."asset_grant_tier"("p_estate" "uuid", "p_uid" "uuid", "p_category" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."attach_death_verification_evidence"("p_case" "uuid", "p_document" "uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid        uuid := auth.uid();
  v_estate     uuid;
  v_status     text;
  v_doc_estate uuid;
  v_evidence   uuid;
begin
  if v_uid is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;

  select c.estate_id, c.status into v_estate, v_status
    from public.death_verification_cases c
   where c.id = p_case;
  -- Nonexistent case and foreign case answer with the same bytes: the caller learns nothing about
  -- whether a case exists anywhere they are not a designee.
  if v_estate is null or not public.is_estate_executor(v_estate, v_uid) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  if v_status <> 'open' then
    raise exception 'case_not_open' using errcode = 'P0001';
  end if;

  select d.estate_id into v_doc_estate from public.documents d where d.id = p_document;
  -- One sentinel for missing and foreign alike: a designee cannot probe the document space of
  -- other estates through attachment errors.
  if v_doc_estate is null or v_doc_estate <> v_estate then
    raise exception 'doc_not_in_estate' using errcode = 'P0001';
  end if;

  insert into public.death_verification_evidence (case_id, estate_id, document_id, submitted_by)
  values (p_case, v_estate, p_document, v_uid)
  returning id into v_evidence;

  perform public.write_audit(
    'death_case.evidence_attached', 'death_verification_evidence', v_evidence, v_estate,
    jsonb_build_object('case_id', p_case, 'evidence_id', v_evidence, 'document_id', p_document));
  return v_evidence;
end $$;


ALTER FUNCTION "public"."attach_death_verification_evidence"("p_case" "uuid", "p_document" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."authorize_purge"("p_outbox_id" "uuid") RETURNS TABLE("v_bucket" "text", "v_path" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_estate uuid;
begin
  if auth.uid() is null then raise exception 'auth_required' using errcode = '42501'; end if;
  select o.estate_id into v_estate
    from public.storage_deletion_outbox o where o.id = p_outbox_id and o.status <> 'purged';
  if not found then raise exception 'outbox_not_found_or_purged' using errcode = 'P0002'; end if;
  if not public.is_estate_owner(v_estate) then raise exception 'not_estate_owner' using errcode = '42501'; end if;

  update public.storage_deletion_outbox set attempts = attempts + 1 where id = p_outbox_id;
  return query
    select o.bucket, o.object_path from public.storage_deletion_outbox o where o.id = p_outbox_id;
end;
$$;


ALTER FUNCTION "public"."authorize_purge"("p_outbox_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."authorize_release"("p_estate" "uuid", "p_reason" "text") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_row        public.estate_lifecycle%rowtype;
  v_uid        uuid;
  v_case       uuid;
  v_reviewer_a uuid;
  v_verified   timestamptz;
  v_duration   interval;
  v_auth       jsonb;
begin
  perform public.admin_require_gate();
  v_uid := auth.uid();

  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'audit_reason_required' using errcode = 'P0001';
  end if;

  select l.* into v_row
    from public.estate_lifecycle l
   where l.estate_id = p_estate
   for update;

  if v_row.state = 'released' then
    return 'released'; -- idempotent replay: no second authorization row, no re-audit
  end if;
  if v_row.state is distinct from 'challenge_window' then
    -- challenge_halted lands here too: release can NEVER proceed from a halted process.
    raise exception 'invalid_release_state' using errcode = 'P0001';
  end if;

  -- The dispatch facts (D4), KEPT IN PHASE D AS PROVENANCE. These no longer decide when a release
  -- may proceed — `owner_notice_release_authority` does — but removing them would make one path
  -- easier, and Phase D makes no path easier. A window whose lifecycle row cannot even name the
  -- dispatch that opened it cannot elapse into disclosure.
  if v_row.owner_notified_at is null or v_row.safety_notification_id is null then
    raise exception 'owner_not_notified' using errcode = 'P0001';
  end if;

  select c.id, c.decided_by, c.decided_at into v_case, v_reviewer_a, v_verified
    from public.death_verification_cases c
   where c.estate_id = p_estate and c.status = 'verified'
   order by c.decided_at desc
   limit 1;
  if v_case is null then
    raise exception 'no_verified_case' using errcode = 'P0001';
  end if;
  if v_reviewer_a is null then
    raise exception 'reviewer_a_unresolved' using errcode = 'P0001';
  end if;

  -- ★ D1, ENFORCED HERE AND AGAIN BY THE TABLE CONSTRAINT BELOW.
  if v_uid = v_reviewer_a then
    raise exception 'two_person_rule_violated' using errcode = 'P0001';
  end if;

  -- ════════════════════════════════════════════════════════════════════════════════════════════
  -- ★ PHASE D — THE OWNER-NOTICE ACCEPTANCE AUTHORITY AND THE RELEASE CLOCK, IN ONE CONSULTATION.
  -- ════════════════════════════════════════════════════════════════════════════════════════════
  --
  -- The verdict is read under the lifecycle row lock taken above, so the state it describes cannot
  -- move between the answer and the write. `owner_notice_release_authority` is `stable` — it reads
  -- the calling statement's snapshot — which is correct here for exactly that reason, and is the
  -- same contract `reissue_owner_safety_notice` has with `owner_notice_reissue_assessment`.
  --
  -- ★ THE REFUSAL CODE IS RAISED VERBATIM, NEVER TRANSLATED. A `case` expression mapping the
  -- authority's codes onto this routine's own sentinels would be a second policy: the console reads
  -- the authority directly, so a translation layer here is precisely how the two come to describe
  -- the same estate differently. `release_window_not_configured` and `release_window_not_elapsed`
  -- are therefore still the strings a caller sees — they are now the AUTHORITY's names for them.
  v_auth := public.owner_notice_release_authority(v_case);
  if not (v_auth ->> 'ready')::boolean then
    raise exception '%', v_auth ->> 'refusal_code' using errcode = 'P0001';
  end if;
  -- Read back for the audit, from the SAME verdict that authorized this release rather than from a
  -- second lookup that could describe a different row.
  v_duration := (v_auth ->> 'window_duration')::interval;

  insert into public.release_authorizations
    (estate_id, case_id, reviewer_a, reviewer_b, verified_at, authorized_at, released_at, audit_reason)
  values (p_estate, v_case, v_reviewer_a, v_uid, v_verified, now(), now(), p_reason);

  perform public.apply_estate_lifecycle_transition(
    p_estate, 'released', v_case, 'two_person_release');

  update public.estate_lifecycle
     set released_at = now()
   where estate_id = p_estate;

  insert into public.audit_logs (actor_id, estate_id, action, target_table, target_id, metadata, source)
  values (v_uid, p_estate, 'death_process.released', 'release_authorizations', v_case,
          jsonb_build_object('severity', 'high', 'case_id', v_case,
                            'reviewer_a', v_reviewer_a, 'reviewer_b', v_uid,
                            'verified_at', v_verified,
                            -- PROVENANCE, and labelled as such. It is no longer the clock, and an
                            -- investigator reconstructing a disputed release a year later must be
                            -- able to see which instant the seven days actually ran from.
                            'owner_notified_at', v_row.owner_notified_at,
                            -- ★ THE FACT THE RELEASE RESTED ON, and the two derived instants, taken
                            -- from the verdict that authorized it. Provider acceptance — never
                            -- delivery, and the key name says so.
                            'notice_accepted_at', v_auth ->> 'notice_accepted_at',
                            'release_eligible_at', v_auth ->> 'release_eligible_at',
                            'notice_id', v_auth ->> 'notice_id',
                            'notice_generation', v_auth ->> 'generation',
                            'window_duration', v_duration::text,
                            'audit_reason', p_reason),
          'admin');
  return 'released';
end $$;


ALTER FUNCTION "public"."authorize_release"("p_estate" "uuid", "p_reason" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."authorize_release"("p_estate" "uuid", "p_reason" "text") IS 'THE release transition (Phase 11-F, re-anchored 11-OC/D): challenge_window -> released, by a SECOND platform operator. Requires admin gate, a non-empty audit reason, the dispatch provenance on the lifecycle row, a verified case, reviewer_b <> reviewer_a where reviewer_a is DERIVED from the case decider, and — from Phase D — owner_notice_release_authority: the CURRENT generation of the CURRENT case episode must carry notice_accepted_at (PROVIDER ACCEPTANCE, never mailbox delivery) and the window must be STRICTLY elapsed from THAT instant, not from owner_notified_at. No status string participates. Ties go to the owner challenge. Records a release_authorizations row whose CHECK constraint makes a single-reviewer release unwritable by any path. Creates no grant, tier, membership or designation.';



CREATE OR REPLACE FUNCTION "public"."begin_challenge_window"("p_estate" "uuid") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid   uuid;
  v_state text;
  v_case  uuid;
  v_row   public.estate_lifecycle%rowtype;
begin
  perform public.admin_require_gate();
  v_uid := auth.uid();

  select l.* into v_row
    from public.estate_lifecycle l
   where l.estate_id = p_estate
   for update;
  v_state := v_row.state;

  if v_state = 'challenge_window' then
    return 'challenge_window'; -- idempotent replay
  end if;
  if v_state is distinct from 'owner_notification_dispatched' then
    raise exception 'invalid_window_state' using errcode = 'P0001';
  end if;

  -- Belt beside the state machine: the dispatch facts must actually be on the row.
  if v_row.owner_notified_at is null or v_row.safety_notification_id is null then
    raise exception 'owner_not_notified' using errcode = 'P0001';
  end if;

  -- ★ THE EPISODE IS RESOLVED BEFORE THE NOTICE IS LOOKED FOR, AND THAT ORDER IS THE FIX. The
  -- pre-Phase-D body checked the outbox by ESTATE and resolved the case afterwards, so a notice
  -- belonging to any death process this estate had ever run satisfied the guard.
  select c.id into v_case
    from public.death_verification_cases c
   where c.estate_id = p_estate and c.status = 'verified'
   order by c.decided_at desc
   limit 1;
  if v_case is null then
    raise exception 'no_verified_case' using errcode = 'P0001';
  end if;

  -- ★ PHASE D (D7) — A COMMITTED EMAIL NOTICE FOR **THIS** EPISODE, AND NOTHING STRONGER.
  --
  -- Case-scoped, so a notice from a prior rejected process cannot open a window under a new case.
  -- Current generation (`superseded_by is null`), so this anchors on the same structural invariant
  -- the release door uses — and, because supersession always writes a successor, "a current
  -- generation exists" is equivalent to "any generation exists" for the episode. NO status string
  -- and NO `notice_accepted_at`: the initial dispatch is normally still `queued` at this instant
  -- (the drain is asynchronous), and gating the owner's own protection on a provider would be a
  -- release-door policy applied to a door that discloses nothing.
  if not exists (
    select 1 from public.owner_notice_outbox o
     where o.case_id = v_case
       and o.channel = 'email'
       and o.notice_kind = any (public.owner_notice_episode_kinds())
       and o.superseded_by is null
  ) then
    raise exception 'no_current_notice' using errcode = 'P0001';
  end if;

  perform public.apply_estate_lifecycle_transition(
    p_estate, 'challenge_window', v_case, 'window_opened');

  update public.estate_lifecycle
     set challenge_window_started_at = now()
   where estate_id = p_estate;

  insert into public.audit_logs (actor_id, estate_id, action, target_table, target_id, metadata, source)
  values (v_uid, p_estate, 'death_process.window_opened', 'estate_lifecycle', v_case,
          jsonb_build_object('severity', 'high', 'case_id', v_case,
                            'owner_notified_at', v_row.owner_notified_at),
          'admin');
  return 'challenge_window';
end $$;


ALTER FUNCTION "public"."begin_challenge_window"("p_estate" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."begin_challenge_window"("p_estate" "uuid") IS 'Opens the owner-challenge window (Phase 11-E, rewritten 11-F, re-scoped 11-OC/D). Its ONLY legal input is owner_notification_dispatched — the death_verified -> challenge_window edge was deleted, so a window cannot open on an un-notified owner even by mistake. Phase D replaced the inert estate-scoped status <> cancelled predicate with the fact it needs: a committed email notice for the CURRENT case episode (no_current_notice otherwise). It deliberately does NOT require notice_accepted_at — opening the window discloses nothing and the initial notice is normally still queued. Admin-gated; idempotent; discloses nothing.';



CREATE OR REPLACE FUNCTION "public"."bind_invitation_token"("p_token" "text") RETURNS TABLE("membership_id" "uuid", "estate_id" "uuid", "estate_display_name" "text", "role" "text", "status" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_user uuid := auth.uid(); v_hash text; v_inv record; v_user_email text; v_user_phone text; v_membership_id uuid;
begin
  if v_user is null then raise exception 'unauthenticated' using errcode = '42501'; end if;
  if p_token is null or length(p_token) < 16 or length(p_token) > 512 then
    raise exception 'invalid_token' using errcode = 'P0001';
  end if;
  v_hash := encode(digest(p_token, 'sha256'), 'hex');
  select * into v_inv from public.invitations where token_hash = v_hash for update;
  if not found then raise exception 'invitation_not_found' using errcode = 'P0002'; end if;
  if v_inv.expires_at < now() then raise exception 'invitation_expired' using errcode = 'P0003'; end if;
  if v_inv.status = 'revoked' then raise exception 'invitation_revoked' using errcode = 'P0004'; end if;

  select profiles.email, profiles.phone into v_user_email, v_user_phone from public.profiles where profiles.id = v_user;
  if not ((v_inv.invitee_email is not null and lower(v_inv.invitee_email) = lower(coalesce(v_user_email,'')))
       or (v_inv.invitee_phone is not null and v_inv.invitee_phone = coalesce(v_user_phone,''))) then
    raise exception 'invitation_not_for_caller' using errcode = 'P0006';
  end if;

  -- Idempotency keys on the invitation's OWN accepted_by (authoritative), NOT the membership's
  -- source_invitation_id (see accept_invitation) — a reconciled membership has a different/NULL source.
  if v_inv.status = 'accepted' then
    if v_inv.accepted_by = v_user then
      perform public.provision_from_invitation(v_inv.id, v_user);   -- idempotent self-heal (re-stamps a missing designation)
      select em.id into v_membership_id from public.estate_memberships em
       where em.estate_id = v_inv.estate_id and em.user_id = v_user;
          -- ★ PHASE 11-MC: A FIDUCIARY ACCEPTANCE HAS NO MEMBERSHIP, SO IT REPORTS NONE.
      -- `provision_from_invitation` no longer creates a membership for an executor/trustee invitation,
      -- so `v_membership_id` is NULL for a recipient who holds no independent access class. Returning
      -- the invitation's stale `proposed_role` and a hardcoded 'approved' would assert an approved
      -- beneficiary membership that does not exist — the exact fiction this phase removes, restated on
      -- the way out. Role and status are NULL together with the membership id; the fiduciary authority
      -- is reported by `get_my_fiduciary_estates`, which is the surface that owns it.
  return query select v_membership_id, v_inv.estate_id,
        (select e.name from public.estates e where e.id = v_inv.estate_id),
        case when v_membership_id is null then null else v_inv.proposed_role::text end,
        case when v_membership_id is null then null else 'approved'::text end;
      return;
    else
      raise exception 'invitation_already_accepted' using errcode = 'P0005';
    end if;
  end if;

  update public.invitations set status='accepted', accepted_by=v_user, accepted_at=now(), updated_at=now() where id=v_inv.id;
  v_membership_id := public.provision_from_invitation(v_inv.id, v_user);
  perform public.write_audit('invitation.bound', 'estate_memberships', v_membership_id, v_inv.estate_id,
    jsonb_build_object('token_fingerprint', substr(v_hash,1,12), 'invitation_id', v_inv.id));
  return query select v_membership_id, v_inv.estate_id,
    (select e.name from public.estates e where e.id = v_inv.estate_id),
    case when v_membership_id is null then null else v_inv.proposed_role::text end,
    case when v_membership_id is null then null else 'approved'::text end;
end;
$$;


ALTER FUNCTION "public"."bind_invitation_token"("p_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."bump_taxonomy_vocabulary_version"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  -- Statement-level AFTER trigger: any VALUE change to a taxonomy table invalidates client caches.
  update public.taxonomy_version set vocabulary_version = vocabulary_version + 1, updated_at = now() where id = 1;
  return null;
end;
$$;


ALTER FUNCTION "public"."bump_taxonomy_vocabulary_version"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."can_access_document"("p_document_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid    uuid := auth.uid();
  v_estate uuid;
  v_sens   text;
  g        record;
begin
  if v_uid is null then
    return false;
  end if;

  select estate_id, sensitivity into v_estate, v_sens
  from public.documents
  where id = p_document_id;

  if v_estate is null then
    return false;
  end if;

  -- Owner inherent (A.1) — no grant row needed.
  if public.is_estate_owner(v_estate) then
    return true;
  end if;

  -- Non-owner: per-document grant first...
  select grantee_role, visibility_tier, release_condition, approved_at
    into g
  from public.access_grants
  where estate_id = v_estate
    and grantee_user_id = v_uid
    and status = 'active'
    and document_id = p_document_id
  limit 1;

  -- ...then category 'estate_documents' fallback (the access-request grant lands here).
  if not found then
    select grantee_role, visibility_tier, release_condition, approved_at
      into g
    from public.access_grants
    where estate_id = v_estate
      and grantee_user_id = v_uid
      and status = 'active'
      and category = 'estate_documents'
    limit 1;
  end if;

  if not found then
    return false;                                            -- default-deny (A.5)
  end if;

  -- Ceiling re-check against the document's CURRENT sensitivity (A.3). For a CATEGORY
  -- grant this is the ONLY ceiling enforcement (the write-time trigger no-ops on category
  -- grants), so a sealed/restricted doc stays hidden here even with the category grant.
  if not public.document_grantable(g.grantee_role, v_sens) then
    return false;
  end if;

  if g.visibility_tier = 'hidden' then
    return false;
  end if;

  -- ★ THE CANONICAL RELEASE PREDICATE (Phase 11-B) — was seven scattered copies, now one call.
  -- Since 11-D it consumes the AUTHORITATIVE lifecycle for THIS document's estate, resolved through
  -- the one sanctioned reader: `after_verified_death` opens exactly while the estate is
  -- death_verified. 'never', incapacity, the legacy fused value, identity and claim conditions stay
  -- dormant-deny (A.4), and an unknown condition or lifecycle refuses. No comparison happens here —
  -- the lifecycle is an ARGUMENT, and the policy stays in the predicate.
  return public.release_condition_satisfied(
    g.release_condition, g.approved_at, 'standard', public.estate_lifecycle_state(v_estate));
end;
$$;


ALTER FUNCTION "public"."can_access_document"("p_document_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cancel_death_verification_case"("p_case" "uuid") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid          uuid := auth.uid();
  v_estate       uuid;
  v_status       text;
  v_initiated_by uuid;
begin
  if v_uid is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;

  select c.estate_id, c.status, c.initiated_by
    into v_estate, v_status, v_initiated_by
    from public.death_verification_cases c
   where c.id = p_case
   for update;
  if v_estate is null
     or v_initiated_by <> v_uid
     or not public.is_estate_executor(v_estate, v_uid) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  if v_status = 'cancelled' then
    return v_status; -- idempotent replay: no re-stamp, no re-audit (the claim-decision precedent)
  end if;
  if v_status <> 'open' then
    raise exception 'case_already_decided' using errcode = 'P0001';
  end if;

  update public.death_verification_cases
     set status = 'cancelled', updated_at = now()
   where id = p_case;

  perform public.apply_estate_lifecycle_transition(v_estate, 'active', p_case, 'case_cancelled');

  perform public.write_audit(
    'death_case.cancelled', 'death_verification_cases', p_case, v_estate,
    jsonb_build_object('case_id', p_case));
  return 'cancelled';
end $$;


ALTER FUNCTION "public"."cancel_death_verification_case"("p_case" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."challenge_death_process"("p_estate" "uuid") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid       uuid := auth.uid();
  v_state     text;
  -- ★ Phase 11-L. The initiator of the case THIS CALL halts, captured from the UPDATE's own
  -- RETURNING rather than looked up afterwards. A separate SELECT could name a case this call did
  -- not touch — one already halted, or one halted by a concurrent transaction — and would notify
  -- someone about a process that is still running, or notify twice about one that stopped once.
  v_initiator uuid;
begin
  if v_uid is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;
  if not public.is_estate_owner(p_estate) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  select l.state into v_state
    from public.estate_lifecycle l
   where l.estate_id = p_estate
   for update;
  if v_state is null then
    v_state := 'active';
  end if;

  if v_state = 'challenge_halted' then
    return 'challenge_halted'; -- idempotent replay: no re-stamp, no re-audit
  end if;
  if v_state = 'active' then
    raise exception 'nothing_to_challenge' using errcode = 'P0001';
  end if;
  -- Too late is stated honestly (R15): what was disclosed cannot be undisclosed, and pretending
  -- a halt succeeded would claim otherwise. The owner is authorized to know this about their
  -- own estate.
  if v_state = 'released' then
    raise exception 'already_released' using errcode = 'P0001';
  end if;

  perform public.apply_estate_lifecycle_transition(
    p_estate, 'challenge_halted', null, 'owner_challenge');

  update public.estate_lifecycle
     set halted_at = now()
   where estate_id = p_estate;

  -- The live case is halted — distinct from 'cancelled' (initiator withdrew): the owner said no.
  --
  -- ★ PHASE 11-NR — THE SET IS ('open','verified'), AND 'open' ALONE WAS THE DEFECT. This predicate
  -- read `status = 'open'`, which is the case status at exactly ONE of the four lifecycle states this
  -- routine can be reached from. The Branch A production drill measured the consequence: on the
  -- canonical operator-driven path the estate reached challenge_halted while its case row stayed
  -- 'verified', `v_initiator` came back NULL, and the 11-L halt notification — the entire deliverable
  -- of that phase — was never emitted to anybody. The case also stayed in the operator's `verified`
  -- work queue, invisible to a `halted` filter, with the queue row stating the contradiction outright.
  --
  -- The set is CLOSED and derived from the transition map, never "every row for this estate":
  --
  --   death_verification_pending    → case is 'open'      (initiate)
  --   death_verified                → case is 'verified'  (admin_decide 'verify')
  --   owner_notification_dispatched → case is 'verified'  (dispatch requires a verified case)
  --   challenge_window              → case is 'verified'  (begin_challenge_window requires one)
  --
  -- 'rejected' and 'cancelled' both return the lifecycle to `active`, where this routine has already
  -- raised `nothing_to_challenge` — they are decided history and settling them would overwrite an
  -- adjudication that did happen. 'halted' is excluded as a SECOND, independent guard against a
  -- re-stamp: the idempotent return above already refuses to reach this statement.
  --
  -- ★ AND IT STILL MATCHES AT MOST ONE ROW, WHICH NO LONGER FOLLOWS FROM THE INDEX ALONE.
  -- `death_verification_cases_one_open_per_estate` makes 'open' unique per estate; 'verified' is
  -- unique per estate for a different reason, and it is the state machine that supplies it. A
  -- verified case pins the lifecycle at death_verified or beyond, `initiate_death_verification_case`
  -- refuses unless the lifecycle is `active`, and no edge returns there from death_verified — so a
  -- second case cannot be opened once one is verified, and an 'open' case cannot coexist with a
  -- 'verified' one. Historical 'rejected' / 'cancelled' rows DO coexist and are excluded by the
  -- predicate. `into` therefore still has no set to choose from arbitrarily, and
  -- `release_safety_authorization.sql` §8 proves it on an estate that actually carries a decided
  -- historical case beside the live one.
  --
  -- ★ RETURNING gives us the initiator of the case actually settled HERE. A separate SELECT could
  -- name a case this call did not touch — one already halted, one from a prior rejected attempt, or
  -- one halted by a concurrent transaction — and would notify the wrong person, or notify twice
  -- about a process that stopped once.
  update public.death_verification_cases
     set status = 'halted', updated_at = now()
   where estate_id = p_estate and status in ('open', 'verified')
  returning initiated_by into v_initiator;

  -- ────────────────────────────────────────────────────────────────────────────────────────────
  -- ★ PHASE 11-L — TELL THE INITIATING FIDUCIARY THAT THEIR PROCESS STOPPED.
  -- ────────────────────────────────────────────────────────────────────────────────────────────
  --
  -- ★ RECIPIENT COMES FROM WORKFLOW STATE, NEVER FROM A CALLER. `p_estate` is the only input to
  -- this routine; there is no recipient parameter and therefore nothing for a client to point at
  -- someone else. `initiated_by` is `not null references auth.users(id)` on the case row.
  --
  -- ★ HISTORICAL INITIATOR, AND THE CASE MODEL SETTLES IT RATHER THAN A GUESS. 0052 states that
  -- `initiator_designation_id` / `initiator_capacity` are "a snapshot of fact ('this person acted
  -- as executor'), never an authority the case can later re-assert — a revoked designee does not
  -- keep acting because a case remembers them." So a designation revoked after initiation must NOT
  -- suppress this message: the notification asserts no authority, it reports one fact about
  -- something the recipient personally did. They already know they initiated it; being told it
  -- stopped discloses nothing they did not bring with them. Re-deriving a LIVE designation here
  -- would instead silently drop the message for exactly the person owed it.
  --
  -- ★ IT CANNOT REACH THE OWNER. The owner is the caller (is_estate_owner above), and the guard
  -- below excludes them explicitly. That covers the degenerate case where an estate owner is also
  -- a designee on their own estate: they would otherwise receive claimant-facing copy about their
  -- own halt, which reads as a message from a stranger about their own death process.
  --
  -- ★ NO DEEP LINK, DELIBERATELY. The recipient's own surface is `/executor`
  -- (`get_executor_workspace`, which refuses a revoked designee) — but the RN deep-link allowlist
  -- in `features/notifications/actions.ts` has no `afterworth://executor` key, and a link that is
  -- not in the allowlist resolves to null and renders as a non-navigating row anyway. Passing an
  -- unmatched string would be inventing a route rather than using one. Wiring that destination is
  -- a bounded mobile follow-up, recorded in docs/phase11l-halt-notification.md §6.
  --
  -- ★ EMISSION IS INSIDE THIS TRANSACTION, so it commits with the halt or not at all — no
  -- notification can precede or outlive the state change it describes. The idempotent-replay
  -- return above happens BEFORE any of this, so a second challenge emits nothing. And when no case
  -- was open, `v_initiator` is null and nothing is emitted: a halt with no initiated process to
  -- report has nobody to report it to.
  if v_initiator is not null and v_initiator <> v_uid then
    perform public.emit_lifecycle_notification(
      v_initiator, p_estate, 'death_process.halted', null);
  end if;

  -- ★ NO PROVENANCE. The fact recorded is THAT the owner challenged and from which state — never
  -- a channel, a device, an address, or a location (§17: provenance is security-sensitive
  -- information about a living owner).
  perform public.write_audit(
    'death_process.challenged', 'estate_lifecycle', null, p_estate,
    jsonb_build_object('severity', 'high', 'from_state', v_state));
  return 'challenge_halted';
end $$;


ALTER FUNCTION "public"."challenge_death_process"("p_estate" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."challenge_death_process"("p_estate" "uuid") IS 'The owner challenge (Phase 11-E, R12-R14): the authenticated estate owner halts a pre-released death process in one action — no evidence, no review, no waiting, no designation. Wins ties (release requires the window strictly elapsed; both serialize on the lifecycle row lock). Produces challenge_halted, terminal in 11-E. Records no provenance beyond the act itself.';



CREATE OR REPLACE FUNCTION "public"."challenge_window_duration"() RETURNS interval
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select p.challenge_window from public.release_safety_policy p where p.id;
$$;


ALTER FUNCTION "public"."challenge_window_duration"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."challenge_window_duration"() IS 'The configured owner-challenge window (Phase 11-E). NULL = not configured = the window never elapses and release refuses. Set only by an explicit, reviewed operator INSERT into release_safety_policy — never seeded by a migration. INTERNAL: clients cannot read the safety clock; the owner surface answers through get_owner_safety_status.';



CREATE OR REPLACE FUNCTION "public"."check_primary_user_matches_owner"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_owner_id uuid;
begin
  -- Only validate primary_user/approved rows. All other combinations
  -- skip this check (no constraint on beneficiary/professional_delegate
  -- rows, or on pending/revoked primary_user rows if those ever exist).
  if new.role <> 'primary_user' or new.status <> 'approved' then
    return new;
  end if;

  select owner_id into v_owner_id
  from public.estates
  where id = new.estate_id;

  if v_owner_id is null then
    raise exception 'estate_not_found'
      using errcode = 'P0007';
  end if;

  if new.user_id <> v_owner_id then
    raise exception 'primary_user_mismatch: estate_memberships.user_id (%) must match estates.owner_id (%) for role=primary_user',
      new.user_id, v_owner_id
      using errcode = 'P0008';
  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."check_primary_user_matches_owner"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."claim_invitation_deliveries"("p_max" integer DEFAULT 25, "p_outbox_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("outbox_id" "uuid", "invitation_id" "uuid", "delivery_generation" integer, "attempts" integer)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_max int;
begin
  v_max := case when p_outbox_id is not null then 1
                else least(greatest(coalesce(p_max, 25), 1), 100) end;

  return query
  with candidate as (
    select o.id
      from public.invitation_delivery_outbox o
     where (p_outbox_id is null or o.id = p_outbox_id)
       and ((o.status = 'queued')
         or (o.status = 'retryPending' and coalesce(o.next_attempt_at, o.requested_at) <= now()))
     order by o.requested_at
     limit v_max
     for update skip locked            -- ★ concurrency spine: never block, never hand out twice
  ),
  -- Settle anything whose invitation is no longer actionable. It never reaches the worker.
  cancelled as (
    update public.invitation_delivery_outbox o
       set status = 'cancelled',
           failure_class = null,
           last_outcome_at = now()
      from public.invitations i
     where o.id in (select c.id from candidate c)
       and i.id = o.invitation_id
       and public.invitation_effective_status(i.status, i.expires_at) not in ('pending', 'matched')
    returning o.id
  ),
  claimed as (
    update public.invitation_delivery_outbox o
       set status = 'processing',
           attempts = o.attempts + 1,
           claimed_at = now()
     where o.id in (select c.id from candidate c)
       and o.id not in (select x.id from cancelled x)
    returning o.id, o.invitation_id, o.delivery_generation, o.attempts
  )
  select cl.id, cl.invitation_id, cl.delivery_generation, cl.attempts from claimed cl;
end;
$$;


ALTER FUNCTION "public"."claim_invitation_deliveries"("p_max" integer, "p_outbox_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."claim_owner_notices"("p_max" integer DEFAULT 25) RETURNS TABLE("id" "uuid", "estate_id" "uuid", "recipient" "text", "notice_kind" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_gate interval;
  v_max  int;
  -- ★ PHASE 11-OBR / OB-1 — the claim visibility timeout, read from the ONE place that defines it
  -- (`owner_notice_claim_visibility()`), so this routine and `owner_notice_census` can never
  -- disagree about which rows are stale.
  v_visibility interval := public.owner_notice_claim_visibility();
begin
  v_gate := public.owner_notice_age_gate();
  if v_gate is null then
    -- Fail-closed: with no configured window there is no defensible notion of "too old", so the
    -- queue is not drained at all rather than drained by a guess.
    raise exception 'owner_notice_age_gate_unconfigured' using errcode = 'P0001';
  end if;
  v_max := least(greatest(coalesce(p_max, 25), 1), 100);

  -- STALE FIRST, so a stale row can never be claimed for sending by the same call.
  update public.owner_notice_outbox o
     set status = 'failedPermanent',
         failure_class = 'stale_beyond_age_gate',
         next_attempt_at = null
   where o.status in ('queued', 'processing')
     and o.requested_at < now() - v_gate;

  -- ────────────────────────────────────────────────────────────────────────────────────────────
  -- ★ THE CLAIM SET IS CLOSED AND WRITTEN OUT AS TWO NAMED BRANCHES (OB-1).
  -- ────────────────────────────────────────────────────────────────────────────────────────────
  --
  --   A · queued           — claimable immediately, subject to its backoff. Unchanged.
  --   B · processing, stale — claimed by a worker that never settled it. Reclaimable ONLY once the
  --                           claim is older than the visibility timeout.
  --
  -- Every other status is excluded, and excluded BY NAME rather than by falling through a
  -- `status <> terminal` predicate. `dispatched`, `outcomeUncertain`, `failedPermanent` and
  -- `cancelled` are all settled: two of them are terminal precisely because the message may already
  -- be in the owner's inbox, and a broad "not terminal" test is exactly how a future status added to
  -- the CHECK constraint would silently become re-sendable.
  --
  -- ★ `claimed_at IS NULL` ON A `processing` ROW IS RECLAIMABLE, AND THAT IS A DECISION.
  -- Such a row was claimed before `claimed_at` existed (migration 0057), which means it has been
  -- sitting in `processing` since at least the deployment — already far beyond any timeout. Treating
  -- NULL as "infinitely stale" is what lets the DEPLOYED mechanism recover the rows the defect
  -- already stranded, rather than requiring a hand-written repair for each one. It is a class rule;
  -- no row is named.
  --
  -- ★ WHAT A RECLAIM COSTS, STATED HONESTLY. A reclaimed row is re-sent under the SAME deterministic
  -- `Idempotency-Key` (`afterworth/owner-notice/<row id>`, built in `lib/ownerNotices/drain.ts` from
  -- the row id with no generation counter), so the provider is asked to no-op a repeat. That is the
  -- same operation the worker ALREADY performs when it retries an ambiguous first attempt — this
  -- does not re-mint a message, it replays one. It is nevertheless AT-LEAST-ONCE, not exactly-once:
  -- the provider's dedupe retention is a vendor property this repository does not pin, and a reclaim
  -- that lands outside it could produce a second copy. See docs/phase11ob-owner-notice-delivery-defect.md.
  return query
  with candidate as (
    select o.id
      from public.owner_notice_outbox o
     where o.requested_at >= now() - v_gate
       and (
         -- A · the ordinary queue
         (o.status = 'queued'
          and (o.next_attempt_at is null or o.next_attempt_at <= now()))
         -- B · an abandoned claim
         or (o.status = 'processing'
             and (o.claimed_at is null or o.claimed_at < now() - v_visibility))
       )
     order by o.requested_at
     limit v_max
     for update skip locked
  )
  update public.owner_notice_outbox o
     set status     = 'processing',
         attempts   = o.attempts + 1,
         -- Stamped on EVERY claim, first or repeat: the timeout must run from THIS claim, or a
         -- reclaimed row would be instantly reclaimable again by the next concurrent drain.
         claimed_at = now()
    from candidate c
   where o.id = c.id
  returning o.id, o.estate_id, o.recipient, o.notice_kind;
end $$;


ALTER FUNCTION "public"."claim_owner_notices"("p_max" integer) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."claim_owner_notices"("p_max" integer) IS 'Claims owner safety notices for delivery, applying the age gate FIRST (Phase 11-F, Stage 3): rows older than the gate are marked failedPermanent/stale_beyond_age_gate and are never sent and never deleted. Fresh rows are claimed with skip-locked so concurrent drains cannot double-send. Refuses entirely when the age gate is unconfigured. service_role ONLY (Phase 11-K wired the drain); no client role may claim.';



CREATE OR REPLACE FUNCTION "public"."create_access_request"("p_estate_id" "uuid", "p_category" "text" DEFAULT 'estate_documents'::"text", "p_reason" "text" DEFAULT NULL::"text") RETURNS SETOF "public"."access_requests"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_user uuid := auth.uid();
  v_requester_role text;
  v_id uuid;
begin
  -- Auth null-guard.
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;

  -- Category validation (V1: estate_documents only). Belt-and-suspenders with the table
  -- CHECK — a clean 400 instead of a raw constraint error.
  if p_category is distinct from 'estate_documents' then
    raise exception 'unsupported request category';  -- P0001 -> 400
  end if;

  -- MEMBER GATE + ROLE CAPTURE in ONE lookup (privilege boundary; DEFINER bypasses RLS, so
  -- this explicit check IS the access boundary). The ownership exclusion stays IN the WHERE
  -- (NOT a post-LIMIT check): a single (estate, user) is NOT guaranteed to have only one
  -- approved membership (accept_invitation inserts with no (estate,user) uniqueness; V2 adds
  -- more ownership roles), so a status-only select + post-check would be nondeterministic —
  -- it could grab an ownership row and wrongly reject a user who also has a non-ownership row.
  -- Filtering here makes this provably equivalent to the original EXISTS (passes iff an
  -- approved NON-ownership membership exists) AND captures that surviving role to stamp.
  select m.role into v_requester_role
  from public.estate_memberships m
  where m.estate_id = p_estate_id
    and m.user_id = v_user
    and m.status = 'approved'
    and not public.is_ownership_role(m.role)
  limit 1;

  if v_requester_role is null then
    raise exception 'not an estate member eligible to request access'
      using errcode = '42501';
  end if;

  -- Insert. requester_user_id + requester_role STAMPED server-side (never params). The
  -- one-pending partial unique fires here; surface a readable 409.
  begin
    insert into public.access_requests
      (estate_id, requester_user_id, requester_role, category, reason, status)
    values
      (p_estate_id, v_user, v_requester_role, p_category, p_reason, 'pending')
    returning id into v_id;
  exception
    when unique_violation then
      raise exception
        'a pending access request already exists for this category; await a decision'
        using errcode = '23505';   -- -> 409 Conflict
  end;

  perform public.write_audit(
    'access_request.created',
    'access_requests',
    v_id,
    p_estate_id,
    jsonb_build_object('category', p_category, 'requester_role', v_requester_role)
  );

  -- ★ PHASE 10-E — the OWNER learns a request is waiting. Emitted AFTER the insert succeeded, in the
  -- SAME transaction: if the insert had raised (the one-pending unique violation above), control
  -- never reaches here, and if anything later rolls the transaction back the notification goes with
  -- it. The recipient comes from `estates.owner_id`, never from a capability combination.
  perform public.emit_lifecycle_notification(
    public.estate_owner_user_id(p_estate_id),
    p_estate_id,
    'access_request.created',
    'afterworth://owner-review'
  );

  return query select r.* from public.access_requests r where r.id = v_id;
end;
$$;


ALTER FUNCTION "public"."create_access_request"("p_estate_id" "uuid", "p_category" "text", "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_asset_grant"("p_estate_id" "uuid", "p_grantee_user_id" "uuid", "p_grantee_role" "text", "p_category" "text", "p_visibility_tier" "text", "p_release_condition" "text", "p_professional_type" "text" DEFAULT NULL::"text", "p_requires_step_up" boolean DEFAULT false) RETURNS SETOF "public"."access_grants"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_user uuid := auth.uid();
  v_id uuid;
begin
  -- Auth null-guard.
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;

  -- SECURITY SPINE (privilege-escalation gate). DEFINER bypasses RLS, so this explicit owner-check
  -- IS the access boundary and MUST precede any insert.
  if not public.is_estate_owner(p_estate_id) then
    raise exception 'not estate owner' using errcode = '42501';
  end if;

  -- No grants to owners (self, or any ownership-role member) — inherent access.
  if p_grantee_user_id = v_user
     or exists (
       select 1 from public.estate_memberships m
       where m.estate_id = p_estate_id
         and m.user_id = p_grantee_user_id
         and public.is_ownership_role(m.role)
     ) then
    raise exception 'cannot grant access to an owner; owners have inherent access';  -- P0001 -> 400
  end if;

  -- Category must be a real ASSET category (defense-in-depth beyond the access_grants.category CHECK;
  -- the RPC is the security boundary and may be called directly).
  --
  -- ★ `estate_inventory` IS IN THIS LIST IN VERSION CONTROL — AND UNTIL PHASE 10-E IT WAS NOT.
  --
  -- Migration 0049 adds it to the DEPLOYED body by string surgery: it reads `pg_get_functiondef`,
  -- replaces this exact literal, and re-executes. So production has had the widened list for weeks
  -- while this file — the supposed source of truth — still refused the category.
  --
  -- That is the live-only-object trap this repository has been bitten by repeatedly (handle_new_user,
  -- is_estate_owner, the whole 0009 notifications table), except inverted and more dangerous: the
  -- object WAS in version control, and the version-controlled copy was WRONG. Re-applying this file
  -- would have silently reverted Phase 9/10-A grantability, and nothing would have caught it — the
  -- deployed-contract verifier checks `asset_category_grantable`, which is a DIFFERENT function and
  -- would have stayed green.
  --
  -- It became reachable in Phase 10-E because this file now ships in a bundle. Fixed at the source
  -- rather than by ordering the bundles carefully, because an ordering rule is a thing to remember
  -- and a correct source file is not. 0049's patch is guarded by `if position('estate_inventory' in
  -- v_src) = 0`, so it now finds the category already present and does nothing — still correct for a
  -- database that predates this fix, a no-op for one that does not.
  if p_category not in
     ('account_balances', 'institution_names', 'total_asset_value', 'linked_account_details', 'estate_inventory') then
    raise exception 'invalid asset category: %', p_category;  -- P0001 -> 400
  end if;

  -- ★ WRITE-TIME RELEASE VOCABULARY (Phase 11-B). The table CHECK still accepts the deprecated
  --   `after_verified_death_or_incapacity` so stored rows stay readable and unreinterpreted; this
  --   gate is what stops a NEW row from carrying the fused ambiguity. Death and incapacity are now
  --   expressible separately — and neither is satisfied by anything, so this widens what an owner
  --   may EXPRESS, never what a grantee may SEE.
  if not public.release_condition_writable(p_release_condition) then
    raise exception 'unsupported release condition: %', p_release_condition;  -- P0001 -> 400
  end if;

  -- ★ WRITE-TIME CEILING — reject an over-ceiling grant before storing it (the trigger skips category
  --   grants). Mirrors the read-time clamp in list_estate_assets: e.g. beneficiary + account_balances
  --   + full_detail -> asset_category_grantable = false -> rejected here.
  if not public.asset_category_grantable(p_grantee_role, p_category, p_visibility_tier) then
    raise exception 'asset grant ceiling: role % cannot be granted tier % for category %',
      p_grantee_role, p_visibility_tier, p_category
      using errcode = '42501';   -- ceiling violation -> 403 (mirrors document_grantable)
  end if;

  -- Insert (category-scoped: document_id NULL). Table CHECKs + the one-active-grant-per-(estate,
  -- grantee,category) unique index fire regardless of the DEFINER context. Catch the unique
  -- violation and surface a readable 409 (fail, never silent upsert — a silent tier change on a
  -- disclosure grant is dangerous; a tier change is revoke + re-create).
  begin
    insert into public.access_grants
      (estate_id, grantee_user_id, grantee_role, professional_type,
       document_id, category, visibility_tier, release_condition,
       requires_step_up, granted_by_user_id)
    values
      (p_estate_id, p_grantee_user_id, p_grantee_role, p_professional_type,
       null, p_category, p_visibility_tier, p_release_condition,
       p_requires_step_up, v_user)
    returning id into v_id;
  exception
    when unique_violation then
      raise exception
        'an active grant already exists for this category and grantee; revoke it first'
        using errcode = '23505';   -- unique_violation -> 409 Conflict
  end;

  perform public.write_audit(
    'access_grant.created',
    'access_grants',
    v_id,
    p_estate_id,
    jsonb_build_object(
      'grantee_user_id', p_grantee_user_id,
      'grantee_role', p_grantee_role,
      'category', p_category,
      'visibility_tier', p_visibility_tier,
      'release_condition', p_release_condition
    )
  );

  -- ★ PHASE 10-E — REWRITTEN, AND THE PREVIOUS VERSION WAS A LIVE DEFECT ON TWO COUNTS.
  --
  -- It read:
  --     'You''ve been granted access to estate assets (' || p_category || ').'
  --     'afterworth://accounts'
  --     jsonb_build_object('kind','grant_created','grant_id', v_id, 'category', p_category)
  --
  -- 1. It concatenated `p_category` — a backend enum — into user-facing prose. The one lifecycle
  --    notification in production reads "...to estate assets (estate_inventory)." on a real device.
  --    The mobile client HAS an audit forbidding backend vocabulary on screen; it never fired,
  --    because the enum arrived as server-authored copy rather than as a client-rendered value.
  --    This is exactly why copy is now a constant looked up by event name.
  -- 2. `afterworth://accounts` is not a route this app has (the route is `/assets`), so the link was
  --    inert — fail-closed by the client allowlist, but a promise the product could not keep.
  --    The payload additionally carried a raw grant id and category, which nothing needs.
  --
  -- ★ AND IT EMITTED UNCONDITIONALLY, WHICH IS THE MORE SERIOUS HALF. "You have access" was sent for
  -- ANY grant this function created, including a `after_verified_death_or_incapacity` one that
  -- releases nothing and must stay dormant until Phase 11 connects activation to release. The gate
  -- below is the death/claim firewall: a grant that is not live RIGHT NOW produces silence.
  --
  -- ★ THE GATE READS THE STORED ROW, NOT THE PARAMETERS. `status` and `approved_at` are column
  -- DEFAULTS here — the insert names neither — so deciding from `p_release_condition` alone would be
  -- reasoning about the arguments rather than about what was actually written. A future default
  -- change, or a trigger, would silently make the parameter-based answer wrong while looking right.
  if exists (
    select 1 from public.access_grants g
    where g.id = v_id
      and public.notification_grant_is_live(g.status, g.release_condition, g.approved_at)
  ) then
    perform public.emit_lifecycle_notification(
      p_grantee_user_id,
      p_estate_id,
      'access_grant.created',
      public.notification_estate_home(p_estate_id, p_grantee_user_id)
    );
  end if;

  return query select g.* from public.access_grants g where g.id = v_id;
end;
$$;


ALTER FUNCTION "public"."create_asset_grant"("p_estate_id" "uuid", "p_grantee_user_id" "uuid", "p_grantee_role" "text", "p_category" "text", "p_visibility_tier" "text", "p_release_condition" "text", "p_professional_type" "text", "p_requires_step_up" boolean) OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."connections" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "estate_id" "uuid" NOT NULL,
    "provider" "text" NOT NULL,
    "institution_id" "text",
    "institution_name" "text",
    "reference_token" "text" NOT NULL,
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."connections" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_connection"("p_estate_id" "uuid", "p_provider" "text", "p_institution_id" "text", "p_institution_name" "text", "p_reference_token" "text", "p_access_token" "text") RETURNS SETOF "public"."connections"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_user uuid := auth.uid();
  v_id   uuid;
begin
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;
  -- SECURITY SPINE: only the estate owner connects accounts (DEFINER bypasses RLS).
  if not public.is_estate_owner(p_estate_id) then
    raise exception 'not estate owner' using errcode = '42501';
  end if;
  -- aal2 GATE: connecting an account is an owner financial action -> ALWAYS require MFA. UNCONDITIONAL
  -- (no tier — this persists the raw access_token). DEFINER bypasses RLS, so the gate must be HERE.
  perform public.require_aal2();

  insert into public.connections
    (estate_id, provider, institution_id, institution_name, reference_token, status)
  values
    (p_estate_id, p_provider, p_institution_id, p_institution_name, p_reference_token, 'active')
  returning id into v_id;

  -- The access_token lands ONLY here (grant-less table). Same row id as the connection.
  insert into public.connection_secrets (connection_id, provider, access_token)
  values (v_id, p_provider, p_access_token);

  perform public.write_audit(
    'connection.created', 'connections', v_id, p_estate_id,
    jsonb_build_object('provider', p_provider, 'institution_name', p_institution_name)
  );

  return query select c.* from public.connections c where c.id = v_id;
end;
$$;


ALTER FUNCTION "public"."create_connection"("p_estate_id" "uuid", "p_provider" "text", "p_institution_id" "text", "p_institution_name" "text", "p_reference_token" "text", "p_access_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_document_grant"("p_estate_id" "uuid", "p_grantee_user_id" "uuid", "p_grantee_role" "text", "p_document_id" "uuid", "p_visibility_tier" "text", "p_release_condition" "text", "p_professional_type" "text" DEFAULT NULL::"text", "p_requires_step_up" boolean DEFAULT false) RETURNS SETOF "public"."access_grants"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_user uuid := auth.uid();
  v_id uuid;
begin
  -- Auth null-guard.
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;

  -- SECURITY SPINE (privilege-escalation gate). SECURITY DEFINER bypasses RLS, so this
  -- explicit owner-check IS the access boundary and MUST precede any insert.
  if not public.is_estate_owner(p_estate_id) then
    raise exception 'not estate owner' using errcode = '42501';
  end if;

  -- Q1: no grants to owners (self, or any ownership-role member) — inherent access.
  if p_grantee_user_id = v_user
     or exists (
       select 1 from public.estate_memberships m
       where m.estate_id = p_estate_id
         and m.user_id = p_grantee_user_id
         and public.is_ownership_role(m.role)
     ) then
    raise exception 'cannot grant access to an owner; owners have inherent access';
      -- default sqlstate P0001 -> PostgREST 400 (validation)
  end if;

  -- The document must belong to this estate. Prevents inert cross-estate junk rows
  -- (a grant whose estate_id never matches the doc's real estate at read) and turns a
  -- missing/foreign doc into a clean error instead of a confusing ceiling-on-NULL from
  -- the trigger.
  if not exists (
    select 1 from public.documents d
    where d.id = p_document_id and d.estate_id = p_estate_id
  ) then
    raise exception 'document not found in this estate';  -- P0001 -> 400
  end if;

  -- ★ WRITE-TIME RELEASE VOCABULARY (Phase 11-B). The deprecated fused
  --   `after_verified_death_or_incapacity` stays legal in the table CHECK so stored rows remain
  --   readable and unreinterpreted; this gate is what stops a NEW row from carrying the ambiguity.
  --   `after_verified_death` and `after_verified_incapacity` are now expressible and satisfied by
  --   nothing — a widening of what an owner may SAY, never of what a grantee may SEE.
  if not public.release_condition_writable(p_release_condition) then
    raise exception 'unsupported release condition: %', p_release_condition;  -- P0001 -> 400
  end if;

  -- Insert. The ceiling trigger + table CHECKs + unique indexes fire here regardless of
  -- the DEFINER context. Catch the one-active-grant unique violation and surface a
  -- readable error instead of a raw constraint failure (Q4: fail, never silent upsert).
  begin
    insert into public.access_grants
      (estate_id, grantee_user_id, grantee_role, professional_type,
       document_id, category, visibility_tier, release_condition,
       requires_step_up, granted_by_user_id)
    values
      (p_estate_id, p_grantee_user_id, p_grantee_role, p_professional_type,
       p_document_id, null, p_visibility_tier, p_release_condition,
       p_requires_step_up, v_user)
    returning id into v_id;
  exception
    when unique_violation then
      raise exception
        'an active grant already exists for this document and grantee; revoke it first'
        using errcode = '23505';   -- unique_violation -> PostgREST 409 Conflict
  end;

  perform public.write_audit(
    'access_grant.created',
    'access_grants',
    v_id,
    p_estate_id,
    jsonb_build_object(
      'grantee_user_id', p_grantee_user_id,
      'grantee_role', p_grantee_role,
      'document_id', p_document_id,
      'visibility_tier', p_visibility_tier,
      'release_condition', p_release_condition
    )
  );

  -- ★ PHASE 10-E — the GRANTEE learns they have access, but ONLY if they actually do, right now.
  --
  -- A document grant created with `after_owner_approval` confers nothing until it is approved, so
  -- this emits SILENCE for it; `approve_document_grant` is where that person is told. A
  -- death-conditioned or claim-conditioned grant emits silence permanently — nothing here may
  -- announce a release Phase 11 has not built.
  --
  -- The gate reads the STORED row rather than the parameters, because `status` and `approved_at` are
  -- column defaults that this insert never names.
  if exists (
    select 1 from public.access_grants g
    where g.id = v_id
      and public.notification_grant_is_live(g.status, g.release_condition, g.approved_at)
  ) then
    perform public.emit_lifecycle_notification(
      p_grantee_user_id,
      p_estate_id,
      'access_grant.created',
      public.notification_estate_home(p_estate_id, p_grantee_user_id)
    );
  end if;

  return query select g.* from public.access_grants g where g.id = v_id;
end;
$$;


ALTER FUNCTION "public"."create_document_grant"("p_estate_id" "uuid", "p_grantee_user_id" "uuid", "p_grantee_role" "text", "p_document_id" "uuid", "p_visibility_tier" "text", "p_release_condition" "text", "p_professional_type" "text", "p_requires_step_up" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_estate_asset"("p_estate" "uuid", "p_subtype" "text", "p_label" "text", "p_sensitivity" "text" DEFAULT NULL::"text", "p_owner_label" "text" DEFAULT NULL::"text", "p_country_code" "text" DEFAULT NULL::"text", "p_jurisdiction" "text" DEFAULT NULL::"text", "p_institution_name" "text" DEFAULT NULL::"text", "p_reference_hint" "text" DEFAULT NULL::"text", "p_approximate_value_cents" bigint DEFAULT NULL::bigint, "p_currency" "text" DEFAULT NULL::"text", "p_notes" "text" DEFAULT NULL::"text", "p_beneficiary_note" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
declare
  v_uid      uuid := auth.uid();
  v_category text;
  v_sens     text;
  v_cur      text;
  v_id       uuid;
begin
  if v_uid is null then raise exception 'auth_required' using errcode = '42501'; end if;
  if not public.is_estate_owner(p_estate) then raise exception 'not_estate_owner' using errcode = '42501'; end if;

  if p_label is null or length(btrim(p_label)) = 0 then
    raise exception 'label_required' using errcode = 'P0001';
  end if;
  if length(p_label) > 200 then
    raise exception 'label_too_long' using errcode = 'P0001';
  end if;

  -- Catalog interrogation. An unknown or retired subtype is refused BEFORE any row exists — the
  -- Vault lesson: a rejection that lands after the write leaves an orphan behind.
  select s.parent_category into v_category
    from public.estate_asset_subtype s
    where s.subtype = p_subtype and s.is_active;
  if not found then
    if exists (select 1 from public.estate_asset_subtype where subtype = p_subtype) then
      raise exception 'inactive_subtype' using errcode = 'P0001';
    else
      raise exception 'unknown_subtype' using errcode = 'P0001';
    end if;
  end if;

  -- Sensitivity defaults to the most protective level, and an explicit value is validated against the
  -- SAME catalog documents use. There is no fallback: an unknown value is refused, never coerced.
  v_sens := coalesce(p_sensitivity, 'sealed');
  if not exists (select 1 from public.document_sensitivity where value = v_sens and is_active) then
    raise exception 'invalid_sensitivity' using errcode = 'P0001';
  end if;

  v_cur := upper(coalesce(p_currency, 'USD'));
  if v_cur !~ '^[A-Z]{3}$' then raise exception 'invalid_currency' using errcode = 'P0001'; end if;

  if p_approximate_value_cents is not null and p_approximate_value_cents < 0 then
    raise exception 'invalid_value' using errcode = 'P0001';
  end if;
  if p_reference_hint is not null and length(p_reference_hint) > 12 then
    -- The column CHECK would refuse this too; raising here turns a constraint violation into a
    -- sentinel the client can explain.
    raise exception 'reference_hint_too_long' using errcode = 'P0001';
  end if;

  -- ★ THIS CHECK WAS MISSING, AND ITS ABSENCE LEAKED THE WHOLE ROW. `update_estate_asset` validated
  -- the country code and this function did not, so a bad code fell through to the column CHECK —
  -- and a Postgres constraint violation carries `DETAIL: Failing row contains (…)`, i.e. the
  -- approximate value, the notes, the beneficiary note and the reference hint, into the server log
  -- and into any error telemetry downstream. The client maps the unrecognized message to `unknown`
  -- and shows nothing, which is exactly why this would never have been noticed from the app.
  --
  -- Every user-supplied field on this path is now validated BEFORE the insert, so a constraint
  -- violation here means a genuine bug rather than ordinary bad input.
  if p_country_code is not null and btrim(p_country_code) <> ''
     and upper(btrim(p_country_code)) !~ '^[A-Z]{2}$' then
    raise exception 'invalid_country_code' using errcode = 'P0001';
  end if;

  insert into public.estate_assets (
    estate_id, created_by, category, subtype, label, sensitivity, owner_label, country_code,
    jurisdiction, institution_name, reference_hint, approximate_value_cents, currency, notes,
    beneficiary_note
  ) values (
    p_estate, v_uid, v_category, p_subtype, btrim(p_label), v_sens, p_owner_label,
    nullif(upper(btrim(coalesce(p_country_code, ''))), ''), p_jurisdiction, p_institution_name,
    p_reference_hint, p_approximate_value_cents, v_cur, p_notes, p_beneficiary_note
  ) returning id into v_id;

  -- FIELD NAMES ONLY. An estate's asset values must not be reconstructable from audit_logs.
  perform public.write_audit('estate_asset.created', 'estate_assets', v_id, p_estate,
    jsonb_build_object('category', v_category, 'subtype', p_subtype, 'sensitivity', v_sens,
                       'via', 'create_estate_asset'));
  return v_id;
end;
$_$;


ALTER FUNCTION "public"."create_estate_asset"("p_estate" "uuid", "p_subtype" "text", "p_label" "text", "p_sensitivity" "text", "p_owner_label" "text", "p_country_code" "text", "p_jurisdiction" "text", "p_institution_name" "text", "p_reference_hint" "text", "p_approximate_value_cents" bigint, "p_currency" "text", "p_notes" "text", "p_beneficiary_note" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_estate_invitation"("p_estate" "uuid", "p_proposed_role" "text", "p_invitee_email" "text" DEFAULT NULL::"text", "p_invitee_phone" "text" DEFAULT NULL::"text", "p_show_estate_name" boolean DEFAULT false, "p_show_inviter_name" boolean DEFAULT false, "p_expires_in_days" integer DEFAULT 14) RETURNS TABLE("invitation_id" "uuid", "token_fingerprint" "text", "expires_at" timestamp with time zone, "delivery_state" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_pending int; v_id uuid; v_expires timestamptz;
  v_estate_name text; v_inviter_name text;
  v_email text; v_phone text; v_email_hint text; v_phone_hint text;
  v_unissued_hash text; v_outbox uuid;
begin
  perform public.estate_owner_gate(p_estate);

  v_email := nullif(btrim(lower(coalesce(p_invitee_email, ''))), '');
  v_phone := nullif(btrim(coalesce(p_invitee_phone, '')), '');
  if v_email is null and v_phone is null then
    raise exception 'invitee_contact_required' using errcode = 'P0001';
  end if;

  -- Bounded to the verified product vocabulary. Ownership and fiduciary roles are unrepresentable
  -- here AND at the schema level (invitations_proposed_role_check), so an invitation can never
  -- grant executor, trustee, or owner. `kind` is set equal to the role: this consumer path does
  -- not expose the broader kind vocabulary the console uses.
  if p_proposed_role not in ('beneficiary', 'professional_delegate') then
    raise exception 'role_not_supported' using errcode = 'P0001';
  end if;
  if p_expires_in_days < 1 or p_expires_in_days > 90 then
    raise exception 'invalid_expiry' using errcode = 'P0001';
  end if;

  -- Self-invitation is rejected: an owner is already the estate's owner, and inviting themselves
  -- would create a second membership row for the same person.
  if v_email is not null and v_email = (select lower(p.email) from public.profiles p where p.id = auth.uid()) then
    raise exception 'cannot_invite_self' using errcode = 'P0001';
  end if;

  -- Already an approved member of this estate → nothing to invite them to.
  if v_email is not null and exists (
    select 1 from public.estate_memberships m
    join public.profiles pr on pr.id = m.user_id
    where m.estate_id = p_estate and lower(pr.email) = v_email and m.status = 'approved'
  ) then
    raise exception 'already_member' using errcode = 'P0001';
  end if;

  -- ★ ATOMIC EXPIRY SWEEP, then the duplicate check (design record D5). A partial unique index
  -- cannot use now(), so overdue rows are settled to their true status first — otherwise a stale
  -- invitation would block re-inviting the same person forever.
  update public.invitations as inv
     set status = 'expired', updated_at = now()
   where inv.estate_id = p_estate and inv.status in ('pending', 'matched') and inv.expires_at <= now();

  if v_email is not null and exists (
    select 1 from public.invitations i
    where i.estate_id = p_estate and lower(i.invitee_email) = v_email
      and i.proposed_role = p_proposed_role and i.status in ('pending', 'matched')
  ) then
    raise exception 'active_invitation_exists' using errcode = 'P0001';
  end if;

  select count(*) into v_pending
    from public.invitations inv
   where inv.estate_id = p_estate and inv.status in ('pending', 'matched') and inv.expires_at > now();
  if v_pending >= 20 then
    raise exception 'pending_invitation_cap' using errcode = 'P0001';
  end if;

  select e.name into v_estate_name from public.estates e where e.id = p_estate;
  select coalesce(nullif(pr.full_name, ''), pr.email) into v_inviter_name
    from public.profiles pr where pr.id = auth.uid();

  v_email_hint := case when v_email is not null
    then left(v_email, 1) || '•••@' || split_part(v_email, '@', 2) else null end;
  v_phone_hint := case when v_phone is not null then '•••' || right(v_phone, 4) else null end;

  -- ★ THE SECRET IS NOT MINTED HERE. token_hash is NOT NULL, so a hash of an immediately-discarded
  -- random value is stored. The invitation therefore exists but is NOT YET USABLE: no token that
  -- hashes to this value has ever existed outside this statement. The real secret is minted by
  -- issue_invitation_delivery() at delivery time. Fail-closed: an invitation nobody has been told
  -- about cannot be accepted.
  v_unissued_hash := encode(digest(encode(gen_random_bytes(32), 'hex'), 'sha256'), 'hex');
  v_expires := now() + make_interval(days => p_expires_in_days);

  insert into public.invitations
    (id, estate_id, invited_by, kind, proposed_role, status, expires_at,
     invitee_email, invitee_phone, invitee_email_hint, invitee_phone_hint,
     estate_display_name, inviter_display_name, preview_visibility, token_hash, created_at, updated_at)
  values
    (gen_random_uuid(), p_estate, auth.uid(), p_proposed_role, p_proposed_role, 'pending', v_expires,
     v_email, v_phone, v_email_hint, v_phone_hint, v_estate_name, v_inviter_name,
     jsonb_build_object('showEstateName', p_show_estate_name, 'showInviterName', p_show_inviter_name),
     v_unissued_hash, now(), now())
  returning id into v_id;

  -- Same transaction: the invitation and its delivery request commit together or not at all.
  insert into public.invitation_delivery_outbox (invitation_id, estate_id, reason, requested_by)
  values (v_id, p_estate, 'invitation_created', auth.uid())
  returning id into v_outbox;

  perform public.write_audit('invitation.created', 'invitations', v_id, p_estate,
    jsonb_build_object('invitation_id', v_id, 'proposed_role', p_proposed_role,
                       'invitee_email_hint', v_email_hint, 'expires_at', v_expires,
                       'delivery_outbox_id', v_outbox));

  -- 'queued' — NOT 'sent'. Nothing has been delivered; a worker must still run.
  return query select v_id, substr(v_unissued_hash, 1, 12), v_expires, 'queued'::text;
end;
$$;


ALTER FUNCTION "public"."create_estate_invitation"("p_estate" "uuid", "p_proposed_role" "text", "p_invitee_email" "text", "p_invitee_phone" "text", "p_show_estate_name" boolean, "p_show_inviter_name" boolean, "p_expires_in_days" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_invitation"("p_estate" "uuid", "p_kind" "text", "p_proposed_role" "text", "p_invitee_email" "text" DEFAULT NULL::"text", "p_invitee_phone" "text" DEFAULT NULL::"text", "p_show_estate_name" boolean DEFAULT false, "p_show_inviter_name" boolean DEFAULT false, "p_expires_in_days" integer DEFAULT 14) RETURNS TABLE("invitation_id" "uuid", "raw_token" "text", "token_fingerprint" "text", "expires_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_pending int; v_raw text; v_hash text;
  v_estate_name text; v_inviter_name text; v_email_hint text; v_phone_hint text;
  v_expires timestamptz; v_id uuid;
begin
  perform public.invitation_write_gate(p_estate);

  if p_invitee_email is null and p_invitee_phone is null then
    raise exception 'invitee_contact_required' using errcode = 'P0001';
  end if;

  if p_kind not in ('beneficiary','professional_delegate','executor','trustee') then
    raise exception 'kind_not_supported' using errcode = 'P0001';
  end if;
  -- ════════════════════════════════════════════════════════════════════════════════════════════════
  -- ★ PHASE 11-MC — THIS LINE STAYS, AND IT IS NOW INERT. BOTH HALVES OF THAT MATTER.
  -- ════════════════════════════════════════════════════════════════════════════════════════════════
  --
  -- WHY IT CANNOT BE REMOVED: `invitations.proposed_role` is `text NOT NULL` with
  -- `check (proposed_role = any (array['beneficiary','professional_delegate']))`. There is no value that
  -- honestly means "no access class", and inventing one is DDL on a live table plus a migration. So an
  -- executor/trustee invitation must still persist one of two disclosure-class words it does not mean.
  --
  -- WHY REMOVING IT WOULD HAVE BEEN WORSE THAN LEAVING IT: the defect was never this value. It was that
  -- `provision_from_invitation` created a membership AT this value for every acceptance. Drop the force
  -- and an executor invitation minted with `p_proposed_role = 'professional_delegate'` would have
  -- provisioned a PROFESSIONAL DELEGATE membership instead — a different manufactured disclosure class,
  -- and a worse one, because nothing in the product expects a fiduciary to arrive as a delegate.
  --
  -- WHERE THE FIX ACTUALLY LIVES: `provision_from_invitation` now gates membership creation on `kind`,
  -- the authoritative and immutable statement of what the invitation is. That also fixes every
  -- OUTSTANDING invitation — this column is written at CREATE time, so rows minted before the correction
  -- already carry 'beneficiary', and a provisioner keyed on `proposed_role` would have kept honouring it
  -- forever.
  --
  -- WHAT IT STILL AFFECTS: nothing in provisioning. It remains visible as `proposedRole` in
  -- `resolve_membership`'s pending-invitation payload, where the client maps it to a presentation-only
  -- `accessClass` label — `features/invitations/model.ts` states outright that nothing gates on it. So a
  -- fiduciary invitation card can still show the wrong relationship WORD. That is a real accuracy defect
  -- and it is recorded rather than silently tolerated: fixing it means surfacing `kind` in that payload,
  -- which is a separate backend+client slice. Making the column nullable belongs with it.
  if p_kind in ('executor','trustee') then
    p_proposed_role := 'beneficiary';
  elsif p_proposed_role not in ('beneficiary','professional_delegate') then
    raise exception 'invalid_proposed_role' using errcode = 'P0001';
  end if;

  if p_expires_in_days < 1 or p_expires_in_days > 90 then
    raise exception 'invalid_expiry' using errcode = 'P0001';
  end if;

  select count(*) into v_pending from public.invitations inv
  where inv.estate_id = p_estate and inv.status in ('pending','matched') and inv.expires_at > now();
  if v_pending >= 20 then raise exception 'pending_invitation_cap' using errcode = 'P0001'; end if;

  select e.name into v_estate_name from public.estates e where e.id = p_estate;
  select coalesce(nullif(p.full_name,''), p.email) into v_inviter_name from public.profiles p where p.id = auth.uid();
  v_email_hint := case when p_invitee_email is not null
    then left(p_invitee_email,1) || '•••@' || split_part(p_invitee_email,'@',2) else null end;
  v_phone_hint := case when p_invitee_phone is not null then '•••' || right(p_invitee_phone,4) else null end;
  v_raw := encode(gen_random_bytes(32), 'hex'); v_hash := encode(digest(v_raw, 'sha256'), 'hex');
  v_expires := now() + make_interval(days => p_expires_in_days);

  insert into public.invitations
    (id, estate_id, invited_by, kind, proposed_role, status, expires_at, invitee_email, invitee_phone,
     invitee_email_hint, invitee_phone_hint, estate_display_name, inviter_display_name, preview_visibility,
     token_hash, created_at, updated_at)
  values
    (gen_random_uuid(), p_estate, auth.uid(), p_kind, p_proposed_role, 'pending', v_expires,
     p_invitee_email, p_invitee_phone, v_email_hint, v_phone_hint, v_estate_name, v_inviter_name,
     jsonb_build_object('showEstateName', p_show_estate_name, 'showInviterName', p_show_inviter_name),
     v_hash, now(), now())
  returning id into v_id;

  perform public.write_audit('invitation.created', 'invitations', v_id, p_estate,
    jsonb_build_object('invitation_id', v_id, 'kind', p_kind, 'proposed_role', p_proposed_role,
                       'token_fingerprint', substr(v_hash,1,12), 'expires_at', v_expires,
                       'invitee_email_hint', v_email_hint));
  return query select v_id, v_raw, substr(v_hash,1,12), v_expires;
end;
$$;


ALTER FUNCTION "public"."create_invitation"("p_estate" "uuid", "p_kind" "text", "p_proposed_role" "text", "p_invitee_email" "text", "p_invitee_phone" "text", "p_show_estate_name" boolean, "p_show_inviter_name" boolean, "p_expires_in_days" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_vault_document"("p_estate" "uuid", "p_doc_id" "uuid", "p_storage_path" "text", "p_title" "text", "p_doc_subtype" "text", "p_sensitivity" "text" DEFAULT 'sealed'::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
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
$_$;


ALTER FUNCTION "public"."create_vault_document"("p_estate" "uuid", "p_doc_id" "uuid", "p_storage_path" "text", "p_title" "text", "p_doc_subtype" "text", "p_sensitivity" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."decline_invitation"("p_invitation_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_user uuid := auth.uid();
  v_inv record;
  v_user_email text;
  v_user_phone text;
begin
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;

  select * into v_inv
  from public.invitations
  where id = p_invitation_id
  for update;

  if not found then
    raise exception 'invitation_not_found' using errcode = 'P0002';
  end if;

  -- Verify the caller is the intended invitee (same guard as accept).
  select profiles.email, profiles.phone into v_user_email, v_user_phone
  from public.profiles
  where profiles.id = v_user;

  if not (
    (v_inv.invitee_email is not null
     and lower(v_inv.invitee_email) = lower(coalesce(v_user_email, '')))
    or
    (v_inv.invitee_phone is not null
     and v_inv.invitee_phone = coalesce(v_user_phone, ''))
  ) then
    raise exception 'invitation_not_for_caller' using errcode = 'P0006';
  end if;

  -- Idempotent: already declined is a successful no-op.
  if v_inv.status = 'declined' then
    return;
  end if;

  if v_inv.status = 'accepted' then
    raise exception 'invitation_already_accepted' using errcode = 'P0005';
  end if;

  if v_inv.status = 'revoked' then
    raise exception 'invitation_revoked' using errcode = 'P0004';
  end if;

  if v_inv.expires_at < now() then
    raise exception 'invitation_expired' using errcode = 'P0003';
  end if;

  update public.invitations
     set status = 'declined',
         updated_at = now()
   where id = v_inv.id;

  perform public.write_audit(
    'invitation.declined',
    'invitations',
    v_inv.id,
    v_inv.estate_id,
    jsonb_build_object('invitation_id', v_inv.id)
  );

  -- ★ PHASE 10-E — the OWNER learns an invitation was declined. Below the idempotent
  -- already-declined early-return, so a repeat decline emits nothing the second time. That
  -- placement is load-bearing and is asserted: an emitter moved above the idempotency guard would
  -- produce one notification per call rather than one per event, and nothing else would notice.
  --
  -- No deep link on this one — the invitation is finished, and there is no state to go and look at.
  perform public.emit_lifecycle_notification(
    public.estate_owner_user_id(v_inv.estate_id),
    v_inv.estate_id,
    'invitation.declined',
    null
  );
end;
$$;


ALTER FUNCTION "public"."decline_invitation"("p_invitation_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_vault_document"("p_doc_id" "uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid    uuid := auth.uid();
  v_estate uuid;
  v_path   text;
  v_outbox uuid;
begin
  if v_uid is null then raise exception 'auth_required' using errcode = '42501'; end if;

  select estate_id, storage_path into v_estate, v_path from public.documents where id = p_doc_id;
  if not found then raise exception 'document_not_found' using errcode = 'P0002'; end if;
  if not public.is_estate_owner(v_estate) then raise exception 'not_estate_owner' using errcode = '42501'; end if;

  -- BLOCKING CONDITIONS (real sources; machine-readable messages). Order: active claim → legal hold → retention.
  if exists (select 1 from public.claim_packets c
             where (c.death_certificate_doc_id = p_doc_id or c.executor_id_doc_id = p_doc_id)
               and c.status <> 'rejected') then
    raise exception 'blocked_active_claim' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.legal_holds h where h.doc_id = p_doc_id and h.released_at is null) then
    raise exception 'blocked_legal_hold' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.documents d
             where d.id = p_doc_id and d.retention_until is not null and d.retention_until > now()) then
    raise exception 'blocked_retention' using errcode = 'P0001';
  end if;

  -- HARD delete (DEFINER = table owner → bypasses the RLS write-lockdown). Rejected-claim evidence FKs SET NULL.
  delete from public.documents where id = p_doc_id;

  -- Durable purge OUTBOX event — SAME TX (atomic with the delete). estate_id denormalized (doc row is gone).
  insert into public.storage_deletion_outbox (estate_id, bucket, object_path, reason, requested_by)
  values (v_estate, 'documents', v_path, 'document_deleted', v_uid)
  returning id into v_outbox;

  -- Immutable audit TOMBSTONE (high-sev). Metadata only — never document bytes.
  perform public.write_audit('document.deleted', 'documents', p_doc_id, v_estate,
    jsonb_build_object('severity', 'high', 'storage_path', v_path, 'reason', 'document_deleted',
                       'outbox_id', v_outbox, 'via', 'delete_vault_document'));

  return v_outbox;
end;
$$;


ALTER FUNCTION "public"."delete_vault_document"("p_doc_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."deny_access_request"("p_request_id" "uuid") RETURNS SETOF "public"."access_requests"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_user      uuid := auth.uid();
  v_estate    uuid;
  v_status    text;
  -- ★ PHASE 10-E — read alongside the estate, from the request row itself. The recipient of a
  -- decision notification is the person who made the request; it is never derived from who happens
  -- to hold a capability on this estate.
  v_requester uuid;
begin
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;

  -- Lock the request row for the txn.
  select estate_id, status, requester_user_id into v_estate, v_status, v_requester
  from public.access_requests
  where id = p_request_id
  for update;

  if v_estate is null then
    raise exception 'request_not_found';  -- P0001 -> 400
  end if;

  -- SECURITY SPINE (privilege gate): owner-only, BEFORE any mutation.
  if not public.is_estate_owner(v_estate) then
    raise exception 'not estate owner' using errcode = '42501';
  end if;

  if v_status is distinct from 'pending' then
    raise exception 'request_not_pending';  -- P0001 -> 400
  end if;

  update public.access_requests
     set status = 'denied',
         resolved_at = now(),
         resolved_by_user_id = v_user
   where id = p_request_id;

  perform public.write_audit(
    'access_request.denied',
    'access_requests',
    p_request_id,
    v_estate,
    jsonb_build_object('outcome', 'denied')
  );

  -- ★ PHASE 10-E — the REQUESTER learns the outcome of THEIR OWN request. Only they receive it: a
  -- denial is not estate news, and no other member is told that someone asked and was refused.
  --
  -- NO DEEP LINK. There is nothing newly available to open, and sending a refused requester to an
  -- estate surface would be an invitation to a screen that says no.
  perform public.emit_lifecycle_notification(
    v_requester,
    v_estate,
    'access_request.denied',
    null
  );

  return query select r.* from public.access_requests r where r.id = p_request_id;
end;
$$;


ALTER FUNCTION "public"."deny_access_request"("p_request_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."dispatch_owner_safety_notice"("p_estate" "uuid") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid       uuid;
  v_state     text;
  v_owner     uuid;
  v_recipient text;
  v_case      uuid;
  v_notice    uuid;
  v_outbox    uuid;
begin
  perform public.admin_require_gate();
  v_uid := auth.uid();

  select l.state into v_state
    from public.estate_lifecycle l
   where l.estate_id = p_estate
   for update;

  if v_state = 'owner_notification_dispatched' then
    return 'owner_notification_dispatched'; -- idempotent replay: no re-dispatch, no re-audit
  end if;
  if v_state is distinct from 'death_verified' then
    raise exception 'invalid_dispatch_state' using errcode = 'P0001';
  end if;

  select c.id into v_case
    from public.death_verification_cases c
   where c.estate_id = p_estate and c.status = 'verified'
   order by c.decided_at desc
   limit 1;
  if v_case is null then
    raise exception 'no_verified_case' using errcode = 'P0001';
  end if;

  v_owner := public.estate_owner_user_id(p_estate);
  if v_owner is null then
    raise exception 'owner_unresolved' using errcode = 'P0001';
  end if;

  -- ★ THE INDEPENDENT CHANNEL, RESOLVED FROM THE IDENTITY PROVIDER rather than from anything a
  -- claimant can write. `profiles.email` is user-editable in principle; `auth.users.email` is the
  -- address the account authenticates with, which is the one a claimant cannot repoint.
  select u.email into v_recipient from auth.users u where u.id = v_owner;
  if v_recipient is null or btrim(v_recipient) = '' then
    raise exception 'owner_channel_unreachable' using errcode = 'P0001';
  end if;

  -- EMAIL FIRST: the row whose existence is the dispatch. Same transaction as the transition, so a
  -- rollback anywhere below un-dispatches it and the window never opened.
  -- ★ PHASE 11-OC — THE ROW NAMES ITS EPISODE, AND `v_case` WAS ALREADY IN HAND.
  --
  -- `v_case` is resolved above and, until this phase, was discarded into the audit metadata only. It
  -- is the EPISODE key: one estate may legitimately experience several independent death processes
  -- over time (`rejected` and `cancelled` both return the lifecycle to `active`), so an accepted
  -- notice from a prior, rejected process must never authorize a release under a later case. Scoping
  -- the release predicate to the estate would do exactly that; scoping it to the case cannot.
  --
  -- `generation` is the literal 1 here and only ever incremented by the re-notice routine, under the
  -- predecessor's row lock — never from an unlocked max().
  --
  -- A BEFORE INSERT trigger (migration 0058) refuses any owner-notice row with a NULL case_id, so
  -- this is a wall rather than a promise this routine makes. Legacy rows keep their NULL and stay
  -- updatable, because the trigger fires on INSERT only.
  insert into public.owner_notice_outbox
    (estate_id, user_id, channel, recipient, notice_kind, status, case_id, generation)
  values (p_estate, v_owner, 'email', v_recipient, 'death_process.window_opened', 'queued',
          v_case, 1)
  returning id into v_outbox;
  if v_outbox is null then
    raise exception 'owner_notification_failed' using errcode = 'P0001';
  end if;

  -- IN-APP SECOND, and still REQUIRED (11-E's guarantee is kept, not replaced). Two channels, both
  -- committed, before any clock starts.
  v_notice := public.emit_lifecycle_notification(
    v_owner, p_estate, 'death_process.window_opened', 'afterworth://challenge');
  if v_notice is null then
    raise exception 'owner_notification_failed' using errcode = 'P0001';
  end if;

  perform public.apply_estate_lifecycle_transition(
    p_estate, 'owner_notification_dispatched', v_case, 'owner_notice_dispatched');

  update public.estate_lifecycle
     set owner_notified_at = now(),
         safety_notification_id = v_notice
   where estate_id = p_estate;

  -- ★ THE AUDIT RECORDS THE CHANNEL CLASS, NEVER THE ADDRESS. That a notice went to email is an
  -- operational fact; WHICH address is a living owner's contact detail, and an audit row outlives
  -- every reason anyone had to read it.
  insert into public.audit_logs (actor_id, estate_id, action, target_table, target_id, metadata, source)
  values (v_uid, p_estate, 'death_process.owner_notice_dispatched', 'owner_notice_outbox', v_outbox,
          jsonb_build_object('severity', 'high', 'case_id', v_case, 'channel', 'email',
                            'in_app_notification_id', v_notice),
          'admin');
  return 'owner_notification_dispatched';
end $$;


ALTER FUNCTION "public"."dispatch_owner_safety_notice"("p_estate" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."dispatch_owner_safety_notice"("p_estate" "uuid") IS 'Phase 11-F (D4): commits an EMAIL row and an in-app notice to the owner, in the same transaction as the death_verified -> owner_notification_dispatched transition, and stamps owner_notified_at (D2: the challenge clock starts at dispatch). Requires dispatch INITIATION, never delivery confirmation. An unresolvable owner address refuses the transition. Admin-gated; idempotent.';



CREATE OR REPLACE FUNCTION "public"."document_grantable"("p_role" "text", "p_sensitivity" "text") RETURNS boolean
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select case
    when p_sensitivity = 'sealed'     then false
    when p_sensitivity = 'restricted' then p_role = 'professional_delegate'
    when p_sensitivity in ('low','medium','high')
                                      then p_role in ('beneficiary','professional_delegate')
    else false                                   -- unknown sensitivity -> deny
  end;
$$;


ALTER FUNCTION "public"."document_grantable"("p_role" "text", "p_sensitivity" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."emit_lifecycle_notification"("p_user_id" "uuid", "p_estate_id" "uuid", "p_event" "text", "p_deep_link" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_copy record;
  v_id uuid;
begin
  -- No recipient, no notification. A null here means a caller could not resolve one, and inventing
  -- a recipient is the one mistake this whole file exists to prevent.
  if p_user_id is null or p_event is null then
    return null;
  end if;

  select c.category, c.title, c.body into v_copy
  from public.notification_event_copy(p_event) c;

  if v_copy is null then
    raise warning 'emit_lifecycle_notification: unknown event %, nothing emitted', p_event;
    return null;
  end if;

  begin
    v_id := public.emit_notification(
      p_user_id, p_estate_id, v_copy.category, v_copy.title, v_copy.body, p_deep_link, '{}'::jsonb
    );
  exception when others then
    -- Swallowed so the load-bearing transition still commits — but LOUD in the server log.
    raise warning 'emit_lifecycle_notification: event % could not be written (%)', p_event, sqlerrm;
    return null;
  end;

  return v_id;
end;
$$;


ALTER FUNCTION "public"."emit_lifecycle_notification"("p_user_id" "uuid", "p_estate_id" "uuid", "p_event" "text", "p_deep_link" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."emit_lifecycle_notification"("p_user_id" "uuid", "p_estate_id" "uuid", "p_event" "text", "p_deep_link" "text") IS 'The only way a lifecycle notification is written. Copy comes from the immutable event catalog; callers name an event and never compose text. Runs in the caller transaction, so it commits or rolls back with the state transition. INTERNAL: execute revoked from public/authenticated.';



CREATE OR REPLACE FUNCTION "public"."emit_notification"("p_user_id" "uuid", "p_estate_id" "uuid", "p_category" "text", "p_title" "text", "p_body" "text", "p_deep_link" "text" DEFAULT NULL::"text", "p_payload" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_id uuid;
begin
  -- Writes the RECONCILED live schema: the logical category maps to the existing `kind` column, and
  -- `read` (boolean) starts false (unread). See 0009_20260702_notifications.sql.
  insert into public.notifications
    (user_id, estate_id, kind, title, body, channel, action_deep_link, payload, read)
  values
    (p_user_id, p_estate_id, p_category, p_title, p_body, 'inApp', p_deep_link, coalesce(p_payload, '{}'::jsonb), false)
  returning id into v_id;
  return v_id;
end;
$$;


ALTER FUNCTION "public"."emit_notification"("p_user_id" "uuid", "p_estate_id" "uuid", "p_category" "text", "p_title" "text", "p_body" "text", "p_deep_link" "text", "p_payload" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enforce_grant_ceiling"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_sens text;
begin
  -- Only enforce for a grant that will be ACTIVE. A transition to 'revoked' must
  -- always succeed, even if the doc's sensitivity was raised above the ceiling after
  -- the grant was created — otherwise a sealed-reclassified doc could not be revoked.
  if new.status = 'active' and new.document_id is not null then
    select sensitivity into v_sens from public.documents where id = new.document_id;
    if not public.document_grantable(new.grantee_role, v_sens) then
      raise exception 'grant ceiling violation: % cannot be granted a % document',
        new.grantee_role, v_sens
        using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."enforce_grant_ceiling"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ensure_primary_user_membership"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
begin
  insert into public.estate_memberships
    (id, estate_id, user_id, role, status, approved_at, created_at)
  values
    (gen_random_uuid(),
     new.id,
     new.owner_id,
     'primary_user',
     'approved',
     now(),
     now())
  on conflict do nothing;

  return new;
end;
$$;


ALTER FUNCTION "public"."ensure_primary_user_membership"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."estate_lifecycle_state"("p_estate" "uuid") RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce(
    (select l.state from public.estate_lifecycle l where l.estate_id = p_estate),
    'active');
$$;


ALTER FUNCTION "public"."estate_lifecycle_state"("p_estate" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."estate_lifecycle_state"("p_estate" "uuid") IS 'THE authoritative estate lifecycle read (Phase 11-C, extracted 11-D). Absent row = active. INTERNAL: execute revoked from every client role — a client that can map estate to lifecycle state holds a death-status oracle. Consumed by the death-verification routines and, since 11-D, as the lifecycle argument to public.release_condition_satisfied inside disclosure evaluators. Never derived from claim_packets.status, evidence, or attained verification levels.';



CREATE OR REPLACE FUNCTION "public"."estate_owner_gate"("p_estate" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if auth.uid() is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;
  -- NOT `owner OR admin`. See design record D2: these are consumer-mobile functions, and platform
  -- admin must never confer estate-owner authority over a customer's estate through this path.
  if not public.is_estate_owner(p_estate) then
    raise exception 'owner_required' using errcode = '42501';
  end if;
end;
$$;


ALTER FUNCTION "public"."estate_owner_gate"("p_estate" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."estate_owner_user_id"("p_estate_id" "uuid") RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select owner_id from public.estates where id = p_estate_id;
$$;


ALTER FUNCTION "public"."estate_owner_user_id"("p_estate_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."estate_owner_user_id"("p_estate_id" "uuid") IS 'The estate owner user id, for server-side notification recipient resolution. INTERNAL: execute is revoked from public/authenticated, because a client that can map estate -> owner identity has been handed an identity-disclosure surface nothing in the product offers.';



CREATE OR REPLACE FUNCTION "public"."estate_release_state"("p_estate" "uuid") RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
$$;


ALTER FUNCTION "public"."estate_release_state"("p_estate" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."extend_estate_invitation"("p_estate" "uuid", "p_invitation" "uuid", "p_expires_in_days" integer DEFAULT 14) RETURNS TABLE("invitation_id" "uuid", "expires_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_inv record; v_new timestamptz;
begin
  perform public.estate_owner_gate(p_estate);
  if p_expires_in_days < 1 or p_expires_in_days > 90 then
    raise exception 'invalid_expiry' using errcode = 'P0001';
  end if;

  select * into v_inv from public.invitations
   where id = p_invitation and estate_id = p_estate for update;
  if not found then raise exception 'invitation_not_found' using errcode = 'P0002'; end if;

  if public.invitation_effective_status(v_inv.status, v_inv.expires_at) not in ('pending', 'matched') then
    raise exception 'invitation_not_actionable' using errcode = 'P0005';
  end if;
  if v_inv.created_at + interval '90 days' <= now() then
    raise exception 'invitation_lifetime_exceeded' using errcode = 'P0003';  -- mint a new one
  end if;

  v_new := least(now() + make_interval(days => p_expires_in_days), v_inv.created_at + interval '90 days');
  -- Never shorten, even if the cap would.
  if v_new <= v_inv.expires_at then
    raise exception 'extension_would_not_lengthen' using errcode = 'P0001';
  end if;

  update public.invitations
     set expires_at = v_new, extended_at = now(), extended_by = auth.uid(), updated_at = now()
   where id = v_inv.id;

  perform public.write_audit('invitation.extended', 'invitations', v_inv.id, p_estate,
    jsonb_build_object('invitation_id', v_inv.id, 'old_expires_at', v_inv.expires_at, 'new_expires_at', v_new));

  return query select v_inv.id, v_new;
end;
$$;


ALTER FUNCTION "public"."extend_estate_invitation"("p_estate" "uuid", "p_invitation" "uuid", "p_expires_in_days" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."extend_invitation"("p_invitation_id" "uuid", "p_expires_in_days" integer DEFAULT 14) RETURNS TABLE("invitation_id" "uuid", "expires_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_inv record; v_new timestamptz;
begin
  if auth.uid() is null then raise exception 'auth_required' using errcode = '42501'; end if;
  if p_expires_in_days < 1 or p_expires_in_days > 90 then
    raise exception 'invalid_expiry' using errcode = 'P0001'; end if;
  select * into v_inv from public.invitations where id = p_invitation_id for update;
  if not found then raise exception 'invitation_not_found' using errcode = 'P0002'; end if;
  perform public.invitation_write_gate(v_inv.estate_id);

  if v_inv.status not in ('pending','matched') then
    raise exception 'cannot_extend_%', v_inv.status using errcode = 'P0005'; end if;
  if v_inv.created_at + interval '90 days' <= now() then
    raise exception 'invitation_lifetime_exceeded' using errcode = 'P0003'; end if;  -- mint a new one

  v_new := least(now() + make_interval(days => p_expires_in_days), v_inv.created_at + interval '90 days');
  update public.invitations set expires_at = v_new, updated_at = now() where id = v_inv.id;
  perform public.write_audit('invitation.extended', 'invitations', v_inv.id, v_inv.estate_id,
    jsonb_build_object('invitation_id', v_inv.id, 'old_expires_at', v_inv.expires_at, 'new_expires_at', v_new));
  return query select v_inv.id, v_new;
end;
$$;


ALTER FUNCTION "public"."extend_invitation"("p_invitation_id" "uuid", "p_expires_in_days" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."forward_client_audit"("p_action" "text", "p_estate" "uuid", "p_table" "text", "p_target" "uuid", "p_meta" "jsonb", "p_client_ts" timestamp with time zone) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
declare
  v_uid     uuid  := auth.uid();
  v_action  text  := p_action;
  v_meta    jsonb := coalesce(p_meta, '{}'::jsonb);
  v_headers jsonb;
  v_ip      inet;
  v_ua      text;
begin
  -- GATE 1 — no anonymous telemetry.
  if v_uid is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;

  -- Normalize the auth_gateway.choice_<suffix> family -> exact-match 'auth_gateway.choice'; the suffix
  -- moves into metadata.choice_index so the allowlist stays a clean exact-match set. Applies to whatever a
  -- direct caller sends too (belt-and-suspenders; the iOS side also emits the normalized form).
  if v_action like 'auth\_gateway.choice\_%' then
    v_meta   := v_meta || jsonb_build_object('choice_index', substring(v_action from '^auth_gateway\.choice_(.*)$'));
    v_action := 'auth_gateway.choice';
  end if;

  -- GATE 2 — CLIENT-ONLY allowlist. Server-reserved actions (access_grant.*, access_request.*,
  -- connection.*, invitation.bound/accepted/declined, estate.primary_created) are NOT in this set, so a
  -- client can never forge an authorization-consequential audit row (the notifications anti-forgery posture).
  if v_action not in (
    'invitation.matched', 'context.switched', 'token.observed', 'preview.shown',
    'token.validation_failed', 'membership.resolution_failed', 'invitation.declined_preauth',
    'membership.created', 'auth_gateway.choice'
  ) then
    raise exception 'action_not_allowed' using errcode = 'P0001';
  end if;

  -- GATE 3 — metadata size cap on the CLIENT-supplied payload.
  if octet_length(coalesce(p_meta, '{}'::jsonb)::text) > 4096 then
    raise exception 'metadata_too_large' using errcode = 'P0001';
  end if;

  -- ip/user_agent BEST-EFFORT from request.headers (set by PostgREST). See KNOWN LIMITATION in the header.
  v_headers := coalesce(nullif(current_setting('request.headers', true), ''), '{}')::jsonb;
  v_ua := v_headers ->> 'user-agent';
  begin
    v_ip := nullif(trim(split_part(coalesce(v_headers ->> 'x-forwarded-for', ''), ',', 1)), '')::inet;
  exception when others then
    v_ip := null;  -- malformed header -> no ip, never fail the write
  end;

  -- Fold the client-reported time into metadata (diagnostic only; created_at is the authoritative server time).
  if p_client_ts is not null then
    v_meta := v_meta || jsonb_build_object('client_ts', p_client_ts);
  end if;

  insert into public.audit_logs
    (actor_id, estate_id, action, target_table, target_id, ip, user_agent, metadata, source)
  values
    (v_uid, p_estate, v_action, p_table, p_target, v_ip, v_ua, v_meta, 'ios_forward');
end;
$_$;


ALTER FUNCTION "public"."forward_client_audit"("p_action" "text", "p_estate" "uuid", "p_table" "text", "p_target" "uuid", "p_meta" "jsonb", "p_client_ts" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_recovery_codes"() RETURNS "text"[]
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_user  uuid := auth.uid();
  v_codes text[] := '{}';
  v_code  text;
  i       int;
begin
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;

  -- Must be MFA-authed (aal2) to (re)generate.
  if coalesce(auth.jwt() ->> 'aal', 'aal1') <> 'aal2' then
    raise exception 'mfa required to generate recovery codes' using errcode = '42501';
  end if;

  -- Regenerate REPLACES the prior set (old codes invalidated). Atomic with the inserts below.
  delete from public.recovery_codes where user_id = v_user;

  for i in 1..10 loop
    -- 64-bit, hex (16 chars; user-typeable). bcrypt makes offline brute-force infeasible even
    -- at this length; iOS formats for display (e.g. groups of 4).
    v_code := encode(extensions.gen_random_bytes(8), 'hex');
    insert into public.recovery_codes (user_id, code_hash)
      values (v_user, extensions.crypt(v_code, extensions.gen_salt('bf')));
    v_codes := array_append(v_codes, v_code);
  end loop;

  -- Fresh code set invalidates any prior lockout/attempt state.
  delete from public.mfa_recovery_attempts where user_id = v_user;

  return v_codes;   -- plaintext, shown ONCE
end;
$$;


ALTER FUNCTION "public"."generate_recovery_codes"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_connection_access_token"("p_connection_id" "uuid") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_user      uuid := auth.uid();
  v_estate_id uuid;
  v_token     text;
begin
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;

  select estate_id into v_estate_id from public.connections where id = p_connection_id;
  if v_estate_id is null then
    return null;                          -- no such connection
  end if;
  if not public.is_estate_owner(v_estate_id) then
    raise exception 'not estate owner' using errcode = '42501';
  end if;
  -- aal2 GATE: reading a provider access_token (owner-only, feeds the aggregator refresh) -> ALWAYS
  -- require MFA. UNCONDITIONAL. DEFINER bypasses RLS, so the gate must be HERE.
  perform public.require_aal2();

  select access_token into v_token from public.connection_secrets where connection_id = p_connection_id;
  return v_token;
end;
$$;


ALTER FUNCTION "public"."get_connection_access_token"("p_connection_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_document_taxonomy"() RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
$$;


ALTER FUNCTION "public"."get_document_taxonomy"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_estate_asset_taxonomy"() RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select jsonb_build_object(
    'schema_version',     (select schema_version     from public.taxonomy_version where id = 1),
    'vocabulary_version', (select vocabulary_version from public.taxonomy_version where id = 1),
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object(
        'value', value, 'display_name', display_name, 'description', description,
        'sort_order', sort_order, 'icon_key', icon_key, 'is_physical', is_physical)
        order by sort_order, value)
      from public.estate_asset_category where is_active), '[]'::jsonb),
    'subtypes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'value', subtype, 'display_name', display_name, 'description', description,
        'parent_category', parent_category, 'sort_order', sort_order, 'icon_key', icon_key)
        order by sort_order, subtype)
      from public.estate_asset_subtype where is_active), '[]'::jsonb)
  );
$$;


ALTER FUNCTION "public"."get_estate_asset_taxonomy"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_estate_discovery"("p_estate" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
$$;


ALTER FUNCTION "public"."get_estate_discovery"("p_estate" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_estate_net_worth"("p_estate_id" "uuid") RETURNS TABLE("total_cents" bigint, "range_low_cents" bigint, "range_high_cents" bigint, "resolved_tier" "text", "currency" "text", "suppressed_by_breakdown" boolean)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid uuid := auth.uid();
  v_sum bigint;
  v_cur text;
  v_tot text;        -- total_asset_value tier
  v_tot_role text;   -- grantee_role from the total grant (for the ceiling re-check)
begin
  if v_uid is null then return; end if;

  -- The exact estate total (SECURITY DEFINER reads owner-only normalized_assets). Empty estate -> 0.
  select coalesce(sum(a.balance_cents), 0)::bigint, coalesce(max(a.currency), 'USD')
    into v_sum, v_cur
  from public.normalized_assets a
  where a.estate_id = p_estate_id;

  -- OWNER FIRST: inherent exact total, never suppressed.
  if public.is_estate_owner(p_estate_id) then
    -- aal2 GATE (option b): the owner sees the EXACT total -> require MFA, UNCONDITIONALLY.
    perform public.require_aal2();
    return query select v_sum, null::bigint, null::bigint, 'full_detail'::text, v_cur, false;
    return;
  end if;

  -- NON-OWNER: grant-based. Resolve the total_asset_value grant (tier + role).
  select g.visibility_tier, g.grantee_role into v_tot, v_tot_role
  from public.access_grants g
  where g.estate_id = p_estate_id
    and g.grantee_user_id = v_uid
    and g.category = 'total_asset_value'
    and g.status = 'active'
    and g.release_condition = 'immediately'   -- signal-based conditions stay dormant-deny (A.4)
  limit 1;

  -- No total_asset_value grant -> nothing disclosed.
  if v_tot is null then
    return query select null::bigint, null::bigint, null::bigint, 'hidden'::text, v_cur, false;
    return;
  end if;

  -- Read-time ceiling re-check (authoritative). asset_category_grantable already caps total_asset_value
  -- like account_balances (beneficiary summary/range; professional full_detail). Over-ceiling -> hidden.
  if not public.asset_category_grantable(v_tot_role, 'total_asset_value', v_tot) then
    v_tot := 'hidden';
  end if;
  if v_tot = 'hidden' then
    return query select null::bigint, null::bigint, null::bigint, 'hidden'::text, v_cur, false;
    return;
  end if;

  -- ★ THE EXCLUSION — account_balances breakdown PRECEDENCE. If the caller has an active,
  --   immediately-released account_balances grant, list_estate_assets is disclosing the per-group
  --   breakdown; suppress the grand total here so the leaky pair never co-appears across surfaces.
  if exists (
    select 1 from public.access_grants g
    where g.estate_id = p_estate_id
      and g.grantee_user_id = v_uid
      and g.category = 'account_balances'
      and g.status = 'active'
      and g.release_condition = 'immediately'
  ) then
    return query select null::bigint, null::bigint, null::bigint, 'hidden'::text, v_cur, true;  -- suppressed
    return;
  end if;

  -- Emit the total per its tier. Beneficiary (range_only/category_summary) -> BRACKETED (never exact);
  -- professional (limited_detail/full_detail) -> exact, authorized by the ceiling.
  -- aal2 GATE (option b) — TIER-AWARE: the EXACT total emits ONLY in this branch (professional
  -- full/limited), so the gate goes HERE, not before. The bracketed else-branch stays aal1.
  if v_tot in ('limited_detail', 'full_detail') then
    perform public.require_aal2();
    return query select v_sum, null::bigint, null::bigint, v_tot, v_cur, false;
  else
    return query select null::bigint,
                        public.asset_bracket_low(v_sum),
                        public.asset_bracket_high(v_sum),
                        v_tot, v_cur, false;
  end if;
end;
$$;


ALTER FUNCTION "public"."get_estate_net_worth"("p_estate_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_estate_readiness"("p_estate" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
$$;


ALTER FUNCTION "public"."get_estate_readiness"("p_estate" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_executor_workspace"("p_estate" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid        uuid := auth.uid();
  v_capacity   text;
  v_lifecycle  text;
  v_case       record;
  v_claim      record;
  v_required   text;
  v_actions    jsonb := '[]'::jsonb;
  v_case_state text;
  -- Caller-scoped: "did YOU start this", never "who did". Fail-closed default.
  v_is_initiator boolean := false;
begin
  -- ★ THE GATE IS THE FIRST STATEMENT. Nothing above this line reads estate data.
  if v_uid is null then
    return jsonb_build_object('authorized', false);
  end if;
  if not public.is_estate_executor(p_estate, v_uid) then
    return jsonb_build_object('authorized', false);
  end if;

  -- The caller's OWN capacity, read from their own active designation. Never another person's.
  select d.designation_type into v_capacity
    from public.estate_designations d
   where d.estate_id = p_estate
     and d.user_id   = v_uid
     and d.status    = 'active'
     and d.designation_type in ('executor', 'trustee')
   order by d.designation_type
   limit 1;

  v_lifecycle := public.estate_lifecycle_state(p_estate);
  v_required  := public.preview_required_verification_level(p_estate);

  /**
   * The estate's one live verification case.
   *
   * ★ THE CASE ID IS SELECTED, AND UNTIL PHASE 11-MF IT WAS NOT — WHICH MADE CANCELLATION
   * UNREACHABLE. `cancel_death_verification_case(p_case uuid)` takes a CASE id. The only routine that
   * ever handed a fiduciary one was `initiate`, as its return value. Every read surface omitted it, so
   * an initiator who restarted the app, force-quit, crashed, or picked up a second device could never
   * cancel the process they had started — and no product path could recover the handle. That is
   * initiation without cancellation, from the user's side.
   *
   * ★ `initiated_by` IS SELECTED FOR ONE CALLER-SCOPED BOOLEAN, NOT FOR DISCLOSURE. The comment this
   * replaces said "Identity of the initiator is NOT selected", and that instinct was right: a
   * co-fiduciary's identity is not this caller's to read. So the uid is compared and discarded —
   * `is_initiator` answers only "did YOU start this", never "who did".
   */
  select c.status, c.required_level_at_initiation, c.attained_level, c.created_at, c.decided_at,
         c.id as case_id, (c.initiated_by = v_uid) as is_initiator
    into v_case
    from public.death_verification_cases c
   where c.estate_id = p_estate
   order by (c.status = 'open') desc, c.created_at desc
   limit 1;

  v_case_state := coalesce(v_case.status, 'none');
  -- No case ⇒ not the initiator. Fail closed: absence must never read as authority.
  v_is_initiator := coalesce(v_case.is_initiator, false);

  -- The caller's OWN claim packet.
  select k.status, k.submitted_at, k.decided_at
    into v_claim
    from public.claim_packets k
   where k.estate_id   = p_estate
     and k.requested_by = v_uid
   order by (k.status <> 'rejected') desc, k.submitted_at desc
   limit 1;

  /**
   * ★ ACTIONS ARE DERIVED FROM THE SAME AUTHORITIES THE MUTATIONS ENFORCE, so the list cannot
   * promise something the door would refuse. It is advisory, never an authorization: every action
   * below is re-checked by the routine that performs it.
   *
   * ★ THAT CLAIM WAS FALSE FOR `cancel_verification` UNTIL PHASE 11-MF, AND THE ASYMMETRY IS THE
   * POINT. The two open-case actions do NOT share a gate:
   *
   *   attach_death_verification_evidence — is_estate_executor + case open.      ANY active executor.
   *   cancel_death_verification_case     — is_estate_executor + initiated_by = auth.uid().  INITIATOR.
   *
   * They were emitted together as one literal, so a co-fiduciary who did not start the process was
   * offered a cancel the door refuses with `not_authorized`. A list that over-promises is worse than no
   * list: a client that trusts it renders a control that always fails, and a client that distrusts it
   * has no reason to consult it at all.
   */
  if v_case_state <> 'open' and v_lifecycle = 'active' then
    v_actions := v_actions || '["initiate_verification"]'::jsonb;
  end if;
  if v_case_state = 'open' then
    v_actions := v_actions || '["attach_evidence"]'::jsonb;
  end if;
  if v_case_state = 'open' and v_is_initiator then
    v_actions := v_actions || '["cancel_verification"]'::jsonb;
  end if;
  if v_claim.status is null then
    v_actions := v_actions || '["submit_claim"]'::jsonb;
  end if;

  return jsonb_build_object(
    'authorized', true,
    'capacity',   v_capacity,
    'verification', jsonb_build_object(
      /**
       * ★ THE HANDLE CANCELLATION NEEDS, SCOPED TO THE ONE CALLER WHO CAN USE IT.
       *
       * Null unless this caller initiated the open case. A co-fiduciary already learns the case's
       * state, level and timestamps here, so the uuid carries no further estate content — but they
       * cannot cancel, so handing them the handle would serve nothing and widen the surface for
       * nothing. `attach_evidence` is an any-executor action that will need this id too; extending it
       * is a deliberate decision for the phase that binds attach, not a default granted in advance.
       */
      'case_id',        case when v_is_initiator then v_case.case_id else null end,
      /** Caller-scoped fact about THEMSELVES. Never names the initiator. */
      'is_initiator',   v_is_initiator,
      'state',          v_case_state,
      'required_level', v_required,
      -- The bar recorded when the case opened, which may differ from today's policy.
      'level_at_initiation', v_case.required_level_at_initiation,
      'attained_level', v_case.attained_level,
      'initiated_at',   v_case.created_at,
      'decided_at',     v_case.decided_at
    ),
    'claim', jsonb_build_object(
      'state',        coalesce(v_claim.status, 'none'),
      'submitted_at', v_claim.submitted_at,
      'decided_at',   v_claim.decided_at
    ),
    'process', jsonb_build_object(
      'challenge_window_open', v_lifecycle = 'challenge_window',
      'challenge_halted',      v_lifecycle = 'challenge_halted',
      'release_completed',     v_lifecycle = 'released'
    ),
    'actions', v_actions
  );
end
$$;


ALTER FUNCTION "public"."get_executor_workspace"("p_estate" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_my_estate_capability_facts"("p_estate" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid           uuid := auth.uid();
  v_estate_exists boolean;
  v_is_owner      boolean;
  v_role          text;
  v_status        text;
begin
  select exists(select 1 from public.estates e where e.id = p_estate)
    into v_estate_exists;

  select exists(select 1 from public.estates e where e.id = p_estate and e.owner_id = v_uid)
    into v_is_owner;

  -- estate_memberships is UNIQUE(estate_id, user_id) — at most one row; limit 1 is defensive.
  select m.role, m.status
    into v_role, v_status
    from public.estate_memberships m
   where m.estate_id = p_estate and m.user_id = v_uid
   limit 1;

  return jsonb_build_object(
    'estate_id',         p_estate,
    'estate_exists',     v_estate_exists,
    'is_owner',          v_is_owner,
    'membership_role',   v_role,
    'membership_status', v_status
  );
end;
$$;


ALTER FUNCTION "public"."get_my_estate_capability_facts"("p_estate" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_my_estate_designations"() RETURNS TABLE("estate_id" "uuid", "designation_type" "text", "status" "text")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select d.estate_id, d.designation_type, d.status
  from public.estate_designations d
  where d.user_id = auth.uid() and d.status = 'active';
$$;


ALTER FUNCTION "public"."get_my_estate_designations"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_my_fiduciary_estates"() RETURNS TABLE("estate_id" "uuid", "estate_display_name" "text", "capacity" "text")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select d.estate_id,
         e.name,
         min(d.designation_type)
    from public.estate_designations d
    join public.estates e on e.id = d.estate_id
   where d.user_id = auth.uid()
     and d.status = 'active'
     and d.designation_type in ('executor', 'trustee')
   group by d.estate_id, e.name;
$$;


ALTER FUNCTION "public"."get_my_fiduciary_estates"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_my_fiduciary_estates"() IS 'Phase 11-MB. Enumerates estates on which the CALLER holds an active executor/trustee designation, for estate-context selection ONLY. Returns estate id, display name and one deterministic capacity; no tier, grant, membership, asset, valuation, document, beneficiary or lifecycle fact. Discovery is not disclosure: appearing here makes an estate selectable and readable by nothing. Scoped to auth.uid() with no caller parameter, so no one can enumerate another person''s fiduciary relationships.';



CREATE OR REPLACE FUNCTION "public"."get_owner_safety_status"("p_estate" "uuid") RETURNS "text"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid   uuid := auth.uid();
  v_state text;
begin
  if v_uid is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;
  if not public.is_estate_owner(p_estate) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  v_state := public.estate_lifecycle_state(p_estate);
  -- ★ THE 11-F STATE JOINS THE `challengeable` GROUP, and that is the safety-preserving mapping:
  -- an owner who has just received the email is squarely in the population this surface exists for.
  -- The union stays four values on purpose — the owner needs "can I stop this", never the machine's
  -- internals, and a client that could distinguish dispatched from windowed would be a client with
  -- something to branch on.
  return case v_state
    when 'death_verification_pending'    then 'challengeable'
    when 'death_verified'                then 'challengeable'
    when 'owner_notification_dispatched' then 'challengeable'
    when 'challenge_window'              then 'challengeable'
    when 'challenge_halted'              then 'halted'
    when 'released'                      then 'released'
    else 'none'
  end;
end $$;


ALTER FUNCTION "public"."get_owner_safety_status"("p_estate" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_owner_safety_status"("p_estate" "uuid") IS 'Owner-scoped safety status (Phase 11-E): a closed presentation union (none / challengeable / halted / released) over the authoritative lifecycle, for the challenge surface. Owner-only; every other caller refuses byte-identically. Not an authorization and not a disclosure: it answers about the process, never about estate content.';



CREATE OR REPLACE FUNCTION "public"."get_professional_workspace"("p_estate" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
$$;


ALTER FUNCTION "public"."get_professional_workspace"("p_estate" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_professional_workspace"("p_estate" "uuid") IS 'Phase 10-D. The professional delegate''s view of ONE estate: their relationship, any fiduciary capacity, what the owner released to them (delegated to get_estate_discovery and can_access_document), and the state of their own access request. Gated on an APPROVED professional_delegate membership — never on a capability combination, a grant, or a designation. The owner is refused. Carries no readiness, no score, and no count of anything withheld.';



CREATE OR REPLACE FUNCTION "public"."get_upload_policy"() RETURNS TABLE("max_upload_bytes" bigint, "max_files_per_claim" integer, "max_aggregate_bytes" bigint, "allowed_mime_types" "text"[])
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select p.max_upload_bytes, p.max_files_per_claim, p.max_aggregate_bytes, p.allowed_mime_types
  from public.upload_policy p where p.id = 1;
$$;


ALTER FUNCTION "public"."get_upload_policy"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  insert into public.profiles (id, email, full_name)
  values (new.id, new.email, new.raw_user_meta_data ->> 'full_name');
  return new;
end;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."initiate_death_verification_case"("p_estate" "uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid          uuid := auth.uid();
  v_designation  uuid;
  v_capacity     text;
  v_state        text;
  v_juris        text;
  v_required     public.verification_level;
  v_case         uuid;
begin
  if v_uid is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;
  if not public.is_estate_executor(p_estate, v_uid) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  -- The designation that authorizes this initiation, captured as fact on the case. Deterministic
  -- when the caller holds both capacities: 'executor' precedes 'trustee' (current product
  -- semantics rank them identically for initiation; the recorded capacity is a fact, not a power).
  select d.id, d.designation_type
    into v_designation, v_capacity
    from public.estate_designations d
   where d.estate_id = p_estate
     and d.user_id = v_uid
     and d.designation_type in ('executor', 'trustee')
     and d.status = 'active'
   order by d.designation_type
   limit 1;

  -- One live death-verification process per estate. An open case holds the lifecycle at
  -- death_verification_pending; a verified case holds it at death_verified. Both refuse a new
  -- initiation. Only an authorized designee can reach this sentinel, so it is not an oracle.
  v_state := public.estate_lifecycle_state(p_estate);
  if v_state <> 'active' then
    raise exception 'lifecycle_conflict' using errcode = 'P0001';
  end if;

  select e.jurisdiction into v_juris from public.estates e where e.id = p_estate;

  -- The policy engine's answer AT INITIATION, recorded on the case. Fail-closed inside the engine:
  -- unknown / unapproved / NULL jurisdiction answers 'enhanced_kyc'. NEVER copied into attained.
  v_required := public.required_verification_level(p_estate);

  insert into public.death_verification_cases
    (estate_id, event_type, status, initiated_by, initiator_designation_id, initiator_capacity,
     jurisdiction_context, required_level_at_initiation)
  values
    (p_estate, 'death', 'open', v_uid, v_designation, v_capacity, v_juris, v_required)
  returning id into v_case;

  perform public.apply_estate_lifecycle_transition(
    p_estate, 'death_verification_pending', v_case, 'case_initiated');

  perform public.write_audit(
    'death_case.initiated', 'death_verification_cases', v_case, p_estate,
    jsonb_build_object('case_id', v_case, 'event_type', 'death',
                       'initiator_capacity', v_capacity,
                       'required_level_at_initiation', v_required::text,
                       'jurisdiction_known', v_juris is not null));
  return v_case;
end $$;


ALTER FUNCTION "public"."initiate_death_verification_case"("p_estate" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."inventory_disclosure_tier"("p_estate" "uuid", "p_uid" "uuid") RETURNS "text"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
$$;


ALTER FUNCTION "public"."inventory_disclosure_tier"("p_estate" "uuid", "p_uid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."invitation_delivery_health"() RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_result jsonb;
begin
  perform public.admin_require_gate();

  select jsonb_build_object(
    'queued_count',            count(*) filter (where status = 'queued'),
    'processing_count',        count(*) filter (where status = 'processing'),
    'retry_pending_count',     count(*) filter (where status = 'retryPending'),
    'outcome_uncertain_count', count(*) filter (where status = 'outcomeUncertain'),
    'failed_permanent_count',  count(*) filter (where status = 'failedPermanent'),
    'provider_accepted_last_24h',
        count(*) filter (where status = 'providerAccepted' and issued_at > now() - interval '24 hours'),
    -- headline signal: how long the oldest un-dispatched row has waited.
    'oldest_pending_age_seconds',
        coalesce(extract(epoch from (now() - min(requested_at)
          filter (where status in ('queued', 'retryPending', 'processing'))))::bigint, 0),
    'max_attempts_seen',       coalesce(max(attempts) filter (where status <> 'providerAccepted'), 0),
    'last_provider_acceptance_at', max(issued_at) filter (where status = 'providerAccepted')
  )
  into v_result
  from public.invitation_delivery_outbox;

  return v_result;
end;
$$;


ALTER FUNCTION "public"."invitation_delivery_health"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."invitation_effective_status"("p_status" "text", "p_expires_at" timestamp with time zone) RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO 'public'
    AS $$
  select case
    when p_status in ('pending', 'matched') and p_expires_at <= now() then 'expired'
    else p_status
  end;
$$;


ALTER FUNCTION "public"."invitation_effective_status"("p_status" "text", "p_expires_at" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."invitation_preview"("p_token" "text") RETURNS TABLE("token_fingerprint" "text", "invitation_kind" "text", "proposed_role" "text", "estate_display_name" "text", "inviter_display_name" "text", "invitee_email_hint" "text", "invitee_phone_hint" "text", "expires_at" timestamp with time zone, "is_expired" boolean, "is_revoked" boolean)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_hash text;
  v_fp text;
  v_inv record;
begin
  -- Validate input shape early to avoid spending DB time on garbage.
  if p_token is null or length(p_token) < 16 or length(p_token) > 512 then
    return;
  end if;

  v_hash := encode(digest(p_token, 'sha256'), 'hex');

  -- Use first 12 hex chars to match iOS fingerprint length.
  -- The iOS InvitationToken.fingerprint uses SHA256 truncated to 12 chars.
  v_fp := substr(v_hash, 1, 12);

  select * into v_inv
  from public.invitations
  where token_hash = v_hash
  limit 1;

  if not found then
    return; -- empty result set; do not leak existence
  end if;

  return query select
    v_fp,
    v_inv.kind::text,
    v_inv.proposed_role::text,
    case when (v_inv.preview_visibility->>'showEstateName')::boolean is true
         then v_inv.estate_display_name else null end,
    case when (v_inv.preview_visibility->>'showInviterName')::boolean is true
         then v_inv.inviter_display_name else null end,
    v_inv.invitee_email_hint,
    v_inv.invitee_phone_hint,
    v_inv.expires_at,
    (v_inv.expires_at < now()),
    (v_inv.status = 'revoked');
end;
$$;


ALTER FUNCTION "public"."invitation_preview"("p_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."invitation_write_gate"("p_estate" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if auth.uid() is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;
  if not (public.is_estate_owner(p_estate) or public.is_admin()) then
    raise exception 'owner_or_admin_required' using errcode = '42501';
  end if;
  if not public.is_estate_owner(p_estate) then
    -- admin (non-owner) branch
    perform public.require_aal2();
    if extract(epoch from now())::bigint - coalesce((auth.jwt() ->> 'iat')::bigint, 0) > 900 then
      raise exception 'stale_token_reauth_required' using errcode = '42501';
    end if;
  end if;
end;
$$;


ALTER FUNCTION "public"."invitation_write_gate"("p_estate" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;


ALTER FUNCTION "public"."is_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_estate_executor"("p_estate" "uuid", "p_user" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1 from public.estate_designations d
    where d.estate_id = p_estate
      and d.user_id    = p_user
      and d.designation_type in ('executor','trustee')
      and d.status = 'active'
  );
$$;


ALTER FUNCTION "public"."is_estate_executor"("p_estate" "uuid", "p_user" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_estate_member"("p_estate_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1 from estate_memberships
    where estate_id = p_estate_id
      and user_id = auth.uid()
      and status = 'approved'
  )
$$;


ALTER FUNCTION "public"."is_estate_member"("p_estate_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_estate_owner"("p_estate_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1 from estates
    where id = p_estate_id and owner_id = auth.uid()
  )
$$;


ALTER FUNCTION "public"."is_estate_owner"("p_estate_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_ownership_role"("p_role" "text") RETURNS boolean
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO 'public', 'extensions'
    AS $$
  SELECT p_role IN ('primary_user');
$$;


ALTER FUNCTION "public"."is_ownership_role"("p_role" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."issue_invitation_delivery"("p_outbox_id" "uuid") RETURNS TABLE("invitation_id" "uuid", "raw_token" "text", "invitee_email" "text", "invitee_phone" "text", "estate_display_name" "text", "inviter_display_name" "text", "preview_visibility" "jsonb", "expires_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare v_out record; v_inv record; v_raw text; v_hash text;
begin
  select * into v_out from public.invitation_delivery_outbox
   where id = p_outbox_id and status = 'pending' for update skip locked;
  if not found then raise exception 'outbox_entry_not_claimable' using errcode = 'P0002'; end if;

  select * into v_inv from public.invitations where id = v_out.invitation_id for update;
  if not found then
    update public.invitation_delivery_outbox
       set status = 'failed', attempts = attempts + 1, last_error = 'invitation_missing'
     where id = p_outbox_id;
    raise exception 'invitation_not_found' using errcode = 'P0002';
  end if;

  -- Never issue a secret for an invitation that is no longer actionable.
  if public.invitation_effective_status(v_inv.status, v_inv.expires_at) not in ('pending', 'matched') then
    update public.invitation_delivery_outbox
       set status = 'failed', attempts = attempts + 1, last_error = 'invitation_not_actionable'
     where id = p_outbox_id;
    raise exception 'invitation_not_actionable' using errcode = 'P0005';
  end if;

  v_raw  := encode(gen_random_bytes(32), 'hex');       -- 64 hex chars, within bind/preview's 16..512
  v_hash := encode(digest(v_raw, 'sha256'), 'hex');    -- ONLY the hash is stored

  update public.invitations set token_hash = v_hash, updated_at = now() where id = v_inv.id;
  update public.invitation_delivery_outbox
     set status = 'issued', attempts = attempts + 1, issued_at = now()
   where id = p_outbox_id;

  -- The audit records the FINGERPRINT, never the token.
  perform public.write_audit('invitation.delivery_issued', 'invitations', v_inv.id, v_inv.estate_id,
    jsonb_build_object('invitation_id', v_inv.id, 'token_fingerprint', substr(v_hash, 1, 12)));

  return query select v_inv.id, v_raw, v_inv.invitee_email, v_inv.invitee_phone,
                      v_inv.estate_display_name, v_inv.inviter_display_name,
                      v_inv.preview_visibility, v_inv.expires_at;
end;
$$;


ALTER FUNCTION "public"."issue_invitation_delivery"("p_outbox_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."issue_invitation_delivery_notice"("p_outbox_id" "uuid") RETURNS TABLE("invitation_id" "uuid", "delivery_generation" integer, "idempotency_key" "text", "invitee_email" "text", "estate_display_name" "text", "inviter_display_name" "text", "preview_visibility" "jsonb", "expires_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_out record; v_inv record; v_gen int; v_key text;
begin
  select * into v_out from public.invitation_delivery_outbox
   where id = p_outbox_id and status = 'processing' for update;
  if not found then raise exception 'outbox_entry_not_claimed' using errcode = 'P0002'; end if;

  select * into v_inv from public.invitations where id = v_out.invitation_id for update;
  if not found then raise exception 'invitation_not_found' using errcode = 'P0002'; end if;

  -- The claim already excluded terminal invitations; this catches one that turned terminal in
  -- between, and settles the row rather than emailing about an invitation that no longer exists.
  if public.invitation_effective_status(v_inv.status, v_inv.expires_at) not in ('pending', 'matched') then
    update public.invitation_delivery_outbox
       set status = 'cancelled', last_outcome_at = now() where id = p_outbox_id;
    raise exception 'invitation_not_actionable' using errcode = 'P0005';
  end if;

  v_gen := v_out.delivery_generation + 1;
  -- Identical derivation to 0043: surrogate server identifiers only. Never a token (there is
  -- none), never the recipient address.
  v_key := 'afterworth/invitation/' || p_outbox_id::text || '/' || v_gen::text;

  update public.invitation_delivery_outbox
     set delivery_generation = v_gen,
         idempotency_key = v_key,
         provider_message_id = null,   -- a new generation has no provider handle yet
         failure_class = null
   where id = p_outbox_id;

  -- ★ NOTE WHAT IS ABSENT: no update to invitations.token_hash, and no token_fingerprint in the
  --   audit — because no secret was created. An auditor reading this row must not be able to
  --   conclude that a credential is in circulation.
  perform public.write_audit('invitation.delivery_notice_issued', 'invitations', v_inv.id, v_inv.estate_id,
    jsonb_build_object('invitation_id', v_inv.id, 'outbox_id', p_outbox_id,
                       'delivery_generation', v_gen));

  return query select v_inv.id, v_gen, v_key, v_inv.invitee_email,
                      v_inv.estate_display_name, v_inv.inviter_display_name,
                      v_inv.preview_visibility, v_inv.expires_at;
end;
$$;


ALTER FUNCTION "public"."issue_invitation_delivery_notice"("p_outbox_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."issue_invitation_delivery_notice"("p_outbox_id" "uuid") IS 'Token-free delivery issue step. Prepares an INFORMATIONAL notice: no secret is minted and invitations.token_hash is not touched. Supersedes issue_invitation_delivery_token for the production flow; that function is retained for backward compatibility.';



CREATE OR REPLACE FUNCTION "public"."issue_invitation_delivery_token"("p_outbox_id" "uuid") RETURNS TABLE("invitation_id" "uuid", "raw_token" "text", "delivery_generation" integer, "idempotency_key" "text", "invitee_email" "text", "estate_display_name" "text", "inviter_display_name" "text", "preview_visibility" "jsonb", "expires_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare v_out record; v_inv record; v_raw text; v_hash text; v_gen int; v_key text;
begin
  select * into v_out from public.invitation_delivery_outbox
   where id = p_outbox_id and status = 'processing' for update;
  if not found then raise exception 'outbox_entry_not_claimed' using errcode = 'P0002'; end if;

  select * into v_inv from public.invitations where id = v_out.invitation_id for update;
  if not found then raise exception 'invitation_not_found' using errcode = 'P0002'; end if;

  -- Belt and braces: the claim already excluded terminal invitations, but never mint a secret for
  -- one that turned terminal in between.
  if public.invitation_effective_status(v_inv.status, v_inv.expires_at) not in ('pending', 'matched') then
    update public.invitation_delivery_outbox
       set status = 'cancelled', last_outcome_at = now() where id = p_outbox_id;
    raise exception 'invitation_not_actionable' using errcode = 'P0005';
  end if;

  v_gen  := v_out.delivery_generation + 1;
  v_raw  := encode(gen_random_bytes(32), 'hex');      -- 64 hex chars, inside bind/preview's 16..512
  v_hash := encode(digest(v_raw, 'sha256'), 'hex');   -- ONLY the hash is stored
  -- Derived from surrogate server identifiers ONLY — never the raw token, never the recipient.
  v_key  := 'afterworth/invitation/' || p_outbox_id::text || '/' || v_gen::text;

  update public.invitations set token_hash = v_hash, updated_at = now() where id = v_inv.id;
  update public.invitation_delivery_outbox
     set delivery_generation = v_gen,
         idempotency_key = v_key,
         provider_message_id = null,   -- a new generation has no provider handle yet
         failure_class = null
   where id = p_outbox_id;

  perform public.write_audit('invitation.delivery_issued', 'invitations', v_inv.id, v_inv.estate_id,
    jsonb_build_object('invitation_id', v_inv.id, 'outbox_id', p_outbox_id,
                       'delivery_generation', v_gen,
                       'token_fingerprint', substr(v_hash, 1, 12)));

  return query select v_inv.id, v_raw, v_gen, v_key, v_inv.invitee_email,
                      v_inv.estate_display_name, v_inv.inviter_display_name,
                      v_inv.preview_visibility, v_inv.expires_at;
end;
$$;


ALTER FUNCTION "public"."issue_invitation_delivery_token"("p_outbox_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."link_asset_document"("p_asset_id" "uuid", "p_doc_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid        uuid := auth.uid();
  v_asset_est  uuid;
  v_doc_est    uuid;
begin
  if v_uid is null then raise exception 'auth_required' using errcode = '42501'; end if;

  select estate_id into v_asset_est from public.estate_assets where id = p_asset_id;
  if not found then raise exception 'asset_not_found' using errcode = 'P0002'; end if;
  select estate_id into v_doc_est from public.documents where id = p_doc_id;
  if not found then raise exception 'document_not_found' using errcode = 'P0002'; end if;

  if not public.is_estate_owner(v_asset_est) then raise exception 'not_estate_owner' using errcode = '42501'; end if;
  if v_asset_est <> v_doc_est then raise exception 'cross_estate_link' using errcode = '42501'; end if;

  insert into public.estate_asset_documents (asset_id, doc_id, linked_by)
  values (p_asset_id, p_doc_id, v_uid)
  on conflict (asset_id, doc_id) do nothing;

  perform public.write_audit('estate_asset.document_linked', 'estate_assets', p_asset_id, v_asset_est,
    jsonb_build_object('doc_id', p_doc_id, 'via', 'link_asset_document'));
end;
$$;


ALTER FUNCTION "public"."link_asset_document"("p_asset_id" "uuid", "p_doc_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."list_estate_assets"("p_estate_id" "uuid") RETURNS TABLE("id" "uuid", "estate_id" "uuid", "connection_id" "uuid", "institution_name" "text", "provider_name" "text", "asset_group" "text", "asset_category" "text", "asset_subtype" "text", "source_type" "text", "masked_identifier" "text", "balance_cents" bigint, "currency" "text", "holdings" "jsonb", "refresh_timestamp" timestamp with time zone, "last_sync_status" "text", "confidence_level" "text", "verification_status" "text", "created_at" timestamp with time zone, "resolved_tier" "text", "range_low_cents" bigint, "range_high_cents" bigint)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid   uuid := auth.uid();
  v_role  text;
  v_bal   text;   -- account_balances tier
  v_inst  text;   -- institution_names tier
  v_det   text;   -- linked_account_details tier
begin
  if v_uid is null then return; end if;

  -- OWNER: inherent full value, no redaction.
  if public.is_estate_owner(p_estate_id) then
    -- aal2 GATE (option b): the owner branch emits EXACT balance_cents + holdings -> require MFA,
    -- UNCONDITIONALLY. (DEFINER bypasses RLS; the gate must be inline.)
    perform public.require_aal2();
    return query
      select a.id, a.estate_id, a.connection_id, a.institution_name, a.provider_name,
             a.asset_group, a.asset_category, a.asset_subtype, a.source_type,
             a.masked_identifier, a.balance_cents, a.currency, a.holdings,
             a.refresh_timestamp, a.last_sync_status, a.confidence_level,
             a.verification_status, a.created_at,
             'full_detail'::text, null::bigint, null::bigint
      from public.normalized_assets a
      where a.estate_id = p_estate_id
      order by a.created_at desc;
    return;
  end if;

  -- NON-OWNER: GRANT-BASED, like can_access_document — NOT membership-gated. A grantee reads via
  -- their grant even without an estate_memberships row (the documents precedent; a beneficiary can
  -- hold grants before/without a membership). grantee_role comes from the GRANT (explicit, singular),
  -- not the membership — so no multi-membership role-derivation ambiguity. The account_balances
  -- grant is the primary gate + the role source.
  select g.visibility_tier, g.grantee_role into v_bal, v_role
  from public.access_grants g
  where g.estate_id = p_estate_id
    and g.grantee_user_id = v_uid
    and g.category = 'account_balances'
    and g.status = 'active'
    -- ★ PHASE 11-B — canonical predicate, `legacy_immediate_only` (see asset_grant_tier above).
    -- 11-D: lifecycle wired through; inert under this policy, by decision (R12).
    and public.release_condition_satisfied(g.release_condition, g.approved_at, 'legacy_immediate_only',
                                           public.estate_lifecycle_state(p_estate_id))
  limit 1;

  -- No account_balances grant -> the non-owner sees NO asset rows (default-deny, safe).
  if v_bal is null then return; end if;

  v_inst := public.asset_grant_tier(p_estate_id, v_uid, 'institution_names');
  v_det  := public.asset_grant_tier(p_estate_id, v_uid, 'linked_account_details');

  -- Read-time ceiling re-check (authoritative), applied to EVERY resolved tier uniformly: an
  -- over-ceiling grant collapses to hidden, even if the grant predates a ceiling tightening. This
  -- is what makes exact value UNREACHABLE for a beneficiary — asset_category_grantable caps
  -- 'account_balances' at category_summary for role 'beneficiary', so v_bal can never become
  -- limited_detail/full_detail for them (the balance_cents AND holdings gates both key off v_bal).
  if not public.asset_category_grantable(v_role, 'account_balances', v_bal) then
    v_bal := 'hidden';
  end if;
  if v_inst is not null and not public.asset_category_grantable(v_role, 'institution_names', v_inst) then
    v_inst := 'hidden';
  end if;
  if v_det is not null and not public.asset_category_grantable(v_role, 'linked_account_details', v_det) then
    v_det := 'hidden';
  end if;

  -- aal2 GATE (option b) — TIER-AWARE, THE CORRECTNESS-CRITICAL PLACEMENT. Placed AFTER the ceiling
  -- re-check so it keys off the FINAL resolved tier. A non-owner sees EXACT balance_cents only at
  -- limited_detail/full_detail (and holdings only at full_detail, which implies v_bal='full_detail'),
  -- so this single check covers every exact-value field. Beneficiary tiers (range_only/category_summary)
  -- and hidden emit brackets/NULL -> NO exact value -> stay aal1 (the payoff of option b). Because
  -- asset_category_grantable caps 'account_balances' at category_summary for role 'beneficiary',
  -- v_bal can never reach limited/full for them, so this can only fire for a professional.
  if v_bal in ('limited_detail', 'full_detail') then
    perform public.require_aal2();
  end if;

  return query
    select
      a.id, a.estate_id, a.connection_id,
      -- institution name gated by institution_names (hidden/none -> masked)
      case when coalesce(v_inst, 'hidden') = 'hidden' then 'Protected Institution' else a.institution_name end,
      a.provider_name, a.asset_group, a.asset_category, a.asset_subtype, a.source_type,
      -- masked account identifier gated by linked_account_details
      case when coalesce(v_det, 'hidden') in ('limited_detail', 'full_detail') then a.masked_identifier else '••••' end,
      -- ★ THE VALUE: exact ONLY at limited/full; otherwise NULL (raw never leaves)
      case when v_bal in ('limited_detail', 'full_detail') then a.balance_cents else null end,
      a.currency,
      -- holdings only when BOTH balances=full_detail AND linked_account_details=full_detail
      case when v_bal = 'full_detail' and coalesce(v_det, 'hidden') = 'full_detail' then a.holdings else '[]'::jsonb end,
      a.refresh_timestamp, a.last_sync_status, a.confidence_level, a.verification_status, a.created_at,
      v_bal,
      -- The value bracket — ALWAYS coarse, never exact. range_only brackets the per-asset value;
      -- category_summary brackets the per-GROUP total (sum over asset_group, then bracketed) so a
      -- single-asset group can't leak its lone balance. Nothing exact leaves for a non-owner.
      case
        when v_bal = 'range_only'       then public.asset_bracket_low(a.balance_cents)
        -- sum(bigint) returns numeric -> cast back to bigint (asset_bracket_low takes bigint)
        when v_bal = 'category_summary' then public.asset_bracket_low((sum(a.balance_cents) over (partition by a.asset_group))::bigint)
        else null
      end,
      case
        when v_bal = 'range_only'       then public.asset_bracket_high(a.balance_cents)
        when v_bal = 'category_summary' then public.asset_bracket_high((sum(a.balance_cents) over (partition by a.asset_group))::bigint)
        else null
      end
    from public.normalized_assets a
    where a.estate_id = p_estate_id
    order by a.created_at desc;
end;
$$;


ALTER FUNCTION "public"."list_estate_assets"("p_estate_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."list_estate_invitations"("p_estate" "uuid", "p_limit" integer DEFAULT 50) RETURNS TABLE("invitation_id" "uuid", "kind" "text", "proposed_role" "text", "status" "text", "invitee_email_hint" "text", "invitee_phone_hint" "text", "token_fingerprint" "text", "created_at" timestamp with time zone, "expires_at" timestamp with time zone, "accepted_at" timestamp with time zone, "declined_at" timestamp with time zone, "revoked_at" timestamp with time zone, "delivery_state" "text", "can_revoke" boolean, "can_extend" boolean, "can_redeliver" boolean)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_limit int;
begin
  perform public.estate_owner_gate(p_estate);
  v_limit := least(greatest(coalesce(p_limit, 50), 1), 100);

  return query
  with projected as (
    select
      i.id, i.kind, i.proposed_role,
      public.invitation_effective_status(i.status, i.expires_at) as eff_status,
      i.invitee_email_hint, i.invitee_phone_hint,
      substr(i.token_hash, 1, 12) as fingerprint,
      i.created_at, i.expires_at, i.accepted_at, i.declined_at, i.revoked_at,
      coalesce(
        (select o.status from public.invitation_delivery_outbox o
          where o.invitation_id = i.id
          order by o.requested_at desc limit 1),
        'none'
      ) as raw_delivery
    from public.invitations i
    where i.estate_id = p_estate
  )
  select
    p.id, p.kind, p.proposed_role, p.eff_status,
    p.invitee_email_hint, p.invitee_phone_hint, p.fingerprint,
    p.created_at, p.expires_at, p.accepted_at, p.declined_at, p.revoked_at,
    -- Worker mechanics collapse to 'queued'; the honest outcomes pass through unchanged.
    case p.raw_delivery
      when 'queued'       then 'queued'
      when 'processing'   then 'queued'
      when 'retryPending' then 'queued'
      else p.raw_delivery
    end,
    (p.eff_status in ('pending', 'matched')),
    (p.eff_status in ('pending', 'matched')),
    (p.eff_status in ('pending', 'matched'))
  from projected p
  where p.eff_status in ('pending', 'matched')
     or coalesce(p.revoked_at, p.declined_at, p.accepted_at, p.expires_at) > now() - interval '90 days'
  order by p.created_at desc, p.id desc
  limit v_limit;
end;
$$;


ALTER FUNCTION "public"."list_estate_invitations"("p_estate" "uuid", "p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."list_estate_members"("p_estate_id" "uuid") RETURNS TABLE("user_id" "uuid", "role" "text", "status" "text", "email" "text", "full_name" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_user uuid := auth.uid();
begin
  -- Auth null-guard.
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;

  -- SECURITY SPINE. SECURITY DEFINER bypasses RLS, so this explicit owner-check IS the
  -- access boundary and MUST precede the read.
  if not public.is_estate_owner(p_estate_id) then
    raise exception 'not estate owner' using errcode = '42501';
  end if;

  return query
    select distinct m.user_id, m.role, m.status, p.email, p.full_name
    from public.estate_memberships m
    join public.profiles p on p.id = m.user_id
    where m.estate_id = p_estate_id
      and m.status = 'approved'
      and not public.is_ownership_role(m.role)
    order by p.email;
end;
$$;


ALTER FUNCTION "public"."list_estate_members"("p_estate_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."list_orphan_storage_objects"("p_grace_hours" integer DEFAULT 72, "p_max" integer DEFAULT 100) RETURNS TABLE("object_name" "text", "created_at" timestamp with time zone, "size_bytes" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  perform public.admin_require_gate();
  return query
    select o.name, o.created_at, (o.metadata->>'size')::bigint
    from storage.objects o
    where o.bucket_id = 'documents'
      and o.name not like '%.emptyFolderPlaceholder'
      and o.created_at < now() - make_interval(hours => greatest(coalesce(p_grace_hours, 72), 0))
      and not exists (select 1 from public.documents d where d.storage_path = o.name)
    order by o.created_at
    limit least(greatest(coalesce(p_max, 100), 1), 100);
end;
$$;


ALTER FUNCTION "public"."list_orphan_storage_objects"("p_grace_hours" integer, "p_max" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."mark_recovery_code_used"("p_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_user uuid := auth.uid();
  v_n    int;
begin
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;

  update public.recovery_codes
    set used_at = now()
    where id = p_id and user_id = v_user and used_at is null;

  get diagnostics v_n = row_count;
  return v_n > 0;
end;
$$;


ALTER FUNCTION "public"."mark_recovery_code_used"("p_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notification_estate_home"("p_estate_id" "uuid", "p_user_id" "uuid") RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select case
    when exists (
      select 1 from public.estate_memberships m
      where m.estate_id = p_estate_id
        and m.user_id = p_user_id
        and m.role = 'professional_delegate'
        and m.status = 'approved'
    ) then 'afterworth://workspace'
    else 'afterworth://estate-summary'
  end;
$$;


ALTER FUNCTION "public"."notification_estate_home"("p_estate_id" "uuid", "p_user_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."notification_estate_home"("p_estate_id" "uuid", "p_user_id" "uuid") IS 'Closed set of two in-app destinations for a lifecycle notification, chosen from authoritative membership. Not an authorization: both destinations re-check their own authority on arrival.';



CREATE OR REPLACE FUNCTION "public"."notification_event_copy"("p_event" "text") RETURNS TABLE("category" "text", "title" "text", "body" "text")
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO 'public'
    AS $$
  select c.category, c.title, c.body
  from (values
    -- ── access requests ───────────────────────────────────────────────────────────────────────
    -- To the OWNER. Says a member requested access; says nothing about WHICH member, because the
    -- brief's own example ("A professional delegate requested access") would make copy vary by
    -- role, and role-varying copy is interpolation wearing a switch statement.
    ('access_request.created',  'accessRequest',  'Access request received',
     'A member of this estate requested access.'),
    -- To the REQUESTER, about their OWN request. Their own outcome is always theirs to know.
    ('access_request.approved', 'accessGranted',  'Access request approved',
     'Your request for access was approved.'),
    ('access_request.denied',   'accessRequest',  'Access request decided',
     'Your request for access was not approved.'),

    -- ── grants ────────────────────────────────────────────────────────────────────────────────
    -- To the GRANTEE, and only for a grant that is LIVE RIGHT NOW — see notification_grant_is_live.
    ('access_grant.created',    'accessGranted',  'Access granted',
     'You have access to shared estate information.'),
    -- ★ THE REVOKE COPY NAMES NOTHING. Not the document, not the category, not the tier. Whatever
    -- was authorized a moment ago may not be authorized now, and a notification row outlives the
    -- grant it describes.
    ('access_grant.revoked',    'accessChanged',  'Access updated',
     'Your access to shared estate information has changed.'),

    -- ── invitations ───────────────────────────────────────────────────────────────────────────
    -- To the OWNER, who issued the invitation and therefore already knows the invitee. This says
    -- LESS than the owner knows, which is the correct direction to err.
    ('invitation.accepted',     'invitationUpdate', 'Invitation accepted',
     'Someone you invited has joined this estate.'),
    ('invitation.declined',     'invitationUpdate', 'Invitation declined',
     'An invitation to this estate was declined.'),

    -- ── the owner safety notice (Phase 11-E) ────────────────────────────────────────────────────
    -- To the OWNER, and ONLY the owner, when the challenge window opens on their estate. The copy
    -- uses exactly the epistemically honest claims the 11-E brief sanctions: a process is waiting,
    -- and the owner can halt it. It asserts no death, names no claimant, no evidence, no deadline
    -- arithmetic, and no estate name. Emitted by begin_challenge_window, which REQUIRES this row
    -- to commit before the window may open — the one notification in the product that is
    -- load-bearing rather than a heads-up.
    ('death_process.window_opened', 'safetyNotice', 'A release process is waiting',
     'A release process is waiting on your estate. You can review and halt it now.'),

    -- ── the halt, to the INITIATING FIDUCIARY (Phase 11-L) ──────────────────────────────────────
    -- To the executor or trustee who OPENED the case, and to nobody else. It tells them one fact
    -- about their OWN action — the same posture as `access_request.denied`, which tells a requester
    -- their own outcome without explaining the decision.
    --
    -- ★ THE VOICE IS PASSIVE ON PURPOSE. "has been halted", never "the owner halted it". Naming the
    -- owner as the actor would disclose that the owner is alive and responded, which is a fact about
    -- a living person's liveness on a channel the recipient has no authority over. The recipient
    -- needs to know their process stopped; they do not need to know who stopped it or how.
    --
    -- ★ AND IT EXPLAINS NOTHING. No channel, no address, no reason, no evidence, no estate name, no
    -- asset, no count, no other party, and no word that could read as an accusation. A claimant who
    -- acted in good faith and a claimant who did not receive the identical sentence, because this
    -- routine cannot tell them apart and must not appear to.
    --
    -- ★ CATEGORY `claimUpdate` IS DELIBERATE AND COSTS THE CLIENT NOTHING. It is already in the RN
    -- client's KNOWN_CATEGORIES with the label "Claim update", and no server event used it before —
    -- so this event decodes exactly rather than degrading to `other` ("Account update"). Inventing a
    -- new category would have required a mobile release to render this event honestly.
    ('death_process.halted',        'claimUpdate',  'Estate process halted',
     'The estate process you initiated has been halted.')
  ) as c(event, category, title, body)
  where c.event = p_event;
$$;


ALTER FUNCTION "public"."notification_event_copy"("p_event" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."notification_event_copy"("p_event" "text") IS 'Immutable closed catalog of lifecycle notification copy, keyed by event name. Returns ZERO rows for an unknown event, which emit_lifecycle_notification treats as a refusal to emit. This is the ONLY place notification copy exists; emitters name an event and never compose text.';



CREATE OR REPLACE FUNCTION "public"."notification_grant_is_live"("p_status" "text", "p_release_condition" "text", "p_approved_at" timestamp with time zone) RETURNS boolean
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO 'public'
    AS $$
  -- ★ PHASE 11-B — the release rule is no longer written here. This was one of seven copies of it;
  -- it is now one call to the canonical authority, under the SAME `'standard'` policy
  -- `can_access_document` uses. That is what makes the paragraph above ("every state accepted here
  -- is accepted by can_access_document") a structural fact rather than a claim two files apart have
  -- to keep agreeing about by hand.
  --
  -- ★ PHASE 11-D — THE LIFECYCLE ARGUMENT IS PINNED TO THE BASE STATE, DELIBERATELY. This predicate
  -- decides whether to SPEAK, and it may speak only about access that holds WITHOUT reference to any
  -- lifecycle event: a "You have access" emitted because an estate is death_verified IS the release
  -- announcement Phase 11-F owns the copy for, and 11-D emits no death or release fact (R11, §16).
  -- Pinning 'active' keeps every emission byte-identical to Phase 10-E — which the source↔deployment
  -- reconciler requires (this function's full truth table is compared EXACT against production) —
  -- and keeps the subset property: everything accepted here is still accepted by the read path,
  -- while the read path may now accept more. The quiet direction costs a heads-up and nothing else.
  -- This literal is the ONE sanctioned non-seam lifecycle argument in the codebase, pinned by
  -- `test/deathVerificationFoundation.test.ts`; every disclosure evaluator passes
  -- `public.estate_lifecycle_state(<estate>)`.
  --
  -- The STATUS half stays here, because it is not a release-condition question: a revoked grant is
  -- not a dormant condition, it is a grant that no longer exists for this purpose.
  select p_status = 'active'
     and public.release_condition_satisfied(p_release_condition, p_approved_at, 'standard', 'active');
$$;


ALTER FUNCTION "public"."notification_grant_is_live"("p_status" "text", "p_release_condition" "text", "p_approved_at" timestamp with time zone) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."notification_grant_is_live"("p_status" "text", "p_release_condition" "text", "p_approved_at" timestamp with time zone) IS 'True only for a grant that confers access in the BASE lifecycle, a deliberate subset of can_access_document''s rule since 11-D: the lifecycle argument is pinned to active, so a death-conditioned grant emits NOTHING even at death_verified — release announcements are 11-F copy, not a side effect of grant emission. Claim-conditioned grants stay dormant. Decides whether to SPEAK, never what may be READ — no read path consults it.';



CREATE OR REPLACE FUNCTION "public"."owner_notice_age_gate"() RETURNS interval
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select public.challenge_window_duration() + interval '1 day';
$$;


ALTER FUNCTION "public"."owner_notice_age_gate"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."owner_notice_age_gate"() IS 'How old an owner safety notice may be and still be worth sending (Phase 11-F): the challenge window plus one day of queue slack, DERIVED so the two cannot drift apart. NULL when the window is unconfigured, which makes the claim routine refuse rather than treat everything as fresh.';



CREATE OR REPLACE FUNCTION "public"."owner_notice_census"() RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_gate interval; v_out jsonb;
begin
  perform public.admin_require_gate();
  v_gate := public.owner_notice_age_gate();

  -- ★ TWO SEPARATE AGGREGATIONS, COMBINED — NOT A LATERAL JOIN. The first draft joined a
  -- per-status GROUP BY laterally onto the row set, which returns every status group for EVERY row:
  -- three rows across three statuses became nine, and `total` reported 9. The status map looked
  -- right (duplicate keys resolve last-wins), so a test asserting only the presence of keys passed
  -- while the headline number was triple the truth. A census whose total is wrong is worse than no
  -- census — it is the number an operator would quote when deciding whether to purge.
  with rows as (
    select o.status, o.requested_at, o.claimed_at,
           -- ★ PHASE 11-OC. The three facts that make the Phase D blast radius countable.
           o.notice_accepted_at, o.case_id, o.superseded_by, o.generation
      from public.owner_notice_outbox o
  ),
  by_gen as (
    select coalesce(jsonb_object_agg(t.generation::text, t.n), '{}'::jsonb) as m
      from (select r.generation, count(*) as n from rows r group by r.generation) t
  ),
  by_status as (
    select coalesce(jsonb_object_agg(t.status, t.n), '{}'::jsonb) as m
      from (select r.status, count(*) as n from rows r group by r.status) t
  )
  select jsonb_build_object(
    'total', (select count(*) from rows),
    'by_status', (select m from by_status),
    'age_gate', v_gate::text,
    'oldest_requested_at', (select min(r.requested_at) from rows r),
    'newest_requested_at', (select max(r.requested_at) from rows r),
    'actionable', (select count(*) from rows r
                    where r.status = 'queued'
                      and v_gate is not null and r.requested_at >= now() - v_gate),
    'stale', (select count(*) from rows r
               where r.status in ('queued', 'processing')
                 and v_gate is not null and r.requested_at < now() - v_gate),
    -- ★ 11-K: without this key an `outcomeUncertain` row would appear in `total` and `by_status`
    -- and in NONE of the three splits, so an operator reconciling actionable+stale+purgeable
    -- against the total would find a gap with no name — and a nameless gap in a safety queue is
    -- the number someone eventually explains away. It is counted separately rather than folded
    -- into `purgeable` because it is deliberately NOT purgeable.
    'uncertain', (select count(*) from rows r where r.status = 'outcomeUncertain'),
    'purgeable', (select count(*) from rows r
                   where r.status in ('dispatched', 'failedPermanent', 'cancelled')),
    -- ★ PHASE 11-OBR / OB-1 — THE STUCK-CLAIM SPLIT, WITHOUT WHICH THIS DEFECT IS INVISIBLE.
    --
    -- The Branch A notice sat at `processing` for a day and nothing anywhere said so: `by_status`
    -- carried a `processing: 1` that reads as healthy in-flight work, and there was no way to ask
    -- how long it had been in flight. These three keys are what turn "a notice is being sent" into
    -- "a notice has been abandoned", which is a different operational fact entirely.
    --
    -- `processing_stale` uses the SAME predicate the drain reclaims by — including its NULL branch —
    -- read from `owner_notice_claim_visibility()` rather than restated, so this number is exactly
    -- "rows the next drain will pick up" and not an approximation of it.
    'processing_total', (select count(*) from rows r where r.status = 'processing'),
    'processing_stale', (select count(*) from rows r
                          where r.status = 'processing'
                            and (r.claimed_at is null
                                 or r.claimed_at < now() - public.owner_notice_claim_visibility())),
    -- Age of the OLDEST claim still in flight, as an interval string. NULL when nothing is
    -- processing. A legacy row with no claimed_at cannot have an age computed, so it reports NULL
    -- here and is counted in `processing_stale` above — the count is the alarm, this is the detail.
    'oldest_processing_age', (select (now() - min(r.claimed_at))::text from rows r
                               where r.status = 'processing' and r.claimed_at is not null),
    -- ────────────────────────────────────────────────────────────────────────────────────────
    -- ★ PHASE 11-OC — THE ACCEPTANCE AND EPISODE SPLITS.
    -- ────────────────────────────────────────────────────────────────────────────────────────
    --
    -- These four keys are what make the Phase D blast radius a NUMBER instead of an argument. They
    -- follow the `uncertain` key's discipline exactly: every row must land in a NAMED split, because
    -- a nameless gap in a safety queue is the number someone eventually explains away.
    --
    -- The reconciliation an operator can perform, and which the suite asserts:
    --
    --   accepted_total + unaccepted_total            = total
    --   legacy_unaccepted ⊆ unaccepted_total         (it is the `dispatched` slice of it)
    --   sum(by_generation values)                    = total
    --
    -- `accepted_total` counts the FACT, not the status: a row is accepted because a provider
    -- acceptance was stamped on it, never because it reached some status.
    'accepted_total',   (select count(*) from rows r where r.notice_accepted_at is not null),
    'unaccepted_total', (select count(*) from rows r where r.notice_accepted_at is null),
    -- ★ THE LEGACY POPULATION, PRECISELY. `dispatched` with no acceptance fact is the shape that
    -- existed before Phase A and is structurally unreachable after it (status and acceptance are
    -- written in one UPDATE). A non-zero count here is therefore a count of PRE-PHASE-A rows, which
    -- is exactly the population Phase D would refuse and Phase C must remediate.
    'legacy_unaccepted', (select count(*) from rows r
                           where r.status = 'dispatched' and r.notice_accepted_at is null),
    -- Rows that belong to no episode. Also strictly pre-Phase-A: the INSERT trigger refuses a NULL
    -- case_id, so this can only shrink.
    'no_episode',       (select count(*) from rows r where r.case_id is null),
    'superseded_total', (select count(*) from rows r where r.superseded_by is not null),
    'current_total',    (select count(*) from rows r where r.superseded_by is null),
    'by_generation',    (select m from by_gen)
  ) into v_out;

  return v_out;
end $$;


ALTER FUNCTION "public"."owner_notice_census"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."owner_notice_census"() IS 'Read-only owner-notice outbox classification (Phase 11-F, Stage 3): totals, status and age distribution, and the actionable/stale/purgeable split against the CURRENT age gate. Phase 11-OC adds the acceptance and episode splits (accepted_total, legacy_unaccepted, no_episode, superseded_total, by_generation), each reconciling against total with no nameless gap. Counts only — never a recipient address. Admin-gated.';



CREATE OR REPLACE FUNCTION "public"."owner_notice_claim_visibility"() RETURNS interval
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO 'public'
    AS $$
  select interval '1 hour';
$$;


ALTER FUNCTION "public"."owner_notice_claim_visibility"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."owner_notice_claim_visibility"() IS 'How long an owner-notice claim is believed before the row may be reclaimed (Phase 11-OBR). One hour: 12x the highest serverless execution ceiling and ~180x the real per-row send cost, and far inside the age gate so every daily drain remains a recovery opportunity. Single-sourced so the claim routine and the census cannot disagree about what is stale.';



CREATE OR REPLACE FUNCTION "public"."owner_notice_episode_kinds"() RETURNS "text"[]
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO 'public'
    AS $$
  select array['death_process.window_opened', 'death_process.window_renotice']::text[];
$$;


ALTER FUNCTION "public"."owner_notice_episode_kinds"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."owner_notice_episode_kinds"() IS 'The owner-safety notice kinds that constitute ONE episode (Phase 11-OC / Phase C): the initial window-opened dispatch and every deliberate operator re-notice. Single-sourced so the readiness census, the operator projection and the re-notice routine cannot disagree about which rows belong to the episode — a literal in any one of them would make the remedy invisible to the instrument that measures whether the remedy worked. INTERNAL: no client role may read the vocabulary.';



CREATE OR REPLACE FUNCTION "public"."owner_notice_reissue_assessment"("p_case" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_c          public.death_verification_cases%rowtype;
  v_state      text;
  v_canonical  uuid;
  v_row        public.owner_notice_outbox%rowtype;
  v_owner      uuid;
  v_resolvable boolean;
  v_reason     text;
  v_refusal    text;
begin
  if p_case is null then
    return jsonb_build_object('eligible', false, 'refusal_code', 'case_not_found');
  end if;

  select * into v_c from public.death_verification_cases c where c.id = p_case;
  if not found then
    return jsonb_build_object('eligible', false, 'refusal_code', 'case_not_found');
  end if;

  -- ★ THE EPISODE KEY IS RESOLVED CANONICALLY AND THE CALLER'S CASE IS COMPARED AGAINST IT — never
  -- trusted as the episode. Identical derivation to `dispatch_owner_safety_notice` and to the
  -- readiness census: the newest VERIFIED case for this estate. A historical case on the same estate
  -- is a real, reachable input (`rejected` and `cancelled` both return the lifecycle to `active`, and
  -- a later process opens a new case), and remediating a current death process using a notice from an
  -- older one is the estate-scope defect this whole phase exists to close.
  select c.id into v_canonical
    from public.death_verification_cases c
   where c.estate_id = v_c.estate_id and c.status = 'verified'
   order by c.decided_at desc
   limit 1;

  select l.state into v_state from public.estate_lifecycle l where l.estate_id = v_c.estate_id;
  v_state := coalesce(v_state, 'active');

  v_owner := public.estate_owner_user_id(v_c.estate_id);
  v_resolvable := exists (
    select 1 from auth.users u
     where u.id = v_owner and btrim(coalesce(u.email, '')) <> ''
  );

  -- The CURRENT generation of this episode: the row nothing supersedes, across BOTH episode kinds.
  select * into v_row
    from public.owner_notice_outbox o
   where o.case_id = p_case
     and o.channel = 'email'
     and o.notice_kind = any (public.owner_notice_episode_kinds())
     and o.superseded_by is null
   limit 1;

  -- ── THE REFUSAL LADDER, IN THE ORDER THE DOOR APPLIES IT ─────────────────────────────────────
  if v_canonical is null then
    v_refusal := 'no_verified_case';
  elsif v_canonical <> p_case then
    -- Covers BOTH "this is a historical case on an estate that has moved on" and "this case was
    -- never verified". The operator's next action is the same in either: work the current case.
    v_refusal := 'case_not_current';
  elsif v_state not in ('owner_notification_dispatched', 'challenge_window') then
    -- ★ THE PERMITTED STATES ARE THE TWO IN WHICH A WARNING STILL MEANS SOMETHING. Before dispatch
    -- there is nothing to re-send (the remedy is dispatch); after a halt or a release the process the
    -- notice describes is over, and mailing a living owner about a concluded process is a false alarm.
    v_refusal := 'invalid_reissue_state';
  elsif v_row.id is null then
    -- Fail closed, and deliberately NOT "dispatch instead". Creating an initial dispatch from this
    -- door would be a second, unaudited entry point into a lifecycle transition.
    v_refusal := 'no_current_notice';
  elsif v_row.status = 'queued' then
    v_refusal := 'notice_still_queued';        -- the ordinary drain still owns it
  elsif v_row.status = 'processing' then
    v_refusal := 'notice_still_processing';    -- OB-1 visibility/reclaim still owns it
  elsif v_row.status = 'dispatched' and v_row.notice_accepted_at is not null then
    v_refusal := 'notice_already_accepted';    -- provider acceptance is established; nothing to remedy
  elsif v_row.status = 'cancelled' then
    -- Defence in depth. Nothing in production writes 'cancelled'; one test fixture does, by direct
    -- UPDATE. Named anyway, because "currently unreachable" is a statement about today's code.
    v_refusal := 'notice_cancelled';
  elsif v_row.status = 'failedPermanent' then
    -- ★ THE VOCABULARY REASON IS DERIVED FROM THE PREDECESSOR, NEVER SUPPLIED. A caller-supplied
    -- value would let an operator relabel an outcomeUncertain reissue as a failed one.
    v_reason := case when v_row.failure_class = 'stale_beyond_age_gate'
                     then 'prior_stale_beyond_age_gate'
                     else 'prior_failed_permanent' end;
  elsif v_row.status = 'outcomeUncertain' then
    v_reason := 'prior_outcome_uncertain';
  elsif v_row.status = 'dispatched' and v_row.notice_accepted_at is null then
    -- ★ THE LEGACY CLASS, AND IT IS LOAD-BEARING. `dispatched` is NOT proof of the Phase A acceptance
    -- fact: every row written before Phase A carries that status with a NULL stamp, because the
    -- stamp did not exist. Refusing this class on the strength of its status would leave exactly the
    -- population Phase D blocks with no route to a remedy — which is the reason Phase C precedes D.
    -- It is structurally unreachable for rows written AFTER Phase A (status and acceptance are set in
    -- one UPDATE), so a row in this shape is an unambiguous pre-Phase-A marker.
    v_reason := 'legacy_no_acceptance_record';
  else
    -- NOT a fall-through: a status outside the six lands here BY NAME, so a widened CHECK constraint
    -- shows up as an explicit refusal instead of joining a neighbouring branch.
    v_refusal := 'notice_not_reissuable';
  end if;

  -- ★ RESOLVABILITY IS CHECKED LAST, AND ONLY WHEN EVERYTHING ELSE PASSED, so an unreachable owner
  -- does not mask a more informative refusal. Fail closed: a row that cannot be sent must not be
  -- manufactured merely to satisfy a remediation workflow — it would settle failedPermanent on the
  -- next drain and leave the episode worse off, with a second dead generation and the evidence of the
  -- first one retired.
  if v_refusal is null and not v_resolvable then
    v_refusal := 'owner_channel_unreachable';
  end if;

  return jsonb_build_object(
    'eligible',                v_refusal is null,
    'refusal_code',            v_refusal,
    'case_is_current',         v_canonical is not null and v_canonical = p_case,
    'lifecycle_state',         v_state,
    'owner_channel_resolvable', v_resolvable,
    'prior_notice_id',         v_row.id,
    'prior_generation',        v_row.generation,
    'prior_status',            v_row.status,
    'prior_notice_kind',       v_row.notice_kind,
    'prior_failure_class',     v_row.failure_class,
    'prior_accepted',          v_row.id is not null and v_row.notice_accepted_at is not null,
    'next_generation',         case when v_refusal is null then v_row.generation + 1 end,
    'reissue_reason',          v_reason
  );
end $$;


ALTER FUNCTION "public"."owner_notice_reissue_assessment"("p_case" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."owner_notice_reissue_assessment"("p_case" "uuid") IS 'The ONE decision about whether an episode may be re-noticed (Phase 11-OC / Phase C), consumed by both reissue_owner_safety_notice and the operator case-file projection so the console can never offer an action the door refuses. Every refusal carries a NAMED code from a closed set. Reports owner_channel_resolvable as a BOOLEAN and never an address. INTERNAL — its callers are gated; a client role cannot reach it.';



CREATE OR REPLACE FUNCTION "public"."owner_notice_reissue_kind"() RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO 'public'
    AS $$
  select 'death_process.window_renotice'::text;
$$;


ALTER FUNCTION "public"."owner_notice_reissue_kind"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."owner_notice_reissue_kind"() IS 'The notice_kind a deliberate operator re-notice takes (Phase 11-OC / Phase C). Distinct from death_process.window_opened so a second warning is never recorded as the initial window-opening event. Both kinds are members of owner_notice_episode_kinds().';



CREATE OR REPLACE FUNCTION "public"."owner_notice_release_authority"("p_case" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_c         public.death_verification_cases%rowtype;
  v_state     text;
  v_canonical uuid;
  v_row       public.owner_notice_outbox%rowtype;
  v_duration  interval;
  v_eligible  timestamptz;
  v_elapsed   boolean := false;
  v_refusal   text;
begin
  if p_case is null then
    return jsonb_build_object('ready', false, 'refusal_code', 'case_not_found',
                              'window_configured', false, 'elapsed', false);
  end if;

  select * into v_c from public.death_verification_cases c where c.id = p_case;
  if not found then
    return jsonb_build_object('ready', false, 'refusal_code', 'case_not_found',
                              'window_configured', false, 'elapsed', false);
  end if;

  -- AUTHORITY 1 · THE EPISODE. Resolved canonically from the ESTATE and compared against the
  -- caller's case — the identical derivation `authorize_release`, `dispatch_owner_safety_notice`,
  -- `owner_notice_reissue_assessment` and the readiness census all use. A caller cannot nominate an
  -- episode, so a historical case cannot be handed in as if it were current.
  select c.id into v_canonical
    from public.death_verification_cases c
   where c.estate_id = v_c.estate_id and c.status = 'verified'
   order by c.decided_at desc
   limit 1;

  select l.state into v_state from public.estate_lifecycle l where l.estate_id = v_c.estate_id;
  v_state := coalesce(v_state, 'active');

  -- AUTHORITY 2 · THE CURRENT GENERATION. Structural — `superseded_by is null` — never a max().
  -- The kind SET comes from `owner_notice_episode_kinds()` rather than a literal, for the reason
  -- Phase C gives: a literal here could not see a re-notice, so a remediated estate would be
  -- refused by the door that its remedy was built to unblock.
  select * into v_row
    from public.owner_notice_outbox o
   where o.case_id = p_case
     and o.channel = 'email'
     and o.notice_kind = any (public.owner_notice_episode_kinds())
     and o.superseded_by is null
   limit 1;

  v_duration := public.challenge_window_duration();

  -- AUTHORITY 4 · THE CLOCK, computed before the ladder so the projection can render the facts even
  -- on a branch that refuses. STRICT `>`; the coalesce is the three-valued-logic discipline — a NULL
  -- comparison must refuse, not pass.
  if v_row.notice_accepted_at is not null and v_duration is not null then
    v_eligible := v_row.notice_accepted_at + v_duration;
    v_elapsed  := coalesce(now() > v_eligible, false);
  end if;

  -- ── THE REFUSAL LADDER, IN THE ORDER THE DOOR APPLIES IT ─────────────────────────────────────
  if v_canonical is null then
    v_refusal := 'no_verified_case';
  elsif v_canonical <> p_case then
    -- A historical case on an estate that has moved on, or a case that was never verified. Either
    -- way the accepted notice it may carry authorizes NOTHING under the current process.
    v_refusal := 'notice_episode_mismatch';
  elsif v_state is distinct from 'challenge_window' then
    -- The release door's own state guard, restated here so the projection refuses for the same
    -- reason the routine will. `challenge_halted` lands here: release can never proceed from a halt.
    v_refusal := 'invalid_release_state';
  elsif v_row.id is null then
    -- No notice names this episode at all. Fail closed: an estate with no provable notice is not an
    -- estate whose owner was warned. Pre-Phase-A rows carry a NULL case_id and land here by design —
    -- they belong to no provable episode and are never guessed into one.
    v_refusal := 'no_current_notice';
  elsif v_row.notice_accepted_at is null then
    -- AUTHORITY 3 · THE LEGACY / UNSETTLED CLASS (D6). Covers every non-accepted shape at once and
    -- WITHOUT consulting a status string: `queued` (never sent), `processing` (never settled),
    -- `outcomeUncertain` (unknown), `failedPermanent` (definitively failed), `cancelled`, a
    -- pre-Phase-A `dispatched` row whose stamp did not exist, and any seventh status a future CHECK
    -- constraint admits. The remedy is a Phase C re-notice that PRODUCES the fact, never a backfill
    -- that invents one and never a manual UPDATE of a safety table.
    v_refusal := 'notice_never_accepted';
  elsif v_duration is null then
    -- NULL duration means NOT CONFIGURED, which means the window never elapses and release refuses.
    v_refusal := 'release_window_not_configured';
  elsif not v_elapsed then
    v_refusal := 'release_window_not_elapsed';
  end if;

  return jsonb_build_object(
    'ready',               v_refusal is null,
    'refusal_code',        v_refusal,
    'case_id',             p_case,
    'case_is_current',     v_canonical is not null and v_canonical = p_case,
    'lifecycle_state',     v_state,
    'notice_id',           v_row.id,
    'generation',          v_row.generation,
    'notice_kind',         v_row.notice_kind,
    -- THE FACT. NULL is a real answer and every consumer must render it as one.
    'notice_accepted_at',  v_row.notice_accepted_at,
    'accepted',            v_row.id is not null and v_row.notice_accepted_at is not null,
    'window_duration',     v_duration::text,
    'window_configured',   v_duration is not null,
    -- Anchored on ACCEPTANCE, never on owner_notified_at. NULL until there is an acceptance fact to
    -- anchor on, which is the honest answer rather than a date computed from provenance.
    'release_eligible_at', v_eligible,
    'elapsed',             v_elapsed);
end $$;


ALTER FUNCTION "public"."owner_notice_release_authority"("p_case" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."owner_notice_release_authority"("p_case" "uuid") IS 'THE owner-notice release authority (Phase 11-OC / Phase D), consumed by both authorize_release and the operator case-file projection so the console can never offer a release the door refuses. A release qualifies ONLY when the CURRENT generation (superseded_by is null) of the CURRENT case episode carries notice_accepted_at, and now() > that instant + challenge_window_duration() STRICTLY. No status string participates in the decision, so a future status cannot become release-qualifying by not being cancelled. notice_accepted_at is PROVIDER ACCEPTANCE and never mailbox delivery; owner_notified_at is provenance and is never the clock. Every refusal carries a NAMED code from a closed set. Discloses no address and no identity. INTERNAL.';



CREATE OR REPLACE FUNCTION "public"."owner_notice_release_readiness_census"() RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_out jsonb;
begin
  perform public.admin_require_gate();

  with door as (
    -- Every estate standing at the release door. `challenge_window` is the ONLY state Phase D's
    -- predicate governs; a released estate is past the door and an earlier one has not reached it.
    --
    -- ★ THE TABLE, NOT `estate_lifecycle_state()`, AND THE CHOICE IS FORCED RATHER THAN CASUAL.
    --
    -- `deathVerificationFoundation.test.ts` keeps two lists with two different privileges, and this
    -- read had to land in one of them. Going through the reader looks stricter and violates the OTHER
    -- rule in the same audit: outside the death module the reader may appear only as an argument to
    -- `release_condition_satisfied`, never in a local comparison — because
    -- `if estate_lifecycle_state(e) = '…'` is release policy leaking back out of the canonical module
    -- one `if` at a time, which that audit calls the single most likely accident here. A
    -- `where estate_lifecycle_state(e.id) = 'challenge_window'` scan is exactly that shape.
    --
    -- So this file joins `LIFECYCLE_TABLE_READERS`, the list `operator_console.sql` already occupies
    -- for the same reason: an operator PROJECTION that reports where the machine stands. Membership
    -- carries a proof obligation the other lists do not — the audit asserts every member is READ-ONLY
    -- against the lifecycle — and this file satisfies it: the census is `stable`, selects only, and
    -- names no transition, no lifecycle UPDATE and no INSERT.
    select l.estate_id
      from public.estate_lifecycle l
     where l.state = 'challenge_window'
  ),
  cur_case as (
    -- The CURRENT episode key, resolved exactly as authorize_release resolves it.
    select d.estate_id,
           (select c.id from public.death_verification_cases c
             where c.estate_id = d.estate_id and c.status = 'verified'
             order by c.decided_at desc limit 1) as case_id
      from door d
  ),
  cur_gen as (
    select cc.estate_id,
           cc.case_id,
           o.status,
           -- ★ ACCEPTANCE IS AN EXISTENTIAL OVER THE WHOLE EPISODE, NEVER A PROPERTY OF THE CURRENT
           -- GENERATION — and this census got that wrong on its first draft, which its own direction-1
           -- positive control caught.
           --
           -- The door asks "did ANY generation of this episode reach provider acceptance?". Reading
           -- only the current generation implements "latest generation only", which the architecture
           -- rejects explicitly: an already-accepted generation 1 would STOP qualifying the moment a
           -- generation 2 was created, so issuing a notice would REMOVE release authority and hand an
           -- operator a lever that suppresses a release. Authority is monotone — creating a generation
           -- can only ever ADD it — which is the same property that makes the MIN anchor immutable.
           --
           -- This must match the Phase D predicate exactly, or the console and the door disagree about
           -- the same estate.
           --
           -- ★ PHASE C — THE EPISODE IS A KIND SET, NOT ONE LITERAL, AND THAT IS WHAT MAKES THE
           -- REMEDY VISIBLE TO THE INSTRUMENT THAT MEASURES IT. A deliberate re-notice takes
           -- `death_process.window_renotice` (migration 0059) so a second warning is never recorded
           -- as the initial window-opening event. Left as the Phase A literal, this predicate could
           -- not see a re-notice at all: a remediated estate would keep reporting as REFUSED however
           -- many times it was re-noticed, its eventual provider acceptance would never be counted,
           -- and Phase C would be inert in exactly the census built to prove Phase C works.
           --
           -- Read from `owner_notice_episode_kinds()` rather than restated, for the reason
           -- `owner_notice_claim_visibility()` gives: two literals are two opinions about the same
           -- bytes, and the door and the census must never hold different ones.
           exists (
             select 1 from public.owner_notice_outbox a
              where a.case_id = cc.case_id
                and a.channel = 'email'
                and a.notice_kind = any (public.owner_notice_episode_kinds())
                and a.notice_accepted_at is not null
           ) as accepted_any,
           -- Does the estate carry any unlinkable pre-Phase-A row? Only consulted when no current
           -- generation was found, to separate "never dispatched" from "cannot be proven".
           (select count(*) from public.owner_notice_outbox z
             where z.estate_id = cc.estate_id and z.case_id is null) as orphan_rows
      from cur_case cc
      -- Phase C: the CURRENT generation may be a re-notice, so the join reads the episode kind SET
      -- for the same reason `accepted_any` above does. Left as one literal, a remediated estate would
      -- report `no_current_notice` — an estate that has just been re-noticed described as one that
      -- was never dispatched, which is the opposite of the truth and would send an operator to
      -- dispatch a window that is already open.
      left join public.owner_notice_outbox o
        on o.case_id = cc.case_id
       and o.channel = 'email'
       and o.notice_kind = any (public.owner_notice_episode_kinds())
       and o.superseded_by is null
  ),
  classified as (
    select case
             when case_id is null                              then 'no_verified_case'
             -- ★ THE ACCEPTANCE TEST COMES FIRST, and it is the ONLY bucket that decides admission.
             -- Everything below it describes what the CURRENT generation is doing, which is
             -- diagnostic information for an operator — useful, and not the release question.
             when accepted_any                                 then 'accepted'
             when status is null and orphan_rows > 0           then 'ambiguous_historical_linkage'
             when status is null                               then 'no_current_notice'
             when status = 'dispatched'                        then 'legacy_dispatched_unaccepted'
             when status = 'outcomeUncertain'                  then 'outcome_uncertain'
             when status = 'failedPermanent'                   then 'failed_permanent'
             when status = 'queued'                            then 'queued'
             when status = 'processing'                        then 'processing'
             when status = 'cancelled'                         then 'cancelled'
             -- ★ NOT A FALL-THROUGH. A status outside the six lands HERE, by name, so a widened
             -- CHECK constraint shows up as an unclassified count instead of silently joining a
             -- neighbouring bucket. The reconciliation assertion in the suite then fails loudly.
             else 'unclassified'
           end as bucket
      from cur_gen
  )
  select jsonb_build_object(
    'estates_at_door', (select count(*) from classified),
    'by_readiness',    coalesce((select jsonb_object_agg(t.bucket, t.n)
                                   from (select bucket, count(*) as n from classified group by bucket) t),
                                '{}'::jsonb),
    -- ★ THE ONE NUMBER THE PHASE D GATE TURNS ON. Estates at the door whose current episode carries
    -- NO provable provider acceptance — i.e. exactly those Phase D would refuse with
    -- `notice_never_accepted`. If this is non-zero, Phase D must not activate for that class until
    -- the Phase C re-notice remedy is deployed and operational.
    'would_be_refused_by_phase_d',
      (select count(*) from classified where bucket <> 'accepted'),
    'would_be_admitted_by_phase_d',
      (select count(*) from classified where bucket = 'accepted'),
    -- Retained so a reader can see that the strict policy is strictly narrower than today's, without
    -- having to reason about it: today's predicate admits every estate with any non-cancelled row.
    'would_be_admitted_by_current_predicate',
      (select count(*) from classified where bucket not in ('no_verified_case', 'no_current_notice',
                                                            'cancelled'))
  ) into v_out;

  return v_out;
end $$;


ALTER FUNCTION "public"."owner_notice_release_readiness_census"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."owner_notice_release_readiness_census"() IS 'Read-only Phase 11-OC blast-radius projection: how many estates standing at the release door would be admitted or refused by the Phase D acceptance predicate, classified by the state of the CURRENT generation of the CURRENT case episode. Scoped by case exactly as the Phase D predicate is, so it cannot credit an accepted notice from a prior rejected process. Every estate lands in one NAMED bucket and the buckets reconcile against the total. Counts ONLY — no estate id, no case id, no user id, no recipient address, on any branch. Admin-gated.';



CREATE OR REPLACE FUNCTION "public"."owner_notice_require_episode"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
begin
  if new.case_id is null then
    raise exception 'owner_notice_case_required' using errcode = 'P0001';
  end if;
  return new;
end $$;


ALTER FUNCTION "public"."owner_notice_require_episode"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."owner_notice_require_episode"() IS 'Phase 11-OC: every NEW owner-notice row must name its death-verification case. Enforced on INSERT only, deliberately — legacy rows carry a NULL case_id and MUST stay updatable, because the stale sweep and the settle path both UPDATE them. A NOT VALID CHECK constraint would have refused those UPDATEs and broken the drain; that was measured, not assumed.';



CREATE OR REPLACE FUNCTION "public"."place_legal_hold"("p_doc_id" "uuid", "p_reason" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_id uuid; v_estate uuid;
begin
  perform public.admin_require_gate();
  select estate_id into v_estate from public.documents where id = p_doc_id;
  if not found then raise exception 'document_not_found' using errcode = 'P0002'; end if;
  if p_reason is null or length(btrim(p_reason)) = 0 then raise exception 'reason_required' using errcode = 'P0001'; end if;

  insert into public.legal_holds (doc_id, reason, placed_by)
  values (p_doc_id, btrim(p_reason), auth.uid()) returning id into v_id;

  perform public.write_audit('document.legal_hold_placed', 'documents', p_doc_id, v_estate,
    jsonb_build_object('severity', 'high', 'hold_id', v_id, 'reason', btrim(p_reason)));
  return v_id;
end;
$$;


ALTER FUNCTION "public"."place_legal_hold"("p_doc_id" "uuid", "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."preview_required_verification_level"("p_estate" "uuid") RETURNS "text"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;
  -- The result is not secret to a PARTY of the estate (they must know what verification to pass); a
  -- non-party cannot probe arbitrary estates. The jurisdiction matrix itself stays unreadable.
  if not (public.is_estate_executor(p_estate, v_uid)
          or public.is_estate_owner(p_estate)
          or public.is_admin()) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return public.required_verification_level(p_estate)::text;
end;
$$;


ALTER FUNCTION "public"."preview_required_verification_level"("p_estate" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."provision_from_invitation"("p_invitation_id" "uuid", "p_user" "uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_inv record;
  v_membership_id uuid;
  v_desig_id uuid;
  v_is_fiduciary boolean;
begin
  select * into v_inv from public.invitations where id = p_invitation_id;
  if not found then raise exception 'invitation_not_found' using errcode = 'P0002'; end if;

  -- ════════════════════════════════════════════════════════════════════════════════════════════════
  -- ★ PHASE 11-MC — A FIDUCIARY DESIGNATION NO LONGER MANUFACTURES A DISCLOSURE CLASS.
  -- ════════════════════════════════════════════════════════════════════════════════════════════════
  --
  -- Until now every acceptance inserted an `estate_memberships` row at the invitation's
  -- `proposed_role`, and `create_invitation` forces that to `'beneficiary'` for executor/trustee. So
  -- granting WORKFLOW capacity silently granted a DISCLOSURE access class as a side effect — the
  -- authority-model defect 11-MA diagnosed.
  --
  -- ★ THE GATE IS `kind`, NOT `proposed_role`, AND THAT CHOICE IS THE WHOLE COMPATIBILITY STORY.
  --
  -- `proposed_role` is PERSISTED AT CREATE TIME (`create_invitation` writes it into the row). Every
  -- executor/trustee invitation already in the table therefore carries a stored
  -- `proposed_role = 'beneficiary'`, and an invitation created before this change but accepted after it
  -- would still manufacture a membership if the provisioner keyed off that stale column. Correcting
  -- `create_invitation` alone fixes NOTHING for outstanding invitations.
  --
  -- `kind` is the authoritative, immutable statement of what the invitation IS. Keying on it fixes new
  -- and outstanding invitations in one place, with no data migration and no need to cancel anything.
  --
  -- ★ AND REMOVING THE FORCED ROLE ALONE WOULD HAVE BEEN WORSE THAN LEAVING IT. Without this gate, an
  -- executor invitation minted with `p_proposed_role = 'professional_delegate'` would provision a
  -- PROFESSIONAL DELEGATE membership instead of a beneficiary one — a different disclosure class,
  -- manufactured just as silently. The defect was never the forced value; it was that a fiduciary
  -- invitation created a membership at all.
  -- ★ `coalesce(..., false)` IS LOAD-BEARING, AND A LAXER TEST SCHEMA IS WHAT PROVED IT.
  --
  -- `NULL in ('executor','trustee')` evaluates to NULL, not false — so `if not v_is_fiduciary` would be
  -- `not NULL`, the membership branch would be SKIPPED, and an ordinary beneficiary acceptance would
  -- silently provision nothing. Production's `invitations.kind` is `text NOT NULL` so it cannot be null
  -- there; the test preamble declares it merely `text`, and an existing lifecycle fixture that omits
  -- `kind` failed immediately on the first run of this correction.
  --
  -- That divergence caught a genuine fragility rather than exposing a harmless one, which is why the
  -- preamble is NOT being tightened to match: a null kind must mean "not a fiduciary invitation" and
  -- therefore "provision exactly as before", because the conservative default for an unrecognised
  -- invitation is the path that existed before this change — never the one that creates no membership.
  v_is_fiduciary := coalesce(v_inv.kind in ('executor', 'trustee'), false);

  if not v_is_fiduciary then
    insert into public.estate_memberships
      (id, estate_id, user_id, role, status, source_invitation_id, approved_at, created_at)
    values
      (gen_random_uuid(), v_inv.estate_id, p_user, v_inv.proposed_role, 'approved', v_inv.id, now(), now())
    on conflict (estate_id, user_id) do nothing
    returning id into v_membership_id;
    if v_membership_id is null then
      select em.id into v_membership_id from public.estate_memberships em
       where em.estate_id = v_inv.estate_id and em.user_id = p_user;
    end if;

    if v_inv.proposed_role::text = 'beneficiary' then
      update public.beneficiaries set user_id = p_user
       where estate_id = v_inv.estate_id and user_id is null
         and ((v_inv.invitee_email is not null and lower(email) = lower(v_inv.invitee_email))
              or (v_inv.invitee_phone is not null and phone = v_inv.invitee_phone));
    end if;
  else
    /**
     * ★ AN INDEPENDENTLY-HELD MEMBERSHIP IS REPORTED, NEVER CREATED, AND NEVER TOUCHED.
     *
     * A person may already be a beneficiary or professional delegate of this estate for reasons that
     * have nothing to do with this invitation. Accepting a fiduciary invitation must leave that
     * relationship exactly as it was — it is a separate authority on a separate axis. So this SELECTs
     * an existing membership to report, and inserts none.
     *
     * ★ NULL IS A LEGITIMATE RETURN VALUE FROM HERE NOW. A fiduciary-only recipient has no membership,
     * so there is no `estate_memberships.id` to hand back. Both callers were adjusted to tell the truth
     * about that rather than assert an approved membership that does not exist, and the two BFF routes
     * that read the result were adjusted to accept it — see `lib/invitations/accept.ts`. Deploying this
     * routine BEFORE those callers would make every executor acceptance look like a 502.
     */
    select em.id into v_membership_id from public.estate_memberships em
     where em.estate_id = v_inv.estate_id and em.user_id = p_user;
  end if;

  if v_inv.kind in ('executor','trustee') then
    v_desig_id := null;
    insert into public.estate_designations
      (estate_id, user_id, designation_type, status, source_invitation_id, granted_by)
    values (v_inv.estate_id, p_user, v_inv.kind, 'active', v_inv.id, v_inv.invited_by)
    on conflict (estate_id, user_id, designation_type) where status = 'active' do nothing
    returning id into v_desig_id;
    if v_desig_id is not null then
      perform public.write_audit('designation.created', 'estate_designations', v_desig_id, v_inv.estate_id,
        jsonb_build_object('invitation_id', v_inv.id, 'designation_type', v_inv.kind));
    end if;
    -- VERIFICATION HOOK (NO-OP): per-claim verification (Reading A) attaches here later; no external call.
  end if;

  return v_membership_id;
end;
$$;


ALTER FUNCTION "public"."provision_from_invitation"("p_invitation_id" "uuid", "p_user" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."purge_outbox_health"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_result jsonb;
begin
  perform public.admin_require_gate();

  select jsonb_build_object(
    'pending_count',              count(*) filter (where status = 'pending'),
    'failed_count',               count(*) filter (where status = 'failed'),
    'purged_last_24h',            count(*) filter (where status = 'purged' and purged_at > now() - interval '24 hours'),
    'oldest_pending_age_seconds', coalesce(extract(epoch from (now() - min(requested_at)
                                    filter (where status <> 'purged')))::bigint, 0),
    'max_attempts_seen',          coalesce(max(attempts) filter (where status <> 'purged'), 0),
    'last_successful_drain_at',   max(purged_at),
    'orphan_candidate_count',     (select count(*) from public.list_orphan_storage_objects(72, 100)),
    -- ADDITIVE (0043): the invitation-delivery heartbeat, same gate, counts and ages only.
    'invitation_delivery',        public.invitation_delivery_health()
  )
  into v_result
  from public.storage_deletion_outbox;

  return v_result;
end;
$$;


ALTER FUNCTION "public"."purge_outbox_health"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."purge_outbox_rows"("p_outbox" "text", "p_before" timestamp with time zone, "p_reason" "text") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid    uuid;
  v_count  int;
  v_oldest timestamptz;
  v_newest timestamptz;
  v_audit  uuid;
begin
  perform public.admin_require_gate();
  v_uid := auth.uid();

  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'purge_reason_required' using errcode = 'P0001';
  end if;
  if p_before is null then
    raise exception 'purge_cutoff_required' using errcode = 'P0001';
  end if;
  -- A closed vocabulary of purgeable outboxes. An unknown name is refused rather than resolved
  -- dynamically: `execute format('delete from %I')` on a caller-supplied table is how an admin
  -- routine becomes a general-purpose delete.
  if p_outbox is distinct from 'owner_notice_outbox' then
    raise exception 'unknown_outbox' using errcode = 'P0001';
  end if;

  select count(*), min(requested_at), max(requested_at)
    into v_count, v_oldest, v_newest
    from public.owner_notice_outbox
   where status in ('dispatched', 'failedPermanent', 'cancelled')
     and requested_at < p_before;

  if v_count = 0 then
    return 0; -- nothing to purge writes no audit row: an audit of a no-op is noise, not evidence
  end if;

  insert into public.outbox_purge_audit
    (outbox_name, actor_id, row_count, oldest_row_at, newest_row_at, reason)
  values (p_outbox, v_uid, v_count, v_oldest, v_newest, p_reason)
  returning id into v_audit;

  -- Stamp the audit id onto the rows first, so even a partial failure leaves the link.
  update public.owner_notice_outbox
     set purge_audit_id = v_audit
   where status in ('dispatched', 'failedPermanent', 'cancelled')
     and requested_at < p_before;

  delete from public.owner_notice_outbox
   where status in ('dispatched', 'failedPermanent', 'cancelled')
     and requested_at < p_before;

  insert into public.audit_logs (actor_id, estate_id, action, target_table, target_id, metadata, source)
  values (v_uid, null, 'outbox.purged', 'outbox_purge_audit', v_audit,
          jsonb_build_object('severity', 'high', 'outbox', p_outbox, 'row_count', v_count,
                            'oldest_row_at', v_oldest, 'newest_row_at', v_newest,
                            'reason', p_reason),
          'admin');
  return v_count;
end $$;


ALTER FUNCTION "public"."purge_outbox_rows"("p_outbox" "text", "p_before" timestamp with time zone, "p_reason" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."purge_outbox_rows"("p_outbox" "text", "p_before" timestamp with time zone, "p_reason" "text") IS 'Purges SETTLED owner-notice rows older than an explicit cutoff (Phase 11-F, Stage 3). Writes the outbox_purge_audit row BEFORE deleting, in the same transaction, so a silent purge is impossible. Requires a non-blank reason, refuses an unknown outbox name, and never touches queued or processing rows — those are live safety messages still in flight.';



CREATE OR REPLACE FUNCTION "public"."record_consent"("p_type" "text", "p_version" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
$$;


ALTER FUNCTION "public"."record_consent"("p_type" "text", "p_version" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."record_invitation_delivery_failure"("p_outbox_id" "uuid", "p_error" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_out record;
begin
  select * into v_out from public.invitation_delivery_outbox where id = p_outbox_id for update;
  if not found then return; end if;
  update public.invitation_delivery_outbox
     set status = 'failed', attempts = attempts + 1, last_error = left(coalesce(p_error, 'unknown'), 500)
   where id = p_outbox_id;
  perform public.write_audit('invitation.delivery_failed', 'invitations', v_out.invitation_id, v_out.estate_id,
    jsonb_build_object('invitation_id', v_out.invitation_id, 'outbox_id', p_outbox_id));
end;
$$;


ALTER FUNCTION "public"."record_invitation_delivery_failure"("p_outbox_id" "uuid", "p_error" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."record_invitation_delivery_outcome"("p_outbox_id" "uuid", "p_delivery_generation" integer, "p_outcome" "text", "p_provider_message_id" "text" DEFAULT NULL::"text", "p_failure_class" "text" DEFAULT NULL::"text") RETURNS TABLE("outbox_id" "uuid", "status" "text", "attempts" integer)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_out record; v_status text; v_next timestamptz; v_class text;
  c_max_attempts constant int := 5;
begin
  if p_outcome not in ('providerAccepted', 'outcomeUncertain', 'retryPending', 'failedPermanent', 'cancelled') then
    raise exception 'invalid_outcome' using errcode = 'P0001';
  end if;

  select * into v_out from public.invitation_delivery_outbox where id = p_outbox_id for update;
  if not found then raise exception 'outbox_entry_not_found' using errcode = 'P0002'; end if;

  -- Stale worker: its generation has been superseded by a reissue. Report current state, change nothing.
  if v_out.delivery_generation <> p_delivery_generation then
    return query select v_out.id, v_out.status, v_out.attempts;
    return;
  end if;

  -- Already settled to an accepted state: a duplicate result is a no-op, never a second send.
  if v_out.status in ('providerAccepted', 'cancelled') then
    return query select v_out.id, v_out.status, v_out.attempts;
    return;
  end if;

  v_class := case when p_outcome in ('retryPending', 'failedPermanent') then p_failure_class else null end;
  v_status := p_outcome;
  v_next := null;

  -- ★ THE RETRY CAP. An exhausted row becomes failedPermanent rather than cycling forever.
  if p_outcome = 'retryPending' then
    if v_out.attempts >= c_max_attempts then
      v_status := 'failedPermanent';
    else
      v_next := now() + make_interval(hours => least(v_out.attempts, 12));
    end if;
  end if;

  update public.invitation_delivery_outbox
     set status = v_status,
         -- A provider handle is only meaningful when the provider actually accepted.
         provider_message_id = case when p_outcome = 'providerAccepted'
                                    then nullif(btrim(coalesce(p_provider_message_id, '')), '')
                                    else provider_message_id end,
         failure_class = v_class,
         -- Deliberately NOT the provider's raw text: it can echo the recipient address.
         last_error = v_class,
         next_attempt_at = v_next,
         last_outcome_at = now(),
         issued_at = case when p_outcome = 'providerAccepted' then now() else issued_at end
   where id = p_outbox_id;

  perform public.write_audit('invitation.delivery_outcome', 'invitations', v_out.invitation_id, v_out.estate_id,
    jsonb_build_object('outbox_id', p_outbox_id, 'delivery_generation', p_delivery_generation,
                       'outcome', v_status, 'failure_class', v_class, 'attempts', v_out.attempts));

  return query select v_out.id, v_status, v_out.attempts;
end;
$$;


ALTER FUNCTION "public"."record_invitation_delivery_outcome"("p_outbox_id" "uuid", "p_delivery_generation" integer, "p_outcome" "text", "p_provider_message_id" "text", "p_failure_class" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."record_orphan_sweep"("p_mode" "text", "p_paths" "text"[], "p_grace_hours" integer, "p_batch_cap" integer) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_uid uuid := auth.uid();
begin
  perform public.admin_require_gate();
  if p_mode not in ('dry_run', 'delete') then
    raise exception 'invalid_mode' using errcode = 'P0001';
  end if;
  insert into public.audit_logs(actor_id, estate_id, action, target_table, target_id, metadata, source)
  values (
    v_uid, null, 'storage.orphans_swept', 'storage.objects', null,
    jsonb_build_object(
      'severity', 'high',
      'mode', p_mode,
      'count', coalesce(array_length(p_paths, 1), 0),
      'grace_hours', p_grace_hours,
      'batch_cap', p_batch_cap,
      'paths', to_jsonb(coalesce(p_paths, array[]::text[]))
    ),
    'admin'
  );
end;
$$;


ALTER FUNCTION "public"."record_orphan_sweep"("p_mode" "text", "p_paths" "text"[], "p_grace_hours" integer, "p_batch_cap" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."record_owner_notice_outcome"("p_id" "uuid", "p_outcome" "text", "p_failure_class" "text" DEFAULT NULL::"text") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_row    public.owner_notice_outbox%rowtype;
  v_status text;
  v_next   timestamptz;
  v_class  text;
  c_max_attempts constant int := 3;
begin
  if p_outcome not in ('providerAccepted', 'outcomeUncertain', 'retryPending', 'failedPermanent') then
    raise exception 'invalid_outcome' using errcode = 'P0001';
  end if;

  select * into v_row from public.owner_notice_outbox where id = p_id for update;
  if not found then
    raise exception 'outbox_entry_not_found' using errcode = 'P0002';
  end if;

  -- Already settled: report current state, change nothing, write no second audit row. Covers a
  -- duplicate callback and an operator-cancelled row alike.
  if v_row.status in ('dispatched', 'outcomeUncertain', 'failedPermanent', 'cancelled') then
    return v_row.status;
  end if;

  v_class := case when p_outcome in ('retryPending', 'failedPermanent') then p_failure_class else null end;
  v_next  := null;

  if p_outcome = 'providerAccepted' then
    v_status := 'dispatched';
  elsif p_outcome = 'outcomeUncertain' then
    v_status := 'outcomeUncertain';
  elsif p_outcome = 'failedPermanent' then
    v_status := 'failedPermanent';
  else
    if v_row.attempts >= c_max_attempts then
      v_status := 'failedPermanent';
      v_class  := coalesce(v_class, 'retry_cap_exhausted');
    else
      v_status := 'queued';
      v_next   := now() + make_interval(hours => least(greatest(v_row.attempts, 1), 3));
    end if;
  end if;

  -- ★ PHASE 11-OC — ACCEPTANCE IS STAMPED IN THIS ONE STATEMENT, BESIDE THE STATUS IT AGREES WITH.
  --
  -- `notice_accepted_at` is the fact Phase D makes release-authoritative, and it is written here and
  -- nowhere else. One UPDATE, so `dispatched` + NULL acceptance is structurally unreachable for any
  -- row written after Phase A — which is what lets the re-notice routine treat that combination as
  -- an unambiguous LEGACY marker rather than as a state it might have produced itself.
  --
  -- ★ IT IS KEYED ON `p_outcome`, NOT ON `v_status`. They agree today: `providerAccepted` is the only
  -- branch that yields `dispatched`. Keying on the OUTCOME ties the stamp to what the provider
  -- actually reported, so if a future branch ever reaches `dispatched` by another route it does not
  -- silently inherit an acceptance fact nobody established. `outcomeUncertain`, `retryPending` and
  -- `failedPermanent` all leave it NULL — an unknown outcome must never be recorded as an acceptance,
  -- which is the whole reason this column exists rather than a status list.
  --
  -- First-write-wins needs no `where notice_accepted_at is null` guard: the settled-status no-op
  -- above already makes a second settle unreachable, and a redundant guard here would mask a future
  -- change to that no-op instead of failing beside it.
  update public.owner_notice_outbox
     set status             = v_status,
         failure_class      = v_class,
         next_attempt_at    = v_next,
         dispatched_at      = case when v_status = 'dispatched' then now() else dispatched_at end,
         notice_accepted_at = case when p_outcome = 'providerAccepted' then now()
                                   else notice_accepted_at end
   where id = p_id;

  -- ★ THE AUDIT NAMES THE OUTCOME AND THE CHANNEL CLASS, NEVER THE ADDRESS — the same discipline as
  -- the dispatch audit it follows. An audit row outlives every reason anyone had to read it.
  -- actor_id is NULL because the actor is a scheduled worker, not a person; `source = 'worker'`
  -- says so without inventing a synthetic operator identity.
  insert into public.audit_logs (actor_id, estate_id, action, target_table, target_id, metadata, source)
  values (null, v_row.estate_id, 'death_process.owner_notice_outcome', 'owner_notice_outbox', p_id,
          jsonb_build_object('severity', 'high', 'outcome', v_status,
                            'failure_class', v_class, 'attempts', v_row.attempts,
                            'channel', v_row.channel, 'notice_kind', v_row.notice_kind),
          'worker');
  return v_status;
end $$;


ALTER FUNCTION "public"."record_owner_notice_outcome"("p_id" "uuid", "p_outcome" "text", "p_failure_class" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."record_owner_notice_outcome"("p_id" "uuid", "p_outcome" "text", "p_failure_class" "text") IS 'Write-back half of the owner-safety notice drain (Phase 11-K). providerAccepted -> dispatched; retryPending -> queued with backoff until a 3-attempt cap, then failedPermanent; outcomeUncertain and failedPermanent are terminal. An already-settled row is a no-op, so a duplicate callback can never produce a second send. Records no recipient address. service_role only.';



CREATE OR REPLACE FUNCTION "public"."record_purge_result"("p_outbox_id" "uuid", "p_ok" boolean, "p_error" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_estate uuid;
begin
  if auth.uid() is null then raise exception 'auth_required' using errcode = '42501'; end if;
  select estate_id into v_estate from public.storage_deletion_outbox where id = p_outbox_id;
  if not found then raise exception 'outbox_not_found' using errcode = 'P0002'; end if;
  if not public.is_estate_owner(v_estate) then raise exception 'not_estate_owner' using errcode = '42501'; end if;

  if p_ok then
    update public.storage_deletion_outbox
       set status = 'purged', purged_at = now(), last_error = null where id = p_outbox_id;
  else
    update public.storage_deletion_outbox
       set status = 'failed', last_error = left(coalesce(p_error, 'unknown'), 500) where id = p_outbox_id;
  end if;
end;
$$;


ALTER FUNCTION "public"."record_purge_result"("p_outbox_id" "uuid", "p_ok" boolean, "p_error" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reissue_owner_safety_notice"("p_case" "uuid", "p_reason" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid        uuid;
  v_c          public.death_verification_cases%rowtype;
  v_prior      public.owner_notice_outbox%rowtype;
  v_verdict    jsonb;
  v_owner      uuid;
  v_recipient  text;
  v_new        uuid;
  v_gen        int;
  v_reason     text;
begin
  perform public.admin_require_gate();
  v_uid := auth.uid();

  -- ★ THE REASON IS REQUIRED AND CANNOT BE BLANK, and it is checked BEFORE anything is locked. "Fixing
  -- it" is not a reason; the audit row exists so somebody reconstructing a disputed release a year
  -- later can tell a legitimate remediation from an operator mailing a living person repeatedly.
  --
  -- ★ "CONTAINS NO NON-WHITESPACE CHARACTER" RATHER THAN `btrim(p_reason) = ''`, AND THE DIFFERENCE
  -- IS NOT PEDANTRY — it was found by execution. Single-argument `btrim` strips SPACES only, so a
  -- reason of one tab, or of a newline, passes that test and lands in the audit as a blank field.
  -- §11.9 sends `E'\t\n'` and the `btrim` form ACCEPTED it. The sibling routines in this schema
  -- (`purge_outbox_rows`, `authorize_release`) carry the narrower spelling; that is recorded as an
  -- observation in `docs/phase11oc-phase-c-owner-notice-reissue.md` rather than changed here, because
  -- widening a deployed reason check is its own decision and `authorize_release` is Phase D's file.
  if p_reason is null or p_reason !~ '[^[:space:]]' then
    raise exception 'reissue_reason_required' using errcode = 'P0001';
  end if;
  if p_case is null then
    raise exception 'case_not_found' using errcode = 'P0002';
  end if;

  -- LOCK 1 · the episode identity.
  select * into v_c from public.death_verification_cases c where c.id = p_case for update;
  if not found then
    raise exception 'case_not_found' using errcode = 'P0002';
  end if;

  -- LOCK 2 · the current generation, so `generation + 1` is computed under the row it increments.
  -- A missing row is legitimate here (the assessment names it `no_current_notice`), so this is not
  -- an assertion — it is a lock taken when there is something to lock.
  select * into v_prior
    from public.owner_notice_outbox o
   where o.case_id = p_case
     and o.channel = 'email'
     and o.notice_kind = any (public.owner_notice_episode_kinds())
     and o.superseded_by is null
   limit 1
   for update;

  -- ★ THE VERDICT COMES FROM THE SHARED ASSESSMENT, READ UNDER THE LOCKS ABOVE. The door does not
  -- restate the policy the console renders, so the two cannot disagree.
  v_verdict := public.owner_notice_reissue_assessment(p_case);
  if not (v_verdict ->> 'eligible')::boolean then
    raise exception '%', v_verdict ->> 'refusal_code' using errcode = 'P0001';
  end if;
  v_reason := v_verdict ->> 'reissue_reason';
  if v_reason is null then
    -- Unreachable: every eligible branch derives one, and the table CHECK pairs generation > 1 with a
    -- non-null reason. Asserted rather than trusted, because the alternative is an insert that fails
    -- on a constraint with no explanation of which branch forgot.
    raise exception 'reissue_reason_underived' using errcode = 'P0001';
  end if;

  -- ★ THE RECIPIENT IS DERIVED, THROUGH THE SAME AUTHORITATIVE PATH AS THE INITIAL DISPATCH:
  -- `estate_owner_user_id` → `auth.users.email`. Not `profiles.email` (user-editable in principle,
  -- and repointable by anyone who can write a profile) and not the predecessor row's stored value.
  --
  -- ★ THE RESIDUAL RISK IS REAL AND IS RECORDED RATHER THAN HIDDEN. Re-resolving means a re-notice
  -- goes to whatever address the account carries NOW. `lib/ownerNotices/drain.ts` deliberately does
  -- NOT re-resolve at SEND time, and that is the right rule there: a worker silently changing
  -- destination between enqueue and send is unaudited and unattended. This is different — an operator
  -- decides, a reason is required, and an audit row is written. Re-sending to the predecessor's stored
  -- address would also be inert for the commonest remediable failure there is, a hard bounce on a dead
  -- address. So the audit records WHETHER the resolved address differs from the predecessor's, as a
  -- BOOLEAN, never the address: an investigator gets the signal, and the audit gains no contact detail
  -- it would then carry forever.
  v_owner := public.estate_owner_user_id(v_c.estate_id);
  if v_owner is null then
    raise exception 'owner_unresolved' using errcode = 'P0001';
  end if;
  select u.email into v_recipient from auth.users u where u.id = v_owner;
  if v_recipient is null or btrim(v_recipient) = '' then
    -- Belt and braces with the assessment's `owner_channel_unreachable`: the assessment answers for
    -- the console, this answers for the write, and neither is allowed to depend on the other having
    -- run. A row with no destination would be claimed, fail, and settle failedPermanent — leaving the
    -- episode with a second dead generation and the first one retired.
    raise exception 'owner_channel_unreachable' using errcode = 'P0001';
  end if;

  v_gen := v_prior.generation + 1;
  v_new := gen_random_uuid();

  -- RETIRE the predecessor. This is the ONLY column of it this routine touches: every forensic field
  -- — requested_at, attempts, failure_class, dispatched_at, notice_accepted_at, case_id, generation,
  -- status, claimed_at — is left exactly as the drain left it.
  update public.owner_notice_outbox
     set superseded_by = v_new
   where id = v_prior.id;

  -- CREATE the successor. Every field that could carry a stale fact forward is written explicitly,
  -- rather than left to a default, so a reader can see that none of them is inherited:
  --   status             'queued'  — a new warning has been queued, nothing more
  --   notice_accepted_at NULL      — only the providerAccepted settle path may ever stamp it
  --   requested_at       now()     — the age gate must run from THIS request, not the predecessor's
  --   attempts           0         — the successor has its own retry budget
  --   claimed_at         NULL      — unclaimed
  --   dispatched_at      NULL      — nothing has been dispatched
  --   failure_class      NULL      — the predecessor's failure is on the predecessor
  --   next_attempt_at    NULL      — claimable by the next drain
  insert into public.owner_notice_outbox
    (id, estate_id, user_id, channel, recipient, notice_kind, status, requested_at, attempts,
     claimed_at, dispatched_at, failure_class, next_attempt_at, notice_accepted_at,
     case_id, generation, superseded_by, reissue_reason, reissued_by)
  values
    (v_new, v_c.estate_id, v_owner, 'email', v_recipient, public.owner_notice_reissue_kind(),
     'queued', now(), 0, null, null, null, null, null,
     p_case, v_gen, null, v_reason, v_uid);

  -- ★ THE AUDIT IS A DISTINCT ACTION, NEVER `owner_notice_dispatched`. That action means "an operator
  -- opened the window and started the challenge clock"; this one means "an operator queued an
  -- additional warning inside a window that was already open". Reusing the first would make the audit
  -- trail assert a lifecycle transition that did not happen, and would hide the reissue from anyone
  -- counting dispatches.
  --
  -- It names both generations and both row ids, so the supersession chain is reconstructible from the
  -- audit alone. It records the operator's reason and the derived vocabulary reason as separate
  -- fields. It records NO recipient address — the same discipline as the dispatch audit it follows.
  insert into public.audit_logs (actor_id, estate_id, action, target_table, target_id, metadata, source)
  values (v_uid, v_c.estate_id, 'death_process.owner_notice_reissued', 'owner_notice_outbox', v_new,
          jsonb_build_object(
            'severity',           'high',
            'case_id',            p_case,
            'prior_notice_id',    v_prior.id,
            'prior_generation',   v_prior.generation,
            'prior_status',       v_prior.status,
            'prior_failure_class', v_prior.failure_class,
            'prior_notice_kind',  v_prior.notice_kind,
            'new_notice_id',      v_new,
            'new_generation',     v_gen,
            'notice_kind',        public.owner_notice_reissue_kind(),
            'channel',            'email',
            'reissue_reason',     v_reason,
            'reason',             p_reason,
            -- A boolean, never the address. See the recipient note above.
            'recipient_changed',  v_recipient is distinct from v_prior.recipient),
          'admin');

  -- The return value is what an operator may know, and no more. No recipient, on any branch.
  return jsonb_build_object(
    'status',            'queued',
    'case_id',           p_case,
    'notice_id',         v_new,
    'generation',        v_gen,
    'notice_kind',       public.owner_notice_reissue_kind(),
    'notice_accepted_at', null,
    'reissue_reason',    v_reason,
    'prior_notice_id',   v_prior.id,
    'prior_generation',  v_prior.generation,
    'prior_status',      v_prior.status);
end $$;


ALTER FUNCTION "public"."reissue_owner_safety_notice"("p_case" "uuid", "p_reason" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."reissue_owner_safety_notice"("p_case" "uuid", "p_reason" "text") IS 'Queues a NEW owner-safety notice generation for the CURRENT case episode (Phase 11-OC / Phase C). Eligible only when the current generation is failedPermanent, outcomeUncertain, or dispatched with NO acceptance fact (the pre-Phase-A legacy class) — and only from owner_notification_dispatched or challenge_window. Appends a row and retires the previous one with a pointer; mutates no forensic field of the predecessor. The new row starts queued with NULL acceptance, so a successful call means NEW WARNING QUEUED and never provider acceptance or delivery. Recipient is DERIVED, never supplied, and never returned. Requires a non-blank reason and writes death_process.owner_notice_reissued. Admin-gated inside the definer.';



CREATE OR REPLACE FUNCTION "public"."release_condition_satisfied"("p_release_condition" "text", "p_approved_at" timestamp with time zone, "p_policy" "text", "p_lifecycle_state" "text") RETURNS boolean
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO 'public'
    AS $$
  select coalesce(
    -- ★ THE LIFECYCLE VALIDITY GATE COMES FIRST and refuses EVERYTHING on an out-of-vocabulary
    -- state. The set is the deployed CHECK's (0052 widened by 0054), spelled here because a pure
    -- function cannot read the catalog; `db/tests/release_condition_authorization.sql` enumerates
    -- the CHECK at run time and fails if the two vocabularies ever drift.
    -- ★ THE GATE MUST NAME EVERY STORABLE STATE, INCLUDING ONES THAT SATISFY NOTHING. A state
    -- missing here refuses EVERY condition for that estate — including `immediately` — so an
    -- owner's ordinary live grants would go dark the moment a death process reached the unlisted
    -- state. Failing closed on an UNKNOWN state is the design; failing closed on a KNOWN one is a
    -- disclosure outage. 11-F's `owner_notification_dispatched` joins the list for that reason and
    -- for no other: it satisfies nothing, exactly like the two states either side of it.
    p_lifecycle_state in ('active', 'death_verification_pending', 'death_verified',
                          'owner_notification_dispatched',
                          'challenge_window', 'challenge_halted', 'released')
    and case p_policy
      -- Documents, the estate-documents category, estate inventory, and notification speech.
      -- `after_owner_approval` (owner-initiated) and `after_access_request_approval`
      -- (beneficiary-initiated) are the SAME gate — both mean "the owner approved this access",
      -- differing only by who asked.
      when 'standard' then
        p_release_condition = 'immediately'
        or (p_release_condition in ('after_owner_approval', 'after_access_request_approval')
            and p_approved_at is not null)
        -- ★ THE DEATH ARM — RE-POINTED IN PHASE 11-E (R7). 11-D satisfied this at death_verified;
        -- that connected an accepted verification DIRECTLY to irreversible disclosure, and 11-E
        -- inserts the safety seam: the condition is satisfied ONLY at `released`, which is
        -- reachable only through the challenge window — owner notified in the same transaction,
        -- configured duration strictly elapsed, no owner challenge. death_verified satisfies
        -- NOTHING; challenge_window satisfies NOTHING; challenge_halted satisfies NOTHING.
        -- Claim approval, evidence, and attained levels never appear here because they cannot
        -- move the lifecycle. Incapacity and the legacy fused value stay out of this arm
        -- entirely — dormant under every policy, every lifecycle (R8/R9).
        or (p_release_condition = 'after_verified_death'
            and p_lifecycle_state = 'released')

      -- The asset-value surfaces (account balances, institution names, total asset value, linked
      -- account details). Carried forward EXACTLY as written in 11-B, including their narrowness
      -- and their lifecycle-indifference: `immediately` alone, at every lifecycle state. This is a
      -- compatibility clamp with a standing ledger entry (R12), not a rule anyone designed — and
      -- 11-D deliberately does NOT spend that product decision.
      when 'legacy_immediate_only' then
        p_release_condition = 'immediately'

      -- Unknown policy -> refused. No `else true`, ever.
      else false
    end,
    false);
$$;


ALTER FUNCTION "public"."release_condition_satisfied"("p_release_condition" "text", "p_approved_at" timestamp with time zone, "p_policy" "text", "p_lifecycle_state" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."release_condition_satisfied"("p_release_condition" "text", "p_approved_at" timestamp with time zone, "p_policy" "text", "p_lifecycle_state" "text") IS 'THE canonical release-condition authority (Phase 11-B; lifecycle-aware since 11-D; safety-seamed in 11-E). Answers only "is this condition presently satisfied", never who may receive a grant, what tier they get, or whether anyone has died. PURE: the lifecycle arrives as an argument, resolved by SECURITY DEFINER consumers through public.estate_lifecycle_state — never from claim status, evidence, or attained levels. after_verified_death is satisfied only under the standard policy at RELEASED (R7) — death_verified, challenge_window and challenge_halted all satisfy nothing; incapacity, the legacy fused value, identity and claim conditions are dormant under every policy. Unknown condition, unknown policy, unknown lifecycle and NULL all refuse.';



CREATE OR REPLACE FUNCTION "public"."release_condition_writable"("p_release_condition" "text") RETURNS boolean
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO 'public'
    AS $$
  select coalesce(p_release_condition in (
    'never',
    'immediately',
    'after_owner_approval',
    'after_identity_verification',
    'after_access_request_approval',
    -- Phase 11-B: the split. Storable and expressible; death satisfiable only since 11-D and only
    -- at death_verified under the standard policy; incapacity satisfied by nothing.
    'after_verified_death',
    'after_verified_incapacity',
    'after_claim_case_approval'
    -- 'after_verified_death_or_incapacity' is DELIBERATELY ABSENT — readable, never writable again.
  ), false);
$$;


ALTER FUNCTION "public"."release_condition_writable"("p_release_condition" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."release_condition_writable"("p_release_condition" "text") IS 'Write-time vocabulary gate for access_grants.release_condition (Phase 11-B). Accepts the split after_verified_death / after_verified_incapacity and REFUSES the deprecated fused after_verified_death_or_incapacity, which remains legal in the CHECK so stored rows stay readable and unreinterpreted. Writable is not live: incapacity is satisfied by no policy, and death only by the authoritative death_verified lifecycle under the standard policy (11-D).';



CREATE OR REPLACE FUNCTION "public"."release_legal_hold"("p_hold_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_doc uuid; v_estate uuid;
begin
  perform public.admin_require_gate();
  select doc_id into v_doc from public.legal_holds where id = p_hold_id and released_at is null;
  if not found then raise exception 'hold_not_found_or_released' using errcode = 'P0002'; end if;

  update public.legal_holds set released_at = now(), released_by = auth.uid() where id = p_hold_id;

  select estate_id into v_estate from public.documents where id = v_doc;
  perform public.write_audit('document.legal_hold_released', 'documents', v_doc, v_estate,
    jsonb_build_object('severity', 'high', 'hold_id', p_hold_id));
end;
$$;


ALTER FUNCTION "public"."release_legal_hold"("p_hold_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."replace_vault_document"("p_doc_id" "uuid", "p_new_storage_path" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
declare
  v_uid       uuid := auth.uid();
  v_estate    uuid;
  v_old_path  text;
  v_size      bigint;
  v_mime      text;
  v_max_bytes bigint;
  v_mimes     text[];
  v_outbox    uuid;
begin
  if v_uid is null then raise exception 'auth_required' using errcode = '42501'; end if;

  select estate_id, storage_path into v_estate, v_old_path from public.documents where id = p_doc_id;
  if not found then raise exception 'document_not_found' using errcode = 'P0002'; end if;
  if not public.is_estate_owner(v_estate) then raise exception 'not_estate_owner' using errcode = '42501'; end if;

  -- Same blocking gauntlet (replace destroys the old bytes → an active claim / hold / retention must freeze them).
  if exists (select 1 from public.claim_packets c
             where (c.death_certificate_doc_id = p_doc_id or c.executor_id_doc_id = p_doc_id)
               and c.status <> 'rejected') then
    raise exception 'blocked_active_claim' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.legal_holds h where h.doc_id = p_doc_id and h.released_at is null) then
    raise exception 'blocked_legal_hold' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.documents d
             where d.id = p_doc_id and d.retention_until is not null and d.retention_until > now()) then
    raise exception 'blocked_retention' using errcode = 'P0001';
  end if;

  -- New path: estates/<estate>/vault/<doc_id>[-<token>].<ext>. Token allows a DISTINCT object so old+new coexist
  -- until the old is purged (kills traversal + ties the object to the doc). Must DIFFER from the current object.
  if p_new_storage_path !~ ('^estates/' || v_estate::text || '/vault/' || p_doc_id::text || '(-[a-zA-Z0-9]+)?\.[a-zA-Z0-9]+$') then
    raise exception 'vault_path_mismatch' using errcode = 'P0001';
  end if;
  if p_new_storage_path = v_old_path then
    raise exception 'replace_same_object' using errcode = 'P0001';
  end if;

  -- New object MUST already exist; size/mime authoritative from storage; policy quota (same source as create).
  select (o.metadata->>'size')::bigint, o.metadata->>'mimetype' into v_size, v_mime
    from storage.objects o where o.bucket_id = 'documents' and o.name = p_new_storage_path;
  if not found then raise exception 'vault_object_missing' using errcode = 'P0002'; end if;

  select max_upload_bytes, allowed_mime_types into v_max_bytes, v_mimes from public.upload_policy where id = 1;
  if coalesce(v_size, 0) > v_max_bytes then raise exception 'vault_too_large' using errcode = 'P0001'; end if;
  if v_mime is null or not (v_mime = any(v_mimes)) then raise exception 'vault_mime_rejected' using errcode = 'P0001'; end if;

  -- Atomically SWITCH to the new object (bytes-only).
  update public.documents
     set storage_path = p_new_storage_path, mime_type = v_mime, size_bytes = v_size
   where id = p_doc_id;

  -- Enqueue deletion of the FORMER object (same tx).
  insert into public.storage_deletion_outbox (estate_id, bucket, object_path, reason, requested_by)
  values (v_estate, 'documents', v_old_path, 'document_replaced', v_uid)
  returning id into v_outbox;

  perform public.write_audit('document.replaced', 'documents', p_doc_id, v_estate,
    jsonb_build_object('severity', 'high', 'old_path', v_old_path, 'new_path', p_new_storage_path,
                       'outbox_id', v_outbox, 'via', 'replace_vault_document'));

  return v_outbox;
end;
$_$;


ALTER FUNCTION "public"."replace_vault_document"("p_doc_id" "uuid", "p_new_storage_path" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."request_invitation_redelivery"("p_estate" "uuid", "p_invitation" "uuid") RETURNS TABLE("invitation_id" "uuid", "delivery_state" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_inv record; v_recent int;
begin
  perform public.estate_owner_gate(p_estate);

  select * into v_inv from public.invitations
   where id = p_invitation and estate_id = p_estate for update;
  if not found then raise exception 'invitation_not_found' using errcode = 'P0002'; end if;

  if public.invitation_effective_status(v_inv.status, v_inv.expires_at) not in ('pending', 'matched') then
    raise exception 'invitation_not_actionable' using errcode = 'P0005';
  end if;

  -- DB-resident throttle, matching 0016's approach: PostgREST bypasses the Vercel rate limiter, so
  -- the abuse control has to live here.
  select count(*) into v_recent from public.invitation_delivery_outbox o
   where o.invitation_id = v_inv.id and o.requested_at > now() - interval '1 hour';
  if v_recent >= 3 then
    raise exception 'redelivery_rate_limited' using errcode = 'P0004';
  end if;

  insert into public.invitation_delivery_outbox (invitation_id, estate_id, reason, requested_by)
  values (v_inv.id, p_estate, 'invitation_redelivery', auth.uid());

  perform public.write_audit('invitation.delivery_requested', 'invitations', v_inv.id, p_estate,
    jsonb_build_object('invitation_id', v_inv.id, 'reason', 'invitation_redelivery'));

  return query select v_inv.id, 'queued'::text;
end;
$$;


ALTER FUNCTION "public"."request_invitation_redelivery"("p_estate" "uuid", "p_invitation" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."require_aal2"() RETURNS "void"
    LANGUAGE "plpgsql" STABLE
    SET "search_path" TO 'public', 'auth', 'extensions'
    AS $$
begin
  if coalesce(auth.jwt() ->> 'aal', 'aal1') <> 'aal2' then
    raise exception 'mfa_required' using errcode = '42501';
  end if;
end;
$$;


ALTER FUNCTION "public"."require_aal2"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."require_breakglass_justification"("p_reason" "text", "p_case_ref" "text") RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
begin
  if p_reason is null or length(btrim(p_reason)) = 0 then
    raise exception 'breakglass_reason_required' using errcode = 'P0001';
  end if;
  if p_case_ref is null or length(btrim(p_case_ref)) = 0 then
    raise exception 'breakglass_case_ref_required' using errcode = 'P0001';
  end if;
end;
$$;


ALTER FUNCTION "public"."require_breakglass_justification"("p_reason" "text", "p_case_ref" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."required_verification_level"("p_estate" "uuid") RETURNS "public"."verification_level"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
declare
  v_juris       text;
  v_floor       public.verification_level;
  v_value_cents bigint;
  v_value_level public.verification_level;
begin
  -- (1) JURISDICTION FLOOR — the immovable legal minimum. Unmapped OR unapproved -> enhanced_kyc (fail closed).
  select e.jurisdiction into v_juris from public.estates e where e.id = p_estate;
  select jp.floor_level into v_floor
    from public.jurisdiction_policy jp
    where jp.jurisdiction = v_juris and jp.is_counsel_approved = true;
  if v_floor is null then
    v_floor := 'enhanced_kyc';   -- STRUCTURAL fail-closed: unknown/unapproved = maximum
  end if;

  -- (2) ESCALATION FACTORS — each maps a SERVER-DERIVED input to a level; each can only RAISE.
  --     Estate value (normalized_assets): a value-tier CASE, monotone in value.
  select coalesce(sum(na.balance_cents), 0) into v_value_cents
    from public.normalized_assets na where na.estate_id = p_estate;
  v_value_level := case
    when v_value_cents >= 100000000 then 'enhanced_kyc'::public.verification_level   -- >= $1,000,000
    when v_value_cents >=  10000000 then 'kyc'::public.verification_level             -- >= $100,000
    else 'attestation'::public.verification_level
  end;
  -- (future factors — international participants [always >= kyc], fraud signals, owner override — each becomes
  --  ONE more argument to the GREATEST below. No data source exists for them yet, so they are OMITTED, not
  --  stubbed at a low level. Adding one CANNOT lower the result — it can only add an upward contributor.)

  -- (3) MONOTONIC COMBINE — the ONLY combinator. No path returns below v_floor.
  return greatest(v_floor, v_value_level);
end;
$_$;


ALTER FUNCTION "public"."required_verification_level"("p_estate" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."resolve_membership"("p_email" "text", "p_phone" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_user uuid := auth.uid();
  v_primary jsonb;
  v_pending jsonb;
  v_additional jsonb;
  v_primary_estate_id uuid;
begin
  -- Caller must be authenticated. Resolution has no meaning otherwise.
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;

  -- Look for the user's primary estate (one they own and that is
  -- marked as is_primary). If none exists, bootstrap one.
  select id into v_primary_estate_id
  from public.estates
  where owner_id = v_user
    and is_primary = true
  limit 1;

  if v_primary_estate_id is null then
    v_primary_estate_id := gen_random_uuid();
    insert into public.estates
      (id, owner_id, name, status, is_primary, created_at, updated_at)
    values
      (v_primary_estate_id, v_user, 'My Estate', 'active', true,
       now(), now());

    -- Note: NO insert into estate_memberships here. The trigger
    -- estates_ensure_primary_user_membership handles it with the
    -- correct V1 'primary_user' role.

    perform public.write_audit(
      'estate.primary_created',
      'estates',
      v_primary_estate_id,
      v_primary_estate_id,
      '{}'::jsonb
    );
  end if;

  -- Primary estate context: the user's own estate.
  select jsonb_build_object(
    'id', m.id,
    'estateId', e.id,
    'estateDisplayName', e.name,
    'ownerUserId', e.owner_id,
    'roleWithinEstate', m.role,
    'membershipStatus', m.status,
    'isPrimaryEstate', true
  )
  into v_primary
  from public.estate_memberships m
  join public.estates e on e.id = m.estate_id
  where m.user_id = v_user
    and e.is_primary = true
    and m.status = 'approved'
    and public.is_ownership_role(m.role)
  limit 1;

  -- Pending invitations matching the user's email or phone.
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', i.id,
    'estateId', i.estate_id,
    'estateDisplayName',
      case when (i.preview_visibility->>'showEstateName')::boolean
           then i.estate_display_name else null end,
    'inviterDisplayName',
      case when (i.preview_visibility->>'showInviterName')::boolean
           then i.inviter_display_name else null end,
    'invitationKind', i.kind,
    'proposedRole', i.proposed_role,
    'expiresAt', i.expires_at,
    'status', i.status
  )), '[]'::jsonb)
  into v_pending
  from public.invitations i
  where i.status in ('pending', 'matched')
    and i.expires_at > now()
    and (
      (p_email is not null
       and i.invitee_email is not null
       and lower(i.invitee_email) = lower(p_email))
      or
      (p_phone is not null
       and i.invitee_phone is not null
       and i.invitee_phone = p_phone)
    );

  -- Additional contexts: approved memberships in estates the user does NOT own.
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', m.id,
    'estateId', e.id,
    'estateDisplayName', e.name,
    'ownerUserId', e.owner_id,
    'roleWithinEstate', m.role,
    'membershipStatus', m.status,
    'isPrimaryEstate', false
  )), '[]'::jsonb)
  into v_additional
  from public.estate_memberships m
  join public.estates e on e.id = m.estate_id
  where m.user_id = v_user
    and m.status = 'approved'
    and not public.is_ownership_role(m.role);

  return jsonb_build_object(
    'primaryEstateContext', v_primary,
    'pendingInvitations', v_pending,
    'additionalContexts', v_additional
  );
end;
$$;


ALTER FUNCTION "public"."resolve_membership"("p_email" "text", "p_phone" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."restore_estate_asset"("p_asset_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid    uuid := auth.uid();
  v_estate uuid;
  v_arch   timestamptz;
begin
  if v_uid is null then raise exception 'auth_required' using errcode = '42501'; end if;
  select estate_id, archived_at into v_estate, v_arch from public.estate_assets where id = p_asset_id;
  if not found then raise exception 'asset_not_found' using errcode = 'P0002'; end if;
  if not public.is_estate_owner(v_estate) then raise exception 'not_estate_owner' using errcode = '42501'; end if;
  if v_arch is null then raise exception 'not_archived' using errcode = 'P0001'; end if;

  update public.estate_assets
     set archived_at = null, archived_by = null, updated_at = now()
   where id = p_asset_id;

  perform public.write_audit('estate_asset.restored', 'estate_assets', p_asset_id, v_estate,
    jsonb_build_object('via', 'restore_estate_asset'));
end;
$$;


ALTER FUNCTION "public"."restore_estate_asset"("p_asset_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."revoke_document_grant"("p_grant_id" "uuid") RETURNS SETOF "public"."access_grants"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_user uuid := auth.uid();
  v_estate uuid;
  v_status text;
begin
  -- Auth null-guard.
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;

  -- Read-only lookup to resolve the grant's estate for the owner-check. No mutation
  -- happens before the gate below.
  select estate_id, status into v_estate, v_status
  from public.access_grants
  where id = p_grant_id;

  if v_estate is null then
    raise exception 'grant_not_found';  -- P0001 -> 400
  end if;

  -- SECURITY SPINE (privilege-escalation gate): must precede the UPDATE.
  if not public.is_estate_owner(v_estate) then
    raise exception 'not estate owner' using errcode = '42501';
  end if;

  -- Idempotent: already revoked -> return as-is, no duplicate audit.
  if v_status = 'revoked' then
    return query select g.* from public.access_grants g where g.id = p_grant_id;
    return;
  end if;

  update public.access_grants
     set status = 'revoked',
         revoked_at = now(),
         revoked_by_user_id = v_user,
         updated_at = now()
   where id = p_grant_id;

  perform public.write_audit(
    'access_grant.revoked',
    'access_grants',
    p_grant_id,
    v_estate,
    jsonb_build_object('revoked_by_user_id', v_user)
  );

  -- ★ PHASE 10-E — the GRANTEE learns their access changed, and learns NOTHING ELSE.
  --
  -- The copy is "Your access to shared estate information has changed." It does not name the
  -- document, the category, the tier, or who revoked it. That is the point: whatever was authorized
  -- a moment ago is not authorized now, and a notification row OUTLIVES the grant it describes — so
  -- "Your access to 2026 UBS Account Statement was revoked" would re-disclose that title forever, in
  -- the one place the person can still read it after losing the right to.
  --
  -- Emitted after the UPDATE and after the idempotent early-return above, so a second revoke of an
  -- already-revoked grant says nothing a second time.
  perform public.emit_lifecycle_notification(
    (select g.grantee_user_id from public.access_grants g where g.id = p_grant_id),
    v_estate,
    'access_grant.revoked',
    null   -- nothing to open; a link here would lead to a refusal
  );

  return query select g.* from public.access_grants g where g.id = p_grant_id;
end;
$$;


ALTER FUNCTION "public"."revoke_document_grant"("p_grant_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."revoke_estate_invitation"("p_estate" "uuid", "p_invitation" "uuid") RETURNS TABLE("invitation_id" "uuid", "status" "text", "revoked_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_inv record; v_eff text;
begin
  perform public.estate_owner_gate(p_estate);

  select * into v_inv from public.invitations
   where id = p_invitation and estate_id = p_estate for update;
  -- Cross-estate and unknown ids are indistinguishable: an owner must not be able to probe for
  -- the existence of another estate's invitations.
  if not found then raise exception 'invitation_not_found' using errcode = 'P0002'; end if;

  -- Idempotent on already-revoked: repeating the operation returns the authoritative revoked row
  -- rather than an error, so a retried request is safe.
  if v_inv.status = 'revoked' then
    return query select v_inv.id, v_inv.status, v_inv.revoked_at;
    return;
  end if;

  v_eff := public.invitation_effective_status(v_inv.status, v_inv.expires_at);
  if v_eff not in ('pending', 'matched') then
    raise exception 'invitation_not_actionable' using errcode = 'P0005';
  end if;

  update public.invitations
     set status = 'revoked', revoked_at = now(), revoked_by = auth.uid(), updated_at = now()
   where id = v_inv.id;

  -- Any queued delivery for a revoked invitation must not go out.
  update public.invitation_delivery_outbox as ob
     set status = 'cancelled', last_error = 'invitation_revoked'
   where ob.invitation_id = v_inv.id and ob.status in ('queued', 'retryPending');

  perform public.write_audit('invitation.revoked', 'invitations', v_inv.id, p_estate,
    jsonb_build_object('invitation_id', v_inv.id, 'prior_status', v_inv.status));

  return query select v_inv.id, 'revoked'::text, now();
end;
$$;


ALTER FUNCTION "public"."revoke_estate_invitation"("p_estate" "uuid", "p_invitation" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."revoke_invitation"("p_invitation_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_inv record;
begin
  if auth.uid() is null then raise exception 'auth_required' using errcode = '42501'; end if;
  select * into v_inv from public.invitations where id = p_invitation_id for update;
  if not found then raise exception 'invitation_not_found' using errcode = 'P0002'; end if;
  perform public.invitation_write_gate(v_inv.estate_id);

  if v_inv.status = 'revoked' then return; end if;                         -- idempotent
  if v_inv.status not in ('pending','matched') then
    raise exception 'cannot_revoke_%', v_inv.status using errcode = 'P0005';  -- e.g. accepted/declined
  end if;

  update public.invitations set status = 'revoked', updated_at = now() where id = v_inv.id;
  perform public.write_audit('invitation.revoked', 'invitations', v_inv.id, v_inv.estate_id,
    jsonb_build_object('invitation_id', v_inv.id, 'prior_status', v_inv.status));
end;
$$;


ALTER FUNCTION "public"."revoke_invitation"("p_invitation_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rls_auto_enable"() RETURNS "event_trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog'
    AS $$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."rls_auto_enable"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_jurisdiction_floor"("p_jurisdiction" "text", "p_floor_level" "public"."verification_level", "p_is_approved" boolean, "p_notes" "text", "p_reason" "text", "p_case_ref" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_old text;
begin
  perform public.admin_require_gate();                       -- auth -> is_admin -> aal2 -> 15-min freshness
  perform public.require_breakglass_justification(p_reason, p_case_ref);
  if p_jurisdiction is null or length(btrim(p_jurisdiction)) = 0 then
    raise exception 'jurisdiction_required' using errcode = 'P0001';
  end if;

  select floor_level::text into v_old from public.jurisdiction_policy where jurisdiction = p_jurisdiction;

  insert into public.jurisdiction_policy
    (jurisdiction, floor_level, is_counsel_approved, notes, updated_by, updated_at)
  values
    (p_jurisdiction, p_floor_level, p_is_approved, p_notes, auth.uid(), now())
  on conflict (jurisdiction) do update
    set floor_level         = excluded.floor_level,
        is_counsel_approved = excluded.is_counsel_approved,
        notes               = excluded.notes,
        updated_by          = excluded.updated_by,
        updated_at          = now();

  perform public.write_admin_breakglass_audit(
    'admin.jurisdiction_floor.set', 'jurisdiction_policy', null, null, p_reason, p_case_ref,
    jsonb_build_object('jurisdiction', p_jurisdiction, 'old_floor', v_old,
                       'new_floor', p_floor_level::text, 'is_counsel_approved', p_is_approved));
end;
$$;


ALTER FUNCTION "public"."set_jurisdiction_floor"("p_jurisdiction" "text", "p_floor_level" "public"."verification_level", "p_is_approved" boolean, "p_notes" "text", "p_reason" "text", "p_case_ref" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."submit_claim_packet"("p_estate" "uuid", "p_death_certificate_doc_id" "uuid" DEFAULT NULL::"uuid", "p_executor_id_doc_id" "uuid" DEFAULT NULL::"uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_uid uuid := auth.uid(); v_id uuid;
begin
  if v_uid is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;
  -- SUBMIT AUTHORITY = an ACTIVE executor/trustee DESIGNATION (never a membership role). is_estate_executor
  -- already requires status='active', so a revoked designee is rejected here just like at read time.
  if not public.is_estate_executor(p_estate, v_uid) then
    raise exception 'not_estate_executor' using errcode = '42501';
  end if;
  if not exists (select 1 from public.estates where id = p_estate) then
    raise exception 'estate_not_found' using errcode = 'P0002';
  end if;

  -- Structural binding: a supplied evidence doc must belong to THIS estate (blocks a cross-estate doc ref).
  if p_death_certificate_doc_id is not null
     and not exists (select 1 from public.documents d where d.id = p_death_certificate_doc_id and d.estate_id = p_estate) then
    raise exception 'doc_not_in_estate' using errcode = 'P0001';
  end if;
  if p_executor_id_doc_id is not null
     and not exists (select 1 from public.documents d where d.id = p_executor_id_doc_id and d.estate_id = p_estate) then
    raise exception 'doc_not_in_estate' using errcode = 'P0001';
  end if;

  -- Idempotency: at most one ACTIVE (non-rejected) claim per estate (clean error; the partial-unique backstops races).
  if exists (select 1 from public.claim_packets c where c.estate_id = p_estate and c.status <> 'rejected') then
    raise exception 'active_claim_exists' using errcode = 'P0001';
  end if;

  insert into public.claim_packets
    (estate_id, requested_by, status, death_certificate_doc_id, executor_id_doc_id, submitted_at)
  values
    (p_estate, v_uid, 'submitted', p_death_certificate_doc_id, p_executor_id_doc_id, now())
  returning id into v_id;

  perform public.write_audit('claim.submitted', 'claim_packets', v_id, p_estate,
    jsonb_build_object('claim_id', v_id,
      'has_death_cert', p_death_certificate_doc_id is not null,
      'has_executor_id', p_executor_id_doc_id is not null));

  return v_id;
end;
$$;


ALTER FUNCTION "public"."submit_claim_packet"("p_estate" "uuid", "p_death_certificate_doc_id" "uuid", "p_executor_id_doc_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."submit_claim_with_evidence"("p_estate" "uuid", "p_death_cert_doc_id" "uuid", "p_death_cert_path" "text", "p_executor_id_doc_id" "uuid", "p_executor_id_path" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
declare
  v_uid       uuid := auth.uid();
  v_claim     uuid;
  v_dc_size   bigint; v_dc_mime text;
  v_ex_size   bigint; v_ex_mime text;
  v_max_file  bigint; v_max_agg bigint; v_max_files int; v_mimes text[];
begin
  if v_uid is null then
    raise exception 'auth_required' using errcode = '42501';
  end if;
  if not public.is_estate_executor(p_estate, v_uid) then
    raise exception 'not_estate_executor' using errcode = '42501';
  end if;
  if not exists (select 1 from public.estates where id = p_estate) then
    raise exception 'estate_not_found' using errcode = 'P0002';
  end if;
  if exists (select 1 from public.claim_packets c where c.estate_id = p_estate and c.status <> 'rejected') then
    raise exception 'active_claim_exists' using errcode = 'P0001';
  end if;

  -- Policy = the single source (fail-closed if the singleton is somehow absent).
  select max_upload_bytes, max_aggregate_bytes, max_files_per_claim, allowed_mime_types
    into v_max_file, v_max_agg, v_max_files, v_mimes
    from public.upload_policy where id = 1;
  if not found then
    raise exception 'upload_policy_missing' using errcode = 'P0002';
  end if;

  if p_death_cert_path !~ ('^estates/' || p_estate::text || '/claim-evidence/' || p_death_cert_doc_id::text || '\.[a-zA-Z0-9]+$') then
    raise exception 'evidence_path_mismatch' using errcode = 'P0001';
  end if;
  if p_executor_id_path !~ ('^estates/' || p_estate::text || '/claim-evidence/' || p_executor_id_doc_id::text || '\.[a-zA-Z0-9]+$') then
    raise exception 'evidence_path_mismatch' using errcode = 'P0001';
  end if;

  select (o.metadata->>'size')::bigint, o.metadata->>'mimetype' into v_dc_size, v_dc_mime
    from storage.objects o where o.bucket_id = 'documents' and o.name = p_death_cert_path;
  if not found then
    raise exception 'evidence_object_missing' using errcode = 'P0002';
  end if;
  select (o.metadata->>'size')::bigint, o.metadata->>'mimetype' into v_ex_size, v_ex_mime
    from storage.objects o where o.bucket_id = 'documents' and o.name = p_executor_id_path;
  if not found then
    raise exception 'evidence_object_missing' using errcode = 'P0002';
  end if;

  -- File count (this RPC creates 2) + MIME allowlist (defense-in-depth; the bucket already enforced at upload)
  -- + per-file + aggregate — ALL sourced from upload_policy (the same numbers get_upload_policy tells the client).
  if 2 > v_max_files then
    raise exception 'evidence_too_many_files' using errcode = 'P0001';
  end if;
  if (v_dc_mime is not null and not (v_dc_mime = any(v_mimes)))
     or (v_ex_mime is not null and not (v_ex_mime = any(v_mimes))) then
    raise exception 'evidence_mime_rejected' using errcode = 'P0001';
  end if;
  if coalesce(v_dc_size, 0) > v_max_file or coalesce(v_ex_size, 0) > v_max_file then
    raise exception 'evidence_too_large' using errcode = 'P0001';
  end if;
  if coalesce(v_dc_size, 0) + coalesce(v_ex_size, 0) > v_max_agg then
    raise exception 'evidence_quota_exceeded' using errcode = 'P0001';
  end if;

  insert into public.documents
    (id, estate_id, owner_id, doc_type, title, storage_path, mime_type, size_bytes, is_encrypted, sensitivity)
  values
    (p_death_cert_doc_id,  p_estate, v_uid, 'death_certificate', 'Death Certificate', p_death_cert_path,  v_dc_mime, v_dc_size, false, 'sealed'),
    (p_executor_id_doc_id, p_estate, v_uid, 'id_document',       'Executor ID',       p_executor_id_path, v_ex_mime, v_ex_size, false, 'sealed');

  insert into public.claim_packets
    (estate_id, requested_by, status, death_certificate_doc_id, executor_id_doc_id, submitted_at)
  values
    (p_estate, v_uid, 'submitted', p_death_cert_doc_id, p_executor_id_doc_id, now())
  returning id into v_claim;

  perform public.write_audit('claim.submitted', 'claim_packets', v_claim, p_estate,
    jsonb_build_object('claim_id', v_claim, 'has_death_cert', true, 'has_executor_id', true,
                       'via', 'submit_claim_with_evidence'));

  return v_claim;
end;
$_$;


ALTER FUNCTION "public"."submit_claim_with_evidence"("p_estate" "uuid", "p_death_cert_doc_id" "uuid", "p_death_cert_path" "text", "p_executor_id_doc_id" "uuid", "p_executor_id_path" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."unlink_asset_document"("p_asset_id" "uuid", "p_doc_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_uid       uuid := auth.uid();
  v_asset_est uuid;
begin
  if v_uid is null then raise exception 'auth_required' using errcode = '42501'; end if;
  select estate_id into v_asset_est from public.estate_assets where id = p_asset_id;
  if not found then raise exception 'asset_not_found' using errcode = 'P0002'; end if;
  if not public.is_estate_owner(v_asset_est) then raise exception 'not_estate_owner' using errcode = '42501'; end if;

  delete from public.estate_asset_documents where asset_id = p_asset_id and doc_id = p_doc_id;

  -- ★ UNLINKING DELETES NO BYTES AND NO DOCUMENT ROW. Detaching evidence from an asset is an
  -- organisational act; removing the document itself remains `delete_vault_document`, with its own
  -- blocking gauntlet and purge outbox.
  perform public.write_audit('estate_asset.document_unlinked', 'estate_assets', p_asset_id, v_asset_est,
    jsonb_build_object('doc_id', p_doc_id, 'via', 'unlink_asset_document'));
end;
$$;


ALTER FUNCTION "public"."unlink_asset_document"("p_asset_id" "uuid", "p_doc_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_asset_grant"("p_grant_id" "uuid", "p_visibility_tier" "text") RETURNS SETOF "public"."access_grants"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_row public.access_grants;
begin
  -- Common guards: owner-gate-first + exists + active.
  v_row := public.assert_grant_updatable(p_grant_id);

  -- Scope: this RPC edits category (asset) grants only.
  if v_row.category is null then
    raise exception 'not an asset grant';  -- P0001 -> 400
  end if;

  -- No-op if the tier is unchanged (avoid a spurious audit row).
  if v_row.visibility_tier = p_visibility_tier then
    return query select g.* from public.access_grants g where g.id = p_grant_id;
    return;
  end if;

  -- ★ Ceiling on the NEW tier (explicit — the trigger won't fire for category grants).
  if not public.asset_category_grantable(v_row.grantee_role, v_row.category, p_visibility_tier) then
    raise exception 'asset grant ceiling: role % cannot be granted tier % for category %',
      v_row.grantee_role, p_visibility_tier, v_row.category
      using errcode = '42501';
  end if;

  update public.access_grants
     set visibility_tier = p_visibility_tier, updated_at = now()
   where id = p_grant_id;

  perform public.write_audit(
    'access_grant.updated', 'access_grants', p_grant_id, v_row.estate_id,
    jsonb_build_object(
      'category', v_row.category,
      'from_tier', v_row.visibility_tier,
      'to_tier', p_visibility_tier
    )
  );

  return query select g.* from public.access_grants g where g.id = p_grant_id;
end;
$$;


ALTER FUNCTION "public"."update_asset_grant"("p_grant_id" "uuid", "p_visibility_tier" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_document_grant"("p_grant_id" "uuid", "p_visibility_tier" "text") RETURNS SETOF "public"."access_grants"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_row public.access_grants;
begin
  -- Common guards: owner-gate-first + exists + active.
  v_row := public.assert_grant_updatable(p_grant_id);

  -- Scope: this RPC edits document grants only.
  if v_row.document_id is null then
    raise exception 'not a document grant';  -- P0001 -> 400
  end if;

  -- No-op if the tier is unchanged.
  if v_row.visibility_tier = p_visibility_tier then
    return query select g.* from public.access_grants g where g.id = p_grant_id;
    return;
  end if;

  -- Ceiling re-enforced by the enforce_grant_ceiling trigger (BEFORE UPDATE) on the line below —
  -- no explicit call (see header). A now-over-ceiling document (reclassified sealed/restricted) makes
  -- the trigger raise 42501 -> 403.
  update public.access_grants
     set visibility_tier = p_visibility_tier, updated_at = now()
   where id = p_grant_id;

  perform public.write_audit(
    'access_grant.updated', 'access_grants', p_grant_id, v_row.estate_id,
    jsonb_build_object(
      'document_id', v_row.document_id,
      'from_tier', v_row.visibility_tier,
      'to_tier', p_visibility_tier
    )
  );

  return query select g.* from public.access_grants g where g.id = p_grant_id;
end;
$$;


ALTER FUNCTION "public"."update_document_grant"("p_grant_id" "uuid", "p_visibility_tier" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_estate_asset"("p_asset_id" "uuid", "p_subtype" "text" DEFAULT NULL::"text", "p_label" "text" DEFAULT NULL::"text", "p_sensitivity" "text" DEFAULT NULL::"text", "p_owner_label" "text" DEFAULT NULL::"text", "p_country_code" "text" DEFAULT NULL::"text", "p_jurisdiction" "text" DEFAULT NULL::"text", "p_institution_name" "text" DEFAULT NULL::"text", "p_reference_hint" "text" DEFAULT NULL::"text", "p_approximate_value_cents" bigint DEFAULT NULL::bigint, "p_currency" "text" DEFAULT NULL::"text", "p_notes" "text" DEFAULT NULL::"text", "p_beneficiary_note" "text" DEFAULT NULL::"text", "p_verification_status" "text" DEFAULT NULL::"text", "p_clear" "text"[] DEFAULT NULL::"text"[]) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
declare
  v_uid      uuid := auth.uid();
  v_estate   uuid;
  v_arch     timestamptz;
  v_category text;
  v_changed  text[] := '{}';
  v_field    text;
begin
  if v_uid is null then raise exception 'auth_required' using errcode = '42501'; end if;

  select estate_id, archived_at into v_estate, v_arch from public.estate_assets where id = p_asset_id;
  if not found then raise exception 'asset_not_found' using errcode = 'P0002'; end if;
  if not public.is_estate_owner(v_estate) then raise exception 'not_estate_owner' using errcode = '42501'; end if;
  -- An archived asset is restored before it is edited. Editing something the owner has removed from
  -- the inventory would silently resurrect it in every list that filters on archived_at.
  if v_arch is not null then raise exception 'asset_archived' using errcode = 'P0001'; end if;

  if p_subtype is null and p_label is null and p_sensitivity is null and p_owner_label is null
     and p_country_code is null and p_jurisdiction is null and p_institution_name is null
     and p_reference_hint is null and p_approximate_value_cents is null and p_currency is null
     and p_notes is null and p_beneficiary_note is null and p_verification_status is null
     and (p_clear is null or array_length(p_clear, 1) is null) then
    raise exception 'no_fields_to_update' using errcode = 'P0001';
  end if;

  if p_label is not null then
    if length(btrim(p_label)) = 0 then raise exception 'label_required' using errcode = 'P0001'; end if;
    if length(p_label) > 200 then raise exception 'label_too_long' using errcode = 'P0001'; end if;
    update public.estate_assets set label = btrim(p_label) where id = p_asset_id;
    v_changed := array_append(v_changed, 'label');
  end if;

  if p_subtype is not null then
    select s.parent_category into v_category
      from public.estate_asset_subtype s where s.subtype = p_subtype and s.is_active;
    if not found then
      if exists (select 1 from public.estate_asset_subtype where subtype = p_subtype) then
        raise exception 'inactive_subtype' using errcode = 'P0001';
      else
        raise exception 'unknown_subtype' using errcode = 'P0001';
      end if;
    end if;
    -- The category is RE-DERIVED, never taken from the caller — the pair cannot be made inconsistent.
    update public.estate_assets set subtype = p_subtype, category = v_category where id = p_asset_id;
    v_changed := array_append(v_changed, 'subtype');
    v_changed := array_append(v_changed, 'category');
  end if;

  if p_sensitivity is not null then
    if not exists (select 1 from public.document_sensitivity where value = p_sensitivity and is_active) then
      raise exception 'invalid_sensitivity' using errcode = 'P0001';
    end if;
    update public.estate_assets set sensitivity = p_sensitivity where id = p_asset_id;
    v_changed := array_append(v_changed, 'sensitivity');
  end if;

  if p_verification_status is not null then
    if p_verification_status not in ('unverified','ownerAsserted','documented','verified') then
      raise exception 'invalid_verification_status' using errcode = 'P0001';
    end if;
    update public.estate_assets set verification_status = p_verification_status where id = p_asset_id;
    v_changed := array_append(v_changed, 'verification_status');
  end if;

  if p_currency is not null then
    if upper(p_currency) !~ '^[A-Z]{3}$' then raise exception 'invalid_currency' using errcode = 'P0001'; end if;
    update public.estate_assets set currency = upper(p_currency) where id = p_asset_id;
    v_changed := array_append(v_changed, 'currency');
  end if;

  if p_approximate_value_cents is not null then
    if p_approximate_value_cents < 0 then raise exception 'invalid_value' using errcode = 'P0001'; end if;
    update public.estate_assets set approximate_value_cents = p_approximate_value_cents where id = p_asset_id;
    v_changed := array_append(v_changed, 'approximate_value_cents');
  end if;

  if p_reference_hint is not null then
    if length(p_reference_hint) > 12 then raise exception 'reference_hint_too_long' using errcode = 'P0001'; end if;
    update public.estate_assets set reference_hint = p_reference_hint where id = p_asset_id;
    v_changed := array_append(v_changed, 'reference_hint');
  end if;

  if p_country_code is not null then
    if upper(btrim(p_country_code)) !~ '^[A-Z]{2}$' then
      raise exception 'invalid_country_code' using errcode = 'P0001';
    end if;
    update public.estate_assets set country_code = upper(btrim(p_country_code)) where id = p_asset_id;
    v_changed := array_append(v_changed, 'country_code');
  end if;

  if p_owner_label is not null then
    update public.estate_assets set owner_label = p_owner_label where id = p_asset_id;
    v_changed := array_append(v_changed, 'owner_label');
  end if;
  if p_jurisdiction is not null then
    update public.estate_assets set jurisdiction = p_jurisdiction where id = p_asset_id;
    v_changed := array_append(v_changed, 'jurisdiction');
  end if;
  if p_institution_name is not null then
    update public.estate_assets set institution_name = p_institution_name where id = p_asset_id;
    v_changed := array_append(v_changed, 'institution_name');
  end if;
  if p_notes is not null then
    update public.estate_assets set notes = p_notes where id = p_asset_id;
    v_changed := array_append(v_changed, 'notes');
  end if;
  if p_beneficiary_note is not null then
    update public.estate_assets set beneficiary_note = p_beneficiary_note where id = p_asset_id;
    v_changed := array_append(v_changed, 'beneficiary_note');
  end if;

  -- Explicit clearing. Only genuinely optional columns are clearable — `label`, `subtype`,
  -- `category`, `sensitivity` and `currency` are NOT NULL and are absent from this list by design.
  if p_clear is not null then
    foreach v_field in array p_clear loop
      case v_field
        when 'owner_label'             then update public.estate_assets set owner_label = null where id = p_asset_id;
        when 'country_code'            then update public.estate_assets set country_code = null where id = p_asset_id;
        when 'jurisdiction'            then update public.estate_assets set jurisdiction = null where id = p_asset_id;
        when 'institution_name'        then update public.estate_assets set institution_name = null where id = p_asset_id;
        when 'reference_hint'          then update public.estate_assets set reference_hint = null where id = p_asset_id;
        when 'approximate_value_cents' then update public.estate_assets set approximate_value_cents = null where id = p_asset_id;
        when 'notes'                   then update public.estate_assets set notes = null where id = p_asset_id;
        when 'beneficiary_note'        then update public.estate_assets set beneficiary_note = null where id = p_asset_id;
        else raise exception 'unclearable_field' using errcode = 'P0001';
      end case;
      v_changed := array_append(v_changed, 'cleared:' || v_field);
    end loop;
  end if;

  update public.estate_assets set updated_at = now() where id = p_asset_id;

  perform public.write_audit('estate_asset.updated', 'estate_assets', p_asset_id, v_estate,
    jsonb_build_object('changed', to_jsonb(v_changed), 'via', 'update_estate_asset'));
end;
$_$;


ALTER FUNCTION "public"."update_estate_asset"("p_asset_id" "uuid", "p_subtype" "text", "p_label" "text", "p_sensitivity" "text", "p_owner_label" "text", "p_country_code" "text", "p_jurisdiction" "text", "p_institution_name" "text", "p_reference_hint" "text", "p_approximate_value_cents" bigint, "p_currency" "text", "p_notes" "text", "p_beneficiary_note" "text", "p_verification_status" "text", "p_clear" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_vault_document"("p_doc_id" "uuid", "p_title" "text" DEFAULT NULL::"text", "p_doc_subtype" "text" DEFAULT NULL::"text", "p_sensitivity" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
$$;


ALTER FUNCTION "public"."update_vault_document"("p_doc_id" "uuid", "p_title" "text", "p_doc_subtype" "text", "p_sensitivity" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."validate_recovery_code"("p_code" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_user         uuid := auth.uid();
  v_id           uuid;
  v_locked_until timestamptz;
begin
  if v_user is null then
    raise exception 'unauthenticated' using errcode = '42501';
  end if;

  -- Lockout check (brute-force guard) — reject without even testing the code.
  select locked_until into v_locked_until
  from public.mfa_recovery_attempts where user_id = v_user;
  if v_locked_until is not null and v_locked_until > now() then
    raise exception 'too many recovery attempts; try again later' using errcode = 'P0001';
  end if;

  -- Match an UNUSED code for this user (bcrypt compare; ~10 rows). Do NOT mark used.
  select id into v_id
  from public.recovery_codes
  where user_id = v_user
    and used_at is null
    and code_hash = extensions.crypt(p_code, code_hash)
  limit 1;

  if v_id is null then
    -- Wrong/used code → a failed attempt; lock after 5 consecutive failures.
    insert into public.mfa_recovery_attempts (user_id, failed_count, updated_at)
      values (v_user, 1, now())
    on conflict (user_id) do update
      set failed_count = public.mfa_recovery_attempts.failed_count + 1,
          locked_until = case
            when public.mfa_recovery_attempts.failed_count + 1 >= 5
              then now() + interval '15 minutes'
            else null
          end,
          updated_at = now();
    return null;
  end if;

  -- Valid code presented → clear the attempt/lockout state (legitimacy proven). NOT consumed yet.
  delete from public.mfa_recovery_attempts where user_id = v_user;
  return v_id;
end;
$$;


ALTER FUNCTION "public"."validate_recovery_code"("p_code" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."write_admin_breakglass_audit"("p_action" "text", "p_table" "text", "p_target" "uuid", "p_estate" "uuid", "p_reason" "text", "p_case_ref" "text", "p_meta" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  insert into public.audit_logs(actor_id, estate_id, action, target_table, target_id, metadata, source)
  values (
    auth.uid(), p_estate, p_action, p_table, p_target,
    coalesce(p_meta, '{}'::jsonb)
      || jsonb_build_object('severity', 'high', 'breakglass', true, 'reason', p_reason, 'case_ref', p_case_ref),
    'admin'
  );
end;
$$;


ALTER FUNCTION "public"."write_admin_breakglass_audit"("p_action" "text", "p_table" "text", "p_target" "uuid", "p_estate" "uuid", "p_reason" "text", "p_case_ref" "text", "p_meta" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."write_audit"("p_action" "text", "p_table" "text", "p_target" "uuid", "p_estate" "uuid", "p_meta" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  insert into audit_logs(actor_id, estate_id, action, target_table, target_id, metadata)
  values (auth.uid(), p_estate, p_action, p_table, p_target, p_meta);
end $$;


ALTER FUNCTION "public"."write_audit"("p_action" "text", "p_table" "text", "p_target" "uuid", "p_estate" "uuid", "p_meta" "jsonb") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."admins" (
    "user_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "note" "text"
);


ALTER TABLE "public"."admins" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."assets" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "estate_id" "uuid" NOT NULL,
    "owner_id" "uuid" NOT NULL,
    "asset_type" "text" NOT NULL,
    "title" "text" NOT NULL,
    "institution" "text",
    "identifier_last4" "text",
    "estimated_value_cents" bigint,
    "currency" "text" DEFAULT 'USD'::"text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "assets_asset_type_check" CHECK (("asset_type" = ANY (ARRAY['bank_account'::"text", 'investment'::"text", 'real_estate'::"text", 'vehicle'::"text", 'digital_asset'::"text", 'crypto'::"text", 'insurance'::"text", 'retirement'::"text", 'other'::"text"])))
);


ALTER TABLE "public"."assets" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."audit_logs_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."audit_logs_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."audit_logs_id_seq" OWNED BY "public"."audit_logs"."id";



CREATE TABLE IF NOT EXISTS "public"."beneficiaries" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "estate_id" "uuid" NOT NULL,
    "owner_id" "uuid" NOT NULL,
    "full_name" "text" NOT NULL,
    "relationship" "text",
    "email" "text",
    "phone" "text",
    "allocation_percent" numeric(5,2),
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "user_id" "uuid",
    CONSTRAINT "beneficiaries_allocation_percent_check" CHECK ((("allocation_percent" >= (0)::numeric) AND ("allocation_percent" <= (100)::numeric)))
);


ALTER TABLE "public"."beneficiaries" OWNER TO "postgres";


COMMENT ON COLUMN "public"."beneficiaries"."user_id" IS 'auth.uid() of the user who accepted the beneficiary invitation for this row. Bare uuid, no FK (matches estate_memberships.user_id). Null until accepted. RLS read policy: a beneficiary sees only rows where user_id = auth.uid().';



CREATE TABLE IF NOT EXISTS "public"."claim_packets" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "estate_id" "uuid" NOT NULL,
    "requested_by" "uuid" NOT NULL,
    "status" "text" DEFAULT 'submitted'::"text" NOT NULL,
    "death_certificate_doc_id" "uuid",
    "executor_id_doc_id" "uuid",
    "reviewer_id" "uuid",
    "review_notes" "text",
    "submitted_at" timestamp with time zone DEFAULT "now"(),
    "decided_at" timestamp with time zone,
    CONSTRAINT "claim_packets_status_check" CHECK (("status" = ANY (ARRAY['submitted'::"text", 'under_review'::"text", 'approved'::"text", 'rejected'::"text", 'released'::"text"])))
);


ALTER TABLE "public"."claim_packets" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."connection_secrets" (
    "connection_id" "uuid" NOT NULL,
    "provider" "text" NOT NULL,
    "access_token" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."connection_secrets" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."consent_records" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "consent_type" "text" NOT NULL,
    "document_version" "text" NOT NULL,
    "accepted_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "consent_records_consent_type_check" CHECK (("consent_type" = ANY (ARRAY['terms_of_service'::"text", 'privacy_policy'::"text", 'data_sharing'::"text", 'beneficiary_disclosure'::"text", 'tax_disclaimer'::"text", 'platform_disclosure'::"text"])))
);


ALTER TABLE "public"."consent_records" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."death_verification_cases" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "estate_id" "uuid" NOT NULL,
    "event_type" "text" DEFAULT 'death'::"text" NOT NULL,
    "status" "text" DEFAULT 'open'::"text" NOT NULL,
    "initiated_by" "uuid" NOT NULL,
    "initiator_designation_id" "uuid" NOT NULL,
    "initiator_capacity" "text" NOT NULL,
    "jurisdiction_context" "text",
    "required_level_at_initiation" "public"."verification_level" NOT NULL,
    "attained_level" "public"."verification_level",
    "decided_by" "uuid",
    "decided_at" timestamp with time zone,
    "decision_note" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "death_verification_cases_event_type_check" CHECK (("event_type" = 'death'::"text")),
    CONSTRAINT "death_verification_cases_initiator_capacity_check" CHECK (("initiator_capacity" = ANY (ARRAY['executor'::"text", 'trustee'::"text"]))),
    CONSTRAINT "death_verification_cases_status_check" CHECK (("status" = ANY (ARRAY['open'::"text", 'verified'::"text", 'rejected'::"text", 'cancelled'::"text", 'halted'::"text"])))
);


ALTER TABLE "public"."death_verification_cases" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."death_verification_evidence" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "case_id" "uuid" NOT NULL,
    "estate_id" "uuid" NOT NULL,
    "document_id" "uuid" NOT NULL,
    "submitted_by" "uuid" NOT NULL,
    "submitted_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "review_status" "text" DEFAULT 'received'::"text" NOT NULL,
    "reviewed_by" "uuid",
    "reviewed_at" timestamp with time zone,
    "review_note" "text",
    CONSTRAINT "death_verification_evidence_review_status_check" CHECK (("review_status" = ANY (ARRAY['received'::"text", 'reviewed_accepted'::"text", 'reviewed_rejected'::"text"])))
);


ALTER TABLE "public"."death_verification_evidence" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."document_sensitivity" (
    "value" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "description" "text",
    "rank" integer DEFAULT 0 NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "badge_color_key" "text",
    "icon_key" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."document_sensitivity" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."document_subtype" (
    "subtype" "text" NOT NULL,
    "parent_doc_type" "text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "display_name" "text" NOT NULL,
    "description" "text",
    "rank" integer DEFAULT 0 NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "badge_color_key" "text",
    "icon_key" "text"
);


ALTER TABLE "public"."document_subtype" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."document_type" (
    "value" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "description" "text",
    "rank" integer DEFAULT 0 NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "badge_color_key" "text",
    "icon_key" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."document_type" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."documents" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "estate_id" "uuid" NOT NULL,
    "owner_id" "uuid" NOT NULL,
    "doc_type" "text" NOT NULL,
    "title" "text" NOT NULL,
    "storage_path" "text" NOT NULL,
    "mime_type" "text",
    "size_bytes" bigint,
    "sha256" "text",
    "is_encrypted" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "sensitivity" "text" DEFAULT 'sealed'::"text" NOT NULL,
    "doc_subtype" "text",
    "retention_until" timestamp with time zone
);


ALTER TABLE "public"."documents" OWNER TO "postgres";


COMMENT ON COLUMN "public"."documents"."sensitivity" IS 'Document-sensitivity ceiling (5-level monotonic ladder), DISTINCT from per-category ResourceSensitivity. Default sealed = owner-only until reclassified down. low/medium/high grantable to beneficiary + professional_delegate; restricted excludes beneficiaries (professional-only); sealed excludes all non-owners (owner always inherent). low/medium/high are equally grantable today — informational only; real floors are restricted + sealed. See docs/live-data-migration.md Appendix A.3.';



CREATE TABLE IF NOT EXISTS "public"."encrypted_instructions" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "estate_id" "uuid" NOT NULL,
    "owner_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "ciphertext" "bytea" NOT NULL,
    "iv" "bytea" NOT NULL,
    "wrapped_key" "bytea" NOT NULL,
    "release_condition" "text" NOT NULL,
    "released" boolean DEFAULT false,
    "released_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "encrypted_instructions_release_condition_check" CHECK (("release_condition" = ANY (ARRAY['on_death'::"text", 'on_executor_claim'::"text", 'manual'::"text"])))
);


ALTER TABLE "public"."encrypted_instructions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."estate_asset_category" (
    "value" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "description" "text",
    "sort_order" integer DEFAULT 0 NOT NULL,
    "icon_key" "text",
    "is_physical" boolean DEFAULT false NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."estate_asset_category" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."estate_asset_documents" (
    "asset_id" "uuid" NOT NULL,
    "doc_id" "uuid" NOT NULL,
    "linked_by" "uuid" NOT NULL,
    "linked_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."estate_asset_documents" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."estate_asset_subtype" (
    "subtype" "text" NOT NULL,
    "parent_category" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "description" "text",
    "sort_order" integer DEFAULT 0 NOT NULL,
    "icon_key" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."estate_asset_subtype" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."estate_assets" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "estate_id" "uuid" NOT NULL,
    "created_by" "uuid" NOT NULL,
    "category" "text" NOT NULL,
    "subtype" "text" NOT NULL,
    "label" "text" NOT NULL,
    "sensitivity" "text" DEFAULT 'sealed'::"text" NOT NULL,
    "owner_label" "text",
    "country_code" "text",
    "jurisdiction" "text",
    "institution_name" "text",
    "reference_hint" "text",
    "approximate_value_cents" bigint,
    "currency" "text" DEFAULT 'USD'::"text" NOT NULL,
    "notes" "text",
    "beneficiary_note" "text",
    "verification_status" "text" DEFAULT 'unverified'::"text" NOT NULL,
    "archived_at" timestamp with time zone,
    "archived_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "estate_assets_approximate_value_cents_check" CHECK ((("approximate_value_cents" IS NULL) OR ("approximate_value_cents" >= 0))),
    CONSTRAINT "estate_assets_archived_pair" CHECK ((("archived_at" IS NULL) = ("archived_by" IS NULL))),
    CONSTRAINT "estate_assets_country_code_check" CHECK ((("country_code" IS NULL) OR ("country_code" ~ '^[A-Z]{2}$'::"text"))),
    CONSTRAINT "estate_assets_currency_check" CHECK (("currency" ~ '^[A-Z]{3}$'::"text")),
    CONSTRAINT "estate_assets_label_len" CHECK (("length"("label") <= 200)),
    CONSTRAINT "estate_assets_label_not_blank" CHECK (("length"("btrim"("label")) > 0)),
    CONSTRAINT "estate_assets_reference_hint_check" CHECK ((("reference_hint" IS NULL) OR ("length"("reference_hint") <= 12))),
    CONSTRAINT "estate_assets_verification_status_check" CHECK (("verification_status" = ANY (ARRAY['unverified'::"text", 'ownerAsserted'::"text", 'documented'::"text", 'verified'::"text"])))
);


ALTER TABLE "public"."estate_assets" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."estate_designations" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "estate_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "designation_type" "text" NOT NULL,
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "source_invitation_id" "uuid",
    "granted_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "revoked_at" timestamp with time zone,
    CONSTRAINT "estate_designations_designation_type_check" CHECK (("designation_type" = ANY (ARRAY['executor'::"text", 'trustee'::"text"]))),
    CONSTRAINT "estate_designations_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'revoked'::"text"])))
);


ALTER TABLE "public"."estate_designations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."estate_lifecycle" (
    "estate_id" "uuid" NOT NULL,
    "state" "text" DEFAULT 'active'::"text" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_case_id" "uuid",
    "owner_notified_at" timestamp with time zone,
    "challenge_window_started_at" timestamp with time zone,
    "halted_at" timestamp with time zone,
    "released_at" timestamp with time zone,
    "safety_notification_id" "uuid",
    CONSTRAINT "estate_lifecycle_state_check" CHECK (("state" = ANY (ARRAY['active'::"text", 'death_verification_pending'::"text", 'death_verified'::"text", 'owner_notification_dispatched'::"text", 'challenge_window'::"text", 'challenge_halted'::"text", 'released'::"text"])))
);


ALTER TABLE "public"."estate_lifecycle" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."estate_memberships" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "estate_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "role" "text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "invited_by" "uuid",
    "approved_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "source_invitation_id" "uuid",
    CONSTRAINT "estate_memberships_role_check" CHECK (("role" = ANY (ARRAY['primary_user'::"text", 'beneficiary'::"text", 'professional_delegate'::"text"]))),
    CONSTRAINT "estate_memberships_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'revoked'::"text", 'expired'::"text"])))
);


ALTER TABLE "public"."estate_memberships" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."estates" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "owner_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "jurisdiction" "text",
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "is_primary" boolean DEFAULT false NOT NULL,
    CONSTRAINT "estates_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'locked'::"text", 'archived'::"text", 'in_claim'::"text"])))
);


ALTER TABLE "public"."estates" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."invitation_delivery_outbox" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "invitation_id" "uuid" NOT NULL,
    "estate_id" "uuid" NOT NULL,
    "reason" "text" NOT NULL,
    "requested_by" "uuid" NOT NULL,
    "requested_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "status" "text" DEFAULT 'queued'::"text" NOT NULL,
    "attempts" integer DEFAULT 0 NOT NULL,
    "last_error" "text",
    "issued_at" timestamp with time zone,
    "delivery_generation" integer DEFAULT 0 NOT NULL,
    "idempotency_key" "text",
    "provider_message_id" "text",
    "failure_class" "text",
    "next_attempt_at" timestamp with time zone,
    "claimed_at" timestamp with time zone,
    "last_outcome_at" timestamp with time zone,
    CONSTRAINT "invitation_delivery_outbox_failure_class_check" CHECK ((("failure_class" IS NULL) OR ("failure_class" = ANY (ARRAY['provider_rejected'::"text", 'provider_unavailable'::"text", 'rate_limited'::"text", 'invalid_recipient'::"text", 'configuration'::"text", 'timeout'::"text", 'unknown'::"text"])))),
    CONSTRAINT "invitation_delivery_outbox_reason_check" CHECK (("reason" = ANY (ARRAY['invitation_created'::"text", 'invitation_redelivery'::"text"]))),
    CONSTRAINT "invitation_delivery_outbox_status_check" CHECK (("status" = ANY (ARRAY['queued'::"text", 'processing'::"text", 'providerAccepted'::"text", 'outcomeUncertain'::"text", 'retryPending'::"text", 'failedPermanent'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."invitation_delivery_outbox" OWNER TO "postgres";


COMMENT ON TABLE "public"."invitation_delivery_outbox" IS 'Durable queue of invitation deliveries. Holds NO secret — the raw token is minted at issue time by issue_invitation_delivery() and never persisted. Drained by a trusted worker as service_role.';



COMMENT ON COLUMN "public"."invitation_delivery_outbox"."delivery_generation" IS 'Increments ONLY on deliberate token issuance. Half of the provider idempotency key. A retry reuses the generation; a reissue increments it and invalidates the previous link.';



COMMENT ON COLUMN "public"."invitation_delivery_outbox"."provider_message_id" IS 'Server-confined provider handle. NEVER returned to a client and NEVER logged.';



COMMENT ON COLUMN "public"."invitation_delivery_outbox"."failure_class" IS 'Sanitized classification. Raw provider text is not retained here — it can carry recipient PII.';



CREATE TABLE IF NOT EXISTS "public"."invitations" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "estate_id" "uuid" NOT NULL,
    "invited_by" "uuid" NOT NULL,
    "kind" "text" NOT NULL,
    "proposed_role" "text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "expires_at" timestamp with time zone NOT NULL,
    "invitee_email" "text",
    "invitee_phone" "text",
    "accepted_by" "uuid",
    "accepted_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "token_hash" "text" NOT NULL,
    "estate_display_name" "text",
    "inviter_display_name" "text",
    "invitee_email_hint" "text",
    "invitee_phone_hint" "text",
    "preview_visibility" "jsonb" DEFAULT '{}'::"jsonb",
    "declined_at" timestamp with time zone,
    "revoked_at" timestamp with time zone,
    "revoked_by" "uuid",
    "extended_at" timestamp with time zone,
    "extended_by" "uuid",
    CONSTRAINT "invitations_kind_check" CHECK (("kind" = ANY (ARRAY['beneficiary'::"text", 'professional_delegate'::"text", 'executor'::"text", 'trustee'::"text"]))),
    CONSTRAINT "invitations_proposed_role_check" CHECK (("proposed_role" = ANY (ARRAY['beneficiary'::"text", 'professional_delegate'::"text"]))),
    CONSTRAINT "invitations_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'matched'::"text", 'accepted'::"text", 'declined'::"text", 'expired'::"text", 'revoked'::"text"])))
);


ALTER TABLE "public"."invitations" OWNER TO "postgres";


COMMENT ON COLUMN "public"."invitations"."revoked_by" IS 'Owner (or console admin) who revoked. Never returned to a client — actor identity is audit data.';



CREATE TABLE IF NOT EXISTS "public"."jurisdiction_policy" (
    "jurisdiction" "text" NOT NULL,
    "floor_level" "public"."verification_level" NOT NULL,
    "is_counsel_approved" boolean DEFAULT false NOT NULL,
    "notes" "text",
    "updated_by" "uuid",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."jurisdiction_policy" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."legal_holds" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "doc_id" "uuid" NOT NULL,
    "reason" "text" NOT NULL,
    "placed_by" "uuid" NOT NULL,
    "placed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "released_at" timestamp with time zone,
    "released_by" "uuid"
);


ALTER TABLE "public"."legal_holds" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."mfa_recovery_attempts" (
    "user_id" "uuid" NOT NULL,
    "failed_count" integer DEFAULT 0 NOT NULL,
    "locked_until" timestamp with time zone,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."mfa_recovery_attempts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."normalized_assets" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "estate_id" "uuid" NOT NULL,
    "connection_id" "uuid" NOT NULL,
    "institution_name" "text",
    "provider_name" "text",
    "asset_group" "text" NOT NULL,
    "asset_category" "text",
    "asset_subtype" "text",
    "source_type" "text" DEFAULT 'aggregator'::"text" NOT NULL,
    "masked_identifier" "text",
    "balance_cents" bigint DEFAULT 0 NOT NULL,
    "currency" "text" DEFAULT 'USD'::"text" NOT NULL,
    "holdings" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "refresh_timestamp" timestamp with time zone,
    "last_sync_status" "text" DEFAULT 'live_connected'::"text" NOT NULL,
    "confidence_level" "text" DEFAULT 'high'::"text" NOT NULL,
    "verification_status" "text" DEFAULT 'verified'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."normalized_assets" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."notifications" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "estate_id" "uuid",
    "kind" "text" NOT NULL,
    "title" "text" NOT NULL,
    "body" "text",
    "read" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "channel" "text" DEFAULT 'inApp'::"text" NOT NULL,
    "action_deep_link" "text",
    "related_document_id" "uuid",
    "payload" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL
);


ALTER TABLE "public"."notifications" OWNER TO "postgres";


COMMENT ON TABLE "public"."notifications" IS 'Self-scoped notification store. Rows are written ONLY by SECURITY DEFINER emitters — authenticated holds no INSERT grant and, since 0050, no EXECUTE on emit_notification either. Lifecycle copy is a constant looked up by event name in notification_event_copy; no emitter composes or interpolates text.';



CREATE TABLE IF NOT EXISTS "public"."outbox_purge_audit" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "outbox_name" "text" NOT NULL,
    "purged_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "actor_id" "uuid",
    "row_count" integer NOT NULL,
    "oldest_row_at" timestamp with time zone,
    "newest_row_at" timestamp with time zone,
    "reason" "text" NOT NULL
);


ALTER TABLE "public"."outbox_purge_audit" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."owner_notice_outbox" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "estate_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "channel" "text" DEFAULT 'email'::"text" NOT NULL,
    "recipient" "text" NOT NULL,
    "notice_kind" "text" NOT NULL,
    "status" "text" DEFAULT 'queued'::"text" NOT NULL,
    "requested_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "dispatched_at" timestamp with time zone,
    "attempts" integer DEFAULT 0 NOT NULL,
    "next_attempt_at" timestamp with time zone,
    "failure_class" "text",
    "purge_audit_id" "uuid",
    "claimed_at" timestamp with time zone,
    "notice_accepted_at" timestamp with time zone,
    "case_id" "uuid",
    "generation" integer DEFAULT 1 NOT NULL,
    "superseded_by" "uuid",
    "reissue_reason" "text",
    "reissued_by" "uuid",
    CONSTRAINT "owner_notice_outbox_channel_check" CHECK (("channel" = 'email'::"text")),
    CONSTRAINT "owner_notice_outbox_notice_kind_check" CHECK (("notice_kind" = ANY (ARRAY['death_process.window_opened'::"text", 'death_process.window_renotice'::"text"]))),
    CONSTRAINT "owner_notice_outbox_reissue_pairing" CHECK (((("generation" = 1) AND ("reissue_reason" IS NULL)) OR (("generation" > 1) AND ("reissue_reason" IS NOT NULL)))),
    CONSTRAINT "owner_notice_outbox_reissue_reason_check" CHECK ((("reissue_reason" IS NULL) OR ("reissue_reason" = ANY (ARRAY['prior_failed_permanent'::"text", 'prior_stale_beyond_age_gate'::"text", 'prior_outcome_uncertain'::"text", 'legacy_no_acceptance_record'::"text"])))),
    CONSTRAINT "owner_notice_outbox_status_check" CHECK (("status" = ANY (ARRAY['queued'::"text", 'processing'::"text", 'dispatched'::"text", 'outcomeUncertain'::"text", 'failedPermanent'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."owner_notice_outbox" OWNER TO "postgres";


COMMENT ON COLUMN "public"."owner_notice_outbox"."notice_kind" IS 'Which owner-safety event this row carries (Phase 11-OC). `death_process.window_opened` is the INITIAL dispatch, written once per episode by dispatch_owner_safety_notice. `death_process.window_renotice` is a deliberate operator re-issue (Phase C) and is never written by the drain, the settle path or the stale sweep. Both kinds belong to the SAME episode — see owner_notice_episode_kinds() — so the release predicate and the readiness census read the set, never one literal. OPERATOR vocabulary only: the email template takes no kind and cannot tell a recipient which attempt they are receiving.';



COMMENT ON COLUMN "public"."owner_notice_outbox"."status" IS 'queued -> processing -> {dispatched | outcomeUncertain | failedPermanent}, or cancelled. outcomeUncertain (Phase 11-K) means the provider never answered: the message may or may not have been accepted, so the row is TERMINAL — never re-claimed, never re-sent, never purged.';



COMMENT ON COLUMN "public"."owner_notice_outbox"."claimed_at" IS 'When claim_owner_notices last moved this row into `processing` (Phase 11-OBR / OB-1). NULL means never claimed, or claimed before this column existed. It is the ONLY basis for deciding that a claim has gone stale — attempts is a counter with no clock, and requested_at does not move on claim. Never backfilled: a guessed claim time defeats the column.';



COMMENT ON COLUMN "public"."owner_notice_outbox"."notice_accepted_at" IS 'The instant the email provider ACCEPTED this specific message (Phase 11-OC). Written ONLY by record_owner_notice_outcome on the providerAccepted branch, in the same UPDATE as status and dispatched_at. It is NOT delivery: providerAccepted is not delivered, received, opened or viewed, and nothing downstream may rename it. From Phase D this is the ONE fact that makes a release qualify, and the anchor of the challenge window. Never backfilled, never synthesized, never coalesced to dispatched_at or owner_notified_at — authority is decided by SOURCE, and both of those were written by paths that could not have been telling the truth about acceptance.';



COMMENT ON COLUMN "public"."owner_notice_outbox"."case_id" IS 'The death-verification case this notice belongs to (Phase 11-OC) — the EPISODE key. Estate id is insufficient: one estate may legitimately experience several independent death processes over time, and an accepted notice from a prior REJECTED case must never authorize a later one. NULL only on rows written before Phase A; those belong to no episode, satisfy no release predicate, and are remediated by operator re-notice rather than by a backfill.';



COMMENT ON COLUMN "public"."owner_notice_outbox"."generation" IS 'Which attempt this row is within its episode (Phase 11-OC). 1 for an original dispatch; n+1 for a deliberate operator re-notice, computed under the predecessor row lock and never from an unlocked max(). Every pre-Phase-A row is definitionally generation 1 — no re-notice mechanism has ever existed — which is the ONLY backfill in this phase and is vacuous rather than inferred.';



COMMENT ON COLUMN "public"."owner_notice_outbox"."superseded_by" IS 'The successor generation that retired this row (Phase 11-OC). NULL means this is the CURRENT generation of its episode. This is a LOOKUP enforced by a partial unique index, deliberately not a derived max(): a derived-max invariant cannot be expressed as a constraint, so the release door would depend on an invariant only the writer maintains, and a concurrent double-reissue would produce two rows that both believe they are latest. A retired row keeps its terminal status and its failure_class — that evidence is why the reissue was warranted — and gains only this pointer.';



COMMENT ON COLUMN "public"."owner_notice_outbox"."reissue_reason" IS 'Why a generation >= 2 exists (Phase 11-OC), from a closed four-value vocabulary. DERIVED from the predecessor row inside the definer, never a caller parameter: a caller-supplied reason would let an operator relabel an outcomeUncertain reissue as a failed one and skip its acknowledgement.';



COMMENT ON COLUMN "public"."owner_notice_outbox"."reissued_by" IS 'The operator who authorized a re-notice (Phase 11-OC). Derived from auth.uid() inside the definer — the reviewer_a discipline — so the routine has no parameter of this type and nominating somebody else is unwritable rather than merely forbidden.';



CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "email" "text" NOT NULL,
    "full_name" "text",
    "phone" "text",
    "date_of_birth" "date",
    "avatar_url" "text",
    "mfa_enabled" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."recovery_codes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "code_hash" "text" NOT NULL,
    "used_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."recovery_codes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."release_authorizations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "estate_id" "uuid" NOT NULL,
    "case_id" "uuid" NOT NULL,
    "reviewer_a" "uuid" NOT NULL,
    "reviewer_b" "uuid" NOT NULL,
    "verified_at" timestamp with time zone NOT NULL,
    "authorized_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "released_at" timestamp with time zone,
    "audit_reason" "text" NOT NULL,
    CONSTRAINT "release_authorizations_two_person" CHECK (("reviewer_a" <> "reviewer_b"))
);


ALTER TABLE "public"."release_authorizations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."release_safety_policy" (
    "id" boolean DEFAULT true NOT NULL,
    "challenge_window" interval NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "release_safety_policy_id_check" CHECK ("id")
);


ALTER TABLE "public"."release_safety_policy" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."storage_deletion_outbox" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "estate_id" "uuid" NOT NULL,
    "bucket" "text" DEFAULT 'documents'::"text" NOT NULL,
    "object_path" "text" NOT NULL,
    "reason" "text" NOT NULL,
    "requested_by" "uuid" NOT NULL,
    "requested_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "attempts" integer DEFAULT 0 NOT NULL,
    "last_error" "text",
    "purged_at" timestamp with time zone,
    CONSTRAINT "storage_deletion_outbox_reason_check" CHECK (("reason" = ANY (ARRAY['document_deleted'::"text", 'document_replaced'::"text"]))),
    CONSTRAINT "storage_deletion_outbox_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'purged'::"text", 'failed'::"text"])))
);


ALTER TABLE "public"."storage_deletion_outbox" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."taxonomy_version" (
    "id" integer DEFAULT 1 NOT NULL,
    "schema_version" integer DEFAULT 1 NOT NULL,
    "vocabulary_version" integer DEFAULT 1 NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "taxonomy_version_id_check" CHECK (("id" = 1))
);


ALTER TABLE "public"."taxonomy_version" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."upload_policy" (
    "id" integer DEFAULT 1 NOT NULL,
    "max_upload_bytes" bigint NOT NULL,
    "max_files_per_claim" integer NOT NULL,
    "max_aggregate_bytes" bigint NOT NULL,
    "allowed_mime_types" "text"[] NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "upload_policy_id_check" CHECK (("id" = 1))
);


ALTER TABLE "public"."upload_policy" OWNER TO "postgres";


ALTER TABLE ONLY "public"."audit_logs" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."audit_logs_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."access_grants"
    ADD CONSTRAINT "access_grants_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."access_requests"
    ADD CONSTRAINT "access_requests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."admins"
    ADD CONSTRAINT "admins_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."assets"
    ADD CONSTRAINT "assets_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."audit_logs"
    ADD CONSTRAINT "audit_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."beneficiaries"
    ADD CONSTRAINT "beneficiaries_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."claim_packets"
    ADD CONSTRAINT "claim_packets_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."connection_secrets"
    ADD CONSTRAINT "connection_secrets_pkey" PRIMARY KEY ("connection_id");



ALTER TABLE ONLY "public"."connections"
    ADD CONSTRAINT "connections_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."consent_records"
    ADD CONSTRAINT "consent_records_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."death_verification_cases"
    ADD CONSTRAINT "death_verification_cases_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."death_verification_evidence"
    ADD CONSTRAINT "death_verification_evidence_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."document_sensitivity"
    ADD CONSTRAINT "document_sensitivity_pkey" PRIMARY KEY ("value");



ALTER TABLE ONLY "public"."document_subtype"
    ADD CONSTRAINT "document_subtype_pkey" PRIMARY KEY ("subtype");



ALTER TABLE ONLY "public"."document_type"
    ADD CONSTRAINT "document_type_pkey" PRIMARY KEY ("value");



ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."encrypted_instructions"
    ADD CONSTRAINT "encrypted_instructions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."estate_asset_category"
    ADD CONSTRAINT "estate_asset_category_pkey" PRIMARY KEY ("value");



ALTER TABLE ONLY "public"."estate_asset_documents"
    ADD CONSTRAINT "estate_asset_documents_pkey" PRIMARY KEY ("asset_id", "doc_id");



ALTER TABLE ONLY "public"."estate_asset_subtype"
    ADD CONSTRAINT "estate_asset_subtype_pkey" PRIMARY KEY ("subtype");



ALTER TABLE ONLY "public"."estate_assets"
    ADD CONSTRAINT "estate_assets_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."estate_designations"
    ADD CONSTRAINT "estate_designations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."estate_lifecycle"
    ADD CONSTRAINT "estate_lifecycle_pkey" PRIMARY KEY ("estate_id");



ALTER TABLE ONLY "public"."estate_memberships"
    ADD CONSTRAINT "estate_members_estate_id_user_id_key" UNIQUE ("estate_id", "user_id");



ALTER TABLE ONLY "public"."estate_memberships"
    ADD CONSTRAINT "estate_members_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."estates"
    ADD CONSTRAINT "estates_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."invitation_delivery_outbox"
    ADD CONSTRAINT "invitation_delivery_outbox_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."invitations"
    ADD CONSTRAINT "invitations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."jurisdiction_policy"
    ADD CONSTRAINT "jurisdiction_policy_pkey" PRIMARY KEY ("jurisdiction");



ALTER TABLE ONLY "public"."legal_holds"
    ADD CONSTRAINT "legal_holds_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."mfa_recovery_attempts"
    ADD CONSTRAINT "mfa_recovery_attempts_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."normalized_assets"
    ADD CONSTRAINT "normalized_assets_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."outbox_purge_audit"
    ADD CONSTRAINT "outbox_purge_audit_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."owner_notice_outbox"
    ADD CONSTRAINT "owner_notice_outbox_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."recovery_codes"
    ADD CONSTRAINT "recovery_codes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."release_authorizations"
    ADD CONSTRAINT "release_authorizations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."release_safety_policy"
    ADD CONSTRAINT "release_safety_policy_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."storage_deletion_outbox"
    ADD CONSTRAINT "storage_deletion_outbox_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."taxonomy_version"
    ADD CONSTRAINT "taxonomy_version_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."upload_policy"
    ADD CONSTRAINT "upload_policy_pkey" PRIMARY KEY ("id");



CREATE INDEX "access_grants_lookup" ON "public"."access_grants" USING "btree" ("estate_id", "grantee_user_id", "status");



CREATE UNIQUE INDEX "access_grants_uniq_cat" ON "public"."access_grants" USING "btree" ("estate_id", "grantee_user_id", "category") WHERE (("category" IS NOT NULL) AND ("status" = 'active'::"text"));



CREATE UNIQUE INDEX "access_grants_uniq_doc" ON "public"."access_grants" USING "btree" ("estate_id", "grantee_user_id", "document_id") WHERE (("document_id" IS NOT NULL) AND ("status" = 'active'::"text"));



CREATE INDEX "access_requests_estate_status" ON "public"."access_requests" USING "btree" ("estate_id", "status");



CREATE UNIQUE INDEX "access_requests_one_pending" ON "public"."access_requests" USING "btree" ("estate_id", "requester_user_id", "category") WHERE ("status" = 'pending'::"text");



CREATE INDEX "assets_estate_id_idx" ON "public"."assets" USING "btree" ("estate_id");



CREATE INDEX "assets_owner_id_idx" ON "public"."assets" USING "btree" ("owner_id");



CREATE INDEX "audit_logs_actor_id_created_at_idx" ON "public"."audit_logs" USING "btree" ("actor_id", "created_at" DESC);



CREATE INDEX "audit_logs_created_at_id_idx" ON "public"."audit_logs" USING "btree" ("created_at" DESC, "id" DESC);



CREATE INDEX "audit_logs_estate_id_created_at_idx" ON "public"."audit_logs" USING "btree" ("estate_id", "created_at" DESC);



CREATE INDEX "audit_logs_source_created_at_idx" ON "public"."audit_logs" USING "btree" ("source", "created_at" DESC);



CREATE INDEX "beneficiaries_estate_id_idx" ON "public"."beneficiaries" USING "btree" ("estate_id");



CREATE INDEX "claim_packets_estate_id_idx" ON "public"."claim_packets" USING "btree" ("estate_id");



CREATE UNIQUE INDEX "claim_packets_one_active_per_estate" ON "public"."claim_packets" USING "btree" ("estate_id") WHERE ("status" <> 'rejected'::"text");



CREATE INDEX "connections_estate_idx" ON "public"."connections" USING "btree" ("estate_id");



CREATE INDEX "consent_records_user_type_version_idx" ON "public"."consent_records" USING "btree" ("user_id", "consent_type", "document_version");



CREATE INDEX "death_verification_cases_estate_idx" ON "public"."death_verification_cases" USING "btree" ("estate_id");



CREATE UNIQUE INDEX "death_verification_cases_one_open_per_estate" ON "public"."death_verification_cases" USING "btree" ("estate_id") WHERE ("status" = 'open'::"text");



CREATE INDEX "death_verification_evidence_case_idx" ON "public"."death_verification_evidence" USING "btree" ("case_id");



CREATE INDEX "death_verification_evidence_document_idx" ON "public"."death_verification_evidence" USING "btree" ("document_id");



CREATE INDEX "documents_estate_id_idx" ON "public"."documents" USING "btree" ("estate_id");



CREATE INDEX "encrypted_instructions_estate_id_idx" ON "public"."encrypted_instructions" USING "btree" ("estate_id");



CREATE INDEX "estate_asset_documents_doc_idx" ON "public"."estate_asset_documents" USING "btree" ("doc_id");



CREATE INDEX "estate_asset_subtype_parent_idx" ON "public"."estate_asset_subtype" USING "btree" ("parent_category");



CREATE INDEX "estate_assets_estate_idx" ON "public"."estate_assets" USING "btree" ("estate_id");



CREATE INDEX "estate_assets_live_idx" ON "public"."estate_assets" USING "btree" ("estate_id", "created_at" DESC) WHERE ("archived_at" IS NULL);



CREATE INDEX "estate_designations_estate_type_idx" ON "public"."estate_designations" USING "btree" ("estate_id", "designation_type");



CREATE UNIQUE INDEX "estate_designations_one_active" ON "public"."estate_designations" USING "btree" ("estate_id", "user_id", "designation_type") WHERE ("status" = 'active'::"text");



CREATE INDEX "estate_designations_user_idx" ON "public"."estate_designations" USING "btree" ("user_id");



CREATE INDEX "estate_members_estate_id_idx" ON "public"."estate_memberships" USING "btree" ("estate_id");



CREATE INDEX "estate_members_user_id_idx" ON "public"."estate_memberships" USING "btree" ("user_id");



CREATE UNIQUE INDEX "estate_memberships_one_primary_user_per_estate" ON "public"."estate_memberships" USING "btree" ("estate_id") WHERE (("role" = 'primary_user'::"text") AND ("status" = 'approved'::"text"));



CREATE INDEX "estate_memberships_source_invitation_idx" ON "public"."estate_memberships" USING "btree" ("source_invitation_id") WHERE ("source_invitation_id" IS NOT NULL);



CREATE INDEX "estates_owner_id_idx" ON "public"."estates" USING "btree" ("owner_id");



CREATE UNIQUE INDEX "estates_primary_per_owner_idx" ON "public"."estates" USING "btree" ("owner_id") WHERE ("is_primary" = true);



CREATE INDEX "invitation_delivery_outbox_claimable_idx" ON "public"."invitation_delivery_outbox" USING "btree" ("requested_at") WHERE ("status" = ANY (ARRAY['queued'::"text", 'retryPending'::"text"]));



CREATE INDEX "invitation_delivery_outbox_invitation_idx" ON "public"."invitation_delivery_outbox" USING "btree" ("invitation_id", "requested_at" DESC);



CREATE INDEX "invitation_delivery_outbox_unissued_idx" ON "public"."invitation_delivery_outbox" USING "btree" ("requested_at") WHERE ("status" = 'pending'::"text");



CREATE INDEX "invitations_email_idx" ON "public"."invitations" USING "btree" ("lower"("invitee_email")) WHERE ("invitee_email" IS NOT NULL);



CREATE INDEX "invitations_estate_id_idx" ON "public"."invitations" USING "btree" ("estate_id");



CREATE UNIQUE INDEX "invitations_one_active_per_phone_role" ON "public"."invitations" USING "btree" ("estate_id", "invitee_phone", "proposed_role") WHERE (("status" = ANY (ARRAY['pending'::"text", 'matched'::"text"])) AND ("invitee_phone" IS NOT NULL));



CREATE UNIQUE INDEX "invitations_one_active_per_recipient_role" ON "public"."invitations" USING "btree" ("estate_id", "lower"("invitee_email"), "proposed_role") WHERE (("status" = ANY (ARRAY['pending'::"text", 'matched'::"text"])) AND ("invitee_email" IS NOT NULL));



CREATE INDEX "invitations_phone_idx" ON "public"."invitations" USING "btree" ("invitee_phone") WHERE ("invitee_phone" IS NOT NULL);



CREATE INDEX "invitations_status_idx" ON "public"."invitations" USING "btree" ("status");



CREATE INDEX "invitations_token_hash_idx" ON "public"."invitations" USING "btree" ("token_hash");



CREATE INDEX "legal_holds_active_idx" ON "public"."legal_holds" USING "btree" ("doc_id") WHERE ("released_at" IS NULL);



CREATE INDEX "normalized_assets_connection_idx" ON "public"."normalized_assets" USING "btree" ("connection_id");



CREATE INDEX "normalized_assets_estate_idx" ON "public"."normalized_assets" USING "btree" ("estate_id");



CREATE INDEX "notifications_recipient_idx" ON "public"."notifications" USING "btree" ("user_id", "created_at" DESC);



CREATE INDEX "notifications_unread_idx" ON "public"."notifications" USING "btree" ("user_id") WHERE ("read" = false);



CREATE INDEX "notifications_user_id_read_idx" ON "public"."notifications" USING "btree" ("user_id", "read");



CREATE INDEX "owner_notice_outbox_case_idx" ON "public"."owner_notice_outbox" USING "btree" ("case_id");



CREATE INDEX "owner_notice_outbox_claimable_idx" ON "public"."owner_notice_outbox" USING "btree" ("requested_at") WHERE ("status" = ANY (ARRAY['queued'::"text", 'processing'::"text"]));



CREATE INDEX "owner_notice_outbox_estate_idx" ON "public"."owner_notice_outbox" USING "btree" ("estate_id");



CREATE UNIQUE INDEX "owner_notice_outbox_one_current_per_episode_idx" ON "public"."owner_notice_outbox" USING "btree" ("case_id", "channel") WHERE ("superseded_by" IS NULL);



COMMENT ON INDEX "public"."owner_notice_outbox_one_current_per_episode_idx" IS 'Exactly ONE current generation per episode (Phase 11-OC / Phase C). Replaces the Phase A index on (case_id, channel, notice_kind), which became insufficient the moment an episode could hold two kinds: it would have permitted one current window_opened row AND one current window_renotice row for the same case — two live generations. Strictly stronger than its predecessor and lossless on every extant row, because notice_kind admitted one value until this migration. Legacy rows carry a NULL case_id and NULLs are distinct in a unique index, so they neither collide nor are blocked.';



CREATE INDEX "owner_notice_outbox_processing_claimed_idx" ON "public"."owner_notice_outbox" USING "btree" ("requested_at") WHERE ("status" = 'processing'::"text");



CREATE INDEX "recovery_codes_user_unused_idx" ON "public"."recovery_codes" USING "btree" ("user_id") WHERE ("used_at" IS NULL);



CREATE UNIQUE INDEX "release_authorizations_one_per_estate" ON "public"."release_authorizations" USING "btree" ("estate_id");



CREATE INDEX "storage_deletion_outbox_unpurged_idx" ON "public"."storage_deletion_outbox" USING "btree" ("requested_at") WHERE ("status" <> 'purged'::"text");



CREATE OR REPLACE TRIGGER "access_grants_ceiling" BEFORE INSERT OR UPDATE ON "public"."access_grants" FOR EACH ROW EXECUTE FUNCTION "public"."enforce_grant_ceiling"();



CREATE OR REPLACE TRIGGER "document_sensitivity_taxonomy_bump" AFTER INSERT OR DELETE OR UPDATE ON "public"."document_sensitivity" FOR EACH STATEMENT EXECUTE FUNCTION "public"."bump_taxonomy_vocabulary_version"();



CREATE OR REPLACE TRIGGER "document_subtype_taxonomy_bump" AFTER INSERT OR DELETE OR UPDATE ON "public"."document_subtype" FOR EACH STATEMENT EXECUTE FUNCTION "public"."bump_taxonomy_vocabulary_version"();



CREATE OR REPLACE TRIGGER "document_type_taxonomy_bump" AFTER INSERT OR DELETE OR UPDATE ON "public"."document_type" FOR EACH STATEMENT EXECUTE FUNCTION "public"."bump_taxonomy_vocabulary_version"();



CREATE OR REPLACE TRIGGER "estate_asset_category_taxonomy_bump" AFTER INSERT OR DELETE OR UPDATE ON "public"."estate_asset_category" FOR EACH STATEMENT EXECUTE FUNCTION "public"."bump_taxonomy_vocabulary_version"();



CREATE OR REPLACE TRIGGER "estate_asset_subtype_taxonomy_bump" AFTER INSERT OR DELETE OR UPDATE ON "public"."estate_asset_subtype" FOR EACH STATEMENT EXECUTE FUNCTION "public"."bump_taxonomy_vocabulary_version"();



CREATE OR REPLACE TRIGGER "estate_memberships_check_primary_user" BEFORE INSERT OR UPDATE ON "public"."estate_memberships" FOR EACH ROW EXECUTE FUNCTION "public"."check_primary_user_matches_owner"();



CREATE OR REPLACE TRIGGER "estates_ensure_primary_user_membership" AFTER INSERT ON "public"."estates" FOR EACH ROW EXECUTE FUNCTION "public"."ensure_primary_user_membership"();



CREATE OR REPLACE TRIGGER "owner_notice_outbox_require_episode" BEFORE INSERT ON "public"."owner_notice_outbox" FOR EACH ROW EXECUTE FUNCTION "public"."owner_notice_require_episode"();



ALTER TABLE ONLY "public"."access_grants"
    ADD CONSTRAINT "access_grants_document_id_fkey" FOREIGN KEY ("document_id") REFERENCES "public"."documents"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."admins"
    ADD CONSTRAINT "admins_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."assets"
    ADD CONSTRAINT "assets_estate_id_fkey" FOREIGN KEY ("estate_id") REFERENCES "public"."estates"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."assets"
    ADD CONSTRAINT "assets_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."audit_logs"
    ADD CONSTRAINT "audit_logs_actor_id_fkey" FOREIGN KEY ("actor_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."beneficiaries"
    ADD CONSTRAINT "beneficiaries_estate_id_fkey" FOREIGN KEY ("estate_id") REFERENCES "public"."estates"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."beneficiaries"
    ADD CONSTRAINT "beneficiaries_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."claim_packets"
    ADD CONSTRAINT "claim_packets_death_certificate_doc_id_fkey" FOREIGN KEY ("death_certificate_doc_id") REFERENCES "public"."documents"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."claim_packets"
    ADD CONSTRAINT "claim_packets_estate_id_fkey" FOREIGN KEY ("estate_id") REFERENCES "public"."estates"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."claim_packets"
    ADD CONSTRAINT "claim_packets_executor_id_doc_id_fkey" FOREIGN KEY ("executor_id_doc_id") REFERENCES "public"."documents"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."claim_packets"
    ADD CONSTRAINT "claim_packets_requested_by_fkey" FOREIGN KEY ("requested_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."claim_packets"
    ADD CONSTRAINT "claim_packets_reviewer_id_fkey" FOREIGN KEY ("reviewer_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."connection_secrets"
    ADD CONSTRAINT "connection_secrets_connection_id_fkey" FOREIGN KEY ("connection_id") REFERENCES "public"."connections"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."connections"
    ADD CONSTRAINT "connections_estate_id_fkey" FOREIGN KEY ("estate_id") REFERENCES "public"."estates"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."consent_records"
    ADD CONSTRAINT "consent_records_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."death_verification_cases"
    ADD CONSTRAINT "death_verification_cases_decided_by_fkey" FOREIGN KEY ("decided_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."death_verification_cases"
    ADD CONSTRAINT "death_verification_cases_estate_id_fkey" FOREIGN KEY ("estate_id") REFERENCES "public"."estates"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."death_verification_cases"
    ADD CONSTRAINT "death_verification_cases_initiated_by_fkey" FOREIGN KEY ("initiated_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."death_verification_cases"
    ADD CONSTRAINT "death_verification_cases_initiator_designation_id_fkey" FOREIGN KEY ("initiator_designation_id") REFERENCES "public"."estate_designations"("id");



ALTER TABLE ONLY "public"."death_verification_evidence"
    ADD CONSTRAINT "death_verification_evidence_case_id_fkey" FOREIGN KEY ("case_id") REFERENCES "public"."death_verification_cases"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."death_verification_evidence"
    ADD CONSTRAINT "death_verification_evidence_document_id_fkey" FOREIGN KEY ("document_id") REFERENCES "public"."documents"("id");



ALTER TABLE ONLY "public"."death_verification_evidence"
    ADD CONSTRAINT "death_verification_evidence_estate_id_fkey" FOREIGN KEY ("estate_id") REFERENCES "public"."estates"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."death_verification_evidence"
    ADD CONSTRAINT "death_verification_evidence_reviewed_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."death_verification_evidence"
    ADD CONSTRAINT "death_verification_evidence_submitted_by_fkey" FOREIGN KEY ("submitted_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."document_subtype"
    ADD CONSTRAINT "document_subtype_parent_doc_type_fkey" FOREIGN KEY ("parent_doc_type") REFERENCES "public"."document_type"("value");



ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_doc_subtype_fkey" FOREIGN KEY ("doc_subtype") REFERENCES "public"."document_subtype"("subtype");



ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_doc_type_fkey" FOREIGN KEY ("doc_type") REFERENCES "public"."document_type"("value");



ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_estate_id_fkey" FOREIGN KEY ("estate_id") REFERENCES "public"."estates"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."documents"
    ADD CONSTRAINT "documents_sensitivity_fkey" FOREIGN KEY ("sensitivity") REFERENCES "public"."document_sensitivity"("value");



ALTER TABLE ONLY "public"."encrypted_instructions"
    ADD CONSTRAINT "encrypted_instructions_estate_id_fkey" FOREIGN KEY ("estate_id") REFERENCES "public"."estates"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."encrypted_instructions"
    ADD CONSTRAINT "encrypted_instructions_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."estate_asset_documents"
    ADD CONSTRAINT "estate_asset_documents_asset_id_fkey" FOREIGN KEY ("asset_id") REFERENCES "public"."estate_assets"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."estate_asset_documents"
    ADD CONSTRAINT "estate_asset_documents_doc_id_fkey" FOREIGN KEY ("doc_id") REFERENCES "public"."documents"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."estate_asset_documents"
    ADD CONSTRAINT "estate_asset_documents_linked_by_fkey" FOREIGN KEY ("linked_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."estate_asset_subtype"
    ADD CONSTRAINT "estate_asset_subtype_parent_category_fkey" FOREIGN KEY ("parent_category") REFERENCES "public"."estate_asset_category"("value");



ALTER TABLE ONLY "public"."estate_assets"
    ADD CONSTRAINT "estate_assets_archived_by_fkey" FOREIGN KEY ("archived_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."estate_assets"
    ADD CONSTRAINT "estate_assets_category_fkey" FOREIGN KEY ("category") REFERENCES "public"."estate_asset_category"("value");



ALTER TABLE ONLY "public"."estate_assets"
    ADD CONSTRAINT "estate_assets_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."estate_assets"
    ADD CONSTRAINT "estate_assets_estate_id_fkey" FOREIGN KEY ("estate_id") REFERENCES "public"."estates"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."estate_assets"
    ADD CONSTRAINT "estate_assets_sensitivity_fkey" FOREIGN KEY ("sensitivity") REFERENCES "public"."document_sensitivity"("value");



ALTER TABLE ONLY "public"."estate_assets"
    ADD CONSTRAINT "estate_assets_subtype_fkey" FOREIGN KEY ("subtype") REFERENCES "public"."estate_asset_subtype"("subtype");



ALTER TABLE ONLY "public"."estate_designations"
    ADD CONSTRAINT "estate_designations_estate_id_fkey" FOREIGN KEY ("estate_id") REFERENCES "public"."estates"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."estate_designations"
    ADD CONSTRAINT "estate_designations_granted_by_fkey" FOREIGN KEY ("granted_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."estate_designations"
    ADD CONSTRAINT "estate_designations_source_invitation_id_fkey" FOREIGN KEY ("source_invitation_id") REFERENCES "public"."invitations"("id");



ALTER TABLE ONLY "public"."estate_designations"
    ADD CONSTRAINT "estate_designations_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."estate_lifecycle"
    ADD CONSTRAINT "estate_lifecycle_estate_id_fkey" FOREIGN KEY ("estate_id") REFERENCES "public"."estates"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."estate_lifecycle"
    ADD CONSTRAINT "estate_lifecycle_updated_case_id_fkey" FOREIGN KEY ("updated_case_id") REFERENCES "public"."death_verification_cases"("id");



ALTER TABLE ONLY "public"."estate_memberships"
    ADD CONSTRAINT "estate_members_estate_id_fkey" FOREIGN KEY ("estate_id") REFERENCES "public"."estates"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."estate_memberships"
    ADD CONSTRAINT "estate_members_invited_by_fkey" FOREIGN KEY ("invited_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."estate_memberships"
    ADD CONSTRAINT "estate_members_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."estate_memberships"
    ADD CONSTRAINT "estate_memberships_source_invitation_id_fkey" FOREIGN KEY ("source_invitation_id") REFERENCES "public"."invitations"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."estates"
    ADD CONSTRAINT "estates_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."invitation_delivery_outbox"
    ADD CONSTRAINT "invitation_delivery_outbox_estate_id_fkey" FOREIGN KEY ("estate_id") REFERENCES "public"."estates"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."invitation_delivery_outbox"
    ADD CONSTRAINT "invitation_delivery_outbox_invitation_id_fkey" FOREIGN KEY ("invitation_id") REFERENCES "public"."invitations"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."invitation_delivery_outbox"
    ADD CONSTRAINT "invitation_delivery_outbox_requested_by_fkey" FOREIGN KEY ("requested_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."invitations"
    ADD CONSTRAINT "invitations_accepted_by_fkey" FOREIGN KEY ("accepted_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."invitations"
    ADD CONSTRAINT "invitations_estate_id_fkey" FOREIGN KEY ("estate_id") REFERENCES "public"."estates"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."invitations"
    ADD CONSTRAINT "invitations_extended_by_fkey" FOREIGN KEY ("extended_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."invitations"
    ADD CONSTRAINT "invitations_invited_by_fkey" FOREIGN KEY ("invited_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."invitations"
    ADD CONSTRAINT "invitations_revoked_by_fkey" FOREIGN KEY ("revoked_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."jurisdiction_policy"
    ADD CONSTRAINT "jurisdiction_policy_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."legal_holds"
    ADD CONSTRAINT "legal_holds_doc_id_fkey" FOREIGN KEY ("doc_id") REFERENCES "public"."documents"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."legal_holds"
    ADD CONSTRAINT "legal_holds_placed_by_fkey" FOREIGN KEY ("placed_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."legal_holds"
    ADD CONSTRAINT "legal_holds_released_by_fkey" FOREIGN KEY ("released_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."mfa_recovery_attempts"
    ADD CONSTRAINT "mfa_recovery_attempts_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."normalized_assets"
    ADD CONSTRAINT "normalized_assets_connection_id_fkey" FOREIGN KEY ("connection_id") REFERENCES "public"."connections"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."normalized_assets"
    ADD CONSTRAINT "normalized_assets_estate_id_fkey" FOREIGN KEY ("estate_id") REFERENCES "public"."estates"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_estate_id_fkey" FOREIGN KEY ("estate_id") REFERENCES "public"."estates"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."owner_notice_outbox"
    ADD CONSTRAINT "owner_notice_outbox_case_fk" FOREIGN KEY ("case_id") REFERENCES "public"."death_verification_cases"("id");



ALTER TABLE ONLY "public"."owner_notice_outbox"
    ADD CONSTRAINT "owner_notice_outbox_estate_id_fkey" FOREIGN KEY ("estate_id") REFERENCES "public"."estates"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."owner_notice_outbox"
    ADD CONSTRAINT "owner_notice_outbox_reissued_by_fk" FOREIGN KEY ("reissued_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."owner_notice_outbox"
    ADD CONSTRAINT "owner_notice_outbox_superseded_fk" FOREIGN KEY ("superseded_by") REFERENCES "public"."owner_notice_outbox"("id") ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED;



ALTER TABLE ONLY "public"."owner_notice_outbox"
    ADD CONSTRAINT "owner_notice_outbox_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."recovery_codes"
    ADD CONSTRAINT "recovery_codes_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."release_authorizations"
    ADD CONSTRAINT "release_authorizations_case_id_fkey" FOREIGN KEY ("case_id") REFERENCES "public"."death_verification_cases"("id");



ALTER TABLE ONLY "public"."release_authorizations"
    ADD CONSTRAINT "release_authorizations_estate_id_fkey" FOREIGN KEY ("estate_id") REFERENCES "public"."estates"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."release_authorizations"
    ADD CONSTRAINT "release_authorizations_reviewer_a_fkey" FOREIGN KEY ("reviewer_a") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."release_authorizations"
    ADD CONSTRAINT "release_authorizations_reviewer_b_fkey" FOREIGN KEY ("reviewer_b") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."storage_deletion_outbox"
    ADD CONSTRAINT "storage_deletion_outbox_estate_id_fkey" FOREIGN KEY ("estate_id") REFERENCES "public"."estates"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."storage_deletion_outbox"
    ADD CONSTRAINT "storage_deletion_outbox_requested_by_fkey" FOREIGN KEY ("requested_by") REFERENCES "auth"."users"("id");



ALTER TABLE "public"."access_grants" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "access_grants_insert" ON "public"."access_grants" FOR INSERT TO "authenticated" WITH CHECK (("public"."is_estate_owner"("estate_id") AND ("granted_by_user_id" = "auth"."uid"())));



CREATE POLICY "access_grants_read" ON "public"."access_grants" FOR SELECT TO "authenticated" USING ((("granted_by_user_id" = "auth"."uid"()) OR ("grantee_user_id" = "auth"."uid"()) OR "public"."is_estate_owner"("estate_id")));



CREATE POLICY "access_grants_update" ON "public"."access_grants" FOR UPDATE TO "authenticated" USING ("public"."is_estate_owner"("estate_id")) WITH CHECK ("public"."is_estate_owner"("estate_id"));



ALTER TABLE "public"."access_requests" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "access_requests_select" ON "public"."access_requests" FOR SELECT TO "authenticated" USING ((("requester_user_id" = "auth"."uid"()) OR "public"."is_estate_owner"("estate_id")));



ALTER TABLE "public"."admins" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."assets" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "assets_read" ON "public"."assets" FOR SELECT USING ((("owner_id" = "auth"."uid"()) OR "public"."is_estate_member"("estate_id")));



CREATE POLICY "assets_write" ON "public"."assets" USING (("owner_id" = "auth"."uid"())) WITH CHECK (("owner_id" = "auth"."uid"()));



ALTER TABLE "public"."audit_logs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "audit_read_own" ON "public"."audit_logs" FOR SELECT USING (("actor_id" = "auth"."uid"()));



ALTER TABLE "public"."beneficiaries" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "beneficiaries_read" ON "public"."beneficiaries" FOR SELECT USING ((("owner_id" = "auth"."uid"()) OR ("user_id" = "auth"."uid"()) OR "public"."is_estate_owner"("estate_id")));



CREATE POLICY "beneficiaries_write" ON "public"."beneficiaries" USING (("owner_id" = "auth"."uid"())) WITH CHECK (("owner_id" = "auth"."uid"()));



CREATE POLICY "claim_own_read" ON "public"."claim_packets" FOR SELECT USING (("requested_by" = "auth"."uid"()));



ALTER TABLE "public"."claim_packets" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."connection_secrets" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."connections" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "connections_require_aal2" ON "public"."connections" AS RESTRICTIVE USING ((COALESCE(("auth"."jwt"() ->> 'aal'::"text"), 'aal1'::"text") = 'aal2'::"text")) WITH CHECK ((COALESCE(("auth"."jwt"() ->> 'aal'::"text"), 'aal1'::"text") = 'aal2'::"text"));



CREATE POLICY "connections_select_owner" ON "public"."connections" FOR SELECT USING (("public"."is_estate_owner"("estate_id") AND (COALESCE(("auth"."jwt"() ->> 'aal'::"text"), 'aal1'::"text") = 'aal2'::"text")));



CREATE POLICY "consent_own_read" ON "public"."consent_records" FOR SELECT USING (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."consent_records" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."death_verification_cases" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."death_verification_evidence" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."document_sensitivity" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."document_subtype" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."document_type" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."documents" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "documents_read" ON "public"."documents" FOR SELECT TO "authenticated" USING (("public"."is_estate_owner"("estate_id") OR "public"."can_access_document"("id")));



ALTER TABLE "public"."encrypted_instructions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."estate_asset_category" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."estate_asset_documents" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "estate_asset_documents_read" ON "public"."estate_asset_documents" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."estate_assets" "a"
  WHERE (("a"."id" = "estate_asset_documents"."asset_id") AND "public"."is_estate_owner"("a"."estate_id")))));



ALTER TABLE "public"."estate_asset_subtype" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."estate_assets" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "estate_assets_read_owner" ON "public"."estate_assets" FOR SELECT TO "authenticated" USING ("public"."is_estate_owner"("estate_id"));



ALTER TABLE "public"."estate_designations" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "estate_designations_designee_read" ON "public"."estate_designations" FOR SELECT USING (("user_id" = "auth"."uid"()));



CREATE POLICY "estate_designations_owner_all" ON "public"."estate_designations" USING ("public"."is_estate_owner"("estate_id")) WITH CHECK ("public"."is_estate_owner"("estate_id"));



ALTER TABLE "public"."estate_lifecycle" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."estate_memberships" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."estates" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "estates_member_read" ON "public"."estates" FOR SELECT USING ("public"."is_estate_member"("id"));



CREATE POLICY "estates_owner_all" ON "public"."estates" USING (("owner_id" = "auth"."uid"())) WITH CHECK (("owner_id" = "auth"."uid"()));



CREATE POLICY "instructions_executor_read_after_release" ON "public"."encrypted_instructions" FOR SELECT USING ((("released" = true) AND "public"."is_estate_executor"("estate_id", "auth"."uid"())));



CREATE POLICY "instructions_owner_all" ON "public"."encrypted_instructions" USING (("owner_id" = "auth"."uid"())) WITH CHECK (("owner_id" = "auth"."uid"()));



ALTER TABLE "public"."invitation_delivery_outbox" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."invitations" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "invitations_invitee_read" ON "public"."invitations" FOR SELECT USING ((("status" = ANY (ARRAY['pending'::"text", 'matched'::"text"])) AND ("expires_at" > "now"()) AND (("invitee_email" = ( SELECT "profiles"."email"
   FROM "public"."profiles"
  WHERE ("profiles"."id" = "auth"."uid"()))) OR ("invitee_phone" = ( SELECT "profiles"."phone"
   FROM "public"."profiles"
  WHERE ("profiles"."id" = "auth"."uid"()))))));



CREATE POLICY "invitations_member_read" ON "public"."invitations" FOR SELECT USING ("public"."is_estate_member"("estate_id"));



CREATE POLICY "invitations_owner_manage" ON "public"."invitations" USING ("public"."is_estate_owner"("estate_id")) WITH CHECK ("public"."is_estate_owner"("estate_id"));



ALTER TABLE "public"."jurisdiction_policy" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."legal_holds" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "members_owner_manage" ON "public"."estate_memberships" USING ("public"."is_estate_owner"("estate_id")) WITH CHECK ("public"."is_estate_owner"("estate_id"));



CREATE POLICY "members_self_read" ON "public"."estate_memberships" FOR SELECT USING (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."mfa_recovery_attempts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."normalized_assets" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "normalized_assets_owner_all" ON "public"."normalized_assets" USING (("public"."is_estate_owner"("estate_id") AND (COALESCE(("auth"."jwt"() ->> 'aal'::"text"), 'aal1'::"text") = 'aal2'::"text"))) WITH CHECK (("public"."is_estate_owner"("estate_id") AND (COALESCE(("auth"."jwt"() ->> 'aal'::"text"), 'aal1'::"text") = 'aal2'::"text")));



CREATE POLICY "normalized_assets_require_aal2" ON "public"."normalized_assets" AS RESTRICTIVE USING ((COALESCE(("auth"."jwt"() ->> 'aal'::"text"), 'aal1'::"text") = 'aal2'::"text")) WITH CHECK ((COALESCE(("auth"."jwt"() ->> 'aal'::"text"), 'aal1'::"text") = 'aal2'::"text"));



ALTER TABLE "public"."notifications" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "notifications_select_self" ON "public"."notifications" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "notifications_self" ON "public"."notifications" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "notifications_update_self" ON "public"."notifications" FOR UPDATE TO "authenticated" USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."outbox_purge_audit" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."owner_notice_outbox" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "profiles_self_insert" ON "public"."profiles" FOR INSERT WITH CHECK (("id" = "auth"."uid"()));



CREATE POLICY "profiles_self_read" ON "public"."profiles" FOR SELECT USING (("id" = "auth"."uid"()));



CREATE POLICY "profiles_self_update" ON "public"."profiles" FOR UPDATE USING (("id" = "auth"."uid"()));



ALTER TABLE "public"."recovery_codes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "recovery_codes_select_own" ON "public"."recovery_codes" FOR SELECT USING (("user_id" = "auth"."uid"()));



ALTER TABLE "public"."release_authorizations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."release_safety_policy" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."storage_deletion_outbox" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."taxonomy_version" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."upload_policy" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";






















































































































































REVOKE ALL ON FUNCTION "public"."admin_authorize_claim_evidence"("p_claim" "uuid", "p_slot" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_authorize_claim_evidence"("p_claim" "uuid", "p_slot" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."admin_create_executor_invitation"("p_estate" "uuid", "p_kind" "text", "p_invitee_email" "text", "p_invitee_phone" "text", "p_reason" "text", "p_case_ref" "text", "p_expires_in_days" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_create_executor_invitation"("p_estate" "uuid", "p_kind" "text", "p_invitee_email" "text", "p_invitee_phone" "text", "p_reason" "text", "p_case_ref" "text", "p_expires_in_days" integer) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."admin_decide_claim_packet"("p_claim_id" "uuid", "p_decision" "text", "p_review_notes" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_decide_claim_packet"("p_claim_id" "uuid", "p_decision" "text", "p_review_notes" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."admin_decide_death_verification_case"("p_case" "uuid", "p_decision" "text", "p_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_decide_death_verification_case"("p_case" "uuid", "p_decision" "text", "p_note" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."admin_get_death_verification_case"("p_case" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_get_death_verification_case"("p_case" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."admin_list_audit"("p_before_created" timestamp with time zone, "p_before_id" bigint, "p_limit" integer, "p_estate" "uuid", "p_actor" "uuid", "p_action" "text", "p_source" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_list_audit"("p_before_created" timestamp with time zone, "p_before_id" bigint, "p_limit" integer, "p_estate" "uuid", "p_actor" "uuid", "p_action" "text", "p_source" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."admin_list_claim_packets"("p_estate" "uuid", "p_status" "text", "p_before_submitted" timestamp with time zone, "p_before_id" "uuid", "p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_list_claim_packets"("p_estate" "uuid", "p_status" "text", "p_before_submitted" timestamp with time zone, "p_before_id" "uuid", "p_limit" integer) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."admin_list_claim_packets_enriched"("p_estate" "uuid", "p_status" "text", "p_before_submitted" timestamp with time zone, "p_before_id" "uuid", "p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_list_claim_packets_enriched"("p_estate" "uuid", "p_status" "text", "p_before_submitted" timestamp with time zone, "p_before_id" "uuid", "p_limit" integer) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."admin_list_death_verification_cases"("p_status" "text", "p_before_initiated" timestamp with time zone, "p_before_id" "uuid", "p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_list_death_verification_cases"("p_status" "text", "p_before_initiated" timestamp with time zone, "p_before_id" "uuid", "p_limit" integer) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."admin_list_jurisdiction_policy"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_list_jurisdiction_policy"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."admin_reconciliation_report"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_reconciliation_report"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."admin_require_gate"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."admin_review_death_evidence"("p_evidence" "uuid", "p_outcome" "text", "p_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_review_death_evidence"("p_evidence" "uuid", "p_outcome" "text", "p_note" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."admin_set_attained_verification_level"("p_case" "uuid", "p_level" "public"."verification_level", "p_basis" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_set_attained_verification_level"("p_case" "uuid", "p_level" "public"."verification_level", "p_basis" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."apply_estate_lifecycle_transition"("p_estate" "uuid", "p_to" "text", "p_case" "uuid", "p_reason" "text") FROM PUBLIC;



GRANT SELECT ON TABLE "public"."access_requests" TO "authenticated";



GRANT SELECT,INSERT,UPDATE ON TABLE "public"."access_grants" TO "authenticated";



REVOKE ALL ON FUNCTION "public"."archive_estate_asset"("p_asset_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."archive_estate_asset"("p_asset_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."assert_not_self_invitee"("p_invitee_email" "text", "p_invitee_phone" "text") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."attach_death_verification_evidence"("p_case" "uuid", "p_document" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."attach_death_verification_evidence"("p_case" "uuid", "p_document" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."authorize_purge"("p_outbox_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."authorize_purge"("p_outbox_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."authorize_release"("p_estate" "uuid", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."authorize_release"("p_estate" "uuid", "p_reason" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."begin_challenge_window"("p_estate" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."begin_challenge_window"("p_estate" "uuid") TO "authenticated";



GRANT ALL ON FUNCTION "public"."bind_invitation_token"("p_token" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."cancel_death_verification_case"("p_case" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."cancel_death_verification_case"("p_case" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."challenge_death_process"("p_estate" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."challenge_death_process"("p_estate" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."challenge_window_duration"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."claim_invitation_deliveries"("p_max" integer, "p_outbox_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."claim_invitation_deliveries"("p_max" integer, "p_outbox_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."claim_owner_notices"("p_max" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."claim_owner_notices"("p_max" integer) TO "service_role";



GRANT SELECT ON TABLE "public"."connections" TO "authenticated";



REVOKE ALL ON FUNCTION "public"."create_estate_asset"("p_estate" "uuid", "p_subtype" "text", "p_label" "text", "p_sensitivity" "text", "p_owner_label" "text", "p_country_code" "text", "p_jurisdiction" "text", "p_institution_name" "text", "p_reference_hint" "text", "p_approximate_value_cents" bigint, "p_currency" "text", "p_notes" "text", "p_beneficiary_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_estate_asset"("p_estate" "uuid", "p_subtype" "text", "p_label" "text", "p_sensitivity" "text", "p_owner_label" "text", "p_country_code" "text", "p_jurisdiction" "text", "p_institution_name" "text", "p_reference_hint" "text", "p_approximate_value_cents" bigint, "p_currency" "text", "p_notes" "text", "p_beneficiary_note" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."create_estate_invitation"("p_estate" "uuid", "p_proposed_role" "text", "p_invitee_email" "text", "p_invitee_phone" "text", "p_show_estate_name" boolean, "p_show_inviter_name" boolean, "p_expires_in_days" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_estate_invitation"("p_estate" "uuid", "p_proposed_role" "text", "p_invitee_email" "text", "p_invitee_phone" "text", "p_show_estate_name" boolean, "p_show_inviter_name" boolean, "p_expires_in_days" integer) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."create_invitation"("p_estate" "uuid", "p_kind" "text", "p_proposed_role" "text", "p_invitee_email" "text", "p_invitee_phone" "text", "p_show_estate_name" boolean, "p_show_inviter_name" boolean, "p_expires_in_days" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_invitation"("p_estate" "uuid", "p_kind" "text", "p_proposed_role" "text", "p_invitee_email" "text", "p_invitee_phone" "text", "p_show_estate_name" boolean, "p_show_inviter_name" boolean, "p_expires_in_days" integer) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."create_vault_document"("p_estate" "uuid", "p_doc_id" "uuid", "p_storage_path" "text", "p_title" "text", "p_doc_subtype" "text", "p_sensitivity" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_vault_document"("p_estate" "uuid", "p_doc_id" "uuid", "p_storage_path" "text", "p_title" "text", "p_doc_subtype" "text", "p_sensitivity" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."delete_vault_document"("p_doc_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."delete_vault_document"("p_doc_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."dispatch_owner_safety_notice"("p_estate" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."dispatch_owner_safety_notice"("p_estate" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."emit_lifecycle_notification"("p_user_id" "uuid", "p_estate_id" "uuid", "p_event" "text", "p_deep_link" "text") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."emit_notification"("p_user_id" "uuid", "p_estate_id" "uuid", "p_category" "text", "p_title" "text", "p_body" "text", "p_deep_link" "text", "p_payload" "jsonb") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."estate_lifecycle_state"("p_estate" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."estate_owner_gate"("p_estate" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."estate_owner_user_id"("p_estate_id" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."estate_release_state"("p_estate" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."extend_estate_invitation"("p_estate" "uuid", "p_invitation" "uuid", "p_expires_in_days" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."extend_estate_invitation"("p_estate" "uuid", "p_invitation" "uuid", "p_expires_in_days" integer) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."extend_invitation"("p_invitation_id" "uuid", "p_expires_in_days" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."extend_invitation"("p_invitation_id" "uuid", "p_expires_in_days" integer) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."forward_client_audit"("p_action" "text", "p_estate" "uuid", "p_table" "text", "p_target" "uuid", "p_meta" "jsonb", "p_client_ts" timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."forward_client_audit"("p_action" "text", "p_estate" "uuid", "p_table" "text", "p_target" "uuid", "p_meta" "jsonb", "p_client_ts" timestamp with time zone) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."get_document_taxonomy"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_document_taxonomy"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."get_estate_asset_taxonomy"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_estate_asset_taxonomy"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."get_estate_discovery"("p_estate" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_estate_discovery"("p_estate" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."get_estate_readiness"("p_estate" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_estate_readiness"("p_estate" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."get_executor_workspace"("p_estate" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_executor_workspace"("p_estate" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."get_my_estate_capability_facts"("p_estate" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_my_estate_capability_facts"("p_estate" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."get_my_estate_designations"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_my_estate_designations"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."get_my_fiduciary_estates"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_my_fiduciary_estates"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."get_owner_safety_status"("p_estate" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_owner_safety_status"("p_estate" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."get_professional_workspace"("p_estate" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_professional_workspace"("p_estate" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."get_upload_policy"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_upload_policy"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."initiate_death_verification_case"("p_estate" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."initiate_death_verification_case"("p_estate" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."inventory_disclosure_tier"("p_estate" "uuid", "p_uid" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."inventory_disclosure_tier"("p_estate" "uuid", "p_uid" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."invitation_delivery_health"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."invitation_delivery_health"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."invitation_effective_status"("p_status" "text", "p_expires_at" timestamp with time zone) FROM PUBLIC;



GRANT ALL ON FUNCTION "public"."invitation_preview"("p_token" "text") TO "anon";



REVOKE ALL ON FUNCTION "public"."invitation_write_gate"("p_estate" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."is_admin"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_admin"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."is_estate_executor"("p_estate" "uuid", "p_user" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."is_estate_executor"("p_estate" "uuid", "p_user" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."issue_invitation_delivery"("p_outbox_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."issue_invitation_delivery"("p_outbox_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."issue_invitation_delivery_notice"("p_outbox_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."issue_invitation_delivery_notice"("p_outbox_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."issue_invitation_delivery_token"("p_outbox_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."issue_invitation_delivery_token"("p_outbox_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."link_asset_document"("p_asset_id" "uuid", "p_doc_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."link_asset_document"("p_asset_id" "uuid", "p_doc_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."list_estate_invitations"("p_estate" "uuid", "p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."list_estate_invitations"("p_estate" "uuid", "p_limit" integer) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."list_orphan_storage_objects"("p_grace_hours" integer, "p_max" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."list_orphan_storage_objects"("p_grace_hours" integer, "p_max" integer) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."notification_estate_home"("p_estate_id" "uuid", "p_user_id" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."owner_notice_age_gate"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."owner_notice_census"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."owner_notice_census"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."owner_notice_claim_visibility"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."owner_notice_episode_kinds"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."owner_notice_reissue_assessment"("p_case" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."owner_notice_reissue_kind"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."owner_notice_release_authority"("p_case" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."owner_notice_release_readiness_census"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."owner_notice_release_readiness_census"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."place_legal_hold"("p_doc_id" "uuid", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."place_legal_hold"("p_doc_id" "uuid", "p_reason" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."preview_required_verification_level"("p_estate" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."preview_required_verification_level"("p_estate" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."provision_from_invitation"("p_invitation_id" "uuid", "p_user" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."purge_outbox_health"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."purge_outbox_health"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."purge_outbox_rows"("p_outbox" "text", "p_before" timestamp with time zone, "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."purge_outbox_rows"("p_outbox" "text", "p_before" timestamp with time zone, "p_reason" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."record_consent"("p_type" "text", "p_version" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."record_consent"("p_type" "text", "p_version" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."record_invitation_delivery_failure"("p_outbox_id" "uuid", "p_error" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."record_invitation_delivery_failure"("p_outbox_id" "uuid", "p_error" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."record_invitation_delivery_outcome"("p_outbox_id" "uuid", "p_delivery_generation" integer, "p_outcome" "text", "p_provider_message_id" "text", "p_failure_class" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."record_invitation_delivery_outcome"("p_outbox_id" "uuid", "p_delivery_generation" integer, "p_outcome" "text", "p_provider_message_id" "text", "p_failure_class" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."record_orphan_sweep"("p_mode" "text", "p_paths" "text"[], "p_grace_hours" integer, "p_batch_cap" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."record_orphan_sweep"("p_mode" "text", "p_paths" "text"[], "p_grace_hours" integer, "p_batch_cap" integer) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."record_owner_notice_outcome"("p_id" "uuid", "p_outcome" "text", "p_failure_class" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."record_owner_notice_outcome"("p_id" "uuid", "p_outcome" "text", "p_failure_class" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."record_purge_result"("p_outbox_id" "uuid", "p_ok" boolean, "p_error" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."record_purge_result"("p_outbox_id" "uuid", "p_ok" boolean, "p_error" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."reissue_owner_safety_notice"("p_case" "uuid", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."reissue_owner_safety_notice"("p_case" "uuid", "p_reason" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."release_condition_satisfied"("p_release_condition" "text", "p_approved_at" timestamp with time zone, "p_policy" "text", "p_lifecycle_state" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."release_condition_satisfied"("p_release_condition" "text", "p_approved_at" timestamp with time zone, "p_policy" "text", "p_lifecycle_state" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."release_condition_writable"("p_release_condition" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."release_condition_writable"("p_release_condition" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."release_legal_hold"("p_hold_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."release_legal_hold"("p_hold_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."replace_vault_document"("p_doc_id" "uuid", "p_new_storage_path" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."replace_vault_document"("p_doc_id" "uuid", "p_new_storage_path" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."request_invitation_redelivery"("p_estate" "uuid", "p_invitation" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."request_invitation_redelivery"("p_estate" "uuid", "p_invitation" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."require_breakglass_justification"("p_reason" "text", "p_case_ref" "text") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."required_verification_level"("p_estate" "uuid") FROM PUBLIC;



GRANT ALL ON FUNCTION "public"."resolve_membership"("p_email" "text", "p_phone" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."restore_estate_asset"("p_asset_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."restore_estate_asset"("p_asset_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."revoke_estate_invitation"("p_estate" "uuid", "p_invitation" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."revoke_estate_invitation"("p_estate" "uuid", "p_invitation" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."revoke_invitation"("p_invitation_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."revoke_invitation"("p_invitation_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."set_jurisdiction_floor"("p_jurisdiction" "text", "p_floor_level" "public"."verification_level", "p_is_approved" boolean, "p_notes" "text", "p_reason" "text", "p_case_ref" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_jurisdiction_floor"("p_jurisdiction" "text", "p_floor_level" "public"."verification_level", "p_is_approved" boolean, "p_notes" "text", "p_reason" "text", "p_case_ref" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."submit_claim_packet"("p_estate" "uuid", "p_death_certificate_doc_id" "uuid", "p_executor_id_doc_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."submit_claim_packet"("p_estate" "uuid", "p_death_certificate_doc_id" "uuid", "p_executor_id_doc_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."submit_claim_with_evidence"("p_estate" "uuid", "p_death_cert_doc_id" "uuid", "p_death_cert_path" "text", "p_executor_id_doc_id" "uuid", "p_executor_id_path" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."submit_claim_with_evidence"("p_estate" "uuid", "p_death_cert_doc_id" "uuid", "p_death_cert_path" "text", "p_executor_id_doc_id" "uuid", "p_executor_id_path" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."unlink_asset_document"("p_asset_id" "uuid", "p_doc_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."unlink_asset_document"("p_asset_id" "uuid", "p_doc_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."update_estate_asset"("p_asset_id" "uuid", "p_subtype" "text", "p_label" "text", "p_sensitivity" "text", "p_owner_label" "text", "p_country_code" "text", "p_jurisdiction" "text", "p_institution_name" "text", "p_reference_hint" "text", "p_approximate_value_cents" bigint, "p_currency" "text", "p_notes" "text", "p_beneficiary_note" "text", "p_verification_status" "text", "p_clear" "text"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_estate_asset"("p_asset_id" "uuid", "p_subtype" "text", "p_label" "text", "p_sensitivity" "text", "p_owner_label" "text", "p_country_code" "text", "p_jurisdiction" "text", "p_institution_name" "text", "p_reference_hint" "text", "p_approximate_value_cents" bigint, "p_currency" "text", "p_notes" "text", "p_beneficiary_note" "text", "p_verification_status" "text", "p_clear" "text"[]) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."update_vault_document"("p_doc_id" "uuid", "p_title" "text", "p_doc_subtype" "text", "p_sensitivity" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_vault_document"("p_doc_id" "uuid", "p_title" "text", "p_doc_subtype" "text", "p_sensitivity" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."write_admin_breakglass_audit"("p_action" "text", "p_table" "text", "p_target" "uuid", "p_estate" "uuid", "p_reason" "text", "p_case_ref" "text", "p_meta" "jsonb") FROM PUBLIC;



REVOKE ALL ON FUNCTION "public"."write_audit"("p_action" "text", "p_table" "text", "p_target" "uuid", "p_estate" "uuid", "p_meta" "jsonb") FROM PUBLIC;


















GRANT SELECT ON TABLE "public"."beneficiaries" TO "authenticated";



GRANT SELECT ON TABLE "public"."claim_packets" TO "authenticated";



GRANT SELECT ON TABLE "public"."consent_records" TO "authenticated";



GRANT SELECT ON TABLE "public"."documents" TO "authenticated";



GRANT SELECT ON TABLE "public"."estate_asset_documents" TO "authenticated";



GRANT SELECT ON TABLE "public"."estate_assets" TO "authenticated";



GRANT SELECT,UPDATE ON TABLE "public"."invitation_delivery_outbox" TO "service_role";



GRANT SELECT,INSERT,DELETE ON TABLE "public"."normalized_assets" TO "authenticated";



GRANT SELECT,UPDATE ON TABLE "public"."notifications" TO "authenticated";



GRANT SELECT ON TABLE "public"."recovery_codes" TO "authenticated";



GRANT SELECT,UPDATE ON TABLE "public"."storage_deletion_outbox" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";



































