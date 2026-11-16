#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 spacegaucho
# SPDX-License-Identifier: GPL-3.0-or-later
# ut99-env.sh — shared configuration for all ut99-tailcat scripts.
#
# Sourced by the ut99 wrapper and by the scripts in scripts/.  Every value can
# be overridden through the environment, e.g.:
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
export BRIDGE_TCP_PORT="${BRIDGE_TCP_PORT:-8777}"   # local TCP port of the relay<->tailcat bridge
# Port the HOST's tailcat serves. Defaults to the standard 8777, NOT to
# BRIDGE_TCP_PORT: on a loopback test the client overrides its *local*
# BRIDGE_TCP_PORT (e.g. 9777) but the host still serves 8777.
export HOST_BRIDGE_TCP_PORT="${HOST_BRIDGE_TCP_PORT:-8777}"

# --- tailcat ----------------------------------------------------------------
# Optional saved tailcat key name for a stable tcp... address across restarts
# (create one with: tailcat genkey --key ut99). Empty = ephemeral per-run key.
export TAILCAT_KEY="${TAILCAT_KEY:-}"

# UT99's built-in web admin (UTServerAdmin, served by [UWeb.WebServer] on
# UT99_ADMIN_PORT). Empty here on purpose: the port is only advertised on the
# tailcat tunnel when the server actually enabled the admin ('ut99 server
# --admin' exports it).  See docs/admin-api.md.
export UT99_ADMIN_PORT="${UT99_ADMIN_PORT:-}"

# install-deps.sh installs tailcat into ~/.local/bin, but some distro/shell
# setups (e.g. a fresh fish/CachyOS) do not have that directory in PATH.
# If tailcat is installed there but not otherwise findable, extend PATH so
# require_cmd/'tailcat_exec' work without the user editing their shell config.
UT99_BIN_DIR="${INSTALL_BIN_DIR:-$HOME/.local/bin}"
if ! command -v tailcat >/dev/null 2>&1 && [ -x "$UT99_BIN_DIR/tailcat" ]; then
  export PATH="$PATH:$UT99_BIN_DIR"
fi

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
# tailcat --key NAME loads CONFIG/tailcat/keys/NAME.private.json and errors
# out if the file is missing, so a first-time named key is generated here
# once — from then on the tcp... address derived from it stays the same.
tailcat_exec() {
  if [ -n "$TAILCAT_KEY" ]; then
    local keyfile="${XDG_CONFIG_HOME:-$HOME/.config}/tailcat/keys/$TAILCAT_KEY.private.json"
    if [ ! -f "$keyfile" ]; then
      echo "tailcat: generating saved key '$TAILCAT_KEY' (first run, its tcp... address is now stable)"
      tailcat genkey --key "$TAILCAT_KEY" || { echo "tailcat: genkey --key $TAILCAT_KEY failed" >&2; return 1; }
    fi
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

# ini_set <ini-file> <Section> <Key> <Value> — replace/add a key inside an ini
# section; appends the section at EOF when missing. Preserves the file's line
# endings (CRLF when the file uses them) and touches nothing else.
ini_set() {
  local file="$1" section="$2" key="$3" value="$4"
  local crlf=""
  [ -f "$file" ] && head -1 "$file" | grep -q $'\r' && crlf=$'\r'
  awk -v sec="[$section]" -v key="$key" -v kv="$key=$value" -v crlf="$crlf" '
    BEGIN { done = 0; insec = 0 }
    {
      line = $0; sub(/\r$/, "", line)
      if (line == sec) { insec = 1; print $0; next }
      if (insec && line ~ /^\[/) {
        if (!done) { print kv crlf; done = 1 }
        insec = 0
      }
      if (insec && line ~ "^" key "=") { print kv crlf; done = 1; next }
      print $0
    }
    END {
      if (!done) { print ""; print sec crlf; print kv crlf }
    }
  ' "$file" > "$file.ut99tmp" && mv "$file.ut99tmp" "$file"
}

# ini_unset <ini-file> <Section> <Key> — delete one key from an ini section.
# No-op when the section or the key is missing; touches nothing else.
ini_unset() {
  local file="$1" section="$2" key="$3"
  awk -v sec="[$section]" -v key="$key" '
    BEGIN { insec = 0 }
    {
      line = $0; sub(/\r$/, "", line)
      if (line == sec) { insec = 1; print $0; next }
      if (insec && line ~ /^\[/) insec = 0
      if (insec && line ~ "^" key "=") next
      print $0
    }
  ' "$file" > "$file.ut99tmp" && mv "$file.ut99tmp" "$file"
}

# ini_get <ini-file> <Section> <Key> — print the key's value (first match).
ini_get() {
  local file="$1" section="$2" key="$3"
  [ -f "$file" ] || return 0
  awk -v sec="[$section]" -v key="$key" '
    BEGIN { insec = 0 }
    {
      line = $0; sub(/\r$/, "", line)
      if (line == sec) { insec = 1; next }
      if (line ~ /^\[/) { insec = 0 }
      if (insec && line ~ "^" key "=") { sub(/^[^=]*=/, "", line); print line; exit }
    }
  ' "$file"
}
