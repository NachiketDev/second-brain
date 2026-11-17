-- Core model rebuild, steps 4, 5 and 7 (17 Nov 2026). Additive: new functions and one new column.

alter table commitments add column if not exists gtask_list text;

-- ── Goals write path ──────────────────────────────────────────────────────────────────────────────
create or replace function brain_upsert_goal(p jsonb) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare gid text := nullif(trim(p->>'id'), '');
begin
  if gid is null then raise exception 'Goal id required'; end if;
  insert into goals (id, kind, parent_id, box_key, title, weekly_target, unit, sort, status, source_fact_id)
  values (gid, coalesce(p->>'kind', 'action'), nullif(p->>'parent_id', ''), nullif(p->>'box_key', ''),
          coalesce(p->>'title', gid), nullif(p->>'weekly_target', '')::numeric, nullif(p->>'unit', ''),
          coalesce((p->>'sort')::int, 0), coalesce(p->>'status', 'active'), nullif(p->>'source_fact_id', '')::bigint)
  on conflict (id) do update set
    title         = coalesce(p->>'title', goals.title),
    weekly_target = case when p ? 'weekly_target' then nullif(p->>'weekly_target', '')::numeric else goals.weekly_target end,
    unit          = case when p ? 'unit' then nullif(p->>'unit', '') else goals.unit end,
    sort          = coalesce((p->>'sort')::int, goals.sort),
    status        = coalesce(p->>'status', goals.status),
    updated_at    = now();
  return jsonb_build_object('id', gid);
end $$;

-- One-time: closed commitments get completed_at from when they last changed.
create or replace function brain_backfill_completed_at() returns int
language plpgsql set search_path = public, pg_temp as $$
declare n int;
begin
  update commitments set completed_at = coalesce(updated_at, created_at)
  where status in ('done', 'dropped') and completed_at is null;
  get diagnostics n = row_count;
  return n;
end $$;

-- Step 5: expire suggestions whose commitment already closed, then clear the rest he never accepted.
create or replace function brain_clear_suggestions(p_note text) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare ne int; nd int;
begin
  update proposals p set status = 'expired', decided_at = now(),
    result = coalesce(p.result, '{}'::jsonb) || jsonb_build_object('expired', 'commitment ' || c.status)
  from commitments c
  where p.status = 'pending' and c.id::text = p.related->>'commitment_id' and c.status in ('done', 'dropped');
  get diagnostics ne = row_count;
  update proposals set status = 'dismissed', decided_at = now(),
    feedback = coalesce(feedback, '{}'::jsonb) || jsonb_build_object('note', p_note, 'at', now())
  where status = 'pending';
  get diagnostics nd = row_count;
  return jsonb_build_object('expired', ne, 'dismissed', nd);
end $$;

-- ── Google Tasks two-way sync ─────────────────────────────────────────────────────────────────────
-- Called by poll for every Google task it sees. Links, imports, completes or reopens the commitment.
-- kv 'gtask_title_links' maps known titles to an existing commitment id, or to {pursuit_id, goal_id}
-- for tasks that only existed in Google before 17 Nov.
create or replace function brain_gtask_seen(p_gtask_id text, p_list_id text, p_title text, p_due date,
  p_notes text, p_completed boolean) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare c commitments; link jsonb; r jsonb;
begin
  select * into c from commitments where gtask_id = p_gtask_id;
  if found then
    if c.gtask_list is null then update commitments set gtask_list = p_list_id where id = c.id; end if;
    if c.gtask_state in ('to_complete', 'to_reopen', 'to_update', 'to_create') then
      return jsonb_build_object('id', c.id, 'result', 'pending push');      -- the brain's change wins
    end if;
    if p_completed and c.status not in ('done', 'dropped') then
      perform brain_complete(c.id, 'done', 'google', 'ticked in Google Tasks');
      update commitments set gtask_state = 'synced' where id = c.id;
      return jsonb_build_object('id', c.id, 'result', 'completed');
    elsif not p_completed and c.status = 'done' then
      perform brain_complete(c.id, 'open', 'google', 'reopened in Google Tasks');
      update commitments set gtask_state = 'synced' where id = c.id;
      return jsonb_build_object('id', c.id, 'result', 'reopened');
    end if;
    return jsonb_build_object('id', c.id, 'result', 'same');
  end if;
  if p_completed then return jsonb_build_object('result', 'ignored completed'); end if;
  select value->p_title into link from kv where key = 'gtask_title_links';
  if jsonb_typeof(link) = 'number' then
    update commitments set gtask_id = p_gtask_id, gtask_list = p_list_id, gtask_state = 'synced'
    where id = (link::text)::bigint and gtask_id is null;
    if found then return jsonb_build_object('id', (link::text)::bigint, 'result', 'linked'); end if;
  end if;
  r := brain_add_task(p_title, p_due, link->>'pursuit_id', link->>'goal_id', p_notes, 'google', p_gtask_id);
  update commitments set gtask_list = p_list_id where id = (r->>'id')::bigint;
  return r;
end $$;

-- Commitments whose Google copy needs a write.
create or replace function brain_gtask_queue() returns jsonb
language sql stable set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'title', action, 'due', due_at, 'notes',
           case when source in ('voice','desk','checkin') and evidence not like 'Added by % via %' then evidence end,
           'status', status, 'state', gtask_state, 'gtask_id', gtask_id, 'list', gtask_list) order by id), '[]')
  from commitments where owner = 'me' and gtask_state in ('to_create', 'to_update', 'to_complete', 'to_reopen')
$$;

create or replace function brain_gtask_pushed(p_id bigint, p_gtask_id text, p_list_id text, p_error text default null)
returns jsonb language plpgsql set search_path = public, pg_temp as $$
begin
  update commitments set gtask_id = coalesce(p_gtask_id, gtask_id), gtask_list = coalesce(p_list_id, gtask_list),
    gtask_state = case when p_error is null then 'synced' else 'error' end
  where id = p_id;
  return jsonb_build_object('id', p_id, 'ok', p_error is null);
end $$;

do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('brain_upsert_goal','brain_backfill_completed_at',
             'brain_clear_suggestions','brain_gtask_seen','brain_gtask_queue','brain_gtask_pushed') loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
