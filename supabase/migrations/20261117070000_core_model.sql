-- Core model rebuild, step 3 (17 Nov 2026). Additive only: new tables, new columns, new functions,
-- one new trigger. Nothing existing is dropped, renamed or redefined; brain_desk, apply_diff v1 and the
-- desk function keep working unchanged.
-- Spine: goals -> pursuits -> commitments (the one task store) -> time_blocks -> people and evidence.

-- ── Goals: the mandala chart as data ──────────────────────────────────────────────────────────────
create table if not exists goals (
  id             text primary key,                 -- 'center', 'box:career', 'action:career:case-prep'
  kind           text not null check (kind in ('center', 'box', 'action')),
  parent_id      text references goals(id),
  box_key        text,                             -- career, wealth, social, party, unique, body, together, impact
  title          text not null,
  weekly_target  numeric,
  unit           text,
  sort           int not null default 0,
  status         text not null default 'active' check (status in ('active', 'paused', 'retired')),
  source_fact_id bigint references facts(id),
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

-- ── Pursuits: what the workbench lists (separate from stories, which stay as history) ─────────────
create table if not exists pursuits (
  id          text primary key,                    -- 'recruiting', 'firm:bcg', 'cfi-sea-rangers'
  parent_id   text references pursuits(id),
  kind        text not null check (kind in ('area', 'firm', 'project', 'workstream')),
  title       text not null,
  goal_id     text references goals(id),
  stage       text check (stage in ('researching', 'networking', 'applied', 'test', 'first round',
                                    'final round', 'offer', 'closed')),
  deadline    date,
  status      text not null default 'active' check (status in ('active', 'paused', 'done', 'dropped')),
  summary     text,
  summary_at  timestamptz,
  story_id    text references stories(id),
  org_entity  text references entities(id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists pursuits_parent on pursuits (parent_id);

-- ── Commitments become the one task store ─────────────────────────────────────────────────────────
alter table commitments add column if not exists pursuit_id    text references pursuits(id);
alter table commitments add column if not exists goal_id       text references goals(id);
alter table commitments add column if not exists source        text not null default 'compiler'
  check (source in ('compiler', 'checkin', 'voice', 'desk', 'google', 'backfill'));
alter table commitments add column if not exists gtask_id      text;
alter table commitments add column if not exists gtask_state   text
  check (gtask_state in ('to_create', 'to_update', 'synced', 'to_complete', 'to_reopen', 'error'));
alter table commitments add column if not exists estimate_min  int check (estimate_min > 0);
alter table commitments add column if not exists completed_at  timestamptz;
create unique index if not exists commitments_gtask on commitments (gtask_id) where gtask_id is not null;
create index if not exists commitments_pursuit on commitments (pursuit_id);

-- ── Big 3 per day, set by the morning check-in ────────────────────────────────────────────────────
create table if not exists day_priorities (
  day           date not null,
  rank          smallint not null check (rank between 1 and 3),
  commitment_id bigint not null references commitments(id),
  set_by        text not null default 'checkin',
  set_at        timestamptz not null default now(),
  primary key (day, rank)
);

-- ── Planning table ────────────────────────────────────────────────────────────────────────────────
create table if not exists time_blocks (
  id            bigserial primary key,
  commitment_id bigint references commitments(id),
  pursuit_id    text references pursuits(id),
  goal_id       text references goals(id),
  title         text,
  starts_at     timestamptz not null,
  ends_at       timestamptz not null,
  kind          text not null default 'planned' check (kind in ('planned', 'actual')),
  gcal_event_id text,
  gcal_state    text check (gcal_state in ('to_create', 'to_update', 'to_delete', 'synced', 'error')),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check (ends_at > starts_at)
);
create index if not exists time_blocks_start on time_blocks (starts_at);

-- ── Contacts (star view) ──────────────────────────────────────────────────────────────────────────
create table if not exists contacts (
  id           bigserial primary key,
  entity_id    text not null references entities(id),
  kind         text not null check (kind in ('email', 'linkedin', 'phone')),
  value        text not null,
  raw_event_id bigint references raw_events(id),
  created_at   timestamptz not null default now(),
  unique (entity_id, kind, value)
);

-- ── Lessons that age ──────────────────────────────────────────────────────────────────────────────
alter table patterns add column if not exists first_seen timestamptz;
alter table patterns add column if not exists last_seen  timestamptz;
alter table patterns add column if not exists status     text not null default 'active'
  check (status in ('active', 'resolved', 'retired'));
alter table patterns add column if not exists pursuit_id text references pursuits(id);

-- ── Staleness per fact type ───────────────────────────────────────────────────────────────────────
create table if not exists fact_decay (predicate text primary key, days int not null check (days > 0));
insert into fact_decay values ('role', 120), ('title', 120), ('works_at', 90), ('office', 90),
  ('relationship', 90), ('interest', 45), ('offers_help', 45), ('plan', 21), ('priority', 14)
on conflict do nothing;

-- ── Interactions: real contact (met, emailed, called), not mentions ───────────────────────────────
create or replace view interactions with (security_invoker = true) as
  select case when x.src = 'me' then x.dst else x.src end as entity_id, r.occurred_at as at,
         x.rel as channel, x.raw_event_id, r.title
  from edges x join raw_events r on r.id = x.raw_event_id
  where 'me' in (x.src, x.dst) and x.src <> x.dst
    and x.rel in ('coffee_chat', 'emailed', 'met', 'called', 'interviewed', 'mock_case', 'coached')
  union
  select c.entity_id, r.occurred_at, 'email', r.id, r.title
  from raw_events r join contacts c on c.kind = 'email' and lower(c.value) = lower(r.payload->>'from')
  where r.provider = 'hbs_email';

-- ── Lifecycle: when a commitment closes or reopens ────────────────────────────────────────────────
-- BEFORE: stamp completed_at and flag the Google copy. AFTER: expire its pending suggestions and touch
-- its pursuit. Applies to every write path (desk, voice, compiler, Google sync).
create or replace function commitment_lifecycle_before() returns trigger language plpgsql
set search_path = public, pg_temp as $$
begin
  if new.status in ('done', 'dropped') and old.status not in ('done', 'dropped') then
    new.completed_at := coalesce(new.completed_at, now());
    if new.gtask_id is not null and coalesce(current_setting('brain.via', true), '') <> 'google' then
      new.gtask_state := 'to_complete';
    end if;
  elsif new.status not in ('done', 'dropped') and old.status in ('done', 'dropped') then
    new.completed_at := null;
    if new.gtask_id is not null and coalesce(current_setting('brain.via', true), '') <> 'google' then
      new.gtask_state := 'to_reopen';
    end if;
  end if;
  return new;
end $$;

create or replace function commitment_lifecycle_after() returns trigger language plpgsql
set search_path = public, pg_temp as $$
begin
  if new.status in ('done', 'dropped') and old.status not in ('done', 'dropped') then
    update proposals set status = 'expired', decided_at = now(),
      result = coalesce(result, '{}'::jsonb) || jsonb_build_object('expired', 'commitment ' || new.status)
    where status = 'pending' and related->>'commitment_id' = new.id::text;
  end if;
  if new.pursuit_id is not null and (new.status is distinct from old.status or new.pursuit_id is distinct from old.pursuit_id) then
    update pursuits set updated_at = now() where id = new.pursuit_id;
  end if;
  return null;
end $$;

drop trigger if exists commitments_lifecycle_before on commitments;
create trigger commitments_lifecycle_before before update of status on commitments
  for each row execute function commitment_lifecycle_before();
drop trigger if exists commitments_lifecycle_after on commitments;
create trigger commitments_lifecycle_after after update on commitments
  for each row execute function commitment_lifecycle_after();

-- ── Write paths ───────────────────────────────────────────────────────────────────────────────────
-- Every task he adds (voice, desk, check-in) becomes a commitment first; Google Tasks gets a copy.
create or replace function brain_add_task(p_title text, p_due date default null, p_pursuit_id text default null,
  p_goal_id text default null, p_notes text default null, p_source text default 'voice',
  p_gtask_id text default null, p_estimate_min int default null) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare ev bigint; cid bigint; t text := nullif(trim(p_title), '');
begin
  if t is null then raise exception 'Task title cannot be empty'; end if;
  if p_source not in ('checkin', 'voice', 'desk', 'google', 'backfill') then raise exception 'bad source %', p_source; end if;
  if p_gtask_id is not null then
    select id into cid from commitments where gtask_id = p_gtask_id;
    if found then return jsonb_build_object('id', cid, 'result', 'exists'); end if;
  end if;
  ev := (ingest_raw(p_source, coalesce('gtask-' || p_gtask_id, p_source || '-task-' || gen_random_uuid()::text), now(),
                    'Task: ' || t, coalesce(p_notes, t), null, 'task', jsonb_build_object('via', 'brain_add_task'))->>'id')::bigint;
  update raw_events set status = 'compiled', compiled_at = now() where id = ev and status = 'pending';
  perform set_config('brain.raw_event_id', ev::text, true);
  perform set_config('brain.run_id', 'task-' || p_source, true);
  perform set_config('brain.reason', 'task added by Nachiket (' || p_source || ')', true);
  insert into commitments (owner, beneficiary, action, due_at, status, raw_event_id, evidence, run_id,
                           pursuit_id, goal_id, source, gtask_id, gtask_state, estimate_min)
  values ('me', null, t, p_due, 'open', ev, coalesce(p_notes, 'Added by Nachiket via ' || p_source), 'task-' || p_source,
          p_pursuit_id, p_goal_id, p_source, p_gtask_id,
          case when p_gtask_id is null then 'to_create' else 'synced' end, p_estimate_min)
  returning id into cid;
  return jsonb_build_object('id', cid, 'result', 'created');
end $$;

-- Close or reopen one commitment from any surface. p_source 'google' means the tick came from Google
-- Tasks, so the copy is not written back.
create or replace function brain_complete(p_id bigint, p_status text default 'done', p_source text default 'desk',
  p_note text default null) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare c commitments;
begin
  select * into c from commitments where id = p_id;
  if not found then raise exception 'Commitment % not found', p_id; end if;
  if p_status not in ('done', 'dropped', 'open') then raise exception 'Status must be done, dropped or open'; end if;
  if c.status = p_status then return jsonb_build_object('id', p_id, 'status', p_status, 'result', 'unchanged'); end if;
  perform set_config('brain.via', p_source, true);
  perform decide_commitment(p_id, p_status,
    coalesce(p_note, format('Nachiket marked it %s (%s)', p_status, p_source)));
  return jsonb_build_object('id', p_id, 'status', p_status, 'result', 'changed');
end $$;

-- Relink or edit one of his commitments: pursuit, goal box, due date, estimate, wording.
create or replace function brain_set_commitment(p_id bigint, p_fields jsonb) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare k text;
begin
  for k in select jsonb_object_keys(p_fields) loop
    if k not in ('pursuit_id', 'goal_id', 'due_at', 'estimate_min', 'action') then raise exception 'Field % cannot be set', k; end if;
  end loop;
  perform set_config('brain.reason', 'edited by Nachiket', true);
  perform set_config('brain.run_id', 'user-edit', true);
  update commitments set
    pursuit_id   = case when p_fields ? 'pursuit_id' then nullif(p_fields->>'pursuit_id', '') else pursuit_id end,
    goal_id      = case when p_fields ? 'goal_id' then nullif(p_fields->>'goal_id', '') else goal_id end,
    due_at       = case when p_fields ? 'due_at' then nullif(p_fields->>'due_at', '')::date else due_at end,
    estimate_min = case when p_fields ? 'estimate_min' then nullif(p_fields->>'estimate_min', '')::int else estimate_min end,
    action       = case when p_fields ? 'action' then coalesce(nullif(trim(p_fields->>'action'), ''), action) else action end,
    gtask_state  = case when gtask_id is not null and (p_fields ? 'action' or p_fields ? 'due_at') then 'to_update' else gtask_state end,
    updated_at   = now()
  where id = p_id;
  if not found then raise exception 'Commitment % not found', p_id; end if;
  return jsonb_build_object('id', p_id, 'updated', p_fields);
end $$;

create or replace function brain_set_priorities(p_day date, p_ids bigint[], p_set_by text default 'checkin') returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare i int;
begin
  if coalesce(array_length(p_ids, 1), 0) > 3 then raise exception 'At most 3 priorities'; end if;
  delete from day_priorities where day = p_day;
  for i in 1 .. coalesce(array_length(p_ids, 1), 0) loop
    insert into day_priorities (day, rank, commitment_id, set_by) values (p_day, i, p_ids[i], p_set_by);
  end loop;
  return jsonb_build_object('day', p_day, 'priorities', to_jsonb(p_ids));
end $$;

create or replace function brain_plan_block(p_starts timestamptz, p_ends timestamptz, p_commitment_id bigint default null,
  p_pursuit_id text default null, p_goal_id text default null, p_title text default null, p_kind text default 'planned') returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare bid bigint; c commitments;
begin
  if p_commitment_id is not null then select * into c from commitments where id = p_commitment_id; end if;
  insert into time_blocks (commitment_id, pursuit_id, goal_id, title, starts_at, ends_at, kind, gcal_state)
  values (p_commitment_id, coalesce(p_pursuit_id, c.pursuit_id), coalesce(p_goal_id, c.goal_id),
          coalesce(nullif(trim(p_title), ''), c.action), p_starts, p_ends, p_kind,
          case when p_kind = 'planned' then 'to_create' end)
  returning id into bid;
  return jsonb_build_object('id', bid);
end $$;

create or replace function brain_move_block(p_id bigint, p_starts timestamptz, p_ends timestamptz) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
begin
  update time_blocks set starts_at = p_starts, ends_at = p_ends, updated_at = now(),
    gcal_state = case when gcal_event_id is not null then 'to_update' else gcal_state end
  where id = p_id;
  if not found then raise exception 'Block % not found', p_id; end if;
  return jsonb_build_object('id', p_id, 'starts_at', p_starts, 'ends_at', p_ends);
end $$;

-- A block already copied to Google Calendar is flagged for removal there before the row goes.
create or replace function brain_delete_block(p_id bigint) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare b time_blocks;
begin
  select * into b from time_blocks where id = p_id;
  if not found then raise exception 'Block % not found', p_id; end if;
  if b.gcal_event_id is not null then
    update time_blocks set gcal_state = 'to_delete', updated_at = now() where id = p_id;
    return jsonb_build_object('id', p_id, 'result', 'removing from calendar');
  end if;
  delete from time_blocks where id = p_id;
  return jsonb_build_object('id', p_id, 'result', 'deleted');
end $$;

create or replace function brain_upsert_pursuit(p jsonb) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare pid text := nullif(trim(p->>'id'), '');
begin
  if pid is null then raise exception 'Pursuit id required'; end if;
  insert into pursuits (id, parent_id, kind, title, goal_id, stage, deadline, status, summary, summary_at, story_id, org_entity)
  values (pid, nullif(p->>'parent_id', ''), coalesce(p->>'kind', 'project'), coalesce(p->>'title', pid), nullif(p->>'goal_id', ''),
          nullif(p->>'stage', ''), nullif(p->>'deadline', '')::date, coalesce(p->>'status', 'active'),
          nullif(p->>'summary', ''), case when p ? 'summary' then now() end, nullif(p->>'story_id', ''), nullif(p->>'org_entity', ''))
  on conflict (id) do update set
    parent_id  = case when p ? 'parent_id' then nullif(p->>'parent_id', '') else pursuits.parent_id end,
    kind       = coalesce(p->>'kind', pursuits.kind),
    title      = coalesce(p->>'title', pursuits.title),
    goal_id    = case when p ? 'goal_id' then nullif(p->>'goal_id', '') else pursuits.goal_id end,
    stage      = case when p ? 'stage' then nullif(p->>'stage', '') else pursuits.stage end,
    deadline   = case when p ? 'deadline' then nullif(p->>'deadline', '')::date else pursuits.deadline end,
    status     = coalesce(p->>'status', pursuits.status),
    summary    = coalesce(nullif(p->>'summary', ''), pursuits.summary),
    summary_at = case when p ? 'summary' then now() else pursuits.summary_at end,
    story_id   = case when p ? 'story_id' then nullif(p->>'story_id', '') else pursuits.story_id end,
    org_entity = case when p ? 'org_entity' then nullif(p->>'org_entity', '') else pursuits.org_entity end,
    updated_at = now();
  return jsonb_build_object('id', pid);
end $$;

create or replace function brain_dismiss_proposal(p_id bigint, p_note text default null) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
begin
  update proposals set status = 'dismissed', decided_at = now(),
    feedback = case when nullif(trim(p_note), '') is null then feedback
               else coalesce(feedback, '{}'::jsonb) || jsonb_build_object('note', trim(p_note), 'at', now()) end
  where id = p_id and status in ('pending', 'failed', 'approved');
  if not found then raise exception 'No open suggestion with id %', p_id; end if;
  return jsonb_build_object('id', p_id, 'status', 'dismissed');
end $$;

create or replace function brain_add_contact(p_entity text, p_kind text, p_value text, p_raw_event_id bigint default null)
returns jsonb language sql set search_path = public, pg_temp as $$
  insert into contacts (entity_id, kind, value, raw_event_id) values (p_entity, p_kind, trim(p_value), p_raw_event_id)
  on conflict (entity_id, kind, value) do nothing
  returning jsonb_build_object('id', id)
$$;

-- Compile run log (the footer and trust view read this).
create or replace function brain_run_start(p_run_id text, p_agent text default 'compiler', p_prompt_version text default null)
returns text language sql set search_path = public, pg_temp as $$
  insert into runs (id, agent, prompt_version, started_at, status) values (p_run_id, p_agent, p_prompt_version, now(), 'running')
  on conflict (id) do update set started_at = now(), status = 'running'
  returning id
$$;

create or replace function brain_run_finish(p_run_id text, p_status text default 'ok', p_note text default null)
returns text language sql set search_path = public, pg_temp as $$
  update runs set finished_at = now(), status = p_status, error = p_note where id = p_run_id returning id
$$;

-- ── Lock down, like the rest of the brain ─────────────────────────────────────────────────────────
do $$ declare t text; begin
  foreach t in array array['goals','pursuits','day_priorities','time_blocks','contacts','fact_decay'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from anon, authenticated', t);
  end loop;
end $$;
revoke all on interactions from anon, authenticated;
do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('commitment_lifecycle_before','commitment_lifecycle_after',
             'brain_add_task','brain_complete','brain_set_commitment','brain_set_priorities','brain_plan_block',
             'brain_move_block','brain_delete_block','brain_upsert_pursuit','brain_dismiss_proposal','brain_add_contact',
             'brain_run_start','brain_run_finish') loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
