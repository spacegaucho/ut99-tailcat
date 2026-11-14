#!/usr/bin/env bash
# host-pack-prefix.sh — pack the UT99 wine prefix into a portable tarball so
# friends can deploy a ready-to-play install instead of installing the game.
#
# Creates:  files/ut99-wineprefix.tgz  (+ .sha256 next to it)
# Friend-side deploy: ./client-deploy-prefix.sh
#
# The game data (.u/.uz/.umx) is already compressed, so the tgz shrinks the
# prefix only modestly. What saves space are the excludes below (each is
# unused by the game or regenerated automatically):
#   drive_c/UT436                          ~100M  leftover 436 backup copy
#   drive_c/windows/mono                   ~228M  .NET runtime, UT99 never uses it
#   drive_c/windows/Installer              ~80M   MSI package caches
#   drive_c/users/*/.../INetCache          ~83M   wine-gecko download cache
#   UnrealTournament/{Installer,GLCache,Logs,*.log,Running.ini}  caches/logs/crash-marker
#
# Usage:
#   ./host-pack-prefix.sh
#   UT99_PACK_OUT=~/share/ut99-wineprefix.tar.xz ./host-pack-prefix.sh
#   UT99_PACK_KEEP=mono,UT436 ./host-pack-prefix.sh   # re-include some excludes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../helpers/ut99-env.sh"

OUT="${UT99_PACK_OUT:-$SCRIPT_DIR/../files/ut99-wineprefix.tgz}"

require_cmd tar || exit 1
if [ ! -d "$WINEPREFIX/drive_c" ] || [ ! -f "$WINEPREFIX/system.reg" ]; then
  echo "Error: $WINEPREFIX does not look like a wine prefix (no drive_c/system.reg)." >&2
  echo "Set WINEPREFIX to the game's wine prefix." >&2
  exit 1
fi
if ! find_ci "$UT_DIR" UnrealTournament.exe >/dev/null; then
  echo "Error: UnrealTournament.exe not found in $UT_DIR — wrong prefix?" >&2
  exit 1
fi
if [ -f "$UT_DIR/Running.ini" ]; then
  echo "Warning: $UT_DIR/Running.ini exists — the game/server appears to be running." >&2
  echo "The marker is excluded from the pack, but pack a stopped game for a" >&2
  echo "consistent copy (avoids files changing while they are read)." >&2
fi

keep=",${UT99_PACK_KEEP:-},"
excludes=()
add_exclude() {           # add_exclude <name> <path-pattern...>
  local name="$1"; shift
  case "$keep" in
    *",${name},"*) echo "Keeping $name (UT99_PACK_KEEP)"; return ;;
  esac
  excludes+=(--exclude="$1")
}
add_exclude mono            './drive_c/windows/mono'
add_exclude UT436           './drive_c/UT436'
add_exclude win_installer   './drive_c/windows/Installer'
add_exclude inetcache       './drive_c/users/*/AppData/Local/Microsoft/Windows/INetCache'
add_exclude ut_installer    './drive_c/UnrealTournament/Installer'
add_exclude glcache         './drive_c/UnrealTournament/GLCache'
add_exclude ut_logs         './drive_c/UnrealTournament/Logs'
add_exclude ut_logs         './drive_c/UnrealTournament/*.log'
add_exclude running_ini     './drive_c/UnrealTournament/System/Running.ini'

echo "Packing wine prefix: $WINEPREFIX"
echo "Output:              $OUT   (compression is picked from the file name)"
echo "Excluded: ${#excludes[@]} patterns — this takes a few minutes on ~1.8G..."

# -a: auto-compress by suffix (.tgz/.tar.gz -> gzip, .tar.xz -> xz, ...).
# Members are stored relative (./drive_c/...), so the prefix is relocatable:
# the friend extracts it into whatever WINEPREFIX they choose.
mkdir -p "$(dirname "$OUT")"
tar -C "$WINEPREFIX" -capf "$OUT" "${excludes[@]}" .

# sha256 with a bare filename inside the .sha256, so `sha256sum -c` works
# wherever the friend places the tarball (client-deploy-prefix.sh does this).
( cd "$(dirname "$OUT")" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256" )

echo
echo "Done:"
du -h "$OUT" | sed 's/^/  tarball:  /'
du -sh "$WINEPREFIX" | sed 's/^/  prefix:   /'
echo "  checksum: $OUT.sha256"
echo
echo "Send both files to your friends (any file host/scp/python http.server)."
echo "They then run:  ./client-deploy-prefix.sh   # extracts into their WINEPREFIX"
