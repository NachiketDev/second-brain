-- Schedules. Before running this, store two secrets in Vault (SQL editor):
--   select vault.create_secret('https://<project-ref>.supabase.co', 'brain_project_url');
--   select vault.create_secret('<same value as the CRON_SECRET function secret>', 'brain_cron_secret');
create extension if not exists pg_cron;
create extension if not exists pg_net;

create or replace function brain_call(fn text) returns bigint language sql security definer as $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'brain_project_url') || '/functions/v1/' || fn,
    headers := jsonb_build_object('content-type', 'application/json',
      'authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'brain_cron_secret')),
    body := '{}'::jsonb,
    timeout_milliseconds := 150000)
$$;

select cron.unschedule(jobname) from cron.job where jobname like 'brain-%';
select cron.schedule('brain-poll',    '*/15 * * * *', $$ select brain_call('poll') $$);
select cron.schedule('brain-agents',  '7 * * * *',    $$ select brain_call('agents') $$);
-- 11:31 UTC = 7:31 am New York in EST (6:31 am during daylight time). Adjust to taste.
select cron.schedule('brain-digest',  '31 11 * * *',  $$ select brain_call('digest') $$);
