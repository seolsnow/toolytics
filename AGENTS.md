# toolytics — Claude Code + Codex usage dashboard

## Purpose
Aggregate tool usage from my Claude Code and Codex session transcripts into a
filterable dashboard. (All projects combined, last N days.)

## How it works / context
- **Data sources**: `~/.claude/projects/**/*.jsonl` and
  `~/.codex/sessions/**/*.jsonl` (both fully recursive). The per-line
  `timestamp` field drives the window filter.
- **Two layers** — the key distinction:
  - `main` = calls I made directly in the main session.
  - `agent` = calls a subagent/workflow I spawned made on my behalf. Claude
    identifies these by `/subagents/` in the path; Codex identifies a session by
    `thread_source: subagent` or `source.subagent` metadata.
- **Tidy table schema**: `date, runtime(claude|codex), triggered_by(main|agent), project, tool, count`.
  Skill calls go into `tool` as `skill:<name>`; MCP keeps the raw
  `mcp__server__method` form.
- **Skill invocation has two transcript shapes, both counted under `skill:<name>`**:
  model-invoked = a `Skill` tool_use block; user-typed `/slash` skill-command =
  a string-content `<command-name>` user message with **no** tool_use. The two
  are mutually exclusive per action (a `/slash` invoke emits no `Skill` call), so
  counting both can't double-count, and reusing the `skill:` label merges them.
  Only `<command-name>`s whose leaf is a real on-disk skill are counted —
  builtins (`/clear`, `/model`, `/plugin`, `/reload-skills`…) are ignored, so
  generic slash commands stay out (intentional: they're session noise, not tool
  use). This is why `skill_inv` is built *before* the scan loop (the leaf set is
  the match table). Codex skills load natively and leave no `/slash` marker → not
  applicable there.
- **Reproduce/build**: `./build.sh [VIEW_DAYS]` (default 30) → full scan →
  refresh cumulative DBs → build dashboard → auto-open browser.
  - Output location: `~/.toolytics/` (change via env `TOOLYTICS_HOME`).
    `history.csv` (cumulative DB) + `dashboard.html` (self-contained, data inlined).
  - For tests, skip the browser open with `TOOLYTICS_OPEN=0`.
  - The dashboard template is `dashboard.template.html` in this folder; JSON is
    injected at the `/*__DATA__*/` slot.
- **Incremental scan (`scan-state.json`)**: the scan is per-file cached, not a full
  reparse each run. Each transcript's per-file aggregate (tool rows, inject rows,
  covered groups) is keyed by `(size, mtime_ns)` in `~/.toolytics/scan-state.json`;
  unchanged files are reused without parsing, **but their cached counts still feed
  the run-level aggregate** — so replace-by-group never drops an unchanged sibling's
  rows when another file in the same group changes (the bug a naive
  changed-files-only scan would have). It's a perf cache, not a source of truth:
  delete it and the next run full-scans and rebuilds it. A signature
  (`cache_version` + `TOOLYTICS_TRIM` + Claude label map + skill-leaf set +
  inject-attribution maps) invalidates the whole cache when label/classification
  inputs change. Written temp+rename only after the CSVs and dashboard succeed
  (atomic). Malformed matching entries are ignored per-file and rebuilt.
- **Cumulative strategy (core)**: the scan covers every jsonl on disk with no time
  window. `history.csv` is merged by **replace-by-covered-group**
  (`date,runtime,triggered_by,project`); the Claude-only `injects.csv`
  uses its equivalent Claude group. Covered rows get replaced
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
  `ensure` subcommand is a no-op if already installed (self-heal). The Claude
  Code and Codex plugins call this from a trusted SessionStart hook via
  `install-daemon.sh ensure` → registered once on the first session after
  install, after which the daemon runs autonomously. Codex discovers the shared
  root-level `hooks/hooks.json` and supplies `CLAUDE_PLUGIN_ROOT` compatibility;
  the hook definition therefore stays identical across runtimes. A standalone
  (cloned-repo) user registers the daily collector by running
  `install-daemon.sh` themselves once; it is idempotent. Data *collection* needs
  no install — `build.sh` scans both transcript roots regardless of how it was
  invoked. macOS is live-verified (exit 0); the Linux systemd `--user` timer
  path is verified on WSL2. **All three backends write run output to
  `~/.toolytics/scheduler.log`**: launchd via `StandardOutPath`/`StandardErrorPath`,
  cron via `>> "$LOG" 2>&1`, and systemd via `StandardOutput=append:` /
  `StandardError=append:` on the service (without those directives systemd would
  route output to the journal instead, not the log file).
- **Permission prompts & expected UX (configuration-dependent)**: toolytics does
  not alter Claude Code permissions or try to grant itself access. The
  SessionStart hook and the `/toolytics` Bash command can be approved or
  prompted independently by the user's client configuration. Codex hook trust
  is reviewed through `/hooks` and is distinct from normal Bash-command
  approvals. In particular,
  `permissions.defaultMode: "auto"` can run the build without a Bash prompt;
  it does not imply hook trust. When Claude Code does show a prompt, explain
  the local-only behavior and recommend the persisted one-time approval
  (`"Yes, and don't ask again"`). `commands/toolytics.md` mentions that option
  once per conversation only when a prompt actually occurred. The hook stays
  decline-safe (`|| true`, fail-open). The daily OS scheduler runs outside
  Claude Code after it is registered and rebuilds `dashboard.html` daily; a
  bookmark of the static file is a no-wait alternative, not a separate
  onboarding path. Power users can pre-authorize
  `Bash(bash *toolytics*build.sh*)` in settings.
- **Rescan time**: roughly ~2ms/file cold (e.g. ~1700 files ≈ 3s); warm (cache-hit)
  rescan is several× faster since only changed/new files are reparsed (see
  Incremental scan).
- **Skill roster**: disk inventory (`~/.claude/skills` + `plugins` +
  per-project `<cwd>/.claude/skills`) ∪ every skill ever used in the full history →
  zero-count skills always show (`DATA.skill_inv`). Pinned client-side as
  `SKILL_UNIVERSE`; the counts react to the filter window and the universe itself is
  project-filtered (project-local skills hide under a different project — see
  Project-scoped skill visibility below). user/plugin toggle (presence of a colon; a
  bare name prefers user).
- **Scope — tool use only**: toolytics counts *tool calls*, not tokens or cost.
  Token/$-spend tracking was deliberately removed (2026-06) — it's out of scope
  for a tool-usage dashboard. Don't re-add a tokens/price/`API value` section.
- **Auto-injection, measured** (`DATA.injects`; Claude Code only): counts only transcript
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
    a `{logged command string → label}` map, split into high-confidence (plugin
    name derived from a path) and low-confidence (cleaned basename / statusMessage).
    Resolution order per logged command: current-disk high-confidence → **learned
    cache** → current-disk fallback → cleaned basename. → self-configuring for any
    plugin in anyone's environment (verified: superpowers/watch/ponytail/
    karpathy-skills all resolve cleanly). The `inject`/`status` distinction isn't
    portable, so it was dropped (everything is `inject`).
  - **Version-skew problem & the learned cache** (`inject-map.json` in `out`): a
    plugin can rename/delete its SessionStart hook command across versions. Since
    injects.csv stores the label and re-scan replaces it by date, a once-correct
    label would silently degrade to a bare basename (e.g. old superpowers
    `check-setup.sh`) and **freeze there permanently** once the source logs rotate.
    Fix: every build persists the high-confidence command→label resolutions into a
    per-machine cache; when current disk can no longer name a command, the cache
    still can. Monotonic — current disk always wins and refreshes. This is GENERAL
    (any plugin's skew), not a per-plugin patch. For orphans that predate the cache
    (a hook deleted before toolytics ever scanned it), the opt-in
    `TOOLYTICS_INJECT_ALIAS="check-setup.sh=superpowers,…"` relabels them **and seeds
    the cache** — one run with the env fixes it permanently (the daemon then keeps it
    without the env). Empty by default → portable, nothing baked into the distro.
  - injects now accumulate into `injects.csv` with the **same date-replace strategy
    as history.csv** → past injects survive log rotation.
- **Meaning of covered groups**: any timestamped line makes its source/runtime,
  trigger layer, project, and date authoritative. That group gets replaced
  wholesale, but another runtime or project on the same date is preserved.
- **self-check**: `./build.sh --selfcheck` — asserts merge behavior,
  legacy Claude-history migration, Codex main/subagent attribution and both
  Codex call payload types, the inject reverse-mapping
  (idempotent · preserves rotated dates · clears covered-but-empty dates), the
  inject reverse-mapping (exact-match on command·statusMessage), the learned
  cache (no regression to a basename after disk skew) + opt-in alias seeding,
  the `/slash` skill-command capture (a string-content `<command-name>` mapping
  to a disk skill becomes a `skill:` row; a builtin like `/clear` is ignored),
  the **incremental scan** (two files in one group; appending to one keeps the
  unchanged sibling's cached count → 2,2,3; Claude label changes invalidate stale
  cached labels; malformed cache entries are rebuilt),
  and that all three plugin manifests agree on `version`. A regression guard for
  the non-trivial logic.
- **Project labels**: default is the home-relative path (`hsc/rain/foo`). The
  personal hardcoded convention (`hsc/` trim) was removed → safe to distribute. To
  shorten, use only the `TOOLYTICS_TRIM="hsc,work"` env (comma-separated leading
  segments). That also resolves any collision worries.
- **Remaining unfixed (low-impact, deliberately deferred)**: skill leaf-basename
  collision (same-named user/plugin counts get merged) — rare and fiddly to fix
  well, so deferred.
- **Project-scoped skill visibility (done)**: `skill_inv` is now `[leaf, origin,
  label, project]`. Global skills (`~/.claude/skills` + plugins) carry
  `project=None`; project-local skills (`<cwd>/.claude/skills`, scanned per project
  via the `proj_cwds` map built in the labels loop) are tagged with their owning
  project. The dashboard project-filters the skill **universe** (not just the
  counts): `inf.project==null || S.projs.has(inf.project)`. → a never-invoked
  project-local skill shows (count 0) under its own project, and a skill scoped to
  another project is hidden when you filter elsewhere. Leaf-collision still defers
  to global (a project-local skill sharing a global name is skipped).
- **Dashboard UI**: 20-per-page pagination on every section (pad to 20 rows only
  when multi-page); pinned rows (Skills' inject pins + divider) render above the
  slice and **don't count toward the page budget**, so page 1 shows a full 20
  ranked rows (was showing 20-minus-pins). heat-ramp bars, **never**
  `text-transform:uppercase` (preserve original case — [[feedback_no_forced_case]]).
- **Dashboard filters**: runtime (All/Claude/Codex) · triggered_by
  (All/Main/Subagent) · project · date range (native date input) · tool search.
  All tool rows re-aggregate client-side in JS.
  Heat-ramp bars (bigger value → hotter orange).
- Artifact URL: https://claude.ai/code/artifact/f680d4ec-5c2c-4590-8ee5-6fb5af7cd0fa

## TODO / backlog

**Open**
- None.

**Done (recent)**
- Codex hook verified in a fresh CLI thread: `/hooks` shows `SessionStart`
  with `5` installed / `5` active hooks, and the detailed SessionStart list
  includes `Plugin - toolytics@toolytics` running
  `toolytics/0.2.0/install-daemon.sh ensure`; trust status is `Trusted`.
- Codex plugin reinstalled after the 0.2.0 bump: `codex plugin marketplace add .`
  repaired a stale marketplace source from the deleted
  `.worktrees/codex-plugin-packaging` path to this repo, and
  `codex plugin add toolytics@toolytics` installed/enabled 0.2.0. Verified with
  `codex plugin list` and a non-opening installed-cache build.
- Public Codex install: `.agents/plugins/marketplace.json` switched from a local
  `./` source to a GitHub URL source (`{source:"url", url:…/toolytics.git,
  ref:"main"}`, ponytail-style) → installable without a clone (needs the repo
  pushed to GitHub `main`).
- Project-scoped skill visibility (see the bullet above) — `skill_inv` 4th field +
  project-filtered universe; `--selfcheck` guards the tagging and the filter.
- `/slash` skill-command capture — user-typed `/skill` invocations (no `Skill`
  tool_use) now counted under `skill:<name>`; builtins ignored; `--selfcheck` guard.
- Token / cost / "API value" tracking **removed** — out of scope for a tool-use
  dashboard (build.sh, template, tokens.csv, docs, self-check all stripped).
- Distribution study (ponytail + superpowers) → produced the items above.
- Version-bump automation: `bump-version.sh` + a `--selfcheck` version-agree assert.
- Codex hooks declared explicitly; Claude marketplace `$schema` added.
- Direct/Delegated → **Main / Subagent**. Filter tool → Skills (already worked).

(Older, still-open idea lives in its own bullet above: skill leaf-basename
collision.)

## Artifacts
- `build.sh` — scan→accumulate→build→open pipeline (reusable).
- `dashboard.template.html` — dashboard template (data slot empty, the source).
- `install-daemon.sh` — per-OS daily collector scheduler installer (macOS launchd /
  Linux systemd·cron, generated dynamically, idempotent; `install` | `ensure` |
  `--remove`).
- `bump-version.sh` — sets the version in all three manifests at once
  (`./bump-version.sh X.Y.Z`); `build.sh --selfcheck` asserts they stay in sync.
- `.claude-plugin/plugin.json` — the `toolytics` plugin manifest.
- `.claude-plugin/marketplace.json` — marketplace for local install (this repo is
  itself the plugin, `source: "./"`; carries `$schema` for editor validation).
  Install: `/plugin marketplace add <repo-path>` → `toolytics@toolytics`.
- `.codex-plugin/plugin.json` — Codex plugin manifest; declares `"hooks":
  "./hooks/hooks.json"` explicitly (matches ponytail/superpowers) so the
  SessionStart hook is wired without relying on auto-discovery.
- `.agents/plugins/marketplace.json` — repository-scoped Codex marketplace; uses a
  GitHub URL source (`https://github.com/seolsnow/toolytics.git`, ref `main`) so it
  installs without a clone (requires the repo pushed to `main`).
- `skills/toolytics/SKILL.md` — Codex dashboard workflow.
- `hooks/hooks.json` — shared Claude Code and Codex SessionStart self-install
  guard. Codex requires explicit hook trust through `/hooks`.
- (generated, `~/.toolytics/`) `history.csv` — tool cumulative DB
  (date,runtime,triggered_by,project,tool,count)
- (generated, `~/.toolytics/`) `injects.csv` — auto-injection cumulative DB
  (date,triggered_by,project,source,count)
- (generated, `~/.toolytics/`) `inject-map.json` — learned command→label attribution
  cache (monotonic; survives plugin hook version skew)
- (generated, `~/.toolytics/`) `scan-state.json` — per-file aggregate scan cache
  (perf only; safe to delete → next run full-scans and rebuilds it)
- (generated, `~/.toolytics/`) `dashboard.html` — self-contained dashboard with
  data inlined
- (generated, `~/.toolytics/`) `scheduler.log` — daily collector daemon run log
