#!/usr/bin/env bash
# host-start-server.sh — start the UT99 dedicated server (Lutris wine install).
#
# Override via environment, e.g.:
#   MAP=CTF-1on1-Jail2 BOT_SKILL=5 ./host-start-server.sh
#   EXTRA_OPTS="?GoalScore=10?TimeLimit=20" ./host-start-server.sh
#   DISABLE_UPLINKS=0 ./host-start-server.sh   # keep master server listings
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../helpers/ut99-env.sh"

MAP="${MAP:-CTF-Face}"
GAME_TYPE="${GAME_TYPE:-Botpack.CTFGame}"
# Bot skill: 0=Novice 1=Average 2=Experienced 3=Skilled 4=Adept 5=Masterful 6=Inhuman 7=Godlike
BOT_SKILL="${BOT_SKILL:-3}"
EXTRA_OPTS="${EXTRA_OPTS:-?Mutator=Botpack.InstaGibDM?MinPlayers=4?GoalScore=5?TimeLimit=15?Difficulty=${BOT_SKILL}}"
# Comment out ServerActors=IpServer.UdpServerUplink lines so the server does
# not register with (mostly dead) public master servers.
DISABLE_UPLINKS="${DISABLE_UPLINKS:-1}"

disable_master_uplinks() {
  local ini
  for ini in "$UT_DIR/Default.ini" "$UT_DIR/UnrealTournament.ini"; do
    [ -f "$ini" ] || continue
    grep -q '^ServerActors=IpServer.UdpServerUplink' "$ini" || continue
    if [ ! -w "$ini" ]; then
      echo "Warning: $ini is not writable, could not disable master server uplinks." >&2
      continue
    fi
    cp -n "$ini" "$ini.ut99bak"   # keep the original as *.ut99bak (only once)
    sed -i 's/^ServerActors=IpServer\.UdpServerUplink/;ServerActors=IpServer.UdpServerUplink/' "$ini"
    echo "Disabled master server uplinks in $(basename "$ini") (backup: $(basename "$ini").ut99bak)"
  done
}

if [ "$DISABLE_UPLINKS" = "1" ]; then
  disable_master_uplinks
fi

# Prefer a native Linux server binary (OldUnreal 469+ ships ucc-bin) if present.
if native_server="$(find_ci "$UT_DIR" ucc-bin)"; then
  echo "Using native server binary: $native_server"
  server_cmd=("$native_server")
else
  if ! ucc_exe="$(find_ci "$UT_DIR" UCC.exe)"; then
    echo "Error: neither ucc-bin nor UCC.exe found in $UT_DIR" >&2
    echo "Set UT_DIR (and WINEPREFIX) to your Lutris install's System directory." >&2
    exit 1
  fi
  server_cmd=("$WINE_BIN" "$(basename "$ucc_exe")")
fi

# Scrub any stale 469 crash-recovery flag (see client-start-ut99.sh): a killed
# server run leaves System/Running.ini behind and would trip the recovery
# wizard on the next client launch on this machine.
rm -f "$UT_DIR/Running.ini"

cd "$UT_DIR"

URL="${MAP}?Game=${GAME_TYPE}${EXTRA_OPTS}"
echo "Starting UT99 dedicated server: $URL"
echo "Local test join: Multiplayer > Join Game > Open Game > 127.0.0.1:${UT_UDP_PORT}"
echo "Press Ctrl+C to stop the server."
exec "${server_cmd[@]}" server "$URL"
