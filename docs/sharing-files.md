# Sharing the game install (one-time setup for friends)

Part of the [ut99-tailcat](../README.md) docs. The quick-start version of
these commands is in the README; this page has the full details and notes.

Instead of each friend installing and patching UT99 themselves, pack your
working Lutris wine prefix into a single tarball; they extract it into their
own `WINEPREFIX` and can immediately run everything.

```sh
# host side
./ut99 pack          # -> files/ut99-wineprefix.tgz (+ .sha256), ~560M
./ut99 file-serve    # serves both files read-only over tailcat; once the
                     # tcp... address is up it prints the exact fetch
                     # commands your friends should paste:
# Friends fetch with (while this runs):
#   Linux/macOS:  ./ut99 file-pull tcpGFwWC…FpGQEt --deploy
#   Windows:      .\ut99.cmd file-pull tcpGFwWC…FpGQEt --deploy
# (no repo clone:  tailcat cp tcpGFwWC…FpGQEt:ut99-wineprefix.tgz files/)
```

Getting the files on the client side (what each friend runs):

```sh
# friend side, in their own clone/copy of this repo (ut99, scripts/, helpers/)
./ut99 deps                                        # installs tailcat, checks python3 + wine
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
  strings. `file-serve` defaults to its own saved key (`ut99-files`, override
  via `UT99_FILE_SERVE_KEY` or `--tc-key`): two tailcat processes sharing one
  saved key are the same node and then `tailcat cp` to that address times
  out. Both addresses are only live while the host's command runs (unless a
  saved key is used).
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
- **See when friends pull files**: `./ut99 file-serve -v` (or `--verbose`,
  same as `UT99_VERBOSE=1`) runs tailcat with its verbose log and keeps only
  the meaningful lines — each fetch prints something like
  `# friend connected from [fd7a:115c:…]:50777 — pulling files` the moment
  the friend's SFTP connection opens (the tailnet address identifies who).
  tailcat logs fetch *starts*, not fetch completions or file names, and the
  default quiet view shows nothing. The same `-v` on `ut99 server` restores
  the full raw bridge/tailcat log instead of the curated view.

## What gets packed

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
install `tailcat`: run `./ut99 deps` too.
