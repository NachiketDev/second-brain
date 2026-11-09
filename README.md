# Second Brain

A personal "cognitive twin" built on Supabase. It captures meeting notes, email, calendars and voice memos into an immutable raw store. A scheduled Claude task compiles them into versioned, linked memory: people, facts, commitments, stories and patterns. Every change is logged with what changed, when and why. Agents read that memory and propose actions, but they are suggest-only, so nothing is sent, booked or deleted without a two-click confirmation.

There is no separate AI bill: the intelligence layer is a scheduled Claude task that calls narrow database functions, never raw table writes.

```
 Granola (Claude task)   Bee (polled)   Voice memo (iOS Shortcut)   Calendar (iCal feed)
            \               |                 /                          |
             └──────► ingest / poll ◄────────┘                           |
                          │                                              |
   1 RAW MEMORY     raw_events (untouched, revisioned, consent-scoped)   |
                          │  scheduled Claude task (your Claude plan)    |
   2 SECOND BRAIN   entities · facts (versioned) · commitments ·         |
                    dependencies · stories · edges · patterns            |
                          │  every write is logged automatically         |
   3 CHANGE LOG     what changed · when (valid / learned) · why (source, |
                    run, reason) · impact (flagged dependents)           |
                          │                                              ▼
   4 AGENTS (hourly, suggest-only)  todo · deadline · followup · review · prep briefing
                          │
                    proposals ──► daily digest email ──► you click ──► act ──► Todoist / Calendar link / draft
```

## How "what changed, when and why" works
- Facts are never overwritten. A new value for the same subject and predicate becomes `current`; the old one becomes `superseded` with `valid_to` set.
- Every fact and commitment change writes a `change_log` row automatically through database triggers: a summary, before and after values, the raw event that caused it, the compiler run, and the reason.
- Commitments record the facts they depend on. When one changes, the commitment is flagged `needs_review` with the reason, and the review agent asks you to keep it or drop it.
- Your own decisions from the digest (keep, drop, done) go into the change log too.

## Layout
| Path | What |
|---|---|
| `supabase/migrations/…01_brain.sql` | Tables, triggers, `apply_diff`, views |
| `supabase/migrations/…02_schedules.sql` | Cron jobs |
| `supabase/functions/ingest` | Webhook front door (Zapier, Shortcuts, anything) |
| `supabase/functions/poll` | Pulls Bee conversations and your calendar feed |
| `supabase/functions/agents` | Writes proposals from the brain and the change log (no AI) |
| `supabase/functions/digest` | Morning email with changes and approve links |
| `supabase/functions/act` | Executes what you approve (two-click confirm) |
| `supabase/migrations/…03_claude_task.sql` | SQL entry points the Claude task uses |
| `CLAUDE_TASK.md` | The intelligence layer: instructions for the scheduled Claude task |
| `supabase/seed_sample.sql`, `sample/` | Ten fictional, already-compiled events to try the brain with (all people and firms are invented) |
| `test/` | Embedded-Postgres tests for the database layer |

## Guarantees (tested in `test/`)
- Re-delivering the same note changes nothing; an edited note becomes a revision
- Ingest order doesn't change the result
- A claim the AI inferred can't be stored as a fact; a bad diff is rolled back whole
- Facts about unknown entities are rejected
- A changed fact flags the commitments that rested on it, with the reason
- `[private]` in a meeting title keeps it out; `NDA` or `confidential` stores only people and commitments

Run tests: `cd test && npm install && node test_db.mjs && node test_task.mjs`

## Design principles
- **Raw memory is never edited.** Re-delivered notes are deduplicated and edited notes become revisions.
- **One write path.** The AI can only change memory through `apply_diff()`, which validates the whole diff and applies it atomically.
- **Hypotheses are not facts.** An inferred claim can't be stored as a fact. Guesses stay hypotheses until the user confirms them in conversation.
- **Consent by title.** `[private]` keeps a meeting out entirely, and `NDA` or `confidential` stores only people and commitments.
- **Suggest-only agents.** Every action needs two clicks: the digest link, then a confirm link.
- **Secrets live in Supabase Vault and edge-function secrets.** Nothing secret is in this repo. See `SETUP.md` for the names to create.

## Try it
1. Create a Supabase project and apply `supabase/migrations` in order.
2. Run `supabase/seed_sample.sql` to load the fictional sample week.
3. Follow `SETUP.md` to add secrets, deploy the edge functions and point `CLAUDE_TASK.md` at your project ref.
