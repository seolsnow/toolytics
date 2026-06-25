---
name: toolytics
description: Build or open the local toolytics dashboard for Claude Code and Codex usage. Use when the user asks to inspect, refresh, open, or summarize their tool usage, dashboard, or usage history.
---

# toolytics

Build the dashboard from the installed plugin copy.

1. If the user specifies a positive number of days, pass that number as the only argument. Otherwise, omit the argument.
2. Locate the installed build script, then run it:

   ```sh
   build_script="$(python3 - <<'PY'
from pathlib import Path
def key(p):
    return tuple(int(x) if x.isdigit() else x for x in p.parent.name.split('.'))
paths = sorted((Path.home() / '.codex/plugins/cache/toolytics/toolytics').glob('*/build.sh'), key=key)
print(paths[-1] if paths else '')
PY
)"
   bash "$build_script"
   bash "$build_script" 7
   ```

3. Report the dashboard location: `~/.toolytics/dashboard.html`, unless `TOOLYTICS_HOME` was set.
4. For a non-interactive build, run the same command with `TOOLYTICS_OPEN=0` and report that no browser was opened.

The plugin's trusted SessionStart hook ensures the daily collector. Do not run `install-daemon.sh` from this skill.
