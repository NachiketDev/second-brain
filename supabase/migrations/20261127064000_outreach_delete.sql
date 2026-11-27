-- Remove a wrong or test outreach row (and the raw event it created). Used only on his word.
create or replace function brain_delete_outreach(p_id bigint, p_reason text) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare r outreach_log;
begin
  delete from outreach_log where id = p_id returning * into r;
  if not found then raise exception 'No outreach row %', p_id; end if;
  if r.raw_event_id is not null then perform brain_forget_event(r.raw_event_id, coalesce(p_reason, 'outreach row deleted')); end if;
  return jsonb_build_object('deleted', p_id, 'person', r.person, 'raw_event_forgotten', r.raw_event_id);
end $$;
revoke execute on function brain_delete_outreach(bigint, text) from public, anon, authenticated;
grant execute on function brain_delete_outreach(bigint, text) to service_role;
