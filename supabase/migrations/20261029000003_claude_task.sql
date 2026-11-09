-- Entry points for the scheduled Claude task (the intelligence layer runs under your Claude plan,
-- not an API key). The task talks to the database through the Supabase connector using only these calls:
--   ingest_raw(...)            put a Granola note / anything into raw memory
--   claim_raw_events(n)        take the next pending events
--   brain_context(id)          everything the brain knows that is relevant to one event
--   apply_diff(id, diff, run)  write the compiled diff (validated, atomic, logged)
--   fail_raw_event(id, err)    mark an event failed so it is retried later
--   briefing_candidates()      upcoming meetings with known people, plus the records to brief from
--   save_briefing(...)         store a briefing as a proposal for the digest

create or replace function ingest_raw(
  p_provider text, p_external_id text, p_occurred_at timestamptz, p_title text, p_content text,
  p_url text default null, p_kind text default 'meeting', p_payload jsonb default '{}')
returns jsonb language plpgsql as $$
declare h text; prior raw_events; scope text; new_id bigint;
begin
  h := md5(coalesce(p_title,'') || E'\n' || coalesce(p_content,''));
  select * into prior from raw_events where provider = p_provider and external_id = p_external_id
    order by id desc limit 1;
  if found and prior.content_hash = h then
    return jsonb_build_object('result','duplicate','id',prior.id);
  end if;
  scope := case when p_title ~* '\[(private|off.?record|no.?brain)\]' then 'exclude'
                when p_title ~* '\m(nda|confidential)\M' then 'restricted' else 'full' end;
  insert into raw_events (provider, external_id, content_hash, kind, occurred_at, title, content, consent_scope,
                          status, revision_of, payload)
  values (p_provider, p_external_id, h, p_kind, p_occurred_at, p_title, p_content, scope,
          case when scope = 'exclude' then 'skipped' else 'pending' end, prior.id,
          p_payload || jsonb_build_object('url', p_url))
  returning id into new_id;
  return jsonb_build_object('result', case when prior.id is null then 'stored' else 'revision' end,
                            'id', new_id, 'consent_scope', scope);
end $$;

create or replace function fail_raw_event(p_id bigint, p_error text) returns void language sql as $$
  update raw_events set status = 'failed', error = left(p_error, 2000) where id = p_id
$$;

-- Retrieve-before-write: the brain's view of one raw event.
create or replace function brain_context(p_id bigint) returns jsonb language plpgsql stable as $$
declare ev raw_events; hay text; ids text[];
begin
  select * into ev from raw_events where id = p_id;
  if not found then raise exception 'raw event % not found', p_id; end if;
  hay := lower(coalesce(ev.title,'') || ' ' || coalesce(ev.content,''));
  select array_agg(e.id) into ids from entities e
  where e.id = 'me' or exists (
    select 1 from (select e.name as n union all select jsonb_array_elements_text(e.aliases)) names
    where length(n) > 2 and (position(lower(n) in hay) > 0
      or (length(split_part(n,' ',1)) > 3 and hay ~ ('\m' || lower(split_part(n,' ',1)) || '\M'))));
  return jsonb_build_object(
    'event', jsonb_build_object('id', ev.id, 'provider', ev.provider, 'date', ev.occurred_at, 'title', ev.title,
                                'consent_scope', ev.consent_scope, 'is_revision_of', ev.revision_of,
                                'content', left(ev.content, 150000)),
    'entities', (select coalesce(jsonb_agg(jsonb_build_object('id',id,'type',type,'name',name,'aliases',aliases)), '[]') from entities),
    'mentioned_entity_details', (select coalesce(jsonb_agg(to_jsonb(e) - 'created_at' - 'updated_at'), '[]') from entities e where e.id = any(ids)),
    'current_facts', (select coalesce(jsonb_agg(jsonb_build_object('subject',subject,'predicate',predicate,'value',value,
                        'valid_from',valid_from,'source',source_title)), '[]')
                      from (select * from current_facts where subject = any(ids) order by valid_from desc limit 400) f),
    'stories', (select coalesce(jsonb_agg(jsonb_build_object('id',id,'title',title)), '[]') from stories where status = 'active'),
    'open_commitments', (select coalesce(jsonb_agg(jsonb_build_object('id',id,'owner',owner,'beneficiary',beneficiary,
                           'action',action,'due_at',due_at,'status',status)), '[]')
                         from commitments where status in ('open','needs_review','unknown')));
end $$;

-- Upcoming meetings (next 36h) involving someone the brain knows, that don't have a briefing yet.
create or replace function briefing_candidates() returns jsonb language plpgsql stable as $$
declare out jsonb := '[]'; ev calendar_events; ids text[]; hay text;
begin
  for ev in select * from calendar_events where starts_at between now() and now() + interval '36 hours' order by starts_at loop
    if exists (select 1 from proposals where dedupe_key = 'prep:' || ev.uid || ':' || ev.starts_at) then continue; end if;
    hay := lower(coalesce(ev.title,'') || ' ' || ev.attendees::text || ' ' || coalesce(ev.description,''));
    select array_agg(e.id) into ids from entities e
    where e.type in ('person','org') and exists (
      select 1 from (select e.name as n union all select jsonb_array_elements_text(e.aliases)) names
      where length(n) > 3 and hay ~ ('\m' || regexp_replace(lower(n), '([.*+?^${}()|\[\]\\])', '\\\1', 'g') || '\M'));
    if ids is null or not exists (select 1 from entities where id = any(ids) and type = 'person') then continue; end if;
    out := out || jsonb_build_array(jsonb_build_object(
      'calendar_uid', ev.uid, 'starts_at', ev.starts_at, 'title', ev.title, 'attendees', ev.attendees,
      'people', (select jsonb_agg(to_jsonb(e) - 'created_at' - 'updated_at') from entities e where id = any(ids)),
      'facts', (select coalesce(jsonb_agg(jsonb_build_object('subject',subject,'predicate',predicate,'value',value,
                  'date',source_at,'source',source_title)), '[]') from current_facts where subject = any(ids)),
      'open_commitments', (select coalesce(jsonb_agg(jsonb_build_object('owner',owner,'beneficiary',beneficiary,
                  'action',action,'due_at',due_at,'since',source_at)), '[]')
                  from open_loops where owner = any(ids) or beneficiary = any(ids)),
      'past_interactions', (select coalesce(jsonb_agg(distinct jsonb_build_object('title',r.title,'date',r.occurred_at)), '[]')
                  from edges x join raw_events r on r.id = x.raw_event_id where x.src = any(ids) or x.dst = any(ids)),
      'my_priorities', (select coalesce(jsonb_agg(jsonb_build_object('predicate',predicate,'value',value)), '[]')
                  from current_facts where subject = 'me'
                  and (predicate like 'target_office%' or predicate = 'goal' or predicate like 'feedback:improve%'))));
    exit when jsonb_array_length(out) >= 3;
  end loop;
  return out;
end $$;

create or replace function save_briefing(p_calendar_uid text, p_starts_at timestamptz, p_title text, p_body text,
                                         p_entities jsonb default '[]') returns bigint language sql as $$
  insert into proposals (agent, kind, title, body, priority, dedupe_key, related)
  values ('prep', 'briefing', p_title, p_body, 1, 'prep:' || p_calendar_uid || ':' || p_starts_at,
          jsonb_build_object('calendar_uid', p_calendar_uid, 'entities', p_entities, 'prompt_version', 'briefing-v1'))
  on conflict (dedupe_key) do nothing
  returning id
$$;

-- Cursor for incremental Granola pulls
insert into kv (key, value) values ('granola_cursor', '"2026-10-28T00:00:00-04:00"') on conflict do nothing;
