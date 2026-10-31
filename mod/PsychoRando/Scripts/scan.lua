-- PsychoRando scanner: builds the location database by loading every level
-- package in-engine and recording each collectible actor.
-- Triggered by Mods/PsychoRando/scan_request.txt (created by the app).
-- Output (JSON lines, resumable):
--   Mods/PsychoRando/data/scan_items.jsonl   inventory item catalogue
--   Mods/PsychoRando/data/scan_locations.jsonl  one line per collectible actor
--   Mods/PsychoRando/data/scan_progress.txt  packages already attempted
--   Mods/PsychoRando/data/scan_done.txt       written when finished
local U = require("util")
local X = require("xform")

local S = {}

local SeenItems -- set below
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
    "GRIS/GRIS", "MALI/MALI", "BOSS_MALI/BOSS_MALI", "COLU/COLU",
    "HOLL/HOLL_CASINO/HOLL_CASINO", "HOLL/HOLL_CLASS/HOLL_CLASS", "HOLL/HOLL_REAL_A/HOLL_REAL_A",
    "HOLL/HOLL_REAL_B/HOLL_REAL_B",
}

-- Item paths that every collectible category uses (no AssetRegistry needed)
local KNOWN_ITEMS = {
    "/Game/Gameplay/Inventory/Upgrades/Minds/INV_Mind_HP.INV_Mind_HP",
    "/Game/Gameplay/Inventory/Experience/INV_PsiChallengeCard.INV_PsiChallengeCard",
    "/Game/Gameplay/Inventory/Experience/INV_PsiChallengeCore.INV_PsiChallengeCore",
    "/Game/Gameplay/Inventory/INV_PSIMarker.INV_PSIMarker",
    "/Game/Gameplay/Inventory/INV_NuggetOfWisdom.INV_NuggetOfWisdom",
    "/Game/Gameplay/Inventory/SupplyChest/INV_SupplyChestKey_Base.INV_SupplyChestKey_Base",
    "/Game/Gameplay/Inventory/INV_PlayerXP.INV_PlayerXP",
}
local VAULT_CODES = { "LOBO", "QUAR", "QAEX", "HQIN", "HUB2", "FORB", "FORC", "FORG", "FORH", "FORV", "FORD",
    "CASS", "COMPT", "COMP", "HELM", "BOBZ", "GRIS", "MALI", "COLU", "HOLL", "HOLL_CASINO", "HOLL_CLASS",
    "HOLL_REAL_A", "HOLL_REAL_B" }

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
    local refs = U.list()
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
    local items = U.list()
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
-- ---------------------------------------------------------------------------
-- Visual recipe: how a collectible is drawn, so the randomizer can show the
-- right model at the spot an item moves to.
local function relTransform(comp)
    local l, r, s = U.get(comp, "RelativeLocation"), U.get(comp, "RelativeRotation"), U.get(comp, "RelativeScale3D")
    local t = { loc = { 0, 0, 0 }, rot = { 0, 0, 0, 1 }, scale = { 1, 1, 1 } }
    if l then t.loc = { U.get(l, "X") or 0, U.get(l, "Y") or 0, U.get(l, "Z") or 0 } end
    if r then t.rot = X.quatFromRotator(U.get(r, "Pitch") or 0, U.get(r, "Yaw") or 0, U.get(r, "Roll") or 0) end
    if s then t.scale = { U.get(s, "X") or 1, U.get(s, "Y") or 1, U.get(s, "Z") or 1 } end
    return t
end

-- transform of a component relative to its actor (root excluded)
local function toActor(comp, root)
    local chain = {}
    local c, guard = comp, 0
    while U.valid(c) and guard < 16 do
        if root and U.fullName(c) == U.fullName(root) then break end
        chain[#chain + 1] = c
        c = U.get(c, "AttachParent")
        guard = guard + 1
    end
    local t = X.IDENTITY
    for i = #chain, 1, -1 do t = X.compose(t, relTransform(chain[i])) end
    return t
end

local function assetPath(v)
    if not v or not U.valid(v) then return nil end
    local p = U.objPath(v)
    if not p then return nil end
    if p:find("Transient", 1, true) or p:find("MaterialInstanceDynamic", 1, true) then
        local parent = U.get(v, "Parent")
        if parent and U.valid(parent) then return U.objPath(parent) end
        return nil
    end
    return p
end

local function materialsOf(comp)
    local mats = U.list()
    U.eachArray(U.get(comp, "OverrideMaterials"), function(i, m) mats[i] = assetPath(m) or "" end)
    return mats
end

local function round3(t)
    local function r(x) return math.floor(x * 1000 + 0.5) / 1000 end
    return { loc = { r(t.loc[1]), r(t.loc[2]), r(t.loc[3]) }, rot = { r(t.rot[1]), r(t.rot[2]), r(t.rot[3]), r(t.rot[4]) },
        scale = { r(t.scale[1]), r(t.scale[2]), r(t.scale[3]) } }
end

local FIGMENT_PARAMS = nil

local function visualRecipe(actor)
    local root = U.get(actor, "RootComponent")
    local comps, seen = {}, {}
    local function add(c)
        if not U.valid(c) then return end
        local f = U.fullName(c)
        if f and not seen[f] then seen[f] = true; comps[#comps + 1] = c end
    end
    U.eachArray(U.get(actor, "BlueprintCreatedComponents"), function(_, c) add(c) end)
    -- a few well-known component properties (e.g. a Character's "Mesh"); never walk
    -- every property: values on not-yet-started actors can be garbage
    for _, name in ipairs({ "Mesh", "CoFigment", "StaticMesh", "SkeletalMesh", "StaticMeshComponent",
        "SkeletalMeshComponent", "Visual", "Model" }) do
        local v = U.get(actor, name)
        if v and type(v) == "userdata" and U.valid(v) then
            local okO, o = pcall(function() return v:GetOuter() end)
            if okO and U.valid(o) and U.fullName(o) == U.fullName(actor) then add(v) end
        end
    end
    local vis = U.list()
    for _, c in ipairs(comps) do
        local cls = (U.fullName(c) or ""):match("^(%S+)") or ""
        local visible = U.get(c, "bVisible")
        local hidden = U.get(c, "bHiddenInGame")
        if visible ~= false and hidden ~= true then
            local rec
            if cls == "CoFigment" then
                local fv = U.get(c, "m_FigmentVisuals")
                rec = { kind = "figment", mesh = assetPath(U.get(c, "StaticMesh")), mats = materialsOf(c) }
                if fv then
                    rec.fmat = assetPath(U.get(fv, "m_pMaterialInstance"))
                    rec.ftex = assetPath(U.get(fv, "m_pFigmentTexture"))
                    rec.fpal = assetPath(U.get(fv, "m_PaletteTexture"))
                    rec.fcol = U.get(fv, "m_iPaletteColor")
                    rec.fcustom = U.get(fv, "m_bUseCustomColor")
                    local cc = U.get(fv, "m_CustomColor")
                    if cc then rec.fcc = { U.get(cc, "R") or 0, U.get(cc, "G") or 0, U.get(cc, "B") or 0, U.get(cc, "A") or 1 } end
                end
                if not FIGMENT_PARAMS then
                    local pd = U.get(c, "m_FigmentMaterialParams")
                    if pd and U.valid(pd) then
                        FIGMENT_PARAMS = {}
                        for _, k in ipairs({ "FigmentTextureParamName", "PaletteTextureParamName", "PaletteColorParamName",
                            "CustomColorParamName", "UseCustomColorParamName", "FigmentOpacityParamName" }) do
                            FIGMENT_PARAMS[k] = U.fname(U.get(pd, k))
                        end
                        U.writeAll(DATA .. "figment_params.json", U.json(FIGMENT_PARAMS))
                    end
                end
            elseif cls:find("StaticMeshComponent$") or cls == "StaticMeshComponent" then
                local m = assetPath(U.get(c, "StaticMesh"))
                if m then rec = { kind = "static", mesh = m, mats = materialsOf(c) } end
            elseif cls:find("SkeletalMeshComponent$") or cls == "SkeletalMeshComponent" then
                local m = assetPath(U.get(c, "SkeletalMesh"))
                if m then
                    rec = { kind = "skeletal", mesh = m, mats = materialsOf(c) }
                    local ac = U.get(c, "AnimClass")
                    if ac and U.valid(ac) then rec.anim = U.objPath(ac) end
                end
            elseif cls:find("ParticleSystemComponent$") then
                local tpl = assetPath(U.get(c, "Template"))
                if tpl and U.get(c, "bAutoActivate") ~= false then rec = { kind = "particle", tpl = tpl } end
            end
            if rec then
                rec.xf = round3(toActor(c, root))
                vis[#vis + 1] = rec
            end
        end
    end
    return vis
end

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

local function expandStreaming(world, expand)
    local levels = U.get(world, "StreamingLevels")
    local n = 0
    U.eachArray(levels, function(_, ls)
        if U.valid(ls) then
            local ok, fn = pcall(function() return ls:GetWorldAssetPackageFName() end)
            local name = ok and U.fname(fn) or nil
            if (not name or name == "None") then name = U.fname(U.get(ls, "PackageNameToLoad")) end
            if name and name ~= "None" and name:find("^/Game/Maps/") then
                expand(name)
                n = n + 1
            end
        end
    end)
    return n
end

local function scanPackage(pkg, expand, safe)
    local leaf = pkg:match("([^/]+)$")
    local world = loadObject(pkg .. "." .. leaf)
    if not world then
        U.log("  could not load %s", pkg)
        return 0, "load_failed"
    end
    local okE, nsub = pcall(expandStreaming, world, expand)
    if okE and nsub > 0 then U.log("     %d sublevels", nsub) end
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
                if not safe then
                    local okV, vis = pcall(visualRecipe, actor)
                    if okV then rec.vis = vis else U.log("    visuals failed for %s: %s", rec.actor, tostring(vis)) end
                end
                for _, g in ipairs(rec.grants or {}) do if g[1] ~= "None" then SeenItems[g[1]] = true end end
                for _, r in ipairs(rec.refs) do if r[2]:find("/Inventory/") then SeenItems[r[2]] = true end end
                appendLine(F_LOCS, U.json(rec))
                count = count + 1
            end
        end
    end
    if safe then return count, nil end
    -- Pickups WITHOUT a CoCollectable component (scavenger hunt
    -- items, some keys) are recorded too, keyed by package|actor.
    local withColl = {}
    for _, c in ipairs(collectables) do
        local okO, a = pcall(function() return c:GetOuter() end)
        if okO and U.valid(a) then withColl[U.fullName(a) or ""] = true end
    end
    local function extra(actorFull, actor, grants, refs)
        local cat
        local function scanList(list, idx)
            for _, g in ipairs(list) do
                local p = g[idx] or ""
                if p:find("/ScavengerHunt/") then cat = "scavenger" end
                if not cat and p:find("INV_SupplyChestKey") then cat = "supplykey" end
            end
        end
        scanList(grants or {}, 1)
        scanList(refs or {}, 2)
        if not cat then return end
        local _, aname = U.splitActorPath(actorFull)
        local rec = { pkg = pkg, actor = aname or "?", class = actorFull:match("^(%S+)") or "?",
            cat = cat, id = "None", grants = grants or U.list(), refs = refs or U.list(), loc = vecOf(actor), noCollectable = true }
        local okV, vis = pcall(visualRecipe, actor)
        if okV then rec.vis = vis end
        for _, g in ipairs(rec.grants) do if g[1] ~= "None" then SeenItems[g[1]] = true end end
        for _, r in ipairs(rec.refs) do if r[2]:find("/Inventory/") then SeenItems[r[2]] = true end end
        appendLine(F_LOCS, U.json(rec))
        count = count + 1
    end
    local done = {}
    for _, map in ipairs({ pickupables, pickupables2 }) do
        for owner, pk in pairs(map) do
            if not withColl[owner] and not done[owner] then
                done[owner] = true
                local okA, actor = pcall(function() return pk:GetOuter() end)
                if okA and U.valid(actor) then extra(owner, actor, grantedItems(pk), inventoryRefs(actor)) end
            end
        end
    end
    return count, nil
end

SeenItems = {}

local function exists(path)
    if U.valid(StaticFindObject(path)) then return true end
    local ok, res = pcall(function() return LoadAsset(path) end)
    if ok and U.valid(res) then return true end
    return U.valid(StaticFindObject(path))
end

-- Builds the item catalogue from known paths, items seen during the scan and
-- probing for numbered vaults / sorted bags. Includes items from a previous
-- (resumed) run's locations file.
local function catalogueAll()
    local paths, order = {}, {}
    local function add(p) if p and not paths[p] then paths[p] = true; order[#order + 1] = p end end
    for _, p in ipairs(KNOWN_ITEMS) do add(p) end
    for p in pairs(SeenItems) do add(p) end
    local prev = U.readAll(F_LOCS) or ""
    for p in prev:gmatch('"(/Game/Gameplay/Inventory/[^"]+)"') do add(p) end
    -- sorted bag for every bag tag
    for _, p in ipairs({ table.unpack(order) }) do
        if p:find("INV_BagTag_") then add((p:gsub("INV_BagTag_", "INV_SortedBag_"))) end
    end
    -- numbered vaults
    for _, code in ipairs(VAULT_CODES) do
        local misses = 0
        for i = 1, 20 do
            local name = "INV_VAULT_" .. code .. "_" .. i
            local p = "/Game/Gameplay/Inventory/Vault/" .. name .. "." .. name
            if exists(p) then add(p); misses = 0 else misses = misses + 1 end
            if misses >= 2 then break end
        end
    end
    os.remove(F_ITEMS)
    local n = 0
    for _, p in ipairs(order) do
        if exists(p) then catalogueItem(p); n = n + 1 end
    end
    return n
end

-- Progress lines: "try <pkg>" before loading, "ok <pkg>" after. A package with
-- one unmatched "try" crashed the game: retry it once in safe mode
-- (collectibles only). Two unmatched tries: skip it.
local function readProgress()
    local tries, oks = {}, {}
    local s = U.readAll(F_PROGRESS)
    if s then
        for line in s:gmatch("[^\r\n]+") do
            local kind, pkg = line:match("^(%S+)%s+(.+)$")
            if kind == "ok" then oks[pkg] = true
            elseif kind == "try" or kind == "safe" then tries[pkg] = (tries[pkg] or 0) + 1 end
        end
    end
    local done, retry = {}, {}
    for pkg, n in pairs(tries) do
        if oks[pkg] then done[pkg] = true
        elseif n >= 2 then done[pkg] = true; U.log("Skipping %s (crashed twice)", pkg)
        else retry[pkg] = true end
    end
    return done, retry
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
    local allPkgs, doneSet, retrySet = {}, {}, {}
    local itemSeen = {}
    local stats = { packages = 0, locations = 0, failed = 0 }
    local busy = false
    local startedAt = os.time()

    local function step()
        if state == "wait" then
            state = "discover"
            return
        end

        if state == "discover" then
            local seen = {}
            local function add(p)
                p = p:gsub("%.[%w_]+$", "")
                if not seen[p] then seen[p] = true; allPkgs[#allPkgs + 1] = p end
            end
            -- Map names supplied by the app (read from the save files), then the built-in list
            for line in (U.readAll(F_REQUEST) or ""):gmatch("[^\r\n]+") do
                if line:find("^/Game/Maps/") then add(line) end
            end
            for _, p in ipairs(FALLBACK_PERSISTENT) do add("/Game/Maps/" .. p) end
            doneSet, retrySet = readProgress()
            for p in pairs(retrySet) do add(p) end -- sublevels that crashed last time
            table.sort(allPkgs)
            for _, p in ipairs(allPkgs) do
                if shouldScan(p, fullScan) and not doneSet[p] then queue[#queue + 1] = p end
            end
            U.log("Map packages known: %d, queued this run: %d", #allPkgs, #queue)
            stats.total = #queue
            state = "scan"
            return
        end

        if state == "scan" then
            if qi > #queue then
                state = "items"
                return
            end
            local pkg = queue[qi]
            qi = qi + 1
            -- Mark as attempted BEFORE loading so a crash on this package skips it next time
            local safe = retrySet[pkg] == true
            appendLine(F_PROGRESS, (safe and "safe " or "try ") .. pkg)
            writeStatus({ state = "scanning", index = qi - 1, total = #queue, current = pkg,
                locations = stats.locations, elapsed = os.time() - startedAt })
            U.log("  -> %s%s", pkg, safe and "  (retry in safe mode)" or "")
            local ok, n, err = pcall(scanPackage, pkg, function(sub)
                sub = sub:gsub("%.[%w_]+$", "")
                for _, p in ipairs(allPkgs) do if p == sub then return end end
                allPkgs[#allPkgs + 1] = sub
                if shouldScan(sub, fullScan) and not doneSet[sub] then
                    queue[#queue + 1] = sub
                    stats.total = #queue
                end
            end, safe)
            appendLine(F_PROGRESS, "ok " .. pkg) -- reached here, so the game didn't crash on it
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

        if state == "items" then
            U.log("Cataloguing items...")
            local n = catalogueAll()
            U.log("Catalogued %d inventory items", n)
            state = "finish"
            return
        end

        if state == "finish" then
            stats.elapsed = os.time() - startedAt
            if stats.locations == 0 and #(U.readAll(F_LOCS) or "") < 10 then
                writeStatus({ state = "failed", packages = stats.packages, failed = stats.failed,
                    message = "No collectibles were found. Send psychorando.log to the developer." })
                U.log("SCAN FAILED: no collectibles found in %d packages (%d failed to load).", stats.packages, stats.failed)
                state = "stopped"
                return
            end
            U.writeAll(F_DONE, U.json(stats))
            writeStatus({ state = "done", locations = stats.locations, packages = stats.packages,
                failed = stats.failed, elapsed = stats.elapsed })
            os.remove(F_REQUEST)
            U.log("SCAN COMPLETE: %d collectibles in %d packages (%d failed). You can close the game now.",
                stats.locations, stats.packages, stats.failed)
            state = "stopped"
        end
    end

    -- One step per game-thread tick (~20/s); each step loads at most one package
    U.everyTick(function()
        if state == "stopped" then return true end
        local ok, err = pcall(step)
        if not ok then U.log("scan step error: %s", tostring(err)) end
        return false
    end)
end

return S
