-- Diary (22 Nov). One entry per day, written from what the user said that day (check-ins, calls, corrections,
-- answers, Bee conversations) by the scheduled compile run, in his own words where possible. He can edit any entry;
-- once he has, the compiler leaves that day alone. Every version is kept in diary_revisions.
-- Mood is recorded only when he stated it. The diary feeds the Mirror (his words for the month).

create table if not exists diary_entries (
  day date primary key,
  body text not null,
  mood text,                                   -- only as he said it
  quotes jsonb not null default '[]',          -- [{text, source_id}]
  people text[] not null default '{}',         -- entity ids
  pursuits text[] not null default '{}',
  boxes text[] not null default '{}',          -- goal box ids, e.g. box:social
  source_ids bigint[] not null default '{}',
  written_by text not null default 'compiler' check (written_by in ('compiler', 'his')),
  compiled_at timestamptz,
  his_edited_at timestamptz,
  run_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists diary_revisions (
  id bigserial primary key,
  day date not null,
  body text not null,
  mood text,
  written_by text not null,
  at timestamptz not null default now()
);
create index if not exists diary_revisions_day on diary_revisions (day, at desc);

alter table diary_entries enable row level security;
alter table diary_revisions enable row level security;

-- Which raw sources feed the diary. Bee transcripts are long: the summary at the top is enough.
create or replace function diary_source_providers() returns text[]
language sql immutable as $$ select array['checkin','correction','confirmation','claude_chat','bee','voice','note'] $$;

create or replace function to_ny_date(t timestamptz) returns date
language sql immutable as $$ select (t at time zone 'America/New_York')::date $$;

-- A diary day runs to 4am New York time, so a late evening check-in belongs to the day it describes.
create or replace function diary_day(t timestamptz) returns date
language sql immutable as $$ select ((t at time zone 'America/New_York') - interval '4 hours')::date $$;

-- Everything the compiler needs to write one day's entry.
create or replace function brain_diary_sources(p_day date) returns jsonb
language sql stable set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'day', p_day,
    'existing', (select jsonb_build_object('body', body, 'mood', mood, 'written_by', written_by, 'his_edited_at', his_edited_at)
                 from diary_entries where day = p_day),
    'said', (select coalesce(jsonb_agg(jsonb_build_object('source_id', r.id, 'provider', r.provider, 'title', r.title,
                 'at', r.occurred_at, 'content', left(r.content, case when r.provider = 'bee' then 4000 else 12000 end))
                 order by r.occurred_at), '[]')
             from raw_events r where r.provider = any(diary_source_providers()) and r.status <> 'skipped'
               and r.consent_scope <> 'exclude' and diary_day(r.occurred_at) = p_day and not (r.payload ? 'forgotten')),
    'calendar', (select coalesce(jsonb_agg(jsonb_build_object('title', e.title, 'start', e.starts_at, 'end', e.ends_at,
                 'location', e.location) order by e.starts_at), '[]')
                 from calendar_events e where to_ny_date(e.starts_at) = p_day),
    'done', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'action', c.action, 'status', c.status)), '[]')
             from commitments c where c.owner = 'me' and c.status in ('done','dropped') and diary_day(c.completed_at) = p_day),
    'promised', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'owner', c.owner, 'beneficiary', c.beneficiary,
                 'action', c.action, 'due', c.due_at)), '[]')
                 from commitments c where diary_day(c.created_at) = p_day and (c.owner = 'me' or c.beneficiary = 'me')),
    'people_seen', (select coalesce(jsonb_agg(distinct jsonb_build_object('id', i.entity_id, 'name', e.name, 'how', i.channel)), '[]')
                    from interactions i join entities e on e.id = i.entity_id where diary_day(i.at) = p_day),
    'boxes', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'title', title) order by sort), '[]')
              from goals where kind = 'box' and status = 'active'));
$$;

-- Days in the last p_days that need an entry written or refreshed (a source arrived after the entry was written).
-- Days he edited himself are never listed.
create or replace function brain_diary_pending(p_days int default 7) returns jsonb
language sql stable set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('day', d.day, 'sources', d.n, 'has_entry', de.day is not null) order by d.day), '[]')
  from (select diary_day(r.occurred_at) as day, count(*) n, max(r.received_at) newest
        from raw_events r where r.provider = any(diary_source_providers()) and r.status <> 'skipped'
          and r.consent_scope <> 'exclude' and not (r.payload ? 'forgotten')
          and r.occurred_at > now() - make_interval(days => p_days)
        group by 1) d
  left join diary_entries de on de.day = d.day
  where de.his_edited_at is null and (de.day is null or d.newest > de.compiled_at);
$$;

-- Compiler write. Unknown people or pursuit ids are dropped rather than failing the entry.
create or replace function brain_save_diary(p_day date, p_entry jsonb, p_run_id text default null) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare cur diary_entries; ppl text[]; prs text[]; bxs text[];
begin
  if coalesce(trim(p_entry->>'body'), '') = '' then raise exception 'diary entry needs a body'; end if;
  select * into cur from diary_entries where day = p_day for update;
  if found and cur.his_edited_at is not null then
    return jsonb_build_object('result', 'kept_his_edit', 'day', p_day);
  end if;
  select coalesce(array_agg(x), '{}') into ppl from jsonb_array_elements_text(coalesce(p_entry->'people', '[]')) x
    where exists (select 1 from entities where id = x and type in ('person','self'));
  select coalesce(array_agg(x), '{}') into prs from jsonb_array_elements_text(coalesce(p_entry->'pursuits', '[]')) x
    where exists (select 1 from pursuits where id = x);
  select coalesce(array_agg(x), '{}') into bxs from jsonb_array_elements_text(coalesce(p_entry->'boxes', '[]')) x
    where exists (select 1 from goals where id = x and kind = 'box');
  insert into diary_entries as d (day, body, mood, quotes, people, pursuits, boxes, source_ids, written_by, compiled_at, run_id)
  values (p_day, trim(p_entry->>'body'), nullif(trim(p_entry->>'mood'), ''), coalesce(p_entry->'quotes', '[]'), ppl, prs, bxs,
          coalesce((select array_agg(x::bigint) from jsonb_array_elements_text(coalesce(p_entry->'source_ids', '[]')) x), '{}'),
          'compiler', now(), p_run_id)
  on conflict (day) do update set body = excluded.body, mood = excluded.mood, quotes = excluded.quotes, people = excluded.people,
    pursuits = excluded.pursuits, boxes = excluded.boxes, source_ids = excluded.source_ids, compiled_at = now(),
    run_id = excluded.run_id, updated_at = now();
  insert into diary_revisions (day, body, mood, written_by) values (p_day, trim(p_entry->>'body'), nullif(trim(p_entry->>'mood'), ''), 'compiler');
  return jsonb_build_object('result', case when cur.day is null then 'written' else 'refreshed' end, 'day', p_day,
                            'people', ppl, 'pursuits', prs, 'boxes', bxs);
end $$;

-- His edit. From then on the compiler leaves the day alone.
create or replace function brain_edit_diary(p_day date, p_body text, p_mood text default null) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
begin
  if coalesce(trim(p_body), '') = '' then raise exception 'diary entry needs a body'; end if;
  insert into diary_entries as d (day, body, mood, written_by, his_edited_at)
  values (p_day, trim(p_body), nullif(trim(p_mood), ''), 'his', now())
  on conflict (day) do update set body = excluded.body, mood = excluded.mood, written_by = 'his', his_edited_at = now(), updated_at = now();
  insert into diary_revisions (day, body, mood, written_by) values (p_day, trim(p_body), nullif(trim(p_mood), ''), 'his');
  return jsonb_build_object('result', 'saved', 'day', p_day);
end $$;

-- Diary screen: a month of entries (or a search across all), plus a calendar strip of which days have an entry.
create or replace function desk_diary(p_month text default null, p_q text default null) returns jsonb
language sql stable set search_path = public, pg_temp as $$
  with m as (select coalesce(to_date(p_month || '-01', 'YYYY-MM-DD'), date_trunc('month', to_ny_date(now()))::date) as start),
  pick as (
    select d.* from diary_entries d, m
    where case when nullif(trim(p_q), '') is not null then d.body ilike '%' || trim(p_q) || '%' or d.mood ilike '%' || trim(p_q) || '%'
               else d.day >= m.start and d.day < (m.start + interval '1 month')::date end
    order by d.day desc limit 62)
  select jsonb_build_object(
    'month', to_char((select start from m), 'YYYY-MM'),
    'query', nullif(trim(p_q), ''),
    'today', to_ny_date(now()),
    'entries', (select coalesce(jsonb_agg(jsonb_build_object(
        'day', p.day, 'body', p.body, 'mood', p.mood, 'quotes', p.quotes, 'written_by', p.written_by,
        'edited', p.his_edited_at is not null, 'updated_at', p.updated_at,
        'people', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'name', e.name)), '[]') from entities e where e.id = any(p.people)),
        'pursuits', (select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'title', q.title)), '[]') from pursuits q where q.id = any(p.pursuits)),
        'boxes', (select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'title', g.title)), '[]') from goals g where g.id = any(p.boxes)),
        'sources', cardinality(p.source_ids)) order by p.day desc), '[]') from pick p),
    'days', (select coalesce(jsonb_agg(jsonb_build_object('day', d.day, 'has_entry', true, 'mood', d.mood) order by d.day), '[]')
             from diary_entries d, m where d.day >= m.start and d.day < (m.start + interval '1 month')::date),
    'waiting', brain_diary_pending(7));
$$;

do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('brain_diary_sources','brain_diary_pending','brain_save_diary',
                                                        'brain_edit_diary','desk_diary','diary_source_providers','to_ny_date','diary_day') loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
