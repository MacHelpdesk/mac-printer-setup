#!/bin/bash
# Tests for plugin/scripts/printer-autoswitch.sh
#
# The real nc / lpstat / lpadmin / lpoptions are replaced by stubs on PATH, so the
# tests never touch CUPS or the network. Addresses are from 192.0.2.0/24 (RFC 5737).
#
# Usage: bash tests/test_autoswitch.sh   (from the repo root)

set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/plugin/scripts/printer-autoswitch.sh"

pass=0
fail=0

ok()   { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

assert_eq() { # name expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}

setup() {
  T="$(mktemp -d)"
  export STUB_STATE="$T/state"
  export HOME="$T/home"
  export MAC_PRINTER_SETUP_CONF="$T/printers.conf"
  export MAC_PRINTER_SETUP_LOG="$T/autoswitch.log"
  export STUB_LANG=en
  mkdir -p "$STUB_STATE" "$HOME" "$T/bin"
  : > "$STUB_STATE/reachable"
  : > "$STUB_STATE/calls"
  printf 'HOME_Q\nOFFICE_Q\nOTHER_Q\n' > "$STUB_STATE/queues"

  cat > "$T/bin/lpstat" <<'EOF'
#!/bin/bash
case "$1" in
  -d)
    n="$(cat "$STUB_STATE/system_default" 2>/dev/null)"
    # the real lpstat -d reports the user layer first; only HOME=/var/empty shows the system layer
    if [ "$HOME" != /var/empty ] && [ -f "$HOME/.cups/lpoptions" ]; then
      n="$(sed -nE 's/^Default[[:space:]]+([^[:space:]]+).*/\1/p' "$HOME/.cups/lpoptions" | head -1)"
    fi
    if [ -z "$n" ]; then
      if [ "$STUB_LANG" = zh ]; then echo "沒有系統預設目標"; else echo "no system default destination"; fi
    elif [ "$STUB_LANG" = zh ]; then echo "系統預設目標：$n"
    else echo "system default destination: $n"
    fi ;;
  -p) grep -qx -- "$2" "$STUB_STATE/queues" ;;
esac
EOF
  cat > "$T/bin/lpadmin" <<'EOF'
#!/bin/bash
echo "lpadmin $*" >> "$STUB_STATE/calls"
[ -e "$STUB_STATE/lpadmin_fails" ] && exit 1
[ "$1" = "-d" ] && echo "$2" > "$STUB_STATE/system_default"
exit 0
EOF
  cat > "$T/bin/lpoptions" <<'EOF'
#!/bin/bash
echo "lpoptions $*" >> "$STUB_STATE/calls"
[ -e "$STUB_STATE/lpoptions_fails" ] && exit 1
if [ "$1" = "-d" ]; then mkdir -p "$HOME/.cups"; echo "Default $2" > "$HOME/.cups/lpoptions"; fi
exit 0
EOF
  cat > "$T/bin/nc" <<'EOF'
#!/bin/bash
# nc -z -G <timeout> <host> <port>
grep -qx -- "$4 $5" "$STUB_STATE/reachable"
EOF
  chmod +x "$T/bin/"*
  OLD_PATH="$PATH"
  export PATH="$T/bin:/usr/bin:/bin"
}

teardown() { export PATH="$OLD_PATH"; rm -rf "$T"; }

run() { bash "$SCRIPT" --now >/dev/null 2>&1; echo $?; }
# the path launchd takes: no --now, so the settle delay applies (shortened to 0 here)
run_as_agent() { MAC_PRINTER_SETUP_SETTLE=0 bash "$SCRIPT" >"$T/agent.out" 2>&1; echo $?; }

sys_default()  { cat "$STUB_STATE/system_default" 2>/dev/null; }
user_default() { sed -nE 's/^Default[[:space:]]+([^[:space:]]+).*/\1/p' "$HOME/.cups/lpoptions" 2>/dev/null; }
set_user()     { mkdir -p "$HOME/.cups"; echo "Default $1" > "$HOME/.cups/lpoptions"; }
conf_two()     { printf '# home first\nHOME_Q 192.0.2.10 631\n\nOFFICE_Q 192.0.2.20\n' > "$MAC_PRINTER_SETUP_CONF"; }
log_lines()    { [ -f "$MAC_PRINTER_SETUP_LOG" ] && wc -l < "$MAC_PRINTER_SETUP_LOG" | tr -d ' ' || echo 0; }

# 1. first printer reachable, both layers wrong -> both layers set to the first printer
setup; conf_two
echo "192.0.2.10 631" > "$STUB_STATE/reachable"
echo OTHER_Q > "$STUB_STATE/system_default"; set_user OTHER_Q
rc=$(run)
assert_eq "1 exit code" 0 "$rc"
assert_eq "1 system layer -> first printer" HOME_Q "$(sys_default)"
assert_eq "1 user layer -> first printer" HOME_Q "$(user_default)"
teardown

# 2. first unreachable, second reachable (default port 631) -> second printer
setup; conf_two
echo "192.0.2.20 631" > "$STUB_STATE/reachable"
echo HOME_Q > "$STUB_STATE/system_default"; set_user HOME_Q
rc=$(run)
assert_eq "2 exit code" 0 "$rc"
assert_eq "2 system layer -> second printer" OFFICE_Q "$(sys_default)"
assert_eq "2 user layer -> second printer" OFFICE_Q "$(user_default)"
teardown

# 3. nothing reachable -> defaults untouched
setup; conf_two
echo OTHER_Q > "$STUB_STATE/system_default"; set_user OTHER_Q
rc=$(run)
assert_eq "3 exit code" 0 "$rc"
assert_eq "3 system layer untouched" OTHER_Q "$(sys_default)"
assert_eq "3 user layer untouched" OTHER_Q "$(user_default)"
assert_eq "3 no lpadmin call" "" "$(cat "$STUB_STATE/calls")"
teardown

# 4. user layer already right but system layer wrong (lpstat -d alone would hide it) -> fixed
setup; conf_two
echo "192.0.2.10 631" > "$STUB_STATE/reachable"
echo OFFICE_Q > "$STUB_STATE/system_default"; set_user HOME_Q
rc=$(run)
assert_eq "4 system layer fixed" HOME_Q "$(sys_default)"
assert_eq "4 user layer stays" HOME_Q "$(user_default)"
teardown

# 5. already correct -> no calls, no log line
setup; conf_two
echo "192.0.2.10 631" > "$STUB_STATE/reachable"
echo HOME_Q > "$STUB_STATE/system_default"; set_user HOME_Q
rc=$(run)
assert_eq "5 exit code" 0 "$rc"
assert_eq "5 no calls when already correct" "" "$(cat "$STUB_STATE/calls")"
assert_eq "5 no log line when already correct" 0 "$(log_lines)"
teardown

# 6. no user layer on this machine -> only the system layer is set, no lpoptions file created
setup; conf_two
echo "192.0.2.10 631" > "$STUB_STATE/reachable"
echo OTHER_Q > "$STUB_STATE/system_default"
rc=$(run)
assert_eq "6 system layer set" HOME_Q "$(sys_default)"
if [ -e "$HOME/.cups/lpoptions" ]; then bad "6 user layer not created" "lpoptions file was created"; else ok "6 user layer not created"; fi
teardown

# 7. config file missing -> exit 2, nothing changed
setup
echo OTHER_Q > "$STUB_STATE/system_default"
rc=$(run)
assert_eq "7 exit code for missing config" 2 "$rc"
assert_eq "7 system layer untouched" OTHER_Q "$(sys_default)"
teardown

# 8. a queue named in the config does not exist -> skipped, next reachable one is used
setup
printf 'GONE_Q 192.0.2.10\nOFFICE_Q 192.0.2.20 631\n' > "$MAC_PRINTER_SETUP_CONF"
printf '192.0.2.10 631\n192.0.2.20 631\n' > "$STUB_STATE/reachable"
echo OTHER_Q > "$STUB_STATE/system_default"
rc=$(run)
assert_eq "8 missing queue skipped" OFFICE_Q "$(sys_default)"
teardown

# 9. lpstat output in Chinese (macOS follows the system language, LC_ALL=C does not change it)
setup; conf_two; export STUB_LANG=zh
echo "192.0.2.10 631" > "$STUB_STATE/reachable"
echo HOME_Q > "$STUB_STATE/system_default"; set_user HOME_Q
rc=$(run)
assert_eq "9 zh output parsed: no calls when already correct" "" "$(cat "$STUB_STATE/calls")"
echo OFFICE_Q > "$STUB_STATE/system_default"
rc=$(run)
assert_eq "9 zh output parsed: system layer fixed" HOME_Q "$(sys_default)"
teardown

# 10. config with only comments -> exit 2
setup
printf '# nothing here\n\n' > "$MAC_PRINTER_SETUP_CONF"
rc=$(run)
assert_eq "10 exit code for empty config" 2 "$rc"
teardown

# 11. last config line has no trailing newline -> still read
setup
printf '# home\nHOME_Q 192.0.2.10' > "$MAC_PRINTER_SETUP_CONF"
echo "192.0.2.10 631" > "$STUB_STATE/reachable"
echo OTHER_Q > "$STUB_STATE/system_default"
rc=$(run)
assert_eq "11 exit code with unterminated last line" 0 "$rc"
assert_eq "11 unterminated last line is used" HOME_Q "$(sys_default)"
teardown

# 12. inline comment after the fields -> ignored, port stays the default
setup
printf 'HOME_Q 192.0.2.10 # the one at home\n' > "$MAC_PRINTER_SETUP_CONF"
echo "192.0.2.10 631" > "$STUB_STATE/reachable"
echo OTHER_Q > "$STUB_STATE/system_default"
rc=$(run)
assert_eq "12 inline comment ignored" HOME_Q "$(sys_default)"
teardown

# 13. CRLF line endings -> the carriage return is not part of the host or port
setup
printf 'HOME_Q 192.0.2.10\r\nOFFICE_Q 192.0.2.20 631\r\n' > "$MAC_PRINTER_SETUP_CONF"
echo "192.0.2.10 631" > "$STUB_STATE/reachable"
echo OTHER_Q > "$STUB_STATE/system_default"
rc=$(run)
assert_eq "13 CRLF config is read" HOME_Q "$(sys_default)"
teardown

# 14. a port other than 631 is the one that gets probed
setup
printf 'HOME_Q 192.0.2.10 9100\n' > "$MAC_PRINTER_SETUP_CONF"
echo "192.0.2.10 631" > "$STUB_STATE/reachable"
echo OTHER_Q > "$STUB_STATE/system_default"
rc=$(run)
assert_eq "14 only the configured port counts (631 open, 9100 configured)" OTHER_Q "$(sys_default)"
echo "192.0.2.10 9100" > "$STUB_STATE/reachable"
rc=$(run)
assert_eq "14 configured port 9100 reachable" HOME_Q "$(sys_default)"
teardown

# 15. lpadmin fails -> exit 1 and a log line
setup; conf_two
echo "192.0.2.10 631" > "$STUB_STATE/reachable"
echo OTHER_Q > "$STUB_STATE/system_default"
: > "$STUB_STATE/lpadmin_fails"
rc=$(run)
assert_eq "15 exit code when lpadmin fails" 1 "$rc"
assert_eq "15 system layer untouched when lpadmin fails" OTHER_Q "$(sys_default)"
assert_eq "15 failure is logged" 1 "$(log_lines)"
teardown

# 16. lpoptions fails while a user layer exists -> exit 1
setup; conf_two
echo "192.0.2.10 631" > "$STUB_STATE/reachable"
echo OTHER_Q > "$STUB_STATE/system_default"; set_user OTHER_Q
: > "$STUB_STATE/lpoptions_fails"
rc=$(run)
assert_eq "16 exit code when lpoptions fails" 1 "$rc"
teardown

# 17. system layer right, user layer wrong -> user layer fixed
setup; conf_two
echo "192.0.2.10 631" > "$STUB_STATE/reachable"
echo HOME_Q > "$STUB_STATE/system_default"; set_user OTHER_Q
rc=$(run)
assert_eq "17 user layer fixed" HOME_Q "$(user_default)"
assert_eq "17 system layer stays" HOME_Q "$(sys_default)"
teardown

# 18. no system default at all -> set
setup; conf_two
echo "192.0.2.10 631" > "$STUB_STATE/reachable"
rc=$(run)
assert_eq "18 exit code with no default" 0 "$rc"
assert_eq "18 default set from none" HOME_Q "$(sys_default)"
teardown

# 19. a change writes exactly one log line naming both ends
setup; conf_two
echo "192.0.2.10 631" > "$STUB_STATE/reachable"
echo OTHER_Q > "$STUB_STATE/system_default"
rc=$(run)
assert_eq "19 one log line on a change" 1 "$(log_lines)"
if grep -q 'system=OTHER_Q .*-> HOME_Q' "$MAC_PRINTER_SETUP_LOG"; then ok "19 log line names old and new default"; else bad "19 log line names old and new default" "$(cat "$MAC_PRINTER_SETUP_LOG")"; fi
teardown

# 20. the launchd path (no --now): switches, prints nothing
setup; conf_two
echo "192.0.2.10 631" > "$STUB_STATE/reachable"
echo OTHER_Q > "$STUB_STATE/system_default"
rc=$(run_as_agent)
assert_eq "20 exit code on the agent path" 0 "$rc"
assert_eq "20 agent path switches" HOME_Q "$(sys_default)"
assert_eq "20 agent path prints nothing" "" "$(cat "$T/agent.out")"
teardown

# 21. --now reports a failure on stderr, never on stdout as a queue name
setup
printf 'GONE_Q 192.0.2.10\n' > "$MAC_PRINTER_SETUP_CONF"
echo "192.0.2.10 631" > "$STUB_STATE/reachable"
echo OTHER_Q > "$STUB_STATE/system_default"
out="$(bash "$SCRIPT" --now 2>/dev/null)"
assert_eq "21 nothing on stdout" "" "$out"
assert_eq "21 default untouched when the only queue is missing" OTHER_Q "$(sys_default)"
teardown

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
