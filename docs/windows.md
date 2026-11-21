# Windows client

The Windows side of this repo is the **friend's side only**: the game client,
the bridge that carries it over the tailcat tunnel, the file puller and the
deps installer. The host (server + bridge + file serve) stays on Linux — see
the README quick start for what the host runs.

```
ut99.cmd                  double-click / cmd.exe entry point (calls ut99.ps1)
ut99.ps1                  the Windows wrapper: client / file-pull / deps / help
scripts/ut99-run.ps1      run orchestration (tailcat + relay + game, Ctrl+C)
scripts/client-start-*.ps1  bridge-only / game-only entry points
scripts/client-pull-files.ps1  ut99 file-pull (fetch + sha256 verify)
scripts/install-deps.ps1  ut99 deps (tailcat.exe + python, checks scp + game)
scripts/ut99-bridge.py    THE SAME framed relay the Linux host runs
helpers/ut99-env.ps1      shared defaults and helpers
```

## Requirements

- Windows 10/11. Windows PowerShell 5.1 (built-in) works; pwsh 7 too.
  All `.ps1`/`.cmd` files are kept **ASCII-only** on purpose: PS 5.1 decodes
  BOM-less UTF-8 via the ANSI code page, where an em dash byte becomes a
  smart-quote and breaks parsing in non-English locales ("Token ...
  inesperado"). A UTF-8 **with BOM** copy would also fix it, but ASCII is
  bulletproof. `ut99.cmd` additionally uses CRLF line endings.
- A **native** UT99 install (GOTY + OldUnreal 469 patch), default game
  directory `C:\UnrealTournament\System` — override with `UT_DIR`.
  No wine on Windows: the game runs natively; the Linux host's packed wine
  prefix (`ut99 pack` / default `file-pull` tarball) is for Linux friends.
- `tailcat.exe` and python: `.\ut99.cmd deps` installs both
  (tailcat v0.7.0 from the pinned GitHub release into `tools\tailcat.exe`,
  python via `winget` when missing). `file-pull` additionally needs
  `scp.exe` — Settings > Apps > Optional Features > **OpenSSH Client**.

## Friend flow

```powershell
# 0) copy this repo folder anywhere (it holds the scripts + tools\), then:
.\ut99.cmd deps                      # tailcat.exe + python, checks scp + game

# 1) the Linux host runs:  ./ut99 server --mode instagib --bots 4
#    and gives you its printed tcp... address.  Then:
.\ut99.cmd client tcpGFwWCDL0hpvOh...   # bridge + game in one window

# optional flags (same as the Linux wrapper):
.\ut99.cmd client <tcp...> --name Myself
.\ut99.cmd client <tcp...> --admin      # host's web admin at http://127.0.0.1:18080/ServerAdmin/
.\ut99.cmd client --lan 192.168.1.10:7777   # plain LAN, no bridge
.\ut99.cmd client --config              # open 469's startup wizard (renderer/audio)

# maps/mods packs the host serves with ./ut99 file-serve:
.\ut99.cmd file-pull <file-serve tcp...> --tgz Mypack.7z --dir D:\downloads
```

`client` starts the tailcat forward + the framed relay, then launches
`UnrealTournament.exe` joining `127.0.0.1:7777` (the local relay — the tunnel
end is the host's server). One **Ctrl+C** ends everything: the game, the relay
and tailcat (tailcat ignores normal kill signals, so the wrapper force-stops
its children; everything is reaped in a `finally` block, even on mid-startup
failure).

The join target is ALWAYS a local address (`127.0.0.1:7777` or your explicit
`--join`); the `tcp...` address goes only to tailcat.

## tailcat keys: host and client must be different nodes

`TAILCAT_KEY` (default `ut99` on both sides) names the *saved key file* on
each machine — each machine keeps its own private key under
`%APPDATA%\tailcat\keys\`, so a host named `ut99` and a friend named `ut99`
on different machines are fine.

On ONE machine (testing both sides locally), or when the host runs
`ut99 server` and `ut99 file-serve` at once, the two tailcat processes must
use **different saved keys**: two processes sharing one key are the same
tailcat node, and dialing/copying to that node then times out
(`Dial: context deadline exceeded`). The Linux host already runs
`file-serve` on its own key (`ut99-files`, override
`UT99_FILE_SERVE_KEY` or `--tc-key`). For a same-machine client test set a
distinct key, e.g. `$env:TAILCAT_KEY = "ut99friend"`.

## Environment variables

Flags are the friendly form; every setting is also an environment variable
(set it before `.\ut99.cmd ...`, see also [docs/environment.md](environment.md)):

| Variable | Default | Meaning |
|---|---|---|
| `UT_DIR` | `C:\UnrealTournament\System` | native game install (where `UnrealTournament.exe` is) |
| `UT_UDP_PORT` | `7777` | local game port the relay listens on (+query port `+1`) |
| `BRIDGE_TCP_PORT` | `8777` | local TCP port forwarded by tailcat |
| `HOST_BRIDGE_TCP_PORT` | `8777` | the host's tailcat serve port |
| `TAILCAT_KEY` | `ut99` | saved key name on THIS machine (stable `tcp...` address) |
| `UT99_TAILCAT_BIN` | — | use this tailcat.exe instead of PATH/tools |
| `UT99_TOOLS_DIR` | `<repo>\tools` | where `deps` installs tailcat.exe |
| `UT99_TAILCAT_VERSION` | `0.7.0` | pinned tailcat release |
| `UT99_PYTHON` | auto | python used to run `scripts/ut99-bridge.py` |
| `UT99_FILE_PULL_DIR` | `<repo>\files` | default `file-pull` destination |
| `UT_AUTOJOIN` | `1` | `0` opens the main menu instead of auto-joining |
| `UT_SHOW_CONFIG` | `0` | `1` opens 469's startup wizard (what `--config` sets) |
| `UT99_ADMIN_LOCAL` | `18080` | local port `--admin` forwards to |
| `UT99_HOST_ADMIN_PORT` | `8080` | the host's web admin port (`--admin-port` on the host) |
| `UT99_LOG` | `1` | pass `-log=ut99-client.log -forcelogflush` to the game |

## file-pull caveats on Windows

- The default tarball `ut99-wineprefix.tgz` is a **Linux wine prefix** — a
  Windows player doesn't need it (native install). Use `file-pull` for map/mod
  packs the host serves with `./ut99 file-serve ~/share` or `--dir`, then
  unpack them into the game's `Maps`/`System` directories yourself.
- `--deploy` (extract the wine prefix) is intentionally not implemented on
  Windows; the script warns and drops it.
- The `.sha256` is fetched first; a re-run whose local file already matches
  skips the download (`--force` re-fetches anyway). A transient
  `tailcat cp` failure is retried once.

## Tested vs. untested

Everything here was exercised headlessly with pwsh 7.5 on Linux (same scripts,
forward-slash paths — Windows accepts them too): wrapper argument handling,
the full bridge/game orchestration through a live tailcat tunnel with a stub
`UnrealTournament.exe`, Ctrl+C cleanup, ini name rewriting (CRLF-safe), the
file-pull cycle against a live `file-serve`, and the deps branch logic.
Natively Windows-only parts — `powershell.exe` 5.1 quirks, `winget` python
install, OpenSSH `scp.exe` presence, real OldUnreal 469 rendering — can only
be verified on an actual Windows box.
