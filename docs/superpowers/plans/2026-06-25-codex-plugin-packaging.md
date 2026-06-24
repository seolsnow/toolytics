# Codex Plugin Packaging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Package toolytics as an installable Codex plugin whose SessionStart hook registers the existing daily collector and whose skill builds the dashboard.

**Architecture:** Keep this repository as the plugin root. Add a Codex manifest, a repository marketplace entry, and one focused skill. Reuse the root-level `hooks/hooks.json`; Codex automatically discovers it and provides the existing `CLAUDE_PLUGIN_ROOT` compatibility variable.

**Tech Stack:** JSON manifests, Markdown skill instructions, Bash, Python standard library validation, Codex CLI.

## Global Constraints

- The plugin is named `toolytics`, and its manifest version is `0.1.6`.
- Keep `hooks/hooks.json` unchanged; it is the shared SessionStart daemon guard.
- Do not create a personal marketplace, symlink, copied plugin source, MCP server, app, or asset.
- `.agents/plugins/marketplace.json` points its local source path at `./`, the repository-root plugin.
- The skill runs only `build.sh`; the trusted SessionStart hook owns `install-daemon.sh ensure`.
- Codex hook trust is separate from normal Bash approvals and must be documented.

---

### Task 1: Add the Codex plugin package

**Files:**
- Create: `.codex-plugin/plugin.json`
- Create: `.agents/plugins/marketplace.json`
- Create: `skills/toolytics/SKILL.md`
- Reuse unchanged: `hooks/hooks.json`

**Interfaces:**
- Consumes: repository-root `build.sh` and the existing SessionStart hook.
- Produces: a marketplace plugin named `toolytics`, an implicitly invokable `toolytics` skill, and a default discovered lifecycle hook.

- [ ] **Step 1: Write and run the failing package-shape check**

```sh
python3 - <<'PY'
import json
from pathlib import Path

root = Path('.')
manifest = json.loads((root / '.codex-plugin/plugin.json').read_text())
marketplace = json.loads((root / '.agents/plugins/marketplace.json').read_text())
skill = (root / 'skills/toolytics/SKILL.md').read_text()
hook = json.loads((root / 'hooks/hooks.json').read_text())

assert manifest['name'] == 'toolytics'
assert manifest['version'] == '0.1.6'
assert manifest['skills'] == './skills/'
assert 'hooks' not in manifest
assert marketplace['plugins'][0]['source'] == {'source': 'local', 'path': './'}
assert skill.startswith('---\nname: toolytics\n')
assert 'install-daemon.sh ensure' not in skill
assert 'install-daemon.sh' in hook['hooks']['SessionStart'][0]['hooks'][0]['command']
PY
```

Expected: `FileNotFoundError` for `.codex-plugin/plugin.json`.

- [ ] **Step 2: Create the Codex manifest**

Create `.codex-plugin/plugin.json` exactly:

```json
{
  "name": "toolytics",
  "version": "0.1.6",
  "description": "Local Claude Code and Codex tool-usage dashboard with a daily collector",
  "author": { "name": "seolsnow" },
  "homepage": "https://github.com/seolsnow/toolytics",
  "repository": "https://github.com/seolsnow/toolytics",
  "license": "MIT",
  "keywords": ["codex", "claude-code", "dashboard", "usage"],
  "skills": "./skills/",
  "interface": {
    "displayName": "toolytics",
    "shortDescription": "Your Claude Code and Codex usage dashboard",
    "longDescription": "Build a local dashboard of Claude Code and Codex tool usage, preserved by a daily collector.",
    "developerName": "seolsnow",
    "category": "Productivity",
    "capabilities": ["Read", "Write"],
    "defaultPrompt": [
      "Open my toolytics dashboard.",
      "Build my tool usage dashboard for the last 7 days."
    ]
  }
}
```

Do not declare a `hooks` manifest field. Codex discovers the root-level default `hooks/hooks.json`.

- [ ] **Step 3: Create the repository marketplace**

Create `.agents/plugins/marketplace.json` exactly. The local `./` source resolves to this repository, which contains the new manifest.

```json
{
  "name": "toolytics",
  "interface": { "displayName": "toolytics" },
  "plugins": [
    {
      "name": "toolytics",
      "source": { "source": "local", "path": "./" },
      "policy": {
        "installation": "AVAILABLE",
        "authentication": "ON_INSTALL"
      },
      "category": "Productivity"
    }
  ]
}
```

- [ ] **Step 4: Create the Codex skill**

Create `skills/toolytics/SKILL.md` exactly. The cache path follows Codex's documented local-plugin cache layout for marketplace `toolytics` and plugin `toolytics`.

````md
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
````

- [ ] **Step 5: Run package validation**

```sh
if python3 -c 'import yaml' >/dev/null 2>&1; then
  python3 /Users/didoo/.codex/skills/.system/plugin-creator/scripts/validate_plugin.py .
  python3 /Users/didoo/.codex/skills/.system/skill-creator/scripts/quick_validate.py skills/toolytics
else
  echo 'PyYAML unavailable; use the standard-library package-shape check below.'
fi
python3 - <<'PY'
import json
from pathlib import Path

root = Path('.')
manifest = json.loads((root / '.codex-plugin/plugin.json').read_text())
marketplace = json.loads((root / '.agents/plugins/marketplace.json').read_text())
skill = (root / 'skills/toolytics/SKILL.md').read_text()
hook = json.loads((root / 'hooks/hooks.json').read_text())

assert manifest['name'] == 'toolytics'
assert manifest['version'] == '0.1.6'
assert manifest['skills'] == './skills/'
assert 'hooks' not in manifest
assert marketplace['plugins'][0]['source'] == {'source': 'local', 'path': './'}
assert skill.startswith('---\nname: toolytics\n')
assert 'install-daemon.sh ensure' not in skill
assert 'install-daemon.sh' in hook['hooks']['SessionStart'][0]['hooks'][0]['command']
PY
```

Expected: all commands exit 0.

- [ ] **Step 6: Commit the package**

```sh
git add .codex-plugin/plugin.json .agents/plugins/marketplace.json skills/toolytics/SKILL.md
git commit -m "feat: package toolytics for Codex"
```

### Task 2: Document Codex installation and shared hook behavior

**Files:**
- Modify: `README.md:30-102`
- Modify: `AGENTS.md:35-74,153-165`

**Interfaces:**
- Consumes: Task 1's marketplace, plugin, skill, and existing hook.
- Produces: accurate standalone, Claude Code, and Codex installation and trust instructions.

- [ ] **Step 1: Update README**

Replace the claim that Codex has no plugin/SessionStart hook. Keep the standalone section for manual installs, then add this section before the Claude Code plugin section:

````md
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
````

Change the overview copy to say either the Claude Code or Codex plugin auto-registers the daemon. In the permissions section, add that Codex hook trust is reviewed through `/hooks` and is distinct from normal Bash approvals.

- [ ] **Step 2: Update AGENTS.md**

Replace the Claude-Code-only daemon statement with:

```md
The Claude Code and Codex plugins call this from a trusted SessionStart hook
via `install-daemon.sh ensure` → registered once on the first session after
install, after which the daemon runs autonomously. Codex discovers the shared
root-level `hooks/hooks.json` and supplies `CLAUDE_PLUGIN_ROOT` compatibility;
the hook definition therefore stays identical across runtimes. A standalone
(cloned-repo) user registers the daily collector by running
`install-daemon.sh` themselves once; it is idempotent.
```

Add the following artifacts and replace the existing Claude-only hook note:

```md
- `.codex-plugin/plugin.json` — Codex plugin manifest.
- `.agents/plugins/marketplace.json` — repository-scoped Codex marketplace;
  its `./` local source is this repository's plugin root.
- `skills/toolytics/SKILL.md` — Codex dashboard workflow.
- `hooks/hooks.json` — shared Claude Code and Codex SessionStart self-install
  guard. Codex requires explicit hook trust through `/hooks`.
```

- [ ] **Step 3: Verify documentation and commit**

```sh
if rg -n 'Codex has no|Claude-Code-only|personal marketplace|symlink' README.md AGENTS.md docs/superpowers/specs/2026-06-25-codex-plugin-packaging-design.md; then exit 1; fi
git diff --check
git add README.md AGENTS.md
git commit -m "docs: explain Codex plugin install"
```

Expected: the search has no stale Codex packaging claim; the diff check exits 0; the documentation commit succeeds.

### Task 3: Verify and install the package locally

**Files:**
- Verify: `.codex-plugin/plugin.json`, `.agents/plugins/marketplace.json`, `skills/toolytics/SKILL.md`, and unchanged `hooks/hooks.json`

**Interfaces:**
- Consumes: committed package files and the current local Codex profile.
- Produces: locally installed `toolytics@toolytics` with a SessionStart hook available for trust review.

- [ ] **Step 1: Run offline regression checks**

```sh
./build.sh --selfcheck
tmp=$(mktemp -d)
TOOLYTICS_HOME="$tmp" TOOLYTICS_OPEN=0 ./build.sh 30
test -s "$tmp/history.csv"
test -s "$tmp/dashboard.html"
git diff --check HEAD
```

Expected: self-check prints `selfcheck OK`; both artifacts exist; diff check exits 0.

- [ ] **Step 2: Register and install the local marketplace**

Obtain approval immediately before running these commands because they write to the user's Codex configuration and plugin cache:

```sh
codex plugin marketplace add .
codex plugin add toolytics@toolytics
```

Expected: both commands succeed. Do not retry a failed installation automatically.

- [ ] **Step 3: Confirm hook discovery and final state**

```sh
codex plugin list
git status --short
git log -2 --oneline
```

Start a new Codex thread and use `/hooks`. Trust the toolytics SessionStart hook only when its command still calls `install-daemon.sh ensure` and its status message is `Ensuring toolytics daily collector...`.

Expected: toolytics appears in the plugin list, its hook is listed for review, and the worktree contains no unintended changes.
