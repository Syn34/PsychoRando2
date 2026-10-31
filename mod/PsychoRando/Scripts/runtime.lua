-- PsychoRando runtime: applies the seed for the active save slot.
--
-- Strategy
--  1. Every collectible carries a CoCollectable component (type + unique id).
--     When one spawns we look its location up in the seed and, if it is a
--     normal pickup, rewrite COMP_Pickupable.m_aPickupGrantedItems so the
--     game itself grants the new item (correct pickup popups, inventory
--     limits checked against the new item).
--  2. Sources that grant from Blueprint code (baggage, vaults, half-a-minds,
--     interact pickups) can't be rewritten. For those we watch inventory
--     changes: when the original category item arrives right after that
--     location was collected, we take it back and grant the assigned item.
local U = require("util")
local Proxy = require("proxy")
local Start = require("start")

local R = {}

local seed = nil          -- loaded seed table
local seedSlot = nil      -- slot index the seed belongs to
local seedMTime = nil
local processed = {}      -- comp full name -> true (rewritten or checked)
local pending = {}        -- { comp=, t= }
local handled = {}        -- location key -> true (this session)
local context = {}        -- category -> { key=, give=, t=, granted= }
local recent = {}         -- category -> { item=, delta=, t= }
local expect = {}         -- item path -> outstanding amount we granted ourselves
local hooks = {}          -- registered hook paths

local LONG_CONTEXT = { vault = 180, baggage = 180 }
local SHORT_CONTEXT = 4

local function now() return os.clock() end

local function lib()
    return StaticFindObject("/Script/Psychonauts2.Default__P2BlueprintLibrary")
end

local function worldCtx()
    local raz = FindFirstOf("P2CharacterRaz")
    if U.valid(raz) then return raz end
    local pc = FindFirstOf("PlayerController")
    if U.valid(pc) then return pc end
    return nil
end

local function loadItem(path)
    local obj = U.resolve(path)
    if obj then return obj end
    pcall(function() LoadAsset(path) end)
    obj = U.resolve(path)
    if obj then return obj end
    U.log("WARNING: could not load item %s", tostring(path))
    return nil
end

---------------------------------------------------------------------------
-- Seed loading
---------------------------------------------------------------------------
local function currentSlot()
    local gus = FindFirstOf("P2GameUserSettings")
    if not U.valid(gus) then return nil end
    local ok, idx = pcall(function() return gus:GetCurrentSaveSlotIndex() end)
    if ok then return idx end
    return nil
end

local function seedPath(slot) return U.ROOT .. "seeds/slot_" .. tostring(slot) .. ".lua" end

local function fileStamp(path)
    local s = U.readAll(path)
    if not s then return nil end
    return #s .. ":" .. s:sub(1, 200)
end

local function loadSeed(slot)
    local path = seedPath(slot)
    if not U.exists(path) then return nil end
    local chunk, err = loadfile(path)
    if not chunk then U.log("Seed file error: %s", tostring(err)) return nil end
    local ok, t = pcall(chunk)
    if not ok or type(t) ~= "table" then U.log("Seed load error: %s", tostring(t)) return nil end
    local n = 0
    for _ in pairs(t.locs or {}) do n = n + 1 end
    U.log("Loaded seed '%s' for save slot %d (%d location keys)", tostring(t.seed), slot + 1, n)
    return t
end

local function refreshSeed()
    if U.scanning then
        if seed then U.log("Scanning: randomizer paused") pcall(Proxy.clearAll) end
        seed, seedSlot, seedMTime, pending = nil, nil, nil, {}
        return
    end
    local slot = currentSlot()
    if slot == nil then return end
    local stamp = fileStamp(seedPath(slot))
    if slot ~= seedSlot or stamp ~= seedMTime then
        seedSlot, seedMTime = slot, stamp
        seed = stamp and loadSeed(slot) or nil
        processed, handled, context, recent, expect = {}, {}, {}, {}, {}
        pcall(Proxy.clearAll)
        if seed then Proxy.setFigmentParams(seed.figParams) end
        if not seed then U.log("Save slot %d is not randomized; mod idle.", slot + 1) end
    end
end

---------------------------------------------------------------------------
-- Location lookup
---------------------------------------------------------------------------
local function locationOf(comp)
    local id = U.fname(U.get(comp, "m_CollectableUniqueID"))
    local okO, actor = pcall(function() return comp:GetOuter() end)
    local pkg, aname
    if okO and U.valid(actor) then pkg, aname = U.splitActorPath(U.fullName(actor)) end
    local entry, key
    if id and id ~= "None" and id ~= "" then
        key = "id:" .. id
        entry = seed.locs[key]
    end
    if not entry and pkg and aname then
        key = "pa:" .. pkg .. "|" .. aname
        entry = seed.locs[key]
    end
    return entry, key, actor
end

-- Locations without a CoCollectable component (scavenger hunt items etc.)
local function locationOfActor(actor)
    if not seed or not U.valid(actor) then return nil end
    local pkg, aname = U.splitActorPath(U.fullName(actor))
    if not pkg or not aname then return nil end
    local key = "pa:" .. pkg .. "|" .. aname
    return seed.locs[key], key
end

local function categoryOfItem(path)
    if not seed or not seed.itemCat then return nil end
    return seed.itemCat[path]
end

local function giveLabel(entry)
    return entry.label or "?"
end

---------------------------------------------------------------------------
-- Granting / reverting
---------------------------------------------------------------------------
local function grant(entry, why)
    local ctx = worldCtx()
    if not ctx then return false end
    for _, g in ipairs(entry.give or {}) do
        local item = loadItem(g[1])
        if item then
            expect[g[1]] = (expect[g[1]] or 0) + g[2]
            local ok, err = pcall(function() lib():AddToRazInventory(ctx, item, g[2]) end)
            if not ok then U.log("AddToRazInventory failed: %s", tostring(err)) end
        end
    end
    U.log("Received: %s  (%s)", giveLabel(entry), why)
    return true
end

local function revert(path, delta)
    local ctx = worldCtx()
    local itemObj = loadItem(path)
    if not ctx or not itemObj then return end
    local ok, err = pcall(function() lib():RemoveFromRazInventory(ctx, itemObj, delta) end)
    if ok then U.log("  (took back original %s x%d)", path, delta)
    else U.log("RemoveFromRazInventory failed: %s", tostring(err)) end
end

local function deferred(fn)
    U.post(fn) -- next game-thread tick, outside the inventory callback
end

---------------------------------------------------------------------------
-- 1. Rewrite pickups when they appear
---------------------------------------------------------------------------
local function pickupableOf(actor)
    local pk = U.get(actor, "COMP_Pickupable")
    if U.valid(pk) then return pk end
    return nil
end

local function rewriteActor(actor, entry, key)
    if not entry or not entry.give or entry.from == key then return end
    pcall(Proxy.make, actor, entry, key)
    local pk = pickupableOf(actor)
    if not pk then return end
    local full = U.fullName(pk)
    if not full or processed[full] then return end
    processed[full] = true
    local arr = U.get(pk, "m_aPickupGrantedItems")
    local n = 0
    pcall(function() n = arr:GetArrayNum() end)
    if n < 1 or #entry.give > 1 then return end
    local ok = pcall(function()
        if #entry.give == 1 then
            arr[1].m_pItemToGrant = loadItem(entry.give[1][1])
            arr[1].m_iAmountToGrant = entry.give[1][2]
        else
            arr[1].m_iAmountToGrant = 0
        end
        for i = 2, n do arr[i].m_iAmountToGrant = 0 end
    end)
    if ok then entry.rewritten = entry.rewritten or {}; entry.rewritten[U.fullName(actor) or full] = true end
end

local function sweepActorLocations()
    if not seed or not seed.hasActorLocs then return end
    for _, cls in ipairs({ "COMP_Pickupable_C", "COMP_Interactible_C" }) do
        for _, c in ipairs(FindAllOf(cls) or {}) do
            local okO, actor = pcall(function() return c:GetOuter() end)
            if okO and U.valid(actor) and not U.valid(U.get(actor, "CoCollectable")) then
                local entry, key = locationOfActor(actor)
                if entry then pcall(rewriteActor, actor, entry, key) end
            end
        end
    end
end

local function tryRewrite(comp)
    local full = U.fullName(comp)
    if not full or processed[full] then return end
    if full:find("Default__", 1, true) or full:find("_GEN_VARIABLE", 1, true) then processed[full] = true return end
    local entry, key, actor = locationOf(comp)
    processed[full] = true
    if not entry then return end
    if entry.from == key then return end
    if U.valid(actor) then
        local ok, err = pcall(Proxy.make, actor, entry, key)
        if not ok then U.log("proxy error %s: %s", key, tostring(err)) end
    end
    if entry.give == nil then return end
    local pk = U.valid(actor) and pickupableOf(actor) or nil
    if not pk then return end
    local arr = U.get(pk, "m_aPickupGrantedItems")
    local n = 0
    pcall(function() n = arr:GetArrayNum() end)
    if n < 1 then return end -- nothing granted natively; handled at collect time
    if #entry.give > 1 then return end -- can't grow arrays from Lua; handled at collect time
    local ok, err = pcall(function()
        if #entry.give == 1 then
            local item = loadItem(entry.give[1][1])
            if not item then error("item not loaded") end
            arr[1].m_pItemToGrant = item
            arr[1].m_iAmountToGrant = entry.give[1][2]
        else
            arr[1].m_iAmountToGrant = 0
        end
        for i = 2, n do arr[i].m_iAmountToGrant = 0 end
    end)
    if ok then
        entry.rewritten = entry.rewritten or {}
        entry.rewritten[full] = true
        handled[key] = nil
    else
        U.log("rewrite failed for %s: %s", key, tostring(err))
    end
end

local function processPending()
    if not seed then pending = {} return end
    local t = now()
    local keep = {}
    for _, p in ipairs(pending) do
        if t - p.t >= 0.6 then
            local comp = U.resolve(p.path)
            if comp then pcall(tryRewrite, comp) end
        else
            keep[#keep + 1] = p
        end
    end
    pending = keep
end

local function sweepExisting()
    if not seed then return end
    local all = FindAllOf("CoCollectable")
    if not all then return end
    for _, c in ipairs(all) do pcall(tryRewrite, c) end
end

---------------------------------------------------------------------------
-- 2. Collection events
---------------------------------------------------------------------------
local function onCollected(comp, why)
    if not seed or not U.valid(comp) then return end
    local entry, key = locationOf(comp)
    if not entry then return end
    if handled[key] then return end
    handled[key] = true
    U.post(function() Proxy.remove(key) end)
    if entry.from and (entry.from == key or ("id:" .. tostring(entry.from)) == key) then
        return -- this spot rolled its own item: let the game behave normally
    end
    local full = U.fullName(comp)
    if entry.rewritten and full and entry.rewritten[full] then
        -- the game granted the new item itself; mark it expected so the watcher ignores it
        for _, g in ipairs(entry.give or {}) do expect[g[1]] = (expect[g[1]] or 0) + g[2] end
        U.log("Received: %s  (%s %s)", giveLabel(entry), why, key)
        return
    end
    local cat = entry.c
    -- Original reward may already have arrived before this hook fired
    local r = recent[cat]
    if r and now() - r.t < 1.5 then
        recent[cat] = nil
        deferred(function() revert(r.item, r.delta) end)
    else
        context[cat] = { key = key, t = now() }
    end
    deferred(function() grant(entry, why .. " " .. key) end)
end

local function collectableOfActor(actor)
    if not U.valid(actor) then return nil end
    local c = U.get(actor, "CoCollectable")
    if U.valid(c) then return c end
    local all = FindAllOf("CoCollectable") or {}
    local af = U.fullName(actor)
    for _, comp in ipairs(all) do
        local okO, o = pcall(function() return comp:GetOuter() end)
        if okO and U.valid(o) and U.fullName(o) == af then return comp end
    end
    return nil
end

local function onInventoryChanged(itemObj, oldAmt, newAmt, fromLoad)
    if not seed or fromLoad then return end
    local delta = (newAmt or 0) - (oldAmt or 0)
    if delta <= 0 then return end
    local path = U.objPath(itemObj)
    if not path then return end
    local e = expect[path]
    if e and e > 0 then
        expect[path] = math.max(0, e - delta)
        return
    end
    local cat = categoryOfItem(path)
    if not cat then return end
    if not seed.cats or not seed.cats[cat] then return end -- category not randomized
    local ctx = context[cat]
    local limit = LONG_CONTEXT[cat] or SHORT_CONTEXT
    if ctx and now() - ctx.t <= limit then
        context[cat] = nil
        deferred(function() revert(path, delta) end)
    else
        recent[cat] = { item = path, delta = delta, t = now() }
    end
end

---------------------------------------------------------------------------
-- Hooks
---------------------------------------------------------------------------
local function hook(path, fn)
    if hooks[path] then return true end
    local ok, err = pcall(function() RegisterHook(path, fn) end)
    if ok then hooks[path] = true U.log("hooked %s", path) return true end
    return false
end

local function p(v)
    if v == nil then return nil end
    local ok, x = pcall(function() return v:get() end)
    if ok then return x end
    return v
end

local function onActorCollected(actor, why)
    local entry, key = locationOfActor(actor)
    if not entry or handled[key] or entry.from == key then return end
    handled[key] = true
    U.post(function() Proxy.remove(key) end)
    if entry.rewritten and entry.rewritten[U.fullName(actor) or ""] then
        for _, g in ipairs(entry.give or {}) do expect[g[1]] = (expect[g[1]] or 0) + g[2] end
        U.log("Received: %s  (%s %s)", giveLabel(entry), why, key)
        return
    end
    local r = recent[entry.c]
    if r and now() - r.t < 1.5 then
        recent[entry.c] = nil
        deferred(function() revert(r.item, r.delta) end)
    else
        context[entry.c] = { key = key, t = now() }
    end
    deferred(function() grant(entry, why .. " " .. key) end)
end

local function actorHook(why)
    return function(self)
        local actor = p(self)
        local c = collectableOfActor(actor)
        if c then onCollected(c, why) else onActorCollected(actor, why) end
    end
end

local BP_HOOKS = {
    { "/Game/Gameplay/Pickups/PKUP_Base.PKUP_Base_C:OnPlayerPickedUp", "pickup" },
    { "/Game/Gameplay/Pickups/PKUP_Base_Interact.PKUP_Base_Interact_C:BndEvt__COMP_Interactible_K2Node_ComponentBoundEvent_0_P2InteractionEvent__DelegateSignature", "interact" },
    { "/Game/Gameplay/Pickups/Upgrades/PKUP_HalfAMind.PKUP_HalfAMind_C:BndEvt__COMP_Interactible_K2Node_ComponentBoundEvent_0_P2InteractionEvent__DelegateSignature", "half-a-mind" },
    { "/Game/Gameplay/GameObjects/SystemsTech/BaseClasses/Utility/GMO_BC_EmotionalBaggage.GMO_BC_EmotionalBaggage_C:BndEvt__COMP_Interactible_K2Node_ComponentBoundEvent_0_P2InteractionEvent__DelegateSignature", "baggage" },
    { "/Game/Gameplay/PlaceableAI/Ambient/CHR_Vault.CHR_Vault_C:BndEvt__CoDamageable_K2Node_ComponentBoundEvent_0_DeadEvent__DelegateSignature", "vault" },
}

local function registerHooks()
    hook("/Script/Psychonauts2.CoCollectable:OnCollectablePickedUp", function(self)
        onCollected(p(self), "pickup")
    end)
    hook("/Script/Psychonauts2.CoCollectable:Collect", function(self)
        onCollected(p(self), "collect")
    end)
    hook("/Script/Psychonauts2.CoLootDropper:OnDeath", function(self, dead)
        local actor = p(dead)
        local c = collectableOfActor(actor)
        if c then onCollected(c, "vault") end
    end)
    local invHook = function(self, item, oldA, newA, fromLoad)
        onInventoryChanged(p(item), p(oldA), p(newA), p(fromLoad))
    end
    hook("/Script/Psychonauts2.P2UpgradeManager:OnInventoryItemAmountChanged", invHook)
    if not hooks["/Script/Psychonauts2.P2UpgradeManager:OnInventoryItemAmountChanged"] then
        hook("/Script/Psychonauts2.CoEquipment:OnInventoryItemAmountChanged", invHook)
    end
    for _, h in ipairs(BP_HOOKS) do hook(h[1], actorHook(h[2])) end
end

---------------------------------------------------------------------------
function R.start()
    U.log("Runtime started; waiting for the game to finish loading")
    -- Safe before the gate: these only register callbacks, they don't search objects
    NotifyOnNewObject("/Script/Psychonauts2.CoCollectable", function(comp)
        if seed and not U.scanning then
            local path = U.objPath(comp)
            if path then pending[#pending + 1] = { path = path, t = now() } end
        end
    end)
    -- Leaving a map destroys everything: forget all references before doing any work
    U.onMapChange(function()
        pending, processed, context, recent, expect = {}, {}, {}, {}, {}
        Proxy.forget()
        Start.reset()
    end)
    U.onReady(function()
        pcall(refreshSeed)
        pcall(registerHooks)
        pcall(sweepExisting)
        -- ticks run ~20 times a second on the game thread
        U.everyTick(function(t)
            if U.scanning then return false end
            if t % 40 == 1 then pcall(refreshSeed) end
            if t % 200 == 2 then pcall(registerHooks) end
            if t % 100 == 3 then pcall(sweepExisting) end
            if t % 100 == 53 then pcall(sweepActorLocations) end
            if t % 5 == 0 then pcall(processPending) end
            if t % 20 == 7 then pcall(Proxy.cleanup) end
            if t % 10 == 4 and seed then
                local ok, err = pcall(Start.tick, seed, seedSlot)
                if not ok then U.log("start error: %s", tostring(err)) end
            end
            return false
        end)
    end)

    RegisterKeyBind(Key.F8, { ModifierKey.CONTROL }, function()
        U.post(function()
            if seed then
                U.log("Seed '%s' active on save slot %d (%d item models shown here)", tostring(seed.seed), (seedSlot or 0) + 1, Proxy.count())
            elseif not U.isReady() then
                U.log("Still waiting for the game to finish loading")
            else
                U.log("No seed active (slot %s)", tostring(seedSlot and seedSlot + 1))
            end
        end)
    end)
end

return R
