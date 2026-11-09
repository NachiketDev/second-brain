create extension if not exists pg_cron;
create extension if not exists pg_net;
create extension if not exists pgcrypto with schema extensions;

-- Random secrets generated inside the database; nobody types or sees them unless they look in Vault.
do $$ begin
  if not exists (select 1 from vault.secrets where name = 'brain_cron_secret') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(24), 'hex'), 'brain_cron_secret');
  end if;
  if not exists (select 1 from vault.secrets where name = 'brain_ingest_secret') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(24), 'hex'), 'brain_ingest_secret');
  end if;
  if not exists (select 1 from vault.secrets where name = 'brain_project_url') then
    perform vault.create_secret('https://<your-project-ref>.supabase.co', 'brain_project_url');
  end if;
end $$;

-- Edge functions check incoming secrets here instead of holding a copy.
create or replace function check_secret(p_name text, p_value text) returns boolean
language sql security definer set search_path = public, pg_temp as $$
  select coalesce(p_value <> '' and p_value = (select decrypted_secret from vault.decrypted_secrets where name = p_name), false)
$$;
revoke execute on function check_secret(text, text) from public, anon, authenticated;
grant execute on function check_secret(text, text) to service_role;

create or replace function brain_call(fn text) returns bigint language sql security definer
set search_path = public, pg_temp as $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'brain_project_url') || '/functions/v1/' || fn,
    headers := jsonb_build_object('content-type', 'application/json',
      'authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'brain_cron_secret')),
    body := '{}'::jsonb,
    timeout_milliseconds := 150000)
$$;
revoke execute on function brain_call(text) from public, anon, authenticated;

select cron.unschedule(jobname) from cron.job where jobname like 'brain-%';
select cron.schedule('brain-poll',    '*/15 * * * *', $$ select brain_call('poll') $$);
select cron.schedule('brain-agents',  '7 * * * *',    $$ select brain_call('agents') $$);
select cron.schedule('brain-digest',  '31 11 * * *',  $$ select brain_call('digest') $$);
