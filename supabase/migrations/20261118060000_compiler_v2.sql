-- Compiler v2 (rollout step 6, 18 Nov 2026). Additive and backward compatible: a v1 diff still applies
-- unchanged; v2 adds optional keys. New columns only; no drops or renames.

alter table commitments add column if not exists is_event boolean not null default false;
alter table commitments add column if not exists estimate_source text
  check (estimate_source in ('default', 'compiler', 'his'));

-- ── apply_diff v2 ─────────────────────────────────────────────────────────────────────────────────
-- New optional keys:
--   commitments[]        + pursuit_id, goal_id, estimate_min, is_event. His open tasks get a Google copy.
--   commitment_updates[] + pursuit_id, goal_id, estimate_min, is_event (status/due_at as before).
--   pursuit_updates[]    {id, summary?, stage?, deadline?, status?, title?, kind?, parent_id?, goal_id?, org_entity?}
--   contacts[]           {entity, kind: email|linkedin|phone, value}
--   claims[]             + affects_commitments: [commitment ids] that rest on this fact (flagged if it later changes)
create or replace function apply_diff(p_raw_event_id bigint, p_diff jsonb, p_run_id text default null)
returns jsonb language plpgsql set search_path = public, pg_temp as $$
declare
  ev raw_events; e jsonb; c jsonb; m jsonb; s jsonb; x jsonb; p jsonb; k text; a jsonb;
  known text[]; n_facts int := 0; n_comm int := 0; n_ent int := 0; n_upd int := 0; n_purs int := 0; n_cont int := 0;
  cid bigint; fid bigint; vf timestamptz; est int;
begin
  select * into ev from raw_events where id = p_raw_event_id for update;
  if not found then raise exception 'raw event % not found', p_raw_event_id; end if;
  if ev.status = 'compiled' then return jsonb_build_object('result', 'already_compiled'); end if;

  perform set_config('brain.raw_event_id', p_raw_event_id::text, true);
  perform set_config('brain.run_id', coalesce(p_run_id, ''), true);

  -- validation first, so a bad diff changes nothing
  select array_agg(id) into known from entities;
  known := known || coalesce(array(select jsonb_array_elements(coalesce(p_diff->'entities','[]'))->>'id'), '{}');
  for c in select * from jsonb_array_elements(coalesce(p_diff->'claims','[]')) loop
    if not (c->>'subject' = any(known)) then raise exception 'claim subject unknown: %', c->>'subject'; end if;
    if c ? 'value_entity' and c->>'value_entity' is not null and not (c->>'value_entity' = any(known))
      then raise exception 'claim value_entity unknown: %', c->>'value_entity'; end if;
    if coalesce(c->>'evidence','') = '' then raise exception 'claim without evidence: %', c->>'predicate'; end if;
    if ev.consent_scope = 'restricted' and c->>'subject' <> 'me'
      then raise exception 'restricted source may only carry claims about the user'; end if;
  end loop;
  for m in select * from jsonb_array_elements(coalesce(p_diff->'commitments','[]') || coalesce(p_diff->'commitment_updates','[]')) loop
    if m ? 'owner' and not (m->>'owner' = any(known)) then raise exception 'commitment owner unknown: %', m->>'owner'; end if;
    if m ? 'action' and coalesce(m->>'evidence','') = '' then raise exception 'commitment without evidence'; end if;
    if nullif(m->>'pursuit_id','') is not null and not exists (select 1 from pursuits where id = m->>'pursuit_id')
       and not exists (select 1 from jsonb_array_elements(coalesce(p_diff->'pursuit_updates','[]')) pu where pu->>'id' = m->>'pursuit_id')
      then raise exception 'pursuit unknown: % (use an id from context.pursuits)', m->>'pursuit_id'; end if;
    if nullif(m->>'goal_id','') is not null and not exists (select 1 from goals where id = m->>'goal_id')
      then raise exception 'goal unknown: % (use an id from context.goals)', m->>'goal_id'; end if;
  end loop;
  for p in select * from jsonb_array_elements(coalesce(p_diff->'pursuit_updates','[]')) loop
    if nullif(p->>'id','') is null then raise exception 'pursuit update without id'; end if;
    if not exists (select 1 from pursuits where id = p->>'id') and coalesce(p->>'title','') = ''
      then raise exception 'new pursuit % needs a title and kind', p->>'id'; end if;
    if p ? 'stage' and nullif(p->>'stage','') is not null and p->>'stage' not in
       ('researching','networking','applied','test','first round','final round','offer','closed')
      then raise exception 'stage must be one of researching, networking, applied, test, first round, final round, offer, closed'; end if;
  end loop;
  for x in select * from jsonb_array_elements(coalesce(p_diff->'contacts','[]')) loop
    if not (x->>'entity' = any(known)) then raise exception 'contact for unknown entity: %', x->>'entity'; end if;
  end loop;

  for e in select * from jsonb_array_elements(coalesce(p_diff->'entities','[]')) loop
    insert into entities (id, type, name, aliases, summary)
    values (e->>'id', e->>'type', e->>'name', coalesce(e->'aliases','[]'), e->>'summary')
    on conflict (id) do update set
      aliases = (select coalesce(jsonb_agg(distinct a2), '[]') from jsonb_array_elements(entities.aliases || excluded.aliases) a2),
      summary = coalesce(excluded.summary, entities.summary),
      updated_at = now();
    n_ent := n_ent + 1;
  end loop;

  -- pursuits before commitments, so a new pursuit can be filed into in the same diff
  for p in select * from jsonb_array_elements(coalesce(p_diff->'pursuit_updates','[]')) loop
    perform brain_upsert_pursuit((select jsonb_object_agg(key, value) from jsonb_each(p)
      where key in ('id','summary','stage','deadline','status','title','kind','parent_id','goal_id','org_entity')));
    n_purs := n_purs + 1;
  end loop;

  for c in select * from jsonb_array_elements(coalesce(p_diff->'claims','[]')) loop
    vf := coalesce((c->>'valid_from')::timestamptz, ev.occurred_at);
    if not is_single_valued(c->>'predicate') and exists (
         select 1 from facts where subject = c->>'subject' and predicate = c->>'predicate'
         and value = c->>'value' and status = 'current') then
      continue;
    end if;
    perform set_config('brain.reason', coalesce(c->>'change_reason', 'extracted from source'), true);
    insert into facts (subject, predicate, value, value_entity, kind, class, confidence, valid_from,
                       raw_event_id, evidence, run_id, status)
    values (c->>'subject', c->>'predicate', c->>'value', nullif(c->>'value_entity',''), c->>'kind', c->>'class',
            coalesce((c->>'confidence')::real, 0.8), vf, p_raw_event_id, c->>'evidence', p_run_id,
            case when is_single_valued(c->>'predicate') then 'superseded' else 'current' end);
    if is_single_valued(c->>'predicate') then
      perform set_config('brain.reason', coalesce(c->>'change_reason', 'newer information'), true);
      perform rechain(c->>'subject', c->>'predicate');
      perform refresh_dependents((c->>'subject') || '|' || (c->>'predicate'));
    end if;
    for a in select * from jsonb_array_elements(coalesce(c->'affects_commitments','[]')) loop
      select id into fid from facts where subject = c->>'subject' and predicate = c->>'predicate' and status = 'current'
        order by valid_from desc limit 1;
      insert into dependencies values ((a #>> '{}')::bigint, (c->>'subject') || '|' || (c->>'predicate'), fid)
        on conflict do nothing;
    end loop;
    n_facts := n_facts + 1;
  end loop;

  perform set_config('brain.reason', 'explicit commitment in source', true);
  for m in select * from jsonb_array_elements(coalesce(p_diff->'commitments','[]')) loop
    cid := null;
    est := nullif(m->>'estimate_min','')::int;
    insert into commitments (owner, beneficiary, action, due_at, status, raw_event_id, evidence, run_id,
                             pursuit_id, goal_id, estimate_min, estimate_source, is_event, source, gtask_state)
    values (m->>'owner', nullif(m->>'beneficiary',''), m->>'action', nullif(m->>'due_at','')::date,
            coalesce(m->>'status','open'), p_raw_event_id, m->>'evidence', p_run_id,
            nullif(m->>'pursuit_id',''), nullif(m->>'goal_id',''),
            case when m->>'owner' = 'me' then coalesce(est, 30) end,
            case when m->>'owner' = 'me' then case when est is null then 'default' else 'compiler' end end,
            coalesce((m->>'is_event')::boolean, false),
            case when ev.provider in ('checkin', 'correction') then 'checkin' else 'compiler' end,
            case when m->>'owner' = 'me' and coalesce(m->>'status','open') = 'open' then 'to_create' end)
    on conflict (raw_event_id, action) do nothing
    returning id into cid;
    if cid is not null then
      n_comm := n_comm + 1;
      for k in select jsonb_array_elements_text(coalesce(m->'depends_on','[]')) loop
        select id into fid from facts where subject || '|' || predicate = k and status = 'current'
          order by valid_from desc limit 1;
        insert into dependencies values (cid, k, fid) on conflict do nothing;
        perform refresh_dependents(k);
      end loop;
    end if;
  end loop;

  for m in select * from jsonb_array_elements(coalesce(p_diff->'commitment_updates','[]')) loop
    perform set_config('brain.reason', coalesce(m->>'reason', 'status update from source'), true);
    perform set_config('brain.estimate_by', 'compiler', true);
    update commitments set
      status       = coalesce(m->>'status', status),
      due_at       = coalesce(nullif(m->>'due_at','')::date, due_at),
      pursuit_id   = case when m ? 'pursuit_id' then nullif(m->>'pursuit_id','') else pursuit_id end,
      goal_id      = case when m ? 'goal_id' then nullif(m->>'goal_id','') else goal_id end,
      estimate_min = case when m ? 'estimate_min' and coalesce(estimate_source, '') <> 'his' then nullif(m->>'estimate_min','')::int else estimate_min end,
      is_event     = coalesce((m->>'is_event')::boolean, is_event),
      gtask_state  = case when gtask_id is not null and nullif(m->>'due_at','') is not null
                          and coalesce(gtask_state,'') not in ('to_complete', 'to_reopen') then 'to_update' else gtask_state end,
      updated_at = now()
    where id = (m->>'id')::bigint;
    perform set_config('brain.estimate_by', '', true);
    n_upd := n_upd + 1;
  end loop;

  for x in select * from jsonb_array_elements(coalesce(p_diff->'contacts','[]')) loop
    perform brain_add_contact(x->>'entity', coalesce(x->>'kind', 'email'), x->>'value', p_raw_event_id);
    n_cont := n_cont + 1;
  end loop;

  perform set_config('brain.reason', 'story touched by source', true);
  for s in select * from jsonb_array_elements(coalesce(p_diff->'stories','[]')) loop
    insert into stories (id, title, summary, importance)
    values (s->>'id', coalesce(s->>'title', s->>'id'), s->>'summary', coalesce((s->>'importance')::real, 0.5))
    on conflict (id) do update set summary = coalesce(excluded.summary, stories.summary), updated_at = now();
    insert into story_events values (s->>'id', p_raw_event_id, s->>'note') on conflict do nothing;
  end loop;
  for x in select * from jsonb_array_elements(coalesce(p_diff->'edges','[]')) loop
    insert into edges values (x->>'src', x->>'rel', x->>'dst', p_raw_event_id) on conflict do nothing;
  end loop;
  for p in select * from jsonb_array_elements(coalesce(p_diff->'patterns','[]')) loop
    insert into patterns (id, title, description, class, raw_event_ids, first_seen, last_seen, pursuit_id)
    values (p->>'id', p->>'title', p->>'description', p->>'class', p->'raw_event_ids', ev.occurred_at, ev.occurred_at,
            nullif(p->>'pursuit_id', ''))
    on conflict (id) do update set description = excluded.description, raw_event_ids = excluded.raw_event_ids,
                                   last_seen = greatest(patterns.last_seen, excluded.last_seen), updated_at = now();
  end loop;

  update raw_events set status = 'compiled', compiled_at = now(), error = null where id = p_raw_event_id;
  return jsonb_build_object('result','applied','entities',n_ent,'facts',n_facts,'commitments',n_comm,
    'commitment_updates',n_upd,'pursuits',n_purs,'contacts',n_cont);
end $$;

-- ── brain_context v2: same keys as v1, plus what the compiler needs to file and close things ─────────
create or replace function brain_context(p_id bigint) returns jsonb
language plpgsql stable set search_path = public, pg_temp as $$
declare ev raw_events; hay text; ids text[]; thread text;
begin
  select * into ev from raw_events where id = p_id;
  if not found then raise exception 'raw event % not found', p_id; end if;
  hay := lower(coalesce(ev.title,'') || ' ' || coalesce(ev.content,''));
  thread := ev.payload->>'thread_id';
  select array_agg(e.id) into ids from entities e
  where e.id = 'me' or exists (
    select 1 from (select e.name as n union all select jsonb_array_elements_text(e.aliases)) names
    where length(n) > 2 and (position(lower(n) in hay) > 0
      or (length(split_part(n,' ',1)) > 3 and hay ~ ('\m' || lower(split_part(n,' ',1)) || '\M'))));
  return jsonb_build_object(
    'event', jsonb_build_object('id', ev.id, 'provider', ev.provider, 'date', ev.occurred_at, 'title', ev.title,
                                'consent_scope', ev.consent_scope, 'is_revision_of', ev.revision_of,
                                'thread_id', thread, 'from', ev.payload->>'from',
                                'content', left(ev.content, 150000)),
    'entities', (select coalesce(jsonb_agg(jsonb_build_object('id',id,'type',type,'name',name,'aliases',aliases)), '[]') from entities),
    'mentioned_entity_details', (select coalesce(jsonb_agg(to_jsonb(e) - 'created_at' - 'updated_at'), '[]') from entities e where e.id = any(ids)),
    'current_facts', (select coalesce(jsonb_agg(jsonb_build_object('subject',subject,'predicate',predicate,'value',value,
                        'valid_from',valid_from,'source',source_title)), '[]')
                      from (select * from current_facts where subject = any(ids) order by valid_from desc limit 400) f),
    'stories', (select coalesce(jsonb_agg(jsonb_build_object('id',id,'title',title)), '[]') from stories where status = 'active'),
    'open_commitments', (select coalesce(jsonb_agg(jsonb_build_object('id',id,'owner',owner,'beneficiary',beneficiary,
                           'action',action,'due_at',due_at,'status',status,'pursuit_id',pursuit_id,'goal_id',goal_id,
                           'is_event',is_event)), '[]')
                         from commitments where status in ('open','needs_review','unknown')),
    'pursuits', (select coalesce(jsonb_agg(jsonb_build_object('id',id,'title',title,'kind',kind,'parent_id',parent_id,
                    'goal_id',goal_id,'stage',stage,'deadline',deadline,'org_entity',org_entity,'story_id',story_id)
                    order by parent_id nulls first, id), '[]') from pursuits where status in ('active','paused')),
    'goals', (select coalesce(jsonb_agg(jsonb_build_object('id',id,'kind',kind,'box',box_key,'title',title) order by box_key, sort), '[]')
              from goals where status = 'active' and kind in ('box','action')),
    -- email only: earlier open commitments from the same thread, for closing them when his reply is quoted
    'thread_open_commitments', case when thread is null then '[]'::jsonb else
      (select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'owner',c.owner,'action',c.action,'from_event',c.raw_event_id,
                 'event_date',r.occurred_at)), '[]')
       from commitments c join raw_events r on r.id = c.raw_event_id
       where r.payload->>'thread_id' = thread and r.id <> ev.id and c.status in ('open','needs_review','unknown')) end);
end $$;

-- ── After-compile work for each run ──────────────────────────────────────────────────────────────
-- unfiled:      his open tasks with no pursuit and no goal, or still on the default estimate
-- summaries:    up to p_limit pursuits whose summary is missing or older than 20 hours, with the material to write one
-- rewrites:     confirmed hypotheses that still carry guess wording (predicate hypothesis:*)
create or replace function brain_compile_followups(p_limit int default 8) returns jsonb
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
        where p.status in ('active','paused') and (p.summary_at is null or p.summary_at < now() - interval '20 hours')
        order by p.summary_at nulls first, p.id
        limit p_limit) s),
    'rewrites', (select coalesce(jsonb_agg(jsonb_build_object('fact_id',id,'subject',subject,'predicate',predicate,
                   'value',value,'confirmed_note',evidence)), '[]')
                 from facts where status = 'current' and class = 'declared' and predicate like 'hypothesis:%'));
$$;

-- Rewrite a confirmed hypothesis as a plain fact: the guess version is superseded, history is kept.
create or replace function brain_rewrite_fact(p_fact_id bigint, p_predicate text, p_value text, p_run_id text default null)
returns jsonb language plpgsql set search_path = public, pg_temp as $$
declare f facts; nid bigint;
begin
  select * into f from facts where id = p_fact_id and status = 'current' and class = 'declared' and predicate like 'hypothesis:%';
  if not found then raise exception 'Fact % is not a confirmed hypothesis waiting for a rewrite', p_fact_id; end if;
  if coalesce(trim(p_predicate), '') = '' or p_predicate like 'hypothesis:%' then raise exception 'Give a plain predicate'; end if;
  if coalesce(trim(p_value), '') = '' then raise exception 'Give the plain wording'; end if;
  perform set_config('brain.raw_event_id', coalesce(f.raw_event_id::text, ''), true);
  perform set_config('brain.run_id', coalesce(p_run_id, 'rewrite'), true);
  perform set_config('brain.reason', 'confirmed hypothesis rewritten as a plain fact', true);
  update facts set status = 'superseded', valid_to = now() where id = f.id;
  insert into facts (subject, predicate, value, value_entity, kind, class, confidence, valid_from, raw_event_id,
                     evidence, supersedes, run_id, status)
  values (f.subject, trim(p_predicate), trim(p_value), f.value_entity, 'fact', 'declared', 1.0, f.valid_from, f.raw_event_id,
          f.evidence, f.id, coalesce(p_run_id, 'rewrite'), 'current')
  returning id into nid;
  return jsonb_build_object('old', f.id, 'new', nid);
end $$;

do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('apply_diff','brain_context','brain_compile_followups','brain_rewrite_fact',
             'brain_file_commitment','brain_backfill_estimates','commitment_estimate_defaults') loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- ── Time estimates (review item 3): every task of his has one; 30 min until someone sets it ─────────
-- estimate_source: default (30 min placeholder), compiler (estimated from the task text), his (he set it).
create or replace function commitment_estimate_defaults() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  if tg_op = 'INSERT' then
    if new.owner = 'me' and new.estimate_min is null then new.estimate_min := 30; new.estimate_source := 'default';
    elsif new.estimate_min is not null and new.estimate_source is null then
      new.estimate_source := case when coalesce(current_setting('brain.estimate_by', true), '') = 'compiler' then 'compiler' else 'his' end;
    end if;
  elsif new.estimate_min is distinct from old.estimate_min and new.estimate_source is not distinct from old.estimate_source then
    new.estimate_source := case when coalesce(current_setting('brain.estimate_by', true), '') = 'compiler' then 'compiler' else 'his' end;
  end if;
  return new;
end $$;
drop trigger if exists commitments_estimate_defaults on commitments;
create trigger commitments_estimate_defaults before insert or update of estimate_min on commitments
  for each row execute function commitment_estimate_defaults();

-- The compiler files and sizes his tasks after each run (pursuit, goal, estimate, event flag).
-- Never overrides an estimate he set himself.
create or replace function brain_file_commitment(p_id bigint, p_fields jsonb, p_run_id text default null) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare k text; c commitments;
begin
  for k in select jsonb_object_keys(p_fields) loop
    if k not in ('pursuit_id', 'goal_id', 'estimate_min', 'is_event') then raise exception 'Field % cannot be set here', k; end if;
  end loop;
  select * into c from commitments where id = p_id;
  if not found then raise exception 'Commitment % not found', p_id; end if;
  if nullif(p_fields->>'pursuit_id','') is not null and not exists (select 1 from pursuits where id = p_fields->>'pursuit_id')
    then raise exception 'pursuit unknown: %', p_fields->>'pursuit_id'; end if;
  if nullif(p_fields->>'goal_id','') is not null and not exists (select 1 from goals where id = p_fields->>'goal_id')
    then raise exception 'goal unknown: %', p_fields->>'goal_id'; end if;
  perform set_config('brain.estimate_by', 'compiler', true);
  perform set_config('brain.run_id', coalesce(p_run_id, 'filing'), true);
  perform set_config('brain.reason', 'filed by the compiler', true);
  update commitments set
    pursuit_id   = case when p_fields ? 'pursuit_id' then nullif(p_fields->>'pursuit_id','') else pursuit_id end,
    goal_id      = case when p_fields ? 'goal_id' then nullif(p_fields->>'goal_id','') else goal_id end,
    estimate_min = case when p_fields ? 'estimate_min' and coalesce(estimate_source,'') <> 'his'
                        then nullif(p_fields->>'estimate_min','')::int else estimate_min end,
    is_event     = coalesce((p_fields->>'is_event')::boolean, is_event),
    updated_at   = now()
  where id = p_id;
  perform set_config('brain.estimate_by', '', true);
  return jsonb_build_object('id', p_id, 'filed', p_fields);
end $$;

-- One-time: his open tasks without an estimate get the 30 min default (the compiler refines them).
create or replace function brain_backfill_estimates() returns int
language plpgsql set search_path = public, pg_temp as $$
declare n int;
begin
  perform set_config('brain.estimate_by', 'compiler', true);
  update commitments set estimate_min = 30, estimate_source = 'default'
  where owner = 'me' and estimate_min is null and status in ('open','needs_review','unknown');
  get diagnostics n = row_count;
  perform set_config('brain.estimate_by', '', true);
  return n;
end $$;

do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('brain_file_commitment','brain_backfill_estimates','commitment_estimate_defaults') loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
