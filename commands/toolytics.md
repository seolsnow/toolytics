---
description: Build the toolytics usage dashboard and open it in the browser
---
Run `bash "${CLAUDE_PLUGIN_ROOT}/build.sh"` (optionally pass a VIEW_DAYS arg if the user gave one). This scans all transcripts, refreshes the cumulative DBs, builds the dashboard, and opens it. Report where the dashboard was written (`~/.toolytics/dashboard.html` unless `TOOLYTICS_HOME` is set) and whether the browser opened.

If Claude Code prompts for Bash permission on the first run, tell the user —
once per conversation, not on every run — that they can pick **"Yes, and don't
ask again"** to persist the approval. The script only scans local transcripts
and writes to `~/.toolytics`. Do not mention permissions if the build already
ran without a prompt (for example because the user's default mode is `auto`).
