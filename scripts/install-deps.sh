#!/usr/bin/env bash
# install-deps.sh — install what ut99-tailcat needs:
#   * tailcat (latest linux binary from the GitHub release, verified with sha256)
#   * python3 (runs the datagram-framed UDP<->TCP relay, scripts/ut99-bridge.py)
#   * wine    (checked only, never auto-installed: runs the 32-bit Windows
#             game binaries, UCC.exe / UnrealTournament.exe)
#
# tailcat is installed to ~/.local/bin (set INSTALL_BIN_DIR to change,
# FORCE_UPDATE=1 to re-download even if tailcat is already present).
set -euo pipefail

INSTALL_BIN_DIR="${INSTALL_BIN_DIR:-$HOME/.local/bin}"
FORCE_UPDATE="${FORCE_UPDATE:-0}"

err() { echo "install-deps: $*" >&2; }

# --- python3 (bridge relay) ---
if command -v python3 >/dev/null 2>&1; then
  echo "python3: already installed ($(command -v python3))"
elif command -v pacman >/dev/null 2>&1; then
  echo "Installing python via pacman (needs sudo)..."
  sudo pacman -S --noconfirm --needed python
else
  err "python3 is missing and pacman was not found."
  err "Install it with your distro's package manager (Debian/Ubuntu: apt install python3, Fedora: dnf install python3)."
  exit 1
fi

# --- wine (check only: runs UCC.exe / UnrealTournament.exe) ---
WINE_BIN="${WINE_BIN:-wine}"
if command -v "$WINE_BIN" >/dev/null 2>&1; then
  echo "wine: found ($WINE_BIN -> $(command -v "$WINE_BIN"), $("$WINE_BIN" --version 2>/dev/null || echo version unknown))"
  # wine without the GL loader libs starts but runs with OpenGL disabled:
  # wined3d gets no context and 469's D3D11Drv.dll fails to import (d3d11.dll
  # "not found") -> instant crash.  Catch that here (skip where ldconfig is absent).
  if command -v ldconfig >/dev/null 2>&1; then
    gl_missing=""
    for lib in libGL.so.1 libEGL.so.1; do
      ldconfig -p 2>/dev/null | grep -qE "(^|[[:space:]])${lib} \(libc6" || gl_missing="$gl_missing $lib"
    done
    if [ -n "$gl_missing" ]; then
      err "GL loader libs missing:$gl_missing — wine would run with OpenGL disabled and the game would crash."
      err "Ubuntu/Debian: sudo apt install libgl1 libegl1 libgl1-mesa-dri"
      err "Arch:          sudo pacman -S mesa"
      err "Fedora:        sudo dnf install mesa-libGL mesa-libEGL mesa-dri-drivers"
      exit 1
    fi
    # 469 is a 32-bit app: unless the wine build does its WoW64 graphics work
    # in a 64-bit host process, wined3d dlopens the 32-bit libGL/libEGL.  apt
    # calls the 64-bit copies "already the newest version" — check for 32-bit
    # entries too (ldconfig marks them "(libc6)", 64-bit ones "(libc6,x86-64)").
    gl32=""
    for lib in libGL.so.1 libEGL.so.1; do
      ldconfig -p 2>/dev/null | grep -qE "(^|[[:space:]])${lib} \(libc6\)" || gl32="$gl32 $lib"
    done
    if [ -n "$gl32" ]; then
      echo "warning: no 32-bit entries for:$gl32 in ldconfig — 469 is a 32-bit app and may crash"
      echo "         ('Failed to load libGL', 'd3d11.dll ... not found') without them."
      echo "         Ubuntu/Debian: sudo dpkg --add-architecture i386 && sudo apt update &&"
      echo "                        sudo apt install libgl1:i386 libegl1:i386 libgl1-mesa-dri:i386"
    fi
  fi
else
  err "wine not found (checked for '$WINE_BIN' in PATH)."
  err "UT99 469 ships 32-bit Windows binaries, so wine is required to run the game."
  err "Install examples:"
  err "  Ubuntu/Debian: sudo dpkg --add-architecture i386 && sudo apt update && sudo apt install wine64 wine32:i386"
  err "                 (wine32:i386 matters: 469 is a 32-bit binary)"
  err "  Arch:          sudo pacman -S wine"
  err "  Fedora:        sudo dnf install wine"
  err "Or point at an existing non-system wine (Lutris/Proton) instead:"
  err "  WINE_BIN=/path/to/wine ./ut99 deps"
  exit 1
fi

# --- tailcat ---
if command -v tailcat >/dev/null 2>&1 && [ "$FORCE_UPDATE" != "1" ]; then
  echo "tailcat: already installed ($(command -v tailcat), $(tailcat version 2>/dev/null || echo version unknown)). Set FORCE_UPDATE=1 to update."
else
  case "$(uname -m)" in
    x86_64)          tc_arch=amd64 ;;
    aarch64|arm64)   tc_arch=arm64 ;;
    armv7l|armhf)    tc_arch=armv7 ;;
    *) err "unsupported CPU architecture: $(uname -m)"; exit 1 ;;
  esac

  api_json="$(curl -fsSL https://api.github.com/repos/tailscale/tailcat/releases/latest)" \
    || { err "could not fetch tailcat release info from GitHub"; exit 1; }
  dl_url="$(printf '%s\n' "$api_json" | grep -oE 'https://github\.com/[^"]*tailcat_[0-9.]+_linux_'"${tc_arch}"'\.tar\.gz' | head -1)"
  [ -n "$dl_url" ] || { err "no linux ${tc_arch} tar.gz found in the latest tailcat release"; exit 1; }

  tmp="$(mktemp -d /tmp/opencode/tailcat-install.XXXXXX)"
  trap 'rm -rf "$tmp"' EXIT

  echo "Downloading $dl_url"
  curl -fsSL -o "$tmp/tailcat.tar.gz" "$dl_url"

  # Verify against the release checksums when available.
  if curl -fsSL -o "$tmp/checksums.txt" "${dl_url%/*}/checksums.txt" 2>/dev/null \
     && line="$(grep -E "tailcat_[0-9.]+_linux_${tc_arch}\.tar\.gz\$" "$tmp/checksums.txt" | head -1)"; then
    want="$(printf '%s\n' "$line" | awk '{print $1}')"
    got="$(sha256sum "$tmp/tailcat.tar.gz" | awk '{print $1}')"
    if [ "$want" = "$got" ]; then
      echo "sha256 checksum OK"
    else
      err "checksum mismatch! expected $want got $got"
      exit 1
    fi
  else
    echo "warning: could not fetch checksums.txt, skipping verification" >&2
  fi

  tar -xzf "$tmp/tailcat.tar.gz" -C "$tmp"
  bin="$(find "$tmp" -type f -name tailcat | head -1)"
  [ -n "$bin" ] || { err "tailcat binary not found inside the archive"; exit 1; }

  mkdir -p "$INSTALL_BIN_DIR"
  install -m 0755 "$bin" "$INSTALL_BIN_DIR/tailcat"
  echo "tailcat: installed to $INSTALL_BIN_DIR/tailcat ($("$INSTALL_BIN_DIR/tailcat" version 2>/dev/null || echo version unknown))"
fi

echo "Done. Dependencies OK."
