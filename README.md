# ut99-socat-tailcat

Play an Unreal Tournament 99 (GOTY) LAN game across the internet using
[tailcat](https://github.com/tailscale/tailcat) (WireGuard-encrypted
point-to-point tunnel via DERP, no accounts/ports/VPN setup) bridged with
socat, because tailcat's CLI only forwards TCP ports while UT99 speaks UDP:

```
UT99 client --UDP :7777--> socat --TCP :8777--> tailcat forward
   ═══════════ WireGuard-encrypted tailcat tunnel ═══════════
host: tailcat serve :8777 <--TCP-- socat --UDP 127.0.0.1:7777--> UCC dedicated server
```

One host runs the server + bridge and shares its `tcp...` address; each friend
runs the client with that address. The address is the secret — ephemeral by
default (dead once the host stops), stable if you generate a saved key.

## Layout

```
ut99                    single wrapper: server / client / bridge / probe / pack / deploy / deps
scripts/                engine scripts (all usable standalone, wrapper just drives them)
  host-start-server.sh          UCC dedicated server (Lutris wine install)
  host-start-bridge.sh          tailcat serve + socat TCP→UDP, prints the tcp... address
  client-start-bridge.sh        tailcat forward + socat UDP→TCP (takes the tcp... address)
  client-start-ut99.sh          game client with auto-join
  host-pack-prefix.sh           pack the wine prefix into files/ut99-wineprefix.tgz (+ .sha256)
  client-deploy-prefix.sh       friend side: verify + extract the tarball
  install-deps.sh               socat (pacman/apt) + tailcat (GitHub release, sha256-checked)
helpers/ut99-env.sh     shared config (every value overridable via environment)
files/                  pack output (gitignored)
```

## Quick start

```sh
./ut99 deps                     # socat + tailcat, only if missing

# Host (one terminal): starts server AND bridge, prints the tcp... address
./ut99 server --mode instagib --bots 4

# Each friend (one terminal): bridge + game in one command
./ut99 client tcpGFwWCDL...     # the address the host printed

# Host player's own game (second terminal)
./ut99 client                   # direct LAN join, no bridge

./ut99 probe 7777               # optional: datagram ping proving server is up
```

Ctrl+C anywhere stops everything that command started (bridges, server, game).
LAN-only play: `./ut99 server --lan`, clients join `host-ip:7777`.

## `ut99` commands

| Command         | What it does                                                       |
|-----------------|--------------------------------------------------------------------|
| `ut99 server`   | Dedicated server + host bridge (combined; one Ctrl+C stops both). `--lan` skips the bridge. |
| `ut99 client`   | Game client. With a `tcp...` address it starts the client bridge first and launches the game once the tunnel is up; without one, joins directly (LAN). |
| `ut99 bridge host\|client …` | Run only one side of the bridge (separate terminals). |
| `ut99 probe [port]` | Send a net-test datagram to `127.0.0.1:port`; a reply proves server/bridge up. |
| `ut99 pack`     | Pack the wine prefix → `files/ut99-wineprefix.tgz` + `.sha256`.    |
| `ut99 deploy`   | Verify + extract the tarball into `WINEPREFIX`.                    |
| `ut99 deps`     | Install socat + tailcat if missing.                                |

### Server game options

| Flag                | Meaning                                             |
|---------------------|-----------------------------------------------------|
| `--map NAME`        | Starting map (default `CTF-Face`)                   |
| `--mode ctf\|dm\|instagib\|team\|dom` | Game-mode preset (see mapping below) |
| `--instagib`        | Add the InstaGib mutator to ctf/dm/team/dom         |
| `--game CLASS`      | Override the mode mapping, e.g. `Botpack.TeamGamePlus` |
| `--mutators a,b`    | Extra mutators → `?Mutator=a+b`                     |
| `--bots N`          | `MinPlayers` bot fill (default 4)                   |
| `--skill 0-7`       | `Difficulty` (0 Novice … 7 Godlike, default 3)      |
| `--goal N`          | `GoalScore` (default 5)                             |
| `--time MIN`        | `TimeLimit` in minutes (default 15)                 |
| `--opts RAW`        | Full raw URL options, overrides all assembly above  |
| `--keep-uplinks`    | Do NOT comment out master-server uplink lines       |

Mode mapping: `ctf`→`Botpack.CTFGame`, `dm`→`Botpack.DeathMatchPlus`,
`instagib`→`Botpack.DeathMatchPlus` + `Botpack.InstaGibDM` mutator,
`team`→`Botpack.TeamGamePlus`, `dom`→`Botpack.Domination`.

### Networking options

| Flag             | Side            | Meaning                                        |
|------------------|-----------------|------------------------------------------------|
| `--lan`          | server/client   | No bridges; plain LAN on UDP `--port`          |
| `--port N`       | server/client   | UT UDP port (server default 7777; also sets the join URL `?port=` so UCC rebinds) |
| `--bridge-port N`| both            | Local TCP port of the socat↔tailcat bridge (default 8777) |
| `--host-port N`  | client          | Host bridge's TCP port it dials (default 8777) |
| `--tc-key NAME`  | server/bridge/client | Saved tailcat key for a stable `tcp...` address |
| `--join HOST:PORT`| client         | Explicit join target                           |
| `--no-join`      | client          | Start at main menu instead of auto-joining     |
| `--xvfb` / `--no-xvfb` | client   | Force/forbid Xvfb; default: automatic when `DISPLAY` is unset |
| `--xvfb-res WxH` | client          | Xvfb screen size (default `2560x1440`, see [Headless](#headless--xvfb)) |
| `--prefix DIR`, `--wine-bin PATH` | server/client | `WINEPREFIX` / wine binary overrides |
| `-- ARGS`        | client          | Passed to the game untouched                   |

## Engine environment variables

The wrapper maps flags onto these; when using `scripts/` directly, set them
yourself. Defaults match the Lutris `unreal-tournament` install (wine runner,
system wine):

| Variable              | Default                                       | Meaning                              |
|-----------------------|-----------------------------------------------|--------------------------------------|
| `WINEPREFIX`          | `~/wine/unreal-tournament`                    | Lutris wine prefix of the game       |
| `UT_DIR`              | `$WINEPREFIX/drive_c/UnrealTournament/System` | Game `System` dir (UCC.exe lives here) |
| `WINE_BIN`            | `wine`                                        | Wine binary to use                   |
| `UT_UDP_PORT`         | `7777`                                        | UT99 server/client UDP port          |
| `BRIDGE_TCP_PORT`     | `8777`                                        | local socat↔tailcat TCP port (both sides) |
| `HOST_BRIDGE_TCP_PORT`| `8777`                                        | Host's bridge port (client-side override) |
| `TC_ADDR`             | —                                             | Host's tailcat address (client side) |
| `TAILCAT_KEY`         | *(empty)*                                     | Saved key name for a stable `tcp...` address |
| `MAP` / `GAME_TYPE` / `EXTRA_OPTS` | `CTF-Face` / `Botpack.CTFGame` / see server flags | Raw server URL settings |
| `UT_AUTOJOIN`         | `1`                                           | `0` = client starts at main menu     |
| `UT99_LOG`            | `1`                                           | Client writes UT engine log `ut99-client.log` in `UT_DIR` (`-log … -forcelogflush`) |
| `UT99_XVFB_RES`       | `2560x1440`                                   | Xvfb screen size used by `ut99 client` |
| `DISABLE_UPLINKS`     | `1`                                           | Comment out master-server uplink lines (backup kept as `*.ut99bak`) |
| `UT99_PACK_OUT`       | `files/ut99-wineprefix.tgz`                   | Pack output path; suffix picks compression |
| `UT99_PACK_KEEP`      | *(empty)*                                     | Re-include named pack excludes, e.g. `mono,UT436` |
| `UT99_PREFIX_TGZ`     | `files/ut99-wineprefix.tgz`                   | Tarball to deploy                     |
| `UT99_DEPLOY_FORCE`   | `0`                                           | `1` = allow extracting over a non-empty prefix |

## Stable address (recommended)

Without a saved key every run generates a fresh keypair and the address takes
a minute+ to bootstrap. Generate one once — the address then never changes:

```sh
tailcat genkey --key ut99        # once; prints the stable tcp... address,
                                 # stores ~/.config/tailcat/keys/ut99.private.json
./ut99 server --tc-key ut99      # bridge comes up in ~3 s, same address every time
./ut99 client <that address> --tc-key ut99
```

## Sharing the game install (one-time setup for friends)

Instead of each friend installing and patching UT99 themselves, pack your
working Lutris wine prefix into a single tarball; they extract it into their
own `WINEPREFIX` and can immediately run everything.

```sh
./ut99 pack          # -> files/ut99-wineprefix.tgz (+ .sha256), ~560M
# share the tgz + .sha256 (scp, file host, python3 -m http.server …)
./ut99 deploy        # friend side: verifies checksum, extracts into WINEPREFIX
```

The raw prefix is ~1.8G; the pack drops things the game never uses or
regenerates: `windows/mono` (~228M), `drive_c/UT436` leftover copy (~100M),
MSI caches (~80M), wine-gecko `INetCache` (~83M), game `Installer`/`GLCache`/
`Logs`/`*.log`, and the `Running.ini` crash marker. Re-include with
`UT99_PACK_KEEP=mono,UT436`; choose output with `--out`. `deploy` refuses to
touch a non-empty prefix unless `--force`. The prefix was created with wine
11.x — friends should use a similarly recent wine (≥ 9). Deploying does not
install `tailcat`/`socat`: run `./ut99 deps` too.

## Headless / Xvfb

`ut99 client` runs the game under `xvfb-run` automatically when `DISPLAY` is
unset (ssh sessions, CI). Notes learned the hard way:

- The Xvfb screen **must match** the game's `FullscreenViewportX/Y` in
  `UnrealTournament.ini` (default here: 2560x1440). A mismatch makes the
  swapchain resize mid-startup and wine dies with an `X BadWindow` error.
  Use `--xvfb-res` to match a different ini resolution.
- Depth is fixed at **24-bit**: this system's Xvfb refuses 32-bit screens
  (`Couldn't add screen 0`), and a 24-bit root window maps to 32-bit D3D
  rendering exactly like a real desktop does.
- Headless Xvfb sessions still play game audio on your real sound device.
- `--no-xvfb` forces your real `DISPLAY`; `UT99_XVFB_RES` overrides the size.

## Caveats & troubleshooting

- **UDP over TCP loses datagram boundaries.** socat streams bytes into the
  tailcat TCP tunnel; small UT99 datagrams can merge or split across the hop
  and get dropped by the game. Reliable traffic retransmits, so it usually
  plays fine; for stutter/packet loss try a datagram-framing tool (e.g.
  `udptunnel`) in place of socat on both sides, or host closer to your friends
  (`tailcat ping <tcp...>` shows direct vs DERP path).
- **Client auto-join**: `ut99 client` auto-joins `127.0.0.1:$UT_UDP_PORT`
  a few seconds after launch, *while the intro movies play*. Verified on this
  469 install with the full tunnel. If it lands on the main menu instead,
  almost always nothing was listening on the local UDP port yet — start in
  order: server → host bridge → client bridge → game (the wrapper does this
  for you and waits for the bridge). In-game fallback: **Multiplayer → Join
  Game → Open Game** → `127.0.0.1:7777`. There is no `-nointro` on 469.
- **`?port=` URLs work on 469**: `ut99 server --port N` appends `?port=N` so
  UCC binds N. The server also binds **N+1** (UDP) for `UdpServerQuery`
  (server browser) — don't let a loopback client bridge reuse either port.
  Working loopback split: server `7777`/bridge `8777` (defaults), client
  `--port 7779 --bridge-port 9777`.
- **Recovery prompt after a hard kill**: 469 tracks clean exits through an
  empty `System/Running.ini` marker. If a game was SIGKILLed, the next launch
  asks how to start (normal/safe mode). Delete `Running.ini` to skip it; the
  wrapper's own teardown leaves it only for hard crashes.
- **tailcat ignores SIGTERM** (installs SIG_IGN): anything left behind by a
  crash can only be cleared with `pkill -KILL -x tailcat`.
- **Windows binaries**: this install is already patched to OldUnreal **469**
  (32-bit Windows binaries under wine: `UCC.exe`, `UnrealTournament.exe`,
  `D3D11Drv.dll`…); no native `ucc-bin`. Server scripts use `ucc-bin`
  automatically if a native build is installed.
- **Master servers**: with `DISABLE_UPLINKS=1` the server doesn't advertise
  itself to public masters (private games, no spam to mostly dead uplinks).
  Restore the `*.ut99bak` files to undo.
- **Firewall**: nothing inbound needs opening — tailcat connects outward via
  DERP and punches to a direct path when possible.
- **Join success signature** (server console):
  `NotifyAcceptingChannel … Accepted` → `Level server received: HELLO …` →
  `Login: <name>` → `Possessed PlayerPawn` → `Join succeeded`. If HELLO never
  arrives, the tunnel path is broken; if HELLO arrives but no `Login:`, check
  the client engine log (`ut99-client.log` in `UT_DIR`).
