-- Motherlobe start. The app writes a save for the slot that already resumes at
-- the Motherlobe with Loboto's Labyrinth complete, so nothing has to happen in
-- game. This only reports where the slot started, to make problems visible.
local U = require("util")

local S = {}
local reported = false
local lastWhere = nil

function S.tick(seed, slot)
    if reported or not seed or seed.startAt ~= "motherlobe" then return end
    local raz = U.raz()
    if not raz then return end
    local where = (U.fullName(raz) or ""):match("/Game/Maps/([^/]+)/")
    if not where or where == lastWhere then return end
    lastWhere = where
    if where == "HQIN" then
        U.log("Start: slot %d resumed at the Motherlobe", (slot or 0) + 1)
        reported = true
    elseif where == "LOBO" then
        U.log("Start: slot %d is in Loboto's Labyrinth. This seed was made to start at the Motherlobe: " ..
            "choose Continue on the slot instead of New Game (New Game overwrites the starting save).", (slot or 0) + 1)
    end
end

function S.reset() end

return S
