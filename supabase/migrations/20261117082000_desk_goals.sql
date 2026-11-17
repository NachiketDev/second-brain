-- Desk v2: goal boxes for the control room, filling toward this week's targets. Additive.
create or replace function desk_goals(p_now timestamptz default now()) returns jsonb language plpgsql stable
set search_path = public, pg_temp as $$
declare
  today date := (p_now at time zone 'America/New_York')::date;
  s date := today - (extract(isodow from today)::int - 1);
  t0 timestamptz := s::timestamp at time zone 'America/New_York';
  t1 timestamptz := (s + 7)::timestamp at time zone 'America/New_York';
begin
  return jsonb_build_object(
    'week_start', s,
    'center', (select title from goals where id = 'center'),
    'boxes', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', g.id, 'box', g.box_key, 'title', g.title, 'tracker', g.tracker,
        'done_week', (select count(*) from commitments c left join pursuits p on p.id = c.pursuit_id
                      where coalesce(c.goal_id, p.goal_id) in (select id from goals where id = g.id or parent_id = g.id)
                        and c.status = 'done' and c.completed_at >= t0 and c.completed_at < t1),
        'open', (select count(*) from commitments c left join pursuits p on p.id = c.pursuit_id
                 where coalesce(c.goal_id, p.goal_id) in (select id from goals where id = g.id or parent_id = g.id)
                   and c.owner = 'me' and c.status in ('open', 'needs_review', 'unknown')),
        'hours_week', (select round((coalesce(sum(extract(epoch from b.ends_at - b.starts_at)), 0) / 3600)::numeric, 1)
                       from time_blocks b left join pursuits p on p.id = b.pursuit_id
                       where coalesce(b.goal_id, p.goal_id) in (select id from goals where id = g.id or parent_id = g.id)
                         and b.starts_at >= t0 and b.starts_at < t1),
        'targets', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'action', a.title, 'target', a.weekly_target,
                       'unit', a.unit,
                       'done', (select count(*) from commitments c where c.goal_id = a.id and c.status = 'done'
                                and c.completed_at >= t0 and c.completed_at < t1)
                             + (select count(*) from time_blocks b where b.goal_id = a.id and b.kind = 'actual'
                                and b.starts_at >= t0 and b.starts_at < t1))), '[]')
                    from goals a where a.parent_id = g.id and a.weekly_target is not null),
        'actions', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'title', a.title) order by a.sort), '[]')
                    from goals a where a.parent_id = g.id and a.status = 'active')
      ) order by g.sort), '[]') from goals g where g.kind = 'box' and g.status = 'active'));
end $$;
revoke execute on function desk_goals(timestamptz) from public, anon, authenticated;
grant execute on function desk_goals(timestamptz) to service_role;
