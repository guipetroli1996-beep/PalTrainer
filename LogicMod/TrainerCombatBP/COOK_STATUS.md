# TrainerCombatBP cook status

| Item | Status |
|------|--------|
| UE 5.1 | `D:\Programas\UE_5.1` |
| Wwise plugin in PMK | Done |
| PMK `D:\PalworldModdingKit` | Done |
| Shipped pak | [`dist/TrainerCombatBP.pak`](./dist/TrainerCombatBP.pak) (~6.7KB) — **working**, committed for players |
| Game `LogicMods/TrainerCombatBP.pak` | Same file after `install-to-game.bat` / deploy |

Compressed LogicMods this small are normal. Older notes calling ~3KB packs “empty stubs” referred to broken label-only cooks; the shipped ~6.7KB pack includes ModActor and loads in-game (`bp: ModActor cached`).

## Players

Install via repo root `install-to-game.bat` — no Unreal cook required.

## Maintainers (re-cook)

```powershell
cd "D:\Palworld - trainer combat project"
powershell -File scripts\cook-logicmod-prep.ps1
# Package in UE 5.1 (see BLUEPRINT_BUILD.md), then:
powershell -File scripts\deploy-logicmod.ps1
Copy-Item "E:\SteamLibrary\steamapps\common\Palworld\Pal\Content\Paks\LogicMods\TrainerCombatBP.pak" `
  ".\LogicMod\TrainerCombatBP\dist\TrainerCombatBP.pak" -Force
```

`scripts\deploy-logicmod.ps1` refuses packs under 5KB (true empty stubs).
