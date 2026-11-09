-- Synthetic sample data: ten fictional events, compiled. Load after the migrations to try the brain.
-- All people and firms here are invented.
do $$ declare rid bigint; d jsonb; begin
  insert into raw_events (provider, external_id, content_hash, kind, occurred_at, title, consent_scope, payload, content)
  values ('granola', 'sample-01', md5('sample-01'), 'meeting', '2026-10-02T15:00:00-04:00', 'Coffee chat with Priya Shah (Meridian SF)', 'full', '{}'::jsonb, '(sample)')
  on conflict do nothing returning id into rid;
  if rid is null then return; end if;
  d := '{"source": {"provider": "granola", "external_id": "sample-01", "title": "Coffee chat with Priya Shah (Meridian SF)", "occurred_at": "2026-10-02T15:00:00-04:00", "url": "https://example.com/notes/sample-01"}, "entities": [{"id": "me", "type": "self", "name": "Me"}, {"id": "priya-shah", "type": "person", "name": "Priya Shah", "aliases": ["Priya"], "summary": "Meridian Group consultant, San Francisco; first coffee chat"}, {"id": "meridian", "type": "org", "name": "Meridian Group"}, {"id": "meridian-sf", "type": "office", "name": "Meridian San Francisco"}, {"id": "theme-adoption", "type": "topic", "name": "Adoption, not technology, is the hard part", "aliases": ["change management"]}], "claims": [{"subject": "priya-shah", "predicate": "works_at", "value": "Meridian SF", "value_entity": "meridian", "kind": "fact", "class": "observed", "evidence": "Priya has been at Meridian SF for two years"}, {"subject": "me", "predicate": "target_office:meridian", "value": "San Francisco", "value_entity": "meridian-sf", "kind": "preference", "class": "declared", "evidence": "Leaning toward San Francisco"}, {"subject": "me", "predicate": "feedback:improve", "value": "Ask specific questions instead of life-story questions", "kind": "feedback", "class": "observed", "evidence": "Priya: skip the life-story questions"}], "commitments": [{"owner": "me", "beneficiary": "priya-shah", "action": "Follow up with Priya with targeted questions", "evidence": "Follow up once goals are clearer"}], "stories": [{"id": "meridian-recruiting", "title": "Meridian recruiting", "importance": 0.7, "note": "First coffee chat (Priya, SF)"}, {"id": "office-decision", "title": "Target office decision", "importance": 0.8, "note": "Leaning SF for Meridian"}], "edges": [{"src": "me", "rel": "coffee_chat", "dst": "priya-shah"}, {"src": "priya-shah", "rel": "works_at", "dst": "meridian"}, {"src": "meridian-sf", "rel": "office_of", "dst": "meridian"}]}'::jsonb;
  perform apply_diff(rid, d, 'sample');
end $$;

do $$ declare rid bigint; d jsonb; begin
  insert into raw_events (provider, external_id, content_hash, kind, occurred_at, title, consent_scope, payload, content)
  values ('granola', 'sample-02', md5('sample-02'), 'meeting', '2026-10-03T10:00:00-04:00', 'Pitch coaching with Leo Grant', 'full', '{}'::jsonb, '(sample)')
  on conflict do nothing returning id into rid;
  if rid is null then return; end if;
  d := '{"source": {"provider": "granola", "external_id": "sample-02", "title": "Pitch coaching with Leo Grant", "occurred_at": "2026-10-03T10:00:00-04:00", "url": "https://example.com/notes/sample-02"}, "entities": [{"id": "leo-grant", "type": "person", "name": "Leo Grant", "aliases": ["Leo"], "summary": "Coffee chat coach"}], "claims": [{"subject": "me", "predicate": "target_office:meridian", "value": "San Francisco (strong preference)", "value_entity": "meridian-sf", "kind": "preference", "class": "declared", "evidence": "SF first, strongly weighted"}, {"subject": "me", "predicate": "advice", "value": "Lead the pitch with the adoption angle", "value_entity": "theme-adoption", "kind": "advice", "class": "observed", "evidence": "Leo: the hard part is adoption, lead with that"}], "commitments": [{"owner": "me", "action": "Refine 60-second pitch around the adoption angle", "evidence": "Refine the pitch using Leo''s framing"}, {"owner": "me", "action": "Attend Meridian campus events to meet SF office reps", "evidence": "Campus events are the path to SF intros", "depends_on": ["me|target_office:meridian"]}], "stories": [{"id": "pitch", "title": "Coffee chat craft and pitch", "importance": 0.6, "note": "Leo reframes pitch around adoption"}, {"id": "office-decision", "note": "SF strongly preferred"}], "edges": [{"src": "leo-grant", "rel": "coaches", "dst": "me"}, {"src": "leo-grant", "rel": "emphasizes", "dst": "theme-adoption"}]}'::jsonb;
  perform apply_diff(rid, d, 'sample');
end $$;

do $$ declare rid bigint; d jsonb; begin
  insert into raw_events (provider, external_id, content_hash, kind, occurred_at, title, consent_scope, payload, content)
  values ('granola', 'sample-03', md5('sample-03'), 'meeting', '2026-10-06T12:30:00-04:00', 'Atlas office decision', 'full', '{}'::jsonb, '(sample)')
  on conflict do nothing returning id into rid;
  if rid is null then return; end if;
  d := '{"source": {"provider": "granola", "external_id": "sample-03", "title": "Atlas office decision", "occurred_at": "2026-10-06T12:30:00-04:00", "url": "https://example.com/notes/sample-03"}, "entities": [{"id": "atlas", "type": "org", "name": "Atlas Consulting", "aliases": ["Atlas"]}, {"id": "atlas-ny", "type": "office", "name": "Atlas New York"}], "claims": [{"subject": "me", "predicate": "target_office:atlas", "value": "New York", "value_entity": "atlas-ny", "kind": "decision", "class": "observed", "evidence": "Settled on New York as the target office", "confidence": 0.7}], "commitments": [], "stories": [{"id": "office-decision", "note": "Leaning New York for Atlas"}, {"id": "atlas-recruiting", "title": "Atlas recruiting (New York)", "importance": 0.9, "note": "Kickoff"}], "edges": [{"src": "atlas-ny", "rel": "office_of", "dst": "atlas"}]}'::jsonb;
  perform apply_diff(rid, d, 'sample');
end $$;

do $$ declare rid bigint; d jsonb; begin
  insert into raw_events (provider, external_id, content_hash, kind, occurred_at, title, consent_scope, payload, content)
  values ('granola', 'sample-04', md5('sample-04'), 'meeting', '2026-10-08T17:00:00-04:00', 'Atlas chat with Nora Ali', 'full', '{}'::jsonb, '(sample)')
  on conflict do nothing returning id into rid;
  if rid is null then return; end if;
  d := '{"source": {"provider": "granola", "external_id": "sample-04", "title": "Atlas chat with Nora Ali", "occurred_at": "2026-10-08T17:00:00-04:00", "url": "https://example.com/notes/sample-04"}, "entities": [{"id": "nora-ali", "type": "person", "name": "Nora Ali", "aliases": ["Nora"], "summary": "Atlas consultant"}], "claims": [{"subject": "nora-ali", "predicate": "works_at", "value": "Atlas", "value_entity": "atlas", "kind": "fact", "class": "observed", "evidence": "Nora works at Atlas"}, {"subject": "me", "predicate": "target_office:atlas", "value": "Undecided: Boston vs New York", "kind": "preference", "class": "declared", "evidence": "Deciding between Boston and New York"}, {"subject": "atlas", "predicate": "fact", "value": "Boston and New York share one staffing region", "kind": "fact", "class": "observed", "evidence": "Nora confirmed the regional staffing model"}], "commitments": [], "stories": [{"id": "atlas-recruiting", "note": "Nora: regional staffing"}, {"id": "office-decision", "note": "Reopened: Boston vs New York"}], "edges": [{"src": "me", "rel": "coffee_chat", "dst": "nora-ali"}, {"src": "nora-ali", "rel": "works_at", "dst": "atlas"}]}'::jsonb;
  perform apply_diff(rid, d, 'sample');
end $$;

do $$ declare rid bigint; d jsonb; begin
  insert into raw_events (provider, external_id, content_hash, kind, occurred_at, title, consent_scope, payload, content)
  values ('granola', 'sample-05', md5('sample-05'), 'meeting', '2026-10-14T18:30:00-04:00', 'Recruiting strategy with Dev Patel', 'full', '{}'::jsonb, '(sample)')
  on conflict do nothing returning id into rid;
  if rid is null then return; end if;
  d := '{"source": {"provider": "granola", "external_id": "sample-05", "title": "Recruiting strategy with Dev Patel", "occurred_at": "2026-10-14T18:30:00-04:00", "url": "https://example.com/notes/sample-05"}, "entities": [{"id": "dev-patel", "type": "person", "name": "Dev Patel", "summary": "Recruiting advisor"}, {"id": "meridian-ny", "type": "office", "name": "Meridian New York"}], "claims": [{"subject": "me", "predicate": "target_office:atlas", "value": "New York", "value_entity": "atlas-ny", "kind": "decision", "class": "observed", "evidence": "Target offices confirmed: both firms in New York"}, {"subject": "me", "predicate": "target_office:meridian", "value": "New York", "value_entity": "meridian-ny", "kind": "decision", "class": "observed", "evidence": "Target offices confirmed: both firms in New York", "change_reason": "switched from SF to New York"}, {"subject": "me", "predicate": "advice", "value": "Advocacy from inside the firm matters more than the resume", "kind": "advice", "class": "observed", "evidence": "Dev: advocacy moves the needle"}], "commitments": [{"owner": "me", "action": "Revise resume to version 3", "evidence": "Revise resume to version 3"}], "stories": [{"id": "office-decision", "note": "Confirmed: both firms in New York"}], "edges": [{"src": "dev-patel", "rel": "advises", "dst": "me"}, {"src": "meridian-ny", "rel": "office_of", "dst": "meridian"}]}'::jsonb;
  perform apply_diff(rid, d, 'sample');
end $$;

do $$ declare rid bigint; d jsonb; begin
  insert into raw_events (provider, external_id, content_hash, kind, occurred_at, title, consent_scope, payload, content)
  values ('granola', 'sample-06', md5('sample-06'), 'meeting', '2026-10-21T19:30:00-04:00', 'Atlas case interview prep session', 'full', '{}'::jsonb, '(sample)')
  on conflict do nothing returning id into rid;
  if rid is null then return; end if;
  d := '{"source": {"provider": "granola", "external_id": "sample-06", "title": "Atlas case interview prep session", "occurred_at": "2026-10-21T19:30:00-04:00", "url": "https://example.com/notes/sample-06"}, "entities": [], "claims": [{"subject": "atlas", "predicate": "process", "value": "Application due Nov 10; online case Nov 12", "kind": "fact", "class": "observed", "evidence": "Application deadline November 10"}], "commitments": [{"owner": "me", "beneficiary": "atlas", "action": "Submit Atlas application", "due_at": "2026-11-10", "evidence": "Application deadline: November 10"}, {"owner": "me", "action": "Complete Atlas practice online case before live window", "due_at": "2026-11-11", "evidence": "Practice case link in follow-up email"}], "stories": [{"id": "atlas-recruiting", "note": "Deadlines: app Nov 10, online case Nov 12"}, {"id": "case-prep", "title": "Case interview prep", "importance": 0.8, "note": "Atlas workshop: hypothesis-led"}], "edges": []}'::jsonb;
  perform apply_diff(rid, d, 'sample');
end $$;

do $$ declare rid bigint; d jsonb; begin
  insert into raw_events (provider, external_id, content_hash, kind, occurred_at, title, consent_scope, payload, content)
  values ('granola', 'sample-07', md5('sample-07'), 'meeting', '2026-10-26T14:30:00-04:00', 'Case coaching with Maya Torres', 'full', '{}'::jsonb, '(sample)')
  on conflict do nothing returning id into rid;
  if rid is null then return; end if;
  d := '{"source": {"provider": "granola", "external_id": "sample-07", "title": "Case coaching with Maya Torres", "occurred_at": "2026-10-26T14:30:00-04:00", "url": "https://example.com/notes/sample-07"}, "entities": [{"id": "maya-torres", "type": "person", "name": "Maya Torres", "aliases": ["Maya"], "summary": "Case coach; weekly sessions planned"}], "claims": [{"subject": "me", "predicate": "case_prep_cadence", "value": "3 cases/week until January", "kind": "advice", "class": "observed", "evidence": "Target 3 cases per week until January"}, {"subject": "me", "predicate": "feedback:improve", "value": "Frameworks are the highest-leverage area", "kind": "feedback", "class": "observed", "evidence": "Cascading errors trace back to framework gaps"}], "commitments": [{"owner": "me", "beneficiary": "maya-torres", "action": "Book weekly case sessions with Maya", "evidence": "Check Maya''s calendar"}], "stories": [{"id": "case-prep", "note": "Maya: 3/week, frameworks first"}], "edges": [{"src": "maya-torres", "rel": "coaches", "dst": "me"}]}'::jsonb;
  perform apply_diff(rid, d, 'sample');
end $$;

do $$ declare rid bigint; d jsonb; begin
  insert into raw_events (provider, external_id, content_hash, kind, occurred_at, title, consent_scope, payload, content)
  values ('granola', 'sample-08', md5('sample-08'), 'meeting', '2026-10-27T10:20:00-04:00', 'Consulting careers with Riley Chen (Atlas)', 'full', '{}'::jsonb, '(sample)')
  on conflict do nothing returning id into rid;
  if rid is null then return; end if;
  d := '{"source": {"provider": "granola", "external_id": "sample-08", "title": "Consulting careers with Riley Chen (Atlas)", "occurred_at": "2026-10-27T10:20:00-04:00", "url": "https://example.com/notes/sample-08"}, "entities": [{"id": "riley-chen", "type": "person", "name": "Riley Chen", "aliases": ["Riley"], "summary": "Atlas consultant, New York"}], "claims": [{"subject": "riley-chen", "predicate": "works_at", "value": "Atlas New York", "value_entity": "atlas", "kind": "fact", "class": "observed", "evidence": "Riley is in Atlas New York"}], "commitments": [{"owner": "riley-chen", "beneficiary": "me", "action": "Send PIPE team intros", "evidence": "Riley offered intros to the PIPE team"}], "stories": [{"id": "atlas-recruiting", "note": "Riley offers PIPE intros"}], "edges": [{"src": "me", "rel": "coffee_chat", "dst": "riley-chen"}, {"src": "riley-chen", "rel": "works_at", "dst": "atlas"}]}'::jsonb;
  perform apply_diff(rid, d, 'sample');
end $$;

do $$ declare rid bigint; d jsonb; begin
  insert into raw_events (provider, external_id, content_hash, kind, occurred_at, title, consent_scope, payload, content)
  values ('granola', 'sample-09', md5('sample-09'), 'meeting', '2026-10-28T16:00:00-04:00', 'Atlas PE practice with Jordan Park', 'full', '{}'::jsonb, '(sample)')
  on conflict do nothing returning id into rid;
  if rid is null then return; end if;
  d := '{"source": {"provider": "granola", "external_id": "sample-09", "title": "Atlas PE practice with Jordan Park", "occurred_at": "2026-10-28T16:00:00-04:00", "url": "https://example.com/notes/sample-09"}, "entities": [{"id": "jordan-park", "type": "person", "name": "Jordan Park", "aliases": ["Jordan"], "summary": "Atlas private equity practice"}], "claims": [{"subject": "jordan-park", "predicate": "works_at", "value": "Atlas PE practice", "value_entity": "atlas", "kind": "fact", "class": "observed", "evidence": "Jordan works in the PE practice"}], "commitments": [{"owner": "me", "beneficiary": "jordan-park", "action": "Email Jordan with go-to-market questions", "evidence": "Jordan will make intros once I email"}], "stories": [{"id": "atlas-recruiting", "note": "Jordan waiting on my email"}], "edges": [{"src": "me", "rel": "coffee_chat", "dst": "jordan-park"}, {"src": "jordan-park", "rel": "works_at", "dst": "atlas"}]}'::jsonb;
  perform apply_diff(rid, d, 'sample');
end $$;

do $$ declare rid bigint; d jsonb; begin
  insert into raw_events (provider, external_id, content_hash, kind, occurred_at, title, consent_scope, payload, content)
  values ('reflection', 'weekly-sample', md5('weekly-sample'), 'meeting', '2026-10-29T13:30:00-04:00', 'Weekly reflection pass', 'full', '{}'::jsonb, '(sample)')
  on conflict do nothing returning id into rid;
  if rid is null then return; end if;
  d := '{"source": {"provider": "reflection", "external_id": "weekly-sample", "title": "Weekly reflection pass", "occurred_at": "2026-10-29T13:30:00-04:00"}, "entities": [], "claims": [], "commitments": [], "stories": [], "edges": []}'::jsonb;
  d := jsonb_set(d, '{patterns}', '[]'::jsonb);
  d := jsonb_set(d, '{patterns}', (d->'patterns') || jsonb_build_array('{"id": "p-adoption", "title": "Adoption theme is the strongest thread", "class": "observed", "description": "The adoption point recurs across Priya and Leo. Use it as the spine of the pitch."}'::jsonb ||
       jsonb_build_object('raw_event_ids', (select jsonb_agg(id order by id) from raw_events where provider = 'granola' and external_id in ('sample-01','sample-02')))));
  d := jsonb_set(d, '{patterns}', (d->'patterns') || jsonb_build_array('{"id": "p-intros", "title": "Two inbound intros pending at Atlas", "class": "observed", "description": "Riley owes PIPE intros; Jordan is waiting on my email."}'::jsonb ||
       jsonb_build_object('raw_event_ids', (select jsonb_agg(id order by id) from raw_events where provider = 'granola' and external_id in ('sample-08','sample-09')))));
  perform apply_diff(rid, d, 'sample');
end $$;
