#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 spacegaucho
# SPDX-License-Identifier: GPL-3.0-or-later
# client-pull-files.sh — client side of host-serve-files.sh: fetch the packed
# wine prefix tarball (+ its .sha256) from a host's tailcat file service,
# verify the checksum, and optionally deploy it.
#
# tailcat cp drives the system scp through the tunnel, so you get scp's
# progress display; remote paths are relative to the directory the host
# serves (default: the host's files/).
#
# The .sha256 is fetched first: if the local tarball already matches it, the
# (expensive) download is skipped — re-running this script is cheap. --force
# re-fetches regardless.
#
# Usage:
#   ./client-pull-files.sh <tcp...>                    # -> ../files/, verified
#   ./client-pull-files.sh <tcp...> --dir ~/Downloads  # somewhere else
#   ./client-pull-files.sh <tcp...> --deploy           # pull + verify + extract
#   ./client-pull-files.sh <tcp...> --force            # ignore a cached copy
#   UT99_FILE_PULL_DIR=~/Downloads ./client-pull-files.sh <tcp...>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../helpers/ut99-env.sh"

usage() {
  cat <<'EOF'
client-pull-files.sh <tcp...> [--dir DIR] [--tgz NAME] [--force] [--no-verify] [--deploy]
  <tcp...>        the host's `file-serve` address (NOT its game-bridge address)
  --dir DIR       local directory to pull into (default: this repo's files/)
  --tgz NAME      served tarball name (default ut99-wineprefix.tgz; the
                  .sha256 is that name with .sha256 appended)
  --force         re-download even when the local copy already matches
  --no-verify     skip the sha256 check
  --deploy        run client-deploy-prefix.sh on the pulled tarball
EOF
}

ADDR=""
DIR="${UT99_FILE_PULL_DIR:-$SCRIPT_DIR/../files}"
NAME="ut99-wineprefix.tgz"
verify=1 force=0 deploy=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir)       DIR="$2"; shift 2 ;;
    --tgz)       NAME="$2"; shift 2 ;;
    --force)     force=1; shift ;;
    --no-verify) verify=0; shift ;;
    --deploy)    deploy=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    tc*)         ADDR="$1"; shift ;;
    *) echo "Error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$ADDR" ]; then
  echo "Error: no tailcat address given: the host runs './ut99 file-serve' and" >&2
  echo "       gives you the tcp... address it prints." >&2
  usage >&2
  exit 2
fi
require_cmd tailcat scp || exit 1

# tailcat cp: the system scp does the transfer, routed through tailcat.
# Dialing a tailcat node we have not talked to yet can time out once
# ("Dial: context deadline exceeded") while the bootstrap warms up, so a
# failure is retried once — the first pull after a host comes up is reliable.
tc_cp() {
  if [ -n "$TAILCAT_KEY" ]; then
    tailcat --key "$TAILCAT_KEY" cp "$@" && return 0
  else
    tailcat cp "$@" && return 0
  fi
  echo "tailcat cp failed; retrying once in 2 s..." >&2
  sleep 2
  if [ -n "$TAILCAT_KEY" ]; then
    tailcat --key "$TAILCAT_KEY" cp "$@"
  else
    tailcat cp "$@"
  fi
}

mkdir -p "$DIR"
echo "Pulling $NAME from $ADDR"
echo "  into:  $DIR"
echo "  (tailcat cp = scp through the tunnel; Ctrl+C aborts, re-run to retry)"

# Checksum file first: tiny, and it tells us whether a re-download is needed.
have_sum=0
if tc_cp "$ADDR:$NAME.sha256" "$DIR/"; then
  have_sum=1
else
  echo "Note: could not fetch $NAME.sha256 (host has none?); will fetch and not verify." >&2
fi

sum_matches() {   # local tarball already equals what the host advertises
  [ "$have_sum" = 1 ] && [ -f "$DIR/$NAME" ] && [ -f "$sha_file" ] || return 1
  local want got
  want="$(awk 'NR==1{print $1; exit}' "$sha_file")"
  got="$(sha256sum "$DIR/$NAME" | awk '{print $1}')"
  [ -n "$want" ] && [ "$want" = "$got" ]
}
sha_file="$DIR/$NAME.sha256"

if [ "$force" != 1 ] && sum_matches; then
  echo "Up to date: $DIR/$NAME already matches the host's checksum (--force to re-fetch)."
else
  tc_cp "$ADDR:$NAME" "$DIR/"
fi

if [ "$verify" = 1 ]; then
  if [ -f "$sha_file" ] && command -v sha256sum >/dev/null 2>&1; then
    echo "Verifying checksum..."
    ( cd "$DIR" && sha256sum -c "$(basename "$sha_file")" )
  else
    echo "Warning: no $NAME.sha256 to check against — checksum not verified." >&2
  fi
else
  echo "Verification skipped (--no-verify)."
fi

ls -lh "$DIR/$NAME" | awk '{print "Tarball: "$5"  "$NF}'

if [ "$deploy" = 1 ]; then
  echo
  export UT99_PREFIX_TGZ="$DIR/$NAME"
  exec "$SCRIPT_DIR/client-deploy-prefix.sh"
fi

echo
echo "Next:  ./ut99 deploy        # verify + extract into WINEPREFIX"
echo "       ./ut99 client <host bridge tcp... address>   # then play"
