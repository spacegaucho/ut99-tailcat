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

One host runs the server + bridge and shares its `tc...` address; each friend
runs the client bridge with that address. The host player joins the server
directly at `127.0.0.1:7777`. Anyone you give the `tc...` address to can join
— the address is the secret, ephemeral by default (dead once the host stops).

## Scripts

| Script            | What it does                                                            |
|-------------------|-------------------------------------------------------------------------|
| `install-deps.sh` | Installs socat (pacman) and tailcat (latest GitHub release, sha256-checked) |
| `ut99-env.sh`     | Shared config, sourced by the others; everything overridable via env vars |
| `host-start-server.sh`    | Starts the UT99 dedicated server (Lutris wine install)             |
| `host-start-bridge.sh`    | tailcat serve + socat TCP→UDP bridge; prints the `tc...` address   |
| `client-start-bridge.sh`  | tailcat forward + socat UDP→TCP bridge (takes the `tc...` address) |
| `client-start-ut99.sh`    | Launches the UT99 game client from the same Lutris install         |
| `host-pack-prefix.sh`     | Packs the wine prefix into `ut99-wineprefix.tgz` + `.sha256`       |
| `client-deploy-prefix.sh` | Friend side: verify + extract that tarball into a fresh `WINEPREFIX` |

## Install

```sh
./install-deps.sh        # sudo pacman -S socat + downloads tailcat, if missing
```

## Configuration

Defaults match the Lutris `unreal-tournament` install (wine runner, system
wine) — set env vars to override, no script editing needed:

| Variable              | Default                                       | Meaning                              |
|-----------------------|-----------------------------------------------|--------------------------------------|
| `WINEPREFIX`          | `~/wine/unreal-tournament`                    | Lutris wine prefix of the game       |
| `UT_DIR`              | `$WINEPREFIX/drive_c/UnrealTournament/System` | Game `System` dir (UCC.exe lives here) |
| `WINE_BIN`            | `wine`                                        | Wine binary to use                   |
| `UT_UDP_PORT`         | `7777`                                        | UT99 server/client UDP port          |
| `BRIDGE_TCP_PORT`     | `8777`                                        | socat↔tailcat TCP port (both sides)  |
| `HOST_BRIDGE_TCP_PORT`| `8777`                                        | Host's bridge port (client-side override) |
| `TC_ADDR`             | —                                             | Host's tailcat address (client side) |
| `TAILCAT_KEY`         | *(empty)*                                     | Saved key name for a stable `tc...` address |
| `MAP`                 | `CTF-Face`                                    | Starting map                         |
| `GAME_TYPE`           | `Botpack.CTFGame`                             | Game type                            |
| `BOT_SKILL`           | `3` (Skilled, 0–7)                            | Bot difficulty                       |
| `EXTRA_OPTS`          | `?Mutator=Botpack.InstaGibDM?MinPlayers=4?GoalScore=5?TimeLimit=15?Difficulty=$BOT_SKILL` | URL options appended to the map |
| `DISABLE_UPLINKS`     | `1`                                           | Comment out master-server uplink lines in `Default.ini`/`UnrealTournament.ini` (backup kept as `*.ut99bak`) |
| `UT99_PACK_OUT`       | `ut99-wineprefix.tgz` (script dir)            | Pack output path; suffix picks compression (`.tgz`, `.tar.xz`, …) |
| `UT99_PACK_KEEP`      | *(empty)*                                     | Re-include named pack excludes, e.g. `UT99_PACK_KEEP=mono,UT436` |
| `UT99_PREFIX_TGZ`     | `ut99-wineprefix.tgz` (script dir)            | Tarball to deploy (`client-deploy-prefix.sh`) |
| `UT99_DEPLOY_FORCE`   | `0`                                           | `1` = allow extracting on top of an existing non-empty prefix |

Example: `MAP=CTF-1on1-Jail2 EXTRA_OPTS="?Difficulty=5" ./host-start-server.sh`

## Run a game

### Host

```sh
# Terminal 1
./host-start-server.sh          # wait until the console settles

# Terminal 2
./host-start-bridge.sh          # prints "Server listening with new address: tc..."
```

Share the printed `tc...` address with your friends over a private channel
(whoever has it can join). Then start your own client: `./client-start-ut99.sh`
auto-joins `127.0.0.1:7777` after the intro (if you launch via Lutris instead,
join manually — see *Client auto-join* under Caveats).

### Each client / friend

```sh
# Terminal 1 — bridge, using the host's address
./client-start-bridge.sh tcXXXXXXXX...

# Terminal 2 — the game; auto-joins 127.0.0.1:7777 during the intro movies
./client-start-ut99.sh
```

Fallback (e.g. when launching via Lutris): in-game **Multiplayer → Join Game →
Open Game** → enter `127.0.0.1:7777` (`127.0.0.1` is correct — the bridge makes
the remote server look local). This assumes the friend already owns a working
UT99 install — otherwise have them deploy your packed prefix first
(*Sharing the game install* below).

### Two or more parties

Everyone connects to the same host: each friend runs their own
`client-start-bridge.sh <same tc... address>`. The host's socat forks one UDP
socket per incoming connection, so N players work. If a friend already has
something on port 7777 locally, run their bridge as
`UT_UDP_PORT=7778 ./client-start-bridge.sh tcXXXX` and join `127.0.0.1:7778`.

### Stable address (optional)

By default the `tc...` address is new on every host run. For a repeatable one:

```sh
tailcat genkey --key ut99        # once, prints the stable address
TAILCAT_KEY=ut99 ./host-start-bridge.sh
TAILCAT_KEY=ut99 ./client-start-bridge.sh <stable address>
```

## Sharing the game install (one-time setup for friends)

Instead of each friend installing and patching UT99 themselves, pack your
working Lutris wine prefix into a single tarball; they extract it into their
own `WINEPREFIX` and can immediately run the bridges and join.

Verified end to end: packed prefix → extracted into a fresh directory → both
server and client run from the extracted copy → client auto-joins and plays.

### Host: pack

```sh
./host-pack-prefix.sh          # -> ut99-wineprefix.tgz (+ .sha256), in this folder
```

The raw prefix is ~1.8G but the tgz is **~560M** (game data is already
compressed). The pack drops things the game never uses or regenerates:
`windows/mono` (~228M), the `drive_c/UT436` leftover copy (~100M), MSI caches
(`windows/Installer`, ~80M), the wine-gecko `INetCache` (~83M), game
`Installer`/`GLCache`/`Logs`/`*.log`, and the `Running.ini` crash marker. Re-include
any of them with `UT99_PACK_KEEP` (e.g. `UT99_PACK_KEEP=mono,UT436`); pick
output/compression with `UT99_PACK_OUT=ut99-wineprefix.tar.xz`. The tarball is
gitignored — share it (and the `.sha256`) over any file host, scp, or a
throwaway `python3 -m http.server`.

### Friend: deploy

Place `ut99-wineprefix.tgz` (+ `.sha256`) next to these scripts, then:

```sh
./client-deploy-prefix.sh      # verifies checksum, extracts into WINEPREFIX (default ~/wine/unreal-tournament)
```

It refuses to touch an existing non-empty prefix. Deploy somewhere else with
`WINEPREFIX=~/wine/ut99-friend ./client-deploy-prefix.sh`, or update an existing
one in place with `UT99_DEPLOY_FORCE=1`. A `.sha256` beside the tarball is
verified automatically. After extraction the script sanity-checks the game files
and removes any stale `Running.ini`, so the first launch is clean.

Notes: the prefix was created with wine 11.x — friends should use a similarly
recent wine (≥ 9); wine notices a version change and updates the prefix
automatically on first launch. Deploying does not install `tailcat`/`socat` —
run `./install-deps.sh` once as usual.

## Caveats & troubleshooting

- **UDP over TCP loses datagram boundaries.** socat streams bytes into the
  tailcat TCP tunnel; small UT99 datagrams can merge or split across the hop
  and get dropped by the game. Reliable traffic retransmits, so it usually
  plays fine, but if you notice stutter/packet loss, try a datagram-framing
  tool (e.g. `udptunnel`) in place of socat on both sides, or host closer to
  your friends so the tunnel goes direct quickly (`tailcat ping <tc...>` shows
  direct vs DERP path).
- **Client auto-join**: `./client-start-ut99.sh` auto-joins
  `127.0.0.1:$UT_UDP_PORT` by default (pass an address to override, or set
  `UT_AUTOJOIN=0`). Verified on this install (patched to **469**): the client
  issues the join a few seconds after launch, *while the intro movies play*.
  If you land on the main menu anyway, the join attempt failed — nearly always
  because nothing was listening on the local UDP port yet, i.e. the server or
  a bridge wasn't up (or you joined a different port than the bridge binds;
  the script warns about unbound local ports). Start things in this order:
  server → host bridge → client bridge → client. There is no `-nointro`
  option on 469, so the intro always plays. Fallback for any client: in-game
  **Join Game → Open Game**.
- **Recovery prompt after a hard kill**: 469 tracks clean exits through an
  empty `System/Running.ini` marker, created at game startup and deleted on a
  clean exit. If the client crashed or was SIGKILLed, the next launch asks how
  to start (normal/safe mode). Pick normal startup, or delete `Running.ini`.
- **Windows binaries**: this install is already patched to OldUnreal **469**
  (32-bit Windows binaries under wine: `UCC.exe`, `UnrealTournament.exe`,
  `D3D11Drv.dll`…); no native `ucc-bin` is present. If you later install a
  Linux build, the server script automatically uses `ucc-bin` instead.
- **Bots & settings**: see `MAP`/`GAME_TYPE`/`BOT_SKILL`/`EXTRA_OPTS` above.
  Bots fill empty slots up to `MinPlayers` and leave as real players join.
- **Master servers**: with `DISABLE_UPLINKS=1` the server doesn't advertise
  itself to public master servers (keeps games private and avoids spam to
  mostly dead uplinks). Revert by restoring the `*.ut99bak` files.
- **Firewall**: nothing needs to be opened inbound — tailcat connects outward
  via DERP and NAT-punches to a direct path when possible.
- **Loopback test** on one machine:
  `./host-start-server.sh`, `./host-start-bridge.sh`, then
  `BRIDGE_TCP_PORT=9777 UT_UDP_PORT=7779 ./client-start-bridge.sh <tc...>`,
  then `./client-start-ut99.sh 127.0.0.1:7779` to join for real. Two port
  overrides are needed because the whole
  chain runs on one box: `BRIDGE_TCP_PORT=9777` keeps the client tailcat off
  the host bridge's 8777, and `UT_UDP_PORT=7779` keeps the client bridge off
  the UDP ports the server itself binds (the GOTY `IpDrv.TcpNetDriver`
  listens on **UDP** 7777 *and* 7778 — 7778 is the `UdpServerQuery` port;
  there is no TCP 7777 listener, which is exactly why the UDP↔TCP bridge is
  needed). Quick end-to-end probe instead of launching the game:

  ```sh
  python3 -c "import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(5); s.sendto(b'\x00\x01\x00\x00\x00UUnreal', ('127.0.0.1',7779)); print(s.recvfrom(2048))"
  ```

  A reply (e.g. `b'\x00@\x80 '`) means client bridge → tailcat tunnel →
  host bridge → server all work.
