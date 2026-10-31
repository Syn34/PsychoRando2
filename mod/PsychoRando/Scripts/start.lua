-- Optional start: skip Loboto's Labyrinth and begin at the Motherlobe.
-- Runs once per randomized slot, right after a New Game drops Raz into LOBO.
-- Uses the game's own developer "advance to quest" (it sets the story state
-- as if every earlier quest was done), then opens the Motherlobe map if the
-- game didn't travel there by itself.
local U = require("util")

local S = {}

local QUEST_ROOT = "/Game/Gameplay/Quests/HUB1/QUEST_HUB1_0000_ROOT.QUEST_HUB1_0000_ROOT"
local QUEST_DONE_LOBO = "/Game/Gameplay/Quests/HUB1/QUEST_HUB1_1000_CompleteLobo.QUEST_HUB1_1000_CompleteLobo"
local QUEST_TARGET = "/Game/Gameplay/Quests/HUB1/QUEST_HUB1_1005_CheckinFrontDesk.QUEST_HUB1_1005_CheckinFrontDesk"
local MAP_MOTHERLOBE = "/Game/Maps/HQIN/HQIN.HQIN"

local function flagPath(slot) return U.ROOT .. "seeds/slot_" .. tostring(slot) .. "_started.txt" end

local function lib() return U.resolve("/Script/Psychonauts2.Default__P2BlueprintLibrary") end

local function load(path)
    local o = U.resolve(path)
    if o then return o end
    pcall(function() LoadAsset(path) end)
    return U.resolve(path)
end

-- UE4SS 3.0.1 soft-object parameters: try the loaded object, the path string,
-- and an FSoftObjectPath-shaped table, in that order.
local function softForms(path)
    local forms = {}
    local o = load(path)
    if o then forms[#forms + 1] = o end
    forms[#forms + 1] = path
    forms[#forms + 1] = { AssetPathName = FName(path), SubPathString = "" }
    return forms
end

local function tryCall(what, fn)
    local ok, err = pcall(fn)
    if ok then U.log("start: %s ok", what) return true end
    U.log("start: %s failed: %s", what, U.errText(err))
    return false
end

-- ---------------------------------------------------------------------------
-- The developers' debug menu (P2CheatManager) has a Checkpoints page whose
-- entries jump to a story point and set the game state to match. All of its
-- calls take plain strings/names, which UE4SS 3.0.1 handles reliably.
local function strList(arr)
    local out = {}
    if arr == nil then return out end
    if type(arr) == "table" then
        for _, v in ipairs(arr) do out[#out + 1] = U.fname(v) or tostring(v) end
        return out
    end
    U.eachArray(arr, function(_, v) out[#out + 1] = U.fname(v) or tostring(v) end)
    return out
end

local function cheatManager()
    local pc = FindFirstOf("PlayerController")
    if not U.valid(pc) then return nil end
    local cm = U.get(pc, "CheatManager")
    if U.valid(cm) then return cm end
    pcall(function()
        U.resolve("/Script/Engine.Default__KismetSystemLibrary"):ExecuteConsoleCommand(pc, "EnableCheats", pc)
    end)
    cm = U.get(pc, "CheatManager")
    if U.valid(cm) then return cm end
    return FindFirstOf("P2CheatManager")
end

local CHECKPOINT_PREFS = { "1005", "CHECKINFRONTDESK", "FRONTDESK", "HUB1_1010", "INTERNSTART", "HQIN", "MOTHERLOBE", "HUB1" }

local function viaDebugMenu()
    local cm = cheatManager()
    if not cm then U.log("start: no cheat manager available") return false end
    pcall(function() cm:LoadDebugMenuContent() end)
    local lines = {}
    local okT, titles = pcall(function() return strList(cm:GetDebugMenuPageTitles()) end)
    if not okT then U.log("start: debug menu titles failed: %s", U.errText(titles)) return false end
    local cpPage
    for _, t in ipairs(titles) do
        lines[#lines + 1] = "PAGE " .. t
        if t:upper():find("CHECKPOINT") then cpPage = t end
        local okF, fns = pcall(function() return strList(cm:GetFunctionsForPage(t)) end)
        if okF then for _, f in ipairs(fns) do lines[#lines + 1] = "  " .. f end end
    end
    U.writeAll(U.ROOT .. "data/debug_menu.txt", table.concat(lines, "\n"))
    U.log("start: debug menu has %d pages (list saved to data/debug_menu.txt)", #titles)
    if not cpPage then U.log("start: no Checkpoints page in the debug menu") return false end
    local fns = strList(cm:GetFunctionsForPage(cpPage))
    local pick
    for _, pref in ipairs(CHECKPOINT_PREFS) do
        for _, f in ipairs(fns) do
            local up = f:upper()
            if up:find(pref, 1, true) and not up:find("LOBO", 1, true) then pick = f break end
        end
        if pick then break end
    end
    if not pick then U.log("start: no Motherlobe checkpoint among %d checkpoints", #fns) return false end
    U.log("start: using checkpoint '%s'", pick)
    return tryCall("debug checkpoint " .. pick, function() cm:CallVoidFunctionOnPage(cpPage, FName(pick)) end)
end

local state = "idle"     -- idle -> waiting -> advanced -> done
local lastWhere = nil
local razSince, advancedAt = nil, nil

local function razInLobo()
    local raz = U.raz()
    if not raz then return false, nil end
    local f = U.fullName(raz) or ""
    return f:find("/Game/Maps/LOBO/", 1, true) ~= nil, raz
end

local function questComplete(raz, path)
    local okS, status = pcall(function()
        for _, q in ipairs(softForms(path)) do
            local ok, r = pcall(function() return lib():GetQuestStatus(raz, q) end)
            if ok then return r end
        end
        return nil
    end)
    return okS and status ~= nil and tonumber(status) ~= nil and tonumber(status) >= 3
end

local function advance(raz)
    if viaDebugMenu() then return true end
    local L = lib()
    if not L then return false end
    for i, q in ipairs(softForms(QUEST_TARGET)) do
        local root = softForms(QUEST_ROOT)[i]
        if tryCall("DebugAdvanceToQuest (form " .. i .. ")", function()
            L:DebugAdvanceToQuest(q, root, raz, false)
        end) then return true end
    end
    return false
end

local function openMotherlobe(raz)
    local L = lib()
    for i, lvl in ipairs(softForms(MAP_MOTHERLOBE)) do
        if tryCall("P2OpenLevel Motherlobe (form " .. i .. ")", function()
            L:P2OpenLevel(raz, lvl, {}, nil, nil, false, 0, true, "", true)
        end) then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Template capture: after this session's skip, the first save the game writes
-- at the Motherlobe is copied to data/template_motherlobe.sav. The app then
-- writes it straight into new randomized slots ("Continue" at the Motherlobe).
local TEMPLATE = U.ROOT .. "data/template_motherlobe.sav"
local capture = nil -- { slot=, baseline = {name -> content}, changedAt=, file= }

local function saveDir()
    local la = os.getenv("LOCALAPPDATA")
    if not la then return nil end
    return la .. "\\Psychonauts2\\Saved\\SaveGames\\"
end

local function slotFiles(slot)
    local d = saveDir()
    if not d then return {} end
    return { d .. "Psychonauts2Save_" .. slot .. ".sav", d .. "Psychonauts2Save_" .. string.char(65 + slot) .. ".sav" }
end

local function captureTick(raz)
    if not capture or capture.done then return end
    local f = U.fullName(raz) or ""
    if not f:find("/Game/Maps/HQIN/", 1, true) then return end
    if not capture.baseline then
        capture.baseline = {}
        for _, p in ipairs(slotFiles(capture.slot)) do capture.baseline[p] = U.readAll(p) or "" end
        U.log("start: at the Motherlobe; waiting for the game's save to capture the starting template")
        return
    end
    if not capture.file then
        for _, p in ipairs(slotFiles(capture.slot)) do
            local now = U.readAll(p) or ""
            if #now > 0 and now ~= capture.baseline[p] then capture.file, capture.changedAt = p, os.time() end
        end
        return
    end
    if os.time() - capture.changedAt < 3 then return end -- let the write finish
    if not questComplete(raz, QUEST_DONE_LOBO) then
        U.log("start: save written but Loboto's Labyrinth isn't marked complete yet; waiting for the next save")
        capture.baseline, capture.file = nil, nil
        return
    end
    local data = U.readAll(capture.file)
    if data and #data > 1000 and data:sub(1, 4) == "GVAS" then
        U.writeAll(TEMPLATE, data)
        U.writeAll(U.ROOT .. "data/template_motherlobe.json",
            U.json({ captured = os.date("%Y-%m-%d %H:%M:%S"), bytes = #data, from = capture.file }))
        U.log("start: captured the Motherlobe starting save (%d bytes). New randomized games will start here.", #data)
        capture.done = true
    end
end

-- Called every game-thread tick by the runtime while a seed is active.
function S.tick(seed, slot)
    if capture and not capture.done then
        local raz = U.raz()
        if raz then pcall(captureTick, raz) end
    end
    if not seed or seed.startAt ~= "motherlobe" or state == "done" then return end
    if state == "idle" then
        local flag = U.readAll(flagPath(slot))
        if flag and not flag:find("^failed") then state = "done" return end
        state = "waiting"
    end
    local inLobo, raz = razInLobo()
    if state == "waiting" then
        local where = raz and (U.fullName(raz) or "?"):match("/Game/Maps/([^/]+)/") or "no Raz yet"
        if where ~= lastWhere then
            lastWhere = where
            U.log("start: waiting for Loboto's Labyrinth (Raz is in: %s)", where)
        end
        if not inLobo then razSince = nil return end
        razSince = razSince or os.time()
        if os.time() - razSince < 4 then return end -- let the new game settle
        if questComplete(raz, QUEST_DONE_LOBO) then
            U.writeAll(flagPath(slot), "already past Loboto's Labyrinth")
            state = "done"
            return
        end
        U.log("Start at the Motherlobe: skipping Loboto's Labyrinth")
        local advanced = advance(raz)
        if not U.exists(TEMPLATE) then capture = { slot = slot } end
        U.writeAll(flagPath(slot), (advanced and "" or "failed ") .. os.date("%Y-%m-%d %H:%M:%S"))
        state, advancedAt = "advanced", os.time()
        return
    end
    if state == "advanced" then
        if os.time() - advancedAt < 6 then return end
        if inLobo then
            U.log("start: still in Loboto's Labyrinth; opening the Motherlobe")
            if openMotherlobe(raz) then
                U.writeAll(flagPath(slot), os.date("%Y-%m-%d %H:%M:%S"))
            else
                U.log("start: could not skip Loboto's Labyrinth this time; will retry next time this slot is loaded")
            end
        end
        state = "done"
    end
end

-- New map loaded: re-check from scratch (the flag file keeps it once-only)
function S.reset()
    if state ~= "done" then state, razSince, advancedAt = "idle", nil, nil end
end

return S
