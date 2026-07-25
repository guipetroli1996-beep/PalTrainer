# PalTrainer (Palworld)

Single-player **UE4SS** Lua mod (+ optional LogicMod) that turns the player into a **trainer**: combat is meant for your active Pal, not you.

GitHub repo name: **PalTrainer** · in-game mod folder: `TrainerCombat`

**Full plan:** see [`ROADMAP.md`](./ROADMAP.md)

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
| 3 | Aim+LMB filler + follow-only standby | Working (Lua NotCombat fallback) |
| 3 | Aim+1/2/3 skill orders | Working |
| 3 | LogicMod standby (stronger than Lua) | Optional — cook currently broken/stub |
| 3 | Aim skill UMG HUD | Parked (off by default) |
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

## Install this mod (Lua)

From this project folder:

```bat
install-to-game.bat "<Steam>\steamapps\common\Palworld\Pal\Binaries\Win64\Mods"
```

If your UE4SS install uses the nested layout, point at `...\Win64\ue4ss\Mods` instead.

Also add/enable it in `Mods\mods.txt` if your UE4SS build requires that:

```
TrainerCombat : 1
```

## Phase 3 standby — LogicMod (optional)

Lua alone cannot always stop `PalAIActionCombat_Standard`. A cooked **LogicMod** is the preferred standby path when available.

**Current reality:** the last cook produced an empty/stub `pakchunk7` (~3KB). Deploy refuses that stub. Until a real `.pak` exists, Lua uses a **NotCombat order fallback** (filler + skills still work).

### Prerequisites (when re-cooking)

| Step | Notes |
|------|--------|
| [Palworld Modding Kit](https://pwmodding.wiki/docs/developers/palworld-modding-kit/prerequisites) | Clone locally |
| UE **5.1** + Wwise **2021.1.11** | Required by PMK |
| Blueprint ModActor wired + cooked | Follow [`LogicMod/TrainerCombatBP/BLUEPRINT_BUILD.md`](./LogicMod/TrainerCombatBP/BLUEPRINT_BUILD.md) |
| Deploy `.pak` to `Paks/LogicMods` | `scripts\deploy-logicmod.ps1` (refuses pak &lt; ~10KB) |

See also [`LogicMod/TrainerCombatBP/COOK_STATUS.md`](./LogicMod/TrainerCombatBP/COOK_STATUS.md).

### Quick path

1. Install PMK prereqs (UE 5.1, VS 2022, .NET 6, Wwise 2021.1.11).
2. Check kit: `powershell -File scripts\setup-pmk.ps1`
3. Open `Pal.uproject` from your PMK clone; run Editor Python:  
   `LogicMod\TrainerCombatBP\Editor\CreateTrainerCombatLogicMod.py`
4. Wire graphs per `BLUEPRINT_BUILD.md` (core call: `RequestSetOtomoOrder(NotCombat)`).
5. Package Windows → copy a **non-stub** `pakchunk7-Windows.pak` →  
   `Palworld\Pal\Content\Paks\LogicMods\TrainerCombatBP.pak`  
   or: `powershell -File scripts\deploy-logicmod.ps1`
6. Quit + relaunch Palworld. Console should show `bp: ModActor cached`.

## Verify it works

1. Start Palworld (single-player).
2. Open the UE4SS GUI console.
3. You should see: `[TrainerCombat] loaded`
4. Enter a world, throw a Pal → standby / follow-only (Lua NotCombat if no LogicMod).
5. Aim+LMB on a hostile → Pal filler attack, then standby.
6. Aim+1/2/3 while aiming → equipped skill orders (vanilla 1/2/3 Pal/sphere switch suppressed while aiming).
7. In combat, swap/recall should hit summon lock CD; sphere throws use sphere CD.

## Dev workflow

1. Edit sources in this repo.
2. After Lua edits, run `install-to-game.bat` (or copy `TrainerCombat` into the game `Mods` folder).
3. **Do not use Ctrl+R hot reload** while PalSchema (or other C++ UE4SS mods) are installed — it can crash during uninstall.
4. After updating Lua: **fully quit Palworld and relaunch**.
5. After a successful LogicMod cook: run `scripts\deploy-logicmod.ps1`, then full relaunch.

## Config

Edit `TrainerCombat\Scripts\config.lua` (cooldown seconds, debug logging, feature flags).

Relevant knobs:

- `Features.MarkStandby`
- `Features.SummonLock` / `SummonLockOnlyInCombat`
- `MarkStandby.LogicMod.Enabled`
- `MarkStandby.SkillOrder.Enabled` / `Features.AimSkillKeyProbe`
- `MarkStandby.AnnounceAttackCommands` / `AnnounceSkillCommands` / `AnnounceSkillCooldown`
- `Hud.UseAimSkillHud` (UMG skill bar — parked / off by default)

## Notes

- **Single-player only** for now.
- Tools keep normal gathering/building (tool combat-damage zeroing cancelled).
- Game updates can rename Blueprint paths — if hooks stop firing, re-find them in Live View.
- Public repo: anyone can view/fork; only the owner can push commits unless collaborators are added.
