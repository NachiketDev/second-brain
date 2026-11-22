-- Merge a duplicate entity into the right one (22 Nov). Used when the user confirms two records are the same
-- person, e.g. a first-name-only record from a transcript and the directory record. Everything that pointed at
-- p_from moves to p_into, p_from's name and aliases become aliases of p_into, summaries are joined, single-valued
-- facts are re-chained, and the merge is kept in kv entity_merges. p_from is then removed.

create or replace function brain_merge_entity(p_from text, p_into text, p_note text default null) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare f entities; t entities; n_facts int; n_edges int; n_comm int; n_cont int; pr text; strip text := '^POSSIBLE DUPLICATE OF [^:]*:\s*';
begin
  if p_from = p_into or p_from = 'me' then raise exception 'bad merge % -> %', p_from, p_into; end if;
  select * into f from entities where id = p_from for update;
  if not found then raise exception 'entity % not found', p_from; end if;
  select * into t from entities where id = p_into for update;
  if not found then raise exception 'entity % not found', p_into; end if;
  perform set_config('brain.reason', coalesce(p_note, 'merged duplicate ' || p_from || ' into ' || p_into), true);

  update facts set subject = p_into where subject = p_from;
  get diagnostics n_facts = row_count;
  update facts set value_entity = p_into where value_entity = p_from;
  update dependencies set fact_key = p_into || substr(fact_key, length(p_from) + 1)
    where fact_key like p_from || '|%'
      and not exists (select 1 from dependencies d2 where d2.commitment_id = dependencies.commitment_id
                      and d2.fact_key = p_into || substr(dependencies.fact_key, length(p_from) + 1));
  delete from dependencies where fact_key like p_from || '|%';

  insert into edges select case when src = p_from then p_into else src end, rel,
                           case when dst = p_from then p_into else dst end, raw_event_id
    from edges where (src = p_from or dst = p_from) on conflict do nothing;
  delete from edges where src = p_from or dst = p_from;
  get diagnostics n_edges = row_count;
  delete from edges where src = p_into and dst = p_into;

  update commitments set owner = p_into where owner = p_from;
  get diagnostics n_comm = row_count;
  update commitments set beneficiary = p_into where beneficiary = p_from;
  update pursuits set org_entity = p_into where org_entity = p_from;

  insert into contacts (entity_id, kind, value, raw_event_id)
    select p_into, kind, value, raw_event_id from contacts where entity_id = p_from on conflict do nothing;
  delete from contacts where entity_id = p_from;
  get diagnostics n_cont = row_count;

  update entities set
    aliases = (select coalesce(jsonb_agg(distinct a), '[]') from jsonb_array_elements_text(
                 t.aliases || f.aliases || jsonb_build_array(f.name)) a where a <> t.name),
    summary = nullif(concat_ws('; ', nullif(regexp_replace(coalesce(f.summary, ''), strip, ''), ''),
                                     nullif(regexp_replace(coalesce(t.summary, ''), strip, ''), '')), ''),
    updated_at = now()
  where id = p_into;
  delete from entities where id = p_from;

  for pr in select distinct predicate from facts where subject = p_into and is_single_valued(predicate) loop
    perform rechain(p_into, pr);
  end loop;

  insert into kv (key, value) values ('entity_merges', jsonb_build_object(p_from, jsonb_build_object('into', p_into, 'at', now(), 'note', p_note)))
  on conflict (key) do update set value = kv.value || excluded.value;

  return jsonb_build_object('merged', p_from, 'into', p_into, 'facts', n_facts, 'edges', n_edges, 'commitments', n_comm, 'contacts', n_cont);
end $$;

revoke execute on function brain_merge_entity(text, text, text) from public, anon, authenticated;
grant execute on function brain_merge_entity(text, text, text) to service_role;
