# ut99-socat-tailcat

Play an Unreal Tournament 99 (GOTY) LAN game across the internet using
[tailcat](https://github.com/tailscale/tailcat) (WireGuard-encrypted
point-to-point tunnel via DERP, no accounts/ports/VPN setup) bridged with
socat, because tailcat's forwarded ports are TCP-only while UT99 speaks UDP
(tailcat's separate built-in file service is the one exception — used by
`ut99 file-serve` to share the game pack):

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
ut99                    single wrapper: server / client / bridge / probe / pack / deploy / file-serve / file-pull / deps
scripts/                engine scripts (all usable standalone, wrapper just drives them)
  host-start-server.sh          UCC dedicated server (Lutris wine install)
  host-start-bridge.sh          tailcat serve + socat TCP→UDP, prints the tcp... address
  client-start-bridge.sh        tailcat forward + socat UDP→TCP (takes the tcp... address)
  client-start-ut99.sh          game client with auto-join
  host-pack-prefix.sh           pack the wine prefix into files/ut99-wineprefix.tgz (+ .sha256)
  client-deploy-prefix.sh       friend side: verify + extract the tarball
  host-serve-files.sh           tailcat file service (`ut99 file-serve`): share the tarball + .sha256
  client-pull-files.sh          client side (`ut99 file-pull`): fetch + verify the tarball
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
| `ut99 pack`     | Pack the wine prefix → `files/ut99-wineprefix.tgz` + `.sha256` (scrubs your player name out of the packed copy). |
| `ut99 deploy`   | Verify + extract the tarball into `WINEPREFIX`.                    |
| `ut99 file-serve [DIR]` | Serve `DIR` (default `files/`) read-only through tailcat's file service; friends fetch with `tailcat cp`. |
| `ut99 file-pull <tcp...>` | Client side of `file-serve`: fetch the tarball + `.sha256` into `files/` and verify (skips the download when the local copy already matches). |
| `ut99 deps`     | Install socat + tailcat if missing.                                |
| `ut99 --completion bash` | Print the bash completion script — see [Shell completion](#shell-completion). |

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
| `--no-ini`          | Don't write those three into `UnrealTournament.ini` (see below) |
| `--opts RAW`        | Full raw URL options, overrides all assembly above (and skips the ini writes) |
| `--keep-uplinks`    | Do NOT comment out master-server uplink lines       |

Mode mapping: `ctf`→`Botpack.CTFGame`, `dm`→`Botpack.DeathMatchPlus`,
`instagib`→`Botpack.DeathMatchPlus` + `Botpack.InstaGibDM` mutator,
`team`→`Botpack.TeamGamePlus`, `dom`→`Botpack.Domination`.

#### Why `--bots`/`--goal`/`--time` are written into the ini

`MinPlayers`, `GoalScore` and `TimeLimit` are declared `var() globalconfig` in
the game classes (`System/Botpack.u`, shipped source on 469), so the engine
reads them from **`UnrealTournament.ini`**, and a `?MinPlayers=4` URL option is
silently ignored — a server whose ini says `MinPlayers=0` stays bot-free no
matter what the URL says. So `ut99 server` writes them into the game type's own
ini section before launching UCC:

```ini
[Botpack.CTFGame]
MinPlayers=4      # total players: you + 3 bots
GoalScore=5
TimeLimit=15
```

`ini_set` replaces the key in place (or adds it), keeps CRLF line endings and
touches nothing else; `--no-ini` (or `--opts RAW`) leaves your ini alone, and
then those numbers have to come from the ini itself.

`--skill` has the same trap from the other side. `TournamentGameInfo.SpawnBot()`
begins with `Difficulty = BotConfig.Difficulty;`, i.e. it *overwrites* the game's
`Difficulty` (a plain `var byte` in `Engine.GameInfo`, so `?Difficulty=` in the URL
is only read once in `InitGame` and then overwritten) with
`[Botpack.ChallengeBotInfo] Difficulty` from the ini — again a `config` key.
Values 0..3 are the four skill levels in novice mode, 4..7 the same levels with
novice mode off, and `InitializeSkill` also sets the bot's `bNovice` flag from it.

Measured on this install (ini-only run, `InitGame` line proves no `?Difficulty=` was
in the URL): `Difficulty=0` → the human pawn logs `Skill 1.0`, `Difficulty=5` →
`Skill 3.0`. That is `PlayerPawn.PreBeginPlay`'s `Skill += Level.Game.Difficulty`
(`Skill` is documented as "scaled by game difficulty"), so the ini key really does
set the game's difficulty. Bot pawns are the confusing part: their default `Skill`
is already 3 and the value is clamped to 0..3, so a low ini difficulty does not show
up as a lower logged `Skill` — what changes is the novice flag and the per-bot
`BotSkills[n]` spread. Judge `--skill` in play (or with the game's own difficulty
menu), not by the logged number.

Bot timing, straight from `DeathMatchPlus.Timer()`: the server never fills
bots before a human is present. Once someone joins it waits `NetWait` seconds
(default 10) and then adds one bot per second until `NumPlayers + NumBots`
reaches `MinPlayers`. So expect the first bot ~12 s after your join — not at
server start.

### Networking options

| Flag             | Side            | Meaning                                        |
|------------------|-----------------|------------------------------------------------|
| `--lan`          | server/client   | No bridges; plain LAN on UDP `--port`          |
| `--port N`       | server/client   | UT UDP port (server default 7777; also sets the join URL `?port=` so UCC rebinds) |
| `--bridge-port N`| both            | Local TCP port of the socat↔tailcat bridge (default 8777) |
| `--host-port N`  | client          | Host bridge's TCP port it dials (default 8777) |
| `--tc-key NAME`  | server/bridge/client | Saved tailcat key for a stable `tcp...` address |
| `--join HOST:PORT`| client         | Explicit join target                           |
| `--name NAME`    | client          | Player name → `[DefaultPlayer] Name` in `User.ini`; default: random `Player-XXXX` (engine limit: 16 chars) |
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
| `UT99_PACK_SCRUB_TO`  | `Player`                                      | Name written into the packed `User.ini`; `''` disables name scrubbing |
| `UT99_FILE_SERVE_DIR` | `files/`                                      | Directory served by `ut99 file-serve` / `host-serve-files.sh` |
| `UT99_FILE_PULL_DIR` | `files/`                                       | Directory `ut99 file-pull` fetches into |
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
# host side
./ut99 pack          # -> files/ut99-wineprefix.tgz (+ .sha256), ~560M
./ut99 file-serve    # serves both files read-only over tailcat; copy its tcp... address
```

Getting the files on the client side (what each friend runs):

```sh
# friend side, in their own clone/copy of this repo (ut99, scripts/, helpers/)
./ut99 deps                                        # installs tailcat + socat if missing
./ut99 file-pull <file-serve tcp... address>       # -> files/, checksum verified
./ut99 deploy                                      # extracts into WINEPREFIX
./ut99 client <host's bridge tcp... address>       # then play
```

`ut99 file-pull` is `tailcat cp` plus checksum logic: it pulls
`ut99-wineprefix.tgz.sha256` first, **skips the download** when the local
tarball already matches it (so re-running is cheap), transfers with scp's
progress display, and verifies afterwards. `--force` re-downloads anyway,
`--no-verify` skips the check, `--dir DIR` pulls somewhere else, `--deploy`
extracts right away. The manual equivalent, if you would rather do it by hand:

```sh
mkdir -p files
tailcat cp <tcp...>:ut99-wineprefix.tgz.sha256 files/
tailcat cp <tcp...>:ut99-wineprefix.tgz files/     # scp-like fetch, with progress
( cd files && sha256sum -c ut99-wineprefix.tgz.sha256 )
```

Notes for the fetching side:

- **Two different addresses**: the `file-serve` address hands over the files;
  the `server` bridge address is what `ut99 client` connects to for the game.
  They are separate commands, separate tailcat processes, separate `tcp...`
  strings (both only live while the host's command runs, unless `--tc-key`
  is used).
- Remote paths are relative to the served directory, so plain file names are
  enough. Put both files in `files/` — that is where `ut99 deploy` looks; any
  other location works via `UT99_PREFIX_TGZ=~/Downloads/ut99-wineprefix.tgz ./ut99 deploy`
  (keep the `.sha256` next to the tarball).
- Fetching only needs `tailcat` (plus the system `scp`, which is what actually
  moves the bytes). `-p` preserves timestamps; abort with Ctrl+C and re-run to
  retry — `scp` restarts the file from scratch rather than resuming.
- `ut99 deploy` checks `<tarball>.sha256` itself when it is present
  (`sha256sum -c` is the manual equivalent, run from inside the directory that
  holds both files). It refuses a non-empty `WINEPREFIX` unless `--force`
  (or `UT99_DEPLOY_FORCE=1`), and points at a different prefix with
  `--prefix DIR` / `WINEPREFIX=DIR`.
- No tailcat on the friend's machine yet, or prefer a plain download? Serve
  the same two files any other way: `scp`, `sftp`, a file host, or on the host
  `python3 -m http.server -d files 8000` and `curl -O` on the client side.

The pack scrubs your personal player name: inside the archive `User.ini`'s
`[DefaultPlayer] Name` becomes `Player` and `BestPlayers[]`/`Saves[]` entries
referencing your name are dropped, while key bindings, video/audio settings
and everything else are carried over byte-identically. Your live `User.ini`
is never touched, and the original name never enters the archive (the real
file is excluded and only the scrubbed copy is packed). Set
`UT99_PACK_SCRUB_TO=''` to pack the name as-is. Friends change it later with
`ut99 client --name <their name>`.

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

## Shell completion

Bash completion for the wrapper is generated by the wrapper itself:

```sh
source <(./ut99 --completion bash)     # try it now
echo 'source <(/path/to/this/repo/ut99 --completion bash)' >> ~/.bashrc   # keep it
```

It is registered for both `ut99` and `./ut99` and completes:

- subcommands (`ut99 <Tab>` → `server client bridge …`) and each subcommand's
  own option set (`ut99 pack <Tab>` → `--out --keep --prefix`, no `--map`);
- option **values**: `--mode` → `ctf dm instagib team dom`, `--keep` → the
  pack-exclude names, `--tc-key` → the keys found in
  `~/.config/tailcat/keys/*.private.json`, `--prefix`/`--dir` → directories,
  `--out`/`--tgz` → files;
- `bridge host` vs `bridge client` (each gets its own port options).

Tailcat `tcp...` addresses are remote and have nothing to complete against
locally — type or paste them. Only bash is supported (`--completion zsh`
errors; a zsh user can wrap this with bashcompinit).

## Caveats & troubleshooting

- **UDP over TCP loses datagram boundaries.** socat streams bytes into the
  tailcat TCP tunnel; small UT99 datagrams can merge or split across the hop
  and get dropped by the game. Reliable traffic retransmits, so it usually
  plays fine; for stutter/packet loss try a datagram-framing tool (e.g.
  `udptunnel`) in place of socat on both sides, or host closer to your friends
  (`tailcat ping <tcp...>` shows direct vs DERP path).
- **Client auto-join**: `ut99 client` auto-joins `127.0.0.1:$UT_UDP_PORT`
  a few seconds after launch, *while the intro movies play*. Verified on this
  469 install with the full tunnel. While a connect attempt is pending the
  intro **loops** — `CityIntro` keeps replaying until the connection lands or
  the engine's ~150 s connect timeout fires. A client stuck looping the intro
  forever therefore means the connect never succeeded: check start order and
  ports (below), especially that both bridge sides agree on the *host* bridge
  port (`--bridge-port` is your local TCP port; the side dialing the host must
  match its port via `--host-port`). If it lands on the main menu instead,
  almost always nothing was listening on the local UDP port yet — start in
  order: server → host bridge → client bridge → game (the wrapper does this
  for you and waits for the bridge). In-game fallback: **Multiplayer → Join
  Game → Open Game** → `127.0.0.1:7777`. There is no `-nointro` on 469.
- **`?port=` URLs work on 469**: `ut99 server --port N` appends `?port=N` so
  UCC binds N. The server also binds **N+1** (UDP) for `UdpServerQuery`
  (server browser) — don't let a loopback client bridge reuse either port.
  Working loopback split: server `7777`/bridge `8777` (defaults), client
  `--port 7779 --bridge-port 9777`.
- **Verify who is really in the game** (humans and bots): the server writes a
  UTF-16 world log to `UnrealTournament/Logs/Unreal.ngLog.<date>.<port>.log`
  (`.tmp` while running / after a hard kill). It is authoritative, unlike the
  console, which only prints `Possessed PlayerPawn` for humans:

  ```sh
  L=$(ls -t "$UT_DIR/../Logs/Unreal.ngLog."* | head -1)
  iconv -f UTF-16LE -t UTF-8 "$L" | tr -d '\r' \
    | grep -E 'player\s(Connect|IsABot|Skill|Score)'
  # 16.91 player Connect SpaceGaucho 0 False   <- you
  # 28.59 player Connect Archon      1 False   \
  # 28.59 player IsABot  1 True                 /  three bots, Skill 3
  ```

  No bots at all? Check `MinPlayers` in the game type's ini section (see
  [Why --bots/--goal/--time are written into the ini](#why---botsgoaltime-are-written-into-the-ini)).
  Bots that feel the same difficulty no matter what `--skill` does? That is normal
  in the logged numbers (bot pawns default to `Skill 3` and the value is clamped);
  the ini key drives the novice flag instead. See the `--skill` note above.
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
