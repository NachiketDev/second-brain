-- Lock the brain to server-side access only (edge functions use service_role; the Claude task uses the
-- Supabase connector, which runs as an admin). Nothing is readable or callable with the public anon key.

-- Views run with the caller's permissions, so table RLS applies to them too.
alter view current_facts set (security_invoker = true);
alter view recent_changes set (security_invoker = true);
alter view open_loops set (security_invoker = true);

-- No direct table access for API roles at all.
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

-- Functions: callable only by service_role (and the owner).
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on all functions in schema public to service_role;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
alter default privileges in schema public revoke all on tables from anon, authenticated;

-- Pin search_path on every brain function.
do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.prokind = 'f' loop
    execute format('alter function %s set search_path = public, pg_temp', f.sig);
  end loop;
end $$;
