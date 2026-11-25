#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 spacegaucho
# SPDX-License-Identifier: GPL-3.0-or-later
# host-serve-files.sh — serve the packed wine prefix tarball (+ its .sha256)
# over tailcat's built-in file service, so friends can pull it with
# `tailcat cp` — no web server, no ports, no accounts.
#
# tailcat's files service is an SFTP-style server rooted at one directory
# (read-only by default); the friend's side uses the system scp under the
# hood, so they get progress bars and resume-friendly copies.
#
# Output: quiet by default.  Once tailcat prints its address, ready-to-paste
# friend fetch commands (Linux + Windows) are built from it — no <tcp...>
# placeholders.  With UT99_VERBOSE=1 (wrapper: --verbose/-v) tailcat runs
# with --verbose and its log is filtered to what matters: every friend
# connection to the file service prints as the pull starts.
#
# Usage:
#   ./host-serve-files.sh                       # serve ./files (repo default)
#   ./host-serve-files.sh ~/share               # serve another directory
#   UT99_FILE_SERVE_DIR=~/share ./host-serve-files.sh
#   (wrapper form: ./ut99 file-serve [DIR] [--dir DIR] [--tc-key NAME] [-v])
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../helpers/ut99-env.sh"

DIR="${1:-${UT99_FILE_SERVE_DIR:-$SCRIPT_DIR/../files}}"
if [ ! -d "$DIR" ]; then
  echo "Error: $DIR is not a directory. Pack first: ./ut99 pack" >&2
  exit 1
fi
require_cmd tailcat awk || exit 1

if [ ! -f "$DIR/ut99-wineprefix.tgz" ]; then
  echo "Warning: no ut99-wineprefix.tgz in $DIR — pack it first (./ut99 pack)." >&2
  echo "Serving the directory as-is." >&2
fi

# Cleanup instead of start_job_trap: tailcat is the direct background job
# (tailcat_exec's 'exec' keeps job pid == tailcat pid), tailcat ignores
# INT/TERM, so the kill is -KILL.  A guarded cleanup runs once for INT,
# once EXIT would double-print without the guard.
TAILCAT_PID=""
FIFO=""
cleaned=0
cleanup() {
  [ "$cleaned" = 1 ] && return
  cleaned=1
  echo
  echo "Stopping file service..."
  [ -n "$TAILCAT_PID" ] && kill -KILL "$TAILCAT_PID" 2>/dev/null || true
  [ -n "$FIFO" ] && rm -f "$FIFO"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

FIFO="$(mktemp -u "${TMPDIR:-/tmp}/ut99-fserve.XXXXXX")"
mkfifo "$FIFO"

verbose="${UT99_VERBOSE:-0}"
echo "Serving $DIR (read-only) via tailcat's files service."
echo "File-service tailcat key: ${TAILCAT_KEY:-<ephemeral>} (its own node; coexists with 'ut99 server')."
[ "$verbose" = 1 ] && echo "Verbose: friend file pulls are reported as they happen."
echo "Press Ctrl+C to stop serving."

# tailcat's output goes through a FIFO read by awk in the FOREGROUND:
# Ctrl+C kills awk (default INT), the INT trap then runs cleanup, which
# kills tailcat by pid.  A plain 'tailcat | awk' pipeline would instead
# orphan tailcat when the pipeline subshell dies.
tailcat_exec serve --files="$DIR" >"$FIFO" 2>&1 &
TAILCAT_PID=$!

# The awk:
#   - always: pass tailcat's own '#'-prefixed lines through; when its
#     'Server listening ... tcp...' address line appears, append the exact
#     fetch commands friends should paste (real address, no placeholders).
#   - quiet (default): tailcat's plain-serve output is only those lines.
#   - verbose (--verbose/-v or UT99_VERBOSE=1): tailcat also logs every
#     tunnel event (wireguard handshakes, STUN, netcheck).  Keep only the
#     file-service connection opens: 'Accept: TCP{... > ...:22} ... tcp ok',
#     one SYN per SFTP session — i.e. watch friends pulling files without
#     the wireguard/STUN noise.  tailcat logs no session-close line, so
#     each 'tcp ok' means a fetch starting.
awk -v v="$verbose" '
  {
    if (/listening with/ && !found) {
      for (i = 1; i <= NF; i++)
        if ($i ~ /^tcp[A-Za-z0-9_-]+$/) { addr = $i; found = 1 }
    }
    if (/Accept: TCP\{/) {
      if (v == 1 && $0 ~ /:22\}/ && $0 ~ /tcp ok/) {
        peer = $0
        sub(/.*Accept: TCP\{/, "", peer)
        sub(/ >.*/, "", peer)
        print "# friend connected from " peer " — pulling files"
        fflush()
      }
      next
    }
    if (v != 1 || /^#/) { print; fflush() }
    if (found && !cmds) {
      cmds = 1
      print "# Friends fetch with (while this runs):"
      print "#   Linux/macOS:  ./ut99 file-pull " addr " --deploy"
      print "#   Windows:      .\\ut99.cmd file-pull " addr " --deploy"
      print "# (no repo clone:  tailcat cp " addr ":ut99-wineprefix.tgz files/)"
      fflush()
    }
  }' <"$FIFO"

cleanup
