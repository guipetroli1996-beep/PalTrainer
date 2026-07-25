--[[
  TrainerCombat — Aim skill HUD (ride-style bar while aiming)

  Palworld is UMG-first; Engine Canvas DrawHUD often never paints.
  Primary visible path: PalUtility:SendSystemAnnounce (same as lock toasts).
  Secondary: ReceiveDrawHUD Canvas (best-effort).
  Also mirrors state onto TrainerCombatBP ModActor for a future UMG widget.
]]

local Config = require("config")
local Session = require("session")

local AimSkillHud = {
    hooked = false,
    visible = false,
    slots = {},
    font = nil,
    drawOkLogged = false,
    drawFailLogged = false,
    drawSkipLogged = false,
    drawHookFired = false,
    lastBpSyncAt = 0,
    lastAnnounceAt = 0,
    lastAnnounceKey = nil,
    announceOnShowDone = false,
    loggedMissingBp = false,
    loopStarted = false,
    widgetPushLogged = false,
    widgetDiagLogged = false,
    nameWriteLogged = false,
    layoutPinned = false,
}

local MOD = "[TrainerCombat]"

local function log(msg)
    print(string.format("%s %s", MOD, msg))
end

local function hudCfg()
    return (Config.Hud and Config.Hud.AimSkillHud) or {}
end

local function featureOn()
    if Config.Hud == nil or Config.Hud.Enabled == false then
        return false
    end
    return Config.Hud.UseAimSkillHud ~= false
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

local function toNumber(v)
    v = unwrap(v)
    if type(v) == "number" then
        return v
    end
    if type(v) == "string" then
        return tonumber(v)
    end
    local n = nil
    pcall(function()
        if v ~= nil and v.GetUnderlyingType ~= nil then
            n = tonumber(tostring(v))
        end
    end)
    if type(n) == "number" then
        return n
    end
    pcall(function()
        n = tonumber(tostring(v))
    end)
    return n
end

local function getPalUtility()
    local util = nil
    pcall(function()
        util = StaticFindObject("/Script/Pal.Default__PalUtility")
    end)
    if util ~= nil then
        return util
    end
    pcall(function()
        util = FindFirstOf("PalUtility")
    end)
    return util
end

local function getPalPlayerController()
    local pc = nil
    pcall(function()
        pc = FindFirstOf("PalPlayerController")
    end)
    if pc ~= nil then
        local ok = false
        pcall(function()
            ok = pc:IsValid() == true
        end)
        if ok then
            return pc
        end
    end
    return nil
end

local function formatSlotLine(slot, index)
    local key = tostring(slot.key or index)
    if slot.enabled ~= true then
        return string.format("[%s] -", key)
    end
    local name = tostring(slot.name or "Skill")
    local remain = tonumber(slot.coolRemain) or 0
    if remain > 0.05 then
        return string.format("[%s] %s %.0fs", key, name, remain)
    end
    return string.format("[%s] %s", key, name)
end

local function buildAnnounceText()
    local parts = {}
    for i = 1, 3 do
        local s = AimSkillHud.slots[i] or { key = i, enabled = false }
        parts[#parts + 1] = formatSlotLine(s, i)
    end
    return "Skills  " .. table.concat(parts, "  |  ")
end

local function announceKey()
    local parts = {}
    for i = 1, 3 do
        local s = AimSkillHud.slots[i] or {}
        local rem = math.floor((tonumber(s.coolRemain) or 0) + 0.999)
        parts[#parts + 1] = string.format(
            "%s:%s:%d:%s",
            tostring(s.key or i),
            tostring(s.name or ""),
            rem,
            tostring(s.enabled == true)
        )
    end
    return table.concat(parts, "|")
end

--- Reliable on-screen path (proven with summon-lock toasts).
local function tryAnnounce(force)
    if not AimSkillHud.visible or not featureOn() then
        return false
    end
    local cfg = hudCfg()
    if cfg.UseSystemAnnounce == false then
        return false
    end
    local key = announceKey()
    local t = os.clock()
    local gap = cfg.AnnounceIntervalSeconds or 1.25
    if not force then
        if key == AimSkillHud.lastAnnounceKey and (t - (AimSkillHud.lastAnnounceAt or 0)) < gap then
            return false
        end
        if (t - (AimSkillHud.lastAnnounceAt or 0)) < gap and AimSkillHud.announceOnShowDone then
            -- Still allow CD digit changes after gap.
            if key == AimSkillHud.lastAnnounceKey then
                return false
            end
        end
    end

    local text = buildAnnounceText()
    local util = getPalUtility()
    local pc = getPalPlayerController()
    if util == nil or pc == nil or util.SendSystemAnnounce == nil then
        if not AimSkillHud.drawFailLogged then
            log("aim-skill-hud: announce unavailable (PalUtility/PC)")
        end
        return false
    end
    local ok = pcall(function()
        util:SendSystemAnnounce(pc, text)
    end)
    if ok then
        AimSkillHud.lastAnnounceAt = t
        AimSkillHud.lastAnnounceKey = key
        AimSkillHud.announceOnShowDone = true
        if force then
            log("aim-skill-hud: announce OK — " .. text)
        end
        return true
    end
    return false
end

local function tryDebugMessage(text)
    local pc = getPalPlayerController()
    if pc == nil then
        return false
    end
    local ok = pcall(function()
        if pc.ClientMessage ~= nil then
            pc:ClientMessage(text)
            return
        end
        error("no ClientMessage")
    end)
    if ok then
        return true
    end
    ok = pcall(function()
        -- AddOnScreenDebugMessage(Key, TimeToDisplay, Color, Text)
        pc:AddOnScreenDebugMessage(-1, 1.2, { R = 1, G = 1, B = 0.6, A = 1 }, text)
    end)
    return ok == true
end

local function getFont()
    if AimSkillHud.font ~= nil then
        local ok = false
        pcall(function()
            ok = AimSkillHud.font:IsValid() == true
        end)
        if ok then
            return AimSkillHud.font
        end
        AimSkillHud.font = nil
    end
    local candidates = {
        "/Engine/EngineFonts/Roboto.Roboto",
        "/Engine/EngineFonts/RobotoDistanceField.RobotoDistanceField",
        "/Engine/EngineFonts/TinyFont.TinyFont",
    }
    for _, path in ipairs(candidates) do
        local font = nil
        pcall(function()
            font = StaticFindObject(path)
        end)
        if font ~= nil then
            local ok = false
            pcall(function()
                ok = font:IsValid() == true
            end)
            if ok then
                AimSkillHud.font = font
                return font
            end
        end
    end
    pcall(function()
        local f = FindFirstOf("Font")
        if f ~= nil and f:IsValid() then
            AimSkillHud.font = f
        end
    end)
    return AimSkillHud.font
end

local function makeColor(r, g, b, a)
    return { R = r, G = g, B = b, A = a }
end

local function makeVec2(x, y)
    local v = nil
    pcall(function()
        if FVector2D ~= nil then
            v = FVector2D(x, y)
        end
    end)
    if v ~= nil then
        return v
    end
    return { X = x, Y = y }
end

local function makeFText(str)
    local s = tostring(str or ""):gsub("—", "-")
    local ft = nil
    pcall(function()
        ft = FText(s)
    end)
    return ft, s
end

--- Left-justify text + pin Canvas Alignment.X = 0 (grow right).
--- Never SetPosition / AutoSize — those were rewriting Y to 0 and jumping the bar.
local function applyLeftAlignLayout(_widget, textBlock)
    if textBlock ~= nil then
        -- ETextJustify::Left = 0
        pcall(function()
            textBlock:SetJustification(0)
        end)
        pcall(function()
            textBlock.Justification = 0
        end)
        pcall(function()
            local slot = textBlock.Slot
            if slot ~= nil then
                pcall(function()
                    slot:SetHorizontalAlignment(0) -- HAlign_Left
                end)
                pcall(function()
                    slot.HorizontalAlignment = 0
                end)
            end
        end)
    end
    if AimSkillHud.layoutPinned or textBlock == nil then
        return
    end
    local parent = nil
    pcall(function()
        if textBlock.GetParent ~= nil then
            parent = textBlock:GetParent()
        end
    end)
    if parent == nil then
        return
    end
    local pinned = false
    pcall(function()
        local slot = parent.Slot
        if slot == nil then
            return
        end
        local alignY = 0.5
        pcall(function()
            local a = slot.Alignment
            if a ~= nil then
                alignY = tonumber(a.Y) or tonumber(a.y) or alignY
            end
        end)
        local align = makeVec2(0.0, alignY)
        pcall(function()
            slot:SetAlignment(align)
            pinned = true
        end)
        if not pinned then
            pcall(function()
                slot.Alignment = align
                pinned = true
            end)
        end
    end)
    if pinned then
        AimSkillHud.layoutPinned = true
        log("aim-skill-hud: Alignment.X=0 (grow right; Position/Y untouched)")
    end
end

--- UE4SS requires FText for UMG SetText — plain Lua strings do not stick.
local function setTextBlockText(textBlock, str)
    if textBlock == nil then
        return false
    end
    local valid = false
    pcall(function()
        valid = textBlock:IsValid() == true
    end)
    if not valid then
        return false
    end
    local ft, s = makeFText(str)
    if ft ~= nil then
        local ok = pcall(function()
            textBlock:SetText(ft)
        end)
        if ok then
            return true
        end
        ok = pcall(function()
            textBlock.Text = ft
        end)
        if ok then
            return true
        end
    end
    -- Last-resort plain string (usually fails on UMG).
    local ok = pcall(function()
        textBlock:SetText(s)
    end)
    return ok == true
end

local function resolveSlotTextBlock(widget, index)
    if widget == nil then
        return nil
    end
    local names = {
        "Slot" .. tostring(index) .. "Text",
        "Slot " .. tostring(index) .. "Text",
    }
    for _, propName in ipairs(names) do
        local tb = nil
        pcall(function()
            tb = widget[propName]
        end)
        if tb ~= nil then
            local valid = false
            pcall(function()
                valid = tb:IsValid() == true
            end)
            if valid then
                return tb
            end
        end
        -- Works even when TextBlock is not marked Is Variable.
        pcall(function()
            if widget.GetWidgetFromName ~= nil then
                local n = nil
                pcall(function()
                    n = FName(propName)
                end)
                if n ~= nil then
                    tb = widget:GetWidgetFromName(n)
                end
                if tb == nil then
                    tb = widget:GetWidgetFromName(propName)
                end
            end
        end)
        if tb ~= nil then
            local valid = false
            pcall(function()
                valid = tb:IsValid() == true
            end)
            if valid then
                return tb
            end
        end
    end
    return nil
end

--- Safe path: only touch the widget ModActor already owns (no FindAllOf).
local function pushLinesViaModActorWidget(actor)
    if not AimSkillHud.visible or actor == nil then
        return false
    end
    local widget = nil
    pcall(function()
        widget = actor.AimSkillHudWidget
    end)
    if widget == nil then
        if not AimSkillHud.widgetDiagLogged then
            AimSkillHud.widgetDiagLogged = true
            log("aim-skill-hud: widget push wait — AimSkillHudWidget still nil (BP create not done yet)")
        end
        return false
    end
    local valid = false
    pcall(function()
        valid = widget:IsValid() == true
    end)
    if not valid then
        return false
    end

    local wroteAny = false
    local diagParts = {}
    for i = 0, 2 do
        local slot = AimSkillHud.slots[i + 1] or { key = i + 1, enabled = false }
        local line = formatSlotLine(slot, i + 1):gsub("—", "-")
        local tb = resolveSlotTextBlock(widget, i)
        if tb ~= nil then
            applyLeftAlignLayout(widget, tb)
        end
        local ok = setTextBlockText(tb, line)
        if ok then
            wroteAny = true
        end
        diagParts[#diagParts + 1] = string.format(
            "s%d tb=%s set=%s line=%s",
            i,
            tostring(tb ~= nil),
            tostring(ok),
            line
        )
    end
    if not AimSkillHud.widgetDiagLogged then
        AimSkillHud.widgetDiagLogged = true
        log("aim-skill-hud: widget push diag | " .. table.concat(diagParts, " | "))
    end
    if wroteAny and not AimSkillHud.widgetPushLogged then
        AimSkillHud.widgetPushLogged = true
        log("aim-skill-hud: pushed names via ModActor.AimSkillHudWidget (FText)")
    end
    return wroteAny
end

local function writeBpString(actor, propName, value)
    local s = tostring(value or "")
    local ok = pcall(function()
        actor[propName] = s
    end)
    if not ok then
        return false
    end
    local rb = nil
    pcall(function()
        rb = actor[propName]
    end)
    return tostring(rb or "") == s
end

local function syncModActorProperties(actor)
    if actor == nil then
        return false
    end
    pcall(function()
        actor.AimSkillHudVisible = AimSkillHud.visible == true
    end)

    local nameWriteOk = true
    for i = 0, 2 do
        local s = AimSkillHud.slots[i + 1] or {}
        local prefix = "AimSkill" .. tostring(i)
        local name = tostring(s.name or ""):gsub("—", "-")
        local line = formatSlotLine(s, i + 1):gsub("—", "-")
        if not writeBpString(actor, prefix .. "Name", name) then
            nameWriteOk = false
        end
        -- Ints/floats/bools do stick; strings often do not on this UE4SS build.
        pcall(function()
            actor[prefix .. "Line"] = line
            actor[prefix .. "CoolRemain"] = tonumber(s.coolRemain) or 0
            actor[prefix .. "CoolMax"] = tonumber(s.coolMax) or 1
            actor[prefix .. "Enabled"] = s.enabled == true
            actor[prefix .. "WazaId"] = tonumber(s.wazaId) or 0
        end)
    end
    if not AimSkillHud.nameWriteLogged then
        AimSkillHud.nameWriteLogged = true
        log("aim-skill-hud: ModActor string Name write ok=" .. tostring(nameWriteOk)
            .. " (false is expected — names come from Lua FText SetText; keep BP Tick off SetText)")
    end

    pcall(function()
        actor.AimSkillHudDirty = true
    end)

    -- Safe text push via owned widget ref only (never FindFirstOf/FindAllOf).
    pushLinesViaModActorWidget(actor)
    return true
end

local function trySyncBp()
    local BpBridge = nil
    pcall(function()
        BpBridge = require("bp_bridge")
    end)
    if BpBridge == nil or BpBridge.GetActor == nil then
        return
    end
    local actor = BpBridge.GetActor()
    if actor == nil then
        return
    end
    local t = os.clock()
    -- While visible, refresh widget text often; property dump throttled inside sync.
    if AimSkillHud.visible then
        if (t - (AimSkillHud.lastBpSyncAt or 0)) >= 0.12 then
            AimSkillHud.lastBpSyncAt = t
            syncModActorProperties(actor)
        else
            pushLinesViaModActorWidget(actor)
        end
        return
    end
    if (t - (AimSkillHud.lastBpSyncAt or 0)) < 0.12 then
        return
    end
    AimSkillHud.lastBpSyncAt = t
    syncModActorProperties(actor)
end

local function drawSlots(canvas, sizeX, sizeY)
    if canvas == nil or type(sizeX) ~= "number" or type(sizeY) ~= "number" then
        return false
    end
    local font = getFont()
    local cfg = hudCfg()
    local yPct = cfg.YPercent or 0.88
    local scale = cfg.Scale or 1.25
    local lineH = (cfg.LineHeight or 22) * scale
    local baseY = sizeY * yPct
    local centerX = sizeX * 0.5
    local colorReady = makeColor(0.95, 0.95, 0.85, 1.0)
    local colorCd = makeColor(0.55, 0.75, 1.0, 1.0)
    local colorEmpty = makeColor(0.45, 0.45, 0.45, 0.85)
    local shadow = makeColor(0, 0, 0, 0.85)

    local lines = {}
    for i = 1, 3 do
        local s = AimSkillHud.slots[i] or { key = i, enabled = false }
        lines[#lines + 1] = {
            text = formatSlotLine(s, i),
            color = (s.enabled ~= true and colorEmpty)
                or ((tonumber(s.coolRemain) or 0) > 0.05 and colorCd)
                or colorReady,
        }
    end

    local startY = baseY - (lineH * (#lines - 1) * 0.5)
    local drew = false
    for i, line in ipairs(lines) do
        local y = startY + (i - 1) * lineH
        local pos = makeVec2(centerX, y)
        local scaleV = makeVec2(scale, scale)
        local ok = pcall(function()
            canvas:K2_DrawText(
                font,
                line.text,
                pos,
                scaleV,
                line.color,
                0.0,
                shadow,
                makeVec2(1, 1),
                true,
                true,
                true,
                makeColor(0, 0, 0, 0.9)
            )
        end)
        if not ok then
            ok = pcall(function()
                canvas:K2_DrawText(font, line.text, pos, line.color)
            end)
        end
        if ok then
            drew = true
        end
    end
    return drew
end

local function onDrawHudPost(Context, SizeX, SizeY)
    if not AimSkillHud.drawHookFired then
        AimSkillHud.drawHookFired = true
        log("aim-skill-hud: ReceiveDrawHUD POST fired")
    end
    if not AimSkillHud.visible or not featureOn() then
        return
    end
    if not Session.IsAlive() then
        return
    end
    local hud = unwrap(Context)
    local sx = toNumber(SizeX)
    local sy = toNumber(SizeY)
    local canvas = nil
    pcall(function()
        if hud ~= nil then
            canvas = hud.Canvas
        end
    end)
    if canvas == nil then
        pcall(function()
            if hud ~= nil and hud.GetCanvas ~= nil then
                canvas = hud:GetCanvas()
            end
        end)
    end
    if canvas == nil or sx == nil or sy == nil then
        if not AimSkillHud.drawSkipLogged then
            AimSkillHud.drawSkipLogged = true
            log(string.format(
                "aim-skill-hud: DrawHUD skip canvas=%s sx=%s sy=%s (using announce)",
                tostring(canvas ~= nil),
                tostring(sx),
                tostring(sy)
            ))
        end
        return
    end
    local ok = drawSlots(canvas, sx, sy)
    if ok and not AimSkillHud.drawOkLogged then
        AimSkillHud.drawOkLogged = true
        log("aim-skill-hud: DrawHUD OK")
    elseif (not ok) and not AimSkillHud.drawFailLogged then
        AimSkillHud.drawFailLogged = true
        log("aim-skill-hud: DrawHUD draw failed (using announce)")
    end
end

local function startAnnounceLoop()
    if AimSkillHud.loopStarted or LoopAsync == nil then
        return
    end
    AimSkillHud.loopStarted = true
    LoopAsync(400, function()
        if not featureOn() then
            return false
        end
        if not Session.IsAlive() then
            return false
        end
        if AimSkillHud.visible then
            trySyncBp()
            tryAnnounce(false)
        end
        return false
    end)
end

function AimSkillHud.Register()
    if AimSkillHud.hooked then
        return
    end
    AimSkillHud.hooked = true
    if not featureOn() then
        log("aim-skill-hud disabled (UseAimSkillHud=false)")
        return
    end
    pcall(function()
        RegisterHook(
            "/Script/Engine.HUD:ReceiveDrawHUD",
            function()
            end,
            function(Context, SizeX, SizeY)
                onDrawHudPost(Context, SizeX, SizeY)
            end
        )
        log("aim-skill-hud: hooked ReceiveDrawHUD (POST)")
    end)
    -- Some builds only hit Blueprint HUD subclasses; best-effort extra hook.
    pcall(function()
        RegisterHook("/Script/Engine.HUD:DrawHUD", function()
        end, function(Context)
            onDrawHudPost(Context, 1920, 1080)
        end)
    end)
    startAnnounceLoop()
    log("aim-skill-hud: system-announce fallback armed")
end

function AimSkillHud.Show(slots, reason)
    if not featureOn() then
        return false
    end
    AimSkillHud.slots = slots or {}
    local was = AimSkillHud.visible
    AimSkillHud.visible = true
    trySyncBp()
    if not was then
        AimSkillHud.announceOnShowDone = false
        log("aim-skill-hud: show (" .. tostring(reason or "show") .. ")")
        local ok = tryAnnounce(true)
        if not ok then
            tryDebugMessage(buildAnnounceText())
        end
    else
        tryAnnounce(false)
    end
    return true
end

function AimSkillHud.Update(slots, reason)
    if not featureOn() or not AimSkillHud.visible then
        return false
    end
    if slots ~= nil then
        AimSkillHud.slots = slots
    end
    trySyncBp()
    tryAnnounce(false)
    return true
end

function AimSkillHud.Hide(reason)
    if not AimSkillHud.visible then
        AimSkillHud.slots = {}
        return false
    end
    AimSkillHud.visible = false
    AimSkillHud.slots = {}
    AimSkillHud.announceOnShowDone = false
    AimSkillHud.lastAnnounceKey = nil
    AimSkillHud.widgetPushLogged = false
    AimSkillHud.widgetDiagLogged = false
    AimSkillHud.nameWriteLogged = false
    AimSkillHud.layoutPinned = false
    trySyncBp()
    log("aim-skill-hud: hide (" .. tostring(reason or "hide") .. ")")
    return true
end

function AimSkillHud.IsVisible()
    return AimSkillHud.visible == true
end

return AimSkillHud
