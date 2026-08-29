-- ════════════════════════════════════════════════════════════════════════════════════════════════
-- R-02 · READ-ONLY DATABASE IDENTITY CHECK
--
-- TARGET PROJECT : afterworth-nonprod
-- TARGET REF     : qxzeougbaarecaiiqsay
-- TARGET REGION  : us-west-2 (West US, Oregon)
--
-- RUN BY   : the operator, manually, in THAT project's Supabase SQL Editor.
-- RUN BY AI: never. Nothing here has been executed.
-- WRITES   : none. Both statements are SELECT over built-ins and catalog views.
--
-- ★ NEVER RUN THIS AGAINST yiaavvkulrpqkkbqhwit (application-facing) OR rpjjwkoezuihpobotbjh
--   (paused, retained). It is harmless read-only SQL, but running it there would produce evidence
--   labelled for the wrong project, and mislabelled evidence is worse than none.
--
-- ★ WHAT THIS CAN AND CANNOT PROVE — stated up front so the result is not over-read.
--
--   CAN:    that the session is a live Supabase-hosted PostgreSQL database; the execution identity
--           (current_user / session_user); the server version; and a STABLE FINGERPRINT that will
--           differ between projects and can be re-checked in every later session.
--
--   CANNOT: bind the session to the project ref by SQL alone. `current_database()` is `postgres`
--           on EVERY Supabase project, so it distinguishes nothing. Query 2 probes for a setting
--           that happens to carry the ref; if it returns no rows, that is expected and not a
--           failure. The binding then rests on the operator having opened the SQL Editor of that
--           specific project — which is a real, but human, link in the chain, and it is recorded
--           as such rather than dressed up as cryptographic proof.
--
-- ★ CAPABILITY ADJUDICATION IS DELIBERATELY ABSENT. No rolsuper, no rolbypassrls, no extension or
--   event-trigger inspection. Those decide hosted compatibility and belong to R02_3, not here.
-- ════════════════════════════════════════════════════════════════════════════════════════════════


-- ── QUERY 1 · SESSION AND SERVER IDENTITY ───────────────────────────────────────────────────────
-- One row, so the Supabase SQL Editor (which shows only the last result) returns everything.
-- Every function here is a PostgreSQL built-in; `current_setting(..., true)` returns NULL rather
-- than raising when a setting is absent, so no branch of this can error.
select
  current_database()                                as current_database,
  current_user                                      as current_user,
  session_user                                      as session_user,
  version()                                         as server_version,
  current_setting('server_version_num', true)       as server_version_num,
  current_setting('cluster_name', true)             as cluster_name,
  current_setting('TimeZone', true)                 as server_timezone,
  pg_postmaster_start_time()                        as postmaster_start_time,
  pg_backend_pid()                                  as backend_pid,
  inet_server_addr()                                as server_addr,
  inet_server_port()                                as server_port,
  now()                                             as observed_at;


-- ── QUERY 2 · DIRECT REF BINDING PROBE (may legitimately return zero rows) ──────────────────────
-- Looks for any server setting whose value carries the project ref. Some Supabase deployments
-- expose it, some do not. ZERO ROWS IS AN EXPECTED OUTCOME, not a failure — it means SQL could not
-- self-attest the ref and the binding rests on the SQL Editor context instead.
select
  name,
  setting
from pg_catalog.pg_settings
where setting like '%qxzeougbaarecaiiqsay%'
order by name;
