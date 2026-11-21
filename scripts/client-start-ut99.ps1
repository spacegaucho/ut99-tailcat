# SPDX-FileCopyrightText: 2026 spacegaucho
# SPDX-License-Identifier: GPL-3.0-or-later
# client-start-ut99.ps1 -- launch the native Windows UT99 client (OldUnreal 469
# install) and auto-join a server.  Windows counterpart of
# scripts/client-start-ut99.sh; extra arguments are passed to the game.
#
# Auto-join: the server address as the first positional argument.  The join
# proceeds while the intro movies play (~15 s).  If you land on the main menu
# instead, nothing was listening on the port yet -- start the host's server and
# bridge first.  Fallback: Multiplayer > Join Game > Open Game > 127.0.0.1:<port>
# (with the bridge up, 127.0.0.1 is the host).
#
# Usage:
#   .\client-start-ut99.ps1                      # auto-join 127.0.0.1:$env:UT_UDP_PORT
#   .\client-start-ut99.ps1 127.0.0.1:7779       # loopback test setup
#   $env:UT_AUTOJOIN="0"; .\client-start-ut99.ps1   # no auto-join (main menu)
#   $env:UT_SHOW_CONFIG="1"; .\client-start-ut99.ps1  # open 469's startup wizard
param(
  [string]$Address = "",
  [string[]]$GameArgs = @()
)

$ErrorActionPreference = "Stop"
. (Join-Path (Split-Path -Parent $PSScriptRoot) "helpers/ut99-env.ps1")

if ($env:UT_AUTOJOIN -ne "0") {
  if (-not $Address) { $Address = "127.0.0.1:$env:UT_UDP_PORT" }
  if ($Address -match '^127\.0\.0\.1:(\d+)$' -and $Matches[1] -ne $env:UT_UDP_PORT) {
    Write-Ut99 "note: joining 127.0.0.1:$($Matches[1]) while UT_UDP_PORT=$env:UT_UDP_PORT (the relay listens on $env:UT_UDP_PORT; pass --port accordingly or omit the port)"
  }
}

# 469 crash-recovery flag: the launcher (UnrealTournament.exe) creates the
# 0-byte System\Running.ini when it starts the engine and deletes it again on a
# clean exit; a killed/crashed run leaves it behind.  The next start then shows
# the "Unreal Tournament Recovery Mode" wizard and waits for you there instead
# of joining, so a normal run scrubs any stale copy first.
#
# UT_SHOW_CONFIG=1 turns that behaviour into the feature: plant the marker on
# purpose, and 469's own wizard opens -- "Change your 3D video device" (the
# renderer list), "Change your audio device", and the safe-mode options.  Picks
# are written to UnrealTournament.ini ([Engine.Engine] GameRenderDevice /
# GameAudioDevice); closing the wizard the normal way removes the marker again.
$marker = Join-Path $env:UT_DIR "Running.ini"
if ($env:UT_SHOW_CONFIG -eq "1") { Set-Content -Path $marker -Value "" -NoNewline -Force }
else { Remove-Item $marker -Force -ErrorAction SilentlyContinue }

if (-not (Test-UtGameInstall)) {
  Write-Ut99Err "UT99 not found at $env:UT_DIR\UnrealTournament.exe -- install OldUnreal 469 (default C:\UnrealTournament) or set UT_DIR"
  exit 1
}

$gargs = @()
if ($env:UT_AUTOJOIN -ne "0" -and $Address) { $gargs += $Address }
if ($env:UT99_LOG -eq "1") { $gargs += @("-log=ut99-client.log", "-forcelogflush") }
$gargs += $GameArgs

Write-Host "Launching UT99 from $env:UT_DIR"
if ($env:UT_SHOW_CONFIG -eq "1") {
  Write-Host "Startup wizard: pick 'Change your 3D video device' for the renderer,"
  Write-Host "'Change your audio device' for sound, or one of the safe-mode options."
} elseif ($gargs.Count -gt 0 -and $gargs[0] -notmatch '^-') {
  Write-Host "Auto-joining $($gargs[0]) -- the join proceeds during the intro movies."
  Write-Host "Fallback if it fails: Multiplayer > Join Game > Open Game > 127.0.0.1:$env:UT_UDP_PORT"
} else {
  Write-Host "No auto-join: the game opens at its main menu."
  Write-Host "Fallback if you meant to join: Multiplayer > Join Game > Open Game > 127.0.0.1:$env:UT_UDP_PORT"
}

$game = Start-Process -FilePath (Join-Path $env:UT_DIR "UnrealTournament.exe") `
                      -ArgumentList $gargs -WorkingDirectory $env:UT_DIR -PassThru
Write-Ut99 "Press Ctrl+C to stop the game."

$h = Start-CtrlCHandler
try {
  while (-not $h.Caught -and -not $game.HasExited) { Start-Sleep -Milliseconds 300 }
} finally {
  Stop-CtrlCHandler $h
  if (-not $game.HasExited) {
    Write-Ut99 "Stopping the game..."
    Stop-Process -Id $game.Id -Force -ErrorAction SilentlyContinue
  }
}
if ($game.HasExited) { exit $game.ExitCode }
