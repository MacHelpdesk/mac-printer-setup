#!/bin/bash
# printer-autoswitch — make the first reachable printer in the config the default printer.
#
# Reads   ~/.config/mac-printer-setup/printers.conf   (one printer per line: QUEUE HOST [PORT])
# Logs to ~/Library/Logs/mac-printer-setup.log        (only when something changes or goes wrong)
#
# Walks the config top to bottom and probes HOST:PORT (default 631). The first printer
# that answers becomes the default. When none answers, the default is left alone.
#
# Exit codes: 0 done (changed, already right, or nothing reachable)
#             1 could not change the default
#             2 config missing or empty
#
# Run by launchd (see install-autoswitch.sh); run by hand with --now to skip the settle delay.

set -u

CONF="${MAC_PRINTER_SETUP_CONF:-$HOME/.config/mac-printer-setup/printers.conf}"
LOG="${MAC_PRINTER_SETUP_LOG:-$HOME/Library/Logs/mac-printer-setup.log}"
PROBE_TIMEOUT=2   # seconds per printer
SETTLE_DELAY="${MAC_PRINTER_SETUP_SETTLE:-5}"   # seconds to let a network change finish before probing
VERBOSE=0

say() {
  mkdir -p "$(dirname "$LOG")" 2>/dev/null
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG"
  # stderr, never stdout: pick_printer's stdout is the chosen queue name
  if [ "$VERBOSE" -eq 1 ]; then printf '%s\n' "$*" >&2; fi
}

queue_exists() { lpstat -p "$1" >/dev/null 2>&1; }

# The default printer lives in two layers: the system layer (lpadmin -d) and the user
# layer (~/.cups/lpoptions). `lpstat -d` reports the user layer when there is one, so a
# wrong system layer stays hidden. Read the two separately.
#
# The text of `lpstat -d` follows the macOS system language (LC_ALL=C does not change it),
# so take whatever follows the last colon, ASCII or full-width, and accept it only if it
# names a real queue.
system_default() {
  local name
  name="$(HOME=/var/empty lpstat -d 2>/dev/null | sed -E 's/.*(: |：)//')"
  if [ -n "$name" ] && queue_exists "$name"; then printf '%s\n' "$name"; fi
}

user_default() {
  [ -f "$HOME/.cups/lpoptions" ] || return 0
  sed -nE 's/^Default[[:space:]]+([^[:space:]]+).*/\1/p' "$HOME/.cups/lpoptions" | head -1
}

has_user_layer() { [ -n "$(user_default)" ]; }

# Prints the first reachable queue. Returns 1 when none is reachable, 2 when the config
# has no usable line.
pick_printer() {
  local line queue host port rest entries=0
  # `|| [ -n "$line" ]` keeps a last line that has no trailing newline.
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"        # a comment may take a whole line or follow the fields
    line="${line%$'\r'}"      # a config saved with CRLF line endings
    queue="" host="" port="" rest=""
    read -r queue host port rest <<< "$line"
    [ -n "$queue" ] && [ -n "$host" ] || continue
    entries=$((entries + 1))
    port="${port:-631}"
    if ! queue_exists "$queue"; then
      say "config names a queue that does not exist: $queue (skipped)"
      continue
    fi
    if nc -z -G "$PROBE_TIMEOUT" "$host" "$port" >/dev/null 2>&1; then
      printf '%s\n' "$queue"
      return 0
    fi
  done < "$CONF"
  [ "$entries" -gt 0 ] || return 2
  return 1
}

main() {
  if [ "${1:-}" = "--now" ]; then VERBOSE=1; else sleep "$SETTLE_DELAY"; fi

  if [ ! -f "$CONF" ]; then
    say "no config at $CONF"
    return 2
  fi

  local target rc
  target="$(pick_printer)"
  rc=$?
  if [ "$rc" -eq 2 ]; then
    say "config has no printer lines: $CONF"
    return 2
  fi
  if [ "$rc" -ne 0 ]; then
    [ "$VERBOSE" -eq 1 ] && printf 'no configured printer is reachable; default left alone\n' >&2
    return 0
  fi

  local sys usr
  sys="$(system_default)"
  usr="$(user_default)"
  if [ "$sys" = "$target" ] && { ! has_user_layer || [ "$usr" = "$target" ]; }; then
    [ "$VERBOSE" -eq 1 ] && printf 'default is already %s\n' "$target" >&2
    return 0
  fi

  if ! lpadmin -d "$target" 2>>"$LOG"; then
    say "could not set the system default to $target"
    return 1
  fi
  # Only keep an existing user layer in step; do not create one on machines without it.
  if has_user_layer && ! lpoptions -d "$target" >/dev/null 2>>"$LOG"; then
    say "could not set the user default to $target"
    return 1
  fi
  say "default printer: system=${sys:-none} user=${usr:-none} -> $target"
}

main "$@"
