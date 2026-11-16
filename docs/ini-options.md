# Game options deep dive

Part of the [ut99-tailcat](../README.md) docs. The flags themselves are
listed in the [server game options table](../README.md#server-game-options);
this page covers what the engine actually does with them (verified against
the shipped 469 sources: `System/Botpack.u` decompiles via `DeCompiler.exe`,
and `Botpack` sources 469 are public).

## Why `--bots`/`--goal`/`--time` are written into the ini

A map URL option only works if the game class running the match actually
parses it in `InitGame()`, and a `config` key is only read from the ini
section of the class that *declares* it. Per option:

| option | ini key (where it must sit) | URL option? |
|---|---|---|
| `--bots` | `MinPlayers` — `var() globalconfig` **declared in `DeathMatchPlus`**, so the engine reads it from `[Botpack.DeathMatchPlus]` whatever game mode runs | none — `DeathMatchPlus.InitGame()` never parses `?MinPlayers` |
| `--time` | `TimeLimit` — plain `config` in `DeathMatchPlus`, read from the section of the class running the game | `?TimeLimit=N` ✓ |
| `--goal` (dm modes) | `FragLimit` — plain `config`, same rule | `?FragLimit=N` ✓ |
| `--goal` (CTF/Domination/Assault) | `GoalTeamScore` — `config float` in `TeamGamePlus`; `CTFGame.InitGame()` hard-sets `FragLimit = 0`, so the team goal key is `GoalTeamScore` | none |
| `--skill` | `[Botpack.ChallengeBotInfo] Difficulty` — see below | none |

Two traps measured on this install:

* `[Botpack.CTFGame] MinPlayers=4` was **ignored** — `globalconfig` keys are
  read from the declaring class's section only. The ngLog then logged
  `MultiPlayerBots False` (= `MinPlayers 0`) and no bot ever spawned.
* `GoalScore` is **not a property** of any shipped 469 game class (an old
  myth from pre-CTF mods); the real keys are `FragLimit` / `GoalTeamScore`.
  `ut99 server` deletes stale `GoalScore=` keys older versions may have left.

So `ut99 server` writes the ini block before launching UCC *and* passes the
`?TimeLimit=` (+ `?FragLimit=` in dm-family modes) URL options the game
class really reads:

```ini
[Botpack.DeathMatchPlus]
MinPlayers=4        # total players: you + 3 bots (all modes!)

[Botpack.CTFGame]
GoalTeamScore=5
TimeLimit=15

[Botpack.ChallengeBotInfo]
Difficulty=3
```

URL options apply only to the map they start, the ini keys are what a map
change (`server.nextmap`) re-reads — writing both is why changing maps on a
running server keeps your settings. `ini_set` replaces a key in place (or
adds it), keeps CRLF line endings and touches nothing else; `--no-ini` (or
`--opts RAW`) leaves your ini alone, and then those numbers have to come
from the ini itself.

## `--skill` and bot difficulty

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

## When bots actually spawn

Bot timing, straight from `DeathMatchPlus.Timer()`: the server never fills
bots before a human is present. Once someone joins it waits `NetWait` seconds
(default 10) and then adds one bot per second until `NumPlayers + NumBots`
reaches `MinPlayers`. So expect the first bot ~12 s after your join — not at
server start.

Live measurement (`ut99 server --bots 4 --skill 3`, ngLog): human joins at
31 s, bots `IsABot True` connect at 42.9 / 43.9 / 45.1 s, `game_start` at
46.2 s — 1 human + 3 bots = `MinPlayers`, exactly the `NetWait` pattern.
