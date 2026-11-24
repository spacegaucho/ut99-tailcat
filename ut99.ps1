# SPDX-FileCopyrightText: 2026 spacegaucho
# SPDX-License-Identifier: GPL-3.0-or-later
# ut99.ps1 -- Windows (PowerShell) wrapper for the client side of ut99-tailcat.
# Counterpart of the bash 'ut99' wrapper; the host/server side stays on Linux.
#
#   ut99 client  [tcp...] [options]     game (+ internet bridge)
#   ut99 file-pull <tcp...> [options]   fetch served files (maps/mods packs)
#   ut99 deps                           install tailcat.exe + python, check scp/game
#   ut99 help                           this list
#
# Internet play: the Linux host runs 'ut99 server' and gives you its tcp...
# address; here:  .\ut99.cmd client <tcp...>  -- bridge starts with the game and
# one Ctrl+C stops both.
#
# Every setting is also an environment variable (UT_UDP_PORT, UT_DIR,
# TAILCAT_KEY, ... see docs/windows.md); flags just set them.
# Requires: Windows 10/11 (Windows PowerShell 5.1 is fine), native UT99
# (OldUnreal 469), tailcat.exe + python (both via 'ut99 deps').

[CmdletBinding()]
param(
  [Parameter(Position = 0)][string]$Command = "help",
  [Parameter(ValueFromRemainingArguments)][object[]]$Rest = @()
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
. (Join-Path $root "helpers/ut99-env.ps1")

function Show-Usage {
  Write-Host @"
ut99 (Windows) -- client side of ut99-tailcat

Commands:
  client [tcp...] [options]      start the bridge (unless --lan/--config) + the
                                 game; Ctrl+C stops both
  file-pull <tcp...> [options]   fetch files from a host's 'ut99 file-serve'
                                 [--dir DIR] [--tgz NAME] [--force] [--no-verify]
                                 [--deploy]
  deps                           install tailcat.exe + Python 3, check scp + game
  help                           this list

Client options:
  --lan                 No bridge; join directly (default target 127.0.0.1:port)
  --join HOST:PORT      Explicit join target instead of the auto-join default
  --name NAME           Player name written to [DefaultPlayer] in User.ini.
                        Default when omitted: a random Player-XXXX. Max 16
                        characters (the engine's PlayerName limit).
  --port N              Local UDP port the client uses/joins (default 7777)
  --bridge-port N       Client-side bridge TCP port          (default 8777)
  --host-port N         Host bridge TCP port it connects to  (default 8777)
  --tc-key NAME         Saved tailcat key name (stable tcp... address; auto-created on first use)
  --no-join             Start at the main menu instead of auto-joining
  --config              Open UT99's own startup wizard instead of joining: the
                        "Unreal Tournament Recovery Mode" page, where you change
                        the 3D video device (renderer), the audio device, or
                        start in safe mode.  No bridge, no player-name rewrite.
  --admin               Open the host's web admin locally: forwards the host's
                        admin port to http://127.0.0.1:<--admin-port>/ServerAdmin/
  --admin-port N        Local port for the forwarded admin UI (default 18080)
  --host-admin-port N   Host's admin port to forward (default 8080; match the server's)
  --ut-dir DIR          System directory of the native UT99 install
                        (default C:\UnrealTournament\System)
  -- ARGS               Passed to the game untouched

Examples:
  .\ut99.cmd deps
  .\ut99.cmd client tcpABCDEFGH...
  .\ut99.cmd client --config
  .\ut99.cmd client --lan --join 192.168.1.10:7777 --name Fox --bots

Environment variables (docs/windows.md): UT_DIR, UT_UDP_PORT, BRIDGE_TCP_PORT,
HOST_BRIDGE_TCP_PORT, TAILCAT_KEY, UT_AUTOJOIN, UT99_LOG, UT_SHOW_CONFIG,
UT99_ADMIN_LOCAL, UT99_HOST_ADMIN_PORT, UT99_TOOLS_DIR, UT99_FILE_PULL_DIR.
"@
}

function Invoke-Child([string]$script, [string[]]$argv) {
  # Call this as a top-level statement, then 'exit $LASTEXITCODE'.  Never wrap
  # it in an expression (exit (Invoke-Child ...)): the parentheses buffer the
  # child's whole output stream and throw the lines away.
  $ps = if ($env:UT99_PS_EXEC) { $env:UT99_PS_EXEC } else { "powershell.exe" }
  & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root "scripts/$script") @argv
}

switch ($Command.ToLower()) {
  "help" { Show-Usage; exit 0 }
  "-h" { Show-Usage; exit 0 }
  "--help" { Show-Usage; exit 0 }

  "client" {
    $tc = ""; $lan = $false; $join = ""; $name = ""; $port = ""; $bridgePort = ""
    $hostPort = ""; $nojoin = $false; $config = $false; $admin = $false
    $adminLocal = $env:UT99_ADMIN_LOCAL; $hostAdmin = $env:UT99_HOST_ADMIN_PORT
    $gameArgs = @()
    $rest = @($Rest | ForEach-Object { [string]$_ })

    for ($i = 0; $i -lt $rest.Count; $i++) {
      $a = $rest[$i]
      switch -Regex ($a) {
        "^--lan$"             { $lan = $true; continue }
        "^--no-join$"         { $nojoin = $true; continue }
        "^--config$"          { $config = $true; continue }
        "^--admin$"           { $admin = $true; continue }
        "^--join$"            { $join = [string]$rest[++$i]; continue }
        "^--name$"            { $name = [string]$rest[++$i]; continue }
        "^--port$"            { $port = [string]$rest[++$i]; continue }
        "^--bridge-port$"     { $bridgePort = [string]$rest[++$i]; continue }
        "^--host-port$"       { $hostPort = [string]$rest[++$i]; continue }
        "^--tc-key$"          { $env:TAILCAT_KEY = [string]$rest[++$i]; continue }
        "^--admin-port$"      { $adminLocal = [string]$rest[++$i]; continue }
        "^--host-admin-port$" { $hostAdmin = [string]$rest[++$i]; continue }
        "^--ut-dir$"          { $env:UT_DIR = [string]$rest[++$i]; continue }
        "^--$"                { if ($i + 1 -lt $rest.Count) { $gameArgs = @($rest[($i + 1)..($rest.Count - 1)]) }; $i = $rest.Count; continue }
        "^tc[A-Za-z0-9_-]+$"  { $tc = $a; continue }
        "^-"                  { Write-Ut99Err "unknown client option: $a"; exit 2 }
        default               { $gameArgs += $a; continue }
      }
    }

    foreach ($p in @(@("--port", $port), @("--bridge-port", $bridgePort), @("--host-port", $hostPort),
                     @("--admin-port", $adminLocal), @("--host-admin-port", $hostAdmin))) {
      $v = $p[1]
      if ($v -and $v -notmatch '^\d+$') { Write-Ut99Err "$($p[0]) needs an integer, got: $v"; exit 2 }
    }
    if ($port)       { $env:UT_UDP_PORT = $port }
    if ($bridgePort) { $env:BRIDGE_TCP_PORT = $bridgePort }
    if ($hostPort)   { $env:HOST_BRIDGE_TCP_PORT = $hostPort }
    if ($nojoin)     { $env:UT_AUTOJOIN = "0" }

    if ($config) {
      # 469's own settings wizard: the launcher shows it when System\Running.ini
      # is left over from a run that did not shut down cleanly, so planting that
      # marker is what opens it.  Its first page offers "Change your 3D video
      # device" (renderer list), "Change your audio device", and the safe-mode
      # options; picks are saved into UnrealTournament.ini, so the next plain
      # 'ut99 client' uses them.  Settings run: no join, no bridge, no admin.
      if ($join)  { Write-Ut99Err "ut99 client --config opens the settings wizard; it cannot join at the same time (drop --config or --join)"; exit 2 }
      if ($tc)    { Write-Ut99Err "ut99 client --config starts no bridge (drop --config to join a tcp... address)"; exit 2 }
      if ($admin) { Write-Ut99Err "ut99 client --config starts no admin forward (use 'ut99 client <tcp...> --admin' for that)"; exit 2 }
      $env:UT_SHOW_CONFIG = "1"; $env:UT_AUTOJOIN = "0"
      $rend = Get-IniValue (Join-Path $env:UT_DIR "UnrealTournament.ini") "Engine.Engine" "GameRenderDevice"
      if ($rend) { Write-Ut99 "startup wizard ON -- current renderer: $rend ([Engine.Engine] GameRenderDevice)" }
      else       { Write-Ut99 "startup wizard ON" }
      Write-Ut99 "in the wizard choose 'Change your 3D video device' to pick a renderer, or a safe-mode option to troubleshoot"
    }

    $udpPort = [int]$env:UT_UDP_PORT

    # Player name: the engine reads [DefaultPlayer] Name from User.ini.  Same
    # rules as the Linux wrapper; --config leaves the existing name alone.
    if ($config -and -not $name) { $name = "" }
    elseif (-not $name) { $name = "Player-{0}" -f (1000 + (Get-Random -Maximum 9000)) }
    if ($name) {
      if ($name -match '[\?="'']') { Write-Ut99Err "invalid player name (contains ? = `" or '): $name"; exit 2 }
      if ($name.Length -gt 16) {
        Write-Ut99Err "player name truncated to 16 chars: $($name.Substring(0, 16))"
        $name = $name.Substring(0, 16)
      }
      $userIni = Join-Path $env:UT_DIR "User.ini"
      if (-not (Test-Path $userIni)) { Write-Ut99Err "note: $userIni did not exist; created it (the game fills in the rest on first save)."; New-Item -ItemType File -Path $userIni -Force | Out-Null }
      Set-IniValue $userIni "DefaultPlayer" "Name" $name
      Write-Host "Player name: $name  ([DefaultPlayer] Name in $userIni)"
    }

    if (-not $tc -or $lan) {
      # direct LAN client: no bridge
      if ($config) {
        Invoke-Child "client-start-ut99.ps1" @()
        exit $LASTEXITCODE
      }
      if (-not $join) { $join = "127.0.0.1:$udpPort" }
      if ($admin) {
        Write-Ut99 "ut99 client: web admin at http://$($join.Split(':')[0]):$hostAdmin/ServerAdmin/ (ask the host for the login)"
      }
      $argv = @()
      if ($env:UT_AUTOJOIN -ne "0") { $argv += @("-Address", $join) }
      if ($gameArgs) { $argv += @("-GameArgs") + $gameArgs }
      Invoke-Child "client-start-ut99.ps1" $argv
      exit $LASTEXITCODE
    }

    # remote client: bridge + game combined (one Ctrl+C stops everything)
    $env:TAILCAT_ADDR = $tc
    if ($admin) {
      $env:UT_ADMIN_FORWARD = "1"
      $env:UT99_ADMIN_LOCAL = $adminLocal
      $env:UT99_HOST_ADMIN_PORT = $hostAdmin
    }
    $argv = @("-Mode", "client", "-Address", $tc)
    if ($join) { $argv += @("-JoinTarget", $join) }
    if ($gameArgs) { $argv += @("-GameArgs") + $gameArgs }
    Invoke-Child "ut99-run.ps1" $argv
    exit $LASTEXITCODE
  }

  "file-pull" {
    # map the bash-style flags onto the script's PowerShell parameters; values
    # follow as the next token and bind to -Dir/-Name.
    $argv = @()
    foreach ($a in @($Rest | ForEach-Object { [string]$_ })) {
      switch ($a) {
        "--dir"      { $argv += "-Dir"; continue }
        "--tgz"      { $argv += "-Name"; continue }
        "--force"    { $argv += "-Force"; continue }
        "--no-verify"{ $argv += "-NoVerify"; continue }
        "--deploy"   { $argv += "-Deploy"; continue }
        default      { $argv += $a; continue }
      }
    }
    Invoke-Child "client-pull-files.ps1" $argv
    exit $LASTEXITCODE
  }

  "deps" { Invoke-Child "install-deps.ps1" @(); exit $LASTEXITCODE }

  default {
    Write-Ut99Err "unknown command: $Command  (server/pack/deploy run on the Linux host)"
    Show-Usage
    exit 2
  }
}
