-- Summary freshness (18 Nov): a summary is rewritten only when its pursuit changed; an unchanged summary is
-- re-confirmed (summary_at moves, text stays). Keeps every summary under 24h old without rewriting 40 a run.

create or replace function pursuit_changed_since(p_id text, p_since timestamptz) returns boolean
language sql stable set search_path = public, pg_temp as $$
  with recursive tree as (select id from pursuits where id = p_id
                          union all select p.id from pursuits p join tree t on p.parent_id = t.id)
  select p_since is null
    or exists (select 1 from commitments c where c.pursuit_id in (select id from tree)
               and greatest(c.created_at, c.completed_at, c.updated_at) > p_since)
    or exists (select 1 from tree t join pursuits q on q.id = t.id join story_events se on se.story_id = q.story_id
               join raw_events r on r.id = se.raw_event_id where r.received_at > p_since)
    or exists (select 1 from pursuits q where q.id = p_id and q.org_entity is not null
               and exists (select 1 from facts f where f.subject = q.org_entity and f.learned_at > p_since))
$$;

-- Re-confirm summaries of pursuits with nothing new since they were written.
create or replace function brain_confirm_summaries() returns int
language plpgsql set search_path = public, pg_temp as $$
declare n int;
begin
  update pursuits p set summary_at = now()
  where p.status in ('active','paused') and p.summary is not null
    and p.summary_at < now() - interval '12 hours'
    and not pursuit_changed_since(p.id, p.summary_at);
  get diagnostics n = row_count;
  return n;
end $$;

-- Followups: summaries now lists pursuits with no summary or with something new since it was written.
create or replace function brain_compile_followups(p_limit int default 15) returns jsonb
language sql stable set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'unfiled', (select coalesce(jsonb_agg(jsonb_build_object('id',id,'action',action,'due_at',due_at,
                  'pursuit_id',pursuit_id,'goal_id',goal_id,'estimate_min',estimate_min,'estimate_source',estimate_source,
                  'is_event',is_event) order by id), '[]')
                from commitments where owner = 'me' and status in ('open','needs_review','unknown')
                  and ((pursuit_id is null and goal_id is null) or estimate_min is null
                       or coalesce(estimate_source, 'default') = 'default')),
    'summaries', (select coalesce(jsonb_agg(x order by x->>'summary_at' nulls first), '[]') from (
        select jsonb_build_object(
          'id', p.id, 'title', p.title, 'kind', p.kind, 'stage', p.stage, 'deadline', p.deadline, 'status', p.status,
          'parent', p.parent_id, 'summary', p.summary, 'summary_at', p.summary_at,
          'open', (select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'action',c.action,'due',c.due_at,'status',c.status)), '[]')
                   from commitments c where c.pursuit_id = p.id and c.status in ('open','needs_review','unknown')),
          'closed_14d', (select coalesce(jsonb_agg(jsonb_build_object('action',c.action,'status',c.status,'at',c.completed_at)), '[]')
                         from commitments c where c.pursuit_id = p.id and c.status in ('done','dropped')
                           and c.completed_at > now() - interval '14 days'),
          'children', (select coalesce(jsonb_agg(jsonb_build_object('title',k.title,'stage',k.stage,'summary',left(k.summary,200))), '[]')
                       from pursuits k where k.parent_id = p.id and k.status = 'active'),
          'story_notes', (select coalesce(jsonb_agg(jsonb_build_object('date',r.occurred_at::date,'note',se.note) order by r.occurred_at desc), '[]')
                          from (select * from story_events where story_id = p.story_id) se
                          join raw_events r on r.id = se.raw_event_id
                          where r.occurred_at > now() - interval '60 days'),
          'org_facts', (select coalesce(jsonb_agg(jsonb_build_object('predicate',f.predicate,'value',f.value,'since',f.valid_from::date)), '[]')
                        from (select * from current_facts where subject = p.org_entity
                              or predicate in ('stage:' || coalesce(p.org_entity,'-'), 'target_office:' || coalesce(p.org_entity,'-'))
                              order by valid_from desc limit 12) f),
          'people', (select count(*) from edges ed where ed.rel = 'works_at' and ed.dst = p.org_entity)
        ) x
        from pursuits p
        where p.status in ('active','paused') and (p.summary is null or pursuit_changed_since(p.id, p.summary_at))
        order by p.summary_at nulls first, p.id
        limit p_limit) s),
    'rewrites', (select coalesce(jsonb_agg(jsonb_build_object('fact_id',id,'subject',subject,'predicate',predicate,
                   'value',value,'confirmed_note',evidence)), '[]')
                 from facts where status = 'current' and class = 'declared' and predicate like 'hypothesis:%'));
$$;

do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('pursuit_changed_since','brain_confirm_summaries','brain_compile_followups') loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
