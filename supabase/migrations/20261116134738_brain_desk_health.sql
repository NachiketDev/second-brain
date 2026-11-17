create or replace function public.brain_desk_health() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('last_compiled', (select max(compiled_at) from raw_events), 'last_source', (select max(received_at) from raw_events),
    'waiting', (select count(*) from raw_events where compiled_at is null and coalesce(status,'') not in ('skipped','error')));
$$;
revoke all on function public.brain_desk_health() from public, anon, authenticated;
grant execute on function public.brain_desk_health() to service_role;
