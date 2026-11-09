-- Skip a note if the source says it hasn't changed since we last stored it, even when the
-- text the task assembled differs slightly between runs.
create or replace function ingest_raw(
  p_provider text, p_external_id text, p_occurred_at timestamptz, p_title text, p_content text,
  p_url text default null, p_kind text default 'meeting', p_payload jsonb default '{}')
returns jsonb language plpgsql set search_path = public, pg_temp as $$
declare h text; prior raw_events; scope text; new_id bigint;
begin
  h := md5(coalesce(p_title,'') || E'\n' || coalesce(p_content,''));
  select * into prior from raw_events where provider = p_provider and external_id = p_external_id
    order by id desc limit 1;
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
revoke execute on function ingest_raw(text,text,timestamptz,text,text,text,text,jsonb) from public, anon, authenticated;
