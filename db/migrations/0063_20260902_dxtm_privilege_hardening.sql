-- 0063_20260902_dxtm_privilege_hardening.sql
-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- U3 · SECURITY HARDENING — remove the Dxtm surface from client roles on application tables.
--
-- WHY. Every ordinary table in `public` carries TRUNCATE / REFERENCES / TRIGGER / MAINTAIN for
-- `anon`, `authenticated` and `service_role`. TRUNCATE operates OUTSIDE row-level security, so a
-- usable TRUNCATE privilege can destroy every row of an RLS-protected table. Defence-in-depth: not
-- presently reachable, because client row-DML is granted sparingly and the API exposes no such path.
--
-- ★ THE GRANTS COME FROM A DEFAULT ACL, NOT FROM ANY MIGRATION. Model C's Phase 100 issues no client
--   GRANT; its ALTER DEFAULT PRIVILEGES statements grant to `postgres` only. The privileges arrive at
--   CREATE TABLE time from the default ACL of the CREATING role. Clearing existing tables without
--   clearing that default reinstates them on the next table.
--
-- ★ SCOPE IS LOAD-BEARING AND A MISMATCH IS A SILENT NO-OP. Proven on PG17: per-schema defaults are
--   ADDED to global defaults and a REVOKE cannot subtract across scopes — a global GRANT with an
--   `IN SCHEMA public` REVOKE leaves new tables fully privileged and reports success. The hosted
--   diagnostic resolved the actual scope: grantor `postgres`, schema `public`, SCHEMA-SCOPED. This
--   migration therefore targets exactly that, and HALTS if a postgres GLOBAL default is ever found.
--
-- ★ supabase_admin's public defaults are PLATFORM-OWNED AND OUT OF SCOPE. They also carry Dxtm (and
--   row-DML) for client roles, but a default ACL is selected by the role CREATING the object, and
--   every one of the 41 application tables is created and owned by `postgres`. They therefore do not
--   determine application-table ACLs. This migration never touches them, and its postconditions
--   deliberately do NOT assert "no Dxtm default anywhere" — that assertion would fail on hosted for
--   a reason that is not ours to fix.
--
-- ★ SERIALIZATION IS OPERATIONAL, NOT DATABASE-ENFORCED. Measured: GRANT/REVOKE take no relation
--   lock on the target table, so no LOCK TABLE on an application table can serialize them; the only
--   mechanism that works is SHARE on pg_class / pg_default_acl, and the hosted executor is denied it
--   (pg_class is owned by supabase_admin; postgres is not a member and holds no UPDATE). An earlier
--   candidate carried a 41-table ACCESS SHARE loop — it was measurably ineffective and has been
--   REMOVED rather than left in place looking like a control. See
--   docs/r02/u3/u3-operational-freeze-protocol.md. Without the freeze, a concurrent GRANT can cross
--   the RECOGNIZE path and a concurrent CREATE TABLE can carry stale Dxtm across this transaction.
--
-- ★ MAINTAIN IS PG17+. The privilege list is built from server_version_num so a PG16 rehearsal does
--   not fail on an unknown privilege name. Hosted is 17.6, so the executed statement includes it.
--
-- ★ ROW-DML IS NEVER TOUCHED. 21 deliberate client row-DML grants exist across 15 tables. Only the
--   four non-row-DML privileges are revoked, and the semantic row-DML inventory is captured before
--   the mutation and proven identical after. There is no REVOKE ALL anywhere in this file.
-- ════════════════════════════════════════════════════════════════════════════════════════════════
BEGIN;

DO $u3$
DECLARE
  v_state        text;
  v_action       text := 'NONE';
  v_privs        text;
  v_tables       int;
  v_owners       int;
  v_notpg        int;
  v_tableset_fp  text;
  v_dxtm_rows    int;
  v_dxtm_before  int;
  v_rowdml_fp0   text;
  v_rowdml_fp    text;
  v_rowdml_n0    int;
  v_rowdml_n     int;
  v_adp_pub_dxtm int;
  v_adp_pub_dml  int;
  v_adp_glb_dxtm int;
  v_ctl          int;
  r              record;
BEGIN
  -- ── INSTRUMENT. An audit that cannot see privileges must never report their absence. ─────────
  SELECT count(*) INTO v_ctl FROM pg_catalog.pg_roles
   WHERE rolname IN ('anon','authenticated','service_role');
  IF v_ctl <> 3
     OR (SELECT count(*) FROM pg_catalog.pg_namespace WHERE nspname = 'public') <> 1
     OR (SELECT count(*) FROM pg_catalog.pg_roles WHERE rolname = 'postgres') <> 1 THEN
    RAISE EXCEPTION 'U3_HALT state=INSTRUMENT_BROKEN (client roles=%, public schema or postgres role missing)', v_ctl;
  END IF;
  -- POSITIVE CONTROL: the ACL decoder must RETURN a client grant known to be present. Without it,
  -- "zero Dxtm found" is indistinguishable from a decoder that can find nothing at all.
  SELECT count(*) INTO v_ctl
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace, aclexplode(c.relacl) a
   WHERE n.nspname = 'public' AND c.relkind = 'r'
     AND pg_catalog.pg_get_userbyid(a.grantee) IN ('anon','authenticated','service_role')
     AND a.privilege_type IN ('SELECT','INSERT','UPDATE','DELETE');
  IF v_ctl < 1 THEN
    RAISE EXCEPTION 'U3_HALT state=INSTRUMENT_BROKEN (ACL decoder returned no known client row-DML grant)';
  END IF;

  IF current_setting('server_version_num')::int >= 170000 THEN
    v_privs := 'TRUNCATE, REFERENCES, TRIGGER, MAINTAIN';
  ELSE
    v_privs := 'TRUNCATE, REFERENCES, TRIGGER';
  END IF;

  -- ── CLASSIFY: application table population and ownership ────────────────────────────────────
  SELECT count(*), count(DISTINCT c.relowner),
         count(*) FILTER (WHERE pg_catalog.pg_get_userbyid(c.relowner) <> 'postgres'),
         md5(string_agg(c.relname, ',' ORDER BY c.relname))
    INTO v_tables, v_owners, v_notpg, v_tableset_fp
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relkind = 'r';

  -- ── CLASSIFY: existing-table Dxtm ───────────────────────────────────────────────────────────
  SELECT count(*) INTO v_dxtm_rows
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace, aclexplode(c.relacl) a
   WHERE n.nspname = 'public' AND c.relkind = 'r'
     AND pg_catalog.pg_get_userbyid(a.grantee) IN ('anon','authenticated','service_role')
     AND a.privilege_type IN ('TRUNCATE','REFERENCES','TRIGGER','MAINTAIN');

  v_dxtm_before := v_dxtm_rows;

  -- ── CAPTURE: row-DML semantic state, BEFORE any mutation ────────────────────────────────────
  SELECT coalesce(md5(string_agg(g, ',' ORDER BY g)), 'NONE'), count(*)
    INTO v_rowdml_fp0, v_rowdml_n0
    FROM (SELECT c.relname || '|' || pg_catalog.pg_get_userbyid(a.grantee) || '|' || a.privilege_type AS g
            FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace, aclexplode(c.relacl) a
           WHERE n.nspname = 'public' AND c.relkind = 'r'
             AND pg_catalog.pg_get_userbyid(a.grantee) IN ('anon','authenticated','service_role')
             AND a.privilege_type IN ('SELECT','INSERT','UPDATE','DELETE')) s;

  -- ── CLASSIFY: the APPLICATION-CREATOR default ACL only (grantor postgres). ──────────────────
  -- Platform grantors (supabase_admin and others) are deliberately NOT counted here: a default ACL
  -- is selected by the creating role, and every application table is created by postgres.
  SELECT count(*) FILTER (WHERE d.defaclnamespace = 'public'::regnamespace::oid
                            AND a.privilege_type IN ('TRUNCATE','REFERENCES','TRIGGER','MAINTAIN')),
         count(*) FILTER (WHERE d.defaclnamespace = 'public'::regnamespace::oid
                            AND a.privilege_type IN ('SELECT','INSERT','UPDATE','DELETE')),
         count(*) FILTER (WHERE d.defaclnamespace = 0
                            AND a.privilege_type IN ('TRUNCATE','REFERENCES','TRIGGER','MAINTAIN'))
    INTO v_adp_pub_dxtm, v_adp_pub_dml, v_adp_glb_dxtm
    FROM pg_catalog.pg_default_acl d, aclexplode(d.defaclacl) a
   WHERE d.defaclobjtype = 'r'
     AND pg_catalog.pg_get_userbyid(d.defaclrole) = 'postgres'
     AND pg_catalog.pg_get_userbyid(a.grantee) IN ('anon','authenticated','service_role');

  -- ── STATE ────────────────────────────────────────────────────────────────────────────────────
  v_state := CASE
    WHEN v_notpg > 0 OR v_owners <> 1               THEN 'UNEXPECTED_PUBLIC_TABLE_OWNER'
    WHEN v_tables > 41                              THEN 'UNEXPECTED_PUBLIC_TABLE'
    WHEN v_tables < 41                              THEN 'MISSING_EXPECTED_PUBLIC_TABLE'
    WHEN v_tableset_fp IS DISTINCT FROM '0009141a4788e0e4adf17a3209bab24c'
                                                    THEN 'UNEXPECTED_PUBLIC_TABLE'
    WHEN v_rowdml_fp0 IS DISTINCT FROM '052198590dd92ba70ab07c99cbd21f15'
                                                    THEN 'UNEXPECTED_ROW_DML_DRIFT'
    WHEN v_adp_glb_dxtm > 0                         THEN 'UNEXPECTED_POSTGRES_GLOBAL_DEFAULT_ACL'
    WHEN v_adp_pub_dml  > 0                         THEN 'UNEXPECTED_POSTGRES_PUBLIC_DEFAULT_ACL'
    WHEN v_dxtm_rows = 492 AND v_adp_pub_dxtm = 12  THEN 'EXACT_PRESTATE'
    WHEN v_dxtm_rows = 0   AND v_adp_pub_dxtm = 0   THEN 'EXACT_POSTSTATE'
    WHEN v_dxtm_rows = 0   AND v_adp_pub_dxtm > 0   THEN 'PARTIAL_DEFAULT_ACL_HARDENING'
    WHEN v_dxtm_rows > 0   AND v_adp_pub_dxtm = 0   THEN 'PARTIAL_TABLE_HARDENING'
    ELSE 'UNEXPECTED_Dxtm_VARIANT' END;

  -- ── ACT. Exactly one state mutates. ─────────────────────────────────────────────────────────
  IF v_state = 'EXACT_PRESTATE' THEN
    -- (1) FUTURE TABLES FIRST, at the hosted-proven scope. Not global: a global REVOKE could not
    --     subtract from a schema-scoped grant, and issuing one would be a silent no-op.
    EXECUTE format(
      'ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE %s ON TABLES FROM anon, authenticated, service_role',
      v_privs);

    -- (2) EXISTING TABLES, named one at a time from the classified set. Never
    --     `ON ALL TABLES IN SCHEMA public` — that resolves its own set at execution time, which is
    --     not the set this transaction classified and approved.
    FOR r IN
      SELECT c.relname FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public' AND c.relkind = 'r' ORDER BY c.relname
    LOOP
      EXECUTE format('REVOKE %s ON TABLE public.%I FROM anon, authenticated, service_role', v_privs, r.relname);
    END LOOP;

    v_action := 'APPLIED';
  ELSIF v_state = 'EXACT_POSTSTATE' THEN
    v_action := 'RECOGNIZED';
  ELSE
    RAISE EXCEPTION 'U3_HALT state=% (no privilege change performed)', v_state;
  END IF;

  -- ── POSTCONDITIONS, in-transaction, each asserted individually ──────────────────────────────
  SELECT count(*), count(DISTINCT c.relowner),
         md5(string_agg(c.relname, ',' ORDER BY c.relname))
    INTO v_tables, v_owners, v_tableset_fp
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relkind = 'r';
  IF v_tables <> 41 OR v_owners <> 1
     OR v_tableset_fp IS DISTINCT FROM '0009141a4788e0e4adf17a3209bab24c' THEN
    RAISE EXCEPTION 'U3_POSTCONDITION_FAILED (table population changed: % tables, % owners, fp %)',
      v_tables, v_owners, v_tableset_fp;
  END IF;

  SELECT count(*) INTO v_dxtm_rows
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace, aclexplode(c.relacl) a
   WHERE n.nspname = 'public' AND c.relkind = 'r'
     AND pg_catalog.pg_get_userbyid(a.grantee) IN ('anon','authenticated','service_role')
     AND a.privilege_type IN ('TRUNCATE','REFERENCES','TRIGGER','MAINTAIN');
  IF v_dxtm_rows <> 0 THEN
    RAISE EXCEPTION 'U3_POSTCONDITION_FAILED (% client Dxtm grants remain on application tables)', v_dxtm_rows;
  END IF;

  -- Per client role individually, so a failure names the role rather than a total.
  FOR r IN SELECT unnest(ARRAY['anon','authenticated','service_role']) AS rolname LOOP
    SELECT count(*) INTO v_ctl
      FROM pg_catalog.pg_default_acl d, aclexplode(d.defaclacl) a
     WHERE d.defaclobjtype = 'r'
       AND pg_catalog.pg_get_userbyid(d.defaclrole) = 'postgres'
       AND d.defaclnamespace = 'public'::regnamespace::oid
       AND pg_catalog.pg_get_userbyid(a.grantee) = r.rolname
       AND a.privilege_type IN ('TRUNCATE','REFERENCES','TRIGGER','MAINTAIN');
    IF v_ctl <> 0 THEN
      RAISE EXCEPTION 'U3_POSTCONDITION_FAILED (postgres/public default ACL still grants % Dxtm privileges to %)', v_ctl, r.rolname;
    END IF;
  END LOOP;

  SELECT count(*) INTO v_adp_glb_dxtm
    FROM pg_catalog.pg_default_acl d, aclexplode(d.defaclacl) a
   WHERE d.defaclobjtype = 'r' AND d.defaclnamespace = 0
     AND pg_catalog.pg_get_userbyid(d.defaclrole) = 'postgres'
     AND pg_catalog.pg_get_userbyid(a.grantee) IN ('anon','authenticated','service_role')
     AND a.privilege_type IN ('TRUNCATE','REFERENCES','TRIGGER','MAINTAIN');
  IF v_adp_glb_dxtm <> 0 THEN
    RAISE EXCEPTION 'U3_POSTCONDITION_FAILED (a postgres GLOBAL default ACL would reintroduce Dxtm: % grants)', v_adp_glb_dxtm;
  END IF;

  SELECT coalesce(md5(string_agg(g, ',' ORDER BY g)), 'NONE'), count(*)
    INTO v_rowdml_fp, v_rowdml_n
    FROM (SELECT c.relname || '|' || pg_catalog.pg_get_userbyid(a.grantee) || '|' || a.privilege_type AS g
            FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace, aclexplode(c.relacl) a
           WHERE n.nspname = 'public' AND c.relkind = 'r'
             AND pg_catalog.pg_get_userbyid(a.grantee) IN ('anon','authenticated','service_role')
             AND a.privilege_type IN ('SELECT','INSERT','UPDATE','DELETE')) s;
  IF v_rowdml_fp IS DISTINCT FROM v_rowdml_fp0 OR v_rowdml_n <> v_rowdml_n0 THEN
    RAISE EXCEPTION 'U3_POSTCONDITION_FAILED (row-DML changed: % rows/% -> % rows/%)',
      v_rowdml_n0, v_rowdml_fp0, v_rowdml_n, v_rowdml_fp;
  END IF;
  IF v_rowdml_fp IS DISTINCT FROM '052198590dd92ba70ab07c99cbd21f15' OR v_rowdml_n <> 21 THEN
    RAISE EXCEPTION 'U3_POSTCONDITION_FAILED (row-DML is % rows/%, expected the ratified 21/052198590dd92ba70ab07c99cbd21f15)',
      v_rowdml_n, v_rowdml_fp;
  END IF;

  -- ★ THE ADMISSIBLE-PRESTATE CONTRACT, ENFORCED — not merely expressed in the CASE above.
  --   A mutation that relaxed EXACT_PRESTATE to ignore the table-Dxtm count SURVIVED the whole
  --   suite: it converged a partial state to a correct poststate, so every outcome assertion
  --   passed. Nothing insecure resulted — REVOKE is idempotent and the postconditions check the end
  --   state exhaustively — but "only exact pre/post are admissible" was a claim no assertion could
  --   falsify. It is now one.
  IF v_action = 'APPLIED' AND v_dxtm_before <> 492 THEN
    RAISE EXCEPTION 'U3_POSTCONDITION_FAILED (APPLY ran from a non-ratified prestate: % client Dxtm grants, expected exactly 492)', v_dxtm_before;
  END IF;
  IF v_action = 'RECOGNIZED' AND v_dxtm_before <> 0 THEN
    RAISE EXCEPTION 'U3_POSTCONDITION_FAILED (RECOGNIZE ran from a non-ratified poststate: % client Dxtm grants, expected exactly 0)', v_dxtm_before;
  END IF;

  RAISE NOTICE 'U3_ACTION=% state=% privileges=% rowdml_rows=%', v_action, v_state, v_privs, v_rowdml_n;
END
$u3$;

COMMIT;
