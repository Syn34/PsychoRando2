-- PsychoRando scanner: builds the location database by loading every level
-- package in-engine and recording each collectible actor.
-- Triggered by Mods/PsychoRando/scan_request.txt (created by the app).
-- Output (JSON lines, resumable):
--   Mods/PsychoRando/data/scan_items.jsonl   inventory item catalogue
--   Mods/PsychoRando/data/scan_locations.jsonl  one line per collectible actor
--   Mods/PsychoRando/data/scan_progress.txt  packages already attempted
--   Mods/PsychoRando/data/scan_done.txt       written when finished
local U = require("util")

local S = {}

local DATA = U.ROOT .. "data/"
local F_ITEMS = DATA .. "scan_items.jsonl"
local F_LOCS = DATA .. "scan_locations.jsonl"
local F_PROGRESS = DATA .. "scan_progress.txt"
local F_DONE = DATA .. "scan_done.txt"
local F_STATUS = DATA .. "scan_status.json"
local F_REQUEST = U.ROOT .. "scan_request.txt"

-- Sublevels that only hold art/lighting/audio; collectibles are never placed there.
local SKIP_PATTERNS = {
    "_ART$", "_ART_", "_LIT$", "_LIT_", "LIGHTING", "_VFX", "_AUDIO", "_FOG",
    "BUILTDATA", "_SOUND", "_ENV$", "_LOW_", "_HLOD", "_LOD", "_SKY",
}
local SKIP_FOLDERS = { "TEST", "GYM", "SANDBOX", "PROTO", "DEMO", "_DEV", "/DEV/", "DEBUG", "TEMPLATE", "EXAMPLE" }

-- Used only if the AssetRegistry can't be queried
local FALLBACK_PERSISTENT = {
    "LOBO/LOBO", "QUAR/QUAR", "QAEX/QAEX", "HQIN/HQIN", "HUB2/HUB2", "FORB/FORB", "FORC/FORC",
    "FORG/FORG", "FORH/FORH", "FORV/FORV", "CASS/CASS", "COMPT/COMPT", "HELM/HELM", "BOBZ/BOBZ",
    "GRIS/GRIS", "MALI/MALI", "BOSS_MALI/BOSS_MALI", "COLU/COLU", "HOLL/HOLL",
}

local function shouldScan(pkg, fullScan)
    if not pkg:find("^/Game/Maps/") then return false end
    local up = pkg:upper()
    for _, f in ipairs(SKIP_FOLDERS) do
        if up:find(f, 1, true) then return false end
    end
    if fullScan then return true end
    local leaf = up:match("([^/]+)$") or up
    for _, p in ipairs(SKIP_PATTERNS) do
        if leaf:find(p) then return false end
    end
    return true
end

local function writeStatus(t)
    U.writeAll(F_STATUS, U.json(t))
end

local function appendLine(path, s)
    local f = io.open(path, "a")
    if f then f:write(s .. "\n") f:close() end
end

local function getAssetRegistry()
    local reg = FindFirstOf("AssetRegistryImpl")
    if U.valid(reg) then return reg end
    local helpers = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    if U.valid(helpers) then
        local ok, r = pcall(function() return helpers:GetAssetRegistry() end)
        if ok and r then
            local ok2, inner = pcall(function() return r:get() end)
            if ok2 and inner then r = inner end
            if U.valid(r) then return r end
        end
    end
    return nil
end

-- Normalises an out-param array (Lua table or TArray) into a Lua list of FAssetData
local function assetList(out, field)
    local arr = out[field]
    local list = {}
    if arr == nil then return list end
    if type(arr) == "table" then
        for _, v in ipairs(arr) do list[#list + 1] = v end
    else
        U.eachArray(arr, function(_, v) list[#list + 1] = v end)
    end
    return list
end

local function assetDataFields(ad)
    local pkg = U.fname(U.get(ad, "PackageName"))
    local name = U.fname(U.get(ad, "AssetName"))
    local cls = U.fname(U.get(ad, "AssetClass"))
    return pkg, name, cls
end

local function listWorldPackages(reg)
    local out = {}
    local ok, err = pcall(function()
        reg:GetAssetsByClass(FName("World"), out, false)
    end)
    if not ok then U.log("GetAssetsByClass failed: %s", tostring(err)) return nil end
    local pkgs = {}
    for _, ad in ipairs(assetList(out, "OutAssetData")) do
        local pkg = assetDataFields(ad)
        if pkg then pkgs[#pkgs + 1] = pkg end
    end
    return pkgs
end

local function listInventoryAssets(reg)
    local out = {}
    local ok, err = pcall(function()
        reg:GetAssetsByPath(FName("/Game/Gameplay/Inventory"), out, true, false)
    end)
    if not ok then U.log("GetAssetsByPath failed: %s", tostring(err)) return {} end
    local list = {}
    for _, ad in ipairs(assetList(out, "OutAssetData")) do
        local pkg, name, cls = assetDataFields(ad)
        if pkg and name then list[#list + 1] = { pkg = pkg, name = name, cls = cls } end
    end
    return list
end

local function loadObject(objPath)
    local obj = StaticFindObject(objPath)
    if U.valid(obj) then return obj end
    local ok, res = pcall(function() return LoadAsset(objPath) end)
    if ok and U.valid(res) then return res end
    obj = StaticFindObject(objPath)
    if U.valid(obj) then return obj end
    return nil
end

local function textOf(v)
    if v == nil then return nil end
    local ok, s = pcall(function() return v:ToString() end)
    if ok then return s end
    return nil
end

-- Item catalogue: everything under /Game/Gameplay/Inventory that a collectible can grant
local INTERESTING_ITEMS = {
    "INV_VAULT_", "INV_BAGTAG_", "INV_SORTEDBAG_", "SCAVHUNTITEM_", "INV_MIND_",
    "INV_PSICHALLENGE", "INV_PSIMARKER", "INV_NUGGETOFWISDOM", "INV_SUPPLYCHESTKEY",
    "INV_PLAYERXP", "INV_UPGRADEPOINT", "INV_UNIQUE_", "INV_PSIMONEY",
}
local function interestingItem(name)
    local up = name:upper()
    if up:find("_BASE$") then return false end
    for _, p in ipairs(INTERESTING_ITEMS) do
        if up:find(p, 1, true) then return true end
    end
    return false
end

local function catalogueItem(objPath)
    local obj = loadObject(objPath)
    local rec = { path = objPath }
    if obj then
        local full = U.fullName(obj) or ""
        rec.class = full:match("^(%S+)")
        rec.name = textOf(U.get(obj, "m_ItemName"))
        local okM, m = pcall(function() return obj:GetMaxAmount() end)
        if okM then rec.max = m end
    else
        rec.missing = true
    end
    appendLine(F_ITEMS, U.json(rec))
end

-- Generic: object properties on an actor that point into the inventory folder
local function inventoryRefs(obj)
    local refs = {}
    local okC, cls = pcall(function() return obj:GetClass() end)
    if not okC or not cls then return refs end
    local guard = 0
    while U.valid(cls) and guard < 12 do
        guard = guard + 1
        local cname = U.fullName(cls) or ""
        if cname:find("/Script/") then break end -- stop at native classes
        pcall(function()
            cls:ForEachProperty(function(prop)
                local okT, ptype = pcall(function() return prop:GetClass():GetFName():ToString() end)
                if okT and (ptype == "ObjectProperty" or ptype == "ClassProperty") then
                    local pname = prop:GetFName():ToString()
                    local v = U.get(obj, pname)
                    if v and U.valid(v) then
                        local p = U.objPath(v)
                        if p and (p:find("/Gameplay/Inventory/") or p:find("/Pickups/")) then
                            refs[#refs + 1] = { pname, p }
                        end
                    end
                end
            end)
        end)
        local okS, sup = pcall(function() return cls:GetSuperStruct() end)
        if not okS then break end
        cls = sup
    end
    return refs
end

local function grantedItems(pickupable)
    local items = {}
    if not U.valid(pickupable) then return items end
    U.eachArray(U.get(pickupable, "m_aPickupGrantedItems"), function(_, el)
        local it = U.get(el, "m_pItemToGrant")
        local n = U.get(el, "m_iAmountToGrant")
        local p = (it and U.valid(it)) and U.objPath(it) or nil
        items[#items + 1] = { p or "None", n or 0 }
    end)
    return items
end

local function vecOf(actor)
    local root = U.get(actor, "RootComponent")
    if not U.valid(root) then return nil end
    local l = U.get(root, "RelativeLocation")
    if not l then return nil end
    local x, y, z = U.get(l, "X"), U.get(l, "Y"), U.get(l, "Z")
    if x then return { x, y, z } end
    return nil
end

-- Indexes components of a given class by their owning actor's full name, for one package
local function componentsByOwner(className, pkg)
    local map = {}
    local all = FindAllOf(className)
    if not all then return map end
    for _, c in ipairs(all) do
        local full = U.fullName(c)
        if full and full:find(pkg .. ".", 1, true) and full:find(":PersistentLevel.", 1, true) then
            local okO, owner = pcall(function() return c:GetOuter() end)
            if okO and U.valid(owner) then
                local of = U.fullName(owner)
                if of and not map[of] then map[of] = c end
            end
        end
    end
    return map
end

local function scanPackage(pkg)
    local leaf = pkg:match("([^/]+)$")
    local world = loadObject(pkg .. "." .. leaf)
    if not world then
        U.log("  could not load %s", pkg)
        return 0, "load_failed"
    end
    local collectables = FindAllOf("CoCollectable") or {}
    local pickupables = componentsByOwner("CoPickupable", pkg)
    local pickupables2 = componentsByOwner("COMP_Pickupable_C", pkg)
    local droppers = componentsByOwner("CoLootDropper", pkg)
    local count = 0
    for _, c in ipairs(collectables) do
        local full = U.fullName(c)
        if full and full:find(pkg .. ".", 1, true) and full:find(":PersistentLevel.", 1, true) then
            local okO, actor = pcall(function() return c:GetOuter() end)
            if okO and U.valid(actor) then
                local afull = U.fullName(actor)
                local _, aname = U.splitActorPath(afull)
                local rec = {
                    pkg = pkg,
                    actor = aname or "?",
                    class = afull and afull:match("^(%S+)") or "?",
                    type = U.get(c, "m_eCollectableType"),
                    id = U.fname(U.get(c, "m_CollectableUniqueID")),
                    comp = (full:match("%.([^%.]+)$")),
                }
                local pk = pickupables[afull] or pickupables2[afull]
                if pk then rec.grants = grantedItems(pk) end
                local ld = droppers[afull]
                if ld then
                    rec.loot = true
                    rec.lootIndex = U.get(ld, "m_iLootTableIndex")
                end
                rec.refs = inventoryRefs(actor)
                rec.loc = vecOf(actor)
                appendLine(F_LOCS, U.json(rec))
                count = count + 1
            end
        end
    end
    return count, nil
end

local function readProgress()
    local done = {}
    local s = U.readAll(F_PROGRESS)
    if s then
        for line in s:gmatch("[^\r\n]+") do
            local pkg = line:match("^%S+%s+(.+)$") or line
            done[pkg] = true
        end
    end
    return done
end

function S.requested()
    return U.exists(F_REQUEST)
end

function S.run()
    local fullScan = (U.readAll(F_REQUEST) or ""):find("full") ~= nil
    U.log("Scan requested (full=%s). Waiting for the main menu...", tostring(fullScan))
    writeStatus({ state = "waiting" })

    local state = "wait"
    local waitTicks = 0
    local queue, qi = {}, 1
    local stats = { packages = 0, locations = 0, failed = 0 }
    local busy = false
    local startedAt = os.time()

    local function step()
        if state == "wait" then
            local pc = FindFirstOf("PlayerController")
            if U.valid(pc) then waitTicks = waitTicks + 1 end
            if waitTicks >= 12 then state = "discover" end
            return
        end

        if state == "discover" then
            local reg = getAssetRegistry()
            local pkgs = reg and listWorldPackages(reg) or nil
            if not pkgs or #pkgs == 0 then
                U.log("AssetRegistry unavailable; using fallback persistent map list")
                pkgs = {}
                for _, p in ipairs(FALLBACK_PERSISTENT) do pkgs[#pkgs + 1] = "/Game/Maps/" .. p end
                stats.fallback = true
            end
            table.sort(pkgs)
            local done = readProgress()
            local seen = {}
            for _, p in ipairs(pkgs) do
                if not seen[p] and shouldScan(p, fullScan) and not done[p] then
                    queue[#queue + 1] = p
                end
                seen[p] = true
            end
            U.log("World packages found: %d, queued this run: %d (already done: %d)",
                #pkgs, #queue, (function() local n = 0 for _ in pairs(done) do n = n + 1 end return n end)())
            appendLine(DATA .. "scan_worlds.txt", table.concat(pkgs, "\n"))

            if not U.exists(F_ITEMS) and reg then
                local inv = listInventoryAssets(reg)
                local n = 0
                for _, a in ipairs(inv) do
                    if interestingItem(a.name) then
                        catalogueItem(a.pkg .. "." .. a.name)
                        n = n + 1
                    end
                end
                U.log("Catalogued %d inventory items", n)
            end
            stats.total = #queue
            state = "scan"
            return
        end

        if state == "scan" then
            if qi > #queue then
                state = "finish"
                return
            end
            local pkg = queue[qi]
            qi = qi + 1
            -- Mark as attempted BEFORE loading so a crash on this package skips it next time
            appendLine(F_PROGRESS, "try " .. pkg)
            writeStatus({ state = "scanning", index = qi - 1, total = #queue, current = pkg,
                locations = stats.locations, elapsed = os.time() - startedAt })
            local ok, n, err = pcall(scanPackage, pkg)
            if not ok then
                U.log("  ERROR scanning %s: %s", pkg, tostring(n))
                stats.failed = stats.failed + 1
            elseif err then
                stats.failed = stats.failed + 1
            else
                stats.packages = stats.packages + 1
                stats.locations = stats.locations + n
                if n > 0 then U.log("  %s -> %d collectibles", pkg, n) end
            end
            if (qi % 8) == 0 then
                pcall(function()
                    StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):CollectGarbage()
                end)
            end
            return
        end

        if state == "finish" then
            stats.elapsed = os.time() - startedAt
            U.writeAll(F_DONE, U.json(stats))
            writeStatus({ state = "done", locations = stats.locations, packages = stats.packages,
                failed = stats.failed, elapsed = stats.elapsed })
            os.remove(F_REQUEST)
            U.log("SCAN COMPLETE: %d collectibles in %d packages (%d failed). You can close the game now.",
                stats.locations, stats.packages, stats.failed)
            state = "stopped"
        end
    end

    LoopAsync(250, function()
        if state == "stopped" then return true end
        if busy then return false end
        busy = true
        ExecuteInGameThread(function()
            local ok, err = pcall(step)
            if not ok then U.log("scan step error: %s", tostring(err)) end
            busy = false
        end)
        return false
    end)
end

return S
