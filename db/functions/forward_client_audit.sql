-- public.forward_client_audit(p_action text, p_estate uuid, p_table text, p_target uuid,
--                             p_meta jsonb, p_client_ts timestamptz) -> void
--
-- The ONLY client-reachable audit write path. iOS emits CLIENT-ONLY telemetry events (UI / pre-auth /
-- diagnostics); this RPC funnels them into audit_logs. write_audit's direct EXECUTE was revoked from
-- authenticated (0011) precisely so this gated funnel is the sole door.
--
-- ALL GATES LIVE INSIDE THIS FUNCTION (the DEFINER-door lesson): api/audit.ts is only an outer layer, and
-- a DIRECT PostgREST caller (…/rest/v1/rpc/forward_client_audit) hits the exact same gates. SECURITY
-- DEFINER, but every trust decision is enforced here — the definer bypass buys nothing for an attacker.
--
-- Trust model: actor_id = auth.uid() (server-derived, spoof-proof — the client's asserted id is IGNORED);
-- source is HARDCODED 'ios_forward' (never a parameter); created_at is the server default; ip/user_agent
-- are read best-effort from request.headers (NOT parameters — a param would be spoofable via direct
-- PostgREST). KNOWN LIMITATION: via the Vercel endpoint, request.headers carry Vercel's egress IP +
-- supabase-js user-agent, NOT the device's (telemetry-grade, accepted). Via direct PostgREST they are the
-- direct caller's. The client timestamp is folded into metadata as client_ts — never the authoritative time.
--
-- Gate order: no anon -> allowlist (client-only vocab; server-reserved actions reject naturally) ->
-- metadata size cap -> insert.
-- GRANT EXECUTE to authenticated ONLY (revoked from PUBLIC/anon). Source of truth — re-apply on reset.

create or replace function public.forward_client_audit(
  p_action    text,
  p_estate    uuid,
  p_table     text,
  p_target    uuid,
  p_meta      jsonb,
  p_client_ts timestamptz
)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
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
$function$;

-- Client-reachable, but gated inside: authenticated ONLY (never PUBLIC/anon).
revoke execute on function public.forward_client_audit(text, uuid, text, uuid, jsonb, timestamptz) from public, anon;
grant execute on function public.forward_client_audit(text, uuid, text, uuid, jsonb, timestamptz) to authenticated;
