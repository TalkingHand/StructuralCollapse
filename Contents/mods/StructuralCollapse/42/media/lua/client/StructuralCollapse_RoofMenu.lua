-- StructuralCollapse: "Dismantle roof" in the world right-click menu (user 2026-11-10). Shown for roof pieces on
-- the clicked squares that are on the player's own level, like vanilla dismantling.
require "TimedActions/SCRoofDismantleAction"

StructuralCollapseRoofMenu = StructuralCollapseRoofMenu or {}
local M = StructuralCollapseRoofMenu

-- roof pieces on the clicked squares (and their 3x3: a roof square is often hard to click exactly) on the
-- player's level
function M.targets(playerObj, worldobjects)
    local z = math.floor(playerObj:getZ())
    local out, seen, done = {}, {}, {}
    for _, wo in ipairs(worldobjects or {}) do
        local sq = wo and wo.getSquare and wo:getSquare()
        if sq and sq:getZ() == z then
            for dx = -1, 1 do for dy = -1, 1 do
                local s = getCell():getGridSquare(sq:getX() + dx, sq:getY() + dy, z)
                if s and not done[s] then
                    done[s] = true
                    local objs = s:getObjects()
                    for i = 0, objs:size() - 1 do
                        local o = objs:get(i)
                        if not seen[o] and SCRoofDismantleAction.kindOf(o) then
                            seen[o] = true
                            out[#out + 1] = o
                        end
                    end
                end
            end end
        end
    end
    return out
end

local function nearest(playerObj, list)
    local best, bd = nil, nil
    for _, o in ipairs(list) do
        local s = o:getSquare()
        local d = math.abs(s:getX() + 0.5 - playerObj:getX()) + math.abs(s:getY() + 0.5 - playerObj:getY())
        if not bd or d < bd then best, bd = o, d end
    end
    return best
end

function M.onDismantle(playerObj, roof)
    local sq = roof:getSquare()
    if not sq then return end
    if luautils.walkAdj(playerObj, sq, true) then
        local hammer = playerObj:getInventory():getFirstTagEvalRecurse(ItemTag.HAMMER, function(i) return not i:isBroken() end)
        if hammer then ISWorldObjectContextMenu.equip(playerObj, playerObj:getPrimaryHandItem(), hammer, true) end
        ISTimedActionQueue.add(SCRoofDismantleAction:new(playerObj, roof))
    end
end

function M.onFill(playerNum, context, worldobjects, test)
    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj or playerObj:getVehicle() then return end
    local list = M.targets(playerObj, worldobjects)
    if #list == 0 then return end
    if test then return true end
    local roof = nearest(playerObj, list)
    local option = context:addOption(getText("IGUI_StructuralCollapse_DismantleRoof"), playerObj, M.onDismantle, roof)
    if not SCRoofDismantleAction.hasTool(playerObj) then
        option.notAvailable = true
        local tip = ISWorldObjectContextMenu.addToolTip()
        tip.description = getText("IGUI_StructuralCollapse_NeedHammer")
        option.toolTip = tip
    end
end

Events.OnFillWorldObjectContextMenu.Add(M.onFill)
