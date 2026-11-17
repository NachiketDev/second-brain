-- Read and write functions behind the brain connector (MCP server in functions/brain-mcp).
-- The connector only calls these; it never runs free-form SQL.

-- Connector access token, generated inside the database.
do $$ begin
  if not exists (select 1 from vault.secrets where name = 'brain_mcp_secret') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(20), 'hex'), 'brain_mcp_secret');
  end if;
end $$;

-- Day window in New York time.
create or replace function ny_day(p_day date) returns tstzrange language sql stable as $$
  select tstzrange((p_day::timestamp) at time zone 'America/New_York',
                   ((p_day + 1)::timestamp) at time zone 'America/New_York')
$$;

create or replace function brain_schedule(p_start date, p_days int default 1) returns jsonb
language sql stable as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'day', to_char(starts_at at time zone 'America/New_York', 'Dy Mon DD'),
           'start', to_char(starts_at at time zone 'America/New_York', 'FMHH12:MI am'),
           'end', to_char(ends_at at time zone 'America/New_York', 'FMHH12:MI am'),
           'title', title, 'location', location,
           'clashes_with', (select jsonb_agg(o.title) from calendar_events o
                            where o.uid <> c.uid and o.starts_at < coalesce(c.ends_at, c.starts_at + interval '30 min')
                              and coalesce(o.ends_at, o.starts_at + interval '30 min') > c.starts_at))
         order by starts_at), '[]')
  from calendar_events c
  where starts_at >= ((p_start::timestamp) at time zone 'America/New_York')
    and starts_at <  (((p_start + greatest(p_days, 1))::timestamp) at time zone 'America/New_York')
$$;

create or replace function brain_hypotheses(p_limit int default 3) returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(jsonb_build_object('fact_id', f.id, 'about', e.name, 'guess', f.value,
           'predicate', f.predicate, 'why', f.evidence, 'confidence', f.confidence, 'source', r.title)), '[]')
  from (select * from facts where class = 'inferred' and status = 'current'
        order by confidence desc, learned_at desc limit p_limit) f
  join entities e on e.id = f.subject join raw_events r on r.id = f.raw_event_id
$$;

create or replace function brain_daily_brief(p_day date default null) returns jsonb language plpgsql stable as $$
declare d date := coalesce(p_day, (now() at time zone 'America/New_York')::date);
begin
  return jsonb_build_object(
    'date', to_char(d, 'Day, Mon DD'),
    'schedule', brain_schedule(d, 1),
    'tomorrow_first_events', (select coalesce(jsonb_agg(x), '[]') from
        (select jsonb_array_elements(brain_schedule(d + 1, 1)) x limit 3) t),
    'my_deadlines_next_7_days', (select coalesce(jsonb_agg(jsonb_build_object('commitment_id', id, 'action', action,
        'due', due_at, 'for', beneficiary, 'source', source_title) order by due_at), '[]')
        from open_loops where owner = 'me' and due_at is not null and due_at <= d + 7),
    'my_open_items_without_date', (select coalesce(jsonb_agg(jsonb_build_object('commitment_id', id, 'action', action,
        'for', beneficiary, 'since', source_at::date)), '[]')
        from (select * from open_loops where owner = 'me' and due_at is null and status = 'open'
              order by source_at desc limit 8) o),
    'owed_to_me', (select coalesce(jsonb_agg(jsonb_build_object('commitment_id', id, 'who', owner, 'action', action,
        'due', due_at, 'since', source_at::date)), '[]')
        from open_loops where beneficiary = 'me' and owner <> 'me' and status = 'open'),
    'needs_review', (select coalesce(jsonb_agg(jsonb_build_object('commitment_id', id, 'action', action)), '[]')
        from open_loops where status = 'needs_review'),
    'meeting_briefings', (select coalesce(jsonb_agg(jsonb_build_object('title', title, 'briefing', body)), '[]')
        from proposals where kind = 'briefing' and status = 'pending' and created_at > now() - interval '2 days'),
    'hypotheses_to_check', brain_hypotheses(3),
    'changed_last_24h', (select coalesce(jsonb_agg(summary), '[]') from
        (select summary from recent_changes where at > now() - interval '24 hours'
           and summary not like '%now current%' limit 15) c));
end $$;

create or replace function brain_search(p_query text, p_limit int default 12) returns jsonb
language plpgsql stable as $$
declare q text := '%' || replace(replace(trim(p_query), '%', ''), '_', '') || '%';
begin
  if length(trim(p_query)) < 2 then raise exception 'query too short'; end if;
  return jsonb_build_object(
    'people_and_orgs', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'type', type, 'name', name,
        'summary', summary)), '[]') from (select * from entities
        where name ilike q or aliases::text ilike q or summary ilike q limit p_limit) e),
    'facts', (select coalesce(jsonb_agg(jsonb_build_object('fact_id', id, 'subject', subject, 'predicate', predicate,
        'value', value, 'class', class, 'since', valid_from::date, 'source', source_title, 'source_event', raw_event_id)), '[]')
        from (select * from current_facts where value ilike q or evidence ilike q or predicate ilike q or subject ilike q
              order by valid_from desc limit p_limit) f),
    'commitments', (select coalesce(jsonb_agg(jsonb_build_object('commitment_id', id, 'owner', owner,
        'beneficiary', beneficiary, 'action', action, 'due', due_at, 'status', status)), '[]')
        from (select * from commitments where action ilike q or evidence ilike q or owner ilike q
              order by created_at desc limit p_limit) c),
    'stories', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'title', title, 'summary', summary)), '[]')
        from (select * from stories where title ilike q or summary ilike q limit 5) s),
    'sources', (select coalesce(jsonb_agg(jsonb_build_object('source_event', id, 'title', title, 'date', occurred_at::date,
        'kind', kind)), '[]')
        from (select * from raw_events where consent_scope <> 'exclude' and (title ilike q or content ilike q)
              order by occurred_at desc limit 8) r));
end $$;

create or replace function brain_person(p_name text) returns jsonb language plpgsql stable as $$
declare e entities; n int;
begin
  select count(*) into n from entities where id = p_name or name ilike p_name or aliases::text ilike '%"' || p_name || '"%'
     or name ilike '%' || p_name || '%';
  select * into e from entities where id = p_name or name ilike p_name or aliases::text ilike '%"' || p_name || '"%'
     or name ilike '%' || p_name || '%'
  order by (id = p_name) desc, (name ilike p_name) desc, length(name) limit 1;
  if not found then return jsonb_build_object('found', false); end if;
  return jsonb_build_object('found', true, 'other_matches', n - 1,
    'entity', to_jsonb(e) - 'created_at',
    'facts', (select coalesce(jsonb_agg(jsonb_build_object('fact_id', id, 'predicate', predicate, 'value', value,
        'class', class, 'since', valid_from::date, 'source', source_title) order by valid_from desc), '[]')
        from current_facts where subject = e.id),
    'history', (select coalesce(jsonb_agg(jsonb_build_object('predicate', predicate, 'old_value', value,
        'until', valid_to::date) order by valid_to desc), '[]')
        from facts where subject = e.id and status = 'superseded'),
    'open_commitments', (select coalesce(jsonb_agg(jsonb_build_object('commitment_id', id, 'owner', owner,
        'beneficiary', beneficiary, 'action', action, 'due', due_at, 'status', status)), '[]')
        from open_loops where owner = e.id or beneficiary = e.id),
    'connections', (select coalesce(jsonb_agg(distinct jsonb_build_object('rel', rel,
        'with', case when src = e.id then dst else src end)), '[]')
        from edges where src = e.id or dst = e.id),
    'interactions', (select coalesce(jsonb_agg(jsonb_build_object('source_event', id, 'title', title,
        'date', occurred_at::date, 'kind', kind) order by occurred_at desc), '[]')
        from raw_events where id in (select raw_event_id from edges where src = e.id or dst = e.id
                                     union select raw_event_id from facts where subject = e.id)));
end $$;

create or replace function brain_open_commitments(p_who text default 'all') returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(jsonb_build_object('commitment_id', id, 'owner', owner, 'beneficiary', beneficiary,
           'action', action, 'due', due_at, 'status', status, 'since', source_at::date, 'source', source_title)
         order by due_at nulls last, source_at desc), '[]')
  from open_loops
  where case p_who when 'me' then owner = 'me' when 'others' then owner <> 'me' else true end
$$;

create or replace function brain_evidence(p_event_id bigint) returns jsonb language sql stable as $$
  select case when consent_scope = 'exclude' then jsonb_build_object('error', 'excluded source')
         else jsonb_build_object('source_event', id, 'provider', provider, 'kind', kind, 'title', title,
           'date', occurred_at, 'url', payload->>'url', 'content', left(content, 12000)) end
  from raw_events where id = p_event_id
$$;

-- A check-in, confirmation or correction is stored as a raw event (immutable evidence) first.
create or replace function brain_record(p_kind text, p_title text, p_content text, p_payload jsonb default '{}')
returns bigint language plpgsql as $$
declare r jsonb;
begin
  if p_kind not in ('checkin', 'correction', 'confirmation') then raise exception 'bad kind %', p_kind; end if;
  r := ingest_raw(p_kind, p_kind || '-' || gen_random_uuid()::text, now(), p_title, p_content, null, p_kind,
                  p_payload || jsonb_build_object('via', 'brain-connector'));
  return (r->>'id')::bigint;
end $$;

create or replace function brain_confirm_hypothesis(p_fact_id bigint, p_note text default null) returns jsonb
language plpgsql as $$
declare f facts; ev bigint; nid bigint;
begin
  select * into f from facts where id = p_fact_id and class = 'inferred' and status = 'current';
  if not found then raise exception 'no open hypothesis with id %', p_fact_id; end if;
  ev := brain_record('confirmation', 'Confirmed: ' || f.value,
          format('the user confirmed the hypothesis "%s" (%s). %s', f.value, f.predicate, coalesce(p_note, '')));
  update raw_events set status = 'compiled', compiled_at = now() where id = ev;
  perform set_config('brain.raw_event_id', ev::text, true);
  perform set_config('brain.run_id', 'user-confirmation', true);
  perform set_config('brain.reason', 'confirmed by the user' || coalesce(': ' || p_note, ''), true);
  update facts set status = 'superseded', valid_to = now() where id = f.id;
  insert into facts (subject, predicate, value, value_entity, kind, class, confidence, valid_from, raw_event_id,
                     evidence, supersedes, run_id, status)
  values (f.subject, f.predicate, f.value, f.value_entity,
          case when f.kind = 'hypothesis' then 'fact' else f.kind end, 'declared', 1.0, now(), ev,
          'Confirmed by the user' || coalesce(': ' || p_note, ''), f.id, 'user-confirmation', 'current')
  returning id into nid;
  return jsonb_build_object('confirmed', f.value, 'new_fact_id', nid);
end $$;

create or replace function brain_reject_hypothesis(p_fact_id bigint, p_note text default null) returns jsonb
language plpgsql as $$
declare f facts; ev bigint;
begin
  select * into f from facts where id = p_fact_id and class = 'inferred' and status = 'current';
  if not found then raise exception 'no open hypothesis with id %', p_fact_id; end if;
  ev := brain_record('confirmation', 'Rejected: ' || f.value,
          format('the user rejected the hypothesis "%s" (%s). %s', f.value, f.predicate, coalesce(p_note, '')));
  update raw_events set status = 'compiled', compiled_at = now() where id = ev;
  perform set_config('brain.raw_event_id', ev::text, true);
  perform set_config('brain.run_id', 'user-confirmation', true);
  perform set_config('brain.reason', 'rejected by the user' || coalesce(': ' || p_note, ''), true);
  update facts set status = 'retracted', valid_to = now() where id = f.id;
  return jsonb_build_object('rejected', f.value);
end $$;

-- Lock everything down to the service role, like the rest of the brain.
do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('ny_day','brain_schedule','brain_hypotheses','brain_daily_brief',
             'brain_search','brain_person','brain_open_commitments','brain_evidence','brain_record',
             'brain_confirm_hypothesis','brain_reject_hypothesis') loop
    execute format('alter function %s set search_path = public, pg_temp', f.sig);
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
