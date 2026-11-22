-- Control room (22 Nov): the Outbox strip and the "why?" sheet.
-- Outbox: suggestions that need his yes, with what to do about each. Nothing is ever sent from here; he sends
-- anything that goes to other people himself, then marks it done. Stale "block time" nudges (task closed or
-- already past due) no longer show.
-- Why: for any task, fact or suggestion, where it came from (the source, in its own words), and how it changed.

-- He did it (sent the nudge, planned the block, kept the task): mark the suggestion done.
create or replace function brain_proposal_done(p_id bigint, p_note text default null) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
begin
  update proposals set status = 'executed', decided_at = now(),
    result = coalesce(result, '{}'::jsonb) || jsonb_build_object('by', 'him', 'note', nullif(trim(p_note), ''), 'at', now())
  where id = p_id and status in ('pending', 'approved', 'failed');
  if not found then raise exception 'No open suggestion with id %', p_id; end if;
  return jsonb_build_object('id', p_id, 'status', 'executed');
end $$;

create or replace function desk_why(p_kind text, p_id text) returns jsonb
language plpgsql stable set search_path = public, pg_temp as $$
declare c commitments; f facts; p proposals; src jsonb;
begin
  if p_kind = 'commitment' then
    select * into c from commitments where id = p_id::bigint;
    if not found then raise exception 'No task %', p_id; end if;
    src := case when c.raw_event_id is not null then brain_evidence(c.raw_event_id) end;
    return jsonb_build_object('kind', 'commitment', 'id', c.id, 'what', c.action, 'status', c.status, 'due', c.due_at,
      'owner', coalesce((select name from entities where id = c.owner), c.owner),
      'for', (select name from entities where id = c.beneficiary),
      'evidence', c.evidence, 'added', c.created_at, 'added_by', c.source,
      'pursuit', (select title from pursuits where id = c.pursuit_id), 'box', (select title from goals where id = c.goal_id),
      'source', case when src is null then null else src - 'content' || jsonb_build_object('excerpt', left(src->>'content', 1500)) end,
      'depends_on', (select coalesce(jsonb_agg(jsonb_build_object('fact', d.fact_key, 'value', (select value from facts where id = d.fact_id))), '[]')
                     from dependencies d where d.commitment_id = c.id),
      'history', (select coalesce(jsonb_agg(jsonb_build_object('at', l.at, 'what', l.summary, 'why', l.reason) order by l.at), '[]')
                  from change_log l where l.table_name = 'commitments' and l.row_id::text = c.id::text));
  elsif p_kind = 'fact' then
    select * into f from facts where id = p_id::bigint;
    if not found then raise exception 'No fact %', p_id; end if;
    src := case when f.raw_event_id is not null then brain_evidence(f.raw_event_id) end;
    return jsonb_build_object('kind', 'fact', 'id', f.id, 'about', coalesce((select name from entities where id = f.subject), f.subject),
      'what', f.predicate || ': ' || f.value, 'status', f.status, 'class', f.class, 'confidence', f.confidence,
      'evidence', f.evidence, 'since', f.valid_from,
      'source', case when src is null then null else src - 'content' || jsonb_build_object('excerpt', left(src->>'content', 1500)) end,
      'earlier', (select coalesce(jsonb_agg(jsonb_build_object('value', x.value, 'since', x.valid_from, 'status', x.status) order by x.valid_from desc), '[]')
                  from facts x where x.subject = f.subject and x.predicate = f.predicate and x.id <> f.id));
  elsif p_kind = 'suggestion' then
    select * into p from proposals where id = p_id::bigint;
    if not found then raise exception 'No suggestion %', p_id; end if;
    return jsonb_build_object('kind', 'suggestion', 'id', p.id, 'agent', p.agent, 'what', p.title, 'body', p.body, 'status', p.status,
      'made', p.created_at,
      'task', case when nullif(p.related->>'commitment_id', '') is not null then desk_why('commitment', p.related->>'commitment_id') end);
  end if;
  raise exception 'why? works for commitment, fact or suggestion';
end $$;

-- needs_yes: drop stale block-time nudges and carry the full draft.
do $do$ declare d text; begin
  d := pg_get_functiondef('desk_control(timestamptz)'::regprocedure);
  d := replace(d, $o$                    and not (p.kind = 'followup' and coalesce(c.owner, '') <> 'me' and c.beneficiary = 'me')),$o$,
    $n$                    and not (p.kind = 'followup' and coalesce(c.owner, '') <> 'me' and c.beneficiary = 'me')
                    and not (p.kind = 'calendar' and (c.id is null or c.status <> 'open' or c.due_at < (now() at time zone 'America/New_York')::date))),$n$);
  d := replace(d, $o$'needs_yes', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'kind', p.kind, 'title', p.title, 'body', left(p.body, 300),$o$,
    $n$'needs_yes', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'kind', p.kind, 'title', p.title, 'body', left(p.body, 1500), 'agent', p.agent, 'payload', p.payload,$n$);
  if position('c.due_at < (now() at time zone' in d) = 0 or position('''payload'', p.payload' in d) = 0 then raise exception 'desk_control patch did not apply'; end if;
  execute d;
end $do$;

do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('brain_proposal_done', 'desk_why') loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
