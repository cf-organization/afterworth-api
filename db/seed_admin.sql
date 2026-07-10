-- seed_admin.sql — run ONCE by Christ in the Supabase SQL editor. NOT a migration (not replayed).
--
-- Replace <ADMIN_UID> with the founding admin's auth.users.id AT RUN TIME. NEVER commit a real uid:
-- the version-controlled file keeps the <ADMIN_UID> placeholder; the actual uid exists only in your
-- executed copy and the resulting public.admins row. Running this file verbatim (with the
-- placeholder) will error on the invalid uuid — that is intentional (it is a template).

insert into public.admins (user_id, note)
values ('<ADMIN_UID>', 'Christ — founding admin')
on conflict do nothing;
