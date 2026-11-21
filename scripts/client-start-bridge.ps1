# SPDX-FileCopyrightText: 2026 spacegaucho
# SPDX-License-Identifier: GPL-3.0-or-later
# client-start-bridge.ps1 -- client side of the tailcat bridge (Windows).
#
# Chain (client side):
#   UT99 client --UDP 127.0.0.1:7777/7778--> ut99-bridge.py relay --TCP 127.0.0.1:8777--> tailcat forward
#     ...tailcat tunnel...--> host's tailcat serve 8777 --> host's relay --> host's UT99 server
#
# The relay frames every UDP datagram before it crosses the TCP tunnel; a raw
# byte-stream bridge merges packet bursts into giant datagrams and corrupts the
# game.  It runs the SAME scripts/ut99-bridge.py the Linux host runs.
#
# Usage: .\client-start-bridge.ps1 <tc-address>
#   If the host uses a different bridge port: $env:HOST_BRIDGE_TCP_PORT = "..."
param(
  [Parameter(Mandatory)][string]$Address
)

$ErrorActionPreference = "Stop"
. (Join-Path (Split-Path -Parent $PSScriptRoot) "helpers/ut99-env.ps1")

$ps = if ($env:UT99_PS_EXEC) { $env:UT99_PS_EXEC } else { "powershell.exe" }
$argv = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
          (Join-Path $PSScriptRoot "ut99-run.ps1"), "-Mode", "bridge", "-Address", $Address)
& $ps @argv
exit $LASTEXITCODE
