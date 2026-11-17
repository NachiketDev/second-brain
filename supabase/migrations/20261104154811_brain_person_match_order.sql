create or replace function brain_person(p_name text) returns jsonb language plpgsql stable
set search_path = public, pg_temp as $$
declare e entities; n int; others jsonb;
begin
  with m as (
    select *, case when id = lower(p_name) then 0
                   when name ilike p_name then 1
                   when exists (select 1 from jsonb_array_elements_text(aliases) a where a ilike p_name) then 2
                   when name ilike p_name || ' %' then 3
                   else 4 end as rank
    from entities
    where id = lower(p_name) or name ilike '%' || p_name || '%'
       or exists (select 1 from jsonb_array_elements_text(aliases) a where a ilike '%' || p_name || '%'))
  select count(*), jsonb_agg(jsonb_build_object('id', id, 'name', name) order by rank, length(name)) into n, others from m;
  select * into e from entities x where x.id = (
    select id from (
      select id, case when id = lower(p_name) then 0 when name ilike p_name then 1
                      when exists (select 1 from jsonb_array_elements_text(aliases) a where a ilike p_name) then 2
                      when name ilike p_name || ' %' then 3 else 4 end rank, length(name) l
      from entities
      where id = lower(p_name) or name ilike '%' || p_name || '%'
         or exists (select 1 from jsonb_array_elements_text(aliases) a where a ilike '%' || p_name || '%')) z
    order by rank, l limit 1);
  if not found then return jsonb_build_object('found', false); end if;
  return jsonb_build_object('found', true,
    'also_matching', case when n > 1 then (select jsonb_agg(o) from jsonb_array_elements(others) o where o->>'id' <> e.id) end,
    'entity', to_jsonb(e) - 'created_at',
    'facts', (select coalesce(jsonb_agg(jsonb_build_object('fact_id', id, 'predicate', predicate, 'value', value,
        'class', class, 'since', valid_from::date, 'source', source_title) order by valid_from desc), '[]')
        from current_facts where subject = e.id),
    'history', (select coalesce(jsonb_agg(jsonb_build_object('predicate', predicate, 'old_value', value,
        'until', valid_to::date) order by valid_to desc), '[]')
        from facts where subject = e.id and status = 'superseded'),
    'open_commitments', (select coalesce(jsonb_agg(jsonb_build_object('commitment_id', id, 'owner', owner,
        'beneficiary', beneficiary, 'action', action, 'due', due_at, 'status', status)), '[]')
        from open_loops where owner = e.id or beneficiary = e.id),
    'connections', (select coalesce(jsonb_agg(distinct jsonb_build_object('rel', rel,
        'with', case when src = e.id then dst else src end)), '[]')
        from edges where src = e.id or dst = e.id),
    'interactions', (select coalesce(jsonb_agg(jsonb_build_object('source_event', id, 'title', title,
        'date', occurred_at::date, 'kind', kind) order by occurred_at desc), '[]')
        from raw_events where id in (select raw_event_id from edges where src = e.id or dst = e.id
                                     union select raw_event_id from facts where subject = e.id
                                     union select raw_event_id from commitments where owner = e.id or beneficiary = e.id)));
end $$;
revoke execute on function brain_person(text) from public, anon, authenticated;
grant execute on function brain_person(text) to service_role;
