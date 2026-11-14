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
# Player name scrubbing: the packed copy of System/User.ini gets
# [DefaultPlayer] Name=<UT99_PACK_SCRUB_TO, default "Player">, and
# BestPlayers[]/Saves[] entries referencing the host's own name are dropped
# (host-specific records that would only confuse a friend's install). Key
# bindings, video/audio settings and everything else in User.ini are kept,
# and your live prefix is never touched — the original User.ini is excluded
# from the archive and the scrubbed copy is spliced in. Set
# UT99_PACK_SCRUB_TO='' to pack the name as-is.
#
# Usage:
#   ./host-pack-prefix.sh
#   UT99_PACK_OUT=~/share/ut99-wineprefix.tar.xz ./host-pack-prefix.sh
#   UT99_PACK_KEEP=mono,UT436 ./host-pack-prefix.sh   # re-include some excludes
#   UT99_PACK_SCRUB_TO=Player ./host-pack-prefix.sh   # scrub target name
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

# Player name scrubbing (see header): only meaningful if User.ini actually
# carries a personal name.
user_ini="$WINEPREFIX/drive_c/UnrealTournament/System/User.ini"
scrub_to="${UT99_PACK_SCRUB_TO-Player}"
scrub_name=""
if [ -n "$scrub_to" ]; then
  scrub_name="$(ini_get "$user_ini" DefaultPlayer Name)"
  [ "$scrub_name" = "$scrub_to" ] && scrub_name=""
fi

echo "Packing wine prefix: $WINEPREFIX"
echo "Output:              $OUT   (compression is picked from the file name)"
echo "Excluded: ${#excludes[@]} patterns — this takes a few minutes on ~1.8G..."
if [ -n "$scrub_name" ]; then
  echo "Scrubbing: [DefaultPlayer] Name=$scrub_name -> $scrub_to (User.ini in the"
  echo "           archive only; your live prefix is untouched; settings kept)"
fi

mkdir -p "$(dirname "$OUT")"
if [ -n "$scrub_name" ]; then
  # Two passes into an intermediate uncompressed tar (tar -r cannot append to
  # a compressed archive), then compress. The original User.ini is excluded
  # everywhere, so the personal name never enters the archive at all.
  member='./drive_c/UnrealTournament/System/User.ini'
  scrub_dir="$(mktemp -d "${TMPDIR:-/tmp}/ut99-scrub-XXXXXX")"
  tmp_tar="${OUT}.tmp.$$"
  trap 'rm -rf "$scrub_dir" "$tmp_tar"' EXIT
  mkdir -p "$scrub_dir/drive_c/UnrealTournament/System"
  awk -v name="$scrub_name" -v repl="$scrub_to" '
    {
      line = $0; sub(/\r$/, "", line)
      if (line ~ /^\[/) { insec = (line == "[DefaultPlayer]") }
      if (insec && line ~ /^Name=/) { print "Name=" repl "\r"; next }
      if ((line ~ /^BestPlayers\[[0-9]+\]=/ || line ~ /^Saves\[[0-9]+\]=/) && index(line, name) > 0) next
      print
    }
  ' "$user_ini" > "$scrub_dir/drive_c/UnrealTournament/System/User.ini"

  tar -C "$WINEPREFIX" -cf "$tmp_tar" "${excludes[@]}" --exclude="$member" .
  tar -rf "$tmp_tar" -C "$scrub_dir" "$member"

  # Mirror tar -a's suffix -> compressor mapping.
  case "$OUT" in
    *.tar.gz|*.tgz)   gzip -c  "$tmp_tar" > "$OUT" ;;
    *.tar.xz|*.txz)   xz -c    "$tmp_tar" > "$OUT" ;;
    *.tar.zst|*.tzst) zstd -q  "$tmp_tar" -o "$OUT" ;;
    *.tar)            mv "$tmp_tar" "$OUT"; tmp_tar="" ;;
    *) echo "Error: unsupported archive suffix in $OUT (use .tar/.tgz/.tar.gz/.tar.xz)." >&2; exit 1 ;;
  esac
  rm -f "$tmp_tar"
else
  # -a: auto-compress by suffix (.tgz/.tar.gz -> gzip, .tar.xz -> xz, ...).
  # Members are stored relative (./drive_c/...), so the prefix is relocatable:
  # the friend extracts it into whatever WINEPREFIX they choose.
  tar -C "$WINEPREFIX" -capf "$OUT" "${excludes[@]}" .
fi

# sha256 with a bare filename inside the .sha256, so `sha256sum -c` works
# wherever the friend places the tarball (client-deploy-prefix.sh does this).
( cd "$(dirname "$OUT")" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256" )

echo
echo "Done:"
du -h "$OUT" | sed 's/^/  tarball:  /'
du -sh "$WINEPREFIX" | sed 's/^/  prefix:   /'
echo "  checksum: $OUT.sha256"
echo
echo "Send both files to your friends (any file host/scp/python http.server),"
echo "or serve them straight from this repo over tailcat:  ./ut99 file-serve"
echo "They then run:  ./client-deploy-prefix.sh   # extracts into their WINEPREFIX"
