--[[
  TrainerCombat — Phase 1C: remove weapon schematics / tech unlocks / combat grenades.

  Strips combat weapon technology tree entries and matching item recipes.
  Also strips throwable combat grenades from tech / recipes / loot.
  Keeps: Pal spheres, sphere launchers, axes/pickaxes, armor, gliders,
  grappling guns, base defenses, buildings, Pal skill unlocks,
  Pal Recovery Grenade (PalHealingGrenade).
]]

local Config = require("config")
local Session = require("session")

local Schematics = {
    applied = false,
    lootApplied = false,
    attempt = 0,
}

local MOD = "[TrainerCombat]"

-- Exact technology IDs that are combat weapons / ammo (from official tech ID list).
-- Sphere launchers intentionally omitted (kept for trainer play).
local BLOCK_TECH_EXACT = {
    Arrow = true,
    Arrow_Fire = true,
    Arrow_Poison = true,
    AssaultRifleBullet = true,
    Bat3 = true,
    Battle_GunPowder_Grade_02 = true,
    Battle_MeleeWeapon_Bat = true,
    Battle_MeleeWeapon_Bat2 = true,
    Battle_MeleeWeapon_Sword = true,
    Battle_RangeWeapon_AssaultRifle = true,
    Battle_RangeWeapon_Bow1 = true,
    Battle_RangeWeapon_Bow3 = true,
    Battle_RangeWeapon_BowGun = true,
    Battle_RangeWeapon_CompoundBow = true,
    Battle_RangeWeapon_FlameThrower = true,
    Battle_RangeWeapon_GatlingGun = true,
    Battle_RangeWeapon_GrenadeLauncher = true,
    Battle_RangeWeapon_GuidedMissileLauncher = true,
    Battle_RangeWeapon_HandGun = true,
    Battle_RangeWeapon_LaserRifle = true,
    Battle_RangeWeapon_OldRevolver = true,
    Battle_RangeWeapon_Rifle = true,
    Battle_RangeWeapon_RocketLauncher = true,
    Battle_RangeWeapon_SemiAutoRifle = true,
    Battle_RangeWeapon_SemiAutoShotgun = true,
    Battle_RangeWeapon_ShotGun = true,
    Battle_RangeWeapon_ShotGun_Multi = true,
    Battle_RangeWeapon_SubmachineGun = true,
    BeamLauncher = true,
    BeamLauncherBullet = true,
    BeamSword = true,
    BronzeSword = true,
    ChargeLaserRifle = true,
    ChargeLaserRifleBullet = true,
    DecalGunSet = true,
    DroneLauncher = true,
    ElecBaton = true,
    ElectricArcAssaultRifle = true,
    ElectricArcAssaultRifleBullet = true,
    EnergyLauncherBullet = true,
    EnergyRocketLauncher = true,
    EnergyShotgun = true,
    EnergyShotgunBullet = true,
    FlamethrowerBullet = true,
    FragGrenade = true,
    FragGrenade_Dark = true,
    FragGrenade_Dragon = true,
    FragGrenade_Elec = true,
    FragGrenade_Fire = true,
    FragGrenade_Ground = true,
    FragGrenade_Ice = true,
    FragGrenade_Leaf = true,
    FragGrenade_Super = true,
    FragGrenade_Water = true,
    GatlingBullet = true,
    GrenadeBullet = true,
    HandgunBullet = true,
    LaserBullet = true,
    LaserGatlingBullet = true,
    LaserGatlingGun = true,
    LauncherBullet = true,
    Launcher_Meteor = true,
    MakeshiftAssaultRifle = true,
    MakeshiftHandgun = true,
    MakeshiftShotgun = true,
    MakeshiftSubmachineGun = true,
    MissileBullet = true,
    Musket = true,
    OverheatRifle = true,
    OverheatRifleBullet = true,
    Katana = true,
    Spear = true,
    Spear_2 = true,
    Spear_3 = true,
    Spear_ForestBoss = true,
    Spear_ForestBoss2 = true,
    PalDopingShot = true,
    PalDopingShotBullet = true,
    PalDopingShot_2 = true,
    ReinforcedArrow = true,
    RifleBullet = true,
    RoughBullet = true,
    SFArrow = true,
    SFBow = true,
    ShotGunBullet = true,
    SkyAssaultRifle = true,
    SkyAssaultRifleBullet = true,
    SkyBeamSword = true,
    SkyBow = true,
    SkyBowArrow = true,
    SkyGrenadeLauncher = true,
    SkyGrenadeLauncherBullet = true,
    SkyShotgun = true,
    SkyShotgunBullet = true,
    SkySubmachineGun = true,
    SkySubmachineGunBullet = true,
    UnlockEquipmentSlot_Weapon_01 = true,
    UnlockEquipmentSlot_Weapon_02 = true,
    WidePenetrateShotgun = true,
    WidePenetrateShotgunBullet = true,
}

local function log(msg)
    print(string.format("%s %s", MOD, msg))
end

local function debug(msg)
    if Config.Debug then
        log(msg)
    end
end

local function fnameToString(name)
    if name == nil then
        return ""
    end
    if type(name) == "string" then
        return name
    end
    local ok, s = pcall(function()
        if name.get ~= nil then
            local inner = name:get()
            if type(inner) == "string" then
                return inner
            end
            if inner ~= nil and inner.ToString ~= nil then
                return inner:ToString()
            end
            return tostring(inner)
        end
        if name.ToString ~= nil then
            return name:ToString()
        end
        return tostring(name)
    end)
    if ok and s ~= nil then
        local out = tostring(s)
        -- Strip common FName noise like "FName OverheatRifle" if present
        local bare = out:match("([^%s]+)$")
        if bare ~= nil and bare ~= "" then
            return bare
        end
        return out
    end
    return tostring(name)
end

local function isBlockedExact(name)
    if BLOCK_TECH_EXACT[name] then
        return true
    end
    local lower = string.lower(name)
    for id, _ in pairs(BLOCK_TECH_EXACT) do
        if string.lower(id) == lower then
            return true
        end
    end
    return false
end

local function isHealingGrenade(name)
    local lower = string.lower(fnameToString(name))
    if lower == "" then
        return false
    end
    -- Official tech/item id: PalHealingGrenade ("Pal Recovery Grenade")
    return string.find(lower, "palhealinggrenade", 1, true) ~= nil
        or string.find(lower, "healinggrenade", 1, true) ~= nil
        or string.find(lower, "recoverygrenade", 1, true) ~= nil
end

--- Throwable combat grenades (not launchers / ammo / healing).
local function isCombatGrenadeItem(staticId)
    local id = fnameToString(staticId)
    if id == "" then
        return false
    end
    if isHealingGrenade(id) then
        return false
    end
    local lower = string.lower(id)
    if string.find(lower, "fraggrenade", 1, true) then
        return true
    end
    -- Generic "grenade" throwables — exclude launchers, ammo, schematics handled elsewhere
    if string.find(lower, "grenade", 1, true)
        and string.find(lower, "launcher", 1, true) == nil
        and string.find(lower, "bullet", 1, true) == nil
        and string.find(lower, "schematic", 1, true) == nil
    then
        return true
    end
    return false
end

local function isAllowedKeep(name)
    local lower = string.lower(name)

    -- Healing grenade is the one throwable combat-adjacent item we keep
    if isHealingGrenade(name) then
        return true
    end

    -- Tools
    if string.find(lower, "axe", 1, true) and string.find(lower, "pickaxe", 1, true) == nil then
        -- "Battle_MeleeWeapon_Axe_*" / Product_Axe — keep; block Bat-like false positives via exact list
        if string.find(lower, "meleeweapon_axe", 1, true) or string.find(lower, "product_axe", 1, true) then
            return true
        end
    end
    if string.find(lower, "pickaxe", 1, true) then
        return true
    end

    -- Spheres / sphere launchers
    if string.find(lower, "sphere", 1, true) then
        return true
    end

    -- Armor / glider / cloth
    if string.find(lower, "armor", 1, true)
        or string.find(lower, "helm", 1, true)
        or string.find(lower, "cloth", 1, true)
        or string.find(lower, "glider", 1, true)
    then
        return true
    end

    -- Utility / non-player-weapon systems
    if string.find(lower, "grappling", 1, true) then
        return true
    end
    if string.find(lower, "skillunlock_", 1, true) then
        return true
    end
    if string.find(lower, "battle_defense", 1, true) then
        return true
    end
    if string.find(lower, "furniture", 1, true) then
        return true
    end
    if string.find(lower, "product_", 1, true) then
        return true
    end

    return false
end

local function shouldRemoveTech(name)
    name = fnameToString(name)
    if name == "" then
        return false
    end
    if isAllowedKeep(name) then
        return false
    end
    if isBlockedExact(name) then
        return true
    end
    if isCombatGrenadeItem(name) then
        return true
    end

    local lower = string.lower(name)
    if string.find(lower, "battle_rangeweapon_", 1, true) then
        return true
    end
    if string.find(lower, "makeshift", 1, true) then
        return true
    end
    if string.find(lower, "schematic", 1, true) then
        return true
    end
    if string.find(lower, "bullet", 1, true) or string.find(lower, "ammo", 1, true) then
        return true
    end
    -- Melee combat (axes/pickaxes already allowed)
    if string.find(lower, "battle_meleeweapon_", 1, true) then
        return true
    end
    -- Short IDs that don't use Battle_* prefixes
    if string.find(lower, "spear", 1, true) then
        return true
    end
    if string.find(lower, "katana", 1, true) then
        return true
    end
    if string.find(lower, "overheat", 1, true) then
        return true
    end
    if string.find(lower, "sword", 1, true) then
        return true
    end
    if string.find(lower, "baton", 1, true) then
        return true
    end

    return false
end

-- Weapon schematic loot item IDs (e.g. Handgun_Schematic_1). Armor/hats stay.
local WEAPON_SCHEMATIC_MARKERS = {
    "handgun", "assault", "rifle", "shotgun", "bow", "crossbow", "rocket",
    "launcher", "musket", "smg", "makeshift", "flamethrower", "gatling",
    "grenade", "missile", "laser", "katana", "spear", "sword", "revolver",
    "compound", "beam", "baton", "oldbow", "old_bow", "pump", "metalbat",
    "metal_bat", "energy", "overheat", "semiauto", "semi_auto", "singleshot",
    "single_shot", "guided", "melee", "weapon",
}

local function isCosmeticOrArmorSchematic(lower)
    return string.find(lower, "armor", 1, true) ~= nil
        or string.find(lower, "helm", 1, true) ~= nil
        or string.find(lower, "cloth", 1, true) ~= nil
        or string.find(lower, "outfit", 1, true) ~= nil
        or string.find(lower, "hat", 1, true) ~= nil
        or string.find(lower, "cap", 1, true) ~= nil
        or string.find(lower, "crown", 1, true) ~= nil
        or string.find(lower, "headband", 1, true) ~= nil
        or string.find(lower, "hairband", 1, true) ~= nil
        or string.find(lower, "pelt", 1, true) ~= nil
        or string.find(lower, "glider", 1, true) ~= nil
        or string.find(lower, "shield", 1, true) ~= nil
        or string.find(lower, "boots", 1, true) ~= nil
end

local function isWeaponSchematicItem(staticId)
    local id = fnameToString(staticId)
    if id == "" then
        return false
    end
    local lower = string.lower(id)
    if string.find(lower, "schematic", 1, true) == nil
        and string.find(lower, "blueprint", 1, true) == nil
    then
        return false
    end
    if isCosmeticOrArmorSchematic(lower) then
        return false
    end
    for _, marker in ipairs(WEAPON_SCHEMATIC_MARKERS) do
        if string.find(lower, marker, 1, true) then
            return true
        end
    end
    return false
end

local function shouldRemoveItemRecipe(rowName, productId, unlockItemId)
    local name = fnameToString(rowName)
    local product = fnameToString(productId)
    local unlock = fnameToString(unlockItemId)

    if isAllowedKeep(name) or isAllowedKeep(product) then
        return false
    end
    if isCombatGrenadeItem(name) or isCombatGrenadeItem(product) or isCombatGrenadeItem(unlock) then
        return true
    end
    if shouldRemoveTech(name) or shouldRemoveTech(product) then
        return true
    end
    if isWeaponSchematicItem(unlock) or isWeaponSchematicItem(product) or isWeaponSchematicItem(name) then
        return true
    end
    if string.find(string.lower(unlock), "schematic", 1, true) then
        if isAllowedKeep(unlock) or isAllowedKeep(product) then
            return false
        end
        return true
    end
    if string.find(string.lower(product), "schematic", 1, true)
        and not isAllowedKeep(product)
    then
        return true
    end
    return false
end

local function shouldStripLootItem(staticId, nameStr)
    return isWeaponSchematicItem(staticId)
        or isWeaponSchematicItem(nameStr)
        or isCombatGrenadeItem(staticId)
        or isCombatGrenadeItem(nameStr)
end

local function getMasterDataTables()
    local ok, mdt = pcall(function()
        return FindFirstOf("PalMasterDataTables")
    end)
    if ok and mdt ~= nil and mdt:IsValid() then
        return mdt
    end
    return nil
end

local function getRecipeUnlockDataTable()
    local mdt = getMasterDataTables()
    if mdt ~= nil then
        local ok, dt = pcall(function()
            return mdt.technologyDataSet.recipeUnlockDataTable
        end)
        if ok and dt ~= nil and dt:IsValid() then
            return dt
        end
    end

    -- Common StaticFindObject fallbacks (paths vary by build)
    local paths = {
        "/Game/Pal/DataTable/Technology/DT_Tech_RecipeUnlock.DT_Tech_RecipeUnlock",
        "/Game/Pal/DataTable/Technology/DT_TechnologyRecipeUnlock.DT_TechnologyRecipeUnlock",
        "/Game/Pal/DataTable/DT_TechnologyRecipeUnlock.DT_TechnologyRecipeUnlock",
    }
    for _, path in ipairs(paths) do
        local ok, dt = pcall(function()
            return StaticFindObject(path)
        end)
        if ok and dt ~= nil and dt:IsValid() then
            return dt
        end
    end
    return nil
end

local function getItemRecipeDataTable()
    local ok, util = pcall(function()
        return StaticFindObject("/Script/Pal.Default__PalMasterDataTablesUtility")
    end)
    if ok and util ~= nil then
        local ok2, dt = pcall(function()
            return util:GetItemRecipeDataTable(nil)
        end)
        if ok2 and dt ~= nil and dt:IsValid() then
            return dt
        end
    end

    local mdt = getMasterDataTables()
    if mdt ~= nil then
        local ok3, dt = pcall(function()
            return mdt.ItemRecipeDataTable
        end)
        if ok3 and dt ~= nil and dt:IsValid() then
            return dt
        end
    end

    local paths = {
        "/Game/Pal/DataTable/Item/DT_ItemRecipe.DT_ItemRecipe",
        "/Game/Pal/DataTable/DT_ItemRecipe.DT_ItemRecipe",
    }
    for _, path in ipairs(paths) do
        local ok4, dt = pcall(function()
            return StaticFindObject(path)
        end)
        if ok4 and dt ~= nil and dt:IsValid() then
            return dt
        end
    end
    return nil
end

local function stripDataTableRows(dt, predicate, label)
    if dt == nil or not dt:IsValid() then
        return 0
    end

    local removed = 0
    local names = nil
    local okNames, result = pcall(function()
        return dt:GetRowNames()
    end)
    if okNames then
        names = result
    end

    if type(names) ~= "table" then
        log(label .. ": GetRowNames failed")
        return 0
    end

    -- Collect first, then remove (don't mutate while iterating GetRowNames)
    local toRemove = {}
    for _, rowName in ipairs(names) do
        local nameStr = fnameToString(rowName)
        local productId = nil
        local unlockItemId = nil
        pcall(function()
            local row = dt:FindRow(nameStr)
            if row ~= nil then
                productId = row.Product_Id
                unlockItemId = row.UnlockItemID
            end
        end)
        if predicate(nameStr, productId, unlockItemId) then
            table.insert(toRemove, nameStr)
        end
    end

    for _, nameStr in ipairs(toRemove) do
        local ok = pcall(function()
            dt:RemoveRow(nameStr)
        end)
        if ok then
            removed = removed + 1
            debug("removed " .. label .. " row: " .. nameStr)
        end
    end

    return removed
end

local function stripUnlockedTechnologyNames()
    local ok, ps = pcall(function()
        return FindFirstOf("PalPlayerState")
    end)
    if not ok or ps == nil or not ps:IsValid() then
        return 0
    end

    local tech = nil
    pcall(function()
        tech = ps:GetTechnologyData()
    end)
    if tech == nil or not tech:IsValid() then
        return 0
    end

    -- Try common property names for the unlocked list
    local stripped = 0
    local propNames = {
        "UnlockedRecipeTechnologyNames",
        "unlockedRecipeTechnologyNames",
        "UnlockedTechnologyNames",
    }

    for _, prop in ipairs(propNames) do
        local okArr, arr = pcall(function()
            return tech[prop]
        end)
        if okArr and arr ~= nil then
            local okLen, len = pcall(function()
                return #arr
            end)
            if okLen and type(len) == "number" and len > 0 then
                -- Rebuild by filtering (TArray mutation APIs vary)
                local keep = {}
                for i = 1, len do
                    local n = fnameToString(arr[i])
                    if not shouldRemoveTech(n) then
                        table.insert(keep, arr[i])
                    else
                        stripped = stripped + 1
                        debug("strip unlocked tech: " .. n)
                    end
                end
                -- Best-effort clear + re-add is unreliable; empty then hope UI refreshes
                pcall(function()
                    while #arr > 0 do
                        arr:Remove(1)
                    end
                end)
                for _, v in ipairs(keep) do
                    pcall(function()
                        arr:Add(v)
                    end)
                end
                if stripped > 0 then
                    log("stripped " .. tostring(stripped) .. " unlocked weapon techs from player state")
                end
                return stripped
            end
        end
    end
    return 0
end

local function getItemLotteryDataTable()
    local mdt = getMasterDataTables()
    if mdt ~= nil then
        local ok, dt = pcall(function()
            return mdt.ItemLotteryDataTable
        end)
        if ok and dt ~= nil and dt:IsValid() then
            return dt
        end
    end
    return nil
end

local function getDungeonItemLotteryDataTable()
    local mdt = getMasterDataTables()
    if mdt ~= nil then
        local ok, dt = pcall(function()
            return mdt.DungeonItemLotteryDataTable
        end)
        if ok and dt ~= nil and dt:IsValid() then
            return dt
        end
    end
    return nil
end

local function getDropItemDataTable()
    -- Often owned by PalDatabase / GameSetting systems
    local candidates = {
        function()
            local mdt = getMasterDataTables()
            if mdt ~= nil then
                return mdt.DropItemDataTable
            end
            return nil
        end,
        function()
            return StaticFindObject("/Game/Pal/DataTable/Character/DT_DropItem.DT_DropItem")
        end,
        function()
            return StaticFindObject("/Game/Pal/DataTable/DT_DropItem.DT_DropItem")
        end,
        function()
            return FindFirstOf("PalDropItemDatabase") -- may not exist
        end,
    }
    for _, getter in ipairs(candidates) do
        local ok, dt = pcall(getter)
        if ok and dt ~= nil and dt:IsValid() and dt.GetRowNames ~= nil then
            return dt
        end
    end
    return nil
end

local function rowStaticItemId(dt, rowName)
    local id = nil
    pcall(function()
        local row = dt:FindRow(rowName)
        if row == nil then
            return
        end
        if row.StaticItemId ~= nil then
            id = row.StaticItemId
            return
        end
        -- Some lottery rows nest the id
        if row.ItemId ~= nil then
            id = row.ItemId
        end
    end)
    return fnameToString(id)
end

local function stripLotteryTable(dt, label)
    if dt == nil or not dt:IsValid() then
        return 0
    end
    local okNames, names = pcall(function()
        return dt:GetRowNames()
    end)
    if not okNames or type(names) ~= "table" then
        return 0
    end

    local toRemove = {}
    for _, rowName in ipairs(names) do
        local nameStr = fnameToString(rowName)
        local staticId = rowStaticItemId(dt, nameStr)
        if shouldStripLootItem(staticId, nameStr) then
            table.insert(toRemove, nameStr)
        end
    end

    local removed = 0
    for _, nameStr in ipairs(toRemove) do
        local ok = pcall(function()
            dt:RemoveRow(nameStr)
        end)
        if ok then
            removed = removed + 1
            debug("removed " .. label .. " loot row: " .. nameStr)
        end
    end
    return removed
end

local function clearDropSlotIfBlocked(row, idField, rateField, minField, maxField)
    local changed = false
    pcall(function()
        local id = fnameToString(row[idField])
        if not shouldStripLootItem(id, id) then
            return
        end
        pcall(function()
            row[idField] = FName("None")
        end)
        if rateField ~= nil then
            row[rateField] = 0
        end
        if minField ~= nil then
            row[minField] = 0
        end
        if maxField ~= nil then
            row[maxField] = 0
        end
        changed = true
    end)
    return changed
end

local function stripDropItemDatabase(dt)
    if dt == nil or not dt:IsValid() then
        return 0
    end
    local okNames, names = pcall(function()
        return dt:GetRowNames()
    end)
    if not okNames or type(names) ~= "table" then
        return 0
    end

    local cleared = 0
    for _, rowName in ipairs(names) do
        local nameStr = fnameToString(rowName)
        pcall(function()
            local row = dt:FindRow(nameStr)
            if row == nil then
                return
            end
            for i = 1, 5 do
                if clearDropSlotIfBlocked(
                    row,
                    "ItemId" .. tostring(i),
                    "Rate" .. tostring(i),
                    "min" .. tostring(i),
                    "Max" .. tostring(i)
                ) then
                    cleared = cleared + 1
                    debug("cleared blocked drop slot on " .. nameStr .. " #" .. tostring(i))
                end
            end
        end)
    end
    return cleared
end

local function stripWeaponSchematicLoot()
    if Schematics.lootApplied then
        return true
    end

    local lottery = getItemLotteryDataTable()
    local dungeon = getDungeonItemLotteryDataTable()
    local drops = getDropItemDataTable()

    if lottery == nil and dungeon == nil and drops == nil then
        return false
    end

    local lotteryRemoved = stripLotteryTable(lottery, "item-lottery")
    local dungeonRemoved = stripLotteryTable(dungeon, "dungeon-lottery")
    local dropCleared = stripDropItemDatabase(drops)

    Schematics.lootApplied = true
    log(string.format(
        "weapon/grenade loot stripped: itemLottery=%d dungeonLottery=%d dropSlots=%d",
        lotteryRemoved,
        dungeonRemoved,
        dropCleared
    ))
    return true
end

local function applyOnce()
    if Schematics.applied and Schematics.lootApplied then
        return true
    end

    local techDt = getRecipeUnlockDataTable()
    local itemDt = getItemRecipeDataTable()

    if not Schematics.applied then
        if techDt == nil and itemDt == nil then
            -- Still try loot; master data may be partially ready
        else
            local techRemoved = 0
            if techDt ~= nil then
                techRemoved = stripDataTableRows(techDt, function(name)
                    return shouldRemoveTech(name)
                end, "tech")
            else
                log("WARNING: recipeUnlockDataTable not found yet")
            end

            local itemRemoved = 0
            if itemDt ~= nil then
                itemRemoved = stripDataTableRows(itemDt, function(name, productId, unlockItemId)
                    return shouldRemoveItemRecipe(name, productId, unlockItemId)
                end, "item-recipe")
            else
                debug("ItemRecipe data table not found (optional)")
            end

            local unlockedStripped = stripUnlockedTechnologyNames()
            Schematics.applied = true
            log(string.format(
                "weapon/grenade tech stripped: techRows=%d itemRecipes=%d unlocked=%d",
                techRemoved,
                itemRemoved,
                unlockedStripped
            ))
        end
    end

    pcall(stripWeaponSchematicLoot)

    return Schematics.applied or Schematics.lootApplied
end

function Schematics.Register()
    if not Config.Features or not Config.Features.HideWeaponSchematics then
        log("weapon schematic hide disabled (HideWeaponSchematics=false)")
        return
    end

    local function tryApply(reason)
        if not Session.IsAlive() then
            debug("schematic strip skipped — world suspended (" .. tostring(reason) .. ")")
            return false
        end
        Schematics.attempt = Schematics.attempt + 1
        debug("schematic strip attempt #" .. tostring(Schematics.attempt) .. " (" .. tostring(reason) .. ")")
        local ok = false
        pcall(function()
            ok = applyOnce()
        end)
        return ok
    end

    tryApply("mod-load")
    Session.Defer(2000, function()
        if not Schematics.applied or not Schematics.lootApplied then
            tryApply("delay-2s")
        end
    end)
    Session.Defer(8000, function()
        if not Schematics.applied or not Schematics.lootApplied then
            tryApply("delay-8s")
        else
            pcall(stripUnlockedTechnologyNames)
        end
    end)

    pcall(function()
        RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
            Schematics.applied = false
            Schematics.lootApplied = false
            -- Wait for main session resume — never Find* during teardown.
            Session.After(3000, function()
                if not Session.IsAlive() then
                    return
                end
                tryApply("ClientRestart+3s")
            end)
            Session.After(8000, function()
                if not Session.IsAlive() then
                    return
                end
                if not Schematics.applied or not Schematics.lootApplied then
                    tryApply("ClientRestart+8s")
                end
            end)
        end)
    end)

    log("weapon/grenade strip registered (tech + loot; PalHealingGrenade kept)")
end

return Schematics
