-- Review item 2 (18 Nov): a weekly target counts things actually done, not tasks about them.
-- A case session = a case-prep calendar event that has passed, or a count he reports in a check-in.
-- For one day his reported count wins over the calendar (a cancelled session can stay on the calendar).

create table if not exists goal_progress (
  id bigint generated always as identity primary key,
  goal_id text not null references goals(id),
  day date not null,
  count int not null check (count >= 0),
  source text not null default 'checkin' check (source in ('checkin', 'voice', 'desk')),
  raw_event_id bigint references raw_events(id),
  note text,
  created_at timestamptz not null default now(),
  unique (goal_id, day, source)
);
alter table goal_progress enable row level security;
revoke all on goal_progress from anon, authenticated;

-- Which calendar titles count as a session of a targeted action.
insert into kv(key, value) values ('goal_session_patterns',
  jsonb_build_object('action:career:1', '(case prep|mock case)'))
on conflict (key) do nothing;

create or replace function brain_log_progress(p_goal_id text, p_day date, p_count int,
  p_raw_event_id bigint default null, p_note text default null, p_source text default 'checkin') returns jsonb
language plpgsql set search_path = public, pg_temp as $$
begin
  if not exists (select 1 from goals where id = p_goal_id) then raise exception 'goal unknown: %', p_goal_id; end if;
  insert into goal_progress (goal_id, day, count, source, raw_event_id, note)
  values (p_goal_id, p_day, p_count, coalesce(p_source, 'checkin'), p_raw_event_id, p_note)
  on conflict (goal_id, day, source) do update set count = excluded.count, raw_event_id = excluded.raw_event_id,
    note = excluded.note, created_at = now();
  return jsonb_build_object('goal', p_goal_id, 'day', p_day, 'count', p_count);
end $$;

-- Sessions per day for one targeted action between two dates (New York days).
create or replace function goal_sessions(p_goal_id text, p_from date, p_to date) returns table(day date, sessions int, source text)
language sql stable set search_path = public, pg_temp as $$
  with cal as (
    select (c.starts_at at time zone 'America/New_York')::date d, count(*)::int n
    from calendar_events c, kv
    where kv.key = 'goal_session_patterns' and kv.value ? p_goal_id
      and c.title ~* (kv.value->>p_goal_id)
      and coalesce(c.ends_at, c.starts_at + interval '1 hour') < now()
      and (c.starts_at at time zone 'America/New_York')::date between p_from and p_to
    group by 1
  ), act as (
    select (b.starts_at at time zone 'America/New_York')::date d, count(*)::int n
    from time_blocks b where b.goal_id = p_goal_id and b.kind = 'actual'
      and (b.starts_at at time zone 'America/New_York')::date between p_from and p_to
    group by 1
  ), rep as (
    select g.day d, max(g.count)::int n from goal_progress g
    where g.goal_id = p_goal_id and g.day between p_from and p_to group by 1
  ), days as (select d from cal union select d from act union select d from rep)
  select days.d,
         coalesce(rep.n, coalesce(cal.n, 0) + coalesce(act.n, 0)),
         case when rep.n is not null then 'reported' else 'calendar' end
  from days left join cal on cal.d = days.d left join act on act.d = days.d left join rep on rep.d = days.d
  order by 1
$$;

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
                       'done', (select coalesce(sum(sessions), 0) from goal_sessions(a.id, s, s + 6)),
                       'days', (select coalesce(jsonb_agg(jsonb_build_object('day', day, 'sessions', sessions, 'source', source)), '[]')
                                from goal_sessions(a.id, s, s + 6)))), '[]')
                    from goals a where a.parent_id = g.id and a.weekly_target is not null),
        'actions', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'title', a.title) order by a.sort), '[]')
                    from goals a where a.parent_id = g.id and a.status = 'active')
      ) order by g.sort), '[]') from goals g where g.kind = 'box' and g.status = 'active'));
end $$;

do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('brain_log_progress','goal_sessions','desk_goals') loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
