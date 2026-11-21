# SPDX-FileCopyrightText: 2026 spacegaucho
# SPDX-License-Identifier: GPL-3.0-or-later
# client-pull-files.ps1 -- Windows counterpart of client-pull-files.sh: fetch
# files from a host running 'ut99 file-serve' through tailcat's file service,
# verify the sha256, into files/ (default).
#
# tailcat cp drives scp through the tunnel, so you get scp's progress display
# (needs scp.exe -- the Windows OpenSSH client, an "Optional Feature" on
# Windows 10/11; ut99 deps tells you if it is missing).
# Remote paths are relative to the directory the host serves (default files/).
#
# The .sha256 is fetched first: if the local file already matches it, the
# (expensive) download is skipped -- re-running this script is cheap. --force
# re-fetches regardless.
#
# Note: the default ut99-wineprefix.tgz is a WINE prefix for Linux clients; a
# Windows player installs UT99 natively (OldUnreal 469) and uses file-pull for
# map/mod packages a host serves with --dir/--tgz.
#
# Usage:
#   .\client-pull-files.ps1 <tcp...>                    # -> ..\files\, verified
#   .\client-pull-files.ps1 <tcp...> --dir D:\downloads
#   .\client-pull-files.ps1 <tcp...> --tgz Mypack.7z --force
param(
  [Parameter(Position = 0)][string]$Address = "",
  [string]$Dir = "",
  [string]$Name = "ut99-wineprefix.tgz",
  [switch]$Force,
  [switch]$NoVerify,
  [switch]$Deploy
)

$ErrorActionPreference = "Stop"
. (Join-Path (Split-Path -Parent $PSScriptRoot) "helpers/ut99-env.ps1")

if (-not $Address) {
  $a = $args[0]
  if ($a -like "tc*") { $Address = $a }
}
if (-not $Address) {
  Write-Ut99Err "no tailcat address given: the host runs './ut99 file-serve' and gives you the tcp... address it prints."
  exit 2
}
if (-not $Dir) { $Dir = $env:UT99_FILE_PULL_DIR }
if ($Deploy) {
  Write-Ut99Err "--deploy extracts a WINE prefix for Linux clients; on Windows install OldUnreal 469 natively instead (see docs/windows.md). Dropping --deploy."
}

if (-not (Get-Command scp -ErrorAction SilentlyContinue) -and -not (Get-Command scp.exe -ErrorAction SilentlyContinue)) {
  Write-Ut99Err "scp not found -- tailcat cp needs it. Windows: Settings > Apps > Optional Features > add 'OpenSSH Client'."
  exit 1
}

New-Item -ItemType Directory -Path $Dir -Force | Out-Null
Write-Host "Pulling $Name from $Address"
Write-Host "  into:  $Dir"
Write-Host "  (tailcat cp = scp through the tunnel; Ctrl+C aborts, re-run to retry)"

$sumFile = Join-Path $Dir "$Name.sha256"

# Dialing a tailcat node we have not talked to yet can time out once
# ("Dial: context deadline exceeded") while the bootstrap warms up, so a
# failure is retried once -- the first pull after a host comes up is reliable.
function Invoke-TailcatCp([string[]]$cpArgs) {
  $rc = Invoke-Tailcat $cpArgs
  if ($rc -eq 0) { return 0 }
  Write-Ut99 "tailcat cp failed; retrying once in 2 s..."
  Start-Sleep -Seconds 2
  return (Invoke-Tailcat $cpArgs)
}

# Checksum file first: tiny, and it tells us whether a re-download is needed.
$haveSum = $false
if ((Invoke-TailcatCp @("cp", "${Address}:${Name}.sha256", "$Dir")) -eq 0 -and (Test-Path $sumFile)) {
  $haveSum = $true
} else {
  Write-Ut99Err "note: could not fetch $Name.sha256 (host has none?); will fetch and not verify"
}

function Test-SumMatches {
  if (-not $haveSum -or -not (Test-Path (Join-Path $Dir $Name)) -or -not (Test-Path $sumFile)) { return $false }
  $want = (Get-Content $sumFile -First 1) -split '\s+' | Select-Object -First 1
  $got = (Get-FileHash -Algorithm SHA256 (Join-Path $Dir $Name)).Hash.ToLower()
  $want -and ($want.ToLower() -eq $got)
}

if (-not $Force -and (Test-SumMatches)) {
  Write-Host "Up to date: $Dir\$Name already matches the host's checksum (--force to re-fetch)."
} else {
  $rc = Invoke-TailcatCp @("cp", "${Address}:${Name}", "$Dir")
  if ($rc -ne 0) { Write-Ut99Err "pull failed (exit $rc)"; exit $rc }
}

if (-not $NoVerify) {
  if ((Test-Path $sumFile) -and (Test-Path (Join-Path $Dir $Name))) {
    Write-Host "Verifying checksum..."
    if (Test-SumMatches) { Write-Host "OK" } else { Write-Ut99Err "CHECKSUM MISMATCH -- do not use $Dir\$Name"; exit 1 }
  } else {
    Write-Ut99Err "warning: no $Name.sha256 to check against -- checksum not verified"
  }
} else {
  Write-Host "Verification skipped (--no-verify)."
}

if (Test-Path (Join-Path $Dir $Name)) {
  $sizeMB = [math]::Round((Get-Item (Join-Path $Dir $Name)).Length / 1MB, 1)
  Write-Host "File: $sizeMB MB  $Dir\$Name"
}
