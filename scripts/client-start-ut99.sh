#!/usr/bin/env bash
# client-start-ut99.sh — launch the UT99 game client (Lutris install) and
# auto-join a server. Extra arguments are passed through to the game.
#
# Auto-join: the server address as the first argument. Verified working on
# this install (OldUnreal 469): the client starts connecting a few seconds
# after launch, while the intro movies play (~15 s). If you land on the main
# menu instead, the join attempt failed — almost always because nothing was
# listening on the port yet (server/bridges not started, or a different
# UT_UDP_PORT). Correct order:
#   host-start-server.sh → host bridge → client bridge → this script
# There is no -nointro option on 469; the intro always plays.
#
# Usage:
#   ./client-start-ut99.sh                    # auto-join 127.0.0.1:$UT_UDP_PORT
#   ./client-start-ut99.sh 127.0.0.1:7779     # loopback test setup (UT_UDP_PORT=7779)
#   UT_AUTOJOIN=0 ./client-start-ut99.sh      # no auto-join (start at main menu)
# Alternative: launch normally with  lutris -i unreal-tournament  and use
# Multiplayer > Join Game > Open Game > 127.0.0.1:<UT_UDP_PORT>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../helpers/ut99-env.sh"

require_cmd "$WINE_BIN" || exit 1

if ! game_exe="$(find_ci "$UT_DIR" UnrealTournament.exe)"; then
  echo "Error: UnrealTournament.exe not found in $UT_DIR" >&2
  echo "Set UT_DIR (and WINEPREFIX) to your Lutris install's System directory." >&2
  exit 1
fi

# Build the game arguments: user-supplied args win; otherwise auto-join.
if [ "$#" -gt 0 ]; then
  game_args=("$@")
elif [ "${UT_AUTOJOIN:-1}" = "1" ]; then
  game_args=("127.0.0.1:${UT_UDP_PORT}")
else
  game_args=()
fi

# Preflight (local targets only): warn when nothing is listening yet, since
# the client would then fall back to the main menu instead of joining.
join_target="${game_args[0]:-}"
if [[ "$join_target" =~ ^127\.0\.0\.1:([0-9]+)$ ]]; then
  join_port="${BASH_REMATCH[1]}"
  if ! ss -lun 2>/dev/null | grep -qE "[:.]${join_port}( |$)"; then
    echo "Warning: nothing is listening on UDP :${join_port} locally." >&2
    echo "Start the server and the bridges first, or the client will" >&2
    echo "show the main menu instead of joining." >&2
  fi
fi

# 469 crash-recovery flag: a normal exit deletes System/Running.ini, but a
# killed/crashed run leaves the 0-byte file behind. The next client then opens
# the "Unreal Tournament Recovery Mode" wizard and stalls instead of joining,
# so scrub any stale copy first.
rm -f "$UT_DIR/Running.ini"

cd "$UT_DIR"
echo "Launching UT99 from $UT_DIR (WINEPREFIX=$WINEPREFIX)"
if [ "${#game_args[@]}" -gt 0 ]; then
  echo "Auto-joining ${game_args[0]} — the join proceeds during the intro movies."
fi
echo "Fallback if it fails: Multiplayer > Join Game > Open Game > 127.0.0.1:${UT_UDP_PORT}"

# UT's own engine log (net attempts, rejections, join state) — the client-side
# view that plain wine stdout never shows. -forcelogflush keeps it usable when
# the process is killed. Written to $UT_DIR/ut99-client.log; disable with
# UT99_LOG=0.
ut99_log=()
if [ "${UT99_LOG:-1}" = "1" ]; then
  ut99_log=(-log=ut99-client.log -forcelogflush)
fi
exec "${WINE_BIN}" "$(basename "$game_exe")" "${game_args[@]}" "${ut99_log[@]}"
