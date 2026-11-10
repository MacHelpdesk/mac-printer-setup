#!/bin/bash
# check-privacy — fail when a tracked file contains details of someone's environment.
#
# This repo is public and its tools print addresses, network names and device ids.
# None of that belongs in the repo. Examples use RFC 5737 addresses
# (192.0.2.x, 198.51.100.x, 203.0.113.x) and placeholder queue names.
#
# Checked, and only these:
#   1. a full IPv4 address in a private range (10/8, 172.16/12, 192.168/16, 169.254/16)
#   2. an absolute home path (/Users/<name>/ or /home/<name>/)
#
# Usage: scripts/check-privacy.sh        (from the repo root)

set -u

cd "$(dirname "$0")/.." || exit 2

PRIVATE_IP='(^|[^0-9.])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|169\.254\.[0-9]{1,3}\.[0-9]{1,3})([^0-9]|$)'
HOME_PATH='/(Users|home)/[A-Za-z0-9._-]+/'

found=0
report() { # label pattern
  local hits
  hits="$(git grep -n -I -E "$2" -- . ':(exclude)scripts/check-privacy.sh' 2>/dev/null)"
  if [ -n "$hits" ]; then
    printf '%s:\n%s\n\n' "$1" "$hits"
    found=1
  fi
}

report "private IPv4 address" "$PRIVATE_IP"
report "absolute home path" "$HOME_PATH"

if [ "$found" -eq 0 ]; then
  echo "privacy check passed"
else
  echo "privacy check failed: replace the values above with RFC 5737 addresses or placeholders" >&2
fi
exit "$found"
