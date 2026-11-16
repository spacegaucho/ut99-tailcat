# ut99-tailcat

Play an Unreal Tournament 99 (GOTY) LAN game across the internet using
[tailcat](https://github.com/tailscale/tailcat) (WireGuard-encrypted
point-to-point tunnel via DERP, no accounts/ports/VPN setup) bridged with the
included datagram-framed UDP↔TCP relay (`scripts/ut99-bridge.py`), because
tailcat's forwarded ports are TCP-only while UT99 speaks UDP (tailcat's
separate built-in file service is the one exception — used by `ut99
file-serve` to share the game pack). An early revision bridged with
plain socat; the included relay replaced it because raw byte-stream bridging
corrupts the game — see [troubleshooting](docs/troubleshooting.md):

```
UT99 client --UDP :7777/7778--> ut99-bridge.py --TCP :8777--> tailcat forward
   ═══════════ WireGuard-encrypted tailcat tunnel ═══════════
host: tailcat serve :8777 <--TCP-- ut99-bridge.py --UDP 127.0.0.1:7777/7778--> UCC dedicated server
```

One host runs the server + bridge and shares its `tcp...` address; each friend
runs the client with that address. The address is the secret — ephemeral by
default (dead once the host stops), stable if you generate a saved key.

## Layout

```
ut99                    single wrapper: server / client / bridge / probe / pack / deploy / file-serve / file-pull / deps
ut99.cmd / ut99.ps1     Windows wrapper (client side only: client / file-pull / deps) — see docs/windows.md
scripts/                engine scripts (all usable standalone, wrapper just drives them)
  host-start-server.sh          UCC dedicated server (Lutris wine install)
  host-start-bridge.sh          tailcat serve + framed UDP relay, prints the tcp... address
  client-start-bridge.sh        tailcat forward + framed UDP relay (takes the tcp... address)
  ut99-bridge.py                the relay itself: length-prefixed UDP<->TCP datagram framing
  client-start-ut99.sh          game client with auto-join
  host-pack-prefix.sh           pack the wine prefix into files/ut99-wineprefix.tgz (+ .sha256)
  client-deploy-prefix.sh       friend side: verify + extract the tarball
  host-serve-files.sh           tailcat file service (`ut99 file-serve`): share the tarball + .sha256 (on its own key, ut99-files)
  client-pull-files.sh          client side (`ut99 file-pull`): fetch + verify the tarball
  install-deps.sh               tailcat (GitHub release, sha256-checked) + python3 install, wine check
  *.ps1                         Windows client side: ut99-run, client-start-bridge, client-start-ut99, client-pull-files, install-deps
helpers/ut99-env.sh     shared config (every value overridable via environment)
helpers/ut99-env.ps1    Windows counterpart of ut99-env.sh
docs/                   advanced docs: ini options, admin web API, environment variables, file sharing, headless, completion, troubleshooting
files/                  pack output (gitignored)
```

## Quick start

### Server side (the host's machine)

```sh
./ut99 deps                     # tailcat + python3 if missing, checks wine

# one terminal: starts server AND bridge, prints the tcp... address and a
# ready-to-copy join command for your friends
./ut99 server --mode instagib --bots 4

# [optional, once per new friend] friend has no game install yet, so the
# host serves them the game files:
./ut99 pack                     # -> files/ut99-wineprefix.tgz (+ .sha256)
./ut99 file-serve               # second terminal, alongside the server:
                                # prints a SECOND tcp... address, for the files

./ut99 probe 7777               # optional: datagram ping proving server is up

# [optional] in-game web admin (change map/mode, bots, kicks while running):
./ut99 server --admin           # adds --admin to the line above; login printed at startup
```

### Client side (each friend's machine, plus the host player's own game)

```sh
./ut99 deps                     # same check, on the friend's machine

# [optional, once] friend has no game install yet: fetch + unpack the
# files the host's file-serve is sharing
./ut99 file-pull <file-serve tcp... address> --deploy
                                # extracts into their WINEPREFIX

# bridge + game in one command:
./ut99 client tcpGFwWCDL...     # the tcp... the host's `server` printed
                                # [optional] --name Archon (player name, max 16 chars)

# on the host machine itself no address is needed (second terminal):
./ut99 client                   # direct LAN join, no bridge

# [optional] reach the host's web admin (if the server used --admin):
./ut99 client tcpGFwWCDL... --admin    # -> http://127.0.0.1:18080/ServerAdmin/
```

Ctrl+C anywhere stops everything that command started (bridges, server, game).
LAN-only play: `./ut99 server --lan`, clients join `host-ip:7777`.

Friend on **Windows**? Copy this repo to their machine and use `.\ut99.cmd deps` /
`.\ut99.cmd client <tcp...>` — the native OldUnreal 469 client, no wine; see
[docs/windows.md](docs/windows.md).

`--name` writes the player name into `[DefaultPlayer] Name` in `User.ini`
(the engine takes it from there into the join URL); omit it and the wrapper
picks a throwaway random `Player-XXXX`. Engine limit: 16 characters.
The `file-serve` address and the `server` bridge address are two different
`tcp...` strings; details in [docs/sharing-files.md](docs/sharing-files.md).

## `ut99` commands

| Command         | What it does                                                       |
|-----------------|--------------------------------------------------------------------|
| `ut99 server`   | Dedicated server + host bridge (combined; one Ctrl+C stops both). `--lan` skips the bridge. |
| `ut99 client`   | Game client. With a `tcp...` address it starts the client bridge first and launches the game once the tunnel is up; without one, joins directly (LAN). |
| `ut99 bridge host\|client …` | Run only one side of the bridge (separate terminals). |
| `ut99 probe [port]` | Send a net-test datagram to `127.0.0.1:port`; a reply proves server/bridge up. |
| `ut99 pack`     | Pack the wine prefix → `files/ut99-wineprefix.tgz` + `.sha256` (scrubs your player name out of the packed copy). |
| `ut99 deploy`   | Verify + extract the tarball into `WINEPREFIX`.                    |
| `ut99 file-serve [DIR]` | Serve `DIR` (default `files/`) read-only through tailcat's file service; friends fetch with `tailcat cp`. |
| `ut99 file-pull <tcp...>` | Client side of `file-serve`: fetch the tarball + `.sha256` into `files/` and verify (skips the download when the local copy already matches). |
| `ut99 deps`     | Install tailcat + python3 if missing; check wine (prints per-distro install hints when absent). |
| `ut99 --completion bash` | Print the bash completion script — see [docs/completion.md](docs/completion.md). |

### Server game options

| Flag                | Meaning                                             |
|---------------------|-----------------------------------------------------|
| `--map NAME`        | Starting map (default `CTF-Face`)                   |
| `--mode ctf\|dm\|instagib\|team\|dom` | Game-mode preset (see mapping below) |
| `--instagib`        | Add the InstaGib mutator to ctf/dm/team/dom         |
| `--game CLASS`      | Override the mode mapping, e.g. `Botpack.TeamGamePlus` |
| `--mutators a,b`    | Extra mutators → `?Mutator=a+b`                     |
| `--bots N`          | Bot fill: writes `[Botpack.DeathMatchPlus] MinPlayers` (total players incl. you; default 4) |
| `--skill 0-7`       | Game/bot difficulty → `[Botpack.ChallengeBotInfo] Difficulty` (0-3 novice, 4-7 not, default 3) |
| `--goal N`          | Frag/Team-score goal (default 5) → `FragLimit` in dm modes, `GoalTeamScore` in ctf/team/dom |
| `--time MIN`        | `TimeLimit` in minutes (default 15; passed as `?TimeLimit=` and into the ini) |
| `--no-ini`          | Don't write MinPlayers/goal/time/skill into `UnrealTournament.ini` — the engine then takes them from the existing ini only (see [docs/ini-options.md](docs/ini-options.md)) |
| `--opts RAW`        | Full raw URL options, overrides all assembly above (and skips the ini writes) |
| `--keep-uplinks`    | Do NOT comment out master-server uplink lines       |

Mode mapping: `ctf`→`Botpack.CTFGame`, `dm`→`Botpack.DeathMatchPlus`,
`instagib`→`Botpack.DeathMatchPlus` + `Botpack.InstaGibDM` mutator,
`team`→`Botpack.TeamGamePlus`, `dom`→`Botpack.Domination`.

Why `--bots`/`--goal`/`--time` go through the ini, how `--skill` actually
reaches the bots, and when bots spawn: [docs/ini-options.md](docs/ini-options.md).

### Networking options

| Flag             | Side            | Meaning                                        |
|------------------|-----------------|------------------------------------------------|
| `--lan`          | server/client   | No bridges; plain LAN on UDP `--port`          |
| `--port N`       | server/client   | UT UDP port (server default 7777; also sets the join URL `?port=` so UCC rebinds) |
| `--bridge-port N`| both            | Local TCP port of the relay↔tailcat bridge (default 8777) |
| `--host-port N`  | client          | Host bridge's TCP port it dials (default 8777) |
| `--tc-key NAME`  | server/bridge/client | Stable `tcp...` address via a saved tailcat key (created automatically on first use) |
| `--admin`        | server/client   | Server: enable UT99's built-in web admin on the running match (bridge serves that port too). Client: open the host's admin locally at `http://127.0.0.1:18080/ServerAdmin/` — see [docs/admin-api.md](docs/admin-api.md) |
| `--admin-port N` | server/client   | Server: admin HTTP port (default 8080). Client: local forwarded port (default 18080) |
| `--admin-pass PASS` | server       | Admin password (user `admin`); default: random 12-char, printed at startup |
| `--host-admin-port N` | client   | Host's admin port to forward (default 8080; match the server's) |
| `--join HOST:PORT`| client         | Explicit join target                           |
| `--name NAME`    | client          | Player name → `[DefaultPlayer] Name` in `User.ini`; default: random `Player-XXXX` (engine limit: 16 chars) |
| `--no-join`      | client          | Start at main menu instead of auto-joining     |
| `--config`       | client          | Open UT99's own startup wizard (choose the 3D video / audio device or safe mode) instead of playing; see [docs/troubleshooting.md](docs/troubleshooting.md) |
| `--xvfb` / `--no-xvfb` | client   | Force/forbid Xvfb; default: automatic when `DISPLAY` is unset |
| `--xvfb-res WxH` | client          | Xvfb screen size (default `2560x1440`, see [docs/headless.md](docs/headless.md)) |
| `--prefix DIR`, `--wine-bin PATH` | server/client | `WINEPREFIX` / wine binary overrides |
| `-- ARGS`        | client          | Passed to the game untouched                   |

The flags map onto environment variables (`WINEPREFIX`, `UT_UDP_PORT`,
`UT99_PACK_OUT`, …) understood by every script — full table with defaults in
[docs/environment.md](docs/environment.md).

## Stable address (recommended)

Without a saved key every run generates a fresh keypair and the address takes
a minute+ to bootstrap. `--tc-key NAME` uses a saved key and **creates it
automatically on the first run**; the address derived from it then never
changes (the server prints a ready-to-copy join command built from it):

```sh
./ut99 server --tc-key ut99      # first run: generates the key + prints the stable tcp... address
                                 # stores ~/.config/tailcat/keys/ut99.private.json
./ut99 client <that address>     # friends; same address every restart
```

(`tailcat genkey --key ut99` creates the same key by hand, e.g. to print the
address before ever starting a game.)

Saved keys are stock tailcat key files, stored at `~/.config/tailcat/keys/NAME.private.json`
on Linux/macOS and `%APPDATA%\tailcat\keys\NAME.private.json` on Windows.

## Documentation

| Document | Contents |
|----------|----------|
| [docs/ini-options.md](docs/ini-options.md) | Why `--bots`/`--goal`/`--time` are written into the ini, the `--skill` config trap, bot spawn timing |
| [docs/admin-api.md](docs/admin-api.md) | `--admin`: UT99's built-in web admin — change map/game mode live, add/remove bots, kick players, console commands, curl examples |
| [docs/environment.md](docs/environment.md) | All engine environment variables with defaults (for using `scripts/` directly) |
| [docs/sharing-files.md](docs/sharing-files.md) | Sharing the game install: pack / file-serve / file-pull / deploy details, name scrubbing, pack excludes |
| [docs/headless.md](docs/headless.md) | Running the client headless under Xvfb (resolution/depth quirks) |
| [docs/windows.md](docs/windows.md) | Playing as a Windows friend: `ut99.cmd` wrapper, native 469 install, deps, tailcat keys, file-pull caveats |
| [docs/completion.md](docs/completion.md) | Bash shell completion for the wrapper |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Caveats & troubleshooting: relay vs socat, diagnosing sessions, auto-join and the intro loop, split ports, verifying players and bots, GL-lib fixes for friends, join success signature |
