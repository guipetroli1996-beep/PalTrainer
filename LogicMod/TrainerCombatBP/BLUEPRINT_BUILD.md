# TrainerCombatBP — LogicMod Blueprint Build

Cooked target: `Pal/Content/Paks/LogicMods/TrainerCombatBP.pak`  
PMK path: `D:\PalworldModdingKit`  
Chunk ID: **7**

This LogicMod owns **otomo standby** on the game thread while the Pal is unmarked.
Lua handles Aim+MMB mark → engage (`ManualStandby=false`) and clear-mark → standby.

## Prerequisites

1. UE 5.1 + VS 2022 + .NET 6 + Wwise 2021.1.11 (see [pwmodding.wiki](https://pwmodding.wiki/docs/developers/palworld-modding-kit/prerequisites))
2. PMK cloned to `D:\PalworldModdingKit` (already done)
3. Wwise plugin integrated into PMK `Plugins\`
4. Open `D:\PalworldModdingKit\Pal.uproject` once and let it compile

Optional: run Editor Python  
`LogicMod/TrainerCombatBP/Editor/CreateTrainerCombatLogicMod.py`  
to scaffold folder / ModActor / PrimaryAssetLabel, then wire the graph below by hand.

## Assets

Create under `Content/Mods/TrainerCombatBP/`:

| Asset | Type | Notes |
|-------|------|--------|
| `ModActor` | Blueprint Class (parent: Actor) | Exact name required by UE4SS |
| `TrainerCombatBP` | Primary Asset Label | Chunk **7**, Always Cook, Label Assets in My Directory |

### ModActor variables

| Name | Type | Default |
|------|------|---------|
| `ModAuthor` | String | `TrainerCombat` |
| `ModDescription` | String | `Otomo follow-only standby for TrainerCombat` |
| `ModVersion` | String | `0.1.0` |
| `ManualStandby` | Boolean | `false` |
| `StandbyTimerHandle` | Timer Handle | (none) |
| `StandbyInterval` | Float | `0.35` |

### Custom events / functions (must match Lua names)

#### `PrintToModLoader` (Custom Event)
- In: `Message` (String)
- Body: no-op for graph; UE4SS intercepts this event name for console print.

#### `Lua_ModInitialized` (Custom Event, from PostBeginPlay)
- Out: `ModActor` (Object / TrainerCombatBP ModActor) = `self`
- Connect **PostBeginPlay** → `Lua_ModInitialized` (return self).
- UE4SS Lua registers `RegisterCustomEvent("Lua_ModInitialized", ...)`.

#### `SetManualStandby` (Function, BlueprintCallable)
- In: `Enabled` (Boolean)
- Set `ManualStandby = Enabled`
- If Enabled: call `ForceOtomoStandby("enable")`, then **Set Timer by Function Name** → `ForceOtomoStandbyTick`, looping, `StandbyInterval`
- If not Enabled: **Clear and Invalidate Timer** (`StandbyTimerHandle`), call holder `RequestSetOtomoOrder(Default)`, `PrintToModLoader("ManualStandby off")`

#### `ForceOtomoStandbyTick` (Function)
- If `ManualStandby`: call `ForceOtomoStandby("tick")`

#### `ForceOtomoStandby` (Function, BlueprintCallable)
- In: `Reason` (String) — for logging only
- Implementation (conservative):

```
1. Get Player Character (or Get Player Controller → Get Controlled Pawn)
2. Get Character Parameter Component → OtomoPal
   Fallback: Get Otomo Holder Component → TryGetCurrentSelectPalActor
3. If Otomo invalid → return
4. Holder = Get Otomo Holder Component (Pal Utility / from player)
5. Holder → RequestSetOtomoOrder (EPalOtomoPalOrderType::NotCombat)
6. Ctrl = Otomo → Get Controller
7. AI = Ctrl → Get AI Action Component
8. AI → AllCancelPushedAction (Instigator = Otomo)
9. AI → AllCancelAction_Logic_HardScript_Reaction (Instigator = Otomo)
10. Current = AI → GetCurrentAction_BP
    Top = AI → GetCurrentTopParentAction_BP
11. On Current/Top if they expose SetOtomoFollowAction → call it
    If ClearTargetCharacter exists → call it
12. Otomo.ActionComponent → CancelAllAction
13. Optional throttle: PrintToModLoader("ForceOtomoStandby: " + Reason)
```

Do **not** thrash `SetActiveAI` every tick. Prefer `NotCombat` order + follow + cancel.

## Package

1. Platforms → Windows → Package Project
2. Find `Windows\Pal\Content\Paks\pakchunk7-Windows.pak`
3. Copy/rename to game:
   ```
   <Steam>\Palworld\Pal\Content\Paks\LogicMods\TrainerCombatBP.pak
   ```
4. Or run: `scripts\deploy-logicmod.ps1`

## Verify in game

UE4SS console should show LogicMod load for `TrainerCombatBP`, then Lua:

```
[TrainerCombat] bp: ModActor cached
[TrainerCombat] mark: LogicMod standby armed
```

Throw Pal, no mark, fight → Pal must not free-fight.
Aim+MMB mark → ManualStandby off / Pal engages. H/J clear → standby again.

---

## Aim Skill HUD (ride-style while aiming)

Lua already draws a bottom-center skill bar via `AHUD:ReceiveDrawHUD` while Aim is held
(`aim_skill_hud.lua`). Optional UMG can mirror the same data from ModActor properties.

### ModActor properties (written by Lua)

| Name | Type | Notes |
|------|------|--------|
| `AimSkillHudVisible` | Boolean | Show/hide widget |
| `AimSkillHudDirty` | Boolean | Pulse true when slots change |
| `AimSkill0Name` … `AimSkill2Name` | String | Localized waza title |
| `AimSkill0CoolRemain` … `AimSkill2CoolRemain` | Float | Seconds left |
| `AimSkill0CoolMax` … `AimSkill2CoolMax` | Float | Fill denominator |
| `AimSkill0Enabled` … `AimSkill2Enabled` | Boolean | Slot has EquipWaza |

### ModActor functions (optional; UE4SS often cannot call these)

- `ShowAimSkillHud()` — create `WBP_AimSkillHud`, AddToViewport, ZOrder high, **not hit-testable**
- `HideAimSkillHud()` — RemoveFromParent / collapse
- `SetAimSkillSlot(SlotIndex, DisplayName, CoolRemain, CoolMax, Enabled)` — update one slot

### Recommended BP pattern (property-driven — matches Lua writes)

Add ModActor variables (in addition to the table above):

| Name | Type |
|------|------|
| `AimSkillHudWidget` | `WBP_AimSkillHud` Object Reference (or User Widget) |

**Event Tick** (or 0.1s timer):

```
1. If AimSkillHudVisible == false:
     If AimSkillHudWidget valid → Remove from Parent, clear ref
     Return
2. If AimSkillHudWidget invalid:
     Create Widget (Class = WBP_AimSkillHud, Owning Player = Get Player Controller)
     Add to Viewport (ZOrder = 50)
     Set Visibility = Hit Test Invisible
     Store in AimSkillHudWidget
3. If AimSkillHudDirty OR always while visible:
     For i in 0..2:
       Text = "[" + (i+1) + "] " + AimSkill{i}Name
       If AimSkill{i}CoolRemain > 0.05: Text += " " + Round(Remain) + "s"
       If not AimSkill{i}Enabled: Text = "[" + (i+1) + "] —"
       Set Text on Slot{i}Text (Get Widget From Name)
     AimSkillHudDirty = false
```

Optional UFunctions `ShowAimSkillHud` / `HideAimSkillHud` / `SetAimSkillSlot` can set the same properties; Lua already writes properties directly.

### Widget `WBP_AimSkillHud`

- 3 horizontal slots (key `1/2/3`, name, cooldown fill).
- Bottom-center anchors; `Visibility = HitTestInvisible`.
- Named TextBlocks: `Slot0Text`, `Slot1Text`, `Slot2Text` (Editor Python scaffolds these).
- Scaffold: `Editor/CreateTrainerCombatLogicMod.py`

### Package / deploy (this PC)

- UE 5.1: `D:\Programas\UE_5.1`
- Package → `D:\PalworldModdingKit\Packaged\Windows\...`
- **Reject** `pakchunk7` if only ~3KB (empty label). Must include ModActor + WBP.
- `powershell -File scripts\deploy-logicmod.ps1` (refuses stub paks)

Recook chunk **7** after adding the widget, then deploy.
Until a non-empty pak is deployed, Lua **system announce** remains the visible skill strip.
