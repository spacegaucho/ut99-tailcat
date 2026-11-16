# SPDX-FileCopyrightText: 2026 spacegaucho
# SPDX-License-Identifier: GPL-3.0-or-later
# ut99-run.ps1 — shared run orchestration for the Windows side (internal;
# called by ut99.ps1 and the client-start-*.ps1 entry points).
#
# It is the PowerShell counterpart of the bash wrapper's job_pipe +
# monitor_jobs + combined_traps: every child (tailcat forward, relay, game)
# is a Start-Process job; the script polls them; when one exits or you press
# Ctrl+C, the others are stopped.
#
# Modes:
#   bridge  tailcat forward + framed relay only
#   game    the UT99 client only
#   client  bridge + game (what 'ut99 client tcpXXXX' runs)
#
# Behaviour comes from the environment set by the caller (see ut99-env.ps1):
#   TAILCAT_ADDR, UT_AUTOJOIN, UT_SHOW_CONFIG, UT99_ADMIN_LOCAL, ...
param(
  [Parameter(Mandatory)][ValidateSet("bridge", "game", "client")][string]$Mode,
  [string]$Address = "",          # tcp... address (bridge/client; tailcat only)
  [string]$JoinTarget = "",       # what the GAME joins (default 127.0.0.1:UT_UDP_PORT)
  [string[]]$GameArgs = @()       # extra args passed to the game untouched
)

$ErrorActionPreference = "Stop"
. (Join-Path (Split-Path -Parent $PSScriptRoot) "helpers/ut99-env.ps1")

# The UDP probe magic from 'ut99 probe' / master-server queries.
$script:MasterQueryBytes = [byte[]](0x00, 0x01, 0x00, 0x00, 0x00) + [System.Text.Encoding]::ASCII.GetBytes("UUnreal")

function Start-BridgeJobs {
  # Chain (client side):
  #   UT99 --UDP 127.0.0.1:port+port+1--> relay --TCP 127.0.0.1:BRIDGE_TCP_PORT--> tailcat forward
  #     ...tailcat tunnel...--> host's tailcat serve --> host's relay --> host's server
  # Every process is registered in $script:watchJobs the moment it starts, so
  # a later failure or Ctrl+C is reaped by the run's finally block.
  $tc_addr = if ($Address) { $Address } else { $env:TAILCAT_ADDR }
  if (-not $tc_addr) { Write-Ut99Err "no tailcat address given (the host prints it when its bridge starts)"; exit 1 }

  $bridgePort = [int]$env:BRIDGE_TCP_PORT
  Write-Ut99 "tailcat: forwarding local TCP 127.0.0.1:$bridgePort -> host port $env:HOST_BRIDGE_TCP_PORT"
  $tcJob = Start-TailcatJob @("forward", $tc_addr, "${bridgePort}:$env:HOST_BRIDGE_TCP_PORT")
  if (-not $tcJob) { exit 1 }
  $script:watchJobs += $tcJob

  # Wait until the tailcat local listener accepts connections (40 * 0.5 s).
  $ready = $false
  for ($i = 0; $i -lt 40 -and -not $ready; $i++) {
    try {
      $c = New-Object System.Net.Sockets.TcpClient
      $ar = $c.BeginConnect("127.0.0.1", $bridgePort, $null, $null)
      if ($ar.AsyncWaitHandle.WaitOne(500) -and $c.Connected) { $ready = $true }
      $c.Close()
    } catch { Start-Sleep -Milliseconds 500 }
  }
  if (-not $ready) {
    Write-Ut99Err "tailcat local listener never came up (bad address, or host not reachable)"
    exit 1   # finally reaps $tcJob
  }

  # @() matters: PowerShell flattens a 1-element return to a scalar string,
  # and $py[0] of a string is its first character.
  $py = @(Get-PythonCommand)
  if ($py.Count -eq 0 -or -not $py[0]) { exit 1 }
  $udpPort = [int]$env:UT_UDP_PORT
  Write-Ut99 "relay: UDP 127.0.0.1:$udpPort +$($udpPort + 1) -> TCP 127.0.0.1:$bridgePort (framed)"
  # PYTHONUNBUFFERED so the relay's [bridge] log lines appear live.
  $env:PYTHONUNBUFFERED = "1"
  $relayArgs = @((Join-Path $PSScriptRoot "ut99-bridge.py"), "client",
                 "--udp-port", "$udpPort", "--tcp-host", "127.0.0.1", "--tcp-port", "$bridgePort")
  if ($py.Count -gt 1) { $relayArgs = $py[1..($py.Count - 1)] + $relayArgs }   # e.g. "py -3"
  $relayJob = Start-Process -FilePath $py[0] -ArgumentList $relayArgs -NoNewWindow -PassThru
  $script:watchJobs += $relayJob

  # Wait until the relay has actually bound its UDP ports before the game joins.
  # Windows: ask which UDP listeners the relay process owns. Elsewhere (local
  # pwsh testing): fall back to a plain socket check of the port.
  $bound = $false
  $haveNetCmdlet = [bool](Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)
  for ($i = 0; $i -lt 60 -and -not $bound; $i++) {
    if ($haveNetCmdlet) {
      $owned = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
               Where-Object { $_.PId -eq $relayJob.Id -and @($udpPort, $udpPort + 1) -contains $_.LocalPort }
      if ($owned) { $bound = $true; break }
    } else {
      try {
        $c = New-Object System.Net.Sockets.TcpClient
        $ar = $c.BeginConnect("127.0.0.1", $bridgePort, $null, $null)
        # the relay connects to the tailcat port right after binding UDP; if
        # that TCP link is up and the relay lives, it is ready.
        if ($ar.AsyncWaitHandle.WaitOne(250) -and $c.Connected) { $bound = $true }
        $c.Close()
      } catch { }
      if ($bound) { break }
    }
    if (-not $relayJob.HasExited) { Start-Sleep -Milliseconds 500 } else { break }
  }
  if (-not $bound) {
    Write-Ut99 "note: could not confirm the relay's UDP listeners (continuing; watch the [bridge] log)"
  }
}

function Start-GameJob {
  if (-not (Test-UtGameInstall)) {
    Write-Ut99Err "UT99 not found at $env:UT_DIR\UnrealTournament.exe (--ut-dir DIR to point at your install, see ut99 deps)"
    exit 1
  }
  $gargs = @()
  # The game joins the LOCAL relay port (or an explicit --join target); the
  # tcp... tailcat address never goes to the game — only to the bridge.
  if ($env:UT_AUTOJOIN -ne "0") {
    $join = if ($JoinTarget) { $JoinTarget } else { "127.0.0.1:$env:UT_UDP_PORT" }
    $gargs += $join
  }
  if ($env:UT99_LOG -eq "1") { $gargs += @("-log=ut99-client.log", "-forcelogflush") }
  $gargs += $GameArgs

  if ($env:UT_SHOW_CONFIG -eq "1") {
    Write-Ut99 "Startup wizard: pick 'Change your 3D video device' for the renderer,"
    Write-Ut99 "'Change your audio device' for sound, or one of the safe-mode options."
  }

  # The client-start-ut99.ps1 entry point handles the Running.ini marker; in
  # combined client mode the wrapper already exported UT_SHOW_CONFIG, so plant
  # or scrub the marker here (same rule as scripts/client-start-ut99.ps1).
  $marker = Join-Path $env:UT_DIR "Running.ini"
  if ($env:UT_SHOW_CONFIG -eq "1") { Set-Content -Path $marker -Value "" -NoNewline -Force }
  else { Remove-Item $marker -Force -ErrorAction SilentlyContinue }

  Write-Ut99 "Launching UT99 from $env:UT_DIR"
  $gameJob = Start-Process -FilePath (Join-Path $env:UT_DIR "UnrealTournament.exe") `
                           -ArgumentList $gargs -WorkingDirectory $env:UT_DIR -PassThru
  $script:watchJobs += $gameJob
}

# ---- run --------------------------------------------------------------------

# Registered the moment a process starts, so the finally below reaps every
# child even when startup fails halfway through the chain.
$script:watchJobs = @()   # watched jobs: if one exits, the run ends
$script:auxJobs = @()     # cleanup-only jobs (admin forward)

$h = $null
try {
  if ($Mode -in "bridge", "client") {
    Start-BridgeJobs
    if ($Mode -eq "client") { Write-Ut99 "Bridge ready." }
  }
  if ($Mode -in "game", "client") {
    if ($Mode -eq "client" -and $env:UT_ADMIN_FORWARD -eq "1") {
      # Same design as the bash wrapper: its OWN tailcat forward that is NOT
      # watched for exit — a failure (local port clash, host without --admin)
      # must not tear down the game run.  Cleanup still reaps it.
      $tc_addr = if ($Address) { $Address } else { $env:TAILCAT_ADDR }
      $adminJob = Start-TailcatJob @("forward", $tc_addr, "${env:UT99_ADMIN_LOCAL}:${env:UT99_HOST_ADMIN_PORT}")
      if ($adminJob) {
        $script:auxJobs += $adminJob
        Write-Ut99 "host web admin -> http://127.0.0.1:${env:UT99_ADMIN_LOCAL}/ServerAdmin/  (host must have started with --admin)"
      }
    }
    Start-GameJob
  }
  if ($Mode -eq "bridge") { Write-Ut99 "Bridge ready. In UT99: Multiplayer > Join Game > Open Game > 127.0.0.1:$env:UT_UDP_PORT" }
  Write-Ut99 "Press Ctrl+C to disconnect."

  $h = Start-CtrlCHandler
  while (-not $h.Caught) {
    $dead = @($script:watchJobs | Where-Object { $_.HasExited })
    if ($dead) {
      Write-Ut99 ("job exited (exit code {0})" -f $dead[0].ExitCode)
      break
    }
    Start-Sleep -Milliseconds 300
  }
} finally {
  if ($h) { Stop-CtrlCHandler $h }
  Write-Ut99 "Stopping ut99 processes..."
  foreach ($j in ($script:watchJobs + $script:auxJobs)) { Stop-Process -Id $j.Id -Force -ErrorAction SilentlyContinue }
}
