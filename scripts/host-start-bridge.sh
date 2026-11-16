#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 spacegaucho
# SPDX-License-Identifier: GPL-3.0-or-later
# host-start-bridge.sh — host side of the tailcat bridge.
#
# Chain (host side):
#   tailcat serve :8777  ->  ut99-bridge.py relay  ->  127.0.0.1:7777/7778 (UT99 server)
#
# The relay frames every UDP datagram before it crosses the TCP tunnel;
# a raw byte-stream bridge (e.g. plain socat) merges packet bursts into
# giant datagrams and corrupts the game. See scripts/ut99-bridge.py.
#
# Start the UT99 server first (./host-start-server.sh), then run this and
# share the printed tcp... address with your friends. Each friend runs
# client-start-bridge.sh with that address.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../helpers/ut99-env.sh"

require_cmd python3 tailcat || exit 1
start_job_trap

echo "relay: TCP 127.0.0.1:${BRIDGE_TCP_PORT} -> UDP 127.0.0.1:${UT_UDP_PORT} +$((UT_UDP_PORT + 1)) (UT99 server, framed)"
python3 "$SCRIPT_DIR/ut99-bridge.py" host \
  --tcp-bind 127.0.0.1 --tcp-port "$BRIDGE_TCP_PORT" \
  --udp-host 127.0.0.1 --udp-port "$UT_UDP_PORT" &
RELAY_PID=$!

# When the server enabled UT99's built-in web admin ('ut99 server --admin'
# exports UT99_ADMIN_PORT), serve that port on the same tailcat address: tailcat
# proxies served ports straight to localhost, and the admin UI is plain HTTP, so
# it needs no relay of its own.  Friends reach it with
#   tailcat forward <this address> 18080:<UT99_ADMIN_PORT>
# (which 'ut99 client <address> --admin' does for them).
serve_ports="$BRIDGE_TCP_PORT"
if [ -n "${UT99_ADMIN_PORT:-}" ]; then
  serve_ports="$BRIDGE_TCP_PORT,$UT99_ADMIN_PORT"
  echo "tailcat: also serving the web admin port ${UT99_ADMIN_PORT} (friends: ut99 client <address> --admin)"
fi

echo "tailcat: serving TCP ports ${serve_ports} — share the tcp... address it prints below."
tailcat_exec serve "$serve_ports" &
TAILCAT_PID=$!

echo "Bridge running. Press Ctrl+C to stop."

# Monitor loop instead of plain 'wait': bash defers trapped signals (notably
# SIGINT from Ctrl+C) until 'wait' completes, which never happens while the
# bridge runs. Polling also makes the script exit as soon as either child
# dies, after which the EXIT trap cleans up the other one.
while kill -0 "$TAILCAT_PID" 2>/dev/null && kill -0 "$RELAY_PID" 2>/dev/null; do
  sleep 1
done
