-- ═══════════════════════════════════════════════════════════════════════════
-- Second Brain: raw memory -> structured memory -> change log -> proposals
-- Layer 1  raw_events        untouched input from Bee, Granola, calendar, manual
-- Layer 2  entities, facts, commitments, stories, edges, patterns   (the brain)
-- Layer 3  change_log         every change to the brain: what, when, why, impact
-- Layer 4  proposals          agent suggestions waiting for your approval
-- ═══════════════════════════════════════════════════════════════════════════

-- ── Layer 1: raw memory ────────────────────────────────────────────────────
create table if not exists raw_events (
  id            bigserial primary key,
  provider      text not null,                        -- granola | bee | calendar | manual
  external_id   text not null,                        -- provider's stable id
  content_hash  text not null,                        -- an edited note becomes a new revision
  kind          text not null default 'meeting',      -- meeting | conversation | note | fact | todo
  occurred_at   timestamptz not null,
  title         text,
  content       text,                                 -- transcript / notes as received
  payload       jsonb not null default '{}',          -- full original payload
  consent_scope text not null default 'full' check (consent_scope in ('full','restricted','exclude')),
  received_at   timestamptz not null default now(),
  status        text not null default 'pending'
                check (status in ('pending','processing','compiled','failed','skipped')),
  attempts      int not null default 0,
  error         text,
  compiled_at   timestamptz,
  revision_of   bigint references raw_events(id),
  unique (provider, external_id, content_hash)
);
create index if not exists raw_events_pending on raw_events (status, received_at);

-- ── Layer 2: the brain ─────────────────────────────────────────────────────
create table if not exists entities (
  id         text primary key,                         -- slug: carter-umetsu
  type       text not null check (type in ('self','person','org','office','topic','goal','project')),
  name       text not null,
  aliases    jsonb not null default '[]',
  summary    text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
insert into entities (id, type, name) values ('me', 'self', 'Me') on conflict do nothing;

create table if not exists facts (
  id           bigserial primary key,
  subject      text not null references entities(id),
  predicate    text not null,
  value        text not null,
  value_entity text references entities(id),
  kind         text not null check (kind in ('fact','preference','plan','decision','advice','feedback','hypothesis')),
  class        text not null check (class in ('observed','declared','inferred')),
  confidence   real not null default 0.8,
  valid_from   timestamptz not null,                 -- when it became true in the world
  valid_to     timestamptz,                          -- when something newer replaced it
  learned_at   timestamptz not null default now(),   -- when the brain found out
  status       text not null default 'current' check (status in ('current','superseded','retracted')),
  raw_event_id bigint not null references raw_events(id),
  evidence     text not null,
  supersedes   bigint references facts(id),
  run_id       text,
  constraint inferred_is_not_fact check (not (class = 'inferred' and kind = 'fact'))
);
create index if not exists facts_subject on facts (subject, predicate, status);

create table if not exists commitments (
  id           bigserial primary key,
  owner        text not null references entities(id),
  beneficiary  text references entities(id),
  action       text not null,
  due_at       date,
  status       text not null default 'open' check (status in ('open','done','dropped','needs_review','unknown')),
  raw_event_id bigint not null references raw_events(id),
  evidence     text not null,
  run_id       text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (raw_event_id, action)
);

-- A commitment can rest on facts ("meet SF reps" rests on target_office:mckinsey).
-- When that fact is superseded, the commitment is flagged for review automatically.
create table if not exists dependencies (
  commitment_id bigint references commitments(id) on delete cascade,
  fact_key      text not null,                      -- subject|predicate
  fact_id       bigint references facts(id),        -- version it was based on
  primary key (commitment_id, fact_key)
);

create table if not exists stories (
  id         text primary key,
  title      text not null,
  status     text not null default 'active',
  summary    text,
  importance real not null default 0.5,
  updated_at timestamptz not null default now()
);
create table if not exists story_events (
  story_id     text references stories(id),
  raw_event_id bigint references raw_events(id),
  note         text,
  primary key (story_id, raw_event_id)
);
create table if not exists edges (
  src          text references entities(id),
  rel          text not null,
  dst          text references entities(id),
  raw_event_id bigint references raw_events(id),
  primary key (src, rel, dst, raw_event_id)
);
create table if not exists patterns (
  id            text primary key,
  title         text not null,
  description   text not null,
  class         text not null check (class in ('observed','inferred')),
  raw_event_ids jsonb not null,
  updated_at    timestamptz not null default now(),
  constraint pattern_needs_two check (jsonb_array_length(raw_event_ids) >= 2)
);

-- ── Layer 3: change log ────────────────────────────────────────────────────
create table if not exists change_log (
  id           bigserial primary key,
  at           timestamptz not null default now(),
  table_name   text not null,
  row_id       text not null,
  op           text not null,                       -- insert | update | supersede | flag
  summary      text,                                -- human-readable "what changed"
  before       jsonb,
  after        jsonb,
  raw_event_id bigint,                              -- why: the evidence that caused it
  run_id       text,                                -- why: which compiler/agent run
  reason       text,                                -- why: stated reasoning
  seen_by_agents boolean not null default false
);
create index if not exists change_log_unseen on change_log (seen_by_agents, at);

create table if not exists runs (
  id             text primary key,
  agent          text not null,
  prompt_version text,
  model          text,
  raw_event_id   bigint,
  started_at     timestamptz not null default now(),
  finished_at    timestamptz,
  status         text,
  input_tokens   int,
  output_tokens  int,
  error          text
);

-- ── Layer 4: calendar mirror + agent proposals ─────────────────────────────
create table if not exists calendar_events (
  uid         text primary key,
  title       text,
  starts_at   timestamptz not null,
  ends_at     timestamptz,
  attendees   jsonb not null default '[]',
  location    text,
  description text,
  updated_at  timestamptz not null default now()
);

create table if not exists proposals (
  id          bigserial primary key,
  agent       text not null,                         -- todo | prep | deadline | review | digest
  kind        text not null check (kind in ('task','calendar','briefing','followup','review','info')),
  title       text not null,
  body        text,
  payload     jsonb not null default '{}',             -- exact action parameters if approved
  priority    int not null default 2,                  -- 1 urgent .. 4 low
  status      text not null default 'pending' check (status in ('pending','approved','dismissed','executed','failed','expired')),
  dedupe_key  text unique,                             -- the same suggestion is never made twice
  related     jsonb not null default '{}',             -- commitment_id, entity ids, raw_event_id
  token       text not null default replace(gen_random_uuid()::text, '-', ''),
  created_at  timestamptz not null default now(),
  decided_at  timestamptz,
  result      jsonb
);
create table if not exists kv (key text primary key, value jsonb, updated_at timestamptz default now());

-- Only the service role (edge functions) touches these tables.
do $$ declare t text; begin
  foreach t in array array['raw_events','entities','facts','commitments','dependencies','stories','story_events',
    'edges','patterns','change_log','runs','calendar_events','proposals','kv'] loop
    execute format('alter table %I enable row level security', t);
  end loop;
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- Change tracking: every write records what / when / why
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function brain_ctx(k text) returns text language sql stable as
$$ select nullif(current_setting('brain.' || k, true), '') $$;

create or replace function log_change() returns trigger language plpgsql as $$
declare
  rid text; summ text; o text;
begin
  if tg_table_name = 'facts' then
    rid := new.id::text;
    if tg_op = 'INSERT' then
      o := 'insert'; summ := format('%s · %s = %s', new.subject, new.predicate, new.value);
    elsif old.status = 'current' and new.status = 'superseded' then
      o := 'supersede'; summ := format('%s · %s: "%s" replaced', new.subject, new.predicate, new.value);
    elsif old.status is distinct from new.status then
      o := 'update'; summ := format('%s · %s now %s', new.subject, new.predicate, new.status);
    else return new; end if;
  elsif tg_table_name = 'commitments' then
    rid := new.id::text;
    if tg_op = 'INSERT' then o := 'insert'; summ := format('new commitment (%s): %s', new.owner, new.action);
    elsif old.status is distinct from new.status then
      o := case when new.status = 'needs_review' then 'flag' else 'update' end;
      summ := format('commitment %s -> %s: %s', old.status, new.status, new.action);
    elsif old.due_at is distinct from new.due_at then
      o := 'update'; summ := format('deadline %s -> %s: %s', old.due_at, new.due_at, new.action);
    else return new; end if;
  elsif tg_table_name = 'entities' then
    rid := new.id;
    if tg_op = 'INSERT' then o := 'insert'; summ := format('new %s: %s', new.type, new.name);
    elsif old.summary is distinct from new.summary or old.aliases is distinct from new.aliases then
      o := 'update'; summ := format('updated %s', new.name);
    else return new; end if;
  elsif tg_table_name = 'stories' then
    rid := new.id;
    o := lower(tg_op); summ := format('story %s: %s', lower(tg_op), new.title);
  else
    return new;
  end if;
  insert into change_log (table_name, row_id, op, summary, before, after, raw_event_id, run_id, reason)
  values (tg_table_name, rid, o, summ,
          case when tg_op = 'UPDATE' then to_jsonb(old) end, to_jsonb(new),
          brain_ctx('raw_event_id')::bigint, brain_ctx('run_id'),
          coalesce(brain_ctx('reason'), case when tg_op = 'INSERT' then 'extracted from source' end));
  return new;
end $$;

do $$ declare t text; begin
  foreach t in array array['facts','commitments','entities','stories'] loop
    execute format('drop trigger if exists %I_log on %I', t, t);
    execute format('create trigger %I_log after insert or update on %I for each row execute function log_change()', t, t);
  end loop;
end $$;

-- A commitment rests on the version of a fact that was true when it was made.
-- If a newer version now exists, the commitment is flagged for review. Order-independent.
create or replace function refresh_dependents(p_key text) returns void language plpgsql as $$
declare d record; f record;
begin
  for d in
    select c.id, r.occurred_at from dependencies dp
    join commitments c on c.id = dp.commitment_id
    join raw_events r on r.id = c.raw_event_id
    where dp.fact_key = p_key and c.status = 'open'
  loop
    select id, status, value into f from facts
      where subject || '|' || predicate = p_key and valid_from <= d.occurred_at and status <> 'retracted'
      order by valid_from desc, id desc limit 1;
    update dependencies set fact_id = f.id where commitment_id = d.id and fact_key = p_key;
    if f.id is not null and f.status = 'superseded' then
      perform set_config('brain.reason',
        format('rests on %s = "%s", which has since changed', p_key, f.value), true);
      update commitments set status = 'needs_review', updated_at = now() where id = d.id;
    end if;
  end loop;
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
-- apply_diff: the ONLY way the intelligence layer writes to the brain.
-- Validates, applies atomically, records why. Re-running it is safe.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function is_single_valued(p text) returns boolean language sql immutable as $$
  select split_part(p, ':', 1) in ('works_at','office','role','title','target_office','case_prep_cadence',
                                   'location','status','relationship','stage','deadline')
$$;

create or replace function rechain(p_subject text, p_predicate text) returns void language plpgsql as $$
declare r record; prev_id bigint; prev_from timestamptz; last_id bigint;
begin
  select id into last_id from facts where subject = p_subject and predicate = p_predicate and status <> 'retracted'
    order by valid_from desc, id desc limit 1;
  prev_id := null;
  for r in select id, valid_from, status from facts
           where subject = p_subject and predicate = p_predicate and status <> 'retracted'
           order by valid_from, id loop
    update facts set supersedes = prev_id where id = r.id and supersedes is distinct from prev_id;
    if r.id <> last_id and r.status = 'current' then
      update facts set status = 'superseded' where id = r.id;
    elsif r.id = last_id and r.status <> 'current' then
      update facts set status = 'current' where id = r.id;
    end if;
    if prev_id is not null then
      update facts set valid_to = r.valid_from where id = prev_id and valid_to is distinct from r.valid_from;
    end if;
    prev_id := r.id;
  end loop;
  update facts set valid_to = null where id = last_id and valid_to is not null;
end $$;

create or replace function apply_diff(p_raw_event_id bigint, p_diff jsonb, p_run_id text default null)
returns jsonb language plpgsql as $$
declare
  ev raw_events; e jsonb; c jsonb; m jsonb; s jsonb; x jsonb; p jsonb; k text;
  known text[]; n_facts int := 0; n_comm int := 0; n_ent int := 0; cid bigint; fid bigint;
  vf timestamptz;
begin
  select * into ev from raw_events where id = p_raw_event_id for update;
  if not found then raise exception 'raw event % not found', p_raw_event_id; end if;
  if ev.status = 'compiled' then return jsonb_build_object('result', 'already_compiled'); end if;

  perform set_config('brain.raw_event_id', p_raw_event_id::text, true);
  perform set_config('brain.run_id', coalesce(p_run_id, ''), true);

  -- validate references
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
  for m in select * from jsonb_array_elements(coalesce(p_diff->'commitments','[]')) loop
    if not (m->>'owner' = any(known)) then raise exception 'commitment owner unknown: %', m->>'owner'; end if;
    if coalesce(m->>'evidence','') = '' then raise exception 'commitment without evidence'; end if;
  end loop;

  -- entities
  for e in select * from jsonb_array_elements(coalesce(p_diff->'entities','[]')) loop
    insert into entities (id, type, name, aliases, summary)
    values (e->>'id', e->>'type', e->>'name', coalesce(e->'aliases','[]'), e->>'summary')
    on conflict (id) do update set
      aliases = (select coalesce(jsonb_agg(distinct a), '[]') from jsonb_array_elements(entities.aliases || excluded.aliases) a),
      summary = coalesce(excluded.summary, entities.summary),
      updated_at = now();
    n_ent := n_ent + 1;
  end loop;

  -- facts (bitemporal; single-valued predicates form a version chain)
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
    n_facts := n_facts + 1;
  end loop;

  -- commitments (+ what they depend on)
  perform set_config('brain.reason', 'explicit commitment in source', true);
  for m in select * from jsonb_array_elements(coalesce(p_diff->'commitments','[]')) loop
    insert into commitments (owner, beneficiary, action, due_at, status, raw_event_id, evidence, run_id)
    values (m->>'owner', nullif(m->>'beneficiary',''), m->>'action', nullif(m->>'due_at','')::date,
            coalesce(m->>'status','open'), p_raw_event_id, m->>'evidence', p_run_id)
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

  -- updates to existing commitments (done, dropped, new deadline)
  for m in select * from jsonb_array_elements(coalesce(p_diff->'commitment_updates','[]')) loop
    perform set_config('brain.reason', coalesce(m->>'reason', 'status update from source'), true);
    update commitments set
      status = coalesce(m->>'status', status),
      due_at = coalesce(nullif(m->>'due_at','')::date, due_at),
      updated_at = now()
    where id = (m->>'id')::bigint;
  end loop;

  -- stories, edges, patterns
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
    insert into patterns (id, title, description, class, raw_event_ids)
    values (p->>'id', p->>'title', p->>'description', p->>'class', p->'raw_event_ids')
    on conflict (id) do update set description = excluded.description, raw_event_ids = excluded.raw_event_ids,
                                   updated_at = now();
  end loop;

  update raw_events set status = 'compiled', compiled_at = now(), error = null where id = p_raw_event_id;
  return jsonb_build_object('result','applied','entities',n_ent,'facts',n_facts,'commitments',n_comm);
end $$;

-- ── Convenience views ──────────────────────────────────────────────────────
create or replace view current_facts as
  select f.*, r.title as source_title, r.occurred_at as source_at
  from facts f join raw_events r on r.id = f.raw_event_id where f.status = 'current';

create or replace view recent_changes as
  select c.id, c.at, c.table_name, c.op, c.summary, c.reason, r.title as source_title,
         r.provider, r.occurred_at as source_at
  from change_log c left join raw_events r on r.id = c.raw_event_id
  order by c.at desc;

create or replace view open_loops as
  select c.*, r.title as source_title, r.occurred_at as source_at
  from commitments c join raw_events r on r.id = c.raw_event_id
  where c.status in ('open','needs_review');

-- Claim the next batch of raw events for compilation (safe with concurrent workers)
create or replace function claim_raw_events(n int default 3) returns setof raw_events language sql as $$
  update raw_events set status = 'processing', attempts = attempts + 1
  where id in (select id from raw_events
               where status = 'pending' or (status = 'failed' and attempts < 3)
               order by occurred_at limit n for update skip locked)
  returning *
$$;

-- Decisions you make from the digest also go through the change log, with your reason.
create or replace function decide_commitment(p_id bigint, p_status text, p_reason text) returns void
language plpgsql as $$
begin
  perform set_config('brain.reason', p_reason, true);
  perform set_config('brain.run_id', 'user-decision', true);
  update commitments set status = p_status, updated_at = now() where id = p_id;
end $$;
