# PalTrainer (Palworld)

Single-player **UE4SS** Lua mod (+ LogicMod pak) that turns the player into a **trainer**: combat is meant for your active Pal, not you.

GitHub repo name: **PalTrainer** · in-game mod folder: `TrainerCombat`

**Full plan:** see [`ROADMAP.md`](./ROADMAP.md)

Discontinued Aim+LMB filler / Aim+1/2/3 skill-order build: branch `archive/aim-lmb-skills`.

## Status

| Phase | Feature | Status |
|------|---------|--------|
| 0 | UE4SS + empty mod loads / logs | Done |
| 1 | Pal summon lock + blocked-attempt announce | Working |
| 1 | Block player weapon combat use | Working |
| 1 | Hide weapons from tech/crafting/loot | Working |
| 1 | Capture sphere throw cooldown | Working |
| 2 | Attack stat boosts party Pals | Working |
| 2 | Enemies prefer Pal (aggro assist) | Working |
| 3 | Unmarked Pal standby (LogicMod / NotCombat) | Working |
| 3 | Aim+MMB mark → engage (vanilla Pal AI) | Working |
| 3 | Shipped LogicMod `.pak` | Working (`LogicMod/TrainerCombatBP/dist/`) |
| 4 | Multiplayer | Not started |

> Tool combat-damage zeroing was cancelled (not in scope).  
> Player damage reduction / transfer to Pal is coded but **disabled** (aggro-only preferred).

## Install UE4SS (Steam)

1. Download the latest **UE4SS** experimental/zDev build for Palworld from [UE4SS releases](https://github.com/UE4SS-RE/RE-UE4SS/releases) (or the build linked by [pwmodding.wiki](https://pwmodding.wiki/)).
2. Extract into:
   ```
   <Steam>\steamapps\common\Palworld\Pal\Binaries\Win64\
   ```
   You should see `UE4SS.dll`, `dwmapi.dll` (or the current injector), `UE4SS-settings.ini`, and a `Mods` folder.
3. Edit `UE4SS-settings.ini`:
   ```ini
   GuiConsoleEnabled = 1
   GuiConsoleVisible = 1
   EnableHotReloadSystem = 1
   ```
4. Launch the game once so UE4SS creates runtime folders.

## Install this mod

From this project folder (Lua + shipped LogicMod pak):

```bat
install-to-game.bat "<Steam>\steamapps\common\Palworld\Pal\Binaries\Win64\Mods"
```

If your UE4SS install uses the nested layout, point at `...\Win64\ue4ss\Mods` instead.

The installer copies:

| Piece | Destination |
|-------|-------------|
| `TrainerCombat/` (Lua) | `...\Mods\TrainerCombat\` |
| `LogicMod/TrainerCombatBP/dist/TrainerCombatBP.pak` | `...\Pal\Content\Paks\LogicMods\TrainerCombatBP.pak` |

Also add/enable it in `Mods\mods.txt` if your UE4SS build requires that:

```
TrainerCombat : 1
```

Manual pak copy (if the bat cannot find `Content\Paks`):

```
LogicMod\TrainerCombatBP\dist\TrainerCombatBP.pak
  →  <Steam>\steamapps\common\Palworld\Pal\Content\Paks\LogicMods\TrainerCombatBP.pak
```

Without the pak, Lua still uses a **NotCombat order fallback** (weaker standby).

## Verify it works

1. Start Palworld (single-player).
2. Open the UE4SS GUI console.
3. You should see: `[TrainerCombat] loaded`
4. Prefer also: `bp: ModActor cached` (LogicMod pak loaded).
5. Throw a Pal → standby / follow-only (no free fight).
6. Aim+MMB on a hostile → mark announce + Pal engages with vanilla combat AI.
7. Aim+MMB the same target again → clear mark, Pal returns to standby.
8. In combat, swap/recall should hit summon lock CD; sphere throws use sphere CD.

## Dev workflow

1. Edit sources in this repo.
2. After Lua / pak edits, run `install-to-game.bat` (or copy files manually).
3. **Do not use Ctrl+R hot reload** while PalSchema (or other C++ UE4SS mods) are installed — it can crash during uninstall.
4. After updating: **fully quit Palworld and relaunch**.
5. After re-cooking the LogicMod: replace `LogicMod/TrainerCombatBP/dist/TrainerCombatBP.pak`, then reinstall.

## Config

Edit `TrainerCombat\Scripts\config.lua` (cooldown seconds, debug logging, feature flags).

Relevant knobs:

- `Features.MarkStandby`
- `Features.SummonLock` / `SummonLockOnlyInCombat`
- `MarkStandby.LogicMod.Enabled`
- `MarkStandby.ManualAttackOnly` / `BlockOtomoDamage`
- `MarkStandby.AnnounceMark`

## Rebuild LogicMod (optional — maintainers)

Players do **not** need UE / Wwise. Only rebuild if you change Blueprint standby:

See [`LogicMod/TrainerCombatBP/BLUEPRINT_BUILD.md`](./LogicMod/TrainerCombatBP/BLUEPRINT_BUILD.md) and [`COOK_STATUS.md`](./LogicMod/TrainerCombatBP/COOK_STATUS.md). After packaging, copy the new chunk into `LogicMod/TrainerCombatBP/dist/TrainerCombatBP.pak` (or run `scripts\deploy-logicmod.ps1` and copy from the game `LogicMods` folder back into `dist/`).

## Notes

- **Single-player only** for now.
- Tools keep normal gathering/building (tool combat-damage zeroing cancelled).
- Game updates can rename Blueprint paths — if hooks stop firing, re-find them in Live View.
- Public repo: anyone can view/fork; only the owner can push commits unless collaborators are added.
