#!/usr/bin/env bash
# ut99-env.sh — shared configuration for all ut99-socat-tailcat scripts.
#
# Sourced by the other scripts. Every value can be overridden through the
# environment, e.g.:
#   UT_UDP_PORT=7778 ./client-start-bridge.sh tcpXXXX
#   MAP=CTF-1on1-Jail2 ./host-start-server.sh
#
# Defaults point at the Lutris "unreal-tournament" install (runner: wine,
# wine version "system"), so scripts work out of the box for testing.

# --- UT99 install (Lutris) -------------------------------------------------
# Wine prefix of the Lutris game (see ~/.config/lutris/games/unreal-tournament-*.yml)
export WINEPREFIX="${WINEPREFIX:-$HOME/wine/unreal-tournament}"
# The game's System directory inside that prefix
export UT_DIR="${UT_DIR:-$WINEPREFIX/drive_c/UnrealTournament/System}"
# Wine binary (Lutris uses the system wine for this game)
export WINE_BIN="${WINE_BIN:-wine}"

# --- Ports ------------------------------------------------------------------
export UT_UDP_PORT="${UT_UDP_PORT:-7777}"           # UT99 server & client port (UDP)
export BRIDGE_TCP_PORT="${BRIDGE_TCP_PORT:-8777}"   # local TCP port of the socat<->tailcat bridge
# Port the HOST's tailcat serves. Defaults to the standard 8777, NOT to
# BRIDGE_TCP_PORT: on a loopback test the client overrides its *local*
# BRIDGE_TCP_PORT (e.g. 9777) but the host still serves 8777.
export HOST_BRIDGE_TCP_PORT="${HOST_BRIDGE_TCP_PORT:-8777}"

# --- tailcat ----------------------------------------------------------------
# Optional saved tailcat key name for a stable tcp... address across restarts
# (create one with: tailcat genkey --key ut99). Empty = ephemeral per-run key.
export TAILCAT_KEY="${TAILCAT_KEY:-}"

# --- helpers -----------------------------------------------------------------

require_cmd() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Error: '$cmd' not found in PATH. Run ./install-deps.sh first." >&2
      return 1
    fi
  done
  return 0
}

# find_ci <dir> <file> — find <file> in <dir>, case-insensitively
# (the Lutris install has UCC.exe / UnrealTournament.exe with capitals,
# while the Linux filesystem is case-sensitive).
find_ci() {
  local dir="$1" target="$2" entry want_lc lc
  if [ -f "$dir/$target" ]; then
    printf '%s\n' "$dir/$target"
    return 0
  fi
  want_lc="$(printf '%s' "$target" | tr '[:upper:]' '[:lower:]')"
  for entry in "$dir"/*; do
    [ -f "$entry" ] || continue
    lc="$(basename "$entry" | tr '[:upper:]' '[:lower:]')"
    if [ "$lc" = "$want_lc" ]; then
      printf '%s\n' "$entry"
      return 0
    fi
  done
  return 1
}

# tailcat_exec — runs tailcat, adding --key when TAILCAT_KEY is set.
# 'exec' makes the backgrounded subshell (cmd &) *become* tailcat, so the
# job pid cleanup kills refers to is the real tailcat process, not a bash
# wrapper that would leave tailcat orphaned.
tailcat_exec() {
  if [ -n "$TAILCAT_KEY" ]; then
    exec tailcat --key "$TAILCAT_KEY" "$@"
  else
    exec tailcat "$@"
  fi
}

# start_job_trap — kill all background jobs when the script exits (Ctrl+C).
# Escalates TERM -> KILL because tailcat ignores SIGTERM (SIG_IGN).
start_job_trap() {
  cleanup() {
    echo
    echo "Stopping bridge processes..."
    local job
    for job in $(jobs -p); do
      # Safety net: also kill any child processes of each job.
      pkill -TERM -P "$job" 2>/dev/null || true
      kill -TERM "$job" 2>/dev/null || true
    done
    sleep 1
    for job in $(jobs -p); do
      pkill -KILL -P "$job" 2>/dev/null || true
      kill -KILL "$job" 2>/dev/null || true
    done
    wait 2>/dev/null || true
  }
  trap cleanup EXIT INT TERM
}
