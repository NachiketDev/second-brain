-- Review page: read the suggestion queue and record decisions + feedback through functions only.
alter table proposals add column if not exists feedback jsonb;

create or replace function review_queue()
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(to_jsonb(x) order by x.priority, x.created_at desc), '[]'::jsonb) from (
    select p.id, p.agent, p.kind, p.title, p.body, p.payload, p.priority, p.status, p.created_at,
           p.decided_at, p.feedback, p.result, c.due_at, c.owner, c.status as commitment_status
    from proposals p
    left join commitments c on c.id = nullif(p.related->>'commitment_id', '')::bigint
    where p.status in ('pending', 'queued', 'failed', 'approved')
       or p.decided_at > now() - interval '3 days'
  ) x
$$;

create or replace function decide_proposal(p_id bigint, p_action text, p_rating text default null,
                                           p_note text default null, p_edits jsonb default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  p proposals; cid bigint; note text := nullif(trim(p_note), ''); pay jsonb; d date;
begin
  select * into p from proposals where id = p_id for update;
  if not found then raise exception 'Suggestion % not found', p_id; end if;
  if p_rating is not null and p_rating not in ('useful', 'not_useful') then
    raise exception 'Rating must be useful or not_useful'; end if;

  if p_rating is not null or note is not null then
    update proposals set feedback = coalesce(feedback, '{}'::jsonb)
      || jsonb_strip_nulls(jsonb_build_object('rating', p_rating, 'note', note, 'at', now()))
    where id = p_id;
  end if;
  if p_action = 'feedback' then return jsonb_build_object('ok', true, 'status', p.status); end if;

  if not (p.status in ('pending', 'failed') or (p.status = 'approved' and p_action in ('done', 'dismiss'))) then
    raise exception 'Already handled: %', p.status; end if;
  cid := nullif(p.related->>'commitment_id', '')::bigint;

  if p_action = 'dismiss' then
    update proposals set status = 'dismissed', decided_at = now() where id = p_id;
    return jsonb_build_object('ok', true, 'status', 'dismissed');

  elsif p_action = 'done' then
    if cid is not null then perform decide_commitment(cid, 'done', coalesce('Marked done in review page: ' || note, 'Marked done in review page')); end if;
    update proposals set status = 'executed', decided_at = now(), result = jsonb_build_object('done', true) where id = p_id;
    return jsonb_build_object('ok', true, 'status', 'executed');

  elsif p_action in ('keep', 'drop') then
    if p.kind <> 'review' then raise exception 'Keep and drop apply to review suggestions only'; end if;
    if cid is not null then
      perform decide_commitment(cid, case p_action when 'keep' then 'open' else 'dropped' end,
        coalesce(note, case p_action when 'keep' then 'You kept it after review' else 'You dropped it after its premise changed' end));
    end if;
    update proposals set status = 'executed', decided_at = now(),
      result = jsonb_build_object('status', case p_action when 'keep' then 'open' else 'dropped' end) where id = p_id;
    return jsonb_build_object('ok', true, 'status', 'executed');

  elsif p_action = 'approve' then
    if p.kind = 'review' then raise exception 'Use keep or drop for review suggestions'; end if;
    if p.kind = 'task' then
      pay := p.payload;
      if p_edits ? 'content' then
        if nullif(trim(p_edits->>'content'), '') is null then raise exception 'Task text cannot be empty'; end if;
        pay := pay || jsonb_build_object('content', trim(p_edits->>'content'));
      end if;
      if p_edits ? 'due_date' then
        if nullif(p_edits->>'due_date', '') is null then pay := pay || '{"due_date": null}'::jsonb;
        else d := (p_edits->>'due_date')::date; pay := pay || jsonb_build_object('due_date', d::text); end if;
      end if;
      update proposals set status = 'queued', payload = pay, decided_at = now() where id = p_id;
      perform brain_call('act');   -- act's queue mode adds it to Google Tasks after this commits
      return jsonb_build_object('ok', true, 'status', 'queued');
    end if;
    update proposals set status = 'approved', decided_at = now() where id = p_id;
    return jsonb_build_object('ok', true, 'status', 'approved', 'url', p.payload->>'url',
      'draft', case when p.kind = 'followup' then split_part(p.body, E'Draft nudge:\n\n', 2) end);
  end if;
  raise exception 'Unknown action %', p_action;
end $$;

revoke all on function review_queue() from public, anon, authenticated;
revoke all on function decide_proposal(bigint, text, text, text, jsonb) from public, anon, authenticated;
