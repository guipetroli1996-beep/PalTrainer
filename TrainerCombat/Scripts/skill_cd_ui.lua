--[[
  Drive ActiveSkill cooldown UI on the summoned Pal.

  SkillSlot lives on APalAIController (otomo:GetController().SkillSlot),
  NOT on the character actor. Also retries shortly after summon because
  the AI controller may not be ready in the ActivateOtomo post-hook.
]]

local Config = require("config")

local SkillCd = {
    saved = {},
    active = false,
    skillSlot = nil,
    duration = nil,
    startToken = 0,
}

local function log(msg)
    print("[TrainerCombat] " .. msg)
end

local function dbg(msg)
    if Config.Debug then
        log(msg)
    end
end

local function getHolder()
    local ok, h = pcall(function()
        return FindFirstOf("BP_OtomoPalHolderComponent_C")
    end)
    if ok and h ~= nil and h:IsValid() then
        return h
    end
    ok, h = pcall(function()
        return FindFirstOf("PalOtomoHolderComponentBase")
    end)
    if ok and h ~= nil and h:IsValid() then
        return h
    end
    return nil
end

local function getOtomo(slot)
    local holder = getHolder()
    if holder == nil then
        return nil
    end

    local otomo = nil
    if slot ~= nil then
        pcall(function()
            otomo = holder:TryGetOtomoActorBySlotIndex(slot)
        end)
        if otomo ~= nil and otomo:IsValid() then
            return otomo
        end
    end

    pcall(function()
        otomo = holder:TryGetCurrentSelectPalActor()
    end)
    if otomo ~= nil and otomo:IsValid() then
        return otomo
    end

    pcall(function()
        otomo = holder:TryGetOtomoActorBySlotIndex(0)
    end)
    if otomo ~= nil and otomo:IsValid() then
        return otomo
    end

    return nil
end

local function getSkillSlotFromController(otomo)
    if otomo == nil then
        return nil
    end

    local ctrl = nil
    pcall(function()
        ctrl = otomo:GetController()
    end)
    if ctrl == nil or not ctrl:IsValid() then
        pcall(function()
            ctrl = otomo:GetAIController()
        end)
    end
    if ctrl == nil or not ctrl:IsValid() then
        dbg("skill CD UI: otomo has no controller yet")
        return nil
    end

    dbg("skill CD UI: controller=" .. tostring((function()
        local n = "?"
        pcall(function()
            n = ctrl:GetFullName()
        end)
        return n
    end)()))

    local skillSlot = nil
    pcall(function()
        skillSlot = ctrl.SkillSlot
    end)
    if skillSlot ~= nil and skillSlot:IsValid() then
        return skillSlot
    end

    -- Combat AI action path: GetSkillSlotRef()
    pcall(function()
        local actionComp = ctrl.AIActionComponent
        if actionComp ~= nil and actionComp:IsValid() then
            -- Current action may expose GetSkillSlotRef
            if actionComp.GetSkillSlotRef ~= nil then
                skillSlot = actionComp:GetSkillSlotRef()
            end
        end
    end)
    if skillSlot ~= nil and skillSlot:IsValid() then
        return skillSlot
    end

    return nil
end

local function getSkillSlot(otomo)
    -- 1) AIController.SkillSlot (correct place)
    local slot = getSkillSlotFromController(otomo)
    if slot ~= nil then
        return slot
    end

    -- 2) Character helpers (rarely present)
    pcall(function()
        slot = otomo:GetSkillSlotRef()
    end)
    if slot ~= nil and slot:IsValid() then
        return slot
    end
    pcall(function()
        slot = otomo.SkillSlot
    end)
    if slot ~= nil and slot:IsValid() then
        return slot
    end

    return nil
end

local function foreachSkillSlotId(skillSlot, fn)
    local okIds, ids = pcall(function()
        return skillSlot:GetEnableSlotIDs()
    end)
    local used = false
    if okIds and ids ~= nil then
        local n = 0
        pcall(function()
            n = ids:Num()
        end)
        if n == 0 then
            pcall(function()
                n = #ids
            end)
        end
        for i = 1, math.max(n, 0) do
            local id = nil
            pcall(function()
                id = ids[i]
            end)
            if id == nil then
                pcall(function()
                    id = ids:Get(i - 1)
                end)
            end
            if id ~= nil then
                fn(id)
                used = true
            end
        end
    end
    if used then
        return
    end

    for id = 0, 3 do
        local valid = false
        pcall(function()
            valid = skillSlot:IsValidSkill(id)
        end)
        if valid then
            fn(id)
        else
            -- Still try restart; some builds don't report IsValidSkill early
            fn(id)
        end
    end
end

local function getSkillObject(skillSlot, slotId)
    local skill = nil
    pcall(function()
        local map = skillSlot:GetSkillMap()
        if map == nil then
            return
        end
        pcall(function()
            skill = map[slotId]
        end)
        if skill == nil then
            pcall(function()
                skill = map:Get(slotId)
            end)
        end
        if skill == nil then
            pcall(function()
                map:ForEach(function(key, value)
                    if key == slotId then
                        skill = value
                    end
                end)
            end)
        end
    end)
    if skill ~= nil and skill:IsValid() then
        return skill
    end
    return nil
end

local function applyCooldown(skillSlot, duration)
    SkillCd.saved = {}
    local touched = 0

    foreachSkillSlotId(skillSlot, function(id)
        local skill = getSkillObject(skillSlot, id)
        if skill ~= nil then
            SkillCd.saved[id] = {
                DatabaseCoolTime = skill.DatabaseCoolTime,
                ReuseCoolTimer = skill.ReuseCoolTimer,
                IsCooling = skill.IsCooling,
            }
            pcall(function()
                skill.DatabaseCoolTime = duration
                skill.ReuseCoolTimer = duration
                skill.IsCooling = true
                skill:OnRep_UpdateCoolTime()
                skill:OnRep_ChangeCTState()
            end)
        end

        local okRestart = pcall(function()
            skillSlot:RestartCoolTime(id)
        end)
        if okRestart then
            touched = touched + 1
        end
    end)

    return touched
end

local function tryStartOnce(slotIndex, duration)
    local otomo = getOtomo(slotIndex)
    if otomo == nil then
        dbg("skill CD UI: no otomo actor yet")
        return false
    end

    local skillSlot = getSkillSlot(otomo)
    if skillSlot == nil then
        dbg("skill CD UI: no SkillSlot on AIController yet")
        return false
    end

    local touched = applyCooldown(skillSlot, duration)
    if touched <= 0 then
        dbg("skill CD UI: SkillSlot found but RestartCoolTime touched 0 slots")
        -- Still mark active so Tick can keep trying property updates
    end

    SkillCd.active = true
    SkillCd.skillSlot = skillSlot
    SkillCd.duration = duration
    log(string.format("skill CD UI started (touched=%d, duration=%.1fs)", touched, duration))
    return true
end

function SkillCd.Start(slotIndex, durationSeconds)
    if not Config.Hud or not Config.Hud.UseSkillCooldownUI then
        return false
    end

    SkillCd.Stop()
    SkillCd.startToken = SkillCd.startToken + 1
    local token = SkillCd.startToken
    local duration = durationSeconds or Config.SummonLockSeconds or 8.0

    if tryStartOnce(slotIndex, duration) then
        return true
    end

    -- ActivateOtomo post-hook is often too early for AIController.SkillSlot
    if ExecuteWithDelay == nil then
        log("skill CD UI: no ActiveSkillSlot on otomo (and no ExecuteWithDelay)")
        return false
    end

    local delays = { 50, 150, 350, 700, 1200 }
    for _, ms in ipairs(delays) do
        ExecuteWithDelay(ms, function()
            if token ~= SkillCd.startToken then
                return
            end
            if SkillCd.active then
                return
            end
            if tryStartOnce(slotIndex, duration) then
                log("skill CD UI started after delay " .. tostring(ms) .. "ms")
            end
        end)
    end

    -- Optimistic: retries are scheduled
    log("skill CD UI: retrying after summon (AIController may spawn late)")
    return true
end

function SkillCd.Tick(remaining)
    if not SkillCd.active or SkillCd.skillSlot == nil then
        return
    end
    if remaining == nil or remaining < 0 then
        remaining = 0
    end

    local skillSlot = SkillCd.skillSlot
    if not skillSlot:IsValid() then
        SkillCd.active = false
        return
    end

    foreachSkillSlotId(skillSlot, function(id)
        local skill = getSkillObject(skillSlot, id)
        if skill == nil then
            return
        end
        pcall(function()
            skill.ReuseCoolTimer = remaining
            skill.IsCooling = remaining > 0.05
            if SkillCd.duration and SkillCd.duration > 0 then
                skill.DatabaseCoolTime = SkillCd.duration
            end
            skill:OnRep_UpdateCoolTime()
        end)
    end)
end

function SkillCd.Stop()
    SkillCd.startToken = SkillCd.startToken + 1

    local skillSlot = SkillCd.skillSlot
    if skillSlot ~= nil and skillSlot:IsValid() then
        foreachSkillSlotId(skillSlot, function(id)
            pcall(function()
                skillSlot:StopCoolTime(id)
            end)
            local skill = getSkillObject(skillSlot, id)
            local saved = SkillCd.saved[id]
            if skill ~= nil and saved ~= nil then
                pcall(function()
                    skill.DatabaseCoolTime = saved.DatabaseCoolTime
                    skill.ReuseCoolTimer = 0
                    skill.IsCooling = false
                    skill:OnRep_UpdateCoolTime()
                    skill:OnRep_ChangeCTState()
                end)
            end
        end)
        log("skill CD UI stopped / restored")
    end

    SkillCd.active = false
    SkillCd.skillSlot = nil
    SkillCd.saved = {}
    SkillCd.duration = nil
end

return SkillCd
