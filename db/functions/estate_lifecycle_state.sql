-- ────────────────────────────────────────────────────────────────────────────────────────────────
-- estate_lifecycle_state(p_estate) → text            [INTERNAL — the authoritative lifecycle read]
-- ────────────────────────────────────────────────────────────────────────────────────────────────
--
-- ★ EXTRACTED FROM `death_verification.sql` IN PHASE 11-D, because the seam changed sides. In 11-C
-- this reader existed for the death-verification routines and was consulted by nobody else — that
-- absence was the firewall. In 11-D the canonical release predicate consumes lifecycle state as an
-- argument, so every disclosure evaluator resolves it at read time. The reader therefore ships in
-- `release_conditions_bundle.sql` (the FIRST artifact an operator pastes), so that no paste order
-- ever leaves a consumer referencing a reader that does not exist yet. The death-verification
-- bundle also carries it (idempotent re-create), keeping that artifact single-paste runnable.
--
-- ★ ABSENT ROW = 'active'. An estate that has never seen a death-verification case has no row in
-- `estate_lifecycle`, and this reader answers the base state. The empty table is a correct table.
--
-- ★ THE CLOSED SET IS THE TABLE'S, NOT THIS FUNCTION'S. The CHECK on `estate_lifecycle.state`
-- (migration 0052) admits exactly 'active' / 'death_verification_pending' / 'death_verified', and
-- the canonical predicate REFUSES any lifecycle value outside that set — so a state this reader
-- could never produce fails closed at the predicate rather than being interpreted.
--
-- ★ NO CLIENT MAY EXECUTE THIS. A client that can map estate → lifecycle state has been handed a
-- death-status oracle for arbitrary estates. Its callers are SECURITY DEFINER routines (the
-- death-verification module and the disclosure evaluators) and the SQL suite. The disclosure rule
-- for consumers is pinned by `test/deathVerificationFoundation.test.ts`: outside the death module,
-- this function may appear ONLY as the lifecycle argument of `public.release_condition_satisfied` —
-- never as the subject of a local comparison, which would be release policy leaking out of the
-- canonical predicate one `if` at a time.
create or replace function public.estate_lifecycle_state(p_estate uuid)
 returns text
 language sql
 security definer
 stable
 set search_path to 'public'
as $function$
  select coalesce(
    (select l.state from public.estate_lifecycle l where l.estate_id = p_estate),
    'active');
$function$;
revoke execute on function public.estate_lifecycle_state(uuid) from public, anon, authenticated;

comment on function public.estate_lifecycle_state(uuid) is
  'THE authoritative estate lifecycle read (Phase 11-C, extracted 11-D). Absent row = active. '
  'INTERNAL: execute revoked from every client role — a client that can map estate to lifecycle '
  'state holds a death-status oracle. Consumed by the death-verification routines and, since 11-D, '
  'as the lifecycle argument to public.release_condition_satisfied inside disclosure evaluators. '
  'Never derived from claim_packets.status, evidence, or attained verification levels.';
