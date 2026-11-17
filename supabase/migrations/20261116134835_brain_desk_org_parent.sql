do $do$ declare d text; begin
  d := replace(pg_get_functiondef('public.brain_desk(date)'::regprocedure),
    '''org_name'', (select name from entities where id = p.org)',
    '''org_name'', (select name from entities where id = p.org), ''parent'', coalesce((select x.dst from edges x where x.src = p.org and x.rel = ''office_of'' limit 1), p.org), ''parent_name'', (select name from entities where id = coalesce((select x.dst from edges x where x.src = p.org and x.rel = ''office_of'' limit 1), p.org))');
  execute d;
end $do$;
