#!/usr/bin/env bash
# host-serve-files.sh — serve the packed wine prefix tarball (+ its .sha256)
# over tailcat's built-in file service, so friends can pull it with
# `tailcat cp` — no web server, no ports, no accounts.
#
# tailcat's files service is an SFTP-style server rooted at one directory
# (read-only by default); the friend's side uses the system scp under the
# hood, so they get progress bars and resume-friendly copies.
#
# Usage:
#   ./host-serve-files.sh                       # serve ./files (repo default)
#   ./host-serve-files.sh ~/share               # serve another directory
#   UT99_FILE_SERVE_DIR=~/share ./host-serve-files.sh
#   (wrapper form: ./ut99 file-serve [DIR] [--dir DIR] [--tc-key NAME])
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../helpers/ut99-env.sh"

DIR="${1:-${UT99_FILE_SERVE_DIR:-$SCRIPT_DIR/../files}}"
if [ ! -d "$DIR" ]; then
  echo "Error: $DIR is not a directory. Pack first: ./ut99 pack" >&2
  exit 1
fi
require_cmd tailcat || exit 1
start_job_trap

if [ ! -f "$DIR/ut99-wineprefix.tgz" ]; then
  echo "Warning: no ut99-wineprefix.tgz in $DIR — pack it first (./ut99 pack)." >&2
  echo "Serving the directory as-is." >&2
fi

echo "Serving $DIR (read-only) via tailcat's files service."
echo "File-service tailcat key: ${TAILCAT_KEY:-<ephemeral>} (its own node; coexists with 'ut99 server')."
echo "Copy the 'tcp...' address printed below and give it to your friends."
echo
echo "Friend side, in their own clone/copy of this repo (fetch + verify + deploy):"
echo "  ./ut99 deps                        # installs tailcat if missing"
echo "  mkdir -p files"
echo "  tailcat cp <tcp...>:ut99-wineprefix.tgz files/"
echo "  tailcat cp <tcp...>:ut99-wineprefix.tgz.sha256 files/"
echo "  ./ut99 deploy                      # checksum + extract into WINEPREFIX"
echo
echo "Press Ctrl+C to stop serving."

# tailcat_exec execs tailcat, so this job IS the tailcat process. tailcat
# ignores SIGTERM; start_job_trap escalates to SIGKILL, so Ctrl+C cleans up.
tailcat_exec serve --files="$DIR" &
wait
