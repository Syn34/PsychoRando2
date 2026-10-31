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
        local isArr = (#v > 0) or (next(v) == nil and v.__array)
        if isArr then
            local parts = {}
            for i = 1, #v do parts[#parts + 1] = U.json(v[i]) end
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

U.CATEGORY_BY_TYPE = {
    [0] = "figment", [1] = "psitanium", [2] = "psimarker", [3] = "keyitem",
    [4] = "vault", [5] = "baggage", [6] = "nugget", [7] = "psicard",
    [8] = "psicore", [9] = "supplychest", [10] = "halfamind", [11] = "bagtag",
    [12] = "supplykey",
}

return U
