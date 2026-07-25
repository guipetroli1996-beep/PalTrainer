--[[
  TrainerCombat — Phase 1B: block local-player gun/melee combat use.
  Phase 1D: capture-sphere throw cooldown (SAFE path — no DestroyActor).

  Sphere throw = hold-aim / release-throw (NOT Attack).
  CD block: zero consume + neutralize ThrowObject/Body.
  Do NOT use SetDisableShootFlag / EndAim for CD — those break attack crosshair.
]]

local Config = require("config")
local Session = require("session")

local Weapons = {
    hooked = false,
    loggedClass = {},
    blockCount = 0,
    lastCaptureThrowAt = nil,
    lastCaptureAnnounceAt = 0,
    probePullCount = 0,
    probeSphereBodyCount = 0,
    captureCdActive = false,
    shootFlagOn = false,
    aimFlagOn = false,
    aimCancelLogCount = 0,
    cachedShootFlagName = nil,
    cdLoopStarted = false,
    -- While > os.clock(), scrub illegal thrown projectiles / fail ChallengeCapture.
    suppressCaptureUntil = 0,
    -- FullNames of capture actors that existed when CD started (first throw).
    captureActorsAllowed = {},
    -- FullNames already neutralized (scrub once — never spam).
    scrubbedOnce = {},
    scrubLogCount = 0,
}

Session.OnSuspend(function(reason)
    Weapons.captureCdActive = false
    Weapons.lastCaptureThrowAt = nil
    Weapons.suppressCaptureUntil = 0
    Weapons.captureActorsAllowed = {}
    Weapons.scrubbedOnce = {}
    Weapons.aimFlagOn = false
    Weapons.shootFlagOn = false
end)

local MOD = "[TrainerCombat]"
local CAPTURE_CD_FLAG_STRING = "TrainerCombat_CaptureSphereCD"

local ALLOW_PATTERNS = {
    "palsphere",
    "sphere",
    "capture",
    "dummyball",
    "prism",
    "axe",
    "pickaxe",
    "meatcutter",
    "meat",
    "torch",
    "lantern",
    "glider",
    "fishing",
    "repair",
    "hammer",
    "shovel",
    "hoe",
    "sickle",
    "backpack",
    "palhealinggrenade",
    "healinggrenade",
    "recoverygrenade",
    "captureball",
}

local CAPTURE_SPHERE_PATTERNS = {
    "palsphere",
    "megasphere",
    "gigasphere",
    "hypersphere",
    "ultrasphere",
    "legendarysphere",
    "ultimatesphere",
    "exoticsphere",
    "capturesphere",
    "captureball",
    "spweaponcaptureball",
}

local function isCombatGrenadeName(name)
    if name == nil or name == "" then
        return false
    end
    local lower = string.lower(name)
    if string.find(lower, "palhealinggrenade", 1, true)
        or string.find(lower, "healinggrenade", 1, true)
        or string.find(lower, "recoverygrenade", 1, true)
    then
        return false
    end
    if string.find(lower, "fraggrenade", 1, true) then
        return true
    end
    if string.find(lower, "grenade", 1, true)
        and string.find(lower, "launcher", 1, true) == nil
        and string.find(lower, "bullet", 1, true) == nil
    then
        return true
    end
    return false
end

local function log(msg)
    print(string.format("%s %s", MOD, msg))
end

local function debug(msg)
    if Config.Debug then
        log(msg)
    end
end

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

local function objectName(obj)
    if obj == nil then
        return ""
    end
    local ok, name = pcall(function()
        return obj:GetFullName()
    end)
    if ok and type(name) == "string" then
        return name
    end
    ok, name = pcall(function()
        return obj:GetClass():GetFullName()
    end)
    if ok and type(name) == "string" then
        return name
    end
    return tostring(obj)
end

local function matchesAllowlist(name)
    if name == nil or name == "" then
        return false
    end
    local lower = string.lower(name)
    for _, pat in ipairs(ALLOW_PATTERNS) do
        if string.find(lower, pat, 1, true) then
            return true
        end
    end
    return false
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

local function getLocalShooter()
    local char = getLocalPlayerCharacter()
    if char == nil then
        return nil
    end
    local shooter = nil
    pcall(function()
        shooter = char.ShooterComponent
    end)
    if shooter ~= nil and shooter:IsValid() then
        return shooter
    end
    pcall(function()
        shooter = char:GetComponentByClass(
            StaticFindObject("/Script/Pal.PalShooterComponent")
        )
    end)
    if shooter ~= nil and shooter:IsValid() then
        return shooter
    end
    return nil
end

local function getCaptureFlagName()
    if Weapons.cachedShootFlagName ~= nil then
        return Weapons.cachedShootFlagName
    end
    local ok, fname = pcall(function()
        return UEHelpers.FindOrAddFName(CAPTURE_CD_FLAG_STRING)
    end)
    if ok and fname ~= nil then
        Weapons.cachedShootFlagName = fname
        return fname
    end
    ok, fname = pcall(function()
        return FName(CAPTURE_CD_FLAG_STRING)
    end)
    if ok and fname ~= nil then
        Weapons.cachedShootFlagName = fname
        return fname
    end
    return nil
end

--- Clear leftover capture-CD shooter gates.
--- IMPORTANT: never leave SetDisableShootFlag on — it breaks attack crosshair/input
--- while sphere-aim can still work (separate path).
local function clearCaptureInputGates(reason)
    if not Session.IsAlive() then
        Weapons.aimFlagOn = false
        Weapons.shootFlagOn = false
        return false
    end
    local shooter = getLocalShooter()
    local fname = getCaptureFlagName()
    if shooter == nil or fname == nil then
        Weapons.aimFlagOn = false
        Weapons.shootFlagOn = false
        log("capture CD input gates clear skipped (" .. tostring(reason) .. ")")
        return false
    end
    pcall(function()
        shooter:SetDisableAimFlag(fname, false)
    end)
    pcall(function()
        shooter:SetDisableShootFlag(fname, false)
    end)
    Weapons.aimFlagOn = false
    Weapons.shootFlagOn = false
    log("capture CD input gates cleared (" .. tostring(reason) .. ")")
    return true
end

-- Legacy no-op setter: do NOT disable aim/shoot for capture CD (breaks attack ADS).
-- Sphere throws are blocked via zero-consume + ThrowObject scrub instead.
local function setCaptureAimDisabled(disabled, reason)
    if disabled == true then
        debug("capture CD skip aim/shoot disable (" .. tostring(reason) .. ") — would break attack input")
        return false
    end
    return clearCaptureInputGates(reason or "enable")
end

local function setCaptureShootDisabled(disabled, reason)
    return setCaptureAimDisabled(disabled, reason)
end

local function startCdClearLoop()
    if Weapons.cdLoopStarted or LoopAsync == nil then
        return
    end
    Weapons.cdLoopStarted = true
    LoopAsync(100, function()
        if not captureCdEnabled() then
            return false
        end
        if Weapons.captureCdActive and captureCdRemaining() <= 0 then
            Weapons.captureCdActive = false
            Weapons.captureActorsAllowed = {}
            Weapons.scrubbedOnce = {}
            Weapons.scrubLogCount = 0
            Weapons.aimCancelLogCount = 0
            clearCaptureInputGates("cd-ended")
            log("capture sphere cooldown ended")
        end
        return false
    end)
end

local function getWeaponOwnerCharacter(weapon)
    if weapon == nil then
        return nil
    end
    local owner = nil
    pcall(function()
        owner = weapon:GetOwnerCharacter()
    end)
    if owner ~= nil and owner:IsValid() then
        return owner
    end
    pcall(function()
        owner = weapon:GetOwner()
    end)
    if owner ~= nil and owner:IsValid() then
        local ok, pawn = pcall(function()
            if owner.IsA ~= nil and owner:IsA("/Script/Engine.Pawn") then
                return owner
            end
            return owner:GetOwner()
        end)
        if ok and pawn ~= nil and pawn:IsValid() then
            return pawn
        end
        return owner
    end
    return nil
end

local function isLocalPlayerWeapon(weapon)
    local localChar = getLocalPlayerCharacter()
    if localChar == nil then
        return false
    end
    local owner = getWeaponOwnerCharacter(weapon)
    if owner == nil then
        return false
    end
    if owner == localChar then
        return true
    end
    local ok, same = pcall(function()
        return owner:GetFullName() == localChar:GetFullName()
    end)
    return ok and same == true
end

local function getWeaponItemName(weapon)
    local itemName = nil
    pcall(function()
        local id = weapon:GetItemId()
        if id ~= nil and id.StaticId ~= nil then
            itemName = tostring(id.StaticId)
        end
    end)
    return itemName
end

local function fnameToString(fname)
    if fname == nil then
        return nil
    end
    local s = nil
    pcall(function()
        if fname.ToString ~= nil then
            s = fname:ToString()
        elseif fname.get ~= nil then
            local inner = fname:get()
            if inner ~= nil and inner.ToString ~= nil then
                s = inner:ToString()
            else
                s = tostring(inner)
            end
        else
            s = tostring(fname)
        end
    end)
    if type(s) == "string" and s ~= "" then
        return s
    end
    return nil
end

local function isCaptureSphereItemName(name)
    if name == nil or name == "" then
        return false
    end
    local lower = string.lower(name)
    if string.find(lower, "dummyball", 1, true) then
        return false
    end
    if string.find(lower, "palhealinggrenade", 1, true)
        or string.find(lower, "healinggrenade", 1, true)
        or string.find(lower, "recoverygrenade", 1, true)
    then
        return false
    end
    for _, pat in ipairs(CAPTURE_SPHERE_PATTERNS) do
        if string.find(lower, pat, 1, true) then
            return true
        end
    end
    if string.find(lower, "sphere", 1, true) then
        return true
    end
    return false
end

local function isCaptureSphereWeapon(weapon)
    if weapon == nil or not weapon:IsValid() then
        return false
    end
    if isCaptureSphereItemName(objectName(weapon)) then
        return true
    end
    if isCaptureSphereItemName(getWeaponItemName(weapon)) then
        return true
    end
    local lower = string.lower(objectName(weapon))
    return string.find(lower, "captureball", 1, true) ~= nil
end

local function canConsumeCaptureSphere(weapon)
    if weapon == nil or not weapon:IsValid() then
        return false
    end
    if not isLocalPlayerWeapon(weapon) then
        return false
    end
    if isCaptureSphereWeapon(weapon) then
        return true
    end
    local hasBalls = false
    pcall(function()
        hasBalls = weapon:IsExistBulletInPlayerInventory() == true
    end)
    return hasBalls == true
end

local function captureCdEnabled()
    return Config.Features ~= nil and Config.Features.CaptureSphereCooldown == true
end

local function getCaptureCdSeconds()
    local s = Config.CaptureSphereCooldownSeconds
    if type(s) ~= "number" or s < 0 then
        return 5.0
    end
    return s
end

local function captureCdRemaining()
    if Weapons.lastCaptureThrowAt == nil then
        return 0
    end
    local rem = getCaptureCdSeconds() - (os.clock() - Weapons.lastCaptureThrowAt)
    if rem < 0 then
        return 0
    end
    return rem
end

local function shouldSuppressCapture()
    if not captureCdEnabled() then
        return false
    end
    -- Only scrub after an illegal throw attempt during CD.
    -- Using captureCdRemaining() here would also kill the first (legal) ball.
    if (Weapons.suppressCaptureUntil or 0) > os.clock() then
        return true
    end
    return false
end

local function armCaptureSuppress(seconds)
    local untilAt = os.clock() + (seconds or 2.0)
    if untilAt > (Weapons.suppressCaptureUntil or 0) then
        Weapons.suppressCaptureUntil = untilAt
    end
end

local function announceCaptureCd(remaining)
    if Config.AnnounceCaptureSphereCooldown == false then
        return
    end
    if Config.Hud and Config.Hud.UseSystemAnnounce == false then
        return
    end
    local debounce = 0.75
    if Config.Hud and type(Config.Hud.BlockedAnnounceDebounce) == "number" then
        debounce = Config.Hud.BlockedAnnounceDebounce
    end
    local nowClock = os.clock()
    if (nowClock - (Weapons.lastCaptureAnnounceAt or 0)) < debounce then
        return
    end
    Weapons.lastCaptureAnnounceAt = nowClock

    local whole = math.ceil((remaining or 0) - 0.0001)
    if whole < 0 then
        whole = 0
    end
    local msg = "Sphere cooldown: " .. tostring(whole) .. "s left"
    pcall(function()
        local Hud = require("hud")
        if Hud ~= nil and Hud.Announce ~= nil then
            Hud.Announce(msg)
        end
    end)
    log(msg)
end

local function startCaptureCd(reason, itemHint)
    Weapons.lastCaptureThrowAt = os.clock()
    Weapons.captureCdActive = true
    log(string.format(
        "capture sphere cooldown started (%.1fs) via %s item=%s",
        getCaptureCdSeconds(),
        tostring(reason or "?"),
        tostring(itemHint or "-")
    ))
    startCdClearLoop()
    -- Snapshot the legal first-throw actors so later CD scrubs do not kill them.
    Weapons.captureActorsAllowed = {}
    Session.Defer(30, function()
        if Weapons.mergeAllowedCaptureActors ~= nil then
            Weapons.mergeAllowedCaptureActors()
        end
    end)
    Session.Defer(120, function()
        if Weapons.mergeAllowedCaptureActors ~= nil then
            Weapons.mergeAllowedCaptureActors()
        end
    end)
    Session.Defer(300, function()
        if Weapons.mergeAllowedCaptureActors ~= nil then
            Weapons.mergeAllowedCaptureActors()
        end
    end)
    -- Do NOT SetDisableShoot/AimFlag here — that breaks attack crosshair/input.
    clearCaptureInputGates("cd-start-clear-leftover")
end

--- Defer CD start so we never mutate game state inside a UFunction callback.
local function deferCaptureCd(reason, itemHint)
    if not captureCdEnabled() then
        return
    end
    if captureCdRemaining() > 0.15 then
        announceCaptureCd(captureCdRemaining())
        log("capture CD already active — consume/scrub handles block")
        return
    end
    Session.Defer(50, function()
        if captureCdRemaining() > 0.15 then
            return
        end
        startCaptureCd(reason, itemHint)
    end)
end

local function shouldBlockWeapon(weapon)
    if weapon == nil or not weapon:IsValid() then
        return false
    end
    if not isLocalPlayerWeapon(weapon) then
        return false
    end
    local name = objectName(weapon)
    local itemName = getWeaponItemName(weapon)
    if isCombatGrenadeName(name) or isCombatGrenadeName(itemName) then
        return true
    end
    if matchesAllowlist(name) then
        return false
    end
    if itemName ~= nil and matchesAllowlist(itemName) then
        return false
    end
    return true
end

local function noteBlock(weapon, reason)
    Weapons.blockCount = Weapons.blockCount + 1
    local name = objectName(weapon)
    local key = name .. "|" .. tostring(reason)
    if Weapons.loggedClass[key] == nil then
        Weapons.loggedClass[key] = true
        log(string.format("blocked weapon (%s): %s", tostring(reason), name))
    else
        debug(string.format("blocked weapon (%s) x%d", tostring(reason), Weapons.blockCount))
    end
end

--- Soft neutralize thrown capture projectile only.
--- NEVER SetLifeSpan / tick-off / hide held BP_Item_PalSphere (softlocks input).
local function neutralizeThrownProjectile(actor)
    if actor == nil then
        return false
    end
    local okValid = false
    pcall(function()
        okValid = actor:IsValid() == true
    end)
    if not okValid then
        return false
    end
    pcall(function()
        actor:SetActorEnableCollision(false)
    end)
    pcall(function()
        actor:SetActorHiddenInGame(true)
    end)
    pcall(function()
        local move = actor.ProjectileMovement
        if move ~= nil then
            if move.StopMovementImmediately ~= nil then
                move:StopMovementImmediately()
            end
            if move.SetActive ~= nil then
                move:SetActive(false, true)
            end
        end
    end)
    pcall(function()
        actor:SetDamageable(false)
    end)
    pcall(function()
        actor:SetWeaponDamage(0)
    end)
    return true
end

local function neutralizeBullet(bullet)
    return neutralizeThrownProjectile(bullet)
end

local function failCaptureJudge(judge)
    if judge == nil then
        return false
    end
    -- Do not hide/destroy the judge actor — only force fail callback.
    pcall(function()
        judge:OnFailedFinish()
    end)
    return true
end

local function fullNameOf(obj)
    if obj == nil then
        return nil
    end
    local n = nil
    pcall(function()
        n = obj:GetFullName()
    end)
    return n
end

--- Held/equip item actors — scrubbing these softlocks the player.
local function isHeldSphereItemName(name)
    if name == nil or name == "" then
        return false
    end
    local lower = string.lower(name)
    if string.find(lower, "bp_item_palsphere", 1, true) then
        return true
    end
    if string.find(lower, "spweaponcaptureball", 1, true) then
        return true
    end
    -- Generic "Item_PalSphere" without Throw/Body = inventory/equip visual.
    if string.find(lower, "item_palsphere", 1, true)
        and string.find(lower, "throw", 1, true) == nil
        and string.find(lower, "body", 1, true) == nil
    then
        return true
    end
    return false
end

--- Only the in-flight throw actors (from user logs: ThrowObject / Body).
local function isThrownCaptureProjectileName(name)
    if name == nil or name == "" then
        return false
    end
    local lower = string.lower(name)
    if string.find(lower, "destroyed", 1, true) then
        return false
    end
    if isHeldSphereItemName(name) then
        return false
    end
    if string.find(lower, "dummyball", 1, true) then
        return false
    end
    return string.find(lower, "throwobject", 1, true) ~= nil
        or string.find(lower, "palsphere_throw", 1, true) ~= nil
        or string.find(lower, "bp_palsphere_throw", 1, true) ~= nil
        or string.find(lower, "palsphere_body", 1, true) ~= nil
        or string.find(lower, "bp_palsphere_body", 1, true) ~= nil
        or string.find(lower, "capturejudge", 1, true) ~= nil
end

--- Classes safe to FindAllOf during a short block burst (NOT BP_Item_PalSphere).
local CAPTURE_SCRUB_CLASSES = {
    "BP_PalSphere_ThrowObject_C",
    "BP_PalSphere_Body_C",
    "PalCaptureJudgeObject",
}

local function snapshotCaptureActorNames()
    local allowed = {}
    for _, className in ipairs(CAPTURE_SCRUB_CLASSES) do
        pcall(function()
            local all = FindAllOf(className)
            if all == nil then
                return
            end
            for _, actor in pairs(all) do
                local fn = fullNameOf(actor)
                if fn ~= nil then
                    allowed[fn] = true
                end
            end
        end)
    end
    return allowed
end

local function mergeAllowedCaptureActors()
    local snap = snapshotCaptureActorNames()
    for fn, _ in pairs(snap) do
        Weapons.captureActorsAllowed[fn] = true
    end
end
Weapons.mergeAllowedCaptureActors = mergeAllowedCaptureActors

local function scrubOneCaptureActor(actor, reason)
    if actor == nil then
        return false
    end
    local name = objectName(actor)
    if isHeldSphereItemName(name) then
        return false
    end
    if not isThrownCaptureProjectileName(name) then
        return false
    end
    local fn = fullNameOf(actor)
    if fn ~= nil and Weapons.captureActorsAllowed[fn] then
        return false -- first legal throw still in flight
    end
    if fn ~= nil and Weapons.scrubbedOnce[fn] then
        return false -- already neutralized
    end
    if fn ~= nil then
        Weapons.scrubbedOnce[fn] = true
    end

    local isJudge = string.find(string.lower(name or ""), "capturejudge", 1, true) ~= nil
    if isJudge then
        failCaptureJudge(actor)
    else
        neutralizeThrownProjectile(actor)
    end

    Weapons.scrubLogCount = (Weapons.scrubLogCount or 0) + 1
    if Weapons.scrubLogCount <= 20 then
        log(string.format(
            "capture CD scrub name=%s reason=%s",
            tostring(name),
            tostring(reason or "?")
        ))
    end
    return true
end

local function scrubCaptureActorsNow(reason)
    if not Session.IsAlive() then
        return 0
    end
    if not shouldSuppressCapture() then
        return 0
    end
    local scrubbed = 0
    for _, className in ipairs(CAPTURE_SCRUB_CLASSES) do
        pcall(function()
            local all = FindAllOf(className)
            if all == nil then
                return
            end
            for _, actor in pairs(all) do
                if scrubOneCaptureActor(actor, reason .. ":" .. className) then
                    scrubbed = scrubbed + 1
                end
            end
        end)
    end
    return scrubbed
end

--- Short burst only — no continuous LoopAsync FindAllOf (that softlocked the game).
local function scheduleCaptureScrubBursts(reason)
    if not Session.IsAlive() then
        return
    end
    armCaptureSuppress(math.max(captureCdRemaining(), 1.0))
    local delays = { 0, 50, 150, 350 }
    for _, ms in ipairs(delays) do
        Session.Defer(ms, function()
            scrubCaptureActorsNow(tostring(reason or "burst") .. "@" .. tostring(ms))
        end)
    end
end

local function tryStartWeaponCoolDown(weapon, reason)
    if weapon == nil then
        return
    end
    pcall(function()
        if weapon.CoolDownTime ~= nil then
            weapon.CoolDownTime = getCaptureCdSeconds()
        end
    end)
    local ok = pcall(function()
        weapon:StartCoolDown()
    end)
    if ok then
        log("capture CD StartCoolDown via " .. tostring(reason))
    end
end

local function onSphereBodySpawned(actor)
    if actor == nil then
        return
    end
    local name = objectName(actor)
    if isHeldSphereItemName(name) then
        return
    end
    Weapons.probeSphereBodyCount = (Weapons.probeSphereBodyCount or 0) + 1
    if Weapons.probeSphereBodyCount <= 12 then
        log(string.format(
            "probe throw/body #%d name=%s suppress=%s",
            Weapons.probeSphereBodyCount,
            tostring(name),
            tostring(shouldSuppressCapture())
        ))
    end
    if not shouldSuppressCapture() then
        return
    end
    if not isThrownCaptureProjectileName(name) then
        return
    end
    if ExecuteWithDelay ~= nil then
        ExecuteWithDelay(1, function()
            if actor ~= nil and shouldSuppressCapture() then
                scrubOneCaptureActor(actor, "NotifyOnNewObject")
            end
        end)
    else
        scrubOneCaptureActor(actor, "NotifyOnNewObject")
    end
end

local function onBulletCreatorPost(...)
    if not shouldSuppressCapture() then
        return
    end
    local args = { ... }
    local ret = args[#args]
    local bullet = unwrap(ret)
    if bullet == nil then
        return
    end
    scrubOneCaptureActor(bullet, "CreateBullet")
end

local function onHitCaptureBall(Context, Attacker)
    if not shouldSuppressCapture() then
        return
    end
    local atk = unwrap(Attacker)
    scrubOneCaptureActor(atk, "OnHitCaptureBall")
    announceCaptureCd(captureCdRemaining())
end

local function trySetParamNumber(param, value)
    if param == nil then
        return false
    end
    local ok = pcall(function()
        if param.set ~= nil then
            param:set(value)
        else
            error("no set")
        end
    end)
    return ok == true
end

local function makeItemFName(itemIdStr)
    if itemIdStr == nil or itemIdStr == "" then
        return nil
    end
    local fname = nil
    pcall(function()
        fname = UEHelpers.FindOrAddFName(itemIdStr)
    end)
    if fname ~= nil then
        return fname
    end
    pcall(function()
        fname = FName(itemIdStr)
    end)
    return fname
end

--- Refund a sphere that slipped through during CD.
local function refundCaptureItem(itemIdStr, count)
    if itemIdStr == nil then
        return
    end
    local n = count or 1
    if ExecuteWithDelay == nil then
        return
    end
    ExecuteWithDelay(100, function()
        local fname = makeItemFName(itemIdStr)
        if fname == nil then
            log("refund failed — no FName for " .. tostring(itemIdStr))
            return
        end
        local ok = pcall(function()
            local inv = FindFirstOf("PalPlayerInventoryData")
            if inv ~= nil and inv:IsValid() then
                inv:RequestAddItem(fname, n, false)
            else
                error("no inventory")
            end
        end)
        if ok then
            log(string.format("refunded %s x%d (CD block)", tostring(itemIdStr), n))
            return
        end
        pcall(function()
            local net = FindFirstOf("PalNetworkPlayerComponent")
            if net ~= nil and net:IsValid() then
                net:RequestAddItem_ToServer(fname, n, false)
                log(string.format("refunded via network %s x%d", tostring(itemIdStr), n))
            end
        end)
    end)
end

local function blockCaptureConsumeInPre(Context, StaticItemId, ConsumeNum)
    local itemStr = fnameToString(unwrap(StaticItemId)) or fnameToString(StaticItemId)
    local weapon = unwrap(Context)
    local rem = captureCdRemaining()
    local wantNum = unwrap(ConsumeNum)
    if type(wantNum) ~= "number" then
        wantNum = 1
    end

    log(string.format(
        "RequestConsumeItem PRE item=%s num=%s local=%s cdRem=%.2f aimFlag=%s",
        tostring(itemStr),
        tostring(wantNum),
        tostring(weapon ~= nil and isLocalPlayerWeapon(weapon)),
        rem,
        tostring(Weapons.aimFlagOn)
    ))

    if itemStr == nil or not isCaptureSphereItemName(itemStr) then
        return false
    end
    if weapon ~= nil and not isLocalPlayerWeapon(weapon) then
        return false
    end

    if rem > 0.2 then
        announceCaptureCd(rem)
        armCaptureSuppress(math.max(rem, 1.0))
        -- Zero consume so the game does not spend the sphere.
        local zeroed = trySetParamNumber(ConsumeNum, 0)
        log(string.format(
            "capture CD block consume zeroed=%s item=%s (suppress projectiles)",
            tostring(zeroed),
            tostring(itemStr)
        ))
        if weapon ~= nil then
            pcall(function()
                weapon:OnPullCancel()
            end)
            tryStartWeaponCoolDown(weapon, "block-consume")
        end
        setCaptureAimDisabled(false, "reassert-clear-during-cd")
        -- Scrub thrown ThrowObject/Body only (never held BP_Item_PalSphere).
        scheduleCaptureScrubBursts("block-consume")
        if not zeroed then
            refundCaptureItem(itemStr, wantNum)
        end
        return true -- blocked
    end

    deferCaptureCd("RequestConsumeItem", itemStr)
    return false
end

local function onRequestConsumePre(Context, StaticItemId, ConsumeNum)
    blockCaptureConsumeInPre(Context, StaticItemId, ConsumeNum)
end

local function onDecrementPalSpherePre(Context, RequestConsumeNum, UsedItemID)
    local rem = captureCdRemaining()
    local weapon = unwrap(Context)
    if rem > 0.2 and (weapon == nil or isLocalPlayerWeapon(weapon)) then
        local zeroed = trySetParamNumber(RequestConsumeNum, 0)
        announceCaptureCd(rem)
        log("DecrementCurrentSelectPalSphere PRE blocked zeroed=" .. tostring(zeroed))
        if weapon ~= nil then
            pcall(function()
                weapon:OnPullCancel()
            end)
        end
        scheduleCaptureScrubBursts("decrement-block")
    end
end

local function onDecrementPalSpherePost(Context, a, b, c)
    log(string.format(
        "DecrementCurrentSelectPalSphere POST a=%s b=%s c=%s",
        tostring(a),
        tostring(b),
        tostring(c)
    ))

    local weapon = unwrap(Context)
    local itemStr = fnameToString(unwrap(c))
        or fnameToString(unwrap(b))
        or fnameToString(a)

    if weapon ~= nil and not isLocalPlayerWeapon(weapon) then
        return
    end
    if itemStr ~= nil and not isCaptureSphereItemName(itemStr) then
        return
    end
    if captureCdRemaining() > 0.15 then
        return
    end
    deferCaptureCd("DecrementCurrentSelectPalSphere", itemStr or "?")
end

local function onWeaponPullTrigger(Context)
    if not Session.IsAlive() then
        return
    end
    local weapon = unwrap(Context)

    if Config.Debug then
        Weapons.probePullCount = (Weapons.probePullCount or 0) + 1
        if Weapons.probePullCount <= 15 then
            log(string.format(
                "probe OnPullTrigger #%d local=%s capture=%s canConsume=%s item=%s cd=%.2f name=%s",
                Weapons.probePullCount,
                tostring(isLocalPlayerWeapon(weapon)),
                tostring(isCaptureSphereWeapon(weapon)),
                tostring(canConsumeCaptureSphere(weapon)),
                tostring(getWeaponItemName(weapon)),
                captureCdRemaining(),
                objectName(weapon)
            ))
        end
    end

    -- Capture CD: announce + scrub only (do not disable shoot/aim — breaks attack ADS).
    if captureCdEnabled() and isLocalPlayerWeapon(weapon) then
        local rem = captureCdRemaining()
        if rem > 0 and (isCaptureSphereWeapon(weapon) or canConsumeCaptureSphere(weapon)) then
            announceCaptureCd(rem)
            noteBlock(weapon, "CaptureSphereCD")
            armCaptureSuppress(math.max(rem, 1.0))
            pcall(function()
                weapon:OnPullCancel()
            end)
            tryStartWeaponCoolDown(weapon, "pull-during-cd")
            scheduleCaptureScrubBursts("pull-during-cd")
            return
        end
    end

    if not shouldBlockWeapon(weapon) then
        return
    end
    noteBlock(weapon, "OnPullTrigger")
    pcall(function()
        weapon:OnPullCancel()
    end)
end

local function onReleaseTrigger(Context)
    local weapon = unwrap(Context)

    -- Sphere throw happens on release while aiming — cancel consume path during CD.
    if captureCdEnabled() and isLocalPlayerWeapon(weapon) then
        local rem = captureCdRemaining()
        if rem > 0.15 and (isCaptureSphereWeapon(weapon) or canConsumeCaptureSphere(weapon)) then
            announceCaptureCd(rem)
            noteBlock(weapon, "CaptureSphereCD-release")
            pcall(function()
                weapon:OnPullCancel()
            end)
            scheduleCaptureScrubBursts("release-during-cd")
            return
        end
    end

    if not shouldBlockWeapon(weapon) then
        return
    end
    noteBlock(weapon, "OnReleaseTrigger")
end

local function onCreatedBullet(Context, Bullet)
    local weapon = unwrap(Context)
    local bullet = unwrap(Bullet)

    if shouldSuppressCapture() and isLocalPlayerWeapon(weapon) then
        noteBlock(weapon, "CaptureSphereCD-bullet")
        announceCaptureCd(captureCdRemaining())
        scrubOneCaptureActor(bullet, "OnCreatedBullet")
        return
    end

    if not shouldBlockWeapon(weapon) then
        return
    end
    noteBlock(weapon, "OnCreatedBullet")
    neutralizeBullet(bullet)
end

local function onChallengeCapture(Context, Character, CapturePower)
    if not shouldSuppressCapture() then
        return
    end
    local judge = unwrap(Context)
    local fn = fullNameOf(judge)
    if fn ~= nil and Weapons.captureActorsAllowed[fn] then
        return -- first legal throw's judge
    end
    local zeroed = trySetParamNumber(CapturePower, 0)
    log(string.format(
        "ChallengeCapture blocked (CD) powerZeroed=%s",
        tostring(zeroed)
    ))
    announceCaptureCd(captureCdRemaining())
    failCaptureJudge(judge)
end

local function onGetWeaponDamagePost(Context, ReturnValue)
    local weapon = unwrap(Context)
    if not shouldBlockWeapon(weapon) then
        return
    end
    noteBlock(weapon, "GetWeaponDamage")
    pcall(function()
        if ReturnValue ~= nil and ReturnValue.set ~= nil then
            ReturnValue:set(0)
        end
    end)
end

local function onGetWeaponBaseDamagePost(Context, ReturnValue)
    local weapon = unwrap(Context)
    if not shouldBlockWeapon(weapon) then
        return
    end
    pcall(function()
        if ReturnValue ~= nil and ReturnValue.set ~= nil then
            ReturnValue:set(0)
        end
    end)
end

function Weapons.Register()
    if Weapons.hooked then
        return
    end

    local blockWeapons = Config.Features and Config.Features.BlockPlayerWeapons
    local sphereCd = captureCdEnabled()
    if not blockWeapons and not sphereCd then
        log("weapon systems disabled")
        return
    end

    Weapons.hooked = true
    Weapons.probePullCount = 0

    local okPull, errPull = pcall(function()
        RegisterHook("/Script/Pal.PalWeaponBase:OnPullTrigger", onWeaponPullTrigger)
    end)
    if not okPull then
        log("OnPullTrigger hook failed: " .. tostring(errPull))
    else
        log("hooked PalWeaponBase:OnPullTrigger")
    end

    pcall(function()
        RegisterHook("/Script/Pal.PalWeaponBase:OnReleaseTrigger", onReleaseTrigger)
    end)

    pcall(function()
        RegisterHook("/Script/Pal.PalWeaponBase:OnCreatedBullet", onCreatedBullet)
    end)

    if sphereCd then
        startCdClearLoop()

        local okDec, errDec = pcall(function()
            RegisterHook(
                "/Script/Pal.PalWeaponBase:DecrementCurrentSelectPalSphere",
                onDecrementPalSpherePre,
                onDecrementPalSpherePost
            )
        end)
        if okDec then
            log("hooked DecrementCurrentSelectPalSphere (capture CD pre+post)")
        else
            log("DecrementCurrentSelectPalSphere hook failed: " .. tostring(errDec))
        end

        pcall(function()
            RegisterHook(
                "/Script/Pal.PalWeaponBase:RequestConsumeItem_ForThrowWeapon",
                onRequestConsumePre
            )
        end)
        pcall(function()
            RegisterHook("/Script/Pal.PalWeaponBase:RequestConsumeItem", onRequestConsumePre)
        end)

        pcall(function()
            RegisterHook(
                "/Script/Pal.PalCaptureJudgeObject:ChallengeCapture",
                onChallengeCapture
            )
        end)
        pcall(function()
            RegisterHook(
                "/Script/Pal.PalCaptureJudgeObject:ChallengeCapture_ToServer",
                onChallengeCapture
            )
        end)

        pcall(function()
            RegisterHook(
                "/Script/Pal.PalBulletCreator:CreateBullet",
                function() end,
                onBulletCreatorPost
            )
            log("hooked PalBulletCreator:CreateBullet")
        end)
        pcall(function()
            RegisterHook(
                "/Script/Pal.PalBulletCreator:SpawnBullet",
                function() end,
                onBulletCreatorPost
            )
            log("hooked PalBulletCreator:SpawnBullet")
        end)

        pcall(function()
            RegisterHook(
                "/Script/Pal.PalOtomoAttackStopJudgeByBallList:OnHitCaptureBall",
                onHitCaptureBall
            )
            log("hooked OnHitCaptureBall")
        end)

        -- Watch thrown sphere actors only — never BP_Item_PalSphere (held item).
        pcall(function()
            NotifyOnNewObject("/Script/Pal.PalSphereBodyBase", onSphereBodySpawned)
            log("watching PalSphereBodyBase (Throw/Body filter)")
        end)
        pcall(function()
            NotifyOnNewObject("/Script/Pal.PalCaptureJudgeObject", onSphereBodySpawned)
            log("watching PalCaptureJudgeObject")
        end)
        local throwPaths = {
            "/Game/Pal/Blueprint/Bullet/BP_PalSphere_ThrowObject.BP_PalSphere_ThrowObject_C",
            "/Game/Pal/Blueprint/Item/BP_PalSphere_ThrowObject.BP_PalSphere_ThrowObject_C",
            "/Game/Pal/Blueprint/Bullet/BP_PalSphere_Body.BP_PalSphere_Body_C",
            "/Game/Pal/Blueprint/Item/BP_PalSphere_Body.BP_PalSphere_Body_C",
        }
        for _, path in ipairs(throwPaths) do
            pcall(function()
                NotifyOnNewObject(path, onSphereBodySpawned)
            end)
        end

        -- Clear leftover gates only while a world session is alive.
        Session.Defer(500, function()
            clearCaptureInputGates("boot-clear")
        end)
        Session.Defer(2000, function()
            clearCaptureInputGates("boot-clear-2s")
        end)

        log(string.format(
            "capture sphere cooldown enabled (%.1fs) — zero consume + ThrowObject scrub (no shoot/aim flags)",
            getCaptureCdSeconds()
        ))
    end

    if blockWeapons then
        pcall(function()
            RegisterHook(
                "/Script/Pal.PalWeaponBase:GetWeaponDamage",
                function() end,
                onGetWeaponDamagePost
            )
        end)
        pcall(function()
            RegisterHook(
                "/Script/Pal.PalWeaponBase:GetWeaponBaseDamage",
                function() end,
                onGetWeaponBaseDamagePost
            )
        end)
        pcall(function()
            NotifyOnNewObject("/Script/Pal.PalBullet", function(Bullet)
                if Bullet == nil or not Bullet:IsValid() then
                    return
                end
                local ok, owner = pcall(function()
                    return Bullet:GetOwner()
                end)
                if not ok or owner == nil then
                    return
                end
                if shouldBlockWeapon(owner) then
                    neutralizeBullet(Bullet)
                    noteBlock(owner, "PalBullet spawn")
                end
            end)
        end)
        log("weapon combat block enabled (spheres/tools allowlisted)")
    end
end

return Weapons
