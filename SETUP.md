# Setup (about 30 minutes)

No Anthropic API key, no Zapier, no paid Granola plan. The thinking runs as a scheduled Claude task under
your Claude plan. Supabase stores the brain and runs the non-AI jobs (calendar sync, agents, digest).

```
Granola ──(Claude task pulls via connector)──► ingest_raw ─► raw_events
Bee ──(poll function)──────────────────────────────────────► raw_events
Voice memo ──(iOS Shortcut → ingest function)──────────────► raw_events
                                   Claude task: claim → brain_context → apply_diff → brain + change_log
Calendar ──(poll function)──► calendar_events ──► Claude task writes briefings
                                   agents function (hourly) ──► proposals ──► digest email ──► act
```

## 1. Connect Supabase to Claude
Connect the Supabase connector in claude.ai, then tell Claude "set up my second brain". With the connector,
Claude can create the project, apply the three migrations, load the October seed and deploy the five
functions for you. Or do it yourself:
```bash
supabase link --project-ref <ref>
supabase db push
supabase functions deploy
```
Then run `supabase/seed_october.sql` in the SQL editor.

## 2. Secrets for the functions
Dashboard → Edge Functions → Secrets (or `supabase secrets set ...`):

| Secret | What | Needed for |
|---|---|---|
| `CRON_SECRET`, `INGEST_SECRET` | two random strings (`openssl rand -hex 24`) | always |
| `DIGEST_EMAIL`, `RESEND_API_KEY` | your email; free key from resend.com | morning digest |
| `TODOIST_API_TOKEN` | Todoist → Settings → Integrations → Developer | approving tasks |
| `CALENDAR_ICS_URL` | Google Calendar → Settings → your calendar → "Secret address in iCal format" | briefings |
| `BEE_API_TOKEN` | docs.bee.computer | if you use Bee |
| `BRAIN_TIMEZONE` | `America/New_York` | dates in emails |

Then in the SQL editor, so cron can call the functions:
```sql
select vault.create_secret('https://<ref>.supabase.co', 'brain_project_url');
select vault.create_secret('<CRON_SECRET>', 'brain_cron_secret');
```
and run `supabase/migrations/20261029000002_schedules.sql` again if it ran before the secrets existed.

## 3. The scheduled Claude task
Ask Claude: "create the second brain scheduled task". It runs `CLAUDE_TASK.md` a few times a day and needs
the Granola and Supabase connectors. Each run: pulls new Granola notes, compiles them, writes briefings.
Runs count toward your Claude plan's usage, not a separate bill.

## 4. Optional: voice debriefs (iPhone Shortcut)
*Dictate Text* → *Get Contents of URL*: POST `https://<ref>.supabase.co/functions/v1/ingest`, header
`x-brain-secret: <INGEST_SECRET>`, JSON body `provider` = voice, `title` = Voice debrief,
`content` = Dictated Text. The next task run compiles it.

## Day to day
- Morning digest: what changed and why, plus suggestions. Every action needs a second confirm click.
- `[private]` in a meeting title keeps it out. `NDA` or `confidential` stores only people and commitments.
- New notes appear in the brain at the next task run, not instantly.
