---
name: toolytics
description: Build or open the local toolytics dashboard for Claude Code and Codex usage. Use when the user asks to inspect, refresh, open, or summarize their tool usage, dashboard, or usage history.
---

# toolytics

Build the dashboard from the installed plugin copy.

1. If the user specifies a positive number of days, pass that number as the only argument. Otherwise, omit the argument.
2. Run one of these commands:

   ```sh
   bash "$HOME/.codex/plugins/cache/toolytics/toolytics/local/build.sh"
   bash "$HOME/.codex/plugins/cache/toolytics/toolytics/local/build.sh" 7
   ```

3. Report the dashboard location: `~/.toolytics/dashboard.html`, unless `TOOLYTICS_HOME` was set.
4. For a non-interactive build, run the same command with `TOOLYTICS_OPEN=0` and report that no browser was opened.

The plugin's trusted SessionStart hook ensures the daily collector. Do not run `install-daemon.sh` from this skill.
