-- Core model rebuild, step 3b (17 Nov 2026): per-view read functions for desk v2 and voice.
-- Every derived value (mode, rollover, overdue, Big 3, next move, stage, quiet days, last contact,
-- staleness) is computed here once. Additive only; brain_desk stays as is for desk v1.

create or replace function ny_now() returns timestamp language sql stable as $$
  select now() at time zone 'America/New_York'
$$;

-- One event row, with end time honesty and clashes.
create or replace function desk_event_json(c calendar_events) returns jsonb language sql stable
set search_path = public, pg_temp as $$
  select jsonb_build_object('uid', c.uid, 'title', c.title, 'location', c.location,
    'start', c.starts_at, 'end', coalesce(c.ends_at, c.starts_at + interval '1 hour'), 'end_known', c.ends_at is not null,
    'is_class', c.title ~ '^[A-Z][A-Z0-9]{1,6} B$',
    'clashes_with', (select jsonb_agg(o.title) from calendar_events o
       where o.uid <> c.uid and o.starts_at < coalesce(c.ends_at, c.starts_at + interval '1 hour')
         and coalesce(o.ends_at, o.starts_at + interval '1 hour') > c.starts_at))
$$;

-- One commitment row as every view shows it.
create or replace function desk_commitment_json(c commitments) returns jsonb language sql stable
set search_path = public, pg_temp as $$
  select jsonb_build_object('id', c.id, 'action', c.action, 'status', c.status, 'due', c.due_at,
    'overdue', c.due_at is not null and c.due_at < (now() at time zone 'America/New_York')::date and c.status in ('open', 'needs_review', 'unknown'),
    'owner', c.owner, 'owner_name', (select name from entities where id = c.owner),
    'for', c.beneficiary, 'for_name', (select name from entities where id = c.beneficiary),
    'pursuit_id', c.pursuit_id, 'pursuit', (select title from pursuits where id = c.pursuit_id),
    'goal_id', coalesce(c.goal_id, (select goal_id from pursuits where id = c.pursuit_id)),
    'estimate_min', c.estimate_min, 'source', c.source, 'in_google', c.gtask_id is not null,
    'completed_at', c.completed_at, 'created', c.created_at)
$$;

-- Mode and day the control room should show at a moment. After the last event of the day (and after
-- 5pm), or from 9pm, it turns to tomorrow.
create or replace function desk_mode(p_now timestamptz default now()) returns jsonb language sql stable
set search_path = public, pg_temp as $$
  with t as (select (p_now at time zone 'America/New_York') as l),
  d as (select l, l::date as today, extract(hour from l)::int as h,
          exists (select 1 from calendar_events where starts_at >= p_now
                  and starts_at < ((l::date + 1)::timestamp at time zone 'America/New_York')) as more_today
        from t)
  select jsonb_build_object(
    'mode', case when h < 5 or h >= 22 then 'night' when h < 11 then 'morning' when h < 17 then 'day' else 'evening' end,
    'day', case when h >= 21 or (h >= 17 and not more_today) then today + 1 else today end,
    'rolled_to_tomorrow', h >= 21 or (h >= 17 and not more_today),
    'local_time', to_char(l, 'FMHH12:MI am'))
  from d
$$;

create or replace function desk_control(p_now timestamptz default now()) returns jsonb language plpgsql stable
set search_path = public, pg_temp as $$
declare m jsonb := desk_mode(p_now); d date := (m->>'day')::date;
begin
  return jsonb_build_object(
    'mode', m,
    'events', (select coalesce(jsonb_agg(desk_event_json(c) order by c.starts_at), '[]') from calendar_events c
               where c.starts_at >= (d::timestamp at time zone 'America/New_York')
                 and c.starts_at < ((d + 1)::timestamp at time zone 'America/New_York')),
    'big3', (select coalesce(jsonb_agg(desk_commitment_json(c) || jsonb_build_object('rank', p.rank) order by p.rank), '[]')
             from day_priorities p join commitments c on c.id = p.commitment_id where p.day = d),
    'big3_set', exists (select 1 from day_priorities where day = d),
    'tasks', (select coalesce(jsonb_agg(desk_commitment_json(c) order by c.due_at nulls last, c.id), '[]') from commitments c
              where c.owner = 'me' and c.status in ('open', 'needs_review', 'unknown')),
    'owed_to_me', (select coalesce(jsonb_agg(desk_commitment_json(c) order by c.due_at nulls last), '[]') from commitments c
                   where c.beneficiary = 'me' and c.owner <> 'me' and c.status = 'open'),
    -- suggestions that still need his yes and are not just a copy of an "owed to you" item
    'needs_yes', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'kind', p.kind, 'title', p.title, 'body', left(p.body, 300),
                    'commitment_id', p.related->>'commitment_id', 'created', p.created_at) order by p.priority, p.created_at desc), '[]')
                  from proposals p
                  left join commitments c on c.id = nullif(p.related->>'commitment_id', '')::bigint
                  where p.status = 'pending' and p.kind in ('followup', 'calendar', 'review')
                    and not (p.kind = 'followup' and coalesce(c.owner, '') <> 'me' and c.beneficiary = 'me')),
    'briefings', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'title', title, 'body', body)), '[]') from proposals
                  where kind = 'briefing' and status = 'pending'
                    and related->>'calendar_uid' in (select uid from calendar_events where starts_at >= (d::timestamp at time zone 'America/New_York')
                                                      and starts_at < ((d + 1)::timestamp at time zone 'America/New_York'))),
    'overdue_count', (select count(*) from commitments where owner = 'me' and status in ('open', 'needs_review', 'unknown')
                      and due_at < (p_now at time zone 'America/New_York')::date),
    'health', desk_health());
end $$;

create or replace function desk_health() returns jsonb language sql stable set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'last_compile', (select max(finished_at) from runs where agent = 'compiler' and status = 'ok'),
    'last_compile_status', (select status from runs where agent = 'compiler' order by started_at desc limit 1),
    'last_compiled_source', (select max(compiled_at) from raw_events),
    'last_source', (select max(received_at) from raw_events),
    'waiting', (select count(*) from raw_events where status in ('pending', 'processing', 'failed')))
$$;

-- Pursuit tree with next move, honest activity and stage.
create or replace function desk_workbench() returns jsonb language sql stable set search_path = public, pg_temp as $$
  with recursive tree as (
    select id, id as root from pursuits
    union all select p.id, t.root from pursuits p join tree t on p.parent_id = t.id
  ),
  act as (
    select p.id,
      greatest(p.updated_at,
        (select max(greatest(c.updated_at, c.created_at)) from commitments c join tree t on t.id = c.pursuit_id where t.root = p.id),
        (select max(r.occurred_at) from story_events se join raw_events r on r.id = se.raw_event_id where se.story_id = p.story_id)) as last_activity
    from pursuits p
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id, 'parent_id', p.parent_id, 'kind', p.kind, 'title', p.title, 'goal_id', p.goal_id,
      'stage', p.stage, 'deadline', p.deadline, 'status', p.status,
      'summary', p.summary, 'summary_at', p.summary_at,
      'summary_stale', p.summary_at is null or p.summary_at < now() - interval '24 hours',
      'last_activity', a.last_activity,
      'quiet_days', (now()::date - a.last_activity::date),
      'open_moves', (select count(*) from commitments c join tree t on t.id = c.pursuit_id
                     where t.root = p.id and c.owner = 'me' and c.status in ('open', 'needs_review', 'unknown')),
      'next_move', (select desk_commitment_json(c) from commitments c join tree t on t.id = c.pursuit_id
                    where t.root = p.id and c.owner = 'me' and c.status = 'open'
                    order by c.due_at nulls last, c.created_at limit 1),
      'ask_close', p.status = 'active' and a.last_activity < now() - interval '14 days'
                   and not exists (select 1 from commitments c join tree t on t.id = c.pursuit_id
                                   where t.root = p.id and c.status = 'open'),
      'people', (select coalesce(jsonb_agg(distinct jsonb_build_object('id', e.id, 'name', e.name)), '[]')
                 from edges x join entities e on e.id = x.src and e.type = 'person'
                 where p.org_entity is not null and x.rel = 'works_at'
                   and (x.dst = p.org_entity or x.dst in (select src from edges where rel = 'office_of' and dst = p.org_entity))),
      'lessons', (select coalesce(jsonb_agg(jsonb_build_object('id', l.id, 'title', l.title, 'description', l.description,
                    'last_seen', l.last_seen) order by l.last_seen desc nulls last), '[]')
                  from patterns l where l.pursuit_id = p.id and l.status = 'active'
                    and (l.last_seen is null or l.last_seen > now() - interval '21 days'))
    ) order by p.parent_id nulls first, (p.status = 'active') desc, a.last_activity desc nulls last), '[]')
  from pursuits p join act a on a.id = p.id
$$;

-- People: the sky (orgs) when p_org is null, otherwise one constellation with every person in it.
create or replace function desk_people(p_org text default null) returns jsonb language sql stable
set search_path = public, pg_temp as $$
  with person_org as (
    select e.id, e.name,
      coalesce((select o.dst from edges w join edges o on o.src = w.dst and o.rel = 'office_of'
                where w.src = e.id and w.rel = 'works_at' limit 1),
               (select w.dst from edges w where w.src = e.id and w.rel = 'works_at' limit 1)) as org
    from entities e where e.type = 'person'
  ),
  last_contact as (select entity_id, max(at) as at, count(*) as n from interactions group by 1)
  select case when p_org is null then jsonb_build_object(
      'orgs', (select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name, 'people', x.n,
                 'active_30d', x.active, 'last', x.last) order by x.active desc, x.n desc), '[]')
               from (select org, count(*) n, max(lc.at) last,
                       count(*) filter (where lc.at > now() - interval '30 days') active
                     from person_org po left join last_contact lc on lc.entity_id = po.id
                     where org is not null group by org) x join entities o on o.id = x.org),
      'unplaced', (select count(*) from person_org where org is null))
    else jsonb_build_object(
      'org', (select jsonb_build_object('id', id, 'name', name) from entities where id = p_org),
      'people', (select coalesce(jsonb_agg(jsonb_build_object('id', po.id, 'name', po.name,
                   'last_contact', lc.at, 'contacts_n', coalesce(lc.n, 0),
                   'i_owe', exists (select 1 from commitments c where c.owner = 'me' and c.beneficiary = po.id and c.status = 'open'),
                   'owes_me', exists (select 1 from commitments c where c.owner = po.id and c.beneficiary = 'me' and c.status = 'open'))
                   order by lc.at desc nulls last), '[]')
                 from person_org po left join last_contact lc on lc.entity_id = po.id where po.org = p_org),
      'links', (select coalesce(jsonb_agg(distinct jsonb_build_object('a', x.src, 'b', x.dst, 'rel', x.rel)), '[]')
                from edges x join person_org a on a.id = x.src join person_org b on b.id = x.dst
                where a.org = p_org and b.org = p_org and x.src <> x.dst))
    end
$$;

create or replace function desk_person(p_id text) returns jsonb language sql stable set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'entity', (select to_jsonb(e) - 'created_at' from entities e where id = p_id),
    'facts', (select coalesce(jsonb_agg(jsonb_build_object('predicate', predicate, 'value', value, 'since', valid_from::date)
               order by valid_from desc), '[]') from current_facts where subject = p_id),
    'contacts', (select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'value', value)), '[]') from contacts where entity_id = p_id),
    'first_contact', (select jsonb_build_object('at', at, 'channel', channel, 'title', title) from interactions
                      where entity_id = p_id order by at limit 1),
    'last_contact', (select jsonb_build_object('at', at, 'channel', channel, 'title', title) from interactions
                     where entity_id = p_id order by at desc limit 1),
    'timeline', (select coalesce(jsonb_agg(jsonb_build_object('at', at, 'channel', channel, 'title', title, 'source_event', raw_event_id)
                  order by at desc), '[]') from interactions where entity_id = p_id),
    'introduced_by', (select coalesce(jsonb_agg(distinct x.src), '[]') from edges x where x.dst = p_id and x.rel in ('introduced', 'referred')),
    'connections', (select coalesce(jsonb_agg(distinct jsonb_build_object('rel', x.rel, 'with', case when x.src = p_id then x.dst else x.src end)), '[]')
                    from edges x where p_id in (x.src, x.dst) and 'me' not in (x.src, x.dst)),
    'i_owe', (select coalesce(jsonb_agg(desk_commitment_json(c)), '[]') from commitments c
              where c.owner = 'me' and c.beneficiary = p_id and c.status in ('open', 'needs_review', 'unknown')),
    'owes_me', (select coalesce(jsonb_agg(desk_commitment_json(c)), '[]') from commitments c
                where c.owner = p_id and c.beneficiary = 'me' and c.status = 'open'))
$$;

-- Planning: one week of events and blocks, the backlog, and utilization.
create or replace function desk_week(p_start date default null) returns jsonb language plpgsql stable
set search_path = public, pg_temp as $$
declare
  s date := coalesce(p_start, (now() at time zone 'America/New_York')::date
                      - (extract(isodow from now() at time zone 'America/New_York')::int - 1));
  t0 timestamptz := s::timestamp at time zone 'America/New_York';
  t1 timestamptz := (s + 7)::timestamp at time zone 'America/New_York';
begin
  return jsonb_build_object(
    'week_start', s,
    'events', (select coalesce(jsonb_agg(desk_event_json(c) order by c.starts_at), '[]') from calendar_events c
               where c.starts_at >= t0 and c.starts_at < t1),
    'events_without_end', (select count(*) from calendar_events where starts_at >= t0 and starts_at < t1 and ends_at is null),
    'blocks', (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'title', b.title, 'start', b.starts_at, 'end', b.ends_at,
                 'kind', b.kind, 'commitment_id', b.commitment_id, 'pursuit_id', b.pursuit_id,
                 'goal_id', coalesce(b.goal_id, (select goal_id from pursuits where id = b.pursuit_id)),
                 'in_calendar', b.gcal_event_id is not null) order by b.starts_at), '[]')
               from time_blocks b where b.starts_at >= t0 and b.starts_at < t1 and coalesce(b.gcal_state, '') <> 'to_delete'),
    'backlog', (select coalesce(jsonb_agg(desk_commitment_json(c) order by c.due_at nulls last), '[]') from commitments c
                where c.owner = 'me' and c.status = 'open'
                  and not exists (select 1 from time_blocks b where b.commitment_id = c.id and b.starts_at >= t0)),
    'goal_actions', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'title', title, 'box', box_key,
                       'weekly_target', weekly_target, 'unit', unit) order by box_key, sort), '[]')
                     from goals where kind = 'action' and status = 'active'),
    -- waking hours 8am to 10pm, 7 days = 98h; events and planned blocks use it up
    'utilization', jsonb_build_object(
       'awake_hours', 98,
       'event_hours', round((select coalesce(sum(extract(epoch from coalesce(ends_at, starts_at + interval '1 hour') - starts_at)), 0) / 3600
                             from calendar_events where starts_at >= t0 and starts_at < t1)::numeric, 1),
       'planned_hours', round((select coalesce(sum(extract(epoch from ends_at - starts_at)), 0) / 3600
                               from time_blocks where kind = 'planned' and starts_at >= t0 and starts_at < t1)::numeric, 1),
       'actual_hours', round((select coalesce(sum(extract(epoch from ends_at - starts_at)), 0) / 3600
                              from time_blocks where kind = 'actual' and starts_at >= t0 and starts_at < t1)::numeric, 1)),
    'hours_by_box', (select coalesce(jsonb_object_agg(box, hrs), '{}') from (
       select coalesce(g.box_key, 'unassigned') box, round((sum(extract(epoch from b.ends_at - b.starts_at)) / 3600)::numeric, 1) hrs
       from time_blocks b left join goals g on g.id = coalesce(b.goal_id, (select goal_id from pursuits where id = b.pursuit_id))
       where b.starts_at >= t0 and b.starts_at < t1 group by 1) x));
end $$;

-- Mirror: explicit status per goal box for a month.
create or replace function desk_review(p_month date default null) returns jsonb language plpgsql stable
set search_path = public, pg_temp as $$
declare
  m date := date_trunc('month', coalesce(p_month, (now() at time zone 'America/New_York')::date))::date;
  t0 timestamptz := m::timestamp at time zone 'America/New_York';
  t1 timestamptz := (m + interval '1 month')::timestamp at time zone 'America/New_York';
begin
  return jsonb_build_object(
    'month', m,
    'boxes', (select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'box', g.box_key, 'title', g.title,
       'done', (select count(*) from commitments c left join pursuits p on p.id = c.pursuit_id
                where coalesce(c.goal_id, p.goal_id) in (select id from goals where id = g.id or parent_id = g.id)
                  and c.status = 'done' and c.completed_at >= t0 and c.completed_at < t1),
       'open', (select count(*) from commitments c left join pursuits p on p.id = c.pursuit_id
                where coalesce(c.goal_id, p.goal_id) in (select id from goals where id = g.id or parent_id = g.id)
                  and c.owner = 'me' and c.status = 'open'),
       'hours', (select round((coalesce(sum(extract(epoch from b.ends_at - b.starts_at)), 0) / 3600)::numeric, 1) from time_blocks b
                 left join pursuits p on p.id = b.pursuit_id
                 where coalesce(b.goal_id, p.goal_id) in (select id from goals where id = g.id or parent_id = g.id)
                   and b.starts_at >= t0 and b.starts_at < t1),
       'targets', (select coalesce(jsonb_agg(jsonb_build_object('action', a.title, 'weekly_target', a.weekly_target, 'unit', a.unit)), '[]')
                   from goals a where a.parent_id = g.id and a.weekly_target is not null)
      ) order by g.sort), '[]') from goals g where g.kind = 'box'),
    'promises', jsonb_build_object(
       'kept', (select count(*) from commitments where owner = 'me' and status = 'done' and completed_at >= t0 and completed_at < t1),
       'dropped', (select count(*) from commitments where owner = 'me' and status = 'dropped' and completed_at >= t0 and completed_at < t1),
       'late', (select count(*) from commitments where owner = 'me' and status = 'done' and completed_at >= t0 and completed_at < t1
                and due_at is not null and completed_at::date > due_at),
       'open_overdue', (select count(*) from commitments where owner = 'me' and status in ('open', 'needs_review', 'unknown')
                        and due_at < (now() at time zone 'America/New_York')::date)));
end $$;

-- Trust: stale facts by type, possible duplicates, corrections and what they changed, compile log.
create or replace function desk_trust() returns jsonb language sql stable set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'stale', (select coalesce(jsonb_agg(jsonb_build_object('fact_id', f.id, 'subject', coalesce(e.name, f.subject),
                'predicate', f.predicate, 'value', left(f.value, 160), 'age_days', now()::date - f.valid_from::date,
                'limit_days', d.days) order by now()::date - f.valid_from::date - d.days desc), '[]')
              from current_facts f join fact_decay d on d.predicate = split_part(f.predicate, ':', 1)
              left join entities e on e.id = f.subject
              where f.valid_from < now() - make_interval(days => d.days)),
    'possible_duplicates', (select coalesce(jsonb_agg(jsonb_build_object('a', a.id, 'a_name', a.name, 'b', b.id, 'b_name', b.name)), '[]')
              from entities a join entities b on a.id < b.id and a.type = b.type and a.type = 'person'
              where (lower(split_part(a.name, ' ', 1)) = lower(split_part(b.name, ' ', 1)) and (a.name !~ ' ' or b.name !~ ' '))
                 or a.summary ilike '%POSSIBLE DUPLICATE OF ' || b.id || '%' or b.summary ilike '%POSSIBLE DUPLICATE OF ' || a.id || '%'),
    'corrections', (select coalesce(jsonb_agg(jsonb_build_object('source_event', r.id, 'title', r.title, 'at', r.occurred_at,
                      'status', r.status,
                      'changed', (select coalesce(jsonb_agg(cl.summary), '[]') from change_log cl where cl.raw_event_id = r.id)) order by r.occurred_at desc), '[]')
                    from (select * from raw_events where provider in ('correction', 'confirmation') order by occurred_at desc limit 10) r),
    'runs', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'agent', agent, 'started', started_at, 'finished', finished_at,
               'status', status, 'note', error) order by started_at desc), '[]')
             from (select * from runs order by started_at desc limit 10) x),
    'health', desk_health())
$$;

do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('ny_now','desk_event_json','desk_commitment_json','desk_mode',
             'desk_control','desk_health','desk_workbench','desk_people','desk_person','desk_week','desk_review','desk_trust') loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
