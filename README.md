# toolytics

A self-contained dashboard for **your own Claude Code usage** — which skills,
tools, and MCP methods you actually reach for, how often, and what they cost.

## What it does (and why you'd want it)

Claude Code logs every session to `~/.claude/projects/**/*.jsonl`, but never
shows you the aggregate. toolytics reads those transcripts and answers
questions you otherwise can't:

- **What do I actually use?** Every tool, `skill:<name>` invocation, and
  `mcp__server__method` call, ranked by count across *all* your projects.
- **Direct vs. delegated.** It splits calls you made yourself in the main
  session from calls your subagents/workflows made for you. The delegated
  layer is usually **~2/3 of all calls** (mostly Read/WebFetch/WebSearch from
  research agents) — invisible if you only eyeball your own session.
- **What am I spending?** Per-model token totals and an estimated API value,
  from the `message.usage` records in the logs.
- **Which skills auto-fire?** Real counts of SessionStart hook injections
  (the skills/guidance silently prepended to your sessions), so you can see
  what's actually running vs. just installed.
- **Skills you never use.** The roster includes every installed skill, so
  zero-count ones still show up.

Everything is filterable in the browser (by direct/delegated, project, date
range, tool search) — the dashboard is one self-contained HTML file with the
data inlined, so you can open or share it offline.

It also **outlives log cleanup.** Claude Code deletes transcripts after
~30 days; toolytics keeps a cumulative CSV and (optionally) installs a daily
background daemon so your history keeps growing even after the raw logs are gone.

## Quick start
```sh
./build.sh               # scan everything → update cumulative DBs → build dashboard → open browser
./build.sh 7             # default view to last 7 days (full history is still kept)
./build.sh --selfcheck   # regression guard for the merge & attribution logic
```
Output goes to `~/.toolytics/` (override with `TOOLYTICS_HOME`):
`history.csv` / `tokens.csv` / `injects.csv` (cumulative DBs) + `dashboard.html`.

## Install as a plugin
This repo is itself the plugin **and** the marketplace (`marketplace.json` with
`source: "./"`).

Inside Claude Code (interactive):
```
/plugin marketplace add seolsnow/toolytics    # or a local clone path
/plugin install toolytics@toolytics
```
From a terminal (non-interactive):
```sh
claude plugin marketplace add seolsnow/toolytics
claude plugin install toolytics@toolytics --scope user
```
Once installed, `/toolytics` builds the dashboard, and a SessionStart hook
self-installs the daily collector daemon (macOS launchd / Linux systemd·cron).
It gathers data before transcript cleanup (default 30 days) so past history is
preserved.

## Environment variables
- `TOOLYTICS_HOME` — output directory (default `~/.toolytics`)
- `TOOLYTICS_OPEN=0` — skip auto-opening the browser
- `TOOLYTICS_TRIM="a,b"` — strip leading path segments from project labels (cosmetic)

For the design and rationale, see [AGENTS.md](AGENTS.md).
