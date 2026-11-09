-- Calendar events whose title matches any pattern in kv 'calendar_exclude' are never stored.
insert into public.kv(key, value) values ('calendar_exclude', '["^discussion group$"]'::jsonb)
on conflict (key) do update set value = excluded.value;

create or replace function public.calendar_skip_excluded() returns trigger
language plpgsql set search_path = public as $$
begin
  if exists (select 1 from kv, jsonb_array_elements_text(kv.value) pat
             where kv.key = 'calendar_exclude' and new.title ~* pat) then
    return null;   -- silently skip events you've asked the brain to ignore
  end if;
  return new;
end $$;

drop trigger if exists calendar_skip_excluded on public.calendar_events;
create trigger calendar_skip_excluded before insert or update on public.calendar_events
  for each row execute function public.calendar_skip_excluded();

-- Email cursor for the forwarded-school-mail step of the scheduled task (Unix seconds).
insert into public.kv(key, value) values ('hbs_email_cursor', '"1793595300"'::jsonb) on conflict do nothing;
