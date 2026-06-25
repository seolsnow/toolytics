# toolytics

A self-contained dashboard for **your own Claude Code and Codex usage** — which
tools and MCP methods you actually reach for, and how often.

## What it does (and why you'd want it)

Claude Code and Codex log sessions locally, but neither shows you the
aggregate. toolytics reads `~/.claude/projects/**/*.jsonl` and
`~/.codex/sessions/**/*.jsonl` and answers questions you otherwise can't:

- **What do I actually use?** Every tool, `skill:<name>` invocation, and
  `mcp__server__method` call, ranked by count across *all* your projects.
- **Claude vs. Codex, direct vs. delegated.** Filter the two runtimes, then
  split main-session calls from calls your subagents/workflows made for you.
- **Which skills auto-fire?** Real counts of SessionStart hook injections
  (the skills/guidance silently prepended to your sessions), so you can see
  what's actually running vs. just installed.
- **Skills you never use.** The roster includes every installed skill, so
  zero-count ones still show up.

Everything is filterable in the browser (by runtime, direct/delegated, project,
date range, tool search) — the dashboard is one self-contained HTML file with
the data inlined, so you can open or archive it offline. If you share that file,
treat it as local usage metadata: project labels and tool/skill/plugin counts
are embedded in the HTML. Injection and skill-inventory data currently come from
Claude Code only.

It also **outlives log cleanup.** Claude Code deletes transcripts after
~30 days; toolytics keeps a cumulative CSV and (optionally) runs a daily
background daemon so your history keeps growing even after the raw logs are gone.
Installing as either the Claude Code or Codex plugin registers that daemon for
you; a standalone setup registers it by running `./install-daemon.sh` once
(see below).

## Quick start
Requires `bash` and `python3`.

```sh
./build.sh               # scan everything → update cumulative DBs → build dashboard → open browser
./build.sh 7             # default view to last 7 days (full history is still kept)
./build.sh --selfcheck   # regression guard for the merge & attribution logic
```
Output goes to `~/.toolytics/` (override with `TOOLYTICS_HOME`):
`history.csv` / `injects.csv` (cumulative DBs) + `dashboard.html`.
Scans are incremental: unchanged transcripts are reused from a per-file cache
(`scan-state.json`), so re-runs only reparse changed files. That cache is purely
a speed-up — delete it any time and the next run full-scans and rebuilds it.

## Platform support
- macOS: full support, including the launchd daily collector.
- Linux: full support, including a systemd user timer or cron fallback.
- WSL: use the Linux path. Data, daemon registration, and `~/.toolytics` live
  inside WSL.
- Native Windows: manual builds only for now. Use a shell with `bash` and
  `python3`, run `./build.sh`, and open `~/.toolytics/dashboard.html` yourself
  if the browser does not auto-open. The plugin hook is fail-open, but it cannot
  register the daily collector until native Windows scheduling is implemented.

VS Code does not need special integration. toolytics scans the transcript roots
visible from the process that runs it. In local VS Code terminals that means the
local home directory; in WSL, Remote SSH, dev containers, or Codespaces it means
the remote/container home directory, not your host machine's logs.

## Install
toolytics scans both `~/.claude/projects` and `~/.codex/sessions`, so one install
covers Claude Code, Codex, or both. Pick the path that fits your setup.

### Standalone (any runtime — Claude Code, Codex, or both)
Clone the repo and run the build; it collects every runtime it finds on disk:
```sh
./build.sh               # scan → update cumulative DBs → build dashboard → open browser
./install-daemon.sh      # (optional) register the daily collector so history survives log cleanup
```
`install-daemon.sh` is idempotent — re-running just refreshes the registration.
The daily collector installer supports macOS launchd and Linux systemd/cron. On
native Windows there is no auto-daemon — run `./build.sh` yourself (or via Task
Scheduler), or use WSL for the daemon path. Remove it any time with
`./install-daemon.sh --remove`.

### As a Codex plugin (auto-registers the daemon)

From a local clone, register the repository marketplace and install the plugin:

```sh
codex plugin marketplace add .
codex plugin add toolytics@toolytics
```

For GitHub, replace `.` with `seolsnow/toolytics`. Start a new Codex thread,
run `/hooks`, and trust the `toolytics` SessionStart hook. The hook calls
`install-daemon.sh ensure`, so the daily collector registers or repairs itself
before dashboard use. Then ask Codex to open the toolytics dashboard or invoke
`$toolytics`.

### As a Claude Code plugin (auto-registers the daemon)
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
Once installed, a SessionStart hook self-installs the daily collector daemon
(macOS launchd / Linux systemd·cron), which gathers data before transcript
cleanup (default 30 days) so past history is preserved. This auto-registration
also applies to the Codex plugin above. The daemon outlives the plugin, so to
stop it run `install-daemon.sh --remove` **before** uninstalling the plugin
(while the script is still on disk); otherwise its daily run just fails harmlessly
once the script path is gone.

## Permissions — prompts depend on your client configuration

`/toolytics` runs a local Bash script, and the plugin has a SessionStart hook
that registers the daily collector. Claude Code may ask for one-time approval
of either action, depending on your client and permission settings:

1. **Trust the plugin hook**, if Claude Code asks. The hook only ensures the
   per-user daily collector is registered.
2. **Allow the build**, if `/toolytics` prompts before running Bash. Choose
   **"Yes, and don't ask again"** to persist that approval. The script only
   reads local transcripts and writes to `~/.toolytics`.

A configuration such as `"permissions": { "defaultMode": "auto" }` can
allow the build without showing the Bash prompt. Hook trust is controlled
separately, so do not infer one prompt from the presence or absence of the
other.

In Codex, review and trust the `toolytics` hook through `/hooks`. That trust is
separate from normal Bash-command approvals.

The daily collector runs outside Claude Code after registration. It rebuilds
`~/.toolytics/dashboard.html` daily, so bookmarking
`file://$HOME/.toolytics/dashboard.html` opens the latest completed build.

Rather pre-authorize than click? Add this once to `~/.claude/settings.json`:
```json
"permissions": { "allow": ["Bash(bash *toolytics*build.sh*)"] }
```

## Environment variables
- `TOOLYTICS_HOME` — output directory (default `~/.toolytics`)
- `TOOLYTICS_OPEN=0` — skip auto-opening the browser
- `TOOLYTICS_TRIM="a,b"` — strip leading path segments from project labels (cosmetic)
- `TOOLYTICS_INJECT_ALIAS="check-setup.sh=superpowers"` — relabel an inject source
  whose plugin can't be auto-resolved (a hook script deleted across versions before
  it was ever scanned). One run seeds the persistent attribution cache. Empty by default.

For the design and rationale, see [AGENTS.md](AGENTS.md).
