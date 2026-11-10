#!/bin/bash
# check-version-bump — fail when plugin/ changed against BASE but the version did not.
#
# The marketplace index tracks this repo's main branch, and Claude Code gives users a
# new copy of the plugin only when the version string changes. A change under plugin/
# that keeps the old version would reach new installs under a version number that
# existing users already have.
#
# Usage: scripts/check-version-bump.sh BASE     e.g. origin/main

set -u

BASE="${1:-}"
[ -n "$BASE" ] || { echo "usage: $0 BASE" >&2; exit 64; }

cd "$(dirname "$0")/.." || exit 2
MANIFEST="plugin/.claude-plugin/plugin.json"

version_of() { # git ref, or "" for the working tree
  if [ -n "$1" ]; then
    git show "$1:$MANIFEST" 2>/dev/null
  else
    cat "$MANIFEST"
  fi | python3 -c "import json,sys; print(json.load(sys.stdin).get('version',''))" 2>/dev/null
}

if ! git rev-parse --verify --quiet "$BASE" >/dev/null; then
  echo "base ref not found: $BASE" >&2
  exit 2
fi

if git diff --quiet "$BASE"...HEAD -- plugin/; then
  echo "plugin/ unchanged against $BASE; no version bump needed"
  exit 0
fi

old="$(version_of "$BASE")"
new="$(version_of "")"

if [ -z "$old" ]; then
  echo "no manifest at $BASE; treating $new as the first version"
  exit 0
fi
if [ "$old" = "$new" ]; then
  echo "plugin/ changed against $BASE but the version is still $old" >&2
  echo "bump \"version\" in $MANIFEST and add a CHANGELOG entry" >&2
  exit 1
fi
echo "version bumped: $old -> $new"
