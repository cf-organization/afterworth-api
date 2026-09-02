-- 0061_20260901_handle_new_user_trigger.sql
-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- U1 · COMPLETENESS REPAIR — restore the auth.users → public.handle_new_user() runtime binding.
--
-- WHY THIS EXISTS. Model C bootstrap 0060 contains public.handle_new_user() but not the trigger
-- that invokes it, because the CLI schema dump that fed the generator excludes platform-owned
-- schemas and the binding lives on auth.users. A virgin bootstrap therefore creates no profiles
-- row on signup: invitation redemption fails closed, estate-member listings silently drop the
-- member, and a self-invitation guard stops firing. bootstrap@0060 is immutable, so the repair is
-- a post-0060 migration.
--
-- ★ MUTATION SURFACE: AT MOST ONE `CREATE TRIGGER`. No DML, no function replacement, no grant,
--   no role or ownership change, no DROP, no bootstrap change.
--
-- ★ FAIL-CLOSED. Eight classifier states; exactly ONE of them mutates. Everything ambiguous raises
--   and rolls the whole transaction back. Specifically NOT used, and why:
--     DROP TRIGGER IF EXISTS   — would delete a pre-existing authoritative binding
--     CREATE OR REPLACE TRIGGER— exists in PG14+, would silently overwrite SAME_NAME_DIFFERENT
--     enable/disable workaround— a disabled trigger is a deliberate operational act
--
-- ★ EXPLICIT ROW EXCLUSIVE LOCK, AND WHY THIS MODE. An earlier draft took no lock, reasoning that
--   the in-transaction postcondition closed the window. A two-session test disproved that for the
--   RECOGNIZE path: that path performs only catalog READS, which hold ZERO locks on auth.users
--   (observed), so a concurrent session created a duplicate binding 70ms later, un-blocked, and
--   committed BEFORE this transaction did — leaving a verified-looking RECOGNIZED outcome over a
--   committed state that was no longer exact. The CREATE path was already safe: CREATE TRIGGER
--   holds ShareRowExclusiveLock to commit (a competing CREATE waited 2554ms).
--
--   ROW EXCLUSIVE is the NARROWEST mode that conflicts with ShareRowExclusiveLock, measured:
--     ACCESS SHARE 74ms · ROW SHARE 73ms  (do not block)
--     ROW EXCLUSIVE 1850ms · SHARE ROW EXCLUSIVE 1849ms  (block)
--   It is deliberately not SHARE ROW EXCLUSIVE: ROW EXCLUSIVE is self-compatible, so ordinary
--   signups keep running while this migration holds it (a concurrent INSERT waited 59ms).
--   Privilege cost: ROW EXCLUSIVE needs INSERT/UPDATE/DELETE/TRUNCATE — the hosted executor holds
--   INSERT, UPDATE and DELETE on auth.users per Stage-0, so no new privilege is required.
-- ════════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

DO $u1$
DECLARE
  v_state   text;
  v_action  text;
  v_sem     int;   -- semantically equivalent bindings, any name, any enabled state
  v_exact   int;   -- exact: right name, right semantics, enabled 'O'
  v_offname int;   -- semantically equivalent, enabled 'O', but a different name
  v_offen   int;   -- semantically equivalent but enabled <> 'O'
  v_badname int;   -- occupies the canonical name but is not semantically equivalent
BEGIN
  -- ── INSTRUMENT ────────────────────────────────────────────────────────────────────────────────
  IF (SELECT count(*) FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'auth' AND c.relname = 'users') <> 1 THEN
    RAISE EXCEPTION 'U1_HALT state=INSTRUMENT_BROKEN (auth.users not visible exactly once)';
  END IF;

  -- ── FUNCTION CONTRACT — metadata AND body. Metadata alone would accept a rewritten body. ─────
  IF (SELECT count(*) FROM pg_catalog.pg_proc p
        JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
        JOIN pg_catalog.pg_language l ON l.oid = p.prolang
       WHERE n.nspname = 'public' AND p.proname = 'handle_new_user'
         AND pg_catalog.format_type(p.prorettype, NULL) = 'trigger'
         AND l.lanname = 'plpgsql'
         AND p.prosecdef
         AND p.provolatile = 'v'
         AND pg_catalog.pg_get_userbyid(p.proowner) = 'postgres'
         AND p.proconfig @> ARRAY['search_path=public']
         AND pg_catalog.pg_get_function_identity_arguments(p.oid) = ''
         AND encode(sha256(p.prosrc::bytea), 'hex')
             = '205a0555f463d294c286732bd9bd7be21fe4201f8310eb30a9ffcfa25b4bc456') <> 1 THEN
    RAISE EXCEPTION 'U1_HALT state=FUNCTION_CONTRACT_MISMATCH';
  END IF;

  -- ── SERIALIZE against concurrent trigger DDL for the REST of this transaction. ────────
  LOCK TABLE auth.users IN ROW EXCLUSIVE MODE;

  -- ── CLASSIFY. tgtype bits: ROW=1 BEFORE=2 INSERT=4 DELETE=8 UPDATE=16 TRUNCATE=32 INSTEAD=64.
  --    AFTER is the absence of BEFORE and INSTEAD, hence (tgtype & 66) = 0.
  WITH t AS (
    SELECT tg.tgname, tg.tgenabled::text AS en, tg.tgtype, tg.tgnargs,
           pn.nspname AS fs, p.proname AS fn
      FROM pg_catalog.pg_trigger tg
      JOIN pg_catalog.pg_class c ON c.oid = tg.tgrelid
      JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_catalog.pg_proc p ON p.oid = tg.tgfoid
      JOIN pg_catalog.pg_namespace pn ON pn.oid = p.pronamespace
     WHERE NOT tg.tgisinternal AND n.nspname = 'auth' AND c.relname = 'users'
  ), s AS (
    SELECT *, (fs = 'public' AND fn = 'handle_new_user' AND tgnargs = 0
               AND (tgtype & 66) = 0 AND (tgtype & 1) <> 0 AND (tgtype & 4) <> 0
               AND (tgtype & 8) = 0 AND (tgtype & 16) = 0 AND (tgtype & 32) = 0) AS sem
      FROM t
  )
  SELECT count(*) FILTER (WHERE sem),
         count(*) FILTER (WHERE sem AND en = 'O' AND tgname = 'on_auth_user_created'),
         count(*) FILTER (WHERE sem AND en = 'O' AND tgname <> 'on_auth_user_created'),
         count(*) FILTER (WHERE sem AND en <> 'O'),
         count(*) FILTER (WHERE tgname = 'on_auth_user_created' AND NOT sem)
    INTO v_sem, v_exact, v_offname, v_offen, v_badname
    FROM s;

  v_state := CASE
    WHEN v_sem   > 1 THEN 'MULTIPLE_EQUIVALENT'
    WHEN v_offen > 0 THEN 'DISABLED_EQUIVALENT'
    WHEN v_badname > 0 THEN 'SAME_NAME_DIFFERENT'
    WHEN v_offname > 0 THEN 'EQUIVALENT_DIFFERENT_NAME'
    WHEN v_exact = 1 THEN 'EXACT_EQUIVALENT'
    ELSE 'ABSENT' END;

  -- ── ACT. Exactly one state mutates. ──────────────────────────────────────────────────────────
  IF v_state = 'ABSENT' THEN
    CREATE TRIGGER on_auth_user_created
      AFTER INSERT ON auth.users
      FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();
    v_action := 'CREATED';
  ELSIF v_state = 'EXACT_EQUIVALENT' THEN
    v_action := 'RECOGNIZED';
  ELSE
    RAISE EXCEPTION 'U1_HALT state=% (no mutation performed)', v_state;
  END IF;

  -- ── POSTCONDITION, in-transaction. Also closes the TOCTOU window (see header). ───────────────
  IF (SELECT count(*) FROM pg_catalog.pg_trigger tg
        JOIN pg_catalog.pg_class c ON c.oid = tg.tgrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_catalog.pg_proc p ON p.oid = tg.tgfoid
        JOIN pg_catalog.pg_namespace pn ON pn.oid = p.pronamespace
       WHERE NOT tg.tgisinternal AND n.nspname = 'auth' AND c.relname = 'users'
         AND tg.tgname = 'on_auth_user_created' AND tg.tgenabled = 'O'
         AND pn.nspname = 'public' AND p.proname = 'handle_new_user'
         AND tg.tgnargs = 0 AND (tg.tgtype & 66) = 0 AND (tg.tgtype & 1) <> 0
         AND (tg.tgtype & 4) <> 0 AND (tg.tgtype & 8) = 0 AND (tg.tgtype & 16) = 0
         AND (tg.tgtype & 32) = 0) <> 1 THEN
    RAISE EXCEPTION 'U1_POSTCONDITION_FAILED (expected exactly one exact binding)';
  END IF;

  IF (SELECT count(*) FROM pg_catalog.pg_trigger tg
        JOIN pg_catalog.pg_class c ON c.oid = tg.tgrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_catalog.pg_proc p ON p.oid = tg.tgfoid
        JOIN pg_catalog.pg_namespace pn ON pn.oid = p.pronamespace
       WHERE NOT tg.tgisinternal AND n.nspname = 'auth' AND c.relname = 'users'
         AND pn.nspname = 'public' AND p.proname = 'handle_new_user') <> 1 THEN
    RAISE EXCEPTION 'U1_POSTCONDITION_FAILED (duplicate equivalent binding present)';
  END IF;

  RAISE NOTICE 'U1_ACTION=% state=%', v_action, v_state;
END
$u1$;

COMMIT;
