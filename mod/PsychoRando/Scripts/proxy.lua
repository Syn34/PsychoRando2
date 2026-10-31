-- Visual proxies: show the randomized item's model at a pickup spot.
-- The original actor stays (its trigger still collects the spot) but is hidden;
-- plain StaticMeshActor / SkeletalMeshActor copies of the assigned item's
-- components are spawned in its place and removed when the spot is collected
-- or the level unloads. All calls run on the game-thread tick.
local U = require("util")
local X = require("xform")

local P = {}
local proxies = {}   -- location key -> { src = path, actors = {paths}, comps = {paths} }
local figParams = nil
local warned = {}

local function lib(path)
    local o = StaticFindObject(path)
    if U.valid(o) then return o end
    return nil
end

local function asset(path)
    if not path or path == "" then return nil end
    local o = U.resolve(path)
    if o then return o end
    pcall(function() LoadAsset(path) end)
    o = U.resolve(path)
    if o then return o end
    if not warned[path] then warned[path] = true U.log("proxy: could not load %s", path) end
    return nil
end

local function worldCtx()
    local raz = FindFirstOf("P2CharacterRaz")
    if U.valid(raz) then return raz end
    return FindFirstOf("PlayerController")
end

local function ftransform(t)
    return {
        Rotation = { X = t.rot[1], Y = t.rot[2], Z = t.rot[3], W = t.rot[4] },
        Translation = { X = t.loc[1], Y = t.loc[2], Z = t.loc[3] },
        Scale3D = { X = t.scale[1], Y = t.scale[2], Z = t.scale[3] },
    }
end

local function actorTransform(actor)
    local ok, t = pcall(function() return actor:GetTransform() end)
    if not ok or not t then return nil end
    local r, l, s = U.get(t, "Rotation"), U.get(t, "Translation"), U.get(t, "Scale3D")
    if not (r and l and s) then return nil end
    return {
        rot = { U.get(r, "X"), U.get(r, "Y"), U.get(r, "Z"), U.get(r, "W") },
        loc = { U.get(l, "X"), U.get(l, "Y"), U.get(l, "Z") },
        scale = { U.get(s, "X"), U.get(s, "Y"), U.get(s, "Z") },
    }
end

local function errText(e) return U.errText(e) end

local function step(what, fn)
    local ok, r = pcall(fn)
    if not ok then error(what .. " failed: " .. errText(r), 0) end
    return r
end

local spawnMode = nil -- remembers which spawn method works
local function spawn(className, t)
    local cls = lib(className)
    local ctx = worldCtx()
    if not (cls and U.valid(ctx)) then error("no class or world context for " .. className, 0) end
    local rot = X.quatToRotator(t.rot)
    local a
    if spawnMode ~= "deferred" then
        local ok, r = pcall(function()
            local world = ctx:GetWorld()
            return world:SpawnActor(cls, { X = t.loc[1], Y = t.loc[2], Z = t.loc[3] },
                { Pitch = rot[1], Yaw = rot[2], Roll = rot[3] })
        end)
        if ok and U.valid(r) then a = r; spawnMode = "world"
        elseif spawnMode == nil then U.log("proxy: World:SpawnActor unavailable (%s); trying deferred spawn", errText(r)) end
    end
    if not a then
        local gs = lib("/Script/Engine.Default__GameplayStatics")
        local tr = ftransform(t)
        a = step("BeginDeferredActorSpawnFromClass", function() return gs:BeginDeferredActorSpawnFromClass(ctx, cls, tr, 1, ctx) end)
        if not U.valid(a) then error("deferred spawn returned nothing", 0) end
        step("FinishSpawningActor", function() gs:FinishSpawningActor(a, tr) end)
        spawnMode = "deferred"
    end
    pcall(function() a:SetActorEnableCollision(false) end)
    pcall(function() a:SetActorScale3D({ X = t.scale[1], Y = t.scale[2], Z = t.scale[3] }) end)
    return a
end

local function setMaterials(comp, mats)
    for i, m in ipairs(mats or {}) do
        local mo = asset(m)
        if mo then pcall(function() comp:SetMaterial(i - 1, mo) end) end
    end
end

local function figmentMaterial(rec)
    local kml = lib("/Script/Engine.Default__KismetMaterialLibrary")
    local parent = asset(rec.fmat or (rec.mats and rec.mats[1]))
    if not (kml and parent) then return nil end
    local mid = kml:CreateDynamicMaterialInstance(worldCtx(), parent, FName("PsychoRandoFigment"), 0)
    if not U.valid(mid) then return nil end
    local fp = figParams or {}
    local tex, pal = asset(rec.ftex), asset(rec.fpal)
    pcall(function()
        if tex and fp.FigmentTextureParamName then mid:SetTextureParameterValue(FName(fp.FigmentTextureParamName), tex) end
        if pal and fp.PaletteTextureParamName then mid:SetTextureParameterValue(FName(fp.PaletteTextureParamName), pal) end
        if rec.fcol and fp.PaletteColorParamName then mid:SetScalarParameterValue(FName(fp.PaletteColorParamName), rec.fcol) end
        if fp.UseCustomColorParamName then mid:SetScalarParameterValue(FName(fp.UseCustomColorParamName), rec.fcustom and 1 or 0) end
        if rec.fcustom and rec.fcc and fp.CustomColorParamName then
            mid:SetVectorParameterValue(FName(fp.CustomColorParamName), { R = rec.fcc[1], G = rec.fcc[2], B = rec.fcc[3], A = rec.fcc[4] })
        end
        if fp.FigmentOpacityParamName then mid:SetScalarParameterValue(FName(fp.FigmentOpacityParamName), 1.0) end
    end)
    return mid
end

local function build(rec, t, p)
    if rec.kind == "static" or rec.kind == "figment" then
        local mesh = asset(rec.mesh)
        if not mesh then return end
        local a = spawn("/Script/Engine.StaticMeshActor", t)
        if not a then return end
        p.actors[#p.actors + 1] = U.objPath(a)
        pcall(function() a:SetMobility(2) end) -- movable, so the mesh can be changed
        local smc = U.get(a, "StaticMeshComponent")
        if not U.valid(smc) then error("StaticMeshActor has no component", 0) end
        step("SetStaticMesh", function() smc:SetStaticMesh(mesh) end)
        if rec.kind == "figment" then
            local mid = figmentMaterial(rec)
            if mid then smc:SetMaterial(0, mid) else setMaterials(smc, rec.mats) end
        else
            setMaterials(smc, rec.mats)
        end
    elseif rec.kind == "skeletal" then
        local mesh = asset(rec.mesh)
        if not mesh then return end
        local a = spawn("/Script/Engine.SkeletalMeshActor", t)
        if not a then return end
        p.actors[#p.actors + 1] = U.objPath(a)
        local skc = U.get(a, "SkeletalMeshComponent")
        if not U.valid(skc) then error("SkeletalMeshActor has no component", 0) end
        step("SetSkeletalMesh", function() skc:SetSkeletalMesh(mesh, true) end)
        setMaterials(skc, rec.mats)
        if rec.anim then
            local ac = asset(rec.anim)
            if ac then pcall(function() skc:SetAnimClass(ac) end) end
        end
    elseif rec.kind == "particle" then
        local gs = lib("/Script/Engine.Default__GameplayStatics")
        local tpl = asset(rec.tpl)
        if not (gs and tpl) then return end
        local ok, comp = pcall(function()
            return gs:SpawnEmitterAtLocation(worldCtx(), tpl,
                { X = t.loc[1], Y = t.loc[2], Z = t.loc[3] }, { Pitch = 0, Yaw = 0, Roll = 0 },
                { X = t.scale[1], Y = t.scale[2], Z = t.scale[3] }, false, 0, true)
        end)
        if ok and U.valid(comp) then p.comps[#p.comps + 1] = U.objPath(comp) end
    end
end

local buildErrors = 0
function P.setFigmentParams(fp) figParams = fp end

-- Creates the proxy for a location if the seed gives it one.
function P.make(actor, entry, key)
    if not entry or not entry.vis or proxies[key] then return end
    if U.get(actor, "bHidden") == true then return end -- collected / not shown by the game
    local base = actorTransform(actor)
    if not base then return end
    if entry.vscale then
        base.scale = { base.scale[1] * entry.vscale, base.scale[2] * entry.vscale, base.scale[3] * entry.vscale }
    end
    if entry.voff then base.loc[3] = base.loc[3] + entry.voff end
    local p = { src = U.objPath(actor), actors = {}, comps = {} }
    proxies[key] = p
    for _, rec in ipairs(entry.vis) do
        local ok, err = pcall(build, rec, X.compose(base, rec.xf or X.IDENTITY), p)
        if not ok then
            buildErrors = buildErrors + 1
            if buildErrors <= 5 then U.log("proxy build error at %s (%s): %s", key, tostring(rec.kind), errText(err)) end
        end
    end
    if #p.actors > 0 or #p.comps > 0 then
        pcall(function() actor:SetActorHiddenInGame(true) end)
    else
        proxies[key] = nil
    end
end

function P.remove(key)
    local p = proxies[key]
    if not p then return end
    proxies[key] = nil
    for _, path in ipairs(p.actors) do
        local a = U.resolve(path)
        if a then pcall(function() a:K2_DestroyActor() end) end
    end
    for _, path in ipairs(p.comps) do
        local c = U.resolve(path)
        if c then pcall(function() c:K2_DestroyComponent(c) end) end
    end
end

-- Removes proxies whose original actor is gone (collected and destroyed, or level unloaded)
function P.cleanup()
    for key, p in pairs(proxies) do
        if not U.resolve(p.src) then P.remove(key) end
    end
end

function P.clearAll()
    for key in pairs(proxies) do P.remove(key) end
end

-- Map changed: the world (and our spawned actors) is gone; just forget them
function P.forget() proxies = {} end

function P.count()
    local n = 0
    for _ in pairs(proxies) do n = n + 1 end
    return n
end

return P
