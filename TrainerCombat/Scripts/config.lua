-- TrainerCombat config
-- After edits: copy to game Mods, fully quit + relaunch (no Ctrl+R with PalSchema).

local Config = {
    Debug = true,

    -- After summoning a Pal, block recall/swap for this many seconds.
    -- With SummonLockOnlyInCombat: only while fighting (see Features below).
    SummonLockSeconds = 8.0,

    -- How long after battle/damage/near-enemy we still treat as "in combat".
    CombatMemorySeconds = 12.0,

    -- TEST: force combat window always (nil/false = normal). Use to verify lock.
    DebugAlwaysInCombat = false,

    -- Capture sphere throw cooldown (Pal Sphere / Mega / etc. + sphere launchers).
    -- Does NOT affect party Pal throw (DummyBall) or the summon lock above.
    CaptureSphereCooldownSeconds = 5.0,
    AnnounceCaptureSphereCooldown = true,

    -- Phase 2B (optional): player damage reduction / transfer — OFF.
    -- Aggro preference alone is enough for trainer feel; DR caused stuck muteki bugs.
    PlayerDamageTakenMultiplierWithPal = 0.35,

    -- How often to pulse enemy hate toward the active Pal (ms).
    -- Lower = stickier Pal focus (CPU cost rises a bit).
    HatePulseIntervalMs = 400,

    -- Min seconds between damage-triggered aggro assist pulses.
    -- Multihit attacks would stutter if we FindAllOf+retarget on every hit.
    AggroAssistCooldownSeconds = 2.5,

    -- Phase 2A: player Attack % boosts ALL party (otomo) Pals' Attack.
    -- Base-camp / box pals are not boosted. Attack 100 = 100%; 150 = 150%.
    -- Combat uses AttackUp on spawned party pals; Stats UI uses withBuff hooks.
    AttackScaleBase = 100,
    -- Off: only lock CD / sphere CD / attack+skill commands / skill CD announce.
    AnnounceAttackBoost = false,

    -- TEST ONLY: pretend player Attack is this value (nil = use real Attack).
    -- Real levels only add ~2 Attack — too small to feel. For A/B testing:
    --   100 = baseline (1.0x), 300 = obvious 3x Pal Attack on Stats, then set nil.
    AttackTestFakeAttack = nil,

    -- Phase 3: Aim+LMB filler attack + follow-only standby (LogicMod / NotCombat).
    -- Lua keeps Aim+LMB attack + NotCombat fallback until the .pak is cooked.
    MarkStandby = {
        -- Master off for all mark_standby Hud announces (legacy).
        AnnounceOrders = true,
        -- Granular filters (ignored when AnnounceOrders == false).
        AnnounceAttackCommands = true,  -- "{Pal} attack {Target}"
        AnnounceSkillCommands = true,   -- "{Pal} use {Skill} on {Target}"
        AnnounceSkillCooldown = true,   -- skill / Aim+LMB filler on CD
        -- Light Lua reassert only; LogicMod timer does the real work (~0.35s).
        StandbyIntervalMs = 350,
        ManualAttackOnly = true,
        -- Zero ProcessDamage from active Pal while manual follow/standby.
        BlockOtomoDamage = true,
        LogicMod = {
            Enabled = true,
            ForceMinGapSeconds = 0.15,
        },
        -- Aim+LMB on a hostile → one elemental filler (same element as Pal), then standby.
        -- No separate mark step. Priority: boring waza → element common shot → neutrals.
        DefaultAttack = {
            Enabled = true,
            -- Hard CD between filler orders (also used as Aim+LMB debounce).
            CooldownSeconds = 2.0,
            DebounceSeconds = 2.0,
            ApproachTimeoutSeconds = 6.0,
            RetryIntervalMs = 250,
            AfterFireStandbyMs = 1000,
            -- Neutral last resorts only (PowerShot=sky drop — keep last).
            RangedWazaIds = { 22, 5, 12, 11 }, -- AirCanon, EnergyShot, PowerBall, PowerShot
            UseDirectOrder = false,
        },
        -- Aim+1/2/3 → order equipped active skills (slots map to ActiveSkillSlot IDs).
        SkillOrder = {
            Enabled = true,
            DebounceSeconds = 0.35,
            -- Wait for cast confirm before standby (after in-range PlayAction).
            ApproachTimeoutSeconds = 8.0,
            RetryIntervalMs = 250,
            AfterFireStandbyMs = 1200,
            ReassertOrderMs = 750,
            SkillSlotSyncMs = 50,
            -- When EquipWaza already resolved the slot, skip SkillMap wait (cuts free-AI window).
            EquipReadySyncMs = 0,
            -- One-frame settle after opening Default before PlayAction.
            PrePlayActionSettleMs = 16,
            -- After PlayAction accepts, wait before NotCombat (montage commit).
            PostAcceptNotCombatMs = 400,
            -- Distance fallbacks when InWazaMaxRange / WazaDB are unavailable (UU ≈ cm).
            InRangeDistanceUU = 2200,
            TooFarDistanceUU = 4500,
            -- UI keys 1/2/3 → EquipWaza / SkillMap indices (0-based).
            SlotIds = { 0, 1, 2 },
            -- Local cast clock fallback when game CoolTime read fails.
            FallbackCooldownSeconds = 8.0,
            -- Always respect CD for skill orders (config kept for docs; enforced in code).
            RespectSkillCooldown = true,
        },
        -- While player is in combat: suppress active-Pal field work (deforest/mine/gather)
        -- and base-camp work so the Pal stays available for filler orders.
        SuppressOtomoWorkInCombat = true,
        -- How long after last combat/filler to keep suppressing work (falls back to CombatMemorySeconds).
        CombatWorkSuppressSeconds = nil,
    },

    Hud = {
        Enabled = true,

        -- Announce ONLY when player tries to change/recall during an active lock.
        UseSystemAnnounce = true,
        BlockedAnnounceDebounce = 0.75,

        -- Experimental (off): ActiveSkill cooldown UI
        UseSkillCooldownUI = false,

        -- Ride-style Aim+1/2/3 skill bar while aiming (DrawHUD + optional LogicMod UMG).
        -- Parked: UMG layout not polished yet; Aim+1/2/3 orders still work without this HUD.
        UseAimSkillHud = false,
        AimSkillHud = {
            -- 0..1 screen fractions (0,0 = top-left); Canvas path only.
            YPercent = 0.88,
            Scale = 1.25,
            LineHeight = 22,
            -- When re-enabled: prefer WBP left-align in Designer; avoid Lua Position writes.
            UseSystemAnnounce = false,
            AnnounceIntervalSeconds = 1.25,
        },

        -- Optional: try player step-cooldown timer on lock start
        UseStepCoolDownTimer = false,

        XPercent = 0.055,
        YPercent = 0.86,
        Scale = 1.35,
        OneDecimal = true,
        Prefix = "",
        Color = { R = 1.0, G = 0.85, B = 0.2, A = 1.0 },
        FallbackPrintString = false,
        ScreenLogDuration = 1.1,
    },

    Features = {
        LogOtomoEvents = true,
        SummonLock = true,
        -- When true: free throw/recall/swap out of combat.
        -- In combat: lock on ActivateOtomo, and also when combat starts with a
        -- Pal already fielded (damage / battle mode / Aim+LMB|skill orders).
        -- Not on recall alone.
        -- Combat window = hostile AI / damage / battle mode (not nearby passives).
        -- When false: always lock for SummonLockSeconds after every summon (old behavior).
        SummonLockOnlyInCombat = true,
        UseGameDisableFlags = true,

        -- Phase 1B: block local-player gun/melee combat use (spheres/tools stay).
        BlockPlayerWeapons = true,

        -- Capture sphere throw cooldown (not DummyBall / Pal summon).
        CaptureSphereCooldown = true,

        -- Phase 1C: remove weapon tech-tree / schematic recipes (tools/spheres stay).
        HideWeaponSchematics = true,

        -- Optional announce when a blocked weapon fires (can spam — keep false).
        AnnounceWeaponBlock = false,

        -- Phase 2B: enemies prefer active Pal. DR/transfer kept off on purpose.
        PreferPalAggro = true,
        PlayerDamageReductionWithPal = false,
        TransferPlayerDamageToPal = false,

        -- Phase 2A: boost party (otomo) Pal Attack by player Attack % (not base camp).
        AttackTransferToPal = true,

        -- Phase 3: Aim+LMB filler attack + follow-only (LogicMod / NotCombat standby).
        MarkStandby = true,

        -- While aiming, suppress vanilla 1/2/3 (Pal/sphere switch) and order
        -- active Pal skills from slots 1–3 instead.
        AimSkillKeyProbe = true,
    },
}

return Config
