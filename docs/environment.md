# Engine environment variables

Part of the [ut99-tailcat](../README.md) docs.

The wrapper maps flags onto these; when using `scripts/` directly, set them
yourself. Defaults match the Lutris `unreal-tournament` install (wine runner,
system wine):

| Variable              | Default                                       | Meaning                              |
|-----------------------|-----------------------------------------------|--------------------------------------|
| `WINEPREFIX`          | `~/wine/unreal-tournament`                    | Lutris wine prefix of the game       |
| `UT_DIR`              | `$WINEPREFIX/drive_c/UnrealTournament/System` | Game `System` dir (UCC.exe lives here) |
| `WINE_BIN`            | `wine`                                        | Wine binary to use                   |
| `UT_UDP_PORT`         | `7777`                                        | UT99 server/client UDP port          |
| `BRIDGE_TCP_PORT`     | `8777`                                        | local relay↔tailcat TCP port (both sides) |
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
