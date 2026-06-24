# Codex Plugin Packaging Design

## Goal

Package toolytics as a personal Codex plugin with a `toolytics` skill. The
skill must provide the same practical collector setup as the Claude plugin:
before building the dashboard, it idempotently ensures the daily collector is
registered.

## Constraints

- Codex plugin validation rejects Claude-style `hooks`; the package must not
  declare one.
- The existing repository remains the single source of `build.sh`,
  `install-daemon.sh`, and dashboard assets. Do not duplicate or relocate it.
- Codex's personal marketplace resolves `./plugins/toolytics` under
  `~/.agents/plugins/` to `~/plugins/toolytics`.
- The user already owns this local clone, so a symlink can expose it to the
  personal marketplace without a copied checkout.

## Distribution Layout

The repository gains:

```
.codex-plugin/plugin.json
skills/toolytics/SKILL.md
```

The plugin manifest declares the skill directory and normal presentation
metadata. It deliberately omits hooks, MCP servers, apps, and visual assets.

At installation time, create or refresh this symlink:

```
~/plugins/toolytics -> <repository root>
```

Then add `toolytics` to `~/.agents/plugins/marketplace.json` with the standard
local source path `./plugins/toolytics`, availability `AVAILABLE`,
authentication `ON_INSTALL`, and category `Productivity`. Codex installs it
with `codex plugin add toolytics@personal`.

## Skill Behavior

The `toolytics` skill is used for requests to build or open the tool-usage
dashboard, optionally with a requested day window.

For every invocation it runs, in order:

1. `bash <plugin-root>/install-daemon.sh ensure`
2. `bash <plugin-root>/build.sh [VIEW_DAYS]`

`ensure` is idempotent. It performs the same daily-collector registration
that the Claude SessionStart hook performs, but at the first Codex dashboard
request because Codex does not provide a compatible lifecycle hook.

The skill reports the dashboard location and whether the browser opened. It
also tells the user how to suppress browser opening for automated use.

## Documentation and Verification

README documents the personal marketplace install, the symlink, and the
requirement to start a new Codex thread after installation or reinstall.

Verification covers:

- plugin manifest validation;
- skill frontmatter validation;
- `./build.sh --selfcheck`;
- a no-browser build into a temporary `TOOLYTICS_HOME`;
- a read-only inspection that the personal marketplace resolves through the
  expected symlink before invoking Codex installation.

## Non-Goals

- No automatic install-time Codex hook: the manifest does not support it.
- No copied plugin source, second repository, MCP server, app, or UI assets.
- No changes to Claude's existing plugin or marketplace flow.
