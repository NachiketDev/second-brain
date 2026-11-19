-- Desk task rows show the estimate and where it came from, and whether the task is an event.
create or replace function desk_commitment_json(c commitments) returns jsonb language sql stable
set search_path = public, pg_temp as $$
  select jsonb_build_object('id', c.id, 'action', c.action, 'status', c.status, 'due', c.due_at,
    'overdue', c.due_at is not null and c.due_at < (now() at time zone 'America/New_York')::date and c.status in ('open', 'needs_review', 'unknown'),
    'owner', c.owner, 'owner_name', (select name from entities where id = c.owner),
    'for', c.beneficiary, 'for_name', (select name from entities where id = c.beneficiary),
    'pursuit_id', c.pursuit_id, 'pursuit', (select title from pursuits where id = c.pursuit_id),
    'goal_id', coalesce(c.goal_id, (select goal_id from pursuits where id = c.pursuit_id)),
    'estimate_min', c.estimate_min, 'estimate_source', c.estimate_source, 'is_event', c.is_event,
    'source', c.source, 'in_google', c.gtask_id is not null,
    'completed_at', c.completed_at, 'created', c.created_at)
$$;
