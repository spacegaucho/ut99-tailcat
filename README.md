# ut99-socat-tailcat

Play an Unreal Tournament 99 (GOTY) LAN game across the internet using
[tailcat](https://github.com/tailscale/tailcat) (WireGuard-encrypted
point-to-point tunnel via DERP, no accounts/ports/VPN setup) bridged with the
included datagram-framed UDP↔TCP relay (`scripts/ut99-bridge.py`), because
tailcat's forwarded ports are TCP-only while UT99 speaks UDP (tailcat's
separate built-in file service is the one exception — used by `ut99
file-serve` to share the game pack). The name is historical: socat was the
original bridge; the relay replaced it because raw byte-stream bridging
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
scripts/                engine scripts (all usable standalone, wrapper just drives them)
  host-start-server.sh          UCC dedicated server (Lutris wine install)
  host-start-bridge.sh          tailcat serve + framed UDP relay, prints the tcp... address
  client-start-bridge.sh        tailcat forward + framed UDP relay (takes the tcp... address)
  ut99-bridge.py                the relay itself: length-prefixed UDP<->TCP datagram framing
  client-start-ut99.sh          game client with auto-join
  host-pack-prefix.sh           pack the wine prefix into files/ut99-wineprefix.tgz (+ .sha256)
  client-deploy-prefix.sh       friend side: verify + extract the tarball
  host-serve-files.sh           tailcat file service (`ut99 file-serve`): share the tarball + .sha256
  client-pull-files.sh          client side (`ut99 file-pull`): fetch + verify the tarball
  install-deps.sh               tailcat (GitHub release, sha256-checked) + python3 install, wine check
helpers/ut99-env.sh     shared config (every value overridable via environment)
docs/                   advanced docs: ini options, environment variables, file sharing, headless, completion, troubleshooting
files/                  pack output (gitignored)
```

## Quick start

### Server side (the host's machine)

```sh
./ut99 deps                     # tailcat + python3 if missing, checks wine

# one terminal: starts server AND bridge, prints the tcp... address
./ut99 server --mode instagib --bots 4

# [optional, once per new friend] friend has no game install yet, so the
# host serves them the game files:
./ut99 pack                     # -> files/ut99-wineprefix.tgz (+ .sha256)
./ut99 file-serve               # second terminal, alongside the server:
                                # prints a SECOND tcp... address, for the files

./ut99 probe 7777               # optional: datagram ping proving server is up
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
```

Ctrl+C anywhere stops everything that command started (bridges, server, game).
LAN-only play: `./ut99 server --lan`, clients join `host-ip:7777`.

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
| `--bots N`          | `MinPlayers` bot fill (default 4)                   |
| `--skill 0-7`       | Game/bot difficulty → `[Botpack.ChallengeBotInfo] Difficulty` (0-3 novice, 4-7 not, default 3) |
| `--goal N`          | `GoalScore` (default 5)                             |
| `--time MIN`        | `TimeLimit` in minutes (default 15)                 |
| `--no-ini`          | Don't write those three into `UnrealTournament.ini` (see [docs/ini-options.md](docs/ini-options.md)) |
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
| `--tc-key NAME`  | server/bridge/client | Saved tailcat key for a stable `tcp...` address |
| `--join HOST:PORT`| client         | Explicit join target                           |
| `--name NAME`    | client          | Player name → `[DefaultPlayer] Name` in `User.ini`; default: random `Player-XXXX` (engine limit: 16 chars) |
| `--no-join`      | client          | Start at main menu instead of auto-joining     |
| `--xvfb` / `--no-xvfb` | client   | Force/forbid Xvfb; default: automatic when `DISPLAY` is unset |
| `--xvfb-res WxH` | client          | Xvfb screen size (default `2560x1440`, see [docs/headless.md](docs/headless.md)) |
| `--prefix DIR`, `--wine-bin PATH` | server/client | `WINEPREFIX` / wine binary overrides |
| `-- ARGS`        | client          | Passed to the game untouched                   |

The flags map onto environment variables (`WINEPREFIX`, `UT_UDP_PORT`,
`UT99_PACK_OUT`, …) understood by every script — full table with defaults in
[docs/environment.md](docs/environment.md).

## Stable address (recommended)

Without a saved key every run generates a fresh keypair and the address takes
a minute+ to bootstrap. Generate one once — the address then never changes:

```sh
tailcat genkey --key ut99        # once; prints the stable tcp... address,
                                 # stores ~/.config/tailcat/keys/ut99.private.json
./ut99 server --tc-key ut99      # bridge comes up in ~3 s, same address every time
./ut99 client <that address> --tc-key ut99
```

## Documentation

| Document | Contents |
|----------|----------|
| [docs/ini-options.md](docs/ini-options.md) | Why `--bots`/`--goal`/`--time` are written into the ini, the `--skill` config trap, bot spawn timing |
| [docs/environment.md](docs/environment.md) | All engine environment variables with defaults (for using `scripts/` directly) |
| [docs/sharing-files.md](docs/sharing-files.md) | Sharing the game install: pack / file-serve / file-pull / deploy details, name scrubbing, pack excludes |
| [docs/headless.md](docs/headless.md) | Running the client headless under Xvfb (resolution/depth quirks) |
| [docs/completion.md](docs/completion.md) | Bash shell completion for the wrapper |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Caveats & troubleshooting: relay vs socat, diagnosing sessions, auto-join and the intro loop, split ports, verifying players and bots, GL-lib fixes for friends, join success signature |
