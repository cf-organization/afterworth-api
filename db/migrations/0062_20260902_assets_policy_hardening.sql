-- 0062_20260902_assets_policy_hardening.sql
-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- U2 · SECURITY HARDENING — enforce destination-estate ownership on public.assets writes.
--
-- WHY. `assets_write` is FOR ALL with `WITH CHECK (owner_id = auth.uid())`. It constrains WHO owns
-- the row and says nothing about WHICH ESTATE the row lands in, so an owner-authorised write may
-- place or move an asset into an estate the caller does not own. Proven behaviourally against the
-- canonical state: a cross-estate UPDATE returned `UPDATE 1` and a cross-estate INSERT returned
-- `INSERT 0 1`.
--
-- Currently UNREACHABLE — public.assets has zero client row-DML grants (relacl is null, Phase 100
-- names it only in an OWNER TO). This is proactive structural hardening, not an incident response.
--
-- ★ WHY A RESTRICTIVE LAYER AND NOT JUST A STRONGER `assets_write`. PostgreSQL ORs permissive
--   policies and ANDs restrictive ones. Tightening only `assets_write` is undone by any future
--   permissive policy. Measured: with a hostile `FOR ALL USING (true) WITH CHECK (true)` present,
--   the restrictive layer still DENIED both the cross-estate move and insert; with the restrictive
--   layer removed, the same hostile policy let both through.
--
-- ★ THE IN-TRANSACTION POSTCONDITION MATCHES EACH POLICY BY IDENTITY. Nothing may COMMIT unless
--   all four policies are individually exactly right. A set-cardinality check ("two restrictive
--   policies whose command is one of INSERT/UPDATE") is NOT equivalent and shipped a real hole —
--   see the note on the postcondition itself.
--
-- ★ MUTATION SURFACE: POLICY METADATA ONLY. One ALTER POLICY, two CREATE POLICY. No DML, no
--   backfill, no GRANT/REVOKE, no function change, no ownership change, no DROP of a correct
--   policy, no bootstrap change. RLS policy creation does not validate existing rows, so no data
--   migration is required or performed.
--
-- ★ LOCK TABLE public.assets IN ACCESS SHARE MODE. Policy DDL takes AccessExclusiveLock, which
--   conflicts with every lock mode, so ACCESS SHARE — the weakest, needing only SELECT — is
--   sufficient to serialise this transaction against concurrent CREATE/ALTER/DROP POLICY. It is
--   taken for the RECOGNIZE path, which otherwise performs only catalog reads and would hold NO
--   lock at all. U1 shipped that exposure and it was caught by a two-session test; this does not
--   repeat it.
-- ════════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

DO $u2$
DECLARE
  v_state  text;
  v_action text;
  v_total  int;
  v_read   int;
  v_wpre   int;
  v_wpost  int;
  v_ins_ok int;
  v_upd_ok int;
  v_ins_n  int;
  v_upd_n  int;
  v_write  int;
  v_read_n int;
  v_alien  int;
  v_fp     text;
BEGIN
  -- ── INSTRUMENT ───────────────────────────────────────────────────────────────────────────────
  IF (SELECT count(*) FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public' AND c.relname = 'assets') <> 1
     OR (SELECT count(*) FROM pg_catalog.pg_proc p
           JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
          WHERE n.nspname = 'public' AND p.proname IN ('is_estate_owner','is_estate_member')) <> 2 THEN
    RAISE EXCEPTION 'U2_HALT state=INSTRUMENT_BROKEN';
  END IF;

  -- ── SERIALISE for the rest of the transaction (see header). ─────────────────────────────────
  LOCK TABLE public.assets IN ACCESS SHARE MODE;

  -- ── CLASSIFY, semantically. Name alone proves nothing. ──────────────────────────────────────
  WITH p AS (
    SELECT pol.polname n, pol.polcmd::text cmd, pol.polpermissive perm,
           (pol.polroles = '{0}'::oid[]) pub,
           coalesce(pg_catalog.pg_get_expr(pol.polqual, pol.polrelid), '~') q,
           coalesce(pg_catalog.pg_get_expr(pol.polwithcheck, pol.polrelid), '~') w
      FROM pg_catalog.pg_policy pol
      JOIN pg_catalog.pg_class c ON c.oid = pol.polrelid
      JOIN pg_catalog.pg_namespace ns ON ns.oid = c.relnamespace
     WHERE ns.nspname = 'public' AND c.relname = 'assets'
  )
  SELECT count(*),
         count(*) FILTER (WHERE n = 'assets_read' AND cmd = 'r' AND perm AND pub
                            AND q = '((owner_id = auth.uid()) OR is_estate_member(estate_id))' AND w = '~'),
         count(*) FILTER (WHERE n = 'assets_write' AND cmd = '*' AND perm AND pub
                            AND q = '(owner_id = auth.uid())' AND w = '(owner_id = auth.uid())'),
         count(*) FILTER (WHERE n = 'assets_write' AND cmd = '*' AND perm AND pub
                            AND q = '(owner_id = auth.uid())'
                            AND w = '((owner_id = auth.uid()) AND is_estate_owner(estate_id))'),
         count(*) FILTER (WHERE n = 'assets_insert_require_estate_owner' AND cmd = 'a' AND NOT perm
                            AND pub AND q = '~' AND w = 'is_estate_owner(estate_id)'),
         count(*) FILTER (WHERE n = 'assets_update_require_estate_owner' AND cmd = 'w' AND NOT perm
                            AND pub AND q = '~' AND w = 'is_estate_owner(estate_id)'),
         count(*) FILTER (WHERE n = 'assets_insert_require_estate_owner'),
         count(*) FILTER (WHERE n = 'assets_update_require_estate_owner'),
         count(*) FILTER (WHERE n = 'assets_write'),
         count(*) FILTER (WHERE n = 'assets_read'),
         count(*) FILTER (WHERE n NOT IN ('assets_read','assets_write',
                                          'assets_insert_require_estate_owner',
                                          'assets_update_require_estate_owner'))
    INTO v_total, v_read, v_wpre, v_wpost, v_ins_ok, v_upd_ok, v_ins_n, v_upd_n, v_write, v_read_n, v_alien
    FROM p;

  v_state := CASE
    WHEN v_alien > 0                              THEN 'DUPLICATE_OR_UNEXPECTED_ASSETS_POLICY'
    WHEN v_read_n = 0                             THEN 'MISSING_ASSETS_READ'
    WHEN v_write = 0                              THEN 'MISSING_ASSETS_WRITE'
    WHEN v_read <> 1                              THEN 'ASSETS_READ_DIFFERENT'
    WHEN v_ins_n > 0 AND v_ins_ok = 0             THEN 'INSERT_HARDENING_ALREADY_PRESENT_DIFFERENT'
    WHEN v_upd_n > 0 AND v_upd_ok = 0             THEN 'UPDATE_HARDENING_ALREADY_PRESENT_DIFFERENT'
    WHEN v_wpre = 1 AND v_ins_n = 0 AND v_upd_n = 0 AND v_total = 2 THEN 'EXACT_PRESTATE'
    WHEN v_wpost = 1 AND v_ins_ok = 1 AND v_upd_ok = 1 AND v_total = 4 THEN 'EXACT_POSTSTATE'
    WHEN v_wpre = 0 AND v_wpost = 0               THEN 'ASSETS_WRITE_DIFFERENT'
    ELSE 'PARTIAL_HARDENING' END;

  -- ── ACT. Exactly one state mutates. ─────────────────────────────────────────────────────────
  IF v_state = 'EXACT_PRESTATE' THEN
    ALTER POLICY assets_write ON public.assets
      USING (owner_id = auth.uid())
      WITH CHECK (owner_id = auth.uid() AND public.is_estate_owner(estate_id));

    CREATE POLICY assets_insert_require_estate_owner ON public.assets
      AS RESTRICTIVE FOR INSERT
      WITH CHECK (public.is_estate_owner(estate_id));

    CREATE POLICY assets_update_require_estate_owner ON public.assets
      AS RESTRICTIVE FOR UPDATE
      WITH CHECK (public.is_estate_owner(estate_id));

    v_action := 'APPLIED';
  ELSIF v_state = 'EXACT_POSTSTATE' THEN
    v_action := 'RECOGNIZED';
  ELSE
    RAISE EXCEPTION 'U2_HALT state=% (no mutation performed)', v_state;
  END IF;

  -- ── POSTCONDITION, in-transaction. EACH POLICY PROVEN BY IDENTITY, NOT BY POPULATION COUNT. ──
  --
  -- ★ WHY THIS IS NOT A COUNT OF TWO RESTRICTIVE POLICIES. The first version asserted "two
  --   restrictive PUBLIC policies whose WITH CHECK is is_estate_owner(estate_id) and whose command
  --   is one of ('a','w')". That is satisfied by TWO UPDATE policies and no INSERT policy — so a
  --   build in which assets_insert_require_estate_owner was declared FOR UPDATE passed the
  --   in-transaction guard and COMMITTED a state with the INSERT destination check missing. It was
  --   caught only by the separate postcheck, after commit. A set-cardinality assertion cannot
  --   express a name-to-command mapping; each policy must be matched individually.
  WITH p AS (
    SELECT pol.polname n, pol.polcmd::text cmd, pol.polpermissive perm,
           (pol.polroles = '{0}'::oid[]) pub,
           coalesce(pg_catalog.pg_get_expr(pol.polqual, pol.polrelid), '~') q,
           coalesce(pg_catalog.pg_get_expr(pol.polwithcheck, pol.polrelid), '~') w
      FROM pg_catalog.pg_policy pol
      JOIN pg_catalog.pg_class c ON c.oid = pol.polrelid
      JOIN pg_catalog.pg_namespace ns ON ns.oid = c.relnamespace
     WHERE ns.nspname = 'public' AND c.relname = 'assets'
  )
  SELECT count(*),
         count(*) FILTER (WHERE n = 'assets_read' AND cmd = 'r' AND perm AND pub
                            AND q = '((owner_id = auth.uid()) OR is_estate_member(estate_id))' AND w = '~'),
         count(*) FILTER (WHERE n = 'assets_write' AND cmd = '*' AND perm AND pub
                            AND q = '(owner_id = auth.uid())'
                            AND w = '((owner_id = auth.uid()) AND is_estate_owner(estate_id))'),
         count(*) FILTER (WHERE n = 'assets_insert_require_estate_owner' AND cmd = 'a' AND NOT perm
                            AND pub AND q = '~' AND w = 'is_estate_owner(estate_id)'),
         count(*) FILTER (WHERE n = 'assets_update_require_estate_owner' AND cmd = 'w' AND NOT perm
                            AND pub AND q = '~' AND w = 'is_estate_owner(estate_id)')
    INTO v_total, v_read, v_wpost, v_ins_ok, v_upd_ok
    FROM p;

  IF v_read <> 1 THEN
    RAISE EXCEPTION 'U2_POSTCONDITION_FAILED (assets_read is not the exact ratified PERMISSIVE PUBLIC SELECT policy)';
  END IF;
  IF v_wpost <> 1 THEN
    RAISE EXCEPTION 'U2_POSTCONDITION_FAILED (assets_write is not the exact hardened PERMISSIVE PUBLIC ALL policy)';
  END IF;
  IF v_ins_ok <> 1 THEN
    RAISE EXCEPTION 'U2_POSTCONDITION_FAILED (assets_insert_require_estate_owner is not RESTRICTIVE PUBLIC FOR INSERT with USING absent and WITH CHECK is_estate_owner(estate_id))';
  END IF;
  IF v_upd_ok <> 1 THEN
    RAISE EXCEPTION 'U2_POSTCONDITION_FAILED (assets_update_require_estate_owner is not RESTRICTIVE PUBLIC FOR UPDATE with USING absent and WITH CHECK is_estate_owner(estate_id))';
  END IF;
  IF v_total <> 4 THEN
    RAISE EXCEPTION 'U2_POSTCONDITION_FAILED (public.assets carries % policies, expected exactly four)', v_total;
  END IF;

  -- ★ EXACT SEMANTIC FINGERPRINT. Redundant given the four identity assertions above plus the
  --   total of four — those already determine the state completely — but it pins the whole
  --   poststate to one ratified constant that an operator can compare by eye against the precheck
  --   and postcheck output, and it fails on any attribute a future edit forgets to assert.
  SELECT coalesce(md5(string_agg(
           pol.polname || '|' || pol.polcmd::text || '|' || pol.polpermissive::text || '|' ||
           (CASE WHEN pol.polroles = '{0}'::oid[] THEN 'PUBLIC' ELSE 'SCOPED' END) || '|' ||
           coalesce(pg_catalog.pg_get_expr(pol.polqual, pol.polrelid), '~') || '|' ||
           coalesce(pg_catalog.pg_get_expr(pol.polwithcheck, pol.polrelid), '~'),
           ',' ORDER BY pol.polname)), 'NONE')
    INTO v_fp
    FROM pg_catalog.pg_policy pol
    JOIN pg_catalog.pg_class c ON c.oid = pol.polrelid
    JOIN pg_catalog.pg_namespace ns ON ns.oid = c.relnamespace
   WHERE ns.nspname = 'public' AND c.relname = 'assets';

  IF v_fp <> 'f3b3f92058a4be2945de72be3800e32f' THEN
    RAISE EXCEPTION 'U2_POSTCONDITION_FAILED (assets policy fingerprint is %, expected the ratified poststate f3b3f92058a4be2945de72be3800e32f)', v_fp;
  END IF;

  RAISE NOTICE 'U2_ACTION=% state=%', v_action, v_state;
END
$u2$;

COMMIT;
