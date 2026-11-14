# Game options deep dive

Part of the [ut99-socat-tailcat](../README.md) docs. The flags themselves are
listed in the [server game options table](../README.md#server-game-options);
this page covers what the engine actually does with them.

## Why `--bots`/`--goal`/`--time` are written into the ini

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
