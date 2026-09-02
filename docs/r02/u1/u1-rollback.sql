-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- U1 · ROLLBACK — CONDITIONAL ON RECORDED OPERATOR EVIDENCE.  PREPARED, NOT EXECUTED.
--
-- ★ THIS IS NOT AN UNCONDITIONAL DOWN MIGRATION, AND MUST NEVER BECOME ONE.
--   U1 has two legitimate outcomes. If it RECOGNIZED a pre-existing authoritative binding — which
--   is what happens on afterworth-dev — then dropping the trigger here would DELETE LIVE
--   AUTHORITATIVE INFRASTRUCTURE THAT U1 NEVER CREATED, re-introducing the exact defect U1 repairs.
--   A static `DROP TRIGGER IF EXISTS` would do precisely that, silently.
--
-- ★ BEFORE RUNNING: replace CREATED_OR_RECOGNIZED below with the outcome U1 actually emitted
--   (`U1_ACTION=CREATED` or `U1_ACTION=RECOGNIZED`), taken from the recorded execution evidence.
--   Left unedited, the guard fails closed and nothing is dropped.
--
-- ★ It also re-verifies that the trigger STILL matches the exact contract U1 would have created.
--   If it has since changed, this HALTS rather than dropping something it no longer understands.
-- ════════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

DO $rb$
DECLARE
  v_recorded_action text := 'CREATED_OR_RECOGNIZED';   -- ← replace with CREATED or RECOGNIZED
  v_exact int;
BEGIN
  IF v_recorded_action NOT IN ('CREATED','RECOGNIZED') THEN
    RAISE EXCEPTION 'U1_ROLLBACK_HALT: recorded U1_ACTION not supplied (got %). Nothing dropped.', v_recorded_action;
  END IF;

  IF v_recorded_action = 'RECOGNIZED' THEN
    RAISE NOTICE 'U1_ROLLBACK_ACTION=NONE (U1 recognized a pre-existing binding; it is not ours to remove)';
    RETURN;
  END IF;

  -- CREATED path: the binding must still match, exactly, what U1 created.
  SELECT count(*) INTO v_exact
    FROM pg_catalog.pg_trigger tg
    JOIN pg_catalog.pg_class c ON c.oid = tg.tgrelid
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_catalog.pg_proc p ON p.oid = tg.tgfoid
    JOIN pg_catalog.pg_namespace pn ON pn.oid = p.pronamespace
   WHERE NOT tg.tgisinternal AND n.nspname = 'auth' AND c.relname = 'users'
     AND tg.tgname = 'on_auth_user_created' AND tg.tgenabled = 'O'
     AND pn.nspname = 'public' AND p.proname = 'handle_new_user'
     AND tg.tgnargs = 0 AND (tg.tgtype & 66) = 0 AND (tg.tgtype & 1) <> 0
     AND (tg.tgtype & 4) <> 0 AND (tg.tgtype & 8) = 0 AND (tg.tgtype & 16) = 0
     AND (tg.tgtype & 32) = 0;

  IF v_exact <> 1 THEN
    RAISE EXCEPTION 'U1_ROLLBACK_HALT: binding is absent or no longer matches the U1 contract (exact=%). Nothing dropped.', v_exact;
  END IF;

  DROP TRIGGER on_auth_user_created ON auth.users;   -- no IF EXISTS: presence was just proven

  IF (SELECT count(*) FROM pg_catalog.pg_trigger tg
        JOIN pg_catalog.pg_class c ON c.oid = tg.tgrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
       WHERE NOT tg.tgisinternal AND n.nspname='auth' AND c.relname='users'
         AND tg.tgname = 'on_auth_user_created') <> 0 THEN
    RAISE EXCEPTION 'U1_ROLLBACK_POSTCONDITION_FAILED';
  END IF;
  RAISE NOTICE 'U1_ROLLBACK_ACTION=DROPPED';
END
$rb$;

COMMIT;
