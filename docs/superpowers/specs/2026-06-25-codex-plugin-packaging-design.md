# Codex Plugin Packaging Design

## Goal

Package toolytics as a Codex plugin with a `toolytics` skill and the same
SessionStart collector registration used by the Claude plugin.

## Constraints

- Codex supports plugin lifecycle hooks. A default `hooks/hooks.json` is
  discovered automatically without a `hooks` manifest field.
- The existing repository remains the single source of `build.sh`,
  `install-daemon.sh`, and dashboard assets. Do not duplicate or relocate it.
- The plugin root is this repository. Codex provides `PLUGIN_ROOT` to bundled
  hook commands and also supplies `CLAUDE_PLUGIN_ROOT` for compatibility.
- The marketplace is repository-scoped so installation does not require a
  personal plugin copy or a symlink outside the repository.

## Distribution Layout

The repository gains:

```
.codex-plugin/plugin.json
.agents/plugins/marketplace.json
skills/toolytics/SKILL.md
```

The plugin manifest declares the skill directory and normal presentation
metadata. It deliberately omits MCP servers, apps, and visual assets. The
existing `hooks/hooks.json` is reused as Codex's default plugin hook file.

Add `toolytics` to `.agents/plugins/marketplace.json` with local source path
`./`, availability `AVAILABLE`, authentication `ON_INSTALL`, and category
`Productivity`. The source path resolves to this repository, which is the
plugin root. Users install the repository marketplace, then the plugin:

```sh
codex plugin marketplace add seolsnow/toolytics
codex plugin add toolytics@toolytics
```

## Skill Behavior

`hooks/hooks.json` runs at Codex `SessionStart`, exactly as it does for Claude
Code. Its existing command calls `install-daemon.sh ensure`; Codex supplies the
existing `CLAUDE_PLUGIN_ROOT` compatibility variable, so the hook command does
not need to diverge by runtime. It registers or repairs the daily collector
before ordinary dashboard use.

The `toolytics` skill is used for requests to build or open the tool-usage
dashboard, optionally with a requested day window. It runs only:

```sh
bash <plugin-root>/build.sh [VIEW_DAYS]
```

Codex requires the user to review and trust the bundled hook definition before
it can run. That trust is separate from normal Bash-command approvals.

The skill reports the dashboard location and whether the browser opened. It
also tells the user how to suppress browser opening for automated use.

## Documentation and Verification

README documents the repository marketplace install, Codex hook trust, and the
requirement to start a new Codex thread after installation or reinstall.

Verification covers:

- plugin manifest validation;
- skill frontmatter validation;
- JSON validation of the shared SessionStart hook and its root-relative
  command;
- `./build.sh --selfcheck`;
- a no-browser build into a temporary `TOOLYTICS_HOME`;
- a read-only inspection that the repository marketplace points to the plugin
  root before invoking Codex installation.

## Non-Goals

- No copied plugin source, personal symlink, MCP server, app, or UI assets.
- No changes to Claude's existing plugin or marketplace flow.
