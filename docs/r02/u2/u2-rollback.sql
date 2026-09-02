-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- U2 · ROLLBACK — CONDITIONAL ON RECORDED OPERATOR EVIDENCE.  PREPARED, NOT EXECUTED.
--
-- ★ NOT AN UNCONDITIONAL DOWN MIGRATION. U2 has two legitimate outcomes. If it RECOGNIZED an
--   already-converged state, this must do NOTHING: the hardening was not ours to remove. Only an
--   APPLIED run may be reversed, and only after re-verifying the exact poststate still stands.
--
-- ★ Replace CREATED_OR_RECOGNIZED with the outcome U2 emitted (U2_ACTION=APPLIED or
--   U2_ACTION=RECOGNIZED). Left unedited, the guard fails closed and nothing changes.
--
-- ★ RESTORES THE EXACT RATIFIED PRESTATE — assets_write's WITH CHECK back to owner-only and the
--   two restrictive policies dropped. It does not invent a third state, and it uses no blind
--   DROP POLICY IF EXISTS: presence and exact shape are proven immediately before each drop.
--
-- ★ REVERSING U2 RESTORES A PROVEN WEAKNESS — cross-estate INSERT and UPDATE become possible again
--   wherever a write grant exists. This is a breakglass, not routine.
-- ════════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

DO $rb$
DECLARE
  v_recorded_action text := 'CREATED_OR_RECOGNIZED';   -- ← replace with APPLIED or RECOGNIZED
  v_post int;
BEGIN
  IF v_recorded_action NOT IN ('APPLIED','RECOGNIZED') THEN
    RAISE EXCEPTION 'U2_ROLLBACK_HALT: recorded U2_ACTION not supplied (got %). Nothing changed.', v_recorded_action;
  END IF;

  IF v_recorded_action = 'RECOGNIZED' THEN
    RAISE NOTICE 'U2_ROLLBACK_ACTION=NONE (U2 recognized an already-converged state; not ours to reverse)';
    RETURN;
  END IF;

  LOCK TABLE public.assets IN ACCESS SHARE MODE;

  SELECT count(*) INTO v_post
    FROM pg_catalog.pg_policy pol
    JOIN pg_catalog.pg_class c ON c.oid = pol.polrelid
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relname = 'assets'
     AND ((pol.polname = 'assets_write' AND pol.polcmd::text = '*' AND pol.polpermissive
           AND pg_catalog.pg_get_expr(pol.polwithcheck, pol.polrelid)
               = '((owner_id = auth.uid()) AND is_estate_owner(estate_id))')
       OR (pol.polname = 'assets_insert_require_estate_owner' AND pol.polcmd::text = 'a'
           AND NOT pol.polpermissive
           AND pg_catalog.pg_get_expr(pol.polwithcheck, pol.polrelid) = 'is_estate_owner(estate_id)')
       OR (pol.polname = 'assets_update_require_estate_owner' AND pol.polcmd::text = 'w'
           AND NOT pol.polpermissive
           AND pg_catalog.pg_get_expr(pol.polwithcheck, pol.polrelid) = 'is_estate_owner(estate_id)'));

  IF v_post <> 3 THEN
    RAISE EXCEPTION 'U2_ROLLBACK_HALT: poststate no longer matches what U2 applied (matched %/3). Nothing changed.', v_post;
  END IF;

  ALTER POLICY assets_write ON public.assets
    USING (owner_id = auth.uid())
    WITH CHECK (owner_id = auth.uid());
  DROP POLICY assets_update_require_estate_owner ON public.assets;
  DROP POLICY assets_insert_require_estate_owner ON public.assets;

  IF (SELECT count(*) FROM pg_catalog.pg_policy pol
        JOIN pg_catalog.pg_class c ON c.oid = pol.polrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public' AND c.relname = 'assets') <> 2 THEN
    RAISE EXCEPTION 'U2_ROLLBACK_POSTCONDITION_FAILED';
  END IF;
  RAISE NOTICE 'U2_ROLLBACK_ACTION=REVERSED';
END
$rb$;

COMMIT;
