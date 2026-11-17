create or replace function public.brain_desk(p_day date default null)
returns jsonb language sql stable security definer set search_path = public as $$
with
d as (select coalesce(p_day, (now() at time zone 'America/New_York')::date) as day),
w as (select day, day - (extract(isodow from day)::int - 1) as wk from d),
self_ppl as (
  select e.id, e.name,
    (select x.dst from edges x where x.src = e.id and x.rel = 'works_at' limit 1) as org,
    (select x.dst from edges x where x.src = e.id and x.rel in ('teammate_on','member_of') limit 1) as grp,
    (select count(*) from edges x where (x.src = 'me' and x.dst = e.id) or (x.dst = 'me' and x.src = e.id)) as direct,
    (select count(distinct x.raw_event_id) from edges x where x.src = e.id or x.dst = e.id) as mentions,
    (select max(r.occurred_at) from edges x join raw_events r on r.id = x.raw_event_id where x.src = e.id or x.dst = e.id) as last_at
  from entities e where e.type = 'person'
)
select jsonb_build_object(
  'day', (select day from d),
  'week_start', (select wk from w),
  'generated_at', now(),
  'goals', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'predicate', predicate, 'value', value, 'kind', kind) order by predicate, id), '[]')
            from current_facts where subject = 'me' and (predicate in ('center_goal','core_value','sub_goal') or predicate like 'goal_plan:%')),
  'events', (select coalesce(jsonb_agg(jsonb_build_object('title', title, 'start', starts_at, 'end', ends_at, 'location', location) order by starts_at), '[]')
             from calendar_events, w where starts_at >= (w.wk::timestamp at time zone 'America/New_York')
               and starts_at < ((w.wk + 14)::timestamp at time zone 'America/New_York')),
  'commitments', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'owner', c.owner, 'for', c.beneficiary,
                    'for_name', (select name from entities where id = c.beneficiary), 'owner_name', (select name from entities where id = c.owner),
                    'action', c.action, 'due', c.due_at, 'status', c.status, 'created', c.created_at, 'updated', c.updated_at,
                    'source', (select title from raw_events where id = c.raw_event_id)) order by c.id), '[]') from commitments c),
  'people', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'org', p.org,
                 'org_name', (select name from entities where id = p.org), 'group', p.grp, 'group_name', (select name from entities where id = p.grp),
                 'direct', p.direct, 'mentions', p.mentions, 'last', p.last_at)), '[]') from self_ppl p where p.mentions > 0),
  'stories', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'title', s.title, 'status', s.status, 'summary', left(s.summary, 400),
                 'importance', s.importance, 'updated', s.updated_at,
                 'events', (select count(*) from story_events se where se.story_id = s.id),
                 'notes', (select coalesce(jsonb_agg(jsonb_build_object('note', q.note, 'at', q.occurred_at, 'title', q.title)), '[]') from
                    (select se.note, r.occurred_at, r.title from story_events se join raw_events r on r.id = se.raw_event_id
                     where se.story_id = s.id order by r.occurred_at desc limit 4) q)) order by s.importance desc), '[]') from stories s where s.status = 'active'),
  'skills', (select coalesce(jsonb_agg(jsonb_build_object('predicate', predicate, 'value', value, 'at', coalesce(source_at, learned_at)) order by coalesce(source_at, learned_at)), '[]')
             from current_facts where subject = 'me' and predicate like 'feedback:%'),
  'needs_yes', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'title', title, 'body', left(body, 300), 'created', created_at) order by priority desc, created_at desc), '[]')
                from proposals where status = 'pending' and kind = 'followup'),
  'brief', brain_daily_brief((select day from d)),
  'hypotheses', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'about', subject, 'guess', value, 'confidence', confidence, 'source', source_title)), '[]')
                 from current_facts where kind = 'hypothesis' and status is distinct from 'retracted'),
  'patterns', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'title', title, 'description', left(description, 240), 'class', class)), '[]') from patterns),
  'corrections', (select coalesce(jsonb_agg(jsonb_build_object('title', title, 'at', occurred_at) order by occurred_at desc), '[]')
                  from (select title, occurred_at from raw_events where provider = 'correction' order by occurred_at desc limit 6) q),
  'stale', (select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'subject', coalesce(e.name, f.subject), 'predicate', f.predicate, 'value', left(f.value, 120),
               'age_days', (now()::date - coalesce(f.source_at, f.learned_at)::date))), '[]')
            from (select * from current_facts where kind in ('fact','plan','preference') and predicate in ('role','works_at','priority','plan','interest','relationship','offers_help')
                  and coalesce(source_at, learned_at) < now() - interval '21 days' order by coalesce(source_at, learned_at) limit 6) f
            left join entities e on e.id = f.subject),
  'counts', jsonb_build_object('people', (select count(*) from entities where type = 'person'), 'facts', (select count(*) from current_facts),
               'links', (select count(*) from edges), 'patterns', (select count(*) from patterns),
               'sources', (select count(*) from raw_events), 'hypotheses', (select count(*) from current_facts where kind = 'hypothesis')),
  'health', jsonb_build_object('last_compile', (select max(finished_at) from runs where status is distinct from 'error'),
               'last_source', (select max(received_at) from raw_events),
               'waiting', (select count(*) from raw_events where compiled_at is null and coalesce(status, '') not in ('skipped','error')))
);
$$;
revoke all on function public.brain_desk(date) from public, anon, authenticated;
grant execute on function public.brain_desk(date) to service_role;
