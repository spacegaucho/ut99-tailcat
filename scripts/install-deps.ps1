# SPDX-FileCopyrightText: 2026 spacegaucho
# SPDX-License-Identifier: GPL-3.0-or-later
# install-deps.ps1 — install what the Windows side of ut99-tailcat needs:
#   * tailcat.exe  (pinned release from the GitHub release page, into tools\)
#   * python       (runs scripts/ut99-bridge.py, the SAME relay the host runs;
#                   installed via winget when missing)
# and checks the rest: scp (OpenSSH Client, for tailcat cp / file-pull) and a
# native UT99 install (OldUnreal 469).
#
# tailcat is installed to <repo>\tools\tailcat.exe (set UT99_TOOLS_DIR to
# change, FORCE_UPDATE=1 to re-download even if it is already present).
#
# Usage: .\install-deps.ps1   (or:  .\ut99.cmd deps)
param()

$ErrorActionPreference = "Continue"
. (Join-Path (Split-Path -Parent $PSScriptRoot) "helpers/ut99-env.ps1")

$newShellHint = "open a new PowerShell window if a just-installed tool is not found"

function Install-Tailcat {
  if ($env:UT99_TAILCAT_BIN) {
    # An explicit override counts as installed unless you ask to update.
    if ($env:FORCE_UPDATE -ne "1" -and (Test-Path $env:UT99_TAILCAT_BIN)) {
      Write-Host "tailcat: using UT99_TAILCAT_BIN ($env:UT99_TAILCAT_BIN). Set FORCE_UPDATE=1 to install the pinned release into tools\ instead."
      return
    }
  } else {
    $cmd = Get-Command tailcat.exe -ErrorAction SilentlyContinue
    if (-not $cmd) { $cmd = Get-Command tailcat -ErrorAction SilentlyContinue }
    $local = Join-Path $env:UT99_TOOLS_DIR "tailcat.exe"
    if ($env:FORCE_UPDATE -ne "1") {
      if ($cmd) { Write-Host "tailcat: already installed ($($cmd.Source)). Set FORCE_UPDATE=1 to update."; return }
      if (Test-Path $local) { Write-Host "tailcat: already installed ($local). Set FORCE_UPDATE=1 to update."; return }
    }
  }

  $ver = $env:UT99_TAILCAT_VERSION
  $url = "https://github.com/tailscale/tailcat/releases/download/v$ver/tailcat_${ver}_windows_amd64.zip"
  Write-Host "Downloading tailcat v$ver for windows/amd64..."
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $stage = Join-Path ([System.IO.Path]::GetTempPath()) "ut99-tailcat-deps"
  New-Item -ItemType Directory -Path $stage -Force | Out-Null
  $zip = Join-Path $stage "tailcat.zip"
  try {
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
  } catch {
    Write-Ut99Err "download failed: $url"; return
  }
  $extract = Join-Path $stage "tailcat-$ver"
  if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }
  Expand-Archive -Path $zip -DestinationPath $extract -Force
  $exe = Get-ChildItem -Path $extract -Recurse -Filter "tailcat*.exe" | Select-Object -First 1
  if (-not $exe) { Write-Ut99Err "no tailcat*.exe inside the zip ($extract)"; return }
  New-Item -ItemType Directory -Path $env:UT99_TOOLS_DIR -Force | Out-Null
  Copy-Item $exe.FullName (Join-Path $env:UT99_TOOLS_DIR "tailcat.exe") -Force
  $env:Path = "$env:Path;$env:UT99_TOOLS_DIR"
  Write-Host "tailcat: installed $(Join-Path $env:UT99_TOOLS_DIR 'tailcat.exe') ($(& (Join-Path $env:UT99_TOOLS_DIR 'tailcat.exe') version 2>$null))"
}

function Install-Python {
  # @() matters: PowerShell flattens Get-PythonCommand's 1-element return.
  $py = @(Get-PythonCommand)
  if ($py.Count -gt 0 -and $py[0]) {
    Write-Host "python: found ($($py -join ' ')) — runs scripts/ut99-bridge.py"
    return
  }
  $winget = Get-Command winget -ErrorAction SilentlyContinue
  if (-not $winget) {
    Write-Ut99Err "python not found and winget is unavailable: install Python 3 from https://python.org (tick 'Add to PATH')."
    return
  }
  Write-Host "Installing Python 3 via winget..."
  winget install -e --id Python.Python.3 --accept-source-agreements --accept-package-agreements
  $py = @(Get-PythonCommand)
  if ($py.Count -gt 0 -and $py[0]) { Write-Host "python: installed ($($py -join ' '))" }
  else { Write-Ut99Err "python installed but not on PATH yet — $newShellHint" }
}

function Check-Scp {
  if ((Get-Command scp -ErrorAction SilentlyContinue) -or (Get-Command scp.exe -ErrorAction SilentlyContinue)) {
    Write-Host "scp: found (tailcat cp / file-pull works)"
  } else {
    Write-Ut99Err "scp not found — needed only for 'ut99 file-pull': Settings > Apps > Optional Features > add 'OpenSSH Client' (or: winget install Microsoft.OpenSSH.Beta)"
  }
}

function Check-Game {
  if (Test-UtGameInstall) {
    Write-Host "UT99: found $env:UT_DIR\UnrealTournament.exe"
  } else {
    Write-Ut99Err "UT99 not found at $env:UT_DIR — install the OldUnreal 469 full installer (https://oldunreal.com/download/, default target C:\UnrealTournament), or set UT_DIR to your install's System directory."
  }
}

Install-Tailcat
Install-Python
Check-Scp
Check-Game
Write-Host ""
Write-Host "Next:  .\ut99.cmd client <host's tcp... address>   # bridge + game"
Write-Host "       .\ut99.cmd client --config                  # pick renderer/audio device"
