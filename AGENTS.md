# toolytics — Claude Code usage dashboard

## Purpose
Aggregate skill/tool usage from my Claude Code session transcripts into a
filterable dashboard. (All projects combined, last N days.)

## How it works / context
- **Data source**: `~/.claude/projects/**/*.jsonl` (fully recursive). The logs
  Claude Code writes for every conversation as line-delimited JSON. The per-line
  `timestamp` field drives the window filter.
- **Two layers** — the key distinction:
  - `main` = calls I made directly in the main session (≈4.6k).
  - `agent` = calls a subagent/workflow I spawned made on my behalf. Path
    contains `/subagents/`. Research delegation, so mostly Read/WebFetch/WebSearch.
    **About 2/3 of the total** (≈8.7k) — easy to miss.
- **Tidy table schema**: `date, triggered_by(main|agent), project, tool, count`.
  Skill calls go into `tool` as `skill:<name>`; MCP keeps the raw
  `mcp__server__method` form.
- **Reproduce/build**: `./build.sh [VIEW_DAYS]` (default 30) → full scan →
  refresh cumulative DBs → build dashboard → auto-open browser.
  - Output location: `~/.toolytics/` (change via env `TOOLYTICS_HOME`).
    `history.csv` (cumulative DB) + `dashboard.html` (self-contained, data inlined).
  - For tests, skip the browser open with `TOOLYTICS_OPEN=0`.
  - The dashboard template is `dashboard.template.html` in this folder; JSON is
    injected at the `/*__DATA__*/` slot.
- **Cumulative strategy (core)**: the scan reads every jsonl on disk with no time
  window. All three cumulative DBs (`history.csv`/`tokens.csv`/`injects.csv`) are
  merged by **replace-by-date** — dates the scan covered get their rows replaced
  wholesale (= rerunning doesn't inflate them, idempotent), while older dates the
  scan didn't see are preserved. So even if logs rotate/are deleted, past
  aggregates survive and keep accumulating. Only the dashboard's default view is
  cropped to the last `VIEW_DAYS`; the data holds the full span (`default_from`
  injected).
- **Daily collector daemon (cleanup defense)**: `build.sh` only runs when invoked,
  so if you don't open the dashboard for 30+ days, Claude Code transcript cleanup
  (default `cleanupPeriodDays` 30) deletes the raw jsonl and that window is lost
  forever before it ever lands in the cumulative CSV (the cumulative strategy only
  preserves a date "if a scan caught it at least once"). → `install-daemon.sh`
  registers a per-user OS scheduler to run `TOOLYTICS_OPEN=0 build.sh` once a day,
  guaranteeing collection before cleanup: macOS = launchd LaunchAgent,
  Linux = systemd `--user` timer (`Persistent=true`), cron if systemd is absent.
  **The plist/unit is generated at install time** — build path, PATH, and home are
  all derived from `$HOME` · `command -v python3` · the script's own location
  (zero hardcoded strings, same self-configuring philosophy as inject
  attribution). It's idempotent, so rerunning = bootout→bootstrap refresh; the
  `ensure` subcommand is a no-op if already installed (self-heal). The plugin
  calls this from a SessionStart hook via `install-daemon.sh ensure` → registered
  once on the first session after install, after which the daemon runs
  autonomously, independent of Claude Code. macOS is live-verified (exit 0); the
  **Linux branch is a standard pattern but unverified on this machine**. Log:
  `~/.toolytics/scheduler.log`.
- **Permission gates & the daemon as the bypass**: Claude Code gates plugins that
  shell out — a Bash-tool prompt for `/toolytics` (matched on the command string,
  not the caller; can't be auto-granted — the harness blocks even programmatic
  allowlisting), and a one-time hook-trust prompt for the SessionStart hook. The
  daemon makes both irrelevant for normal use: once installed it runs `build.sh`
  via the OS scheduler **outside Claude Code** (no prompt ever) and rebuilds
  `dashboard.html` daily, so the everyday path is "open the static file" — zero
  Claude involvement. `/toolytics` (gated bash) is only an on-demand rebuild;
  document the one-time `Bash(bash *toolytics*build.sh*)` allowlist for those who
  want it silent. The hook is decline-safe (`|| true`, fail-open) with a manual
  `install-daemon.sh install` fallback. So the gates are surfaced-and-bypassed by
  design, not hacked around.
- **Rescan time**: full cold scan ~3s (currently ~1700 files). Per the ponytail
  comment, switch to mtime-incremental if it gets slow.
- **Skill roster**: disk inventory (`~/.claude/skills` + `plugins`) ∪ every skill
  ever used in the full history → zero-count skills always show (`DATA.skill_inv`).
  Pinned client-side as `SKILL_UNIVERSE`; only the counts react to the filter
  window. user/plugin toggle (presence of a colon; a bare name prefers user).
- **Tokens·cost** (`DATA.tokens`, `tokens.csv`): per-line `message.usage`
  (input/output/cache_read/cache_creation 5m·1h) aggregated by
  `(date,by,project,model)`. Models are normalized (`claude-opus-4-8`→`opus-4-8`,
  etc.). Cost = tokens × list price (input/output + cache read 0.1× / cache write
  5m 1.25× · 1h 2×). **The price table is baked into the `PRICE` dict in
  `build.sh` (as of 2026-06) — when Anthropic changes prices, fix the one line
  there** (a ponytail calibration knob). Unregistered models (`<synthetic>`, etc.)
  cost 0 but their tokens still show. `build.sh` echoes the estimated total API
  value after accumulating. (The dashboard Spend section was removed — token
  collection · `tokens.csv` · cost aggregation are kept.)
- **Auto-injection, measured** (`DATA.injects`): counts only transcript
  `attachment.type=hook_success` + `hookEvent=SessionStart` (superpowers also
  emits a duplicate `hook_additional_context`, which is skipped → one row per
  firing). Empty-output hooks aren't logged at all, so things that don't actually
  run (like security-guidance) are auto-excluded. → Pinned at the top of Skills
  (self-scaling).
  - **Attribution is the heart of portability**: the logged `command` is recorded
    with `${CLAUDE_PLUGIN_ROOT}` **unexpanded**, and if a hook has a
    `statusMessage` that string is logged instead of the command — neither carries
    the plugin name. So **no hardcoding**: every build reverse-maps from disk —
    scan `~/.claude/plugins/**/hooks.json` (plugin name = path) +
    `~/.claude/settings*.json` (SessionStart hooks' command·statusMessage) to build
    a `{logged command string → label}` map, **exact-match** the logged command,
    and fall back to a cleaned form on a miss. → self-configuring for any plugin in
    anyone's environment (verified: superpowers/watch/ponytail/karpathy-skills all
    resolve cleanly). The `inject`/`status` distinction isn't portable, so it was
    dropped (everything is `inject`).
  - injects now accumulate into `injects.csv` with the **same date-replace strategy
    as history.csv** → past injects survive log rotation.
- **Meaning of scanned_dates**: "if disk has even one line for that date," the scan
  is authoritative for it (= all three tables tool/token/inject get that date's
  rows replaced wholesale). It used to be wrongly gated on "days with assistant
  content" → past history for days with zero tool_use could be silently wiped
  (fixed). Every line with a timestamp does `scanned_dates.add(d)`.
- **self-check**: `./build.sh --selfcheck` — asserts the replace-by-date merge
  (idempotent · preserves rotated dates · clears covered-but-empty dates) and the
  inject reverse-mapping (exact-match on command·statusMessage), 5 assertions. A
  regression guard for the non-trivial logic.
- **Project labels**: default is the home-relative path (`hsc/rain/foo`). The
  personal hardcoded convention (`hsc/` trim) was removed → safe to distribute. To
  shorten, use only the `TOOLYTICS_TRIM="hsc,work"` env (comma-separated leading
  segments). That also resolves any collision worries.
- **Remaining unfixed (low-impact, deliberately deferred)**: skill leaf-basename
  collision (same-named user/plugin counts get merged) — rare and fiddly to fix
  well, so deferred.
- **Dashboard UI**: 20-per-page pagination on every section (pad to 20 rows only
  when multi-page), heat-ramp bars, **never** `text-transform:uppercase` (preserve
  original case — [[feedback_no_forced_case]]).
- **Dashboard filters**: triggered_by (All/Direct/Delegated) · project · date range
  (native date input) · tool search. All re-aggregated client-side in JS.
  Heat-ramp bars (bigger value → hotter orange).
- Artifact URL: https://claude.ai/code/artifact/f680d4ec-5c2c-4590-8ee5-6fb5af7cd0fa

## Artifacts
- `build.sh` — scan→accumulate→build→open pipeline (reusable).
- `dashboard.template.html` — dashboard template (data slot empty, the source).
- `install-daemon.sh` — per-OS daily collector scheduler installer (macOS launchd /
  Linux systemd·cron, generated dynamically, idempotent; `install` | `ensure` |
  `--remove`).
- `.claude-plugin/plugin.json` — the `toolytics` plugin manifest.
- `.claude-plugin/marketplace.json` — marketplace for local install (this repo is
  itself the plugin, `source: "./"`). Install:
  `/plugin marketplace add <repo-path>` → `toolytics@toolytics`.
- `hooks/hooks.json` — SessionStart self-install guard (calls `install-daemon.sh
  ensure` → auto-registers the daemon).
- (generated, `~/.toolytics/`) `history.csv` — tool cumulative DB
  (date,triggered_by,project,tool,count)
- (generated, `~/.toolytics/`) `tokens.csv` — token cumulative DB
  (date,triggered_by,project,model,input,output,cache_read,cw5m,cw1h)
- (generated, `~/.toolytics/`) `injects.csv` — auto-injection cumulative DB
  (date,triggered_by,project,source,count)
- (generated, `~/.toolytics/`) `dashboard.html` — self-contained dashboard with
  data inlined
- (generated, `~/.toolytics/`) `scheduler.log` — daily collector daemon run log
