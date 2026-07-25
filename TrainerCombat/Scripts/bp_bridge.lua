--[[
  TrainerCombat — LogicMod (Blueprint) bridge

  Caches ModActor from TrainerCombatBP via RegisterCustomEvent("Lua_ModInitialized").
  Exposes SetManualStandby / ForceOtomoStandby for mark_standby.lua.

  Note: UE4SS often cannot call custom BP functions (TrivialObject). Prefer writing
  the ManualStandby property directly so the BP timer Branch skips ForceOtomoStandby.
]]

local Config = require("config")

local BpBridge = {
    actor = nil,
    initHooked = false,
    loggedMissing = false,
    lastForceAt = 0,
    lastMissingLogAt = 0,
    -- Lua mirror of ModActor.ManualStandby (true = BP should enforce NotCombat).
    manualStandby = false,
}

local MOD = "[TrainerCombat]"

local function log(msg)
    print(string.format("%s %s", MOD, msg))
end

local function cfg()
    return (Config.MarkStandby and Config.MarkStandby.LogicMod) or {}
end

local function featureWantsLogicMod()
    if Config.Features ~= nil and Config.Features.MarkStandby == false then
        return false
    end
    if cfg().Enabled == false then
        return false
    end
    return true
end

function BpBridge.IsReady()
    if BpBridge.actor == nil then
        return false
    end
    local ok = false
    pcall(function()
        ok = BpBridge.actor:IsValid() == true
    end)
    return ok
end

function BpBridge.GetActor()
    if BpBridge.IsReady() then
        return BpBridge.actor
    end
    return nil
end

function BpBridge.IsManualStandby()
    return BpBridge.manualStandby == true
end

--- Pause/resume BP timer gate. Prefer property write over UFunction call.
function BpBridge.SetManualStandby(enabled)
    if not featureWantsLogicMod() then
        return false
    end
    local want = enabled == true
    BpBridge.manualStandby = want

    local actor = BpBridge.GetActor()
    if actor == nil then
        return false
    end

    local wrote = false
    pcall(function()
        actor.ManualStandby = want
        wrote = true
    end)

    -- Best-effort UFunction call (often fails as TrivialObject on this build).
    pcall(function()
        actor:SetManualStandby(want)
    end)

    if wrote then
        log("bp: ManualStandby=" .. tostring(want) .. " (property)")
        return true
    end

    log("bp: ManualStandby property write failed; Lua mirror=" .. tostring(want))
    return false
end

--- Lua → BP: one-shot force follow / NotCombat (best-effort).
function BpBridge.ForceOtomoStandby(reason)
    if not featureWantsLogicMod() then
        return false
    end
    if BpBridge.manualStandby ~= true then
        return false
    end

    local t = os.clock()
    local minGap = cfg().ForceMinGapSeconds or 0.15
    if (t - (BpBridge.lastForceAt or 0)) < minGap then
        return BpBridge.IsReady()
    end
    BpBridge.lastForceAt = t

    local actor = BpBridge.GetActor()
    if actor == nil then
        return false
    end

    local ok = pcall(function()
        actor:ForceOtomoStandby(tostring(reason or ""))
    end)
    return ok == true
end

function BpBridge.Register()
    if BpBridge.initHooked then
        return
    end
    BpBridge.initHooked = true

    if not featureWantsLogicMod() then
        log("bp: LogicMod bridge disabled in config")
        return
    end

    if RegisterCustomEvent == nil then
        log("bp: RegisterCustomEvent missing — LogicMod bridge unavailable")
        return
    end

    pcall(function()
        RegisterCustomEvent("Lua_ModInitialized", function(ModActor)
            local actor = nil
            pcall(function()
                if ModActor ~= nil and ModActor.get ~= nil then
                    actor = ModActor:get()
                else
                    actor = ModActor
                end
            end)
            if actor ~= nil then
                local valid = false
                pcall(function()
                    valid = actor:IsValid() == true
                end)
                if valid then
                    BpBridge.actor = actor
                    BpBridge.loggedMissing = false
                    -- Sync property if already set from a previous session attempt.
                    pcall(function()
                        actor.ManualStandby = BpBridge.manualStandby == true
                    end)
                    log("bp: ModActor cached")
                    return
                end
            end
            log("bp: Lua_ModInitialized received invalid ModActor")
        end)
    end)

    log("bp: waiting for TrainerCombatBP Lua_ModInitialized")
end

function BpBridge.WarnIfMissing()
    if BpBridge.IsReady() or not featureWantsLogicMod() then
        return
    end
    local t = os.clock()
    if (t - (BpBridge.lastMissingLogAt or 0)) < 30 then
        return
    end
    BpBridge.lastMissingLogAt = t
    if not BpBridge.loggedMissing then
        BpBridge.loggedMissing = true
        log("bp: TrainerCombatBP ModActor not loaded yet — using Lua NotCombat fallback")
    end
end

--- Aim skill HUD (property-driven; UMG optional when cooked).
--- Prefer writing AimSkillHud* properties; UFunction calls are best-effort.
function BpBridge.ShowAimSkillHud()
    local actor = BpBridge.GetActor()
    if actor == nil then
        return false
    end
    local wrote = false
    pcall(function()
        actor.AimSkillHudVisible = true
        actor.AimSkillHudDirty = true
        wrote = true
    end)
    pcall(function()
        actor:ShowAimSkillHud()
    end)
    return wrote
end

function BpBridge.HideAimSkillHud()
    local actor = BpBridge.GetActor()
    if actor == nil then
        return false
    end
    local wrote = false
    pcall(function()
        actor.AimSkillHudVisible = false
        actor.AimSkillHudDirty = true
        wrote = true
    end)
    pcall(function()
        actor:HideAimSkillHud()
    end)
    return wrote
end

--- slotIndex 0..2
function BpBridge.SetAimSkillSlot(slotIndex, displayName, coolRemain, coolMax, enabled)
    local actor = BpBridge.GetActor()
    if actor == nil then
        return false
    end
    local i = tonumber(slotIndex) or 0
    local prefix = "AimSkill" .. tostring(i)
    local wrote = false
    pcall(function()
        actor[prefix .. "Name"] = tostring(displayName or "")
        actor[prefix .. "CoolRemain"] = tonumber(coolRemain) or 0
        actor[prefix .. "CoolMax"] = tonumber(coolMax) or 1
        actor[prefix .. "Enabled"] = enabled == true
        actor.AimSkillHudDirty = true
        wrote = true
    end)
    pcall(function()
        actor:SetAimSkillSlot(
            i,
            tostring(displayName or ""),
            tonumber(coolRemain) or 0,
            tonumber(coolMax) or 1,
            enabled == true
        )
    end)
    return wrote
end

return BpBridge
