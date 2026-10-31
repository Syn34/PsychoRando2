-- PsychoRando shared helpers
local U = {}

U.ROOT = "Mods/PsychoRando/"
U.TAG = "[PsychoRando] "

local logFile = nil
function U.log(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then msg = tostring(fmt) end
    print(U.TAG .. msg .. "\n")
    if not logFile then logFile = io.open(U.ROOT .. "psychorando.log", "a") end
    if logFile then
        logFile:write(os.date("%Y-%m-%d %H:%M:%S ") .. msg .. "\n")
        logFile:flush()
    end
end

function U.exists(path)
    local f = io.open(path, "rb")
    if f then f:close() return true end
    return false
end

function U.readAll(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

function U.writeAll(path, s)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(s)
    f:close()
    return true
end

-- Safe property access: returns nil instead of throwing
function U.get(obj, name)
    local ok, v = pcall(function() return obj[name] end)
    if ok then return v end
    return nil
end

function U.valid(obj)
    if obj == nil then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v
end

function U.fname(v)
    if v == nil then return nil end
    local ok, s = pcall(function() return v:ToString() end)
    if ok then return s end
    return tostring(v)
end

function U.fullName(obj)
    local ok, s = pcall(function() return obj:GetFullName() end)
    if ok then return s end
    return nil
end

-- "ClassName /Game/Maps/X/Y.Y:PersistentLevel.Actor" -> package "/Game/Maps/X/Y", actor "Actor"
function U.splitActorPath(full)
    if not full then return nil, nil end
    local path = full:match("^%S+%s+(.+)$") or full
    local pkg = path:match("^([^%.:]+)")
    local actor = path:match(":PersistentLevel%.([^%.]+)")
    return pkg, actor
end

-- object path of an asset from its full name: "Class /Game/A/B.B" -> "/Game/A/B.B"
function U.objPath(obj)
    local full = U.fullName(obj)
    if not full then return nil end
    return full:match("^%S+%s+(.+)$") or full
end

-- Iterate a TArray safely; fn(index, elementValue)
function U.eachArray(arr, fn)
    if arr == nil then return end
    local okN, n = pcall(function() return arr:GetArrayNum() end)
    if not okN or not n then return end
    for i = 1, n do
        local ok, el = pcall(function() return arr[i] end)
        if ok and el ~= nil then
            -- elements may be RemoteUnrealParam-like wrappers
            local ok2, inner = pcall(function() return el:get() end)
            if ok2 and inner ~= nil then el = inner end
            fn(i, el)
        end
    end
end

function U.list() return { __array = true } end

-- Minimal JSON encoder (strings, numbers, booleans, arrays, objects)
local function esc(s)
    s = s:gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"' end
        if c == '\\' then return '\\\\' end
        if c == '\n' then return '\\n' end
        if c == '\r' then return '\\r' end
        if c == '\t' then return '\\t' end
        return string.format('\\u%04x', c:byte())
    end)
    return s
end

function U.json(v)
    local t = type(v)
    if t == "nil" then return "null" end
    if t == "boolean" then return v and "true" or "false" end
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "0" end
        if math.floor(v) == v and math.abs(v) < 1e15 then return string.format("%d", v) end
        return string.format("%.3f", v)
    end
    if t == "string" then return '"' .. esc(v) .. '"' end
    if t == "table" then
        local isArr = v.__array or #v > 0
        if isArr then
            local parts = {}
            for i = 1, #v do parts[#parts + 1] = U.json(v[i]) end -- (__array marker is not a list element)
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local parts = {}
        for k, val in pairs(v) do
            if k ~= "__array" then
                parts[#parts + 1] = '"' .. esc(tostring(k)) .. '":' .. U.json(val)
            end
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return '"' .. esc(tostring(v)) .. '"'
end

-- Game-thread scheduler.
-- UE4SS 3.0.1's ExecuteInGameThread runs on whichever thread next calls
-- ProcessEvent, which is sometimes a worker thread; loading assets there
-- crashes ("Tried to access cooked shader map ID from unknown thread").
-- Instead we start a looping engine timer on the PlayerController that calls
-- the harmless AActor::ForceNetUpdate, and hook that function: engine timers
-- always fire on the game thread. All engine work runs from that tick.
--
-- Startup: searching objects while the engine initializes also crashes, so
-- nothing happens until a PlayerController exists and the game has settled.
local tickFns, postQueue = {}, {}
local readyCallbacks, readyFired, pcSeenAt = {}, false, nil
local startedAt = os.time()
local lastTick = 0
local armedAt = 0
local SETTLE_SECONDS = 8
local FALLBACK_SECONDS = 90
local TICK_INTERVAL = 0.05

U.gameTicks = 0
U.mapEpoch = 0
local mapChangeFns = {}
-- fn() is called (on the game thread, before any other work) whenever the
-- player controller changes: title screen, loading screen, new map. Handlers
-- must only drop references, never call into game objects.
function U.onMapChange(fn) mapChangeFns[#mapChangeFns + 1] = fn end
local function mapChanged()
    U.mapEpoch = U.mapEpoch + 1
    for _, fn in ipairs(mapChangeFns) do pcall(fn) end
end

-- Resolve an object path to a live object, or nil (never holds stale pointers)
function U.resolve(path)
    if not path then return nil end
    local ok, o = pcall(StaticFindObject, path)
    if ok and U.valid(o) then return o end
    return nil
end

-- Run fn on the game thread at the next tick
function U.post(fn) postQueue[#postQueue + 1] = fn end

-- Run fn(tickNumber) on the game thread every tick; return true from fn to stop
function U.everyTick(fn) tickFns[#tickFns + 1] = fn end

function U.onReady(fn)
    if readyFired then U.post(fn) return end
    readyCallbacks[#readyCallbacks + 1] = fn
end

function U.isReady() return readyFired end

local lastDrainClock = 0
local function drain()
    -- Several heartbeats may call this; run at most ~20 times a second
    local c = os.clock()
    if c - lastDrainClock < 0.045 then return end
    lastDrainClock = c
    U.gameTicks = U.gameTicks + 1
    lastTick = os.time()
    if not readyFired then
        readyFired = true
        U.log("Game is up; starting.")
        for _, fn in ipairs(readyCallbacks) do postQueue[#postQueue + 1] = fn end
        readyCallbacks = {}
    end
    local q = postQueue
    postQueue = {}
    for _, fn in ipairs(q) do
        local ok, err = pcall(fn)
        if not ok then U.log("error: %s", tostring(err)) end
    end
    local snapshot = tickFns
    local done = {}
    for i = 1, #snapshot do
        local ok, res = pcall(snapshot[i], U.gameTicks)
        if not ok then U.log("tick error: %s", tostring(res))
        elseif res then done[snapshot[i]] = true end
    end
    if next(done) then
        local keep = {}
        for _, fn in ipairs(tickFns) do if not done[fn] then keep[#keep + 1] = fn end end
        tickFns = keep
    end
end

local lastArmed = nil
local function arm()
    local pc = FindFirstOf("PlayerController")
    if not U.valid(pc) then return false end
    local name = U.fullName(pc)
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local ok, err = pcall(function() ksl:K2_SetTimer(pc, "ForceNetUpdate", TICK_INTERVAL, true, 0.0, 0.0) end)
    if not ok then U.log("could not start game-thread timer: %s", tostring(err)) return false end
    if name ~= lastArmed then
        U.log("Game-thread timer started on %s", name or "?")
        if lastArmed ~= nil then mapChanged() end
    end
    lastArmed = name
    return true
end

function U.initReadyGate()
    NotifyOnNewObject("/Script/Engine.PlayerController", function()
        if not pcSeenAt then pcSeenAt = os.time() end
    end)
    RegisterHook("/Script/Engine.Actor:ForceNetUpdate", function()
        drain()
    end)
    -- Map changes replace the controller (and its timer); this hook runs on the game thread
    pcall(function()
        RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
            if not pcSeenAt then pcSeenAt = os.time() end
            if readyFired and os.time() - armedAt >= 1 then armedAt = os.time() pcall(arm) end
        end)
    end)
    -- Gameplay heartbeat: Raz's Blueprint tick runs every frame on the game
    -- thread (the timer above does not fire in gameplay maps). The class only
    -- exists once gameplay has loaded, so keep trying until the hook sticks.
    local razHooked = false
    local RAZ_TICK = "/Game/Characters/Raz/RazCharacter.RazCharacter_C:ReceiveTick"
    LoopAsync(2000, function()
        if razHooked then return true end
        if not pcSeenAt then return false end
        local fn = StaticFindObject(RAZ_TICK)
        if not U.valid(fn) then return false end
        local lastRaz = nil
        local ok = pcall(function() RegisterHook(RAZ_TICK, function(self)
            local okR, raz = pcall(function() return self:get() end)
            local addr = okR and raz and U.fullName(raz) or nil
            if addr and addr ~= lastRaz then
                if lastRaz ~= nil then mapChanged() end
                lastRaz = addr
            end
            drain()
        end) end)
        if ok then
            razHooked = true
            U.log("Gameplay heartbeat attached (Raz tick)")
        end
        return razHooked
    end)
    -- Arms (and re-arms after map changes destroy the controller) the timer
    LoopAsync(1000, function()
        local t = os.time()
        local settled = (pcSeenAt and t - pcSeenAt >= SETTLE_SECONDS) or (t - startedAt >= FALLBACK_SECONDS)
        if settled and t - lastTick >= 3 and t - armedAt >= 3 then
            armedAt = t
            ExecuteInGameThread(function() pcall(arm) end)
        end
        return false
    end)
end

U.CATEGORY_BY_TYPE = {
    [0] = "figment", [1] = "psitanium", [2] = "psimarker", [3] = "keyitem",
    [4] = "vault", [5] = "baggage", [6] = "nugget", [7] = "psicard",
    [8] = "psicore", [9] = "supplychest", [10] = "halfamind", [11] = "bagtag",
    [12] = "supplykey",
}

return U
