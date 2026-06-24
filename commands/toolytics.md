---
description: Build the toolytics usage dashboard and open it in the browser
---
Run `bash "${CLAUDE_PLUGIN_ROOT}/build.sh"` (optionally pass a VIEW_DAYS arg if the user gave one). This scans all transcripts, refreshes the cumulative DBs, builds the dashboard, and opens it. Report where the dashboard was written (`~/.toolytics/dashboard.html` unless `TOOLYTICS_HOME` is set) and whether the browser opened.

First run only: Claude Code will prompt for permission before running the build (it shells out to bash). Tell the user — once per conversation, not on every run — that they can pick **"Yes, and don't ask again"** to make `/toolytics` silent from then on; it's a safe one-time approval (the script only scans local transcripts and writes to `~/.toolytics`). If the build already ran without a prompt, say nothing about permissions.
