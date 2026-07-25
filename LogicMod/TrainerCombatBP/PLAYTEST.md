# Playtest — LogicMod otomo standby

## Before playtest

1. Lua deployed (done if you ran `install-to-game.bat` to `...\ue4ss\Mods`).
2. LogicMod pak (optional but preferred):
   - Install UE 5.1 + Wwise, open `D:\PalworldModdingKit\Pal.uproject`
   - Build ModActor per `LogicMod/TrainerCombatBP/BLUEPRINT_BUILD.md`
   - `scripts\deploy-logicmod.ps1` → `Paks\LogicMods\TrainerCombatBP.pak`
3. Fully quit Palworld and relaunch (no Ctrl+R with PalSchema).

## Checklist

1. Console shows `[TrainerCombat] loaded (... logicmod-bridge)`.
2. If pak present: `bp: ModActor cached`. If not: `bp: TrainerCombatBP ModActor not loaded yet — using Lua NotCombat fallback`.
3. Throw a Pal → announce standby / NotCombat.
4. Fight with spear **without** marking → Pal must **not** attack and stay near you.
5. Aim + LMB on a wild Pal → `Marked: <localized name>` (e.g. Lamball).
6. H or J clears mark; Pal stays on standby.
7. Recall Pal → order returns toward Default; no nullptr spam.

## Pass / fail notes

| Case | Expected |
|------|----------|
| No pak, NotCombat works | Temporary pass until LogicMod cooked |
| No pak, Pal still free-fights | Fail — finish LogicMod cook |
| Pak loaded, Pal still free-fights | Fail — check ForceOtomoStandby graph / NotCombat call |
| Aim+LMB mark name wrong | Fail — localized name path (Lua) |

Log snippets to capture: `RequestSetOtomoOrder(NotCombat)`, `bp: SetManualStandby(true)`, any `Combat_Standard` spam.
