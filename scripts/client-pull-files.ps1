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
# The default ut99-wineprefix.tgz is the host's whole game install packed as
# a WINE prefix -- but drive_c\UnrealTournament inside it is a complete NATIVE
# Windows tree (UnrealTournament.exe / UCC.exe, GOTY + OldUnreal 469: exactly
# what the Linux host runs under wine).  --deploy extracts just that tree, so
# a Windows friend without a game install can play right away; without
# --deploy the file is only downloaded.  Map/mod packs a host serves with
# --dir/--tgz are plain downloads: unpack those yourself into the game dirs.
#
# Usage:
#   .\client-pull-files.ps1 <tcp...>                    # -> ..\files\, verified
#   .\client-pull-files.ps1 <tcp...> --deploy           # + extract game tree
#   .\client-pull-files.ps1 <tcp...> --dir D:\downloads
#   .\client-pull-files.ps1 <tcp...> --tgz Mypack.7z --force
param(
  [Parameter(Position = 0)][string]$Address = "",
  [string]$Dir = "",
  [Alias("tgz")][string]$Name = "ut99-wineprefix.tgz",
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
if ($Deploy -and $Name -ne "ut99-wineprefix.tgz") {
  Write-Ut99 "note: --deploy applies to ut99-wineprefix.tgz (the host's game pack); --tgz packages are download-only. Skipping deploy."
  $Deploy = $false
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

# --deploy: turn the host's wine-prefix pack into a native Windows install.
# Only the drive_c\UnrealTournament subtree is extracted -- the rest of the
# prefix (dosdevices symlinks, drive_c\windows, registry hives) is wine
# plumbing that Windows has no use for.  Default target: the parent of
# UT_DIR, i.e. C:\UnrealTournament, so the default UT_DIR
# C:\UnrealTournament\System matches the extracted tree.  UT99_DEPLOY_DIR
# overrides the target.
if ($Deploy) {
  $tgz = Join-Path $Dir $Name
  if (-not (Test-Path $tgz)) { Write-Ut99Err "cannot deploy: $tgz is not there"; exit 1 }
  $target = $env:UT99_DEPLOY_DIR
  if (-not $target) { $target = Split-Path -Parent $env:UT_DIR }
  $sysExe = Join-Path (Join-Path $target "System") "UnrealTournament.exe"
  if ((Test-Path $sysExe) -and -not $Force) {
    Write-Ut99Err "refusing to deploy over an existing install: $sysExe already exists. If that is your game, just play (ut99 client); to replace it, re-run with --force."
    exit 1
  }
  if (-not (Get-Command tar -ErrorAction SilentlyContinue)) {
    Write-Ut99Err "tar not found -- Windows 10 1803+ ships tar.exe (bsdtar). Deploy needs it."
    exit 1
  }
  Write-Host "Deploying: extracting the native game tree into $target ..."
  New-Item -ItemType Directory -Path $target -Force | Out-Null
  # '*drive_c/UnrealTournament*' selects only the game tree; --strip-components=3
  # drops './drive_c/UnrealTournament' (bsdtar counts the leading '.'), so the
  # members land directly in $target: System\UnrealTournament.exe etc.
  $tarArgs = @("-xzf", $tgz, "-C", $target, "--strip-components=3")
  # desktop shortcuts in the pack point at the HOST's paths, which are useless
  # (and confusing) on the friend's machine, so they are not deployed.
  $tarArgs += "--exclude=*.lnk"
  # GNU tar needs --wildcards to honour a pattern; Windows' built-in tar.exe is
  # bsdtar, which matches patterns by default and REJECTS --wildcards.  Only a
  # GNU tar on PATH (e.g. from Git for Windows) needs the extra flag.
  $tarFlavour = ((& tar --version 2>$null) | Select-Object -First 1)
  if ($tarFlavour -match "GNU tar") { $tarArgs = @("--wildcards") + $tarArgs }
  & tar @tarArgs '*drive_c/UnrealTournament*'
  if ($LASTEXITCODE -ne 0) { Write-Ut99Err "tar extraction failed (exit $LASTEXITCODE)"; exit 1 }
  if (-not (Test-Path $sysExe)) {
    Write-Ut99Err "extracted, but $sysExe is missing -- is $Name a real ut99 pack from './ut99 pack'?"
    exit 1
  }
  Write-Host "Deployed: play with  .\ut99.cmd client <tcp...>   (renderer/audio trouble: .\ut99.cmd client --config)"
}
