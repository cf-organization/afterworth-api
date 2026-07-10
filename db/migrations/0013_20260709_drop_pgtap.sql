-- 0013_20260709_drop_pgtap — remove the pgTAP test-framework extension from production.
--
-- CONTEXT: pgTAP (a unit-test framework) was installed live and left client-readable artifacts in
-- prod — notably the views `pg_all_foreign_keys` and `tap_funky` carrying FULL DML granted to anon
-- (a Supabase-extension-install default). Nothing in either repo references pgTAP (grep across
-- afterworth-api = zero hits; the repo has no CI), so it is dead weight + surface area, not a
-- dependency. Approved for removal 2026-07-09.
--
-- PLAIN DROP FIRST (RESTRICT semantics): removes the extension and every object it owns. This will
-- ERROR if some NON-extension object depends on a pgTAP object. If it errors, STOP — do NOT switch to
-- CASCADE blind; paste the error so the dependent objects can be enumerated and reviewed before any
-- CASCADE. (Given zero repo/CI references, a clean RESTRICT drop is expected.)
--
-- Idempotent via IF EXISTS. Separate from 0012 so a dependency-blocked drop cannot roll back the sweep.

begin;

drop extension if exists pgtap;

commit;
