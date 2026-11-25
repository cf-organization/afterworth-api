-- safe_inviter_display_name — assertions decided INSIDE SQL.
--
-- Every expectation is compared with IS NOT DISTINCT FROM in the database, so no client-side
-- trimming (a shell, psql's own output trimming, a JavaScript .trim()) can turn a failing case into a
-- passing one. The block raises on the first mismatch and names it; a run that ends without an
-- exception has checked every row listed here. Run with ON_ERROR_STOP=1.
--
-- Mirror of the client's acceptance sanitizer (`sanitizeInviterDisplayName`: JavaScript trim, empty →
-- null, /\S@\S/ → null), plus the server's one intentionally stricter rule: > 200 characters → null.

do $assert$
declare
  r record;
  n_checked int := 0;
  failed text[] := '{}';
begin
  for r in
    select * from (values
      -- label                                  input                                                     expected
      ('null',                                  null::text,                                               null::text),
      ('empty',                                 '',                                                       null),
      ('spaces only',                           '   ',                                                    null),
      ('tabs and newlines only',                E'\t\n\r\t',                                              null),
      ('vertical tab + form feed only',         E'\x0B\x0C',                                              null),
      ('nonbreaking spaces only',               U&'\00A0\00A0',                                           null),
      ('zero-width no-break spaces only (BOM)', U&'\FEFF\FEFF',                                           null),
      ('ideographic + Zs-block spaces only',    U&'\3000\2003\202F',                                      null),
      ('line separators only',                  U&'\2028\2029',                                           null),
      ('valid name',                            'Dana Hartley',                                           'Dana Hartley'),
      ('valid name padded with spaces',         '  Dana Hartley  ',                                       'Dana Hartley'),
      ('valid name padded with tabs/newlines',  E'\t Dana Hartley \n',                                    'Dana Hartley'),
      ('valid name padded with NBSP',           U&'\00A0Dana Hartley\00A0',                               'Dana Hartley'),
      ('valid name padded with BOM',            U&'\FEFFDana Hartley\FEFF',                               'Dana Hartley'),
      ('inner whitespace is kept',              E'Dana\tHartley',                                         E'Dana\tHartley'),
      ('address-shaped',                        'dana@example.test',                                      null),
      ('address inside a name',                 'Dana <dana@example.test>',                               null),
      ('address-shaped, padded',                E'\t dana@example.test \n',                               null),
      ('a lone @ is not address-shaped',        '@',                                                      '@'),
      ('@ with space either side',              'a @ b',                                                  'a @ b'),
      ('exactly 200 characters',                repeat('x', 200),                                         repeat('x', 200)),
      ('201 characters',                        repeat('x', 201),                                         null),
      ('200 characters padded to 202',          ' ' || repeat('x', 200) || ' ',                           repeat('x', 200)),
      ('201 characters padded',                 ' ' || repeat('x', 201) || ' ',                           null),
      ('200 non-ASCII characters',              repeat(U&'\00E9', 200),                                   repeat(U&'\00E9', 200)),
      ('201 non-ASCII characters',              repeat(U&'\00E9', 201),                                   null)
    ) as t(label, input, expected)
  loop
    n_checked := n_checked + 1;
    if public.safe_inviter_display_name(r.input) is not distinct from r.expected then
      raise notice 'ok   %', r.label;
    else
      raise notice 'FAIL % — got % (expected %)', r.label,
        coalesce('"' || public.safe_inviter_display_name(r.input) || '"', 'NULL'),
        coalesce('"' || r.expected || '"', 'NULL');
      failed := failed || r.label;
    end if;
  end loop;
  if n_checked < 20 then
    raise exception 'FAIL vacuous — only % cases checked', n_checked;
  end if;
  if array_length(failed, 1) > 0 then
    raise exception '% of % sanitizer assertions FAILED: %', array_length(failed, 1), n_checked, array_to_string(failed, '; ');
  end if;
  raise notice 'ALL % SANITIZER ASSERTIONS PASSED (compared in SQL)', n_checked;
end
$assert$;
