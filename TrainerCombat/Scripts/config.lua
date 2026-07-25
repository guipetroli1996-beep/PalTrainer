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
    -- Off: only lock CD / sphere CD / mark announce.
    AnnounceAttackBoost = false,

    -- TEST ONLY: pretend player Attack is this value (nil = use real Attack).
    -- Real levels only add ~2 Attack — too small to feel. For A/B testing:
    --   100 = baseline (1.0x), 300 = obvious 3x Pal Attack on Stats, then set nil.
    AttackTestFakeAttack = nil,

    -- Phase 3: controlled Pal — unmarked standby; Aim+MMB mark → engage.
    -- Aim+LMB filler / Aim+1/2/3 skills: archive/aim-lmb-skills only.
    MarkStandby = {
        -- Master off for all mark_standby Hud announces (legacy).
        AnnounceOrders = true,
        -- Aim+MMB mark announce ("Marked: <name>").
        AnnounceMark = true,
        -- Legacy knobs (filler/skills archived — kept so old configs do not error).
        AnnounceAttackCommands = false,
        AnnounceSkillCommands = false,
        AnnounceSkillCooldown = false,
        -- Light Lua reassert only; LogicMod timer does the real work (~0.35s).
        StandbyIntervalMs = 350,
        -- true = Pal standby until Aim+MMB mark, then vanilla combat AI.
        ManualAttackOnly = true,
        -- Zero ProcessDamage from active Pal while unmarked standby.
        BlockOtomoDamage = true,
        LogicMod = {
            Enabled = true,
            ForceMinGapSeconds = 0.15,
        },
        -- Archived on archive/aim-lmb-skills (disabled here).
        DefaultAttack = {
            Enabled = false,
        },
        SkillOrder = {
            Enabled = false,
        },
        -- While player is in combat: suppress active-Pal field work (deforest/mine/gather)
        -- and base-camp work so the Pal stays available for combat.
        SuppressOtomoWorkInCombat = true,
        -- How long after last combat/engage to keep suppressing work (falls back to CombatMemorySeconds).
        CombatWorkSuppressSeconds = nil,
    },

    Hud = {
        Enabled = true,

        -- Announce ONLY when player tries to change/recall during an active lock.
        UseSystemAnnounce = true,
        BlockedAnnounceDebounce = 0.75,

        -- Experimental (off): ActiveSkill cooldown UI (archive path).
        UseSkillCooldownUI = false,

        -- Aim+1/2/3 skill bar (archive/aim-lmb-skills only).
        UseAimSkillHud = false,
        AimSkillHud = {
            YPercent = 0.88,
            Scale = 1.25,
            LineHeight = 22,
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
        -- Pal already fielded (damage / battle mode / Aim+MMB engage).
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

        -- Phase 3: unmarked standby + Aim+MMB mark → engage.
        MarkStandby = true,

        -- Aim+1/2/3 skill key probe (archive/aim-lmb-skills only).
        AimSkillKeyProbe = false,
    },
}

return Config
