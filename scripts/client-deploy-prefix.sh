#!/usr/bin/env bash
# client-deploy-prefix.sh — unpack a ut99-wineprefix tarball into a fresh
# WINEPREFIX so a client can immediately run the bridges and join a game.
#
# Looks for the tarball in ../files/ut99-wineprefix.tgz, or at the
# path given in UT99_PREFIX_TGZ. A matching .sha256 is verified automatically
# when present. The tarball stores paths relative to the prefix root, so it
# extracts fine under any directory/user name.
#
# Usage:
#   ./client-deploy-prefix.sh
#   WINEPREFIX=~/wine/ut99 ./client-deploy-prefix.sh
#   UT99_PREFIX_TGZ=~/Downloads/ut99-wineprefix.tgz ./client-deploy-prefix.sh
#   UT99_DEPLOY_FORCE=1 ./client-deploy-prefix.sh    # extract over an existing prefix
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../helpers/ut99-env.sh"

TGZ="${UT99_PREFIX_TGZ:-$SCRIPT_DIR/../files/ut99-wineprefix.tgz}"

require_cmd tar || exit 1

if [ ! -f "$TGZ" ]; then
  echo "Error: tarball not found: $TGZ" >&2
  echo "Download ut99-wineprefix.tgz (plus its .sha256) from your host friend," >&2
  echo "place it next to these scripts, or set UT99_PREFIX_TGZ=/path/to/file." >&2
  exit 1
fi

if [ -d "$WINEPREFIX" ] && [ -n "$(ls -A "$WINEPREFIX" 2>/dev/null)" ]; then
  if [ "${UT99_DEPLOY_FORCE:-0}" != "1" ]; then
    echo "Refusing to deploy: WINEPREFIX=$WINEPREFIX already exists and is not empty." >&2
    echo "Options:" >&2
    echo "  WINEPREFIX=~/wine/ut99-friend ./client-deploy-prefix.sh   # fresh prefix" >&2
    echo "  UT99_DEPLOY_FORCE=1 ./client-deploy-prefix.sh             # extract on top of it" >&2
    exit 1
  fi
  echo "UT99_DEPLOY_FORCE=1: extracting on top of the existing prefix (files are overwritten)."
fi

if [ -f "$TGZ.sha256" ]; then
  if command -v sha256sum >/dev/null 2>&1; then
    echo "Verifying checksum..."
    ( cd "$(dirname "$TGZ")" && sha256sum -c "$(basename "$TGZ").sha256" )
  else
    echo "Warning: $TGZ.sha256 present but sha256sum not found; skipping verification." >&2
  fi
fi

echo "Extracting $TGZ -> $WINEPREFIX (a few minutes)..."
mkdir -p "$WINEPREFIX"
tar -xpf "$TGZ" -C "$WINEPREFIX"

# Sanity-check the deployed prefix
fail=0
# (wine.inf is not part of modern prefixes — it lives with the wine build)
for f in system.reg user.reg drive_c/windows/system32/kernel32.dll; do
  if [ ! -e "$WINEPREFIX/$f" ]; then
    echo "Error: $WINEPREFIX/$f missing after extraction — bad tarball?" >&2
    fail=1
  fi
done
UT_DIR="$WINEPREFIX/drive_c/UnrealTournament/System"
if ! find_ci "$UT_DIR" UnrealTournament.exe >/dev/null; then
  echo "Error: drive_c/UnrealTournament/System/UnrealTournament.exe missing — bad tarball?" >&2
  fail=1
fi
if [ "$fail" != 0 ]; then
  echo "The partially extracted prefix is incomplete — remove $WINEPREFIX before retrying." >&2
  exit 1
fi

rm -f "$UT_DIR/Running.ini"   # never start a game with a stale crash-marker

cat <<EOF

Deployed OK: $WINEPREFIX
  Game:    $UT_DIR
  Wine:    a recent wine is recommended (prefix was created with wine 11.x)

Play now (bridges must already be running on the host side):
  ./client-start-bridge.sh <tc... address from your host>
  ./client-start-ut99.sh            # auto-joins 127.0.0.1:\${UT_UDP_PORT:-7777}
EOF
