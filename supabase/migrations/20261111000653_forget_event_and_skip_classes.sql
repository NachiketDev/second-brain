-- Calendar titles that mark class time; Bee recordings that start during these are never kept.
insert into kv(key, value) values ('bee_skip_calendar', '["^[A-Z][A-Z0-9]{1,6} B$"]'::jsonb)
on conflict (key) do nothing;

create or replace function is_class_time(p_at timestamptz) returns text
language sql stable set search_path = public, pg_temp as $$
  select c.title from calendar_events c, kv, jsonb_array_elements_text(kv.value) pat
  where kv.key = 'bee_skip_calendar' and c.title ~ pat
    and p_at between c.starts_at - interval '15 min' and coalesce(c.ends_at, c.starts_at + interval '90 min')
  limit 1
$$;

-- Forget one source: retract its facts, drop its open commitments, remove its links and story notes,
-- and delete its content. The raw row stays as an empty, excluded stub so it is never re-ingested,
-- and every change is logged with the reason.
create or replace function brain_forget_event(p_id bigint, p_reason text) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare nf int; nc int; ne int; k text;
begin
  perform set_config('brain.raw_event_id', p_id::text, true);
  perform set_config('brain.run_id', 'forget', true);
  perform set_config('brain.reason', p_reason, true);
  update facts set status = 'retracted', valid_to = now() where raw_event_id = p_id and status <> 'retracted';
  get diagnostics nf = row_count;
  for k in select distinct subject || '|' || predicate from facts where raw_event_id = p_id loop
    perform rechain(split_part(k, '|', 1), split_part(k, '|', 2));
  end loop;
  update commitments set status = 'dropped', updated_at = now() where raw_event_id = p_id and status <> 'dropped';
  get diagnostics nc = row_count;
  delete from edges where raw_event_id = p_id; get diagnostics ne = row_count;
  delete from story_events where raw_event_id = p_id;
  update raw_events set content = null, consent_scope = 'exclude', status = 'skipped',
    payload = payload || jsonb_build_object('forgotten', p_reason, 'forgotten_at', now())
  where id = p_id;
  return jsonb_build_object('facts_retracted', nf, 'commitments_dropped', nc, 'edges_removed', ne);
end $$;

-- ingest_raw must not resurrect a forgotten source on the next poll.
create or replace function ingest_raw(
  p_provider text, p_external_id text, p_occurred_at timestamptz, p_title text, p_content text,
  p_url text default null, p_kind text default 'meeting', p_payload jsonb default '{}')
returns jsonb language plpgsql set search_path = public, pg_temp as $$
declare h text; prior raw_events; scope text; new_id bigint;
begin
  h := md5(coalesce(p_title,'') || E'\n' || coalesce(p_content,''));
  select * into prior from raw_events where provider = p_provider and external_id = p_external_id
    order by id desc limit 1;
  if found and prior.payload ? 'forgotten' then
    return jsonb_build_object('result','forgotten','id',prior.id);
  end if;
  if found and prior.content_hash = h then
    return jsonb_build_object('result','duplicate','id',prior.id);
  end if;
  if found and p_payload ? 'source_updated_at' and prior.payload ? 'source_updated_at'
     and (p_payload->>'source_updated_at')::timestamptz <= (prior.payload->>'source_updated_at')::timestamptz then
    return jsonb_build_object('result','unchanged','id',prior.id);
  end if;
  scope := case when p_title ~* '\[(private|off.?record|no.?brain)\]' then 'exclude'
                when p_title ~* '\m(nda|confidential)\M' then 'restricted' else 'full' end;
  insert into raw_events (provider, external_id, content_hash, kind, occurred_at, title, content, consent_scope,
                          status, revision_of, payload)
  values (p_provider, p_external_id, h, p_kind, p_occurred_at, p_title, p_content, scope,
          case when scope = 'exclude' then 'skipped' else 'pending' end, prior.id,
          p_payload || jsonb_build_object('url', p_url))
  returning id into new_id;
  return jsonb_build_object('result', case when prior.id is null then 'stored' else 'revision' end,
                            'id', new_id, 'consent_scope', scope);
end $$;

revoke execute on function is_class_time(timestamptz), brain_forget_event(bigint, text),
  ingest_raw(text,text,timestamptz,text,text,text,text,jsonb) from public, anon, authenticated;
grant execute on function is_class_time(timestamptz), brain_forget_event(bigint, text) to service_role;

select brain_forget_event(129, 'class recording (MKT B): the user does not keep class recordings');
select brain_forget_event(127, 'class recording (FIN1 B): the user does not keep class recordings');
