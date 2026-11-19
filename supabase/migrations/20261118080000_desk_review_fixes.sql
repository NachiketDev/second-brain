-- Desk v2 review fixes (18 Nov). Additive: views and read functions replaced in place, same outputs plus new keys.

-- Talks, info sessions and events he attended count as contact ('attended' edge: me -> person or org).
create or replace view interactions with (security_invoker = true) as
  select case when x.src = 'me' then x.dst else x.src end as entity_id, r.occurred_at as at,
         x.rel as channel, x.raw_event_id, r.title
  from edges x join raw_events r on r.id = x.raw_event_id
  where 'me' in (x.src, x.dst) and x.src <> x.dst
    and x.rel in ('coffee_chat', 'emailed', 'met', 'called', 'interviewed', 'mock_case', 'coached', 'attended')
  union
  select c.entity_id, r.occurred_at, 'email', r.id, r.title
  from raw_events r join contacts c on c.kind = 'email' and lower(c.value) = lower(r.payload->>'from')
  where r.provider = 'hbs_email';

-- Email domains that place a person in an organisation when no works_at edge exists.
insert into kv(key, value) values ('org_email_domains', jsonb_build_object(
  'hbs.edu', 'hbs', 'mba2027.hbs.edu', 'hbs', 'mba2028.hbs.edu', 'hbs',
  'bcg.com', 'bcg', 'bain.com', 'bain', 'mckinsey.com', 'mckinsey', 'pwc.com', 'strategy-and',
  'amgen.com', 'amgen', 'cisco.com', 'cisco'))
on conflict (key) do nothing;

-- Pursuit activity counts only real things: tasks created or closed, and sources (story events) in its tree.
-- (The 17 Nov backfill touched every pursuit's updated_at, which made every card read "last activity today".)
create or replace function desk_workbench() returns jsonb language sql stable set search_path = public, pg_temp as $$
  with recursive tree as (
    select id, id as root from pursuits
    union all select p.id, t.root from pursuits p join tree t on p.parent_id = t.id
  ),
  act as (
    select p.id,
      greatest(
        (select max(greatest(c.created_at, c.completed_at)) from commitments c join tree t on t.id = c.pursuit_id
          where t.root = p.id and c.run_id is distinct from 'backfill'),
        (select max(r.occurred_at) from tree t join pursuits q on q.id = t.id
           join story_events se on se.story_id = q.story_id join raw_events r on r.id = se.raw_event_id
          where t.root = p.id),
        (select max(i.at) from interactions i where p.org_entity is not null and i.entity_id = p.org_entity)) as last_activity
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

-- People: place by works_at edge, then studies_at, then email domain. Organisations also count contact from
-- events he attended there (attended edges and the sources of the matching pursuit).
create or replace function desk_people(p_org text default null) returns jsonb language sql stable
set search_path = public, pg_temp as $$
  with person_org as (
    select e.id, e.name,
      coalesce((select o.dst from edges w join edges o on o.src = w.dst and o.rel = 'office_of'
                where w.src = e.id and w.rel = 'works_at' limit 1),
               (select w.dst from edges w where w.src = e.id and w.rel = 'works_at' limit 1),
               (select w.dst from edges w where w.src = e.id and w.rel = 'studies_at' limit 1),
               (select kv.value->>lower(split_part(c.value, '@', 2)) from contacts c, kv
                where kv.key = 'org_email_domains' and c.entity_id = e.id and c.kind = 'email'
                  and kv.value ? lower(split_part(c.value, '@', 2)) limit 1)) as org
    from entities e where e.type = 'person' and e.id <> 'me'
  ),
  last_contact as (select entity_id, max(at) as at, count(*) as n from interactions group by 1),
  org_events as (
    select o.id as org, max(x.at) as at from entities o
    cross join lateral (
      select i.at from interactions i where i.entity_id = o.id
      union all
      select r.occurred_at from pursuits p join story_events se on se.story_id = p.story_id
        join raw_events r on r.id = se.raw_event_id where p.org_entity = o.id) x
    where o.type = 'org' group by o.id
  )
  select case when p_org is null then jsonb_build_object(
      'orgs', (select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'name', o.name, 'people', x.n,
                 'active_30d', x.active, 'last', greatest(x.last, oe.at)) order by x.active desc, x.n desc), '[]')
               from (select org, count(*) n, max(lc.at) last,
                       count(*) filter (where lc.at > now() - interval '30 days') active
                     from person_org po left join last_contact lc on lc.entity_id = po.id
                     where org is not null group by org) x join entities o on o.id = x.org
               left join org_events oe on oe.org = x.org),
      'unplaced', (select count(*) from person_org where org is null))
    else jsonb_build_object(
      'org', (select jsonb_build_object('id', id, 'name', name, 'last_contact', (select at from org_events where org = p_org))
              from entities where id = p_org),
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

-- Mirror: completion dates before 17 Nov were backfilled from "last changed", so flag them as approximate.
create or replace function desk_review(p_month date default null) returns jsonb language plpgsql stable
set search_path = public, pg_temp as $$
declare
  m date := date_trunc('month', coalesce(p_month, (now() at time zone 'America/New_York')::date))::date;
  t0 timestamptz := m::timestamp at time zone 'America/New_York';
  t1 timestamptz := (m + interval '1 month')::timestamp at time zone 'America/New_York';
  exact_from date := '2026-11-17';
begin
  return jsonb_build_object(
    'month', m,
    'approximate_before', case when m < exact_from then exact_from end,
    'approximate_note', case when m < exact_from then
       'Completion dates before 17 Nov were backfilled from when each item last changed, so kept, dropped and late counts for that part of the month are approximate.' end,
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
       'targets', (select coalesce(jsonb_agg(jsonb_build_object('action', a.title, 'weekly_target', a.weekly_target, 'unit', a.unit,
                     'done_month', (select coalesce(sum(sessions), 0) from goal_sessions(a.id, m, (m + interval '1 month')::date - 1)))), '[]')
                   from goals a where a.parent_id = g.id and a.weekly_target is not null)
      ) order by g.sort), '[]') from goals g where g.kind = 'box'),
    'promises', jsonb_build_object(
       'kept', (select count(*) from commitments where owner = 'me' and status = 'done' and completed_at >= t0 and completed_at < t1),
       'dropped', (select count(*) from commitments where owner = 'me' and status = 'dropped' and completed_at >= t0 and completed_at < t1),
       'late', (select count(*) from commitments where owner = 'me' and status = 'done' and completed_at >= t0 and completed_at < t1
                and due_at is not null and completed_at::date > due_at),
       'late_exact', (select count(*) from commitments where owner = 'me' and status = 'done' and completed_at >= greatest(t0, exact_from::timestamptz)
                and completed_at < t1 and due_at is not null and completed_at::date > due_at),
       'open_overdue', (select count(*) from commitments where owner = 'me' and status in ('open', 'needs_review', 'unknown')
                        and due_at < (now() at time zone 'America/New_York')::date)));
end $$;
