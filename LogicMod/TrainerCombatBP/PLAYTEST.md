# Playtest — Controlled Pal (Aim+MMB)

## Before playtest

1. Lua deployed (done if you ran `install-to-game.bat` to `...\ue4ss\Mods`).
2. LogicMod pak (shipped — install-to-game.bat copies it):
   - Source: `LogicMod/TrainerCombatBP/dist/TrainerCombatBP.pak`
   - Dest: `Paks\LogicMods\TrainerCombatBP.pak`
   - Rebuilders only: `BLUEPRINT_BUILD.md` + `scripts\deploy-logicmod.ps1 -UpdateShippedDist`
3. Fully quit Palworld and relaunch (no Ctrl+R with PalSchema).

## Checklist

1. Console shows `[TrainerCombat] loaded`.
2. If pak present: `bp: ModActor cached`. If not: Lua NotCombat fallback log.
3. Throw a Pal → standby / NotCombat (no free fight).
4. Fight with spear **without** marking → Pal must **not** attack and stay near you.
5. Aim + MMB on a wild Pal → `Marked: <localized name>` and Pal **engages** with vanilla combat AI.
6. Aim + MMB the **same** target again → mark clears, Pal returns to standby.
7. Recall Pal → order returns toward Default; no nullptr spam.

## Pass / fail notes

| Case | Expected |
|------|----------|
| No pak, NotCombat works | Temporary pass until LogicMod cooked |
| No pak, Pal still free-fights unmarked | Fail — finish LogicMod cook / check Lua fallback |
| Pak loaded, Pal still free-fights unmarked | Fail — check ForceOtomoStandby graph / NotCombat call |
| Aim+MMB mark, Pal never engages | Fail — check `releaseToEngage` / ManualStandby off |
| Remake same mark, Pal keeps fighting freely | Fail — toggle-clear path must re-arm standby |

Log snippets to capture: `RequestSetOtomoOrder(NotCombat)`, `mark: ENGAGE`, `bp: SetManualStandby`, any `Combat_Standard` spam while unmarked.
