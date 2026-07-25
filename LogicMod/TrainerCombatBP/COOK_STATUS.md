# TrainerCombatBP cook status

| Item | Status |
|------|--------|
| UE 5.1 | **Found** at `D:\Programas\UE_5.1` |
| Wwise plugin in PMK | Done (`Plugins\Wwise`) |
| PMK `D:\PalworldModdingKit` | Done |
| `Content/Mods/TrainerCombatBP/ModActor.uasset` | Present (~82KB) |
| PrimaryAssetLabel `TrainerCombatBP` | Present |
| Cooked `pakchunk7-Windows.pak` | **Broken / empty (~3124 bytes)** — assets not in chunk |
| Game `LogicMods/TrainerCombatBP.pak` | Same stub until re-package |
| Aim Skill HUD Lua (announce) | Working |
| Aim Skill HUD UMG (`WBP_AimSkillHud`) | Needs scaffold + ModActor wire + **re-cook** |

## Why HUD is only announce today

Palworld does not paint Engine Canvas. Real ride-style bar needs UMG in chunk **7**.  
Last package produced an **empty** chunk 7 (label only), so UE4SS never got ModActor/WBP.

## Fix (re-cook)

```powershell
cd "D:\Palworld - trainer combat project"
powershell -File scripts\cook-logicmod-prep.ps1
# Optional: -RunEditorPython  (opens UnrealEditor-Cmd, slow)

# Then in Editor (D:\Programas\UE_5.1 → open Pal.uproject):
# 1. Execute Python: Content/Mods/TrainerCombatBP/Editor/CreateTrainerCombatLogicMod.py
# 2. Wire AimSkillHud on ModActor (BLUEPRINT_BUILD.md)
# 3. PrimaryAssetLabel: Chunk 7, Always Cook, Label Assets in My Directory
# 4. Platforms → Windows → Package Project
# 5. powershell -File scripts\deploy-logicmod.ps1
#    (script refuses to deploy if pak < 10KB)
```

After a good cook, `pakchunk7-Windows.pak` should be **much larger than 3KB**.
