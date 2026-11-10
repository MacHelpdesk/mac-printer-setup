#!/bin/bash
# printer-probe — read-only checks for "the Mac cannot reach the printer".
#
#   printer-probe.sh queues               every CUPS queue: status, device URI, model
#   printer-probe.sh net                  this Mac's addresses, the gateway, and the second hop
#   printer-probe.sh bonjour [SECONDS]    printers advertised on this network
#                                         (SECONDS per service type, four types, default 4)
#   printer-probe.sh scan A.B.C [HOST]    which hosts in A.B.C.0/24 have a print port open
#   printer-probe.sh identify HOST        model, UUID and state of the IPP printer at HOST
#   printer-probe.sh wifi-direct          printer Wi-Fi Direct networks in range
#
# Nothing here changes a setting. The commands that open connections are:
#   queues    one TCP connection to the address in each queue's URI
#   net       a traceroute limited to two hops
#   scan      ports 631 and 9100 on every address of one private /24, then up to four
#             ports (53, 80, 443, 631) on HOST to check the scan can reach that network
#   identify  one IPP request to HOST
# Whether a network may be scanned is decided in the printer-diagnose skill, not here;
# this script only refuses networks that are not private (RFC 1918).

set -u

PROBE_TIMEOUT=2

TMPD="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMPD"' EXIT
trap 'exit 130' INT TERM

port_for_scheme() {
  case "$1" in
    ipp|ipps) echo 631 ;;
    socket)   echo 9100 ;;
    lpd)      echo 515 ;;
    http)     echo 80 ;;
    https)    echo 443 ;;
    *)        echo "" ;;
  esac
}

# A.B.C with every part a number from 0 to 255.
valid_prefix() {
  local IFS=. a b c extra o
  read -r a b c extra <<< "$1"
  [ -z "${extra:-}" ] || return 1
  for o in "${a:-}" "${b:-}" "${c:-}"; do
    case "$o" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#o}" -le 3 ] && [ "$o" -le 255 ] || return 1
  done
}

is_private_prefix() { # A.B.C, already validated
  case "$1" in
    10.*|192.168.*) return 0 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
    *) return 1 ;;
  esac
}

open_port() { nc -z -G "$PROBE_TIMEOUT" "$1" "$2" >/dev/null 2>&1; }

queue_exists() { lpstat -p "$1" >/dev/null 2>&1; }

# The text of `lpstat -d` follows the system language, so take what follows the last
# colon (ASCII or full-width) and accept it only if it names a real queue.
system_default() {
  local name
  name="$(HOME=/var/empty lpstat -d 2>/dev/null | sed -E 's/.*(: |：)//')"
  if [ -n "$name" ] && queue_exists "$name"; then printf '%s' "$name"; fi
}

user_default() {
  sed -nE 's/^Default[[:space:]]+([^[:space:]]+).*/\1/p' "$HOME/.cups/lpoptions" 2>/dev/null | head -1
}

# Queue names come from `lpstat -e` and the URI and model from `lpoptions -p`: both are
# independent of the system language. The text of `lpstat -v` / `-p` is localized
# (LC_ALL=C does not change it on macOS) and must not be parsed for names.
cmd_queues() {
  local sys usr name opts uri model scheme rest hostport host port status
  sys="$(system_default)"
  usr="$(user_default)"
  echo "default (system layer): ${sys:-none}"
  echo "default (user layer):   ${usr:-none}"
  echo
  printf 'QUEUE\tSTATUS\tURI\tMODEL\n'
  local uris="$TMPD/uris"
  : > "$uris"
  lpstat -e 2>/dev/null | while IFS= read -r name; do
    [ -n "$name" ] || continue
    queue_exists "$name" || continue
    opts="$(lpoptions -p "$name" 2>/dev/null)"
    uri="$(printf '%s\n' "$opts" | tr ' ' '\n' | sed -n 's/^device-uri=//p' | head -1)"
    model="$(printf '%s\n' "$opts" | sed -n "s/.*printer-make-and-model='\\([^']*\\)'.*/\\1/p")"
    [ -n "$model" ] || model="$(printf '%s\n' "$opts" | sed -n 's/.*printer-make-and-model=\([^ ]*\).*/\1/p')"
    scheme="${uri%%://*}"
    rest="${uri#*://}"
    hostport="${rest%%/*}"
    status="not-probed"
    case "$scheme" in
      dnssd) status="bonjour" ;;
      *)
        port="$(port_for_scheme "$scheme")"
        case "$hostport" in
          ''|*@*|\[*) : ;;   # no host, credentials in the URI, or a bracketed IPv6 address
          *)
            host="${hostport%%:*}"
            case "$hostport" in *:*) port="${hostport##*:}" ;; esac
            if [ -n "$port" ]; then
              if open_port "$host" "$port"; then status="reachable"; else status="unreachable"; fi
            fi ;;
        esac ;;
    esac
    printf '%s\t%s\t%s\t%s\n' "$name" "$status" "${uri:-none}" "${model:-unknown}"
    [ -n "$uri" ] && printf '%s\t%s\n' "$uri" "$name" >> "$uris"
  done
  local dup
  dup="$(cut -f1 "$uris" | sort | uniq -d)"
  if [ -n "$dup" ]; then
    echo
    echo "queues that share one URI (duplicates):"
    printf '%s\n' "$dup" | while IFS= read -r uri; do
      printf '  %s: %s\n' "$uri" "$(awk -F'\t' -v u="$uri" '$1==u{print $2}' "$uris" | tr '\n' ' ')"
    done
  fi
}

cmd_net() {
  local i ip gw hop2 own=""
  for i in $(ifconfig -lu); do
    ip="$(ipconfig getifaddr "$i" 2>/dev/null)" || continue
    [ -n "$ip" ] || continue
    echo "interface $i: $ip"
    own="$own ${ip%.*}"
  done
  gw="$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')"
  echo "default gateway: ${gw:-none}"
  [ -n "$gw" ] || return 0
  # Two hops only: enough to see the router behind the gateway.
  hop2="$(traceroute -n -w 1 -q 1 -m 2 1.1.1.1 2>/dev/null | awk '$1==2{print $2}')"
  case "$hop2" in
    ''|'*') echo "second hop: no answer" ;;
    *)
      echo "second hop: $hop2"
      if valid_prefix "${hop2%.*}" && is_private_prefix "${hop2%.*}"; then
        case " $own " in
          *" ${hop2%.*} "*) : ;;
          *)
            echo "second hop is private: ${hop2%.*}.0/24"
            echo "  that network is either your own second router's, or your ISP's or building's;"
            echo "  this check cannot tell which. Bonjour from it does not reach this Mac." ;;
        esac
      fi ;;
  esac
}

cmd_bonjour() {
  local secs="${1:-4}" t pid out="$TMPD/bonjour"
  case "$secs" in
    ''|*[!0-9]*) echo "usage: $0 bonjour [SECONDS]   (a whole number)" >&2; return 64 ;;
  esac
  for t in _ipp._tcp _ipps._tcp _pdl-datastream._tcp _printer._tcp; do
    dns-sd -B "$t" local. > "$out.$t" 2>/dev/null &
    pid=$!
    sleep "$secs"
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    awk -v t="$t" '$2=="Add"{ n=$7; for(i=8;i<=NF;i++) n=n" "$i; print t"\t"n }' "$out.$t"
  done | sort -u > "$out"
  if [ -s "$out" ]; then
    cat "$out"
  else
    echo "no printer advertised on this network in $secs s per service type"
  fi
}

cmd_scan() {
  local prefix="${1:-}" check="${2:-}" out="$TMPD/scan" i p
  if ! valid_prefix "$prefix"; then
    echo "usage: $0 scan A.B.C [HOST]   (the first three numbers of a /24, each 0-255)" >&2
    return 64
  fi
  if ! is_private_prefix "$prefix"; then
    echo "refusing to scan $prefix.0/24: not a private (RFC 1918) network" >&2
    return 64
  fi
  check="${check:-$prefix.1}"
  case "$check" in
    *[!A-Za-z0-9._:-]*) echo "not a host name or address: $check" >&2; return 64 ;;
  esac
  : > "$out"
  for p in 631 9100; do
    for i in $(seq 1 254); do
      ( nc -z -G 1 "$prefix.$i" "$p" >/dev/null 2>&1 && echo "$prefix.$i $p" >> "$out" ) &
    done
    wait
  done
  if [ -s "$out" ]; then
    sort -t. -k4 -n "$out" | awk '{print $1"\tport "$2" open"}'
  else
    echo "no host in $prefix.0/24 has port 631 or 9100 open"
  fi
  # An empty result means little unless this method can reach something in that network.
  for p in 53 80 443 631; do
    if nc -z -G 1 "$check" "$p" >/dev/null 2>&1; then
      echo "check: $check answers on port $p, so this method reaches $prefix.0/24"
      return 0
    fi
  done
  echo "check: $check did not answer on 53, 80, 443 or 631; an empty result may mean the scan could not get there"
}

cmd_identify() {
  local host="${1:-}" attrs
  case "$host" in
    ''|*[!A-Za-z0-9._:-]*) echo "usage: $0 identify HOST   (a host name or address)" >&2; return 64 ;;
  esac
  attrs="$(ipptool -tv "ipp://$host/ipp/print" get-printer-attributes.test 2>/dev/null \
    | grep -E '^[[:space:]]*(printer-make-and-model|printer-info|printer-uuid|printer-state|printer-state-reasons) ' \
    | sed -E 's/^[[:space:]]+//')"
  if [ -z "$attrs" ]; then
    echo "no IPP answer from $host (a host with only port 9100 open does not speak IPP, so this says nothing about it)"
    return 1
  fi
  printf '%s\n' "$attrs"
}

cmd_wifi_direct() {
  local found
  found="$(system_profiler SPAirPortDataType 2>/dev/null | sed -nE 's/^[[:space:]]+(DIRECT-.*):$/\1/p' | sort -u)"
  if [ -n "$found" ]; then printf '%s\n' "$found"; else echo "no Wi-Fi Direct network in range"; fi
}

case "${1:-}" in
  queues)      cmd_queues ;;
  net)         cmd_net ;;
  bonjour)     shift; cmd_bonjour "$@" ;;
  scan)        shift; cmd_scan "$@" ;;
  identify)    shift; cmd_identify "$@" ;;
  wifi-direct) cmd_wifi_direct ;;
  *) echo "usage: $0 {queues|net|bonjour [SECONDS]|scan A.B.C [HOST]|identify HOST|wifi-direct}" >&2; exit 64 ;;
esac
