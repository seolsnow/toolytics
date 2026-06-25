#!/usr/bin/env bash
# Bump the toolytics version across every plugin manifest in one shot, so the
# Claude plugin, Claude marketplace, and Codex plugin can't drift apart.
# (build.sh --selfcheck asserts they agree.)
#   Usage: ./bump-version.sh X.Y.Z
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
NEW="${1:-}"
[[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: $0 X.Y.Z" >&2; exit 1; }

# each manifest carries exactly one "version" field, so a per-file replace is safe.
FILES=(.claude-plugin/plugin.json .claude-plugin/marketplace.json .codex-plugin/plugin.json)
OLD=$(perl -ne 'if (/"version":\s*"([^"]+)"/) { print $1; exit }' "$SRC/.claude-plugin/plugin.json")
for f in "${FILES[@]}"; do
  perl -i -pe 's/("version":\s*")[^"]+(")/${1}'"$NEW"'${2}/' "$SRC/$f"
done
echo "bumped ${OLD:-?} -> $NEW in: ${FILES[*]}"
