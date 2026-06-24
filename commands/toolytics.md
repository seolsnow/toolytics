---
description: cc-usage 사용량 대시보드 빌드 후 브라우저로 열기
---
Run `bash "${CLAUDE_PLUGIN_ROOT}/build.sh"` (optionally pass a VIEW_DAYS arg if the user gave one). This scans all transcripts, refreshes the cumulative DBs, builds the dashboard, and opens it. Report where the dashboard was written (`~/.cc-usage/dashboard.html` unless `CC_USAGE_HOME` is set) and whether the browser opened.
