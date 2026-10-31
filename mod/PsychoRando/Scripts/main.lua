-- PsychoRando: item randomizer for Psychonauts 2 (UE4SS Lua mod)
-- Installed and configured by PsychoRando.exe. Do not edit seeds by hand.
package.path = ".\\Mods\\PsychoRando\\Scripts\\?.lua;" .. package.path

local U = require("util")
local VERSION = "0.2.1"
U.log("PsychoRando %s loading", VERSION)
U.writeAll(U.ROOT .. "data/mod_version.txt", VERSION)

U.initReadyGate()

local Scan = require("scan")
local runtimeStarted = false
local function startRuntime()
    U.scanning = false
    if runtimeStarted then return end
    runtimeStarted = true
    require("runtime").start()
end
U.afterScan = startRuntime -- the randomizer takes over as soon as a scan finishes

if Scan.requested() then
    U.scanning = true
    Scan.run()
else
    startRuntime()
    -- A scan can also be requested from the app while the game is already running
    U.onReady(function()
        U.everyTick(function(t)
            if t % 40 ~= 0 or not Scan.requested() then return false end
            U.scanning = true
            U.log("Scan request detected; switching to scan mode")
            Scan.run()
            return true
        end)
    end)
end
