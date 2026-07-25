--[[
  TrainerCombat — Phase 2A: player Attack → party Pal Attack boost.

  Player Attack is a percent multiplier on party Pals' Attack:
    Attack 100 = 100% (no change)
    Attack 150 = 150% of each party Pal's Attack (withBuff)

  Scope: ALL pals in the player's otomo party slots (via OtomoHolder).
  Base-camp / box pals are NOT boosted.

  Combat: AttackUp on spawned party actors.
  Stats UI: PostHook Get*_withBuff for party IndividualParameters.
  Announce: "Player attack boost = xx%" (debounced).
]]

local Config = require("config")
local Hud = require("hud")
local Session = require("session")

local Attack = {
    registered = false,
    palActive = false,
    activeSlot = nil,
    displayHooksReady = false,
    partyHooksReady = false,
    refreshLoopStarted = false,
    readingRaw = false,
    lastAnnouncePercent = nil,
    lastRefreshLogAt = 0,
    -- Shared scale for all party pals.
    scale = 1.0,
    percent = 100,
    -- [individualFullName] = { savedAttackUp, otomoName, slot }
    party = {},
}

local MOD = "[TrainerCombat]"
local HOLDER_BP =
    "/Game/Pal/Blueprint/Component/OtomoHolder/BP_OtomoPalHolderComponent.BP_OtomoPalHolderComponent_C"
local MAX_PARTY_SLOTS = 10

local function log(msg)
    print(string.format("%s %s", MOD, msg))
end

local function debug(msg)
    if Config.Debug then
        log(msg)
    end
end

local function now()
    return os.clock()
end

local function getLocalPlayerCharacter()
    if not Session.IsAlive() then
        return nil
    end
    local ok, pc = pcall(function()
        return FindFirstOf("PalPlayerController")
    end)
    if not ok or pc == nil or not pc:IsValid() then
        return nil
    end
    local char = nil
    pcall(function()
        char = pc:K2_GetPawn()
    end)
    if char ~= nil and char:IsValid() then
        return char
    end
    pcall(function()
        char = pc:GetControlledPawn()
    end)
    if char ~= nil and char:IsValid() then
        return char
    end
    return nil
end

local function getCharacterParam(actor)
    if actor == nil or not actor:IsValid() then
        return nil
    end
    local param = nil
    pcall(function()
        param = actor.CharacterParameterComponent
    end)
    if param ~= nil and param:IsValid() then
        return param
    end
    pcall(function()
        param = actor:GetComponentByClass(
            StaticFindObject("/Script/Pal.PalCharacterParameterComponent")
        )
    end)
    if param ~= nil and param:IsValid() then
        return param
    end
    return nil
end

local function getHolder()
    local holder = nil
    pcall(function()
        holder = FindFirstOf("BP_OtomoPalHolderComponent_C")
    end)
    if holder ~= nil and holder:IsValid() then
        return holder
    end
    pcall(function()
        holder = FindFirstOf("PalOtomoHolderComponentBase")
    end)
    if holder ~= nil and holder:IsValid() then
        return holder
    end
    return nil
end

local function actorFullName(actor)
    local name = nil
    pcall(function()
        name = actor:GetFullName()
    end)
    return name
end

--- Player Attack attribute used as a percent (100 = 100%).
local function readAttackStat(param)
    if param == nil then
        return 100
    end
    local melee = nil
    local shot = nil
    pcall(function()
        shot = param:GetShotAttack()
    end)
    pcall(function()
        melee = param:GetMeleeAttack()
    end)
    pcall(function()
        local ind = param:GetIndividualParameter()
        if ind ~= nil then
            local s = ind:GetShotAttack_withBuff()
            local m = ind:GetMeleeAttack_withBuff()
            if type(s) == "number" then
                shot = s
            end
            if type(m) == "number" then
                melee = m
            end
        end
    end)
    local atk = 0
    if type(melee) == "number" then
        atk = melee
    end
    if type(shot) == "number" and shot > atk then
        atk = shot
    end
    if atk <= 0 then
        return 100
    end
    return atk
end

local function getScaleBase()
    local b = Config.AttackScaleBase
    if type(b) ~= "number" or b <= 0 then
        return 100
    end
    return b
end

local function getPlayerAttackScale()
    local atk = nil
    local fake = Config.AttackTestFakeAttack
    if type(fake) == "number" and fake > 0 then
        atk = fake
    else
        local char = getLocalPlayerCharacter()
        if char == nil then
            return 1.0, 100
        end
        Attack.readingRaw = true
        atk = readAttackStat(getCharacterParam(char))
        Attack.readingRaw = false
    end
    local scale = atk / getScaleBase()
    if scale < 0 then
        scale = 0
    end
    return scale, atk
end

local function readRawPalAttack(param)
    local melee = 0
    local shot = 0
    local meleeBuff = 0
    local shotBuff = 0
    local attackUp = 0

    Attack.readingRaw = true
    pcall(function()
        local ind = param:GetIndividualParameter()
        if ind ~= nil then
            local m = ind:GetMeleeAttack()
            local s = ind:GetShotAttack()
            local mb = ind:GetMeleeAttack_withBuff()
            local sb = ind:GetShotAttack_withBuff()
            if type(m) == "number" then
                melee = m
            end
            if type(s) == "number" then
                shot = s
            end
            if type(mb) == "number" then
                meleeBuff = mb
            end
            if type(sb) == "number" then
                shotBuff = sb
            end
        end
    end)
    Attack.readingRaw = false

    pcall(function()
        attackUp = param.AttackUp or 0
    end)

    local base = melee
    if shot > base then
        base = shot
    end
    local withBuff = meleeBuff
    if shotBuff > withBuff then
        withBuff = shotBuff
    end
    if withBuff <= 0 then
        withBuff = base
    end
    return {
        base = base,
        withBuff = withBuff,
        attackUp = attackUp,
    }
end

local function announceBoost(percent)
    if Config.AnnounceAttackBoost == false then
        return
    end
    if Attack.lastAnnouncePercent == percent then
        return
    end
    Attack.lastAnnouncePercent = percent

    local msg = string.format("Player attack boost = %d%%", percent)
    local ok = false
    pcall(function()
        if Hud ~= nil and Hud.Announce ~= nil then
            ok = Hud.Announce(msg) == true
        end
    end)
    if not ok then
        pcall(function()
            local util = StaticFindObject("/Script/Pal.Default__PalUtility")
            local pc = FindFirstOf("PalPlayerController")
            if util ~= nil and pc ~= nil and pc:IsValid() then
                util:SendSystemAnnounce(pc, msg)
                ok = true
            end
        end)
    end
    if ok then
        log("announce: " .. msg)
    else
        log(msg)
    end
end

local function isPartyIndividual(ind)
    if ind == nil then
        return false
    end
    local okValid = false
    pcall(function()
        okValid = ind:IsValid() == true
    end)
    if not okValid then
        return false
    end
    local name = actorFullName(ind)
    return name ~= nil and Attack.party[name] ~= nil
end

local function unwrapReturnInt(returnValue)
    if returnValue == nil then
        return nil
    end
    local n = nil
    pcall(function()
        if returnValue.get ~= nil then
            n = returnValue:get()
        else
            n = returnValue
        end
    end)
    if type(n) == "number" then
        return n
    end
    return nil
end

local function postScaleWithBuff(Context, returnValue)
    if not Session.IsAlive() then
        return nil
    end
    if Attack.readingRaw then
        return nil
    end
    if Config.Features == nil or not Config.Features.AttackTransferToPal then
        return nil
    end
    local scale = Attack.scale
    if type(scale) ~= "number" or math.abs(scale - 1.0) < 0.0001 then
        return nil
    end

    local ind = nil
    pcall(function()
        ind = Context:get()
    end)
    if not isPartyIndividual(ind) then
        return nil
    end

    local original = unwrapReturnInt(returnValue)
    if original == nil then
        return nil
    end
    return math.max(0, math.floor(original * scale + 0.5))
end

local function tryRegisterDisplayHooks(reason)
    if Attack.displayHooksReady then
        return true
    end

    local paths = {
        "/Script/Pal.PalIndividualCharacterParameter:GetMeleeAttack_withBuff",
        "/Script/Pal.PalIndividualCharacterParameter:GetShotAttack_withBuff",
    }
    local okCount = 0
    for _, path in ipairs(paths) do
        local ok, err = pcall(function()
            RegisterHook(path, function(_Context)
            end, function(Context, ReturnValue)
                return postScaleWithBuff(Context, ReturnValue)
            end)
        end)
        if ok then
            okCount = okCount + 1
            log("hooked " .. path .. " (Stats UI Attack)")
        else
            debug("display hook fail " .. path .. ": " .. tostring(err))
        end
    end

    if okCount > 0 then
        Attack.displayHooksReady = true
        log(string.format("attack Stats UI hooks ready (%s) count=%d", tostring(reason), okCount))
        return true
    end
    log("attack Stats UI hooks not ready yet (" .. tostring(reason) .. ")")
    return false
end

local function restoreActorAttackUp(actor, savedAttackUp)
    if actor == nil or not actor:IsValid() then
        return
    end
    local param = getCharacterParam(actor)
    if param == nil then
        return
    end
    pcall(function()
        param.AttackUp = savedAttackUp or 0
    end)
end

local function applyActorAttackUp(actor, entry, scale)
    if actor == nil or not actor:IsValid() then
        return false
    end
    local param = getCharacterParam(actor)
    if param == nil then
        return false
    end

    local actorName = actorFullName(actor)
    if entry.otomoName ~= actorName then
        entry.otomoName = actorName
        entry.savedAttackUp = nil
    end

    -- Restore baseline before measuring raw withBuff / applying new delta.
    if entry.savedAttackUp ~= nil then
        pcall(function()
            param.AttackUp = entry.savedAttackUp
        end)
    end

    local snap = readRawPalAttack(param)
    if entry.savedAttackUp == nil then
        entry.savedAttackUp = snap.attackUp
    end

    local target = math.max(0, math.floor(snap.withBuff * scale + 0.5))
    local delta = target - snap.withBuff
    local newAttackUp = entry.savedAttackUp + delta

    local ok = pcall(function()
        param.AttackUp = newAttackUp
    end)
    return ok == true
end

local function collectPartyMembers(holder)
    local members = {}
    for slot = 0, MAX_PARTY_SLOTS - 1 do
        local handle = nil
        pcall(function()
            handle = holder:GetOtomoIndividualHandle(slot)
        end)
        if handle ~= nil and handle:IsValid() then
            local ind = nil
            pcall(function()
                ind = handle:TryGetIndividualParameter()
            end)
            if ind ~= nil and ind:IsValid() then
                local indName = actorFullName(ind)
                if indName ~= nil then
                    local actor = nil
                    pcall(function()
                        actor = holder:TryGetOtomoActorBySlotIndex(slot)
                    end)
                    if actor == nil or not actor:IsValid() then
                        pcall(function()
                            actor = handle:TryGetIndividualActor()
                        end)
                    end
                    members[#members + 1] = {
                        slot = slot,
                        individualName = indName,
                        individual = ind,
                        actor = (actor ~= nil and actor:IsValid()) and actor or nil,
                    }
                end
            end
        end
    end
    return members
end

--- Refresh boost for every party-slot Pal. Base camp / box are never included.
function Attack.RefreshParty(reason)
    if not Session.IsAlive() then
        return
    end
    if not Config.Features or not Config.Features.AttackTransferToPal then
        return
    end

    local holder = getHolder()
    if holder == nil then
        debug("party boost: no otomo holder (" .. tostring(reason) .. ")")
        return
    end

    local scale, playerAtk = getPlayerAttackScale()
    local percent = math.floor(playerAtk + 0.5)
    Attack.scale = scale
    Attack.percent = percent

    local members = collectPartyMembers(holder)
    local seen = {}
    local appliedActors = 0

    for _, m in ipairs(members) do
        seen[m.individualName] = true
        local entry = Attack.party[m.individualName]
        if entry == nil then
            entry = {
                savedAttackUp = nil,
                otomoName = nil,
                slot = m.slot,
            }
            Attack.party[m.individualName] = entry
        end
        entry.slot = m.slot

        if m.actor ~= nil then
            if applyActorAttackUp(m.actor, entry, scale) then
                appliedActors = appliedActors + 1
            end
        end
    end

    -- Left the party → drop from boost set (and restore AttackUp if actor still around).
    for indName, entry in pairs(Attack.party) do
        if not seen[indName] then
            if entry.otomoName ~= nil then
                local actor = nil
                pcall(function()
                    local all = FindAllOf("PalCharacter")
                    if all ~= nil then
                        for _, a in pairs(all) do
                            if actorFullName(a) == entry.otomoName then
                                actor = a
                                break
                            end
                        end
                    end
                end)
                restoreActorAttackUp(actor, entry.savedAttackUp)
            end
            Attack.party[indName] = nil
            debug("party boost removed (left party): " .. tostring(indName))
        end
    end

    local partyCount = 0
    for _ in pairs(Attack.party) do
        partyCount = partyCount + 1
    end

    if (now() - Attack.lastRefreshLogAt) > 2.0 or reason == "mod-load" or reason == "ActivateOtomo" then
        Attack.lastRefreshLogAt = now()
        local fake = Config.AttackTestFakeAttack
        local atkLabel = (type(fake) == "number" and fake > 0)
            and string.format("%d [TEST FAKE]", playerAtk)
            or tostring(playerAtk)
        log(string.format(
            "party attack boost (%s) playerAtk=%s -> %d%% | party=%d spawnedBoosted=%d UI hooks=%s",
            tostring(reason),
            atkLabel,
            percent,
            partyCount,
            appliedActors,
            tostring(Attack.displayHooksReady)
        ))
    end

    announceBoost(percent)
end

local function tryRegisterPartyHooks(reason)
    if Attack.partyHooksReady then
        return true
    end

    local hooked = 0
    local paths = {
        HOLDER_BP .. ":OnUpdateSlot",
        "/Script/Pal.PalOtomoHolderComponentBase:OnUpdateSlot",
        "/Script/Pal.PalPlayerCharacter:OnUpdateOtomoHolderSlot",
    }
    for _, path in ipairs(paths) do
        local ok, err = pcall(function()
            RegisterHook(path, function()
                Session.Defer(100, function()
                    Attack.RefreshParty("party-slot-update")
                end)
            end)
        end)
        if ok then
            hooked = hooked + 1
            log("hooked " .. path .. " (party boost refresh)")
        else
            debug("party hook skip " .. path .. ": " .. tostring(err))
        end
    end

    if hooked > 0 then
        Attack.partyHooksReady = true
        log(string.format("party boost hooks ready (%s) count=%d", tostring(reason), hooked))
        return true
    end
    return false
end

local function startRefreshLoop()
    if Attack.refreshLoopStarted then
        return
    end
    if LoopAsync == nil then
        return
    end
    Attack.refreshLoopStarted = true
    -- Keep party stats in sync when player Attack changes / pals swap quietly.
    LoopAsync(2500, function()
        if not Session.IsAlive() then
            return false
        end
        if not Config.Features or not Config.Features.AttackTransferToPal then
            return false
        end
        pcall(function()
            Attack.RefreshParty("poll")
        end)
        return false
    end)
end

function Attack.OnPalActivated(slot)
    Attack.palActive = true
    Attack.activeSlot = slot

    if not Config.Features or not Config.Features.AttackTransferToPal then
        return
    end

    Session.Defer(150, function()
        if Attack.activeSlot == slot then
            Attack.RefreshParty("ActivateOtomo")
        end
    end)
end

function Attack.OnPalRecalled(reason)
    Attack.palActive = false
    Attack.activeSlot = nil
    -- Avoid FindAllOf / actor walks during ClientRestart (world teardown crashes).
    if reason == "ClientRestart" then
        Attack.party = {}
        return
    end
    -- Keep party boosts — inactive party pals should stay updated.
    Attack.RefreshParty(reason or "recall")
end

Session.OnSuspend(function()
    Attack.palActive = false
    Attack.activeSlot = nil
    Attack.party = {}
end)

local function unwrap(param)
    if param == nil then
        return nil
    end
    local ok, val = pcall(function()
        if param.get ~= nil then
            return param:get()
        end
        return param
    end)
    if ok then
        return val
    end
    return param
end

local function sameActor(a, b)
    if a == nil or b == nil then
        return false
    end
    if a == b then
        return true
    end
    local ok = false
    pcall(function()
        ok = a:GetFullName() == b:GetFullName()
    end)
    return ok == true
end

--- Non-player Pal character (party or wild) — for TEST zero damage.
local function isPalAttackerNotPlayer(actor)
    if actor == nil then
        return false
    end
    local player = getLocalPlayerCharacter()
    if player ~= nil and sameActor(actor, player) then
        return false
    end

    local isPal = false
    pcall(function()
        if actor.IsA ~= nil then
            if actor:IsA("/Script/Pal.PalCharacter") then
                isPal = true
            elseif actor:IsA("/Script/Pal.PalMonsterCharacter") then
                isPal = true
            end
        end
    end)
    if isPal then
        return true
    end

    -- Fallback: otomo / party markers
    local param = getCharacterParam(actor)
    if param ~= nil then
        local isOtomo = false
        pcall(function()
            isOtomo = param:IsOtomo() == true
        end)
        if isOtomo then
            return true
        end
    end

    local name = actorFullName(actor)
    if name ~= nil then
        local lower = string.lower(name)
        if string.find(lower, "palcharacter", 1, true)
            or string.find(lower, "monstercharacter", 1, true)
            or string.find(lower, "bp_pal", 1, true)
        then
            if player == nil or not sameActor(actor, player) then
                return true
            end
        end
        for _, entry in pairs(Attack.party) do
            if entry.otomoName == name then
                return true
            end
        end
    end

    return false
end

local function applyZeroDamageToInfo(info, attacker, label)
    if info == nil then
        return false
    end
    local ok = false
    pcall(function()
        info.NativeDamageValue = 0
        ok = true
    end)
    pcall(function()
        if info.set ~= nil then
            -- unlikely for struct
        end
    end)
    pcall(function()
        info.bApplyNativeDamageValue = true
    end)
    pcall(function()
        info.NoDamage = true
    end)
    Attack.zeroDmgLogCount = (Attack.zeroDmgLogCount or 0) + 1
    if Attack.zeroDmgLogCount <= 12 then
        log(string.format(
            "TEST zero Pal damage (%s): %s",
            tostring(label),
            tostring(actorFullName(attacker))
        ))
    end
    return ok
end

local function zeroPalDamagePre(Context, Info)
    if Config.TestZeroPalDamage ~= true and Config.TestZeroPartyPalDamage ~= true then
        return
    end
    local info = unwrap(Info)
    local attacker = nil
    pcall(function()
        if info ~= nil then
            attacker = info.Attacker
        end
    end)
    -- Probe first few damage events so we can see if Attacker is populated.
    Attack.dmgProbeCount = (Attack.dmgProbeCount or 0) + 1
    if Attack.dmgProbeCount <= 10 then
        log(string.format(
            "TEST dmg probe #%d attacker=%s isPal=%s",
            Attack.dmgProbeCount,
            tostring(actorFullName(attacker)),
            tostring(isPalAttackerNotPlayer(attacker))
        ))
    end
    if isPalAttackerNotPlayer(attacker) then
        applyZeroDamageToInfo(info, attacker, "ProcessDamage-pre")
    end
end

local function zeroPalDamagePost(Context, Info)
    if Config.TestZeroPalDamage ~= true and Config.TestZeroPartyPalDamage ~= true then
        return
    end
    local info = unwrap(Info)
    local attacker = nil
    pcall(function()
        if info ~= nil then
            attacker = info.Attacker
        end
    end)
    if isPalAttackerNotPlayer(attacker) then
        applyZeroDamageToInfo(info, attacker, "ProcessDamage-post")
    end
end

local function zeroPalSendDamage(Context, Target, Info)
    if Config.TestZeroPalDamage ~= true and Config.TestZeroPartyPalDamage ~= true then
        return
    end
    -- Prefer Context owner / pawn as attacker when dealing damage.
    local attacker = unwrap(Context)
    pcall(function()
        if attacker ~= nil and attacker.K2_GetPawn ~= nil then
            attacker = attacker:K2_GetPawn()
        elseif attacker ~= nil and attacker.GetOwner ~= nil then
            local o = attacker:GetOwner()
            if o ~= nil then
                attacker = o
            end
        end
    end)
    local info = unwrap(Info)
    local infoAtk = nil
    pcall(function()
        if info ~= nil then
            infoAtk = info.Attacker
        end
    end)
    if isPalAttackerNotPlayer(infoAtk) or isPalAttackerNotPlayer(attacker) then
        applyZeroDamageToInfo(info, infoAtk or attacker, "SendDamage")
    end
end

local function registerZeroPartyDamageHook()
    if Attack.zeroDmgHooked then
        return
    end
    if Config.TestZeroPalDamage ~= true and Config.TestZeroPartyPalDamage ~= true then
        return
    end

    local ok, err = pcall(function()
        RegisterHook(
            "/Script/Pal.PalDamageReactionComponent:ProcessDamage_ToServer",
            zeroPalDamagePre,
            zeroPalDamagePost
        )
    end)
    if ok then
        log("TEST: hooked ProcessDamage_ToServer (zero Pal damage)")
    else
        log("TEST ProcessDamage zero hook failed: " .. tostring(err))
    end

    pcall(function()
        RegisterHook(
            "/Script/Pal.PalPlayerController:SendDamage_ToServer",
            zeroPalSendDamage
        )
        log("TEST: hooked SendDamage_ToServer (zero Pal damage)")
    end)

    Attack.zeroDmgHooked = true
    log("TEST: non-player Pals deal 0 damage (TestZeroPalDamage=true) — set false when done")
end

function Attack.Register()
    if Attack.registered then
        return
    end
    Attack.registered = true

    registerZeroPartyDamageHook()

    if not Config.Features or not Config.Features.AttackTransferToPal then
        log("party attack boost disabled (AttackTransferToPal=false)")
        return
    end

    local fake = Config.AttackTestFakeAttack
    if type(fake) == "number" and fake > 0 then
        log(string.format(
            "attack TEST override ON: fake Attack=%d (%d%%) — set AttackTestFakeAttack=nil when done",
            fake,
            fake
        ))
    end

    tryRegisterDisplayHooks("mod-load")
    tryRegisterPartyHooks("mod-load")
    startRefreshLoop()

    Session.Defer(1500, function()
        tryRegisterDisplayHooks("delay-1.5s")
        tryRegisterPartyHooks("delay-1.5s")
        Attack.RefreshParty("delay-1.5s")
    end)
    Session.Defer(5000, function()
        tryRegisterDisplayHooks("delay-5s")
        tryRegisterPartyHooks("delay-5s")
        Attack.RefreshParty("delay-5s")
    end)

    log("party attack boost ready (party slots only; base camp excluded)")
end

return Attack
