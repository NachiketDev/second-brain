# Migrations

Applied in filename order. The first eight files predate the live history and were consolidated when
the repo was published; the live project records them as:

| File | Live migration |
|---|---|
| 20261029000001_brain.sql | 20261030015100 brain |
| 20261029000002/3_*.sql | 20261030015139 claude_task |
| 20261029000004_hardening.sql | 20261030015148 hardening |
| 20261030184034_vault_secrets_and_schedules.sql | 20261030184034 vault_secrets_and_schedules |
| 20261030223714_secrets_helpers.sql | 20261030223714 ms_todo_secrets + 20261102043036 google_oauth_state |
| 20261102035828_ingest_skip_unchanged_source.sql | 20261102035828 ingest_skip_unchanged_source |
| 20261102045312_calendar_exclude.sql | 20261102045312 calendar_exclude |

From 20261103065656 on, each file is the exact statement text of the live migration with the same
version, with personal identifiers replaced by placeholders (`<your-project-ref>`, `<school-email>`).
`v1-desk` tags the state before the core model rebuild (17 Nov 2026).

## 17 Nov 2026 rebuild, steps 4 to 8
- `20261117080000_backfill_and_gsync.sql`: goal write path, one-time helpers (completed_at, clearing suggestions),
  Google Tasks two-way sync functions (`brain_gtask_seen`, `brain_gtask_queue`, `brain_gtask_pushed`).
- `core_backfill` (applied live, not in this public repo): the approved one-time data load. It only calls
  `brain_upsert_goal`, `brain_upsert_pursuit`, `brain_set_commitment`, `brain_backfill_completed_at`,
  `brain_add_contact` and seeds kv `gtask_title_links`. It holds personal data, so it stays private.
- `20261117082000_desk_goals.sql`: goal boxes with this week's progress for desk v2.
