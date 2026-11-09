-- Server-side secret storage for OAuth refresh tokens (Google Tasks; originally Microsoft To Do).
create or replace function get_secret(p_name text) returns text
language sql security definer set search_path = public, pg_temp as $$
  select decrypted_secret from vault.decrypted_secrets where name = p_name
$$;
create or replace function set_secret(p_name text, p_value text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare sid uuid;
begin
  select id into sid from vault.secrets where name = p_name;
  if sid is null then perform vault.create_secret(p_value, p_name);
  else perform vault.update_secret(sid, p_value); end if;
end $$;
revoke execute on function get_secret(text), set_secret(text, text) from public, anon, authenticated;
grant execute on function get_secret(text), set_secret(text, text) to service_role;

-- One-time sign-in link state (unused since the switch to Google Tasks).
create or replace function new_ms_oauth_state() returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare s text := encode(extensions.gen_random_bytes(18), 'hex');
begin
  insert into kv (key, value) values ('ms_oauth_state', jsonb_build_object('state', s, 'used', false, 'at', now()))
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return s;
end $$;
revoke execute on function new_ms_oauth_state() from public, anon, authenticated;

-- Google Tasks sign-in link state.
create or replace function new_g_oauth_state() returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare s text := encode(extensions.gen_random_bytes(18), 'hex');
begin
  insert into kv (key, value) values ('g_oauth_state', jsonb_build_object('state', s, 'used', false, 'at', now()))
  on conflict (key) do update set value = excluded.value, updated_at = now();
  return s;
end $$;
revoke execute on function new_g_oauth_state() from public, anon, authenticated;
