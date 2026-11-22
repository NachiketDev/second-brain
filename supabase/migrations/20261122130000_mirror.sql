-- Mirror (22 Nov): the monthly performance review, like a boss with all the data. Verdict per goal box with evidence,
-- what went well and wrong named plainly, root-cause and excuse-check questions that quote his own diary words,
-- keep / rewrite / pause / drop per box, and dated commitments that open next month's review.
-- His answers and decisions are saved as he goes; goal changes apply only when he closes the review.

create table if not exists mirror_reviews (
  month date primary key,                    -- first day of the reviewed month
  answers jsonb not null default '{}',       -- {box_id: {text, at}}
  decisions jsonb not null default '{}',     -- {goal_id: {decision, new_title, note, at}}
  commitment_ids bigint[] not null default '{}',
  opened_at timestamptz not null default now(),
  closed_at timestamptz,
  summary_event bigint
);
alter table mirror_reviews enable row level security;

-- The month under review: the previous month during the first 10 days, otherwise this month.
create or replace function mirror_default_month() returns date
language sql stable as $$
  select case when extract(day from to_ny_date(now())) <= 10
              then (date_trunc('month', to_ny_date(now())) - interval '1 month')::date
              else date_trunc('month', to_ny_date(now()))::date end
$$;

create or replace function desk_mirror(p_month date default null) returns jsonb
language plpgsql stable set search_path = public, pg_temp as $$
declare
  m date := date_trunc('month', coalesce(p_month, mirror_default_month()))::date;
  t0 timestamptz := m::timestamp at time zone 'America/New_York';
  t1 timestamptz := (m + interval '1 month')::timestamp at time zone 'America/New_York';
  today date := to_ny_date(now());
  last_day date := least((m + interval '1 month')::date - 1, today);
  days_in numeric := greatest(1, (least((m + interval '1 month')::date, today + 1) - m));
  g record; boxes jsonb := '[]'; ev jsonb; qs jsonb; verdict text; tgt jsonb; worst numeric;
  n_done int; n_drop int; n_open int; n_over int; n_late int; hrs numeric; n_diary int; n_purs int; quote jsonb; short text;
begin
  for g in select * from goals where kind = 'box' and status <> 'retired' order by sort loop
    short := lower(split_part(g.title, ':', 1));
    with ids as (select id from goals where id = g.id or parent_id = g.id),
    c as (select c.* from commitments c left join pursuits p on p.id = c.pursuit_id
          where c.owner = 'me' and coalesce(c.goal_id, p.goal_id) in (select id from ids))
    select count(*) filter (where status = 'done' and completed_at >= t0 and completed_at < t1),
           count(*) filter (where status = 'dropped' and completed_at >= t0 and completed_at < t1),
           count(*) filter (where status in ('open','needs_review','unknown')),
           count(*) filter (where status in ('open','needs_review','unknown') and due_at < today),
           count(*) filter (where status = 'done' and completed_at >= t0 and completed_at < t1 and due_at is not null and to_ny_date(completed_at) > due_at)
      into n_done, n_drop, n_open, n_over, n_late from c;
    select round((coalesce(sum(extract(epoch from b.ends_at - b.starts_at)), 0) / 3600)::numeric, 1) into hrs
      from time_blocks b left join pursuits p on p.id = b.pursuit_id
      where coalesce(b.goal_id, p.goal_id) in (select id from goals where id = g.id or parent_id = g.id) and b.starts_at >= t0 and b.starts_at < t1;
    select count(*) into n_diary from diary_entries d where g.id = any(d.boxes) and d.day >= m and d.day <= last_day;
    select count(*) into n_purs from pursuits p where p.goal_id = g.id and p.status in ('active','paused');
    select coalesce(jsonb_agg(jsonb_build_object('action', a.title, 'weekly_target', a.weekly_target, 'unit', coalesce(a.unit, 'sessions'),
             'done', s.done, 'expected', round(a.weekly_target * days_in / 7))), '[]'),
           min(case when a.weekly_target * days_in / 7 >= 1 then s.done / (a.weekly_target * days_in / 7) end)
      into tgt, worst
      from goals a cross join lateral (select coalesce(sum(sessions), 0)::numeric as done from goal_sessions(a.id, m, last_day)) s
      where a.parent_id = g.id and a.weekly_target is not null and a.status = 'active';
    select jsonb_build_object('day', d.day, 'text', q->>'text') into quote
      from diary_entries d cross join lateral jsonb_array_elements(d.quotes) q
      where d.boxes = array[g.id] and d.day >= m and d.day <= last_day order by d.day desc limit 1;   -- a single-box day, so the quote is about this box

    verdict := case
      when n_done + n_drop + n_open + n_diary + n_purs = 0 and jsonb_array_length(tgt) = 0 and hrs = 0 then 'no_data'
      when coalesce(worst, 1) < 0.5 or n_over > n_done or (n_done = 0 and (n_open > 0 or n_drop > 0)) then 'failing'
      when coalesce(worst, 1) < 0.9 or n_over >= 1 or n_drop > n_done or n_late * 2 > n_done then 'behind'
      else 'on_track' end;

    ev := '[]';
    if verdict = 'no_data' then ev := ev || to_jsonb('Nothing is linked to this box yet: no tasks, pursuits, targets or diary days.'::text); end if;
    ev := ev || coalesce((select jsonb_agg(format('%s of %s %s for "%s" (target %s a week)', t->>'done', t->>'expected', t->>'unit', t->>'action', t->>'weekly_target'))
                          from jsonb_array_elements(tgt) t), '[]');
    if verdict <> 'no_data' then
      ev := ev || to_jsonb(format('%s done, %s dropped, %s still open (%s overdue)', n_done, n_drop, n_open, n_over));
    end if;
    if n_late > 0 then ev := ev || to_jsonb(format('%s finished after the due date', n_late)); end if;
    if hrs > 0 then ev := ev || to_jsonb(format('%s hours planned on the calendar', hrs)); end if;
    if n_diary > 0 then ev := ev || to_jsonb(format('In your diary on %s day%s', n_diary, case when n_diary = 1 then '' else 's' end)); end if;

    qs := '[]';
    if verdict in ('behind', 'failing') then
      qs := qs || to_jsonb(format('What actually took the time this month instead of %s?', short));
      if quote is not null then
        qs := qs || to_jsonb(format('On %s you said "%s". The record shows: %s. What happened between saying it and doing it?',
                    to_char((quote->>'day')::date, 'Dy DD Mon'), quote->>'text',
                    case when coalesce(worst, 1) < 0.9 then ev->>0 else format('%s done, %s dropped, %s overdue', n_done, n_drop, n_over) end));
      end if;
      qs := qs || to_jsonb('Was the reason outside your control, or a choice you would make again?'::text);
    elsif verdict = 'no_data' then
      qs := qs || to_jsonb('Do you still want this box? If yes, what is one thing that should count toward it each week?'::text);
    else
      qs := qs || to_jsonb('What made this work that you can repeat next month?'::text);
    end if;

    boxes := boxes || jsonb_build_object('id', g.id, 'box', g.box_key, 'title', g.title, 'tracker', g.tracker, 'status', g.status,
      'verdict', verdict, 'evidence', ev, 'questions', qs, 'targets', tgt, 'quote', quote,
      'counts', jsonb_build_object('done', n_done, 'dropped', n_drop, 'open', n_open, 'overdue', n_over, 'late', n_late,
                                   'hours', hrs, 'diary_days', n_diary, 'pursuits', n_purs),
      'actions', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'title', a.title, 'weekly_target', a.weekly_target) order by a.sort), '[]')
                  from goals a where a.parent_id = g.id and a.status = 'active'));
  end loop;

  return jsonb_build_object(
    'month', m, 'label', to_char(m, 'FMMonth YYYY'), 'through', last_day, 'partial', last_day < (m + interval '1 month')::date - 1,
    'approximate_note', case when m <= '2026-11-01'::date then
       'Completion dates before 17 Nov were backfilled, so late and dropped counts before then are approximate.' end,
    'center', (select title from goals where kind = 'center' limit 1),
    'boxes', boxes,
    'promises', (select jsonb_build_object('kept_on_time', count(*) filter (where status = 'done' and (due_at is null or to_ny_date(completed_at) <= due_at)),
                    'kept_late', count(*) filter (where status = 'done' and due_at is not null and to_ny_date(completed_at) > due_at),
                    'dropped', count(*) filter (where status = 'dropped'))
                 from commitments where owner = 'me' and status in ('done','dropped') and completed_at >= t0 and completed_at < t1)
               || jsonb_build_object('overdue_now', (select count(*) from commitments where owner = 'me' and status in ('open','needs_review','unknown') and due_at < today),
                    'owed_to_others_done', (select count(*) from commitments where owner = 'me' and beneficiary is not null and beneficiary <> 'me'
                                            and status = 'done' and completed_at >= t0 and completed_at < t1),
                    'owed_to_others_open', (select count(*) from commitments where owner = 'me' and beneficiary is not null and beneficiary <> 'me'
                                            and status in ('open','needs_review','unknown'))),
    'went_well', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'action', action, 'at', completed_at) order by completed_at desc), '[]')
                  from (select * from commitments where owner = 'me' and status = 'done' and completed_at >= t0 and completed_at < t1
                        and coalesce(is_event, false) = false order by completed_at desc limit 8) x),
    'went_wrong', (select coalesce(jsonb_agg(x order by x->>'kind', x->>'due'), '[]') from (
                     select jsonb_build_object('id', id, 'action', action, 'kind', 'dropped', 'due', due_at) x from commitments
                       where owner = 'me' and status = 'dropped' and completed_at >= t0 and completed_at < t1
                     union all
                     select jsonb_build_object('id', id, 'action', action, 'kind', 'late', 'due', due_at) from commitments
                       where owner = 'me' and status = 'done' and completed_at >= t0 and completed_at < t1 and due_at is not null and to_ny_date(completed_at) > due_at
                     union all
                     select jsonb_build_object('id', id, 'action', action, 'kind', 'overdue', 'due', due_at) from commitments
                       where owner = 'me' and status in ('open','needs_review','unknown') and due_at < today and due_at >= m - 31
                     order by 1 limit 40) s),
    'diary_days', (select count(*) from diary_entries where day >= m and day <= last_day),
    'last_review', (select jsonb_build_object('month', r.month, 'closed_at', r.closed_at,
                      'commitments', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'action', c.action, 'due', c.due_at, 'status', c.status)), '[]')
                                      from commitments c where c.id = any(r.commitment_ids)))
                    from mirror_reviews r where r.month = (m - interval '1 month')::date),
    'review', (select jsonb_build_object('answers', r.answers, 'decisions', r.decisions, 'closed_at', r.closed_at,
                 'commitments', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'action', c.action, 'due', c.due_at, 'status', c.status, 'goal_id', c.goal_id)), '[]')
                                 from commitments c where c.id = any(r.commitment_ids)))
               from mirror_reviews r where r.month = m));
end $$;

create or replace function brain_mirror_answer(p_month date, p_box text, p_answer text) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare m date := date_trunc('month', coalesce(p_month, mirror_default_month()))::date;
begin
  if not exists (select 1 from goals where id = p_box and kind = 'box') then raise exception 'unknown box %', p_box; end if;
  insert into mirror_reviews (month) values (m) on conflict do nothing;
  if (select closed_at from mirror_reviews where month = m) is not null then raise exception 'the % review is closed', to_char(m, 'FMMonth YYYY'); end if;
  update mirror_reviews set answers = case when coalesce(trim(p_answer), '') = '' then answers - p_box
                                           else answers || jsonb_build_object(p_box, jsonb_build_object('text', trim(p_answer), 'at', now())) end
  where month = m;
  return jsonb_build_object('month', m, 'box', p_box, 'result', 'saved');
end $$;

create or replace function brain_mirror_decide(p_month date, p_goal_id text, p_decision text, p_new_title text default null, p_note text default null) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare m date := date_trunc('month', coalesce(p_month, mirror_default_month()))::date;
begin
  if p_decision not in ('keep', 'rewrite', 'pause', 'drop', 'undecided') then raise exception 'decision must be keep, rewrite, pause or drop'; end if;
  if not exists (select 1 from goals where id = p_goal_id) then raise exception 'unknown goal %', p_goal_id; end if;
  if p_decision = 'rewrite' and coalesce(trim(p_new_title), '') = '' then raise exception 'a rewrite needs the new wording'; end if;
  insert into mirror_reviews (month) values (m) on conflict do nothing;
  if (select closed_at from mirror_reviews where month = m) is not null then raise exception 'the % review is closed', to_char(m, 'FMMonth YYYY'); end if;
  update mirror_reviews set decisions = case when p_decision = 'undecided' then decisions - p_goal_id
    else decisions || jsonb_build_object(p_goal_id, jsonb_build_object('decision', p_decision, 'new_title', nullif(trim(p_new_title), ''),
                                                                       'note', nullif(trim(p_note), ''), 'at', now())) end
  where month = m;
  return jsonb_build_object('month', m, 'goal', p_goal_id, 'decision', p_decision);
end $$;

-- A dated commitment from the review: a real task (copied to Google Tasks) that opens next month's review.
create or replace function brain_mirror_commit(p_month date, p_title text, p_due date, p_goal_id text default null) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare m date := date_trunc('month', coalesce(p_month, mirror_default_month()))::date; r jsonb;
begin
  if p_due is null then raise exception 'a review commitment needs a date'; end if;
  insert into mirror_reviews (month) values (m) on conflict do nothing;
  r := brain_add_task(p_title, p_due, null, p_goal_id, 'Committed in the ' || to_char(m, 'FMMonth YYYY') || ' Mirror review', 'checkin', null, null);
  update mirror_reviews set commitment_ids = array_append(commitment_ids, (r->>'id')::bigint) where month = m;
  return r || jsonb_build_object('month', m);
end $$;

-- Close: apply goal decisions (rewrite, pause, drop) and save the review as his own words for memory and the diary.
create or replace function brain_mirror_close(p_month date) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare m date := date_trunc('month', coalesce(p_month, mirror_default_month()))::date; r mirror_reviews; d record; applied int := 0; body text; ev bigint; snap jsonb;
begin
  select * into r from mirror_reviews where month = m for update;
  if not found then raise exception 'nothing recorded for the % review yet', to_char(m, 'FMMonth YYYY'); end if;
  if r.closed_at is not null then return jsonb_build_object('month', m, 'result', 'already closed'); end if;
  snap := desk_mirror(m);
  for d in select key as goal_id, value as v from jsonb_each(r.decisions) loop
    if d.v->>'decision' = 'rewrite' then perform brain_upsert_goal(jsonb_build_object('id', d.goal_id, 'title', d.v->>'new_title')); applied := applied + 1;
    elsif d.v->>'decision' = 'pause' then perform brain_upsert_goal(jsonb_build_object('id', d.goal_id, 'status', 'paused')); applied := applied + 1;
    elsif d.v->>'decision' = 'drop' then perform brain_upsert_goal(jsonb_build_object('id', d.goal_id, 'status', 'retired')); applied := applied + 1;
    end if;
  end loop;
  body := '## Mirror review, ' || to_char(m, 'FMMonth YYYY') || E'\n\n## Verdicts\n' ||
    coalesce((select string_agg('- ' || (b->>'title') || ': ' || replace(b->>'verdict', '_', ' ') || '. ' || coalesce((b->'evidence')->>0, ''), E'\n')
              from jsonb_array_elements(snap->'boxes') b), '') ||
    E'\n\n## In his words\n' ||
    coalesce((select string_agg('- ' || coalesce((select title from goals where id = a.key), a.key) || ': ' || (a.value->>'text'), E'\n')
              from jsonb_each(r.answers) a), '(no answers written)') ||
    E'\n\n## Goal decisions\n' ||
    coalesce((select string_agg('- ' || coalesce((select title from goals where id = x.key), x.key) || ': ' || (x.value->>'decision') ||
                                coalesce(' to "' || (x.value->>'new_title') || '"', '') || coalesce(' (' || (x.value->>'note') || ')', ''), E'\n')
              from jsonb_each(r.decisions) x), '(none)') ||
    E'\n\n## Commitments for next month\n' ||
    coalesce((select string_agg('- ' || c.action || ' by ' || to_char(c.due_at, 'Dy DD Mon'), E'\n') from commitments c where c.id = any(r.commitment_ids)), '(none)');
  ev := brain_record('checkin', 'Mirror review ' || to_char(m, 'FMMonth YYYY'), body, jsonb_build_object('checkin_kind', 'mirror', 'month', m));
  update mirror_reviews set closed_at = now(), summary_event = ev where month = m;
  return jsonb_build_object('month', m, 'result', 'closed', 'goal_changes', applied, 'source_event', ev);
end $$;

do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('mirror_default_month','desk_mirror','brain_mirror_answer','brain_mirror_decide',
                                                        'brain_mirror_commit','brain_mirror_close') loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
