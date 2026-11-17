# Desk app

`v1/` is the desk screen as of 16 Nov 2026 (control room, workbench, observatory, planning, mirror, trust).
It runs as a Claude artifact through the Second Brain connector (`get_desk`, `mark_commitment`), or opened
from disk, where it reads `GET <project>/functions/v1/desk/<brain_mcp_secret>`. It is kept running until
v2 (built on the per-view SQL functions) passes the acceptance tests.
