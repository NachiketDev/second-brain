-- Planned time blocks go to a separate "Brain" calendar in his Google Calendar (decided 17 Nov, built 22 Nov).
-- No invitees, so nothing reaches anyone else. The brain writes; it never reads his other calendars this way.
-- poll pushes brain_gcal_queue every 15 minutes and reports each result with brain_gcal_pushed.

alter table time_blocks add column if not exists gcal_error text;
alter table time_blocks add column if not exists gcal_tries int not null default 0;

-- Blocks whose calendar copy needs a write. Old blocks (ended more than a day ago) are not created late.
-- Failed writes are retried up to 5 times.
create or replace function brain_gcal_queue() returns jsonb
language sql stable set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', b.id, 'state', case when b.gcal_state = 'error' then case when b.gcal_event_id is null then 'to_create' else 'to_update' end else b.gcal_state end,
      'event_id', b.gcal_event_id, 'title', coalesce(b.title, 'Planned block'),
      'start', b.starts_at, 'end', b.ends_at,
      'notes', concat_ws(' · ', (select p.title from pursuits p where p.id = b.pursuit_id),
                                (select g.title from goals g where g.id = b.goal_id), 'Planned on your desk'))
    order by b.starts_at), '[]')
  from time_blocks b
  where b.kind = 'planned'
    and (b.gcal_state in ('to_create', 'to_update', 'to_delete') or (b.gcal_state = 'error' and b.gcal_tries < 5))
    and (b.gcal_state = 'to_delete' or b.gcal_event_id is not null or b.ends_at > now() - interval '1 day');
$$;

create or replace function brain_gcal_pushed(p_id bigint, p_event_id text default null, p_error text default null) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare b time_blocks;
begin
  select * into b from time_blocks where id = p_id for update;
  if not found then return jsonb_build_object('id', p_id, 'result', 'gone'); end if;
  if p_error is not null then
    update time_blocks set gcal_state = case when b.gcal_state = 'to_delete' then 'to_delete' else 'error' end,
      gcal_error = left(p_error, 500), gcal_tries = b.gcal_tries + 1, updated_at = now() where id = p_id;
    return jsonb_build_object('id', p_id, 'result', 'error');
  end if;
  if b.gcal_state = 'to_delete' then
    delete from time_blocks where id = p_id;
    return jsonb_build_object('id', p_id, 'result', 'deleted');
  end if;
  update time_blocks set gcal_event_id = coalesce(p_event_id, b.gcal_event_id), gcal_state = 'synced',
    gcal_error = null, gcal_tries = 0, updated_at = now() where id = p_id;
  return jsonb_build_object('id', p_id, 'result', 'synced');
end $$;

revoke execute on function brain_gcal_queue() from public, anon, authenticated;
revoke execute on function brain_gcal_pushed(bigint, text, text) from public, anon, authenticated;
grant execute on function brain_gcal_queue() to service_role;
grant execute on function brain_gcal_pushed(bigint, text, text) to service_role;
