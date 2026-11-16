# Admin web interface & API

Part of the [ut99-tailcat](../README.md) docs.

`ut99 server --admin` enables UT99's own built-in admin: the engine ships
`UTServerAdmin.u`, served by `UWeb.WebServer` as plain HTTP with HTTP Basic
auth under `/ServerAdmin/`. ut99 just turns it on, sets a login, and (with a
tailcat bridge) also serves the port on the same `tcp...` address — so the
host **and** friends can drive the **running match** from a browser or curl.
Everything below was verified live on the OldUnreal 469 GOTY install.

## Enabling it

```bash
./ut99 server --admin                      # web admin on :8080, random password printed at startup
./ut99 server --admin --admin-port 8090 --admin-pass secretpass
```

ut99 writes into `UnrealTournament.ini`:

```ini
[UWeb.WebServer]
bEnabled=True
ListenPort=8090
[UTServerAdmin.UTServerAdmin]
AdminUsername=admin
AdminPassword=secretpass
```

- Without `--admin-pass`, ut99 generates a random 12-char password and prints
  it in the startup lines. An **empty** `AdminPassword` in the ini lets
  *anyone* through (the engine only checks a non-empty string), so ut99 always
  sets one — keep it that way if you edit the ini by hand.
- `--admin-port` picks the HTTP port; 8080 is a common collision, pick another
  if your machine already uses it. The engine binds `0.0.0.0`, so LAN hosts
  can reach it directly.
- The pages are plain HTTP with Basic auth (credentials in clear text). Over
  the tailcat tunnel that's fine (the tunnel is encrypted); over a plain LAN
  treat the password as LAN-only.

## Access from a friend's machine

The host bridge serves the admin port alongside the game port
(`tailcat serve 8777,8090`), and on the client side one flag does the rest:

```bash
./ut99 client tcpXXXXXXXXXXXX --admin
# -> [admin] host web admin -> http://127.0.0.1:18080/ServerAdmin/
```

`--admin-port` changes the local port (default 18080); `--host-admin-port`
must match what the server used (default 8080). The admin forward is a
separate job: if it fails (port clash, host without `--admin`) the game run
is unaffected. On LAN, `./ut99 client --lan --admin` just prints the host's
admin URL — nothing to forward.

## The pages

Index: `http://<host>:<port>/ServerAdmin/` (or `.../current_menu`), with
sections for *Current game* (players, game, console, restart) and *Defaults*
(settings, rules, bots, maps, mutators, IP policy for **newly started**
games). With curl:

```bash
A='-u admin:secretpass'
S=http://127.0.0.1:8090/ServerAdmin

curl $A $S/current_players      # player list: name, (Bot), team, ping, score, IP
curl $A $S/current_game         # current map + game type, switch forms
curl $A $S/current_console      # "server console" text box
curl $A $S/current_console_log  # live console/event log of the match
curl $A $S/current_restart      # restart current map + game type
```

Wrong or missing credentials return `401`, so the whole surface is a
`curl`-able JSON-less API: POST the same form fields a browser would.

## Controlling the running match (all verified live)

### Console page = any server console command

```bash
curl $A --data-urlencode 'SendText=get botpack.ctfgame TimeLimit'    $S/current_console
curl $A --data-urlencode 'SendText=say hello everyone'               $S/current_console
curl $A --data-urlencode 'SendText=get botpack.deathmatchplus MinPlayers' $S/current_console
curl $A $S/current_console_log   # results appear as '> ' lines
```

`SendText` with a `say ` prefix broadcasts a chat line (`(Event) Admin: ...`);
anything else runs through `Level.ConsoleCommand()` — `get`/`set` of any
engine class property works.

### Bots

```bash
curl $A --data-urlencode 'SendText=set botpack.deathmatchplus MinPlayers 5' $S/current_console
```

Verified: with one human connected the bot list grew to fill exactly
`MinPlayers` players total (bots join one by one ~12 s after you connect —
the `NetWait=10` timer; be patient before refreshing `current_players`).
`MinPlayers` is `var() globalconfig` in `Botpack.DeathMatchPlus` (see
[ini-options.md](ini-options.md)), so it lives in `[Botpack.DeathMatchPlus]`
for *every* game type and persists across matches.

- **Removing bots**: the engine only ever *adds* bots (`Timer()` →
  `AddBot()`), and bots have no Kick checkbox on `current_players` (only
  humans do). Verified flow: lower `MinPlayers` via the console, then
  `curl $A $S/current_restart` — the restarted match fills to the new count.
- `addbots N` and `killall bot` as `SendText` return `200` but had **no
  effect** on the player list in live tests — don't rely on them here.
- Kicking humans: `current_players` shows `Kick`/`BanIP` checkboxes per human
  (`KickPlayer0`/`BanPlayer0` form fields + the *Kick / Ban* button).

### Map and game mode switching

`current_game` holds the select forms; posting their buttons switches the
live match via `Level.ServerTravel()` — players stay connected:

```bash
curl $A -d 'SwitchMap=Switch&MapSelect=CTF-Command' $S/current_game
curl $A -d 'SwitchGameTypeAndMap=Switch&MapSelect=DM-117&GameTypeSelect=Botpack.DeathMatchPlus' $S/current_game
```

Verified: `CTF-Face` → `CTF-Command` → `DM-117`/`DeathMatchPlus`, with the
match settings (`TimeLimit`, new `MinPlayers`) carried into the new match;
allow 10–15 s for the level change, then check `current_players` /
`current_console_log`.

### Restart

```bash
curl $A $S/current_restart
```

Server-travels to the current map with the current game type and mutators —
the way to re-apply bot counts or clean up a match.

## Defaults pages

`defaults_rules`, `defaults_bots`, `defaults_settings`, `defaults_maps`,
`defaults_server` … edit the engine's **config** for games you start *next*
(the same keys [ini-options.md](ini-options.md) covers). They do not retune a
match already running — use the console page for that.
