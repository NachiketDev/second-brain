-- Instinct bridge (27 Nov). Instinct is his cloud agent (texted on WhatsApp) with its own browser; it acts on LinkedIn.
-- It has no MCP, so it reaches the brain through edge fn `instinct` with its own Vault token (brain_instinct_secret).
-- Three things: a networking brief (what is due, caps, which firms next), a structured outreach log, and capture
-- (what he tells Instinct, relayed into raw memory). Nothing here sends anything to anyone.

create table if not exists outreach_log (
  id bigserial primary key,
  at timestamptz not null default now(),
  person text not null,
  firm text,
  title text,
  event text not null check (event in ('target', 'invite_sent', 'accepted', 'message_sent', 'nudge_sent', 'replied',
                                       'call_booked', 'call_done', 'thanks_sent', 'blocked', 'declined', 'note')),
  channel text not null default 'linkedin',
  note text,
  linkedin_url text,
  follow_up date,          -- when to look again (invite_sent: 6 weeks; blocked: when the block lifts)
  source text not null default 'instinct',
  raw_event_id bigint,
  over_cap boolean not null default false
);
create index if not exists outreach_log_person on outreach_log (lower(person), at desc);
alter table outreach_log enable row level security;

create or replace function ny_today() returns date language sql stable as $$ select (now() at time zone 'America/New_York')::date $$;

-- Record one outreach event. Logged even if over the cap (it already happened), but flagged so the brief shows it.
create or replace function brain_log_outreach(p jsonb) returns jsonb
language plpgsql set search_path = public, pg_temp as $$
declare r outreach_log; ev text := lower(trim(p->>'event')); n_day int; n_week int; at_ts timestamptz;
  person text := nullif(trim(p->>'person'), ''); raw jsonb;
begin
  if person is null then raise exception 'person is required'; end if;
  if ev is null then raise exception 'event is required'; end if;
  at_ts := coalesce(nullif(p->>'at', '')::timestamptz, now());
  select count(*) filter (where (o.at at time zone 'America/New_York')::date = (at_ts at time zone 'America/New_York')::date),
         count(*) filter (where o.at > at_ts - interval '7 days')
    into n_day, n_week from outreach_log o where o.event = 'invite_sent';
  insert into outreach_log (at, person, firm, title, event, channel, note, linkedin_url, follow_up, source, over_cap)
  values (at_ts, person, nullif(trim(p->>'firm'), ''), nullif(trim(p->>'title'), ''), ev, coalesce(nullif(p->>'channel', ''), 'linkedin'),
    nullif(trim(p->>'note'), ''), nullif(trim(p->>'linkedin_url'), ''),
    coalesce(nullif(p->>'follow_up', '')::date,
      case ev when 'invite_sent' then (at_ts at time zone 'America/New_York')::date + 42
              when 'message_sent' then (at_ts at time zone 'America/New_York')::date + 7 end),
    coalesce(nullif(p->>'source', ''), 'instinct'),
    ev = 'invite_sent' and (n_day >= 15 or n_week >= 70))
  returning * into r;
  -- Also into raw memory, so the compiler files the person, firm, title and LinkedIn URL
  -- (skip_memory: for events already captured another way, such as the 27 Nov seed from two check-ins).
  if not coalesce((p->>'skip_memory')::boolean, false) then
    raw := ingest_raw('instinct_outreach', 'outreach:' || r.id, r.at,
      format('LinkedIn %s: %s%s', replace(r.event, '_', ' '), r.person, coalesce(' (' || r.firm || ')', '')),
      concat_ws(E'\n', 'Outreach event logged by Instinct (his LinkedIn agent).', 'Event: ' || r.event, 'Person: ' || r.person,
        'Firm: ' || r.firm, 'Title: ' || r.title, 'LinkedIn: ' || r.linkedin_url, 'Note: ' || r.note, 'Follow up: ' || r.follow_up),
      r.linkedin_url, 'outreach', jsonb_build_object('outreach_id', r.id));
    update outreach_log set raw_event_id = nullif(raw->>'id', '')::bigint where id = r.id;
  end if;
  return jsonb_build_object('id', r.id, 'event', r.event, 'person', r.person, 'follow_up', r.follow_up, 'over_cap', r.over_cap,
    'invites_today', n_day + (ev = 'invite_sent')::int, 'invites_7d', n_week + (ev = 'invite_sent')::int);
end $$;

-- What Instinct should do today. Caps: 15 invites a day, 70 a rolling week.
create or replace function desk_networking() returns jsonb
language sql stable set search_path = public, pg_temp as $$
with s as (   -- latest state per person
  select distinct on (lower(o.person)) lower(o.person) k, o.person, o.firm, o.title, o.event last_event, o.at last_at,
         o.follow_up, o.linkedin_url
  from outreach_log o where o.event <> 'note' order by lower(o.person), o.at desc
), f as (
  select lower(person) k, max(firm) filter (where firm is not null) firm,
         bool_or(event = 'accepted') accepted, bool_or(event = 'replied') replied, bool_or(event = 'nudge_sent') nudged,
         max(at) filter (where event = 'accepted') accepted_at
  from outreach_log group by 1
), caps as (
  select count(*) filter (where (at at time zone 'America/New_York')::date = ny_today()) d,
         count(*) filter (where at > now() - interval '7 days') w
  from outreach_log where event = 'invite_sent'
), due as (
  select case
      when s.last_event = 'blocked' and coalesce(s.follow_up, ny_today()) <= ny_today() then 'retry_invite'
      when s.last_event = 'accepted' then 'propose_call_times'
      when s.last_event = 'call_done' then 'send_thank_you'
      when s.last_event in ('message_sent') and not f.replied and not f.nudged and s.follow_up <= ny_today() then 'send_one_nudge'
      when s.last_event = 'invite_sent' and s.follow_up <= ny_today() then 're_engage'
      when s.last_event = 'target' then 'invite' end as action,
    s.*, f.replied
  from s join f using (k)
)
select jsonb_build_object(
  'today', ny_today(),
  'caps', (select jsonb_build_object('invites_today', d, 'left_today', greatest(15 - d, 0), 'invites_7d', w, 'left_7d', greatest(70 - w, 0)) from caps),
  'due', (select coalesce(jsonb_agg(jsonb_build_object('action', action, 'person', person, 'firm', firm, 'title', title,
            'last', last_event, 'last_at', (last_at at time zone 'America/New_York')::date, 'linkedin_url', linkedin_url)
            order by case action when 'send_thank_you' then 1 when 'propose_call_times' then 2 when 'send_one_nudge' then 3
                                 when 're_engage' then 4 when 'retry_invite' then 5 else 6 end, last_at), '[]')
          from due where action is not null),
  'waiting', (select coalesce(jsonb_agg(jsonb_build_object('person', person, 'firm', firm, 'last', last_event,
               'since', (last_at at time zone 'America/New_York')::date, 'look_again', follow_up) order by follow_up nulls last), '[]')
              from due where action is null),
  'firms', (select coalesce(jsonb_agg(x order by x->>'deadline' nulls last, (x->>'contacts')::int), '[]') from (
      select jsonb_build_object('id', p.id, 'firm', p.title, 'stage', p.stage, 'deadline', p.deadline,
        'contacts', (select count(distinct lower(o.person)) from outreach_log o
                     where o.firm is not null and (lower(p.title) like '%' || lower(o.firm) || '%' or lower(o.firm) like '%' || lower(split_part(p.title, ' (', 1)) || '%')),
        'known_people', (select coalesce(jsonb_agg(distinct e.name), '[]') from edges g join entities e on e.id = g.src
                         where g.rel in ('works_at', 'office_of') and g.dst = p.org_entity and e.type = 'person')) x
      from pursuits p where p.kind = 'firm' and p.status = 'active' and coalesce(p.stage, '') not in ('closed', 'offer') and (p.deadline is null or p.deadline >= ny_today())) y),
  'rules', 'Caps: 15 invites a day, 70 a week. Never resend while blocked. One nudge only, 7 days after a message. Anything sent to people needs his yes, given by him, unless he set a standing approval himself.'
);
$$;

-- What he tells Instinct counts as something he said (diary and memory).
create or replace function diary_source_providers() returns text[] language sql immutable as
$$ select array['checkin','correction','confirmation','claude_chat','bee','voice','note','instinct'] $$;

revoke all on table outreach_log from public, anon, authenticated;
do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname in ('brain_log_outreach', 'desk_networking', 'ny_today') loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
