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
