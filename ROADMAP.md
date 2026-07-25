# Trainer Combat — Roadmap

Single-player first. Multiplayer later.

Design goal: **player is a trainer, active Pal is the fighter.**

**Out of scope:** tool combat damage zeroing (formerly Phase 4) — tools stay as-is.

**Archive:** Aim+LMB filler + Aim+1/2/3 skill orders live on branch `archive/aim-lmb-skills` (discontinued).

---

## Phase 0 — Tooling & proof of life

**Goal:** UE4SS runs and this mod loads reliably.

- [x] Project folder + mod skeleton
- [x] Install UE4SS into Steam Palworld `Pal\Binaries\Win64`
- [x] Install `TrainerCombat` into `Mods`
- [x] Confirm console: `[TrainerCombat] loaded`
- [x] Confirm console on Pal throw: `ActivateOtomo slot=...`

**Exit criteria:** Mod loads every launch; otomo activate logs every throw.  
**Status:** Done.

---

## Phase 1 — Soft trainer mode

**Goal:** Player can no longer play as a normal gun/melee fighter; Pal swap is gated in combat.

### 1A — Summon / swap lock
- [x] Summon starts lock timer + game disable flags (throw/switch)
- [x] Announce on blocked E / controller L1 during lock
- [x] Lift lock early if active Pal dies / is force-inactivated during lock
- [x] Combat-only gating: free out of combat; lock only when sending a Pal out in battle
- [x] Playtest: explore throw/recall free; fight locks swap for `SummonLockSeconds`

### 1B — Block player weapon combat
- [x] Hook `PalWeaponBase` fire/damage for **local player only**
- [x] Allowlist spheres / gathering tools
- [ ] Optional polish: Live View dig for cleaner shooter disable flags

### 1C — Hide/remove weapon schematics
- [x] Strip combat weapon rows from technology / recipes / loot
- [x] Strip combat grenades; keep `PalHealingGrenade`

### 1D — Capture sphere throw cooldown
- [x] Cooldown after throwing capture spheres (+ sphere launchers)
- [x] Does **not** affect party Pal throw (`DummyBall`) or summon lock (1A)
- [x] Announce remaining CD on blocked attempt

**Exit criteria:** Player guns/weapons don’t deal combat damage; Pal throw + tools still work; weapon schematics gone; capture spheres gated by cooldown.  
**Status:** Working (1A–1D). Optional 1B polish left.

---

## Phase 2 — Stat + threat rewrite

**Goal:** Stats and aggro reinforce trainer play.

### 2A — Attack attribute → party Pal
- [x] Scale party Pal Attack by player Attack %
- [x] Clear transfer state on recall / ClientRestart

### 2B — Threat while Pal is out
- [x] Prefer Pal aggro via hate pulse + hard retarget assist
- [x] Player DR / damage transfer implemented then **disabled** (aggro-only preferred; DR caused muteki bugs)
- [ ] Further aggro hardening if enemies still tunnel the player

**Exit criteria:** Player Attack makes the Pal stronger; standing behind your Pal is safer than solo gunplay.  
**Status:** Working (2A + 2B aggro on; DR/transfer off).

---

## Phase 3 — Controlled Pal (Aim+MMB)

**Goal:** Pal stays on standby until the player marks a target with base-game **Aim+MMB**; then vanilla Pal combat AI engages. Marking the same target again (or losing it) returns to standby.

### Implemented
- [x] No Torch / command-rod item required
- [x] Unmarked → LogicMod ManualStandby + NotCombat (Lua fallback if no pak)
- [x] Aim+MMB on hostile → sticky mark + announce + release engage (Default order)
- [x] Aim+MMB same target again → clear mark + standby
- [x] Lost / dead mark → auto clear + standby
- [x] Block otomo free damage while unmarked standby
- [x] Suppress field/base work in combat
- [x] Lua ↔ ModActor bridge (`bp_bridge.lua`) ready for LogicMod

### Removed from main (see `archive/aim-lmb-skills`)
- [x] Aim+LMB elemental filler orders
- [x] Aim+1/2/3 equipped skill orders
- [x] Aim skill key unbind / Aim skill HUD driving

### Remaining / optional
- [x] Ship cooked `TrainerCombatBP.pak` for players (`LogicMod/TrainerCombatBP/dist/`)
- [x] LogicMod standby verified in-game (`bp: ModActor cached`)
- [ ] Optional: stronger standby hardening if patches regress NotCombat / ModActor

**Exit criteria:** Unmarked Pal does not free-fight; Aim+MMB mark engages vanilla AI; remaking the same mark (or losing the target) returns to standby.  
**Status:** Core controlled-Pal loop on main. Shipped LogicMod pak in repo.

---

## Phase 4 — Multiplayer (later)

**Goal:** Same rules on listen/dedicated hosts without desync disasters.

- [ ] Revisit every hook for authority (server vs client)
- [ ] Ensure cooldown / damage / aggro only apply to owning player
- [ ] Test 2-player fight with both using trainer rules
- [ ] Document host vs client install requirements

**Exit criteria:** Two players can use the mod in co-op without major desync or duplicated effects.  
**Status:** Not started.

---

## Suggested config knobs

| Key | Purpose | Phase |
|-----|---------|-------|
| `SummonLockSeconds` | Recall/swap gate after summon | 1 |
| `SummonLockOnlyInCombat` | Free out of combat; lock only in battle | 1A |
| `CombatMemorySeconds` | Keep “in combat” after damage/battle | 1A |
| `BlockPlayerWeapons` | Zero local gun/melee combat use | 1B |
| `CaptureSphereCooldownSeconds` | Capture sphere throw CD | 1D |
| `PreferPalAggro` | Feature flag | 2B |
| `AttackTransferToPal` | Feature flag | 2A |
| `AttackScaleBase` | Divisor for Attack percent (default `100`) | 2A |
| `MarkStandby` / `ManualAttackOnly` | Unmarked standby + mark→engage | 3 |
| `LogicMod.Enabled` | Prefer LogicMod standby when pak loads | 3 |
| `AnnounceMark` | Hud announce on Aim+MMB mark | 3 |

All knobs live in `TrainerCombat/Scripts/config.lua`.

---

## Working rules

1. One phase at a time.
2. Every new hook starts as **log-only**, then mutate behavior.
3. Feature flags in `config.lua` so a bad hook can be disabled without deleting code.
4. After each Palworld patch: re-verify function paths in Live View.
5. Prefer local-player checks always.
6. Reload-crash hardening is ongoing but not blocking gameplay.

---

## Current status

| Phase | Status |
|-------|--------|
| 0 Tooling | Done |
| 1 Soft trainer | Working (optional 1B polish left) |
| 2 Stats / threat | Working (aggro on; DR off) |
| 3 Controlled Pal | **Working** (Aim+MMB mark→engage; LogicMod pak shipped) |
| 4 Multiplayer | Later |

**Next action:** Multiplayer later, or harden standby if a Palworld patch breaks ModActor / NotCombat.
