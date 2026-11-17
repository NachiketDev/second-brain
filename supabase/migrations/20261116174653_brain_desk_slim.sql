do $do$ declare d text; begin
  d := pg_get_functiondef('public.brain_desk(date)'::regprocedure);
  -- only the two briefing pieces the screens use
  d := replace(d, '''brief'', brain_daily_brief((select day from d)),',
    '''brief'', (select jsonb_build_object(''meeting_briefings'', b->''meeting_briefings'', ''changed_last_24h'', b->''changed_last_24h'') from (select brain_daily_brief((select day from d))::jsonb b) bb),');
  -- commitments: open ones plus anything decided in the last 45 days
  d := replace(d, 'order by c.id), ''[]'') from commitments c)',
    'order by c.id), ''[]'') from commitments c where c.status in (''open'',''needs_review'') or c.updated_at > now() - interval ''45 days'')');
  -- drop source titles from commitments
  d := replace(d, ',
                    ''source'', (select title from raw_events where id = c.raw_event_id))', ')');
  -- story summaries shorter, two notes
  d := replace(d, 'left(s.summary, 400)', 'left(s.summary, 220)');
  d := replace(d, 'order by r.occurred_at desc limit 4) q)', 'order by r.occurred_at desc limit 2) q)');
  execute d;
end $do$;
