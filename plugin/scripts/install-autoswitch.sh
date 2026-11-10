#!/bin/bash
# install-autoswitch — install, remove or inspect the launchd agent that runs
# printer-autoswitch.sh.
#
#   install-autoswitch.sh init-config   write a commented template config (never overwrites)
#   install-autoswitch.sh install       copy the script out of the plugin, write the agent, load it
#   install-autoswitch.sh status        agent state and the last log lines
#   install-autoswitch.sh uninstall     unload and remove the agent and the copied script
#
# The script is copied to ~/Library/Application Support/mac-printer-setup/ because the
# plugin cache path changes with every plugin version; the agent must not point into it.
# The config and the log are left in place by uninstall.

set -u

LABEL="io.github.machelpdesk.printer-autoswitch"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$HOME/Library/Application Support/mac-printer-setup"
INSTALLED="$APP_DIR/printer-autoswitch.sh"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CONF="$HOME/.config/mac-printer-setup/printers.conf"
LOG="$HOME/Library/Logs/mac-printer-setup.log"
DOMAIN="gui/$(id -u)"

xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# True when the config has at least one line the switch script would use: after the
# comment is removed, a QUEUE and a HOST remain. Keep this in step with pick_printer in
# printer-autoswitch.sh, or install would accept a config the agent then rejects.
has_printer_lines() {
  [ -f "$CONF" ] || return 1
  awk '{ sub(/#.*/, ""); gsub(/\r/, ""); if (NF >= 2) found = 1 } END { exit !found }' "$CONF"
}

cmd_init_config() {
  if [ -e "$CONF" ]; then
    echo "config already exists, left unchanged: $CONF"
    return 0
  fi
  mkdir -p "$(dirname "$CONF")" || return 1
  cat > "$CONF" <<'EOF'
# mac-printer-setup: printers to choose the default from, most preferred first.
# One printer per line:  QUEUE  HOST  [PORT]
#   QUEUE  the CUPS queue name, as listed by `lpstat -e`
#   HOST   the address or host name in the queue's URI (ipp://HOST/...). A queue whose
#          URI starts with dnssd:// has neither and cannot be listed here.
#   PORT   optional. 631 (ipp, ipps) when left out; use 9100 for socket://, 515 for lpd://
# Anything after a # is a comment.
# The first printer that answers on HOST:PORT becomes the default. When none answers,
# nothing changes.
#
# Home_Printer    192.0.2.10
# Office_Printer  198.51.100.20  631
EOF
  echo "wrote template: $CONF"
}

write_plist() {
  local script_xml
  script_xml="$(xml_escape "$INSTALLED")"
  mkdir -p "$(dirname "$PLIST")" || return 1
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$script_xml</string>
  </array>
  <key>WatchPaths</key>
  <array>
    <string>/Library/Preferences/SystemConfiguration</string>
    <string>/private/var/run/resolv.conf</string>
  </array>
  <key>StartInterval</key>
  <integer>600</integer>
  <key>RunAtLoad</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>10</integer>
</dict>
</plist>
EOF
  plutil -lint "$PLIST" >/dev/null
}

cmd_install() {
  if ! has_printer_lines; then
    echo "no printers in $CONF" >&2
    echo "run '$0 init-config', add at least one line, then install again" >&2
    return 2
  fi
  mkdir -p "$APP_DIR" || return 1
  cp "$SRC_DIR/printer-autoswitch.sh" "$INSTALLED" || return 1
  chmod 755 "$INSTALLED"
  if ! write_plist; then
    echo "the generated agent file did not pass plutil -lint: $PLIST" >&2
    return 1
  fi
  unload_agent
  if ! launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null; then
    # the previous job may still be on its way out; give it a moment and try once more
    sleep 1
    if ! launchctl bootstrap "$DOMAIN" "$PLIST"; then
      echo "launchctl bootstrap failed" >&2
      return 1
    fi
  fi
  echo "installed and loaded: $LABEL"
  echo "  script: $INSTALLED"
  echo "  agent:  $PLIST"
  echo "  config: $CONF"
  echo "  log:    $LOG (created the first time the default changes or something goes wrong)"
  warn_last_printer_mode
}

# Unload the agent and wait until launchd no longer lists it (at most about 3 s).
unload_agent() {
  local n=0
  launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1
  while launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 && [ "$n" -lt 10 ]; do
    sleep 0.3
    n=$((n + 1))
  done
}

# macOS can already pick the default printer by network: with "Default printer" set to
# "Last Printer Used", CUPS remembers the last printer used on each network. That setting
# is the preference UseLastPrinter in org.cups.PrintingPrefs, and it counts as on when it
# has never been set. This agent was only tested with it off (a fixed default printer).
last_printer_mode() {
  [ "$(defaults read org.cups.PrintingPrefs UseLastPrinter 2>/dev/null)" != "0" ]
}

warn_last_printer_mode() {
  if last_printer_mode; then
    echo
    echo "note: this Mac's default printer is set to \"Last Printer Used\" (or was never set)."
    echo "  macOS then chooses the default by network on its own, and this agent has not been"
    echo "  tested together with that setting. Pick a fixed default printer in System Settings >"
    echo "  Printers & Scanners, or uninstall this agent and rely on the built-in behaviour."
  fi
}

cmd_status() {
  if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    echo "agent loaded: $LABEL"
    # launchctl repeats "state =" for nested endpoints; keep the first of each key
    launchctl print "$DOMAIN/$LABEL" 2>/dev/null | awk -F' = ' '
      /^[[:space:]]*(state|runs|last exit code) = / {
        key = $1; gsub(/^[[:space:]]+/, "", key)
        if (!(key in seen)) { seen[key] = 1; printf "  %s = %s\n", key, $2 }
      }'
  else
    echo "agent not loaded: $LABEL"
  fi
  if [ -f "$LOG" ]; then
    echo "last log lines ($LOG):"
    tail -n 5 "$LOG"
  else
    echo "no log yet ($LOG is written only when the default changes or something goes wrong)"
  fi
  if last_printer_mode; then
    echo "default printer mode: Last Printer Used (untested together with this agent)"
  else
    echo "default printer mode: fixed"
  fi
}

cmd_uninstall() {
  unload_agent
  rm -f "$PLIST" "$INSTALLED"
  rmdir "$APP_DIR" 2>/dev/null
  echo "removed the agent and the copied script"
  echo "kept: $CONF and $LOG"
}

case "${1:-}" in
  init-config) cmd_init_config ;;
  install)     cmd_install ;;
  status)      cmd_status ;;
  uninstall)   cmd_uninstall ;;
  *) echo "usage: $0 {init-config|install|status|uninstall}" >&2; exit 64 ;;
esac
