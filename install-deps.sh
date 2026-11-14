#!/usr/bin/env bash
# install-deps.sh — install what ut99-socat-tailcat needs:
#   * socat   (Arch Linux: via pacman; other distros: manual, with a hint)
#   * tailcat (latest linux binary from the GitHub release, verified with sha256)
#
# tailcat is installed to ~/.local/bin (set INSTALL_BIN_DIR to change,
# FORCE_UPDATE=1 to re-download even if tailcat is already present).
set -euo pipefail

INSTALL_BIN_DIR="${INSTALL_BIN_DIR:-$HOME/.local/bin}"
FORCE_UPDATE="${FORCE_UPDATE:-0}"

err() { echo "install-deps: $*" >&2; }

# --- socat ---
if command -v socat >/dev/null 2>&1; then
  echo "socat: already installed ($(command -v socat))"
elif command -v pacman >/dev/null 2>&1; then
  echo "Installing socat via pacman (needs sudo)..."
  sudo pacman -S --noconfirm --needed socat
else
  err "socat is missing and pacman was not found."
  err "Install it with your distro's package manager (Debian/Ubuntu: apt install socat, Fedora: dnf install socat)."
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
