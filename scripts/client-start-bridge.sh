#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 spacegaucho
# SPDX-License-Identifier: GPL-3.0-or-later
# client-start-bridge.sh — client side of the tailcat bridge.
#
# Chain (client side):
#   UT99 client --UDP 127.0.0.1:7777/7778--> ut99-bridge.py relay --TCP 127.0.0.1:8777--> tailcat forward
#     ...tailcat tunnel...--> host's tailcat serve 8777 --> host's relay --> host's UT99 server
#
# The relay frames every UDP datagram before it crosses the TCP tunnel;
# a raw byte-stream bridge (e.g. plain socat) merges packet bursts into
# giant datagrams and corrupts the game. See scripts/ut99-bridge.py.
#
# Usage: ./client-start-bridge.sh <tc-address>
#   or:  TC_ADDR=tcpXXXX ./client-start-bridge.sh
# If the host uses a different bridge port, set HOST_BRIDGE_TCP_PORT=...
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../helpers/ut99-env.sh"

TC_ADDR="${1:-${TC_ADDR:-}}"
if [ -z "$TC_ADDR" ]; then
  echo "Usage: $0 <tc-address>   (the address host-start-bridge.sh printed)" >&2
  exit 1
fi

require_cmd python3 tailcat || exit 1
start_job_trap

echo "tailcat: forwarding local TCP 127.0.0.1:${BRIDGE_TCP_PORT} -> host port ${HOST_BRIDGE_TCP_PORT}"
tailcat_exec forward "$TC_ADDR" "${BRIDGE_TCP_PORT}:${HOST_BRIDGE_TCP_PORT}" &
TAILCAT_PID=$!

# Wait until the tailcat local listener is actually accepting connections.
ready=0
for _ in $(seq 1 40); do
  if (exec 3<>"/dev/tcp/127.0.0.1/${BRIDGE_TCP_PORT}") 2>/dev/null; then
    ready=1
    break
  fi
  sleep 0.5
done
if [ "$ready" != "1" ]; then
  echo "Error: tailcat local listener never came up (bad address, or host not reachable)." >&2
  exit 1
fi

echo "relay: UDP 127.0.0.1:${UT_UDP_PORT} +$((UT_UDP_PORT + 1)) -> TCP 127.0.0.1:${BRIDGE_TCP_PORT} (framed)"
python3 "$SCRIPT_DIR/ut99-bridge.py" client \
  --udp-port "$UT_UDP_PORT" --tcp-host 127.0.0.1 --tcp-port "$BRIDGE_TCP_PORT" &

echo "Bridge ready. In UT99: Multiplayer > Join Game > Open Game > 127.0.0.1:${UT_UDP_PORT}"
echo "Press Ctrl+C to disconnect."
wait -n
