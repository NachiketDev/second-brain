-- HBS ClassCards roster (22 Nov). The official directory export is ingested as one raw event (provider 'hbs_classcards')
-- and turned into a diff by brain_import_classcards, which goes through apply_diff like every other source.
-- Source columns (TSV): name, email, section letter, start-up Y/N. Class year comes from the email domain.
-- Kept: name, school email, section, class year, start-up experience. Not kept: phones, partner names.
-- Roster-only people (nothing known about them except the directory) stay out of the compiler's entity list,
-- the People constellation and the duplicate check, so ~900 classmates do not flood any of them.
-- The moment the brain learns anything else about a classmate (a meeting, an email, a commitment) they become normal.

create or replace function roster_only_ids() returns text[]
language sql stable set search_path = public, pg_temp as $$
  select coalesce(array_agg(e.id), '{}') from entities e
  where e.type = 'person' and e.id <> 'me'
    and e.created_at >= coalesce((select min(received_at) from raw_events where provider = 'hbs_classcards'), 'infinity')
    and exists (select 1 from facts f join raw_events r on r.id = f.raw_event_id
                where f.subject = e.id and r.provider = 'hbs_classcards')
    and not exists (select 1 from facts f left join raw_events r on r.id = f.raw_event_id
                    where f.subject = e.id and coalesce(r.provider, '') <> 'hbs_classcards')
    and not exists (select 1 from edges x left join raw_events r on r.id = x.raw_event_id
                    where (x.src = e.id or x.dst = e.id) and coalesce(r.provider, '') <> 'hbs_classcards')
    and not exists (select 1 from commitments c where c.owner = e.id or c.beneficiary = e.id)
    and not exists (select 1 from interactions i where i.entity_id = e.id)
$$;

create or replace function brain_import_classcards(p_raw_event_id bigint, p_apply boolean default false) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare ev raw_events; rec record; cand text; diff jsonb; rep jsonb; res jsonb;
  ev_note constant text := 'HBS ClassCards directory export (21 Nov 2026)';
begin
  select * into ev from raw_events where id = p_raw_event_id and provider = 'hbs_classcards';
  if not found then raise exception 'raw event % is not a ClassCards export', p_raw_event_id; end if;

  drop table if exists _cc;
  create temp table _cc on commit drop as
  with lines as (select l, n from regexp_split_to_table(ev.content, E'\n') with ordinality t(l, n) where n > 1 and l <> ''),
  t as (select n, split_part(l, E'\t', 1) as name, nullif(split_part(l, E'\t', 2), '') as email,
               nullif(split_part(l, E'\t', 3), '') as section, nullif(split_part(l, E'\t', 4), '') as su from lines),
  r as (select n, name, email, section, substring(email from '@mba(\d{4})\.') as yr,
               case su when 'Y' then 'Yes' when 'N' then 'No' end as startup,
               trim(both '-' from regexp_replace(lower(name), '[^a-z0-9]+', '-', 'g')) as slug from t)
  select r.*,
    (select c.entity_id from contacts c where c.kind = 'email' and r.email is not null
       and lower(c.value) = lower(r.email) limit 1) as by_email,
    (select case when count(*) = 1 then min(e.id) end from entities e
       where e.type in ('person', 'self') and (lower(e.name) = lower(r.name)
         or exists (select 1 from jsonb_array_elements_text(e.aliases) a
                    where lower(a) = lower(r.name) or (r.email is not null and lower(a) = lower(r.email))))) as by_name,
    null::text as eid
  from r;

  update _cc set eid = coalesce(by_email, by_name);
  for rec in select * from _cc where eid is null order by n loop
    cand := rec.slug;
    if exists (select 1 from entities where id = cand) or exists (select 1 from _cc where eid = cand)
       or (select count(*) from _cc where by_email is null and by_name is null and slug = rec.slug) > 1 then
      cand := rec.slug || '-hbs' || coalesce('-' || lower(rec.section), '');
      if exists (select 1 from entities where id = cand) or exists (select 1 from _cc where eid = cand) then
        cand := cand || '-' || rec.n;
      end if;
    end if;
    update _cc set eid = cand where n = rec.n;
  end loop;

  diff := jsonb_build_object(
    'entities', (select coalesce(jsonb_agg(x), '[]') from (
        select jsonb_build_object('id', c.eid, 'type', 'person', 'name', c.name, 'aliases', '[]'::jsonb,
                 'summary', 'HBS MBA ' || coalesce(c.yr, '') || coalesce(', Section ' || c.section, '') || '.') x
        from _cc c where c.by_email is null and c.by_name is null
        union all
        select jsonb_build_object('id', e.id, 'type', e.type, 'name', e.name, 'aliases', jsonb_build_array(c.name))
        from _cc c join entities e on e.id = c.eid
        where lower(e.name) <> lower(c.name)
          and not exists (select 1 from jsonb_array_elements_text(e.aliases) a where lower(a) = lower(c.name))) s),
    'claims', (select coalesce(jsonb_agg(jsonb_build_object('subject', c.eid, 'predicate', p.pred, 'value', p.val,
                  'kind', 'fact', 'class', 'observed', 'confidence', 0.95, 'evidence', ev_note,
                  'valid_from', ev.occurred_at)), '[]')
               from _cc c cross join lateral (values ('hbs_section', 'Section ' || c.section),
                                                     ('hbs_class', 'MBA ' || c.yr),
                                                     ('startup_experience', c.startup)) p(pred, val)
               where p.val is not null
                 and not exists (select 1 from facts f where f.subject = c.eid and f.predicate = p.pred
                                 and f.value = p.val and f.status = 'current')),
    'edges', (select coalesce(jsonb_agg(jsonb_build_object('src', c.eid, 'rel', 'studies_at', 'dst', 'hbs')), '[]')
              from _cc c where not exists (select 1 from edges x where x.src = c.eid and x.rel = 'studies_at' and x.dst = 'hbs')),
    'contacts', (select coalesce(jsonb_agg(jsonb_build_object('entity', c.eid, 'kind', 'email', 'value', c.email)), '[]')
                 from _cc c where c.email is not null and c.by_email is null));

  rep := jsonb_build_object(
    'rows', (select count(*) from _cc),
    'matched_by_email', (select count(*) from _cc where by_email is not null),
    'matched_by_name', (select count(*) from _cc where by_email is null and by_name is not null),
    'new_people', (select count(*) from _cc where by_email is null and by_name is null),
    'matched', (select coalesce(jsonb_agg(jsonb_build_object('id', eid, 'roster_name', name,
                  'how', case when by_email is not null then 'email' else 'name' end) order by name), '[]')
                from _cc where by_email is not null or by_name is not null),
    'suffixed_ids', (select coalesce(jsonb_agg(eid order by eid), '[]') from _cc
                     where by_email is null and by_name is null and eid <> slug),
    -- First-name-only people already in the brain with a section hint, and the classmates they might be.
    'section_candidates', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'name', e.name, 'section', s.sec,
                  'could_be', (select jsonb_agg(c.name order by c.name) from _cc c
                               where c.section = s.sec and lower(split_part(c.name, ' ', 1)) = lower(e.name)))), '[]')
               from entities e
               cross join lateral (select coalesce(substring(e.aliases::text from 'Section ([A-J])'),
                                                   upper(substring(e.id from '-section-([a-j])$')),
                                                   case when e.aliases::text ilike '%section-mate%' then 'B' end) as sec) s
               where e.type = 'person' and e.name !~ ' ' and s.sec is not null),
    'diff_sizes', jsonb_build_object('entities', jsonb_array_length(diff->'entities'), 'claims', jsonb_array_length(diff->'claims'),
                    'edges', jsonb_array_length(diff->'edges'), 'contacts', jsonb_array_length(diff->'contacts')));

  if not p_apply then return rep; end if;
  res := apply_diff(p_raw_event_id, diff, null);
  return rep || jsonb_build_object('applied', res);
end $$;

-- People constellation: leave roster-only classmates out (they would all sit under HBS).
create or replace function desk_people(p_org text default null) returns jsonb
language sql stable set search_path = public, pg_temp as $$
  with ro as (select unnest(roster_only_ids()) as id),
  person_org as (
    select e.id, e.name,
      coalesce((select o.dst from edges w join edges o on o.src = w.dst and o.rel = 'office_of'
                where w.src = e.id and w.rel = 'works_at' limit 1),
               (select w.dst from edges w where w.src = e.id and w.rel = 'works_at' limit 1),
               (select w.dst from edges w where w.src = e.id and w.rel = 'studies_at' limit 1),
               (select kv.value->>lower(split_part(c.value, '@', 2)) from contacts c, kv
                where kv.key = 'org_email_domains' and c.entity_id = e.id and c.kind = 'email'
                  and kv.value ? lower(split_part(c.value, '@', 2)) limit 1)) as org
    from entities e where e.type = 'person' and e.id <> 'me' and e.id not in (select id from ro)
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
      'unplaced', (select count(*) from person_org where org is null),
      'roster_only', (select count(*) from ro))
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

-- Compiler context: roster-only classmates are matched by full name only, and listed only when mentioned.
create or replace function brain_context(p_id bigint) returns jsonb
language plpgsql stable set search_path = public, pg_temp as $$
declare ev raw_events; hay text; ids text[]; thread text; ro text[];
begin
  select * into ev from raw_events where id = p_id;
  if not found then raise exception 'raw event % not found', p_id; end if;
  hay := lower(coalesce(ev.title,'') || ' ' || coalesce(ev.content,''));
  thread := ev.payload->>'thread_id';
  ro := roster_only_ids();
  select array_agg(e.id) into ids from entities e
  where e.id = 'me'
    or (not (e.id = any(ro)) and exists (
      select 1 from (select e.name as n union all select jsonb_array_elements_text(e.aliases)) names
      where length(n) > 2 and (position(lower(n) in hay) > 0
        or (length(split_part(n,' ',1)) > 3 and hay ~ ('\m' || lower(split_part(n,' ',1)) || '\M')))))
    or (e.id = any(ro) and position(lower(e.name) in hay) > 0)
    or (e.id = any(ro) and exists (select 1 from contacts c where c.entity_id = e.id and c.kind = 'email'
                                   and position(lower(c.value) in hay) > 0));
  return jsonb_build_object(
    'event', jsonb_build_object('id', ev.id, 'provider', ev.provider, 'date', ev.occurred_at, 'title', ev.title,
                                'consent_scope', ev.consent_scope, 'is_revision_of', ev.revision_of,
                                'thread_id', thread, 'from', ev.payload->>'from',
                                'content', left(ev.content, 150000)),
    'entities', (select coalesce(jsonb_agg(jsonb_build_object('id',id,'type',type,'name',name,'aliases',aliases)), '[]')
                 from entities where not (id = any(ro)) or id = any(ids)),
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
    'thread_open_commitments', case when thread is null then '[]'::jsonb else
      (select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'owner',c.owner,'action',c.action,'from_event',c.raw_event_id,
                 'event_date',r.occurred_at)), '[]')
       from commitments c join raw_events r on r.id = c.raw_event_id
       where r.payload->>'thread_id' = thread and r.id <> ev.id and c.status in ('open','needs_review','unknown')) end);
end $$;

-- Duplicate check: a roster-only classmate is flagged only against a first-name-only person with the same section hint.
create or replace function desk_trust() returns jsonb
language sql stable set search_path = public, pg_temp as $$
  with ro as (select unnest(roster_only_ids()) as id),
  hint as (select e.id, coalesce(substring(e.aliases::text from 'Section ([A-J])'), upper(substring(e.id from '-section-([a-j])$')),
                                 case when e.aliases::text ilike '%section-mate%' then 'B' end) as sec
           from entities e where e.type = 'person' and e.name !~ ' ')
  select jsonb_build_object(
    'stale', (select coalesce(jsonb_agg(jsonb_build_object('fact_id', f.id, 'subject', coalesce(e.name, f.subject),
                'predicate', f.predicate, 'value', left(f.value, 160), 'age_days', now()::date - f.valid_from::date,
                'limit_days', d.days) order by now()::date - f.valid_from::date - d.days desc), '[]')
              from current_facts f join fact_decay d on d.predicate = split_part(f.predicate, ':', 1)
              left join entities e on e.id = f.subject
              where f.valid_from < now() - make_interval(days => d.days)),
    'possible_duplicates', (select coalesce(jsonb_agg(jsonb_build_object('a', a.id, 'a_name', a.name, 'b', b.id, 'b_name', b.name)), '[]')
              from entities a join entities b on a.id < b.id and a.type = b.type and a.type = 'person'
              where (((lower(split_part(a.name, ' ', 1)) = lower(split_part(b.name, ' ', 1)) and (a.name !~ ' ' or b.name !~ ' '))
                       and not exists (select 1 from ro where ro.id in (a.id, b.id)))
                 or (lower(split_part(a.name, ' ', 1)) = lower(split_part(b.name, ' ', 1))
                     and exists (select 1 from ro where ro.id in (a.id, b.id))
                     and exists (select 1 from hint h join current_facts f on f.predicate = 'hbs_section' and f.value = 'Section ' || h.sec
                                 where (h.id = a.id and f.subject = b.id) or (h.id = b.id and f.subject = a.id))))
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
           where n.nspname = 'public' and p.proname in ('roster_only_ids','brain_import_classcards') loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
