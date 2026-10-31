-- PsychoRando: item randomizer for Psychonauts 2 (UE4SS Lua mod)
-- Installed and configured by PsychoRando.exe. Do not edit seeds by hand.
package.path = ".\\Mods\\PsychoRando\\Scripts\\?.lua;" .. package.path

local U = require("util")
local VERSION = "0.1.2"
U.log("PsychoRando %s loading", VERSION)
U.writeAll(U.ROOT .. "data/mod_version.txt", VERSION)

U.initReadyGate()

local Scan = require("scan")
if Scan.requested() then
    U.scanning = true
    Scan.run()
else
    require("runtime").start()
    -- A scan can also be requested from the app while the game is already running
    U.onReady(function()
        LoopAsync(2000, function()
            if not Scan.requested() then return false end
            U.scanning = true
            U.log("Scan request detected; switching to scan mode")
            Scan.run()
            return true
        end)
    end)
end
