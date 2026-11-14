# Caveats & troubleshooting

Part of the [ut99-socat-tailcat](../README.md) docs.

- **Datagram boundaries are the whole game (why a relay, not socat).** tailcat
  carries TCP byte streams; UT99 speaks UDP. The original socat bridge
  (`TCP-LISTEN ...,fork <-> UDP:...`) treats that stream as opaque bytes: when
  the game bursts packets each tick, TCP coalesces the burst into one `read`,
  and the bridge fires the merged blob at the server as **one giant UDP
  datagram**. UT99 then misparses the stream and the log fills with
  `Forged object`, `Received unwanted function`, `Recovered from extra data
  received after socket close`, `NotifyAcceptingChannel …: Refused`, and
  `corrupted packet … Disconnecting`; a session can grind or the server can
  die outright (its `UCC.log` ends mid-line, no `Log file closed`). Once the
  server is gone the bridge starts spamming `read(5, …): Connection refused`
  — that error is the **symptom**, check the server log first.
  `scripts/ut99-bridge.py` replaced socat on both sides: every datagram gets a
  `TYPE(1B)|LEN(2B)|payload` frame, so TCP coalescing can no longer merge
  them. Measured: a tight burst of 40 datagrams came out of the old chain as 4
  merged blobs; through the relay all 40 arrive intact, game and query
  channels separate, one relay session per client socket. (This socat build
  also lacks its `TUNNEL:` framing addresses, which would have been the
  built-in equivalent.)
- **Diagnosing a broken session** (469 writes `UCC.log` / `ut99-client.log` as
  UTF-8 with BOM + CRLF):
  `grep -aE 'Forged object|unwanted function|extra data|Refused|corrupted packet|timed out' "$UT_DIR/UCC.log" | sort | uniq -c`
  — a healthy bridged session produces **none** of these. A lone
  `extra data received after socket close` right after a client quit is
  normal engine noise.
- **Client auto-join**: `ut99 client` auto-joins `127.0.0.1:$UT_UDP_PORT`
  a few seconds after launch, *while the intro movies play*. Verified on this
  469 install with the full tunnel. While a connect attempt is pending the
  intro **loops** — `CityIntro` keeps replaying until the connection lands or
  the engine's ~150 s connect timeout fires. A client stuck looping the intro
  therefore means the connect never landed: a stalled handshake (old
  byte-stream bridges produced exactly that — see the relay bullet above), a
  wrong port agreement (`--bridge-port` is your local TCP port; the side
  dialing the host must match its port via `--host-port`), or nothing
  listening on the local UDP port yet — start in order: server → host bridge
  → client bridge → game (the wrapper does this for you and waits for the
  bridge). After the 150 s timeout the client falls back to the menu/browser,
  which looks like a second, spontaneous re-join. If the connect stalls
  **mid-game** and then the intro loops again, the server likely died
  (check `UCC.log`, bullet above). In-game fallback: **Multiplayer → Join
  Game → Open Game** → `127.0.0.1:7777` (or your `--port`). There is no
  `-nointro` on 469.
- **`?port=` URLs work on 469**: `ut99 server --port N` appends `?port=N` so
  UCC binds N. The server also binds **N+1** (UDP) for `UdpServerQuery`
  (server-browser queries). The client relay binds `N+1` too and routes it to
  the *server's* query port through the tunnel, so a query probe to
  `127.0.0.1:7780` reaches a server on `7777`/`7778` even when your client
  uses split ports (e.g. `--port 7779`, join URL `127.0.0.1:7779`). Just
  don't let a loopback client bridge reuse the server's own `7777`/`7778`.
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
  [ini options](ini-options.md#why---bots--goal--time-are-written-into-the-ini)).
  Bots that feel the same difficulty no matter what `--skill` does? That is normal
  in the logged numbers (bot pawns default to `Skill 3` and the value is clamped);
  the ini key drives the novice flag instead. See the `--skill` note in
  [ini options](ini-options.md).
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
- **Friend's game dies right after launch** (`err:wgl:egl_init Failed to load
  libEGL.so.1`, `Failed to load libGL`, `OpenGL support is disabled`, then
  `Library d3d11.dll ... needed by D3D11Drv.dll not found`): their distro has
  wine but not the desktop GL loader libraries, so wined3d gets no GL context
  and 469's D3D11Drv renderer can't load. Install them — Ubuntu/Debian
  `sudo apt install libgl1 libegl1 libgl1-mesa-dri`, Arch `sudo pacman -S
  mesa`, Fedora `sudo dnf install mesa-libGL mesa-libEGL mesa-dri-drivers` —
  `./ut99 deps` now checks for this. If apt answers "already the newest
  version", what's missing is the **32-bit** copies (469 is a 32-bit process):
  `sudo dpkg --add-architecture i386 && sudo apt update && sudo apt install
  libgl1:i386 libegl1:i386 libgl1-mesa-dri:i386`; confirm with
  `ldconfig -p | grep -E 'lib(GL|EGL)\.so\.1'` — 32-bit entries show as
  `(libc6)`, 64-bit ones as `(libc6,x86-64)`. `err:hid:udev_bus_init UDEV
  monitor creation failed` is harmless (input permissions), and the wall of
  `dbghelp/dwarf2 fixme` lines is just wine dumping the crash backtrace, not
  a second cause.
- **`Critical Error: Assertion failed: RenDev` on a friend's machine**
  (`Assertion failed: RenDev [File:.\WinViewport.cpp]`, `Video: No Video` in
  the crash log header): the assertion fires in `UWindowsViewport::OpenWindow`
  called from `UGameEngine::Init`, and it means the global `RenDev` is null —
  the render device object never initialized. Until wine has a working GL
  context in the game's process, ini resolution tweaks and device swaps are
  irrelevant (all 469 renderers end up going through wine's GL): install the
  32-bit GL libs from the previous bullet (the `./ut99 deps` 32-bit warning
  confirms it), or run the 32-bit game under the 64-bit WoW64 host
  (`WINE_BIN=wine64 ./ut99 client …`) if that binary exists. The deployed
  prefix's `UnrealTournament.ini` also pins the host's renderer
  (`GameRenderDevice=D3D11Drv.D3D11RenderDevice`, `WindowedViewportX/Y` from
  the host's monitor); once GL works, lower the viewports if the friend's
  screen is smaller, and if D3D11Drv still fails on their Intel iGPU switch
  to OpenGLDrv (safest under wine/Mesa):
  `sed -i 's/^GameRenderDevice=.*/GameRenderDevice=OpenGLDrv.OpenGLRenderDevice/' ~/wine/unreal-tournament/drive_c/UnrealTournament/System/UnrealTournament.ini`
  (or `D3D9Drv.D3D9RenderDevice`).
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
