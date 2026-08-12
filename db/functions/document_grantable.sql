-- public.document_grantable(p_role text, p_sensitivity text) -> boolean
--
-- THE DOCUMENT DISCLOSURE CEILING. What a grantee role may be shown at a given document
-- sensitivity, regardless of what tier a grant happens to name. `can_access_document` re-checks it
-- at READ time against the document's CURRENT sensitivity, so reclassifying a document to `sealed`
-- takes effect immediately rather than only for grants issued afterwards.
--
-- ★ EXTRACTED TO A SOURCE FILE IN PHASE 11-B, AND IT HAD BEEN A SHADOW COPY UNTIL THEN.
--
-- Its only definition was inside `db/migrations/0002_20260620_access_grants.sql`, and
-- `db/tests/preamble_real_auth.sql` carried a hand-written copy so the SQL suite could stand the
-- schema up. `verifySqlAuthorization.mjs` refuses to run when the preamble shadows a production
-- body — but it resolved "production body" by searching `db/functions/` alone, so a function whose
-- source of truth lived in a migration was invisible to the guard. The ceiling, the document gate
-- and the asset ceiling all sat in that blind spot, unaudited, for their entire lives.
--
-- They happened to agree. Nothing would have said so if they had not — which is the same near-miss
-- as `asset_bracket_low`/`asset_bracket_high` in Phase 10-F, one directory over.
--
-- The body below is byte-identical to 0002's. Extraction is what makes it comparable, not a rewrite.
--
-- Unknown sensitivity denies. Source of truth — re-apply on DB reset.

create or replace function public.document_grantable(p_role text, p_sensitivity text)
returns boolean
language sql
immutable
as $$
  select case
    when p_sensitivity = 'sealed'     then false
    when p_sensitivity = 'restricted' then p_role = 'professional_delegate'
    when p_sensitivity in ('low','medium','high')
                                      then p_role in ('beneficiary','professional_delegate')
    else false                                   -- unknown sensitivity -> deny
  end;
$$;
