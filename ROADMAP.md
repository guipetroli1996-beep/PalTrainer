# Trainer Combat — Roadmap

Single-player first. Multiplayer later.

Design goal: **player is a trainer, active Pal is the fighter.**

**Out of scope:** tool combat damage zeroing (formerly Phase 4) — tools stay as-is.

---

## Phase 0 — Tooling & proof of life

**Goal:** UE4SS runs and this mod loads reliably.

- [x] Project folder + mod skeleton
- [x] Install UE4SS into Steam Palworld `Pal\Binaries\Win64`
- [x] Install `TrainerCombat` into `Mods`
- [x] Confirm console: `[TrainerCombat] loaded`
- [x] Confirm console on Pal throw: `ActivateOtomo slot=...`

**Exit criteria:** Mod loads every launch; otomo activate logs every throw.

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
- [ ] Leave room for Phase 3 command rod item

### 1D — Capture sphere throw cooldown
- [x] Cooldown after throwing capture spheres (+ sphere launchers)
- [x] Does **not** affect party Pal throw (`DummyBall`) or summon lock (1A)
- [x] Announce remaining CD on blocked attempt

**Exit criteria:** Player guns/weapons don’t deal combat damage; Pal throw + tools still work; weapon schematics gone; capture spheres gated by cooldown.

---

## Phase 2 — Stat + threat rewrite

**Goal:** Stats and aggro reinforce trainer play.

### 2A — Attack attribute → party Pal
- [x] Scale party Pal Attack by player Attack %
- [x] Clear transfer state on recall / ClientRestart

### 2B — Threat while Pal is out
- [x] Prefer Pal aggro via hate pulse + hard retarget assist
- [x] Player DR / damage transfer implemented then **disabled** (aggro-only preferred)
- [ ] Further aggro hardening if enemies still tunnel the player

**Exit criteria:** Player Attack makes the Pal stronger; standing behind your Pal is safer than solo gunplay.

---

## Phase 3 — Manual mark (no command-rod item) — **IN PROGRESS**

**Goal:** Aim+LMB marks a target (localized name); while Pal is out, **no free combat** (follow / NotCombat) until future skill orders.

### Current focus
- [x] No Torch / command-rod item required
- [x] Aim + LMB → sticky mark (+ MMB reticle tracked)
- [x] Localized mark names (`GetLocalizedCharacterName`)
- [x] LogicMod path: PMK at `D:\PalworldModdingKit` + `LogicMod/TrainerCombatBP` recipe
- [x] Lua ↔ ModActor bridge (`bp_bridge.lua`) + strip AI thrash; NotCombat fallback
- [x] Cook/deploy `LogicMods/TrainerCombatBP.pak`
- [x] Playtest: Pal out, no mark, player fights → Pal does not attack
- [x] Aim+LMB on marked target → one default/filler attack, then standby
- [ ] Skill / move orders (slots 1–3) parked

**Exit criteria:** Mark with Aim+LMB; Pal does not free-fight while out; second Aim+LMB on mark fires default attack then returns to standby.

---

## Phase 4 — Multiplayer (later)

**Goal:** Same rules on listen/dedicated hosts without desync disasters.

- [ ] Revisit every hook for authority (server vs client)
- [ ] Ensure cooldown / damage / aggro only apply to owning player
- [ ] Test 2-player fight with both using trainer rules
- [ ] Document host vs client install requirements

**Exit criteria:** Two players can use the mod in co-op without major desync or duplicated effects.

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
| `MarkStandby` / `LogicMod.Enabled` | Mark + LogicMod standby bridge | 3 |

---

## Working rules

1. One phase at a time.
2. Every new hook starts as **log-only**, then mutate behavior.
3. Feature flags in `config.lua` so a bad hook can be disabled without deleting code.
4. After each Palworld patch: re-verify function paths in Live View.
5. Prefer local-player checks always.
6. Reload-crash hardening is ongoing but not blocking Phase 3.

---

## Current status

| Phase | Status |
|-------|--------|
| 0 Tooling | Done |
| 1 Soft trainer | 1A–1D working |
| 2 Stats / threat | 2A + 2B aggro on (DR off) |
| 3 Command rod | **Next / in progress** |
| 4 Multiplayer | Later |

**Next action:** Playtest mark-never-attack (Aim+MMB only). Re-enable skill orders after that is solid.
