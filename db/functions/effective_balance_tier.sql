-- public.effective_balance_tier(p_estate, p_uid) -> text
--
-- ★ MIRROR of migration 0066. The migration is the authority; this copy exists for the bundle builders
-- and the SQL authorization harness, and test/beneficiaryConnectorDisclosure.test.ts holds the two
-- byte-identical (whitespace-normalised).
--
-- THE ONE ANSWER PER SESSION for the balances tier, used by discovery and the total reader alike: an
-- exact tier without a CURRENT aal2 session degrades to the category bracket, so the anti-inference rule
-- is evaluated against the breakdown the viewer can actually see, through either reader.

create or replace function public.effective_balance_tier(p_estate uuid, p_uid uuid)
 returns text
 language plpgsql
 stable
 security definer
 set search_path to 'public'
as $function$
declare v_bal text := public.connector_disclosure_tier(p_estate, p_uid, 'account_balances');
begin
  if v_bal in ('limited_detail', 'full_detail') and not public.aal2_is_current() then
    return 'category_summary';
  end if;
  return v_bal;
end;
$function$;
revoke execute on function public.effective_balance_tier(uuid, uuid) from public, anon, authenticated;
