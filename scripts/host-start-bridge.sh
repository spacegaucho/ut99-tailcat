#!/usr/bin/env bash
# host-start-bridge.sh — host side of the tailcat bridge.
#
# Chain (host side):
#   tailcat serve :8777  ->  socat TCP->UDP  ->  127.0.0.1:7777 (UT99 server)
#
# Start the UT99 server first (./host-start-server.sh), then run this and
# share the printed tcp... address with your friends. Each friend runs
# client-start-bridge.sh with that address.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../helpers/ut99-env.sh"

require_cmd socat tailcat || exit 1
start_job_trap

echo "socat: TCP 127.0.0.1:${BRIDGE_TCP_PORT} -> UDP 127.0.0.1:${UT_UDP_PORT} (UT99 server)"
socat "TCP-LISTEN:${BRIDGE_TCP_PORT},reuseaddr,fork,bind=127.0.0.1" "UDP:127.0.0.1:${UT_UDP_PORT}" &
SOCAT_PID=$!

echo "tailcat: serving TCP port ${BRIDGE_TCP_PORT} — share the tcp... address it prints below."
tailcat_exec serve "$BRIDGE_TCP_PORT" &
TAILCAT_PID=$!

echo "Bridge running. Press Ctrl+C to stop."

# Monitor loop instead of plain 'wait': bash defers trapped signals (notably
# SIGINT from Ctrl+C) until 'wait' completes, which never happens while the
# bridge runs. Polling also makes the script exit as soon as either child
# dies, after which the EXIT trap cleans up the other one.
while kill -0 "$TAILCAT_PID" 2>/dev/null && kill -0 "$SOCAT_PID" 2>/dev/null; do
  sleep 1
done
