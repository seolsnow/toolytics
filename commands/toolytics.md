---
description: Build the toolytics usage dashboard and open it in the browser
---
Run `bash "${CLAUDE_PLUGIN_ROOT}/build.sh"` (optionally pass a VIEW_DAYS arg if the user gave one). This scans all transcripts, refreshes the cumulative DBs, builds the dashboard, and opens it. Report where the dashboard was written (`~/.toolytics/dashboard.html` unless `TOOLYTICS_HOME` is set) and whether the browser opened.
