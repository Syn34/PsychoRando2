-- PsychoRando: item randomizer for Psychonauts 2 (UE4SS Lua mod)
-- Installed and configured by PsychoRando.exe. Do not edit seeds by hand.
package.path = ".\\Mods\\PsychoRando\\Scripts\\?.lua;" .. package.path

local U = require("util")
local VERSION = "0.1.1"
U.log("PsychoRando %s loading", VERSION)
U.writeAll(U.ROOT .. "data/mod_version.txt", VERSION)

U.initReadyGate()

local Scan = require("scan")
if Scan.requested() then
    Scan.run()
else
    require("runtime").start()
end
