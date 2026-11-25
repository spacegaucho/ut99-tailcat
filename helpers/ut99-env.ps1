# SPDX-FileCopyrightText: 2026 spacegaucho
# SPDX-License-Identifier: GPL-3.0-or-later
# ut99-env.ps1 -- shared configuration and helpers for the Windows (PowerShell)
# side of ut99-tailcat. Dot-sourced by ut99.ps1 and by the scripts/*.ps1.
#
# This mirrors helpers/ut99-env.sh: every value can be overridden through the
# environment, e.g.
#   $env:UT_UDP_PORT = "7778"; .\ut99.cmd client tcpXXXX
#   .\ut99.cmd client tcpXXXX --port 7778      (flags map onto the same vars)
#
# Defaults assume a native Windows install of UT99 (OldUnreal 469, whose
# installer defaults to C:\UnrealTournament).  On Windows the client needs
# exactly three things: tailcat.exe, python.exe (scripts/ut99-bridge.py is the
# SAME relay both sides run), and the game itself.  `ut99 deps` installs the
# first two.

# --- UT99 install ------------------------------------------------------------
# System directory of the native Windows install (469 installer default).
$script:UT99EnvRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $script:UT99EnvRoot) { $script:UT99EnvRoot = (Get-Location).Path }

if (-not $env:UT_DIR) { $env:UT_DIR = "C:\UnrealTournament\System" }
if (-not $env:UT99_TOOLS_DIR) { $env:UT99_TOOLS_DIR = Join-Path $script:UT99EnvRoot "tools" }

# --- Ports --------------------------------------------------------------------
if (-not $env:UT_UDP_PORT)         { $env:UT_UDP_PORT = "7777" }
if (-not $env:BRIDGE_TCP_PORT)     { $env:BRIDGE_TCP_PORT = "8777" }   # local TCP to tailcat
if (-not $env:HOST_BRIDGE_TCP_PORT){ $env:HOST_BRIDGE_TCP_PORT = "8777" } # host's serve port
if (-not $env:UT99_ADMIN_LOCAL)    { $env:UT99_ADMIN_LOCAL = "18080" }
if (-not $env:UT99_HOST_ADMIN_PORT){ $env:UT99_HOST_ADMIN_PORT = "8887" }

# --- tailcat -------------------------------------------------------------------
# Stable key name (same name as on the Linux side; each machine keeps its own
# private key locally, only the public tcp... address is shared).
if (-not $env:TAILCAT_KEY) { $env:TAILCAT_KEY = "ut99" }

# --- client behaviour -----------------------------------------------------------
if (-not $env:UT_AUTOJOIN)  { $env:UT_AUTOJOIN = "1" }
if (-not $env:UT99_LOG)     { $env:UT99_LOG = "1" }
if (-not $env:UT_SHOW_CONFIG){ $env:UT_SHOW_CONFIG = "0" }
if (-not $env:UT99_FILE_PULL_DIR) { $env:UT99_FILE_PULL_DIR = Join-Path $script:UT99EnvRoot "files" }

# tailcat release this project is pinned to (matches the tested host side).
if (-not $env:UT99_TAILCAT_VERSION) { $env:UT99_TAILCAT_VERSION = "0.7.0" }

# --- small helpers ---------------------------------------------------------------

function Write-Ut99([string]$msg) { Write-Host "ut99: $msg" }
function Write-Ut99Err([string]$msg) { Write-Host "ut99: $msg" -ForegroundColor Yellow }

# Get-TailcatPath -- find tailcat.exe: UT99_TAILCAT_BIN as an explicit
# override first, then PATH, then UT99_TOOLS_DIR (where deps installs it).
function Get-TailcatPath {
  if ($env:UT99_TAILCAT_BIN) {
    if (Test-Path $env:UT99_TAILCAT_BIN) { return $env:UT99_TAILCAT_BIN }
    Write-Ut99Err "UT99_TAILCAT_BIN set but not found: $env:UT99_TAILCAT_BIN"
    return $null
  }
  $cmd = Get-Command tailcat.exe -ErrorAction SilentlyContinue
  if (-not $cmd) { $cmd = Get-Command tailcat -ErrorAction SilentlyContinue }
  if ($cmd) { return $cmd.Source }
  $local = Join-Path $env:UT99_TOOLS_DIR "tailcat.exe"
  if (Test-Path $local) {
    # extend this session's PATH so inline `tailcat ...` calls work too
    $env:Path = "$env:Path;$env:UT99_TOOLS_DIR"
    return $local
  }
  Write-Ut99Err "tailcat not found (PATH or $env:UT99_TOOLS_DIR). Run: .\ut99.cmd deps"
  return $null
}

# python_command -- resolve the python that runs ut99-bridge.py (python /
# python3 / py -3, or UT99_PYTHON override).  Returns an array: exe + leading args.
# Two Windows traps make a plain "Get-Command python3 succeeds" test useless:
#   * Microsoft Store "app execution aliases": python.exe / python3.exe stubs
#     in %LOCALAPPDATA%\Microsoft\WindowsApps sit ON PATH near the front, even
#     after a real python is installed (winget/python.org add python.exe and
#     never remove the aliases).  A stub "exists", and running it prints a
#     Store advertisement and exits non-zero.
#   * Because of that, only the FIRST match of a name is a stub: the real
#     interpreter is the second match of the same name, further down PATH --
#     so Get-Command needs -All, not just the first hit.
# Hence: enumerate every match and VERIFY each by actually running --version.
# Only candidates that really report "Python 3.x" are returned (as their full
# path, which also dodges the alias entirely).
function Test-PythonCandidate([string[]]$cand) {
  if (-not $cand -or $cand.Count -eq 0) { return $false }
  $exe = $cand[0]
  $tail = @()
  if ($cand.Count -gt 1) { $tail = $cand[1..($cand.Count - 1)] }
  $argv = @($tail) + @("--version")
  $out = $null
  try { $out = & $exe $argv 2>$null } catch { return $false }
  if ($LASTEXITCODE -ne 0) { return $false }
  $line = (@($out) | Select-Object -First 1)
  if ($line -match "^Python 3\.") { return $true }
  return $false   # python 2, or a stub whose output is not a version banner
}
function Find-PythonMatches([string]$name) {
  # -All: every match on PATH in PATH order.  Alias stubs, functions and
  # aliases of our own are filtered out; only real executables/scripts stay.
  $seen = @{}
  $out = @()
  foreach ($c in @(Get-Command -All $name -ErrorAction SilentlyContinue)) {
    if ($c.CommandType -ne "Application" -and $c.CommandType -ne "ExternalScript") { continue }
    $src = $c.Source
    if (-not $src -or $seen.ContainsKey($src)) { continue }
    $seen[$src] = $true
    $out += $src
  }
  return $out
}
function Get-PythonCommand {
  if ($env:UT99_PYTHON) {
    $c = @($env:UT99_PYTHON)
    if (Test-PythonCandidate $c) { return $c }
    Write-Ut99Err "UT99_PYTHON set but it cannot run '--version' as Python 3: $env:UT99_PYTHON"
    return $null
  }
  foreach ($name in "python", "python3") {
    foreach ($src in (Find-PythonMatches $name)) {
      if (Test-PythonCandidate @($src)) { return @($src) }
      Write-Ut99 "python: skipping '$src' (it does not run as Python 3 -- a Microsoft Store app-execution alias?)"
    }
  }
  foreach ($src in (Find-PythonMatches "py")) {
    if (Test-PythonCandidate @($src, "-3")) { return @($src, "-3") }
  }
  Write-Ut99Err "python not found (the relay scripts/ut99-bridge.py needs it). Run: .\ut99.cmd deps"
  Write-Ut99Err "if a python 3 IS installed but hidden behind a Windows Store alias: Settings > Apps > Advanced app settings > App execution aliases, turn python/python3 off -- or set UT99_PYTHON to the real python.exe path."
  return $null
}

# tailcat_key_file -- where tailcat stores saved keys (Windows: %APPDATA%\tailcat,
# Linux: $XDG_CONFIG_HOME/tailcat -- checked too so local testing works).
function Get-TailcatKeyFile([string]$name) {
  $dirs = @()
  if ($env:TAILCAT_CONFIG) { $dirs += $env:TAILCAT_CONFIG }
  if ($env:APPDATA)        { $dirs += (Join-Path $env:APPDATA "tailcat") }
  if ($env:XDG_CONFIG_HOME){ $dirs += (Join-Path $env:XDG_CONFIG_HOME "tailcat") }
  $dirs += (Join-Path $HOME "AppData\Roaming\tailcat")
  $dirs += (Join-Path $HOME ".config\tailcat")
  foreach ($d in $dirs) {
    $f = Join-Path (Join-Path $d "keys") "$name.private.json"
    if (Test-Path $f) { return $f }
  }
  # not generated yet: report the primary location so genkey can target it
  if ($env:APPDATA) { return (Join-Path (Join-Path $env:APPDATA "tailcat") (Join-Path "keys" "$name.private.json")) }
  return (Join-Path (Join-Path $HOME "AppData/Roaming/tailcat") (Join-Path "keys" "$name.private.json"))
}

# Invoke-Tailcat -- runs tailcat inline, adding --key when TAILCAT_KEY is set
# (generating the named key once, so its tcp... address stays stable).
# Returns the exit code; output streams to the console.
function Invoke-Tailcat([string[]]$args_) {
  $tc = Get-TailcatPath
  if (-not $tc) { return 1 }
  $full = @()
  if ($env:TAILCAT_KEY) {
    $keyfile = Get-TailcatKeyFile $env:TAILCAT_KEY
    if (-not (Test-Path $keyfile)) {
      Write-Ut99 "tailcat: generating saved key '$env:TAILCAT_KEY' (first run, its tcp... address is now stable)"
      & $tc genkey --key $env:TAILCAT_KEY
      if ($LASTEXITCODE -ne 0) { Write-Ut99Err "tailcat genkey --key $env:TAILCAT_KEY failed"; return 1 }
    }
    $full += @("--key", $env:TAILCAT_KEY)
  }
  $full += $args_
  & $tc @full
  return $LASTEXITCODE
}

# Start-TailcatJob -- same as Invoke-Tailcat but backgrounded via Start-Process;
# returns the Process object (for polling/Stop-Process).
function Start-TailcatJob([string[]]$args_) {
  $tc = Get-TailcatPath
  if (-not $tc) { return $null }
  $full = @()
  if ($env:TAILCAT_KEY) {
    $keyfile = Get-TailcatKeyFile $env:TAILCAT_KEY
    if (-not (Test-Path $keyfile)) {
      Write-Ut99 "tailcat: generating saved key '$env:TAILCAT_KEY' (first run, its tcp... address is now stable)"
      & $tc genkey --key $env:TAILCAT_KEY
      if ($LASTEXITCODE -ne 0) { Write-Ut99Err "tailcat genkey --key $env:TAILCAT_KEY failed"; return $null }
    }
    $full += @("--key", $env:TAILCAT_KEY)
  }
  $full += $args_
  return Start-Process -FilePath $tc -ArgumentList $full -NoNewWindow -PassThru
}

# --- ini helpers (mirror ini_get / ini_set / ini_unset from ut99-env.sh) ------
# Windows UT ini files are plain text like the Linux ones. Files are rewritten
# with their original line endings (CRLF preserved).

function Get-IniValue([string]$file, [string]$section, [string]$key) {
  if (-not (Test-Path $file)) { return "" }
  $insec = $false
  foreach ($line in Get-Content $file) {
    $t = $line.TrimEnd("`r")
    if ($t -eq "[$section]") { $insec = $true; continue }
    if ($insec -and $t.StartsWith("[")) { break }
    if ($insec -and $t.StartsWith("$key=")) { return $t.Substring($key.Length + 1) }
  }
  return ""
}

function Set-IniValue([string]$file, [string]$section, [string]$key, [string]$value) {
  if (-not (Test-Path $file)) { New-Item -ItemType File -Path $file -Force | Out-Null }
  # Read raw so the file's original line endings can be detected and preserved
  # (Get-Content would have swallowed them).
  $raw = [System.IO.File]::ReadAllText($file)
  $eol = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
  $lines = @($raw -split "`r`n|`n|`r")
  $out = New-Object System.Collections.Generic.List[string]
  $insec = $false; $done = $false
  foreach ($line in $lines) {
    if ($line -eq "[$section]") { $insec = $true; $out.Add($line); continue }
    if ($insec -and $line.StartsWith("[")) {
      if (-not $done) { $out.Add("$key=$value"); $done = $true }
      $insec = $false
    }
    if ($insec -and $line.StartsWith("$key=")) { $out.Add("$key=$value"); $done = $true; continue }
    $out.Add($line)
  }
  if (-not $done) { $out.Add(""); $out.Add("[$section]"); $out.Add("$key=$value") }
  [System.IO.File]::WriteAllText($file, ($out -join $eol))
}

# --- game path helpers -----------------------------------------------------------

function Test-UtGameInstall {
  # true when the UT_DIR holds a usable 469 install
  Test-Path (Join-Path $env:UT_DIR "UnrealTournament.exe")
}

# --- console/Ctrl+C helpers (shared by the polling loops) ------------------------

# Start-CtrlCHandler -- Ctrl+C is caught instead of killing the script, so the
# Stop... cleanup always runs for the child processes (tailcat/python/game).
# .NET raises Console.CancelKeyPress on Ctrl+C (and on SIGINT).  The handler
# must be compiled code: a PowerShell script block invoked from the signal
# thread dies with "no Runspace available", so we add a tiny C# helper class
# whose instance method sets a flag and cancels the default Ctrl+C kill.
# Returns a holder object; the loop checks $h.Caught.
function Start-CtrlCHandler {
  if (-not ("Ut99CtrlC" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
public class Ut99CtrlC {
  public volatile bool Caught;
  private ConsoleCancelEventHandler handler;
  public Ut99CtrlC() { handler = OnKey; }
  public void Attach() { Console.CancelKeyPress += handler; }
  public void Detach() { Console.CancelKeyPress -= handler; }
  private void OnKey(object sender, ConsoleCancelEventArgs e) { Caught = true; e.Cancel = true; }
}
'@
  }
  $h = New-Object Ut99CtrlC
  $previous = [Console]::TreatControlCAsInput
  $h.Attach()
  $h | Add-Member -NotePropertyName Previous -NotePropertyValue $previous -PassThru
}

function Stop-CtrlCHandler($h) {
  if ($h) {
    $h.Detach()
    [Console]::TreatControlCAsInput = $h.Previous
  }
}
