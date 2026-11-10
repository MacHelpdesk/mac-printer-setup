#!/bin/bash
# Tests for plugin/scripts/install-autoswitch.sh
#
# Only the paths that stop before launchd is touched: init-config, and install refusing a
# config with no usable printer line. HOME points at a temp directory, so nothing in the
# real home is read or written. Loading the agent is not tested here.
#
# Usage: bash tests/test_install.sh   (from the repo root)

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/plugin/scripts/install-autoswitch.sh"

pass=0
fail=0

ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }

setup() {
  T="$(mktemp -d)"
  REAL_HOME="$HOME"
  export HOME="$T/home"
  mkdir -p "$HOME"
  CONF="$HOME/.config/mac-printer-setup/printers.conf"
}
teardown() { export HOME="$REAL_HOME"; rm -rf "$T"; }

install_rc() { bash "$SCRIPT" install >/dev/null 2>&1; echo $?; }
agent_file_count() { ls "$HOME/Library/LaunchAgents" 2>/dev/null | wc -l | tr -d ' '; }
write_conf() { mkdir -p "$(dirname "$CONF")"; printf "$1" > "$CONF"; }

# 1. no config -> install refuses with 2 and writes no agent
setup
assert_eq "1 install without a config" 2 "$(install_rc)"
assert_eq "1 no agent file written" 0 "$(agent_file_count)"
teardown

# 2. init-config writes a template that has no usable line -> install still refuses
setup
bash "$SCRIPT" init-config >/dev/null 2>&1
if [ -s "$CONF" ]; then ok "2 init-config writes the template"; else bad "2 init-config writes the template" "missing or empty"; fi
assert_eq "2 install with the untouched template" 2 "$(install_rc)"
teardown

# 3. init-config never overwrites an existing config
setup
write_conf 'Home_Printer 192.0.2.10\n'
bash "$SCRIPT" init-config >/dev/null 2>&1
assert_eq "3 existing config kept" "Home_Printer 192.0.2.10" "$(cat "$CONF")"
teardown

# 4. lines the switch script would not use -> install refuses
#    (a queue with only a comment after it, a queue with no host, comments, blank lines)
setup
write_conf 'Home_Printer # at home\n'
assert_eq "4 queue followed only by a comment" 2 "$(install_rc)"
write_conf 'Home_Printer\n'
assert_eq "4 queue without a host" 2 "$(install_rc)"
write_conf '# Home_Printer 192.0.2.10\n\n   \n'
assert_eq "4 only comments and blank lines" 2 "$(install_rc)"
assert_eq "4 no agent file written" 0 "$(agent_file_count)"
teardown

# 5. unknown subcommand -> usage, exit 64
setup
bash "$SCRIPT" nonsense >/dev/null 2>&1
assert_eq "5 unknown subcommand" 64 "$?"
teardown

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
