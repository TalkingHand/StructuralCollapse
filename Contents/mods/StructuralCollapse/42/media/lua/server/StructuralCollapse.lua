-- Structural Collapse (prototype): when no wall, pillar, door/window frame or staircase is left under an
-- upper floor group, the group and everything above it drop one level. Design: pz_mod/_devnotes/StructuralCollapse.
-- Runs where the world is authoritative: single player and the dedicated server (not on MP clients).
--
-- Flow: OnObjectAboutToBeRemoved (vanilla fires it for every removal, SP and server) -> if the object is a
-- support, queue the floor level above -> next OnTick: floor-group BFS from there, stopping at the first
-- supported tile -> a group with no support drops one level, bottom level first, top level last.

StructuralCollapse = StructuralCollapse or {}
local SC = StructuralCollapse

SC.PUSH_RADIUS = 5       -- tiles searched for a free spot for furniture that lands on furniture
SC.DROP_CHANCE = 50      -- % per build material returned when a player-built object breaks (vanilla onDestroy: 50)
SC.queue = SC.queue or {}
SC.busy = false          -- our own removals also fire OnObjectAboutToBeRemoved
SC.stats = SC.stats or { checks = 0, collapses = 0 }

local function log(m) print("[StructuralCollapse] " .. m) end
SC.log = log

local function key(x, y, z) return x .. "," .. y .. "," .. z end

-- ---------------------------------------------------------------- object classification

local function props(obj)
    return obj and obj:getProperties()
end

local function has(p, flag)
    return p ~= nil and p:has(flag)
end

local STAIRS = {}
local function isStairs(obj)
    if not STAIRS.ready then
        STAIRS[IsoObjectType.stairsTW] = true; STAIRS[IsoObjectType.stairsMW] = true; STAIRS[IsoObjectType.stairsBW] = true
        STAIRS[IsoObjectType.stairsTN] = true; STAIRS[IsoObjectType.stairsMN] = true; STAIRS[IsoObjectType.stairsBN] = true
        STAIRS.ready = true
    end
    return obj:getType() ~= nil and STAIRS[obj:getType()] == true
end
SC.isStairs = isStairs

-- posts by sprite (no WallSE flag on these). Map check 2026-11-10 (_devnotes/StructuralCollapse/mapcheck.md Q5):
-- log posts under hunting stands, cabins and gazebos, scaffold frames, industrial frames, pylon feet, stair posts.
local POLE_SPRITES = { walls_exterior_wooden_01_27 = true, carpentry_02_94 = true, carpentry_02_95 = true,
    fixtures_stairs_01_14 = true, fixtures_railings_01_78 = true, industry_01_28 = true, industry_01_29 = true,
    industry_01_30 = true, industry_01_49 = true, electricity_pylon_176 = true, electricity_pylon_181 = true }
for _, i in ipairs({ 3, 7, 11, 15, 16, 17, 18, 19, 43 }) do POLE_SPRITES["carpentry_03_" .. i] = true end
for i = 16, 26 do POLE_SPRITES["construction_01_" .. i] = true end
for i = 48, 55 do POLE_SPRITES["construction_01_" .. i] = true end

-- an object's sprite name (vanilla reads it the same way: objects made with IsoObject.new(sq, name) keep it
-- in getSpriteName while their sprite has none)
local function spriteNameOf(o)
    if not o then return nil end
    local sp = o:getSprite()
    return (sp and sp:getName()) or o:getSpriteName()
end
SC.spriteNameOf = spriteNameOf

local function isPole(obj)
    local p = props(obj)
    if has(p, IsoFlagType.WallSE) then return true end
    local n = spriteNameOf(obj)
    if n and POLE_SPRITES[n] then return true end
    -- SpriteConfig has no public isPole() in 42.21 (the script flag isPole = true is not readable here),
    -- so B42 poles are matched by sprite above
    return false
end

-- full-height wall on the N and/or W edge of its square (walls, door frames, window frames)
local function wallEdges(obj)
    local p = props(obj)
    if not p or has(p, IsoFlagType.halfheight) then return false, false end
    -- garage and truck doors (walls_garage_01/02_*, industry_trucks_01_32..37) are IsoDoors whose tiles carry
    -- WallN/WallW: a whole wall face, so they count as walls (decided 2026-11-10). Ordinary doors don't have those.
    local garage = instanceof(obj, "IsoDoor")
        and (has(p, IsoFlagType.WallN) or has(p, IsoFlagType.WallW) or has(p, IsoFlagType.WallNW))
    if garage then
        local nw = has(p, IsoFlagType.WallNW)
        return nw or has(p, IsoFlagType.WallN), nw or has(p, IsoFlagType.WallW)
    end
    if instanceof(obj, "IsoDoor") or instanceof(obj, "IsoWindow") or instanceof(obj, "IsoBarricade")
        or instanceof(obj, "IsoCurtain") then
        return false, false
    end
    if instanceof(obj, "IsoThumpable") and (obj:isDoor() or obj:isWindow()) then return false, false end
    local nw = has(p, IsoFlagType.WallNW)
    local n = nw or has(p, IsoFlagType.WallN) or has(p, IsoFlagType.cutN)
    local w = nw or has(p, IsoFlagType.WallW) or has(p, IsoFlagType.cutW)
    return n, w
end
SC.wallEdges = wallEdges

function SC.isSupport(obj)
    if obj == nil or instanceof(obj, "IsoWorldInventoryObject") then return false end
    local n, w = wallEdges(obj)
    return n or w or isStairs(obj) or isPole(obj)
end

-- which edge an object sits on: "N", "W", "NW", "SE" (corner post) or nil (whole square)
local function edgeOf(obj)
    if instanceof(obj, "IsoWorldInventoryObject") then return nil end
    local n, w = wallEdges(obj)
    if n and w then return "NW" end
    if n then return "N" end
    if w then return "W" end
    local p = props(obj)
    if has(p, IsoFlagType.WallSE) then return "SE" end
    if instanceof(obj, "IsoDoor") or instanceof(obj, "IsoWindow") or instanceof(obj, "IsoCurtain")
        or (instanceof(obj, "IsoThumpable") and (obj:isDoor() or obj:isWindow())) then
        return obj:getNorth() and "N" or "W"
    end
    if instanceof(obj, "IsoBarricade") then
        -- no direction getter: find the door/window on this square whose same-square barricade it is
        local sq = obj:getSquare()
        local sp = sq and sq:getSpecialObjects()
        for i = 0, (sp and sp:size() or 0) - 1 do
            local o = sp:get(i)
            if o ~= obj and o.getBarricadeOnSameSquare and o:getBarricadeOnSameSquare() == obj then
                return o:getNorth() and "N" or "W"
            end
        end
        return nil   -- barricades on the outside square (facing S/E) move with that square
    end
    if has(p, IsoFlagType.attachedN) or has(p, IsoFlagType.WindowN) or has(p, IsoFlagType.HoppableN)
        or has(p, IsoFlagType.TallHoppableN) or has(p, IsoFlagType.DoorWallN) then return "N" end
    if has(p, IsoFlagType.attachedW) or has(p, IsoFlagType.WindowW) or has(p, IsoFlagType.HoppableW)
        or has(p, IsoFlagType.TallHoppableW) or has(p, IsoFlagType.DoorWallW) then return "W" end
    return nil
end
SC.edgeOf = edgeOf

-- a floor: solidfloor, not an edge thing, not stairs, and not a flat roof (solidfloor + RoofGroup: those are judged
-- as roof pieces; counting them as floors left 385 vanilla groups with no support, map check 2026-11-10)
local function isFloorObj(obj)
    if instanceof(obj, "IsoWorldInventoryObject") then return false end
    local p = props(obj)
    return has(p, IsoFlagType.solidfloor) and edgeOf(obj) == nil and not isStairs(obj)
        and not (p ~= nil and p:has("RoofGroup"))
end

SC.isFloorObj = isFloorObj

-- furniture that cannot share a tile with other furniture
local function isFurniture(obj)
    if instanceof(obj, "IsoWorldInventoryObject") or isFloorObj(obj) or edgeOf(obj) ~= nil or isStairs(obj) then
        return false
    end
    if obj:isTableTopObject() then return false end   -- rides on the furniture below it
    local p = props(obj)
    return has(p, IsoFlagType.solid) or has(p, IsoFlagType.solidtrans) or obj:isTableSurface()
        or obj:getContainerCount() > 0
end
SC.isFurniture = isFurniture

-- ---------------------------------------------------------------- support test

local cell = function() return getCell() end

local function sqAt(x, y, z) return cell():getGridSquare(x, y, z) end

local function hasEdgeWall(sq, north)
    if not sq then return false end
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local n, w = wallEdges(objs:get(i))
        if (north and n) or ((not north) and w) then return true end
    end
    return false
end

local function hasSupportObj(sq)
    if not sq then return false end
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        local n, w = wallEdges(o)
        if n or w or isStairs(o) or isPole(o) then return true end
    end
    return false
end

-- floor tile (x,y,z) is held up by a support on level z-1 on its square or its four edges/corners
function SC.tileSupported(x, y, z)
    if z <= 0 then return true end
    local zb = z - 1
    if hasSupportObj(sqAt(x, y, zb)) then return true end
    if hasEdgeWall(sqAt(x + 1, y, zb), false) then return true end   -- east edge = W wall of the east square
    if hasEdgeWall(sqAt(x, y + 1, zb), true) then return true end    -- south edge = N wall of the south square
    for _, d in ipairs({ { 1, 0 }, { 0, 1 }, { 1, 1 } }) do               -- posts on the other corners
        local s = sqAt(x + d[1], y + d[2], zb)
        if s then
            local objs = s:getObjects()
            for i = 0, objs:size() - 1 do
                if isPole(objs:get(i)) then return true end
            end
        end
    end
    return false
end

local function isGroupTile(sq)
    if not sq then return false end
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        if isFloorObj(o) or isStairs(o) then return true end
    end
    return false
end
SC.isGroupTile = isGroupTile

-- Structure search (2026-11-10, user's definition). On one level z >= 1, a structure is what touches:
--   floor-floor   floor/stairs squares side by side (4 directions)
--   wall-wall     wall segments sharing an end point (straight on, or at a right angle at a corner);
--                 parallel walls one square apart do NOT touch
--   floor-wall    a wall standing on one of the four edges of a floor square
--   post-wall     a post (pole) on a square touches the walls meeting at that square's corners, and its floor
-- A structure stays up when ANY of its parts rests on something on level z-1 ("almost no ground floor" may hold
-- an upper floor; "no ground floor at all" never does):
--   floor square  SC.tileSupported (a wall, post or staircase under the square or its edges)
--   wall segment  a wall on the same edge on z-1, or a post on z-1 at either end
--   post          a post on the same square on z-1, or a wall on z-1 on that square's edges
-- Nodes: { k = "f" (floor) | "N" | "W" (wall on the north / west edge of square x,y) | "P" (post) | "r" (roof), x, y }
-- Resumable over ticks: SC.bfsStart / SC.bfsStep (a big structure is judged in pieces).

local function wallOn(x, y, z, north)
    local s = sqAt(x, y, z)
    if not s then return false end
    local objs = s:getObjects()
    for i = 0, objs:size() - 1 do
        local n, w = wallEdges(objs:get(i))
        if (north and n) or ((not north) and w) then return true end
    end
    return false
end

local function poleOn(x, y, z)
    local s = sqAt(x, y, z)
    if not s then return false end
    local objs = s:getObjects()
    for i = 0, objs:size() - 1 do
        if isPole(objs:get(i)) then return true end
    end
    return false
end

-- the nodes standing on square (x,y,z)
local function nodesOn(x, y, z, roof)
    local s = sqAt(x, y, z)
    local out = {}
    if not s then return out end
    if roof then
        if SC.hasRoof(s) then out[1] = { k = "r", x = x, y = y } end
        return out
    end
    if isGroupTile(s) then out[#out + 1] = { k = "f", x = x, y = y } end
    if wallOn(x, y, z, true) then out[#out + 1] = { k = "N", x = x, y = y } end
    if wallOn(x, y, z, false) then out[#out + 1] = { k = "W", x = x, y = y } end
    if poleOn(x, y, z) then out[#out + 1] = { k = "P", x = x, y = y } end
    return out
end

local function exists(n, z)
    if n.k == "f" then return isGroupTile(sqAt(n.x, n.y, z)) end
    if n.k == "N" then return wallOn(n.x, n.y, z, true) end
    if n.k == "W" then return wallOn(n.x, n.y, z, false) end
    if n.k == "P" then return poleOn(n.x, n.y, z) end
    if n.k == "r" then return SC.hasRoof(sqAt(n.x, n.y, z)) end
    return false
end

-- walls ending at corner point (px,py) (point = north-west corner of square px,py), and posts around it
local function atPoint(list, px, py)
    list[#list + 1] = { k = "N", x = px, y = py }       -- runs east from the point
    list[#list + 1] = { k = "N", x = px - 1, y = py }   -- runs west to the point
    list[#list + 1] = { k = "W", x = px, y = py }       -- runs south from the point
    list[#list + 1] = { k = "W", x = px, y = py - 1 }   -- runs north to the point
    list[#list + 1] = { k = "P", x = px, y = py }
    list[#list + 1] = { k = "P", x = px - 1, y = py }
    list[#list + 1] = { k = "P", x = px, y = py - 1 }
    list[#list + 1] = { k = "P", x = px - 1, y = py - 1 }
end

-- candidate neighbours (existence is checked by the caller)
local function candidates(n)
    local c, x, y = {}, n.x, n.y
    if n.k == "r" then
        c = { { k = "r", x = x + 1, y = y }, { k = "r", x = x - 1, y = y }, { k = "r", x = x, y = y + 1 }, { k = "r", x = x, y = y - 1 } }
    elseif n.k == "f" then
        c = { { k = "f", x = x + 1, y = y }, { k = "f", x = x - 1, y = y }, { k = "f", x = x, y = y + 1 }, { k = "f", x = x, y = y - 1 },
            { k = "N", x = x, y = y }, { k = "W", x = x, y = y }, { k = "N", x = x, y = y + 1 }, { k = "W", x = x + 1, y = y },
            { k = "P", x = x, y = y } }
    elseif n.k == "N" then
        atPoint(c, x, y); atPoint(c, x + 1, y)
        c[#c + 1] = { k = "f", x = x, y = y }; c[#c + 1] = { k = "f", x = x, y = y - 1 }
    elseif n.k == "W" then
        atPoint(c, x, y); atPoint(c, x, y + 1)
        c[#c + 1] = { k = "f", x = x, y = y }; c[#c + 1] = { k = "f", x = x - 1, y = y }
    elseif n.k == "P" then
        atPoint(c, x, y); atPoint(c, x + 1, y); atPoint(c, x, y + 1); atPoint(c, x + 1, y + 1)
        c[#c + 1] = { k = "f", x = x, y = y }
    end
    return c
end

local function nodeSupported(n, z)
    if n.k == "r" then return SC.roofSupported(n.x, n.y, z) end
    if z <= 0 then return true end
    local zb = z - 1
    if n.k == "f" then return SC.tileSupported(n.x, n.y, z) end
    if n.k == "N" then
        return wallOn(n.x, n.y, zb, true) or poleOn(n.x, n.y, zb) or poleOn(n.x - 1, n.y, zb)
            or poleOn(n.x, n.y - 1, zb) or poleOn(n.x - 1, n.y - 1, zb) or poleOn(n.x + 1, n.y, zb)
            or poleOn(n.x + 1, n.y - 1, zb)
    end
    if n.k == "W" then
        return wallOn(n.x, n.y, zb, false) or poleOn(n.x, n.y, zb) or poleOn(n.x - 1, n.y, zb)
            or poleOn(n.x, n.y - 1, zb) or poleOn(n.x - 1, n.y - 1, zb) or poleOn(n.x, n.y + 1, zb)
            or poleOn(n.x - 1, n.y + 1, zb)
    end
    if n.k == "P" then
        return poleOn(n.x, n.y, zb) or wallOn(n.x, n.y, zb, true) or wallOn(n.x, n.y, zb, false)
            or wallOn(n.x + 1, n.y, zb, false) or wallOn(n.x, n.y + 1, zb, true)
    end
    return false
end

local function nk(pre, n, z) return pre .. n.k .. "," .. n.x .. "," .. n.y .. "," .. z end

-- start a search at square (x,y,z): nil when nothing of that kind stands there or it's all settled
function SC.bfsStart(x, y, z, held, roof)
    local pre = roof and "r" or ""
    local start = nil
    for _, n in ipairs(nodesOn(x, y, z, roof)) do
        if not held[nk(pre, n, z)] then start = n; break end
    end
    if not start then return nil end
    return { z = z, roof = roof, held = held, pre = pre, seen = { [nk(pre, start, z)] = true },
        nodes = {}, tiles = {}, queue = { start }, head = 1 }
end

local function bfsFinish(st, res)
    for k in pairs(st.seen) do st.held[k] = true end
    st.result = res
    return res
end

-- nil while unfinished; else "supported" | "unloaded" | nodes (the structure, no part supported)
function SC.bfsStep(st, deadline)
    local z, pre, held, seen, queue = st.z, st.pre, st.held, st.seen, st.queue
    local steps = 0
    while st.head <= #queue do
        steps = steps + 1
        if steps % 16 == 0 and deadline and getTimestampMs() >= deadline then return nil end
        local n = queue[st.head]; st.head = st.head + 1
        st.nodes[#st.nodes + 1] = n
        if held[nk(pre, n, z)] and st.head > 2 then return bfsFinish(st, "supported") end
        if nodeSupported(n, z) then return bfsFinish(st, "supported") end
        for _, c in ipairs(candidates(n)) do
            local k = nk(pre, c, z)
            if not seen[k] then
                if sqAt(c.x, c.y, z) == nil and cell():getChunkForGridSquare(c.x, c.y, z) == nil then
                    -- not loaded: the structure can't be seen whole; judged again later
                    return bfsFinish(st, "unloaded")
                end
                if exists(c, z) then
                    seen[k] = true
                    queue[#queue + 1] = c
                end
            end
        end
    end
    return bfsFinish(st, st.nodes)
end

-- squares of a node list (one per square)
function SC.nodeSquares(nodes, z)
    local seen, out = {}, {}
    for _, n in ipairs(nodes) do
        local k = n.x .. "," .. n.y
        if not seen[k] then
            seen[k] = true
            local s = sqAt(n.x, n.y, z)
            if s then out[#out + 1] = s end
        end
    end
    return out
end

-- one-shot search (tests, tools): "nofloor" | "supported" | "unloaded" | nodes, visited
function SC.findGroup(x, y, z, held, roof)
    local st = SC.bfsStart(x, y, z, held or {}, roof)
    if not st then return "nofloor" end
    local res = SC.bfsStep(st, nil)
    return res, #st.nodes
end

-- ---------------------------------------------------------------- breaking objects (with drops)

local function dropItem(sq, fullType)
    sq:AddWorldInventoryItem(fullType, ZombRandFloat(0.1, 0.9), ZombRandFloat(0.1, 0.9), 0)
end

local function scrapDrops(obj, sq)
    -- player-built: the materials it was built from (vanilla ISBuildingObject.onDestroy: 50% each)
    if instanceof(obj, "IsoThumpable") and obj:hasBuildMaterials() then
        for fullType, v in pairs(obj:getBuildMaterials()) do
            for _ = 1, (tonumber(v) or 0) do
                if ZombRand(100) < SC.DROP_CHANCE then dropItem(sq, fullType) end
            end
        end
        return
    end
    -- map furniture: vanilla scrap table for the tile's materials, at the base chance (no character skill)
    local ok, mp = pcall(ISMoveableSpriteProps.new, obj:getSprite())
    if not ok or not mp or not mp.canScrap then return end
    local defs = ISMoveableDefinitions:getInstance()
    for _, mat in ipairs({ mp.material, mp.material2, mp.material3 }) do
        local def = mat and defs.getScrapDefinition(mat)
        if def then
            local list = (def.returnItemsStatic and #def.returnItemsStatic > 0) and def.returnItemsStatic or def.returnItems
            for _, v in ipairs(list or {}) do
                for _ = 1, (v.maxAmount or 1) do
                    if ZombRand(100) < (v.chancePerRoll or 50) then dropItem(sq, v.returnItem) end
                end
            end
        end
    end
end

local function removeObj(obj)
    local sq = obj:getSquare()
    if not sq or not sq:getObjects():contains(obj) then return end
    SC.busy = true
    local ok, err = pcall(function() sq:transmitRemoveItemFromSquare(obj, false) end)
    SC.busy = false
    if not ok then log("remove failed " .. tostring(obj) .. ": " .. tostring(err)) end
end

-- container contents onto square sq (vanilla IsoObject.Thump does the same when a zombie breaks furniture)
local function dumpInto(obj, sq)
    for i = 0, obj:getContainerCount() - 1 do
        local c = obj:getContainerByIndex(i)
        local items = c:getItems()
        local list = {}
        for j = 0, items:size() - 1 do list[#list + 1] = items:get(j) end
        c:removeItemsFromProcessItems()
        c:removeAllItems()
        for _, it in ipairs(list) do
            sq:AddWorldInventoryItem(it, ZombRandFloat(0.1, 0.9), ZombRandFloat(0.1, 0.9), 0, true)
        end
    end
end

-- break an object: contents and scrap fall on dropSq (default: where it stands)
function SC.breakObj(obj, why, dropSq)
    local sq = obj:getSquare()
    if not sq then return end
    local parts = { obj }
    if isStairs(obj) and buildUtil and buildUtil.getStairObjects then
        parts = buildUtil.getStairObjects(obj, true)
    else
        local grid = ArrayList.new()
        obj:getSpriteGridObjectsIncludingSelf(grid)
        if grid:size() > 1 then
            parts = {}
            for i = 0, grid:size() - 1 do parts[#parts + 1] = grid:get(i) end
        end
    end
    for _, o in ipairs(parts) do
        local s = o:getSquare()
        if s then
            -- a falling part drops at the same offset on the level it falls to
            local d = s
            if dropSq then
                d = getCell():getOrCreateGridSquare(dropSq:getX() + s:getX() - sq:getX(),
                    dropSq:getY() + s:getY() - sq:getY(), dropSq:getZ())
            end
            dumpInto(o, d)
            scrapDrops(o, d)
            SC.stats.broken = (SC.stats.broken or 0) + 1
            log("break " .. tostring(spriteNameOf(o)) .. " at " .. key(s:getX(), s:getY(), s:getZ()) .. " (" .. why .. ")")
            removeObj(o)
        end
    end
end

-- ---------------------------------------------------------------- moving objects

local function placeObj(obj, dst, special, index)
    obj:setSquare(dst)
    for i = 0, obj:getContainerCount() - 1 do
        obj:getContainerByIndex(i):setSourceGrid(dst)
    end
    if special then
        if index then dst:AddSpecialObject(obj, index) else dst:AddSpecialObject(obj) end
    else
        if index then dst:AddTileObject(obj, index) else dst:AddTileObject(obj) end
    end
    if isServer() then obj:transmitCompleteItemToClients() end
    triggerEvent("OnObjectAdded", obj)   -- vanilla does this after placing (global object systems re-register)
end

-- move one object to dst (same instance: containers, modData and components come along)
function SC.moveObj(obj, dst, index)
    local src = obj:getSquare()
    if not src or not dst then return false end
    if instanceof(obj, "IsoWorldInventoryObject") then
        local item = obj:getItem()
        local ox, oy, oz = obj:getOffX(), obj:getOffY(), obj:getOffZ()
        removeObj(obj)
        if item then
            item:setWorldItem(nil)
            dst:AddWorldInventoryItem(item, ox, oy, oz, true)
        end
        return true
    end
    local special = src:getSpecialObjects():contains(obj)
    removeObj(obj)
    if src:getObjects():contains(obj) then return false end
    placeObj(obj, dst, special, index)
    return true
end

-- objects on square sq that share edge e ("N"/"W") — walls, frames, doors, windows, decorations
local function edgeObjects(sq, e)
    local out = {}
    if not sq then return out end
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        local oe = edgeOf(o)
        if oe == e or oe == "NW" then out[#out + 1] = o end
    end
    return out
end

local function hasWallOnEdge(sq, e)
    for _, o in ipairs(edgeObjects(sq, e)) do
        local n, w = wallEdges(o)
        if (e == "N" and n) or (e == "W" and w) then return true end
    end
    return false
end

local function furnitureOn(sq)
    local out = {}
    if not sq then return out end
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        if isFurniture(objs:get(i)) then out[#out + 1] = objs:get(i) end
    end
    return out
end

local function stairsOn(sq)
    if not sq then return nil end
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        if isStairs(objs:get(i)) then return objs:get(i) end
    end
    return nil
end

-- a vehicle on square sq's level whose centre is within 2.5 squares (a car covers about 2x5 squares).
-- getVehicleContainer is empty on most squares a car covers (in-game 2026-11-10), so the cell's vehicles are
-- looked at: a java Set in 42.22, copied into an ArrayList once per tick to index it
local function vehicleAt(sq)
    if not sq then return nil end
    local v = sq:getVehicleContainer()
    if v then return v end
    if SC.vehicleTick ~= SC.tickNo or not SC.vehicleList then
        SC.vehicleTick, SC.vehicleList = SC.tickNo, ArrayList.new(cell():getVehicles())
    end
    local list = SC.vehicleList
    local cx, cy = sq:getX() + 0.5, sq:getY() + 0.5
    for i = 0, list:size() - 1 do
        local w = list:get(i)
        if w and math.floor(w:getZ()) == sq:getZ() and math.abs(w:getX() - cx) < 2.5 and math.abs(w:getY() - cy) < 2.5 then
            return w
        end
    end
    return nil
end
SC.vehicleAt = vehicleAt

local function freeForFurniture(sq, reserved)
    if not sq or reserved[sq] then return false end
    if vehicleAt(sq) then return false end
    if stairsOn(sq) then return false end
    local floor = false
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        if isFurniture(o) then return false end
        if isFloorObj(o) then floor = true end
    end
    return floor
end

-- nearest spot (same level, not through walls/doors) where every part of a furniture unit fits.
-- offsets: list of {dx, dy} of the unit's parts relative to the anchor part
local function findSpot(start, offsets, reserved)
    local z = start:getZ()
    local function fits(a)
        for _, off in ipairs(offsets) do
            if not freeForFurniture(sqAt(a:getX() + off[1], a:getY() + off[2], z), reserved) then return false end
        end
        return true
    end
    local seen, queue, head = { [start] = 0 }, { start }, 1
    while head <= #queue do
        local s = queue[head]; head = head + 1
        if fits(s) then return s end
        local dist = seen[s]
        if dist < SC.PUSH_RADIUS then
            for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
                local n = sqAt(s:getX() + d[1], s:getY() + d[2], z)
                if n and seen[n] == nil and not s:isBlockedTo(n) then
                    seen[n] = dist + 1
                    queue[#queue + 1] = n
                end
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------- collapse

-- Columns that move: every square of the footprint (all objects), plus the squares east/south of it that
-- carry the footprint's east/south walls on their W/N edge, and the SE corner posts.
-- Columns that move, from the structure's nodes: a floor square moves whole (every object, every level above);
-- a wall moves its edge (walls, frames, doors, windows, decorations on it) and the decorations on its other face
-- (on the neighbouring square: attachedS for a north wall, attachedE for a west wall); a post moves its posts.
-- A floor square also takes the walls on its east/south edges (they sit on the neighbouring squares).
local function buildColumns(nodes)
    local foot = {}
    for _, n in ipairs(nodes) do if n.k == "f" then foot[key(n.x, n.y, 0)] = true end end
    local cols = {}
    local function add(x, y, mode)
        local k = key(x, y, 0)
        if foot[k] then mode = "all" end
        local c = cols[k]
        if not c then cols[k] = { x = x, y = y, modes = { [mode] = true } }
        else c.modes[mode] = true end
    end
    for _, n in ipairs(nodes) do
        local x, y = n.x, n.y
        if n.k == "f" then
            add(x, y, "all")
            add(x + 1, y, "W")
            add(x, y + 1, "N")
            add(x + 1, y + 1, "SE")
            add(x, y - 1, "aS")
            add(x - 1, y, "aE")
        elseif n.k == "N" then
            add(x, y, "N")
            add(x, y - 1, "aS")
        elseif n.k == "W" then
            add(x, y, "W")
            add(x - 1, y, "aE")
        elseif n.k == "P" then
            add(x, y, "pole")
        end
    end
    local list = {}
    for _, c in pairs(cols) do list[#list + 1] = c end
    return list
end

-- sprite sheet of an object ("industry_02" for "industry_02_96")
local function sheetOf(o)
    local n = spriteNameOf(o)
    return n and (string.match(n, "^(.*)_%d+$") or n) or nil
end

-- which objects of square sq move, by column mode
local function columnObjects(sq, c)
    local out = {}
    if not sq then return out end
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        if c.modes.all then
            out[#out + 1] = o
        elseif c.modes.free then
            if SC.isFreeObj(o) and (c.sheets == nil or c.sheets[sheetOf(o)]) then out[#out + 1] = o end
        elseif c.modes.loose then
            -- what stood on a removed floor tile: everything but walls/frames/edge things and stairs
            if edgeOf(o) == nil and not isStairs(o) and not isFloorObj(o) then out[#out + 1] = o end
        else
            local e = edgeOf(o)
            if (c.modes.W and (e == "W" or e == "NW")) or (c.modes.N and (e == "N" or e == "NW"))
                or (c.modes.SE and e == "SE")
                or (c.modes.pole and isPole(o))
                or (c.modes.aS and has(props(o), IsoFlagType.attachedS))
                or (c.modes.aE and has(props(o), IsoFlagType.attachedE))
                or (c.modes.roof and c.roofLevels and c.roofLevels[sq:getZ()] and SC.onRoofLayer(o)) then
                out[#out + 1] = o
            end
        end
    end
    return out
end

local function order(o)
    if isFloorObj(o) then return 1 end
    if isStairs(o) then return 2 end
    local e = edgeOf(o)
    if e ~= nil then
        local n, w = wallEdges(o)
        return (n or w) and 3 or 4
    end
    if isFurniture(o) then return 5 end
    if instanceof(o, "IsoWorldInventoryObject") then return 7 end
    return 6
end

-- A collapse is a job: the judgment is done at once (cheap), the moving is spread over ticks within
-- SC.TICK_BUDGET_MS. Levels still go strictly bottom-up (a level is planned only after the one below is done).
-- While a job runs, queued support checks wait, so nothing judges a half-moved group.
-- Per-tick budget, kept well under a frame (16.7 ms at 60 fps): 2 ms. An entry is not started when the running
-- average cost of one entry would take the tick past the budget, so a tick overruns only when a single entry
-- is heavier than the whole budget. The heaviest entry (a floor: break the one below + move + neighbour
-- recalcs) is done as two steps in separate ticks.
SC.TICK_BUDGET_MS = 2
SC.jobs = SC.jobs or {}

-- ---------------------------------------------------------------- characters under a falling floor
-- A floor (or furniture) landing on a square hits the characters standing there on the head, once per job.
SC.HEAD_DAMAGE = 25        -- head body-part damage before helmet defense
SC.HEAD_CUT_MIN = 10       -- damage after defense at or above this also cuts (bleeds)
-- zombie health (IsoZombie, 42.22.2) by sandbox toughness: tough 3.5-3.8, normal 1.8-2.1, fragile 0.5-0.8,
-- random 0.5-3.8. 3.7 kills all on normal and fragile, about 99% on random and about 2/3 on tough (the rest are
-- knocked down) (user 2026-11-10)
SC.ZOMBIE_DAMAGE = 3.7     -- health taken from a zombie; one that survives is knocked down
SC.ANIMAL_DAMAGE = 0.6     -- health taken from an animal
SC.VEHICLE_DAMAGE = 15     -- condition taken from every part of a vehicle under a falling floor

local HEAD_INDEX = nil
local function headIndex()
    if HEAD_INDEX == nil then HEAD_INDEX = BodyPartType.ToIndex(BodyPartType.Head) end
    return HEAD_INDEX
end

function SC.hitBelow(job, sq, what)
    if not sq then return end
    local movers = sq:getMovingObjects()
    for i = movers:size() - 1, 0, -1 do
        local c = movers:get(i)
        if c and instanceof(c, "IsoGameCharacter") and not job.hit[c] and not c:isDead() then
            job.hit[c] = true
            job.report.hit = job.report.hit + 1
            if instanceof(c, "IsoAnimal") then
                -- IsoAnimal extends IsoPlayer: handle it first, like a zombie (health only)
                c:setHealth(math.max(0, c:getHealth() - SC.ANIMAL_DAMAGE))
            elseif instanceof(c, "IsoPlayer") then
                -- helmet: head scratch defense in %, the same number the protection panel shows
                local def = 0
                local okD, d = pcall(function() return c:getBodyPartClothingDefense(headIndex(), false, false) end)
                if okD and d then def = math.max(0, math.min(100, d)) end
                local dmg = SC.HEAD_DAMAGE * (1 - def / 100)
                local head = c:getBodyDamage():getBodyPart(BodyPartType.Head)
                head:AddDamage(dmg)
                if dmg >= SC.HEAD_CUT_MIN then head:setCut(true) end
                log(string.format("hit %s on the head by %s: damage %.1f (helmet %d%%)", tostring(c:getUsername()), what, dmg, def))
            elseif instanceof(c, "IsoZombie") then
                c:setHealth(c:getHealth() - SC.ZOMBIE_DAMAGE)
                if c:getHealth() <= 0 then c:Kill(nil) else c:knockDown(true) end
            end
        end
    end
    -- a vehicle standing there: every part loses condition
    local v = vehicleAt(sq)
    if v and not job.hit[v] then
        job.hit[v] = true
        job.report.hit = job.report.hit + 1
        for i = 0, v:getPartCount() - 1 do
            local part = v:getPartByIndex(i)
            if part and part:getCondition() > 0 then
                part:setCondition(math.max(0, part:getCondition() - SC.VEHICLE_DAMAGE))
                v:transmitPartCondition(part)
            end
        end
        log("hit vehicle " .. tostring(v:getScriptName()) .. " by " .. what .. ": parts -" .. SC.VEHICLE_DAMAGE)
    end
end

-- ---------------------------------------------------------------- corpses, rooms, saves

-- corpses on sq fall `drop` levels (vanilla path: IsoDeadBody:becomeCorpseItem, then tryAddCorpseToWorld,
-- which also sends the corpse to clients on a server)
function SC.dropBodies(sq, drop, report)
    if not sq then return end
    local list = sq:getDeadBodys()
    if not list or list:size() == 0 then return end
    local bodies = {}
    for i = 0, list:size() - 1 do bodies[#bodies + 1] = list:get(i) end
    local dst = cell():getOrCreateGridSquare(sq:getX(), sq:getY(), sq:getZ() - drop)
    for _, b in ipairs(bodies) do
        local ox, oy = b:getX() - sq:getX(), b:getY() - sq:getY()
        local item = b:becomeCorpseItem(false)
        if item then
            SC.busy = true
            local ok, err = pcall(function() dst:tryAddCorpseToWorld(item, ox, oy, true) end)
            SC.busy = false
            if ok then report.bodies = report.bodies + 1 else log("corpse drop failed: " .. tostring(err)) end
        end
    end
end

-- Global mod data (saved with the world): rooms cleared from map squares (the game rebuilds square rooms from
-- the map files on every load, so they are cleared again as their squares load), and collapses still moving
-- when the game was saved (judged again on load, which finishes them).
local function md()
    if not SC.data then
        SC.data = ModData.getOrCreate("StructuralCollapse")
        SC.data.rooms = SC.data.rooms or {}
        SC.data.jobs = SC.data.jobs or {}
    end
    return SC.data
end

function SC.clearRoom(sq)
    if not sq or sq:getRoomID() == -1 or isGroupTile(sq) then return end
    sq:setRoomID(-1)
    sq:RecalcProperties()   -- no room and no roof -> exterior (rain, light)
    local rooms = md().rooms
    local x, y = sq:getX(), sq:getY()
    rooms[x] = rooms[x] or {}
    rooms[x][y] = rooms[x][y] or {}
    rooms[x][y][sq:getZ()] = true
end

local function onLoadGridsquare(sq)
    local rooms = SC.data and SC.data.rooms
    if not rooms then return end
    local rx = rooms[sq:getX()]
    local ry = rx and rx[sq:getY()]
    if ry and ry[sq:getZ()] and sq:getRoomID() ~= -1 then
        sq:setRoomID(-1)
        sq:RecalcProperties()
    end
end

function SC.persistJob(job, start)
    local jobs = md().jobs
    if start then
        local xs = {}
        for _, t in ipairs(job.tiles) do xs[#xs + 1] = t:getX(); xs[#xs + 1] = t:getY() end
        job.persistKey = key(job.tiles[1]:getX(), job.tiles[1]:getY(), job.z) .. "#" .. getTimestampMs()
        jobs[job.persistKey] = { z = job.z, xy = xs }
    elseif job.persistKey then
        jobs[job.persistKey] = nil
    end
end

-- after a load: collapses that were still moving are judged again where they were (what is still unsupported
-- drops; what already came down is held by what it landed on)
local function resumeJobs()
    local jobs = md().jobs
    local n = 0
    for k, j in pairs(jobs) do
        for i = 1, #j.xy, 2 do
            SC.queue[#SC.queue + 1] = { x = j.xy[i], y = j.xy[i + 1], z = j.z, r = 0 }
            SC.queue[#SC.queue + 1] = { x = j.xy[i], y = j.xy[i + 1], z = j.z, r = 0, roof = true }
        end
        jobs[k] = nil
        n = n + 1
    end
    if n > 0 then log("resuming " .. n .. " collapse(s) cut off by a save") end
end

local function onInitGlobalModData()
    if isClient() then return end
    SC.data = nil
    md()
    resumeJobs()
end

-- Order inside a level (2026-11-10, user's idea): nearest to the support that went first, so the floor gives way
-- from there outwards. `ring` = whole tiles of distance from the origin; inside a ring, a tile's floor still goes
-- before its walls, furniture and items. SC.RING_TICKS ticks pass between rings (0 = no pacing), so the wave
-- can be seen; levels still go bottom-up, each level starting its own wave once the one below is done.
SC.RING_TICKS = 2

local function planLevel(job)
    local plan = {}
    local ox, oy = job.ox or 0, job.oy or 0
    for _, c in ipairs(job.cols) do
        local src = (c.levels == nil or c.levels[job.lz]) and sqAt(c.x, c.y, job.lz) or nil
        local dx, dy = c.x - ox, c.y - oy
        local ring = math.floor(math.sqrt(dx * dx + dy * dy) + 0.5)
        for _, o in ipairs(columnObjects(src, c)) do
            plan[#plan + 1] = { obj = o, x = c.x, y = c.y, ord = order(o), ring = ring }
        end
    end
    table.sort(plan, function(a, b)
        if a.ring ~= b.ring then return a.ring < b.ring end
        if a.ord ~= b.ord then return a.ord < b.ord end
        if a.x ~= b.x then return a.x < b.x end
        return a.y < b.y
    end)
    if job.free and #plan == 0 then
        local c = job.cols[1]
        local s = sqAt(c.x, c.y, job.lz)
        local objs = s and s:getObjects()
        local names = {}
        for i = 0, (objs and objs:size() or 0) - 1 do
            local o = objs:get(i)
            names[#names + 1] = tostring(spriteNameOf(o)) .. (SC.isFreeObj(o) and "*" or "")
        end
        log("piece drop found nothing to move at " .. key(c.x, c.y, job.lz) .. " levels=" .. tostring(c.levels and c.levels[job.lz])
            .. " objects: " .. table.concat(names, " "))
    end
    job.plan, job.i = plan, 1
    job.reserved, job.movedUnit, job.edgeCleared = {}, {}, {}
    job.levelTicks = 0
end

-- one plan entry: move (or break) one object of level job.lz to job.lz - 1, resolving overlaps
local function handleEntry(job, p)
    local o, z = p.obj, job.lz
    local zb, report = z - job.drop, job.report
    if job.free then
        -- a free-standing upper piece (lamp head, sign top): just falls; what it lands on may be hit
        if not (o:getSquare() and o:getSquare():getZ() == z) then return end
        local dst = cell():getOrCreateGridSquare(p.x, p.y, zb)
        SC.hitBelow(job, dst, "falling piece")
        SC.moveObj(o, dst)
        report.moved = report.moved + 1
        return
    end
    local reserved, movedUnit, edgeCleared = job.reserved, job.movedUnit, job.edgeCleared
    -- changed since it was planned (removed, moved by a player, moved with its unit): skip
    if not (o:getSquare() and o:getSquare():getZ() == z and not movedUnit[o]) then return end
    local dst = cell():getOrCreateGridSquare(p.x, p.y, zb)
    if p.ord == 1 then
        -- one floor per tile: the falling floor stays, the one below breaks. Step 1 (its own tick): clear the
        -- tile below; step 2 (a later tick): land the floor. Returns true to be called again for step 2.
        if not p.cleared then
            p.cleared = true
            local lower = dst:getFloor()
            local st = stairsOn(dst)
            if lower or st then
                if lower then SC.breakObj(lower, "floor under falling floor") end
                if st then SC.breakObj(st, "stairs under falling floor") end
                return true
            end
        end
        SC.hitBelow(job, dst, "falling floor")
        SC.moveObj(o, dst, 0)
        report.moved = report.moved + 1
    elseif p.ord == 3 or p.ord == 4 then
        -- edge objects: if the falling side carries a wall and the same edge below has one, the lower edge breaks
        local e = edgeOf(o)
        for _, ed in ipairs(e == "NW" and { "N", "W" } or { e }) do
            local k = key(p.x, p.y, zb) .. ed
            if p.ord == 3 and not edgeCleared[k] and (ed == "N" or ed == "W") and hasWallOnEdge(dst, ed) then
                edgeCleared[k] = true
                for _, lo in ipairs(edgeObjects(dst, ed)) do SC.breakObj(lo, "edge " .. ed .. " under falling wall") end
            end
        end
        local st = stairsOn(dst)
        if st and p.ord == 3 then SC.breakObj(st, "stairs under falling wall") end
        SC.moveObj(o, dst)
        report.moved = report.moved + 1
    elseif p.ord == 5 then
        -- furniture: whole unit (sprite grid parts) and the things on top of it go together
        local grid = ArrayList.new()
        o:getSpriteGridObjectsIncludingSelf(grid)
        local parts = {}
        for i = 0, grid:size() - 1 do parts[#parts + 1] = grid:get(i) end
        if #parts == 0 then parts = { o } end
        if job.loose then
            -- one tile of floor went: furniture still standing on floor with another part stays where it is
            for _, part in ipairs(parts) do
                if part ~= o and part:getSquare() and part:getSquare():getFloor() then
                    for _, q in ipairs(parts) do movedUnit[q] = true end
                    return
                end
            end
        end
        local offsets = {}
        for _, part in ipairs(parts) do
            offsets[#offsets + 1] = { part:getX() - o:getX(), part:getY() - o:getY() }
        end
        local spot = findSpot(dst, offsets, reserved)
        for _, part in ipairs(parts) do movedUnit[part] = true end
        if spot then
            if spot ~= dst then report.pushed = report.pushed + 1 end
            for i, part in ipairs(parts) do
                local psq = part:getSquare()
                local tops = {}
                if psq then
                    local objs = psq:getObjects()
                    for j = 0, objs:size() - 1 do
                        local t = objs:get(j)
                        if t ~= part and t:isTableTopObject() then tops[#tops + 1] = t end
                    end
                end
                local target = sqAt(spot:getX() + offsets[i][1], spot:getY() + offsets[i][2], zb)
                reserved[target] = true
                if psq and psq:getZ() == z then
                    SC.hitBelow(job, target, "falling furniture")
                    SC.moveObj(part, target)
                    report.moved = report.moved + 1
                    for _, t in ipairs(tops) do
                        movedUnit[t] = true
                        SC.moveObj(t, target)
                        report.moved = report.moved + 1
                    end
                end
            end
        else
            report.broken = report.broken + 1
            SC.hitBelow(job, dst, "falling furniture")
            SC.breakObj(o, "no free tile within " .. SC.PUSH_RADIUS, dst)
        end
    else
        -- decorations, overlays, world items, everything else: may overlap. A falling roof hits who is below.
        if job.roof then SC.hitBelow(job, dst, "falling roof") end
        SC.moveObj(o, dst)
        report.moved = report.moved + 1
    end
end

-- work on a job until the deadline (at least one entry per call); true when it is finished
local function stepJob(job, deadline)
    local did = false
    local counted = false
    while job.lz <= job.top do
        if not job.plan then planLevel(job) end
        if not counted then job.levelTicks = job.levelTicks + 1; counted = true end
        -- rings allowed so far on this level (ring 0 on the level's first tick)
        local limit = SC.RING_TICKS > 0 and math.floor((job.levelTicks - 1) / SC.RING_TICKS) or 1e9
        while job.i <= #job.plan do
            if did and getTimestampMs() >= deadline then return false end
            local p = job.plan[job.i]
            if p.ring > limit then
                -- an empty ring in between (gap in the group) would only waste ticks: skip ahead to this ring
                if not did and p.ring > limit + 1 then
                    job.levelTicks = p.ring * SC.RING_TICKS + 1
                    limit = p.ring
                else
                    return false
                end
            end
            -- don't start an entry the budget can't fit (by the average cost so far)
            if did and getTimestampMs() + (job.avgMs or 0) > deadline then return false end
            local t0 = getTimestampMs()
            local again = handleEntry(job, p)
            local dt = getTimestampMs() - t0
            job.avgMs = (job.avgMs or dt) * 0.8 + dt * 0.2
            if not again then job.i = job.i + 1 end
            did = true
            if again then return false end   -- the second step of a split entry waits for the next tick
        end
        -- corpses lying on the footprint of this level fall with it (vanilla path: corpse -> item -> corpse again)
        for _, c in ipairs(job.cols) do
            if c.modes.all or c.modes.loose then
                SC.dropBodies(sqAt(c.x, c.y, job.lz), job.drop, job.report)
            end
        end
        job.plan = nil
        job.lz = job.lz + 1
    end
    return true
end

-- ---------------------------------------------------------------- roofs
-- Roof tiles are pictures: no collision, no floor (except ~26 flat roof tiles with solidfloor), and a tall roof
-- spans two or more levels. Roof pieces over a falling floor group fall with it (they are in its columns).
-- Every other roof piece has its own rule (decided 2026-11-10): the roof pieces joined on one level form a roof
-- layer; a layer drops one level when none of its pieces is held up by
--   * a wall, pillar or staircase under its edges (as for floors),
--   * a floor on its own square, or
--   * a roof piece straight below it (the lower part of the same tall roof).
-- So when the lower part of a tall roof is gone, the part above comes down a level, and so on.
-- Level 1 roofs follow the same rule (2026-11-10: a player on the ground can't reach them with a sledgehammer -
-- the cursor works on the player's own level - so a single-storey roof left with no wall at all comes down).
-- Their eaves don't drop alone: they are in the same layer as the roof resting on the walls.
SC.ROOF_MIN_DROP_Z = 1

local function isRoofObj(o)
    if instanceof(o, "IsoWorldInventoryObject") or isFloorObj(o) then return false end
    -- roof pieces flagged attachedN/W (roofs_accents_*, ~6k in roofs_01..05) are still roof; walls are not
    local wn, ww = wallEdges(o)
    if wn or ww then return false end
    local t = o:getType()
    if t == IsoObjectType.WestRoofB or t == IsoObjectType.WestRoofM or t == IsoObjectType.WestRoofT then return true end
    local p = props(o)
    return has(p, IsoFlagType.isEave) or (p ~= nil and p:has("RoofGroup"))
end
SC.isRoofObj = isRoofObj

local function hasRoof(sq)
    if not sq then return false end
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        if isRoofObj(objs:get(i)) then return true end
    end
    return false
end
SC.hasRoof = hasRoof

function SC.roofSupported(x, y, z)
    if z < SC.ROOF_MIN_DROP_Z then return true end
    if isGroupTile(sqAt(x, y, z)) then return true end
    if hasRoof(sqAt(x, y, z - 1)) then return true end
    -- a roof lying on the ceiling (floor) of the level below (325 vanilla roof layers, map check 2026-11-10).
    -- Not the ground (z 0): that would hold every single-storey roof up for ever.
    if z - 1 >= 1 and isGroupTile(sqAt(x, y, z - 1)) then return true end
    return SC.tileSupported(x, y, z)
end

local function finishJob(job)
    local r = job.report
    if job.wireList then
        SC.stats.wires = (SC.stats.wires or 0) + 1
        log(string.format("wires at %s (%s): squares=%d broken=%d items=%d tower=%d ticks=%d workMs=%d maxTickMs=%d",
            key(job.x, job.y, 0), job.kind, r.squares, r.broken, r.items, r.tower or 0, job.ticks, job.workMs, job.maxTickMs))
        SC.lastWires = { kind = job.kind, squares = r.squares, broken = r.broken, items = r.items, tower = r.tower,
            ticks = job.ticks }
        return
    end
    if job.loose then
        SC.stats.drops = (SC.stats.drops or 0) + 1
        log(string.format("drop %s -> %d levels moved=%d pushed=%d furnitureBroken=%d hit=%d ticks=%d",
            key(job.cols[1].x, job.cols[1].y, job.z), job.drop, r.moved, r.pushed, r.broken, r.hit, job.ticks))
        SC.lastDrop = { report = r, drop = job.drop, free = job.free }
        -- what stood on the pieces that fell, or was left beside them, may stand on nothing now: judge it next
        if job.free and r.moved > 0 then
            for _, m in ipairs(job.members or { { job.cols[1].x, job.cols[1].y, job.z } }) do
                SC.queue[#SC.queue + 1] = { x = m[1], y = m[2], z = m[3], free = true }
                SC.queue[#SC.queue + 1] = { x = m[1], y = m[2], z = m[3] + 1, free = true }
                SC.queue[#SC.queue + 1] = { x = m[1], y = m[2], z = m[3], attach = true, r = 1 }
            end
        end
        return
    end
    if job.roof then
        SC.stats.roofDrops = (SC.stats.roofDrops or 0) + 1
        log(string.format("roof drop z=%d pieces=%d moved=%d ticks=%d", job.z, #job.tiles, r.moved, job.ticks))
        SC.lastRoof = { z = job.z, pieces = #job.tiles, report = r }
        -- the layer now one level down may hang again; the roof above it lost what it rested on;
        -- a free-standing piece above the layer's squares stood on it
        for _, sq in ipairs(job.tiles) do
            SC.queue[#SC.queue + 1] = { x = sq:getX(), y = sq:getY(), z = job.z + 1, free = true }
            SC.queue[#SC.queue + 1] = { x = sq:getX(), y = sq:getY(), z = job.z, attach = true, r = 1 }
            SC.queue[#SC.queue + 1] = { x = sq:getX(), y = sq:getY(), z = job.z - 1, r = 0, roof = true }
            SC.queue[#SC.queue + 1] = { x = sq:getX(), y = sq:getY(), z = job.z + 1, r = 1, roof = true }
        end
        return
    end
    SC.stats.collapses = SC.stats.collapses + 1
    log(string.format("collapse z=%d tiles=%d levels=%d..%d moved=%d pushed=%d furnitureBroken=%d hit=%d bodiesLeft=%d ticks=%d workMs=%d maxTickMs=%d",
        job.z, #job.tiles, job.z, job.top, r.moved, r.pushed, r.broken, r.hit, r.bodies, job.ticks, job.workMs, job.maxTickMs))
    SC.last = { z = job.z, top = job.top, tiles = #job.tiles, report = r, ticks = job.ticks, maxTickMs = job.maxTickMs }
    SC.persistJob(job, false)
    -- moving isn't removing (no event fires): free-standing pieces left on the moved columns (on top of a wall
    -- that came down) are judged here
    for _, c in ipairs(job.cols) do
        for lz = job.z, job.top + 1 do
            SC.queue[#SC.queue + 1] = { x = c.x, y = c.y, z = lz, free = true }
        end
        -- hanging objects next to what moved (lights under a ceiling that came down, signs on its walls)
        for lz = job.z, job.top + 1, 2 do
            SC.queue[#SC.queue + 1] = { x = c.x, y = c.y, z = lz, attach = true, r = 1 }
        end
    end
    -- the top level is empty now: its squares stop being part of a map room (the level below them keeps the
    -- ground floor's rooms, which now hold what came down)
    for _, sq in ipairs(job.tiles) do
        SC.clearRoom(sqAt(sq:getX(), sq:getY(), job.top))
    end
    -- the dropped group may now hang over an empty level again; parts above that reached past it may hang too.
    -- Roof pieces around the footprint (eaves, the rest of a tall roof) lost what they rested on: judge them too.
    for _, sq in ipairs(job.tiles) do
        -- up to one level above the top: what rested on the structure (a rooftop on tall walls) lost it
        for lz = job.z - 1, job.top + 1 do
            SC.queue[#SC.queue + 1] = { x = sq:getX(), y = sq:getY(), z = lz, r = 1 }
        end
        for lz = job.z - 1, job.top + 1 do
            SC.queue[#SC.queue + 1] = { x = sq:getX(), y = sq:getY(), z = lz, r = 1, roof = true }
        end
    end
end

-- centre of a tile list (origin of the wave when no trigger point is known)
local function centre(tiles)
    local sx, sy = 0, 0
    for _, t in ipairs(tiles) do sx = sx + t:getX(); sy = sy + t:getY() end
    local n = math.max(1, #tiles)
    return math.floor(sx / n + 0.5), math.floor(sy / n + 0.5)
end

-- ox, oy: where the last support went (the wave starts there); default the group's centre
function SC.collapse(nodes, z, ox, oy)
    local cols = buildColumns(nodes)
    local tiles = SC.nodeSquares(nodes, z)
    if not ox then ox, oy = centre(tiles) end
    -- how high the columns go (no size cap: a bigger collapse just takes more ticks)
    local total, top = 0, z
    for lz = z, 31 do
        local n = 0
        for _, c in ipairs(cols) do
            local sq = sqAt(c.x, c.y, lz)
            if sq then
                n = n + #columnObjects(sq, c)
            end
        end
        if n == 0 and lz > z then break end
        total = total + n; top = lz
    end
    local job = { tiles = tiles, z = z, top = top, cols = cols, lz = z, drop = 1, hit = {}, ox = ox, oy = oy,
        report = { moved = 0, pushed = 0, broken = 0, bodies = 0, hit = 0 }, ticks = 0, workMs = 0, maxTickMs = 0 }
    SC.jobs[#SC.jobs + 1] = job
    SC.persistJob(job, true)
    log(string.format("collapse start z=%d tiles=%d levels=%d..%d objects=%d", z, #tiles, z, top, total))
    return true
end

-- a roof layer with nothing under it: its roof pieces (only those, only on this level) drop one level
function SC.roofCollapse(tiles, z, ox, oy)
    if not ox then ox, oy = centre(tiles) end
    local cols = {}
    for _, sq in ipairs(tiles) do
        cols[#cols + 1] = { x = sq:getX(), y = sq:getY(), modes = { roof = true }, roofLevels = { [z] = true } }
    end
    SC.jobs[#SC.jobs + 1] = { roof = true, tiles = tiles, z = z, top = z, cols = cols, lz = z, drop = 1, hit = {}, ox = ox, oy = oy,
        report = { moved = 0, pushed = 0, broken = 0, bodies = 0, hit = 0 }, ticks = 0, workMs = 0, maxTickMs = 0 }
    log(string.format("roof drop start z=%d pieces=%d", z, #tiles))
    return true
end

-- An upper floor tile was removed: what stood on it falls to the nearest floor below (same rules as a
-- collapse: overlapping furniture goes to the nearest free tile, else breaks; characters below are hit).
-- Walls and other edge things stay (they also stand on the neighbouring tiles).
function SC.dropLoose(x, y, z)
    local sq = sqAt(x, y, z)
    if not sq or sq:getFloor() then return false end   -- gone, or a floor was put back meanwhile
    local col = { x = x, y = y, modes = { loose = true } }
    if #columnObjects(sq, col) == 0 then return false end
    local land = 0
    for zb = z - 1, 0, -1 do
        local s = sqAt(x, y, zb)
        if s and s:getFloor() then land = zb; break end
    end
    SC.jobs[#SC.jobs + 1] = { loose = true, tiles = {}, z = z, top = z, cols = { col }, lz = z, drop = z - land, hit = {},
        report = { moved = 0, pushed = 0, broken = 0, bodies = 0, hit = 0 }, ticks = 0, workMs = 0, maxTickMs = 0 }
    log(string.format("drop start %s -> z=%d", key(x, y, z), land))
    return true
end

-- Free-standing upper pieces (2026-11-10: street-light heads, tops of standing signs and billboards): an object on a
-- level >= 1, on a square with no floor there, that is not a wall/edge thing, stairs, post or roof. It stands on
-- whatever is straight below it; when something below it is removed and nothing is left there (only a floor or
-- nothing), it falls to the nearest floor below, and the piece above it is judged next. Only a removal right
-- under a piece triggers it, so things floating in vanilla (power lines) stay unless that happens.
function SC.isFreeObj(o)
    if instanceof(o, "IsoWorldInventoryObject") or isFloorObj(o) or isStairs(o) or isPole(o) then return false end
    if SC.isRoofObj(o) then return false end
    -- overhead wires hang between poles: only the wire rule (SC.breakWires) takes them down
    if SC.isWire(o) or SC.isHVLine(o) then return false end
    -- pylon towers have their own rule (SC.breakWires "pylon": the tower stands while it has a leg)
    if SC.isPylonPiece(o) then return false end
    local e = edgeOf(o)
    if e == nil then return true end
    -- an edge thing (window, railing, decoration) with no wall on its edge stands on its own (map check: ~3.6k)
    local wn, ww = wallEdges(o)
    if wn or ww then return false end
    local sq = o:getSquare()
    if not sq then return false end
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    if e == "N" then return not wallOn(x, y, z, true) end
    if e == "W" then return not wallOn(x, y, z, false) end
    if e == "NW" then return not wallOn(x, y, z, true) and not wallOn(x, y, z, false) end
    return false
end

-- what moves with a falling roof layer: the roof pieces and whatever sits on or in them (rooftop units, items,
-- decorations); not walls, floors, stairs or posts (those belong to structures)
function SC.onRoofLayer(o)
    if SC.isRoofObj(o) then return true end
    if isFloorObj(o) or isStairs(o) or isPole(o) then return false end
    local wn, ww = wallEdges(o)
    return not (wn or ww)
end

local function standsOnSomething(x, y, z)
    local s = sqAt(x, y, z - 1)
    if not s then return false end
    local objs = s:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        if not instanceof(o, "IsoWorldInventoryObject") and not isFloorObj(o) then return true end
    end
    return false
end

-- the free pieces of the given sheets on a square
local function freePieces(sq, sheets)
    local out = {}
    if not sq then return out end
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        if SC.isFreeObj(o) and (sheets == nil or sheets[sheetOf(o)]) then out[#out + 1] = o end
    end
    return out
end

-- Free pieces of one big object (2026-11-10, map check: 94% of what stayed up is a piece of a factory tank, pylon
-- or radio tower lattice, billboard or water tank touching another piece of it): the free pieces of the same
-- sprite sheet touching in 3x3x3 are one object. It stands while any piece stands on something (an object below
-- that is not part of it, a floor on its own square, or the ground: a piece on level 0). Otherwise the whole
-- object drops, keeping its shape, by the smallest fall of its pieces (to the nearest floor or object below).
SC.FREE_CLUSTER_MAX = 600   -- squares; a bigger one is left standing (logged)
SC.freeSeen = SC.freeSeen or {}

-- Hanging objects (2026-11-10, user: "the 269 that stay up must work too"): what floats in vanilla (ceiling lights
-- over an atrium, a sign or pipe beside a wall, a lattice piece) is held by what it touches. When something near it
-- is removed or moved (SC.queue entry `attach`), a free object that stands on nothing stays while any of its pieces
-- touches another object (3x3 on its level, the level above, and the level below except the floor there), and
-- otherwise falls like any free object. The judgement from below (something under it went) ignores this: a lamp
-- head whose post went falls even beside a wall.
SC.ATTACH_REACH = 2   -- squares around a removal where hanging objects are judged again

local function touchesSomething(members, isMember, sheets)
    for _, m in ipairs(members) do
        for dz = -1, 1 do
            local nz = m[3] + dz
            if nz >= 0 then
                for dx = -1, 1 do for dy = -1, 1 do
                    local s = sqAt(m[1] + dx, m[2] + dy, nz)
                    local objs = s and s:getObjects()
                    local own = isMember[key(m[1] + dx, m[2] + dy, nz)]
                    for i = 0, (objs and objs:size() or 0) - 1 do
                        local o = objs:get(i)
                        if not instanceof(o, "IsoWorldInventoryObject")
                            and not (dz == -1 and isFloorObj(o))
                            and not (own and sheets[sheetOf(o)] and SC.isFreeObj(o)) then
                            return true
                        end
                    end
                end end
            end
        end
    end
    return false
end

function SC.dropFree(x, y, z, attach)
    if SC.freeSeen[key(x, y, z)] then return false end
    local sq = sqAt(x, y, z)
    local seed = freePieces(sq, nil)
    if #seed == 0 then return false end
    local sheets = {}
    for _, o in ipairs(seed) do local s = sheetOf(o); if s then sheets[s] = true end end
    -- the object: squares holding free pieces of these sheets, 3x3x3-connected
    local members, seen, queue, head = {}, { [key(x, y, z)] = true }, { { x, y, z } }, 1
    while head <= #queue do
        local q = queue[head]; head = head + 1
        members[#members + 1] = q
        SC.freeSeen[key(q[1], q[2], q[3])] = true
        if #members > SC.FREE_CLUSTER_MAX then
            log("free piece object over " .. SC.FREE_CLUSTER_MAX .. " squares at " .. key(x, y, z) .. ": left standing")
            return false
        end
        for dz = -1, 1 do for dx = -1, 1 do for dy = -1, 1 do
            local nx, ny, nz = q[1] + dx, q[2] + dy, q[3] + dz
            local k = key(nx, ny, nz)
            if nz >= 0 and not seen[k] then
                seen[k] = true
                if #freePieces(sqAt(nx, ny, nz), sheets) > 0 then queue[#queue + 1] = { nx, ny, nz } end
            end
        end end end
    end
    local isMember = {}
    for _, m in ipairs(members) do isMember[key(m[1], m[2], m[3])] = true end
    -- the smallest fall over the pieces; 0 = something holds it
    local drop, z0, z1 = nil, nil, nil
    for _, m in ipairs(members) do
        local mx, my, mz = m[1], m[2], m[3]
        z0, z1 = math.min(z0 or mz, mz), math.max(z1 or mz, mz)
        local fall = 0
        if mz >= 1 and not isGroupTile(sqAt(mx, my, mz)) then
            fall = mz
            for zb = mz - 1, 0, -1 do
                if not isMember[key(mx, my, zb)] then
                    if standsOnSomething(mx, my, zb + 1) then fall = mz - zb - 1; break end
                    local b = sqAt(mx, my, zb)
                    if b and b:getFloor() then fall = mz - zb; break end
                end
            end
        end
        drop = math.min(drop or fall, fall)
        if drop == 0 then return false end
    end
    -- judged because something near it went: it stays while it still touches something
    if attach and touchesSomething(members, isMember, sheets) then return false end
    -- one column entry per square, moving only this object's pieces on that level
    local cols = {}
    for _, m in ipairs(members) do
        cols[#cols + 1] = { x = m[1], y = m[2], modes = { free = true }, sheets = sheets, levels = { [m[3]] = true } }
    end
    SC.jobs[#SC.jobs + 1] = { loose = true, free = true, tiles = {}, z = z0, top = z1, cols = cols, lz = z0,
        drop = drop, hit = {}, members = members, ox = x, oy = y,
        report = { moved = 0, pushed = 0, broken = 0, bodies = 0, hit = 0 }, ticks = 0, workMs = 0, maxTickMs = 0 }
    log(string.format("piece drop start %s: %d squares, z %d..%d, down %d", key(x, y, z), #members, z0, z1, drop))
    return true
end

-- Overhead wires (2026-11-10, map check §8). Both kinds are broken the same way (user decision): when a piece of a
-- pole or pylon goes, the spans hanging on it break, and every SC.WIRE_ITEM_EVERY-th piece drops a SC.WIRE_ITEM on
-- the floor below.
--   wooden utility poles  appliances_com_01_88..95 (foot z0, trunk z1, cross-arm top _90..93 z2; sledge or scrap in
--                         vanilla, not picked up). Wires _96..135 and _143..147 in two-row bands at z2 through the
--                         pole tops; spans median 45 squares (max 208).
--   high-voltage pylons   electricity_pylon_0..71 (12 legs z0, body z1..z4, arms z5..z7; 117 on the map, 5x5 at the
--                         foot; no CanScrap, so sledge only). Lines _72..175 and _177..180 (_176/_181 are posts), two
--                         rows at each of z4, z6, z7 through the arms; spans 27 to ~3,000 squares, about 1,600 line
--                         squares a pylon.
-- A span = line squares 8-connected on one level, from the pole's own box out to just before the next pole (a
-- square next to a pole piece outside the own box ends the span: that pole holds the far end). The search and the
-- breaking both run as one job inside SC.TICK_BUDGET_MS; a square that is not loaded ends the span there (that part
-- stays up, as for any check that reaches unloaded squares).
SC.WIRE_ITEM = "Base.ElectricWire"
SC.WIRE_ITEM_EVERY = 10
SC.WIRE_SPAN_MAX = { pole = 1000, pylon = 30000 }   -- line squares per removal, all levels together

local function spriteIndex(o, sheet)
    local n = spriteNameOf(o)
    if not n then return nil end
    local i = string.match(n, "^" .. sheet .. "_(%d+)$")
    return i and tonumber(i) or nil
end
local function comIndex(o) return spriteIndex(o, "appliances_com_01") end
local function pylIndex(o) return spriteIndex(o, "electricity_pylon") end

local function isPolePiece(o) local i = comIndex(o); return i ~= nil and i >= 88 and i <= 95 end
local function isPoleTop(o) local i = comIndex(o); return i ~= nil and i >= 90 and i <= 93 end
local function isWire(o)
    local i = comIndex(o)
    return i ~= nil and ((i >= 96 and i <= 135) or (i >= 143 and i <= 147))
end
local function isPylonPiece(o) local i = pylIndex(o); return i ~= nil and i <= 71 end
local function isHVLine(o)
    local i = pylIndex(o)
    return i ~= nil and i >= 72 and i <= 180 and i ~= 176
end
SC.isPolePiece, SC.isWire, SC.isPylonPiece, SC.isHVLine = isPolePiece, isWire, isPylonPiece, isHVLine

local WIRE_KINDS = {
    -- line = span pieces; holder = the pole pieces that hold a span end; z0..z1 = levels the spans run on;
    -- reach = how far from a pole's core a span still belongs to it (the own start area, and the stop distance
    -- around other poles); column = holder pieces count on any level of the column (pylons: the lines pass the
    -- tower up to 3 squares off its legs, on levels with no tower piece next to them; map check 2026-11-10).
    pole = { line = isWire, holder = isPoleTop, z0 = 1, z1 = 4, reach = 1, column = false },
    pylon = { line = isHVLine, holder = isPylonPiece, z0 = 1, z1 = 8, reach = 3, column = true },
}
SC.WIRE_KINDS = WIRE_KINDS

local function squareHas(x, y, z, pred)
    local s = sqAt(x, y, z)
    if not s then return false end
    local objs = s:getObjects()
    for i = 0, objs:size() - 1 do
        if pred(objs:get(i)) then return true end
    end
    return false
end

local function colKey(x, y) return x * 100000 + y end
local function sqKey(x, y, z) return (x * 100000 + y) * 64 + z + 8 end

local function pylonColumn(x, y)
    for lz = 0, 7 do
        if squareHas(x, y, lz, isPylonPiece) then return true end
    end
    return false
end

-- the core of the pole whose piece at (x,y,z) went, per level: {x0, x1, y0, y1}
local function ownCores(kind, x, y)
    local cores = {}
    if kind == "pole" then
        -- the cross-arm top next to the removed piece, if it is still there; else the removed square
        for lz = 1, 4 do
            local ox, oy = x, y
            for dx = -1, 1 do for dy = -1, 1 do
                if squareHas(x + dx, y + dy, lz, isPoleTop) then ox, oy = x + dx, y + dy end
            end end
            cores[lz] = { ox, ox, oy, oy }
        end
        return cores
    end
    -- a pylon: the bounding box of the columns holding its pieces, connected (8 neighbours) to the removed square
    -- and within 6 squares of it (a tower stands on 5x6 columns; the next one is 27 or more squares away)
    local x0, x1, y0, y1 = x, x, y, y
    local seen, q, head = { [colKey(x, y)] = true }, { { x, y } }, 1
    while head <= #q do
        local c = q[head]; head = head + 1
        for dx = -1, 1 do for dy = -1, 1 do
            local nx, ny = c[1] + dx, c[2] + dy
            local k = colKey(nx, ny)
            if not seen[k] and math.abs(nx - x) <= 6 and math.abs(ny - y) <= 6 then
                seen[k] = true
                if pylonColumn(nx, ny) then
                    q[#q + 1] = { nx, ny }
                    x0, x1, y0, y1 = math.min(x0, nx), math.max(x1, nx), math.min(y0, ny), math.max(y1, ny)
                end
            end
        end end
    end
    for lz = 1, 8 do cores[lz] = { x0, x1, y0, y1 } end
    return cores
end

-- queue the spans hanging on the pole/pylon whose piece at (x,y) went. kind = "pole" | "pylon"
-- Pylons (user, 2026-11-10 night: few of them, handled on their own): the tower stands while any of its legs
-- (electricity_pylon_0..11 on level 0) is left, and nothing happens. When the last leg goes, the tower falls: its
-- pieces on every level are removed (vanilla gives nothing back for them) and the lines hanging on it break.
SC.pylonsThisPass = {}

function SC.breakWires(x, y, z, kind)
    kind = kind or "pole"
    local K = WIRE_KINDS[kind]
    if kind == "pylon" then
        -- the legs of one tower removed together (in-game 2026-11-10: 12 jobs, one 491 ms frame): judge it once
        for _, b in ipairs(SC.pylonsThisPass) do
            if x >= b[1] - 1 and x <= b[2] + 1 and y >= b[3] - 1 and y <= b[4] + 1 then return false end
        end
    end
    local cores = ownCores(kind, x, y)
    local tower = nil
    if kind == "pylon" then
        local b = cores[1]
        SC.pylonsThisPass[#SC.pylonsThisPass + 1] = b
        local legs = 0
        tower = {}
        for lz = 0, 8 do
            for sx = b[1], b[2] do for sy = b[3], b[4] do
                local s = sqAt(sx, sy, lz)
                local objs = s and s:getObjects()
                for i = 0, (objs and objs:size() or 0) - 1 do
                    local o = objs:get(i)
                    if isPylonPiece(o) then
                        tower[#tower + 1] = o
                        if lz == 0 and pylIndex(o) <= 11 then legs = legs + 1 end
                    end
                end
            end end
        end
        if legs > 0 then
            log(string.format("pylon at %s stands on %d legs", key(x, y, 0), legs))
            return false
        end
    end
    local st = { cores = cores, memo = {}, cmemo = {}, seen = {}, queue = {}, head = 1 }
    local r = K.reach
    for lz = K.z0, K.z1 do
        local b = cores[lz]
        for sx = b[1] - r, b[2] + r do for sy = b[3] - r, b[4] + r do
            st.seen[sqKey(sx, sy, lz)] = true
            st.queue[#st.queue + 1] = { sx, sy, lz }
        end end
    end
    SC.jobs[#SC.jobs + 1] = { wireSearch = st, wireList = {}, wi = 1, wcount = 0, kind = kind,
        towerList = tower, ti = 1,
        tiles = {}, z = 0, top = 0, cols = {}, lz = 0, drop = 0, hit = {},
        report = { moved = 0, pushed = 0, broken = 0, bodies = 0, hit = 0, items = 0, squares = 0, tower = 0 },
        ticks = 0, workMs = 0, maxTickMs = 0, x = x, y = y }
    return true
end

-- does the square hold a span piece (looked up once per search)
local function isLineSq(job, x, y, lz)
    local st = job.wireSearch
    local k = sqKey(x, y, lz)
    local v = st.memo[k]
    if v == nil then
        v = squareHas(x, y, lz, WIRE_KINDS[job.kind].line)
        st.memo[k] = v
    end
    return v
end

-- does the square (or, for pylons, its column) hold a pole piece (looked up once per search)
local function isHolder(job, x, y, lz)
    local st, K = job.wireSearch, WIRE_KINDS[job.kind]
    local k = K.column and colKey(x, y) or sqKey(x, y, lz)
    local v = st.cmemo[k]
    if v == nil then
        if K.column then v = pylonColumn(x, y) else v = squareHas(x, y, lz, K.holder) end
        st.cmemo[k] = v
    end
    return v
end

local function inBox(b, x, y) return x >= b[1] and x <= b[2] and y >= b[3] and y <= b[4] end

-- within reach of a pole piece outside the own core: that other pole holds this end of the span
local function nearOtherHolder(job, x, y, lz)
    local b, r = job.wireSearch.cores[lz], WIRE_KINDS[job.kind].reach
    for dx = -r, r do for dy = -r, r do
        local tx, ty = x + dx, y + dy
        if not inBox(b, tx, ty) and isHolder(job, tx, ty, lz) then return true end
    end end
    return false
end

-- one tick of the span search; true when it is done
local function stepWireSearch(job, deadline)
    local st, list, K = job.wireSearch, job.wireList, WIRE_KINDS[job.kind]
    local cap = SC.WIRE_SPAN_MAX[job.kind]
    while st.head <= #st.queue do
        if getTimestampMs() >= deadline then return false end
        if job.report.squares >= cap then
            log("wire span cap reached at " .. key(job.x, job.y, 0) .. " (" .. job.kind .. ")")
            break
        end
        local q = st.queue[st.head]; st.head = st.head + 1
        local qx, qy, lz = q[1], q[2], q[3]
        if isLineSq(job, qx, qy, lz) then
            job.report.squares = job.report.squares + 1
            local objs = sqAt(qx, qy, lz):getObjects()
            for i = 0, objs:size() - 1 do
                if K.line(objs:get(i)) then list[#list + 1] = objs:get(i) end
            end
            for dx = -1, 1 do for dy = -1, 1 do
                local nx, ny = qx + dx, qy + dy
                local k = sqKey(nx, ny, lz)
                if not st.seen[k] then
                    st.seen[k] = true
                    if isLineSq(job, nx, ny, lz) and not nearOtherHolder(job, nx, ny, lz) then
                        st.queue[#st.queue + 1] = { nx, ny, lz }
                    end
                end
            end end
        end
    end
    job.wireSearch = nil
    log(string.format("wires start at %s (%s): %d pieces on %d squares", key(job.x, job.y, 0), job.kind, #list,
        job.report.squares))
    return true
end

-- one tick of a wire job (the search, then breaking); true when done
local function stepWires(job, deadline)
    if job.wireSearch and not stepWireSearch(job, deadline) then return false end
    local list = job.wireList
    while job.wi <= #list do
        if getTimestampMs() >= deadline then return false end
        local o = list[job.wi]
        job.wi = job.wi + 1
        local s = o:getSquare()
        if s and s:getObjects():contains(o) then
            job.wcount = job.wcount + 1
            if job.wcount % SC.WIRE_ITEM_EVERY == 0 then
                -- the piece of wire lands on the nearest floor below
                local land = nil
                for zb = s:getZ() - 1, 0, -1 do
                    local b = sqAt(s:getX(), s:getY(), zb)
                    if b and b:getFloor() then land = b; break end
                end
                land = land or cell():getOrCreateGridSquare(s:getX(), s:getY(), 0)
                dropItem(land, SC.WIRE_ITEM)
                job.report.items = job.report.items + 1
            end
            removeObj(o)
            job.report.broken = job.report.broken + 1
        end
    end
    -- a fallen pylon: its own pieces go after the lines
    local tl = job.towerList
    while tl and job.ti <= #tl do
        if getTimestampMs() >= deadline then return false end
        local o = tl[job.ti]
        job.ti = job.ti + 1
        local s = o:getSquare()
        if s and s:getObjects():contains(o) then
            removeObj(o)
            job.report.tower = job.report.tower + 1
        end
    end
    return true
end

-- ---------------------------------------------------------------- queue
-- Work runs in this order, one kind at a time, inside SC.TICK_BUDGET_MS per tick:
--   1. a collapse job that is moving things (checks wait until it is done),
--   2. the group search in progress (resumable, so a big group is judged over several ticks),
--   3. the next seed (a square to judge) of the current pass,
--   4. the next pass: raw queue entries expanded to seeds (loose drops start at once; floors before roofs).
-- Judging happens only when something is removed (decided 2026-11-10: no timed checks). A structure that reaches
-- an unloaded square can't be seen whole: it is left standing, and judged again the next time something near it
-- is removed.
SC.seeds = SC.seeds or {}

-- A pass takes the queue as it is and works through it inside the tick budget (in-game 2026-11-10: 278 and 1,185
-- queued entries done in one tick took 102 and 37 ms). Steps, in order: direct entries (piece drops from below,
-- floor tile drops, wires), then hanging objects near each entry, then the seeds for structure and roof checks
-- (floors before roofs). A pass that started a job waits for it and goes on afterwards.
local function startPass()
    SC.pass = { q = SC.queue, step = 1, i = 1, seeds = {} }
    SC.queue = {}
    SC.held = {}
    SC.freeSeen = {}
    SC.pylonsThisPass = {}
end

-- true when the pass is done
local function stepPass(deadline)
    local p = SC.pass
    local q = p.q
    while p.step <= 3 do
        while p.i <= #q do
            if getTimestampMs() >= deadline then return false end
            local e = q[p.i]
            p.i = p.i + 1
            if p.step == 1 then
                if e.loose then SC.dropLoose(e.x, e.y, e.z) end
                if e.free then SC.dropFree(e.x, e.y, e.z) end
                if e.wires then SC.breakWires(e.x, e.y, e.z, e.wires) end
            elseif p.step == 2 then
                -- hanging objects near what went or moved (after the judgements from below, which ignore
                -- attachments)
                if e.attach then
                    local r = e.r or SC.ATTACH_REACH
                    for lz = math.max(1, e.z - 1), e.z + 1 do
                        for dx = -r, r do for dy = -r, r do
                            SC.dropFree(e.x + dx, e.y + dy, lz, true)
                        end end
                    end
                end
            else
                if not e.loose and not e.free and not e.wires and not e.attach and not e.roof and e.z > 0 then
                    local r = e.r or 1
                    for dx = -r, r do for dy = -r, r do
                        p.seeds[#p.seeds + 1] = { x = e.x + dx, y = e.y + dy, z = e.z, ox = e.x, oy = e.y, tries = e.tries or 0 }
                    end end
                end
            end
        end
        if p.step == 3 then
            -- roofs after floors
            for _, e in ipairs(q) do
                if e.roof and e.z > 0 then
                    local r = e.r or 1
                    for dx = -r, r do for dy = -r, r do
                        p.seeds[#p.seeds + 1] = { x = e.x + dx, y = e.y + dy, z = e.z, roof = true, ox = e.x, oy = e.y,
                            tries = e.tries or 0 }
                    end end
                end
            end
        end
        p.step = p.step + 1
        p.i = 1
    end
    for _, sd in ipairs(p.seeds) do SC.seeds[#SC.seeds + 1] = sd end
    SC.pass = nil
    return true
end

local function finishSearch(st)
    local res = st.result
    SC.stats.checks = SC.stats.checks + 1
    local label = type(res) == "table" and "unsupported" or res
    SC.lastCheck = { res = label, visited = #st.nodes, ticks = st.ticks, roof = st.roof }
    log(string.format("%scheck %s -> %s visited=%d ticks=%d", st.roof and "roof " or "", key(st.sx, st.sy, st.z),
        label, #st.nodes, st.ticks))
    if type(res) == "table" then
        -- the wave starts where the check came from (the support or floor that went)
        local ok, err = pcall(function()
            if st.roof then SC.roofCollapse(SC.nodeSquares(res, st.z), st.z, st.ox, st.oy) else SC.collapse(res, st.z, st.ox, st.oy) end
        end)
        if not ok then log("ERROR starting the collapse: " .. tostring(err)) end
    end
end

-- one tick of judging; returns when the budget is used or a collapse job was started
local function judge(deadline)
    while getTimestampMs() < deadline do
        if SC.bfs then
            local st = SC.bfs
            st.ticks = st.ticks + (st.lastTickSeen == SC.tickNo and 0 or 1)
            st.lastTickSeen = SC.tickNo
            if SC.bfsStep(st, deadline) == nil then return end
            SC.bfs = nil
            local jobsBefore = #SC.jobs
            finishSearch(st)
            if #SC.jobs > jobsBefore then
                -- things will move: what this pass settled may change, judge the rest afresh afterwards
                SC.held = {}
                return
            end
        elseif #SC.seeds > 0 then
            local s = table.remove(SC.seeds, 1)
            local k = (s.roof and "r" or "") .. key(s.x, s.y, s.z)
            if not SC.held[k] and not (s.roof and s.z < SC.ROOF_MIN_DROP_Z) then
                local st = SC.bfsStart(s.x, s.y, s.z, SC.held, s.roof)
                if st then
                    st.sx, st.sy, st.ox, st.oy, st.tries, st.ticks = s.x, s.y, s.ox, s.oy, s.tries, 0
                    SC.bfs = st
                end
            end
        elseif SC.pass or #SC.queue > 0 then
            if not SC.pass then startPass() end
            local done = stepPass(deadline)
            if #SC.jobs > 0 then return end   -- a drop or wire job started: it runs first, the pass goes on after
            if not done then return end
        else
            return
        end
    end
end

-- true while a collapse is moving things or checks are waiting (tests wait on this)
function SC.pending()
    return #SC.jobs > 0 or #SC.queue > 0 or #SC.seeds > 0 or SC.bfs ~= nil or SC.pass ~= nil
end

local function onAboutToBeRemoved(obj)
    if SC.busy or isClient() or obj == nil then return end
    local sq = obj:getSquare()
    if not sq then return end
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    -- whatever went, a free-standing piece right above it may now stand on nothing
    if not instanceof(obj, "IsoWorldInventoryObject") then
        SC.queue[#SC.queue + 1] = { x = x, y = y, z = z + 1, free = true }
        -- and a hanging object near it may have hung on it
        SC.queue[#SC.queue + 1] = { x = x, y = y, z = z, attach = true }
    end
    -- a utility pole or pylon piece went: the wires hanging on it break
    if SC.isPolePiece(obj) then
        SC.queue[#SC.queue + 1] = { x = x, y = y, z = z, wires = "pole" }
    elseif SC.isPylonPiece(obj) then
        SC.queue[#SC.queue + 1] = { x = x, y = y, z = z, wires = "pylon" }
    end
    if SC.isSupport(obj) then
        -- a support went: the floor level above may have lost its last one, and so may a roof layer above
        SC.queue[#SC.queue + 1] = { x = x, y = y, z = z + 1, r = 1 }
        SC.queue[#SC.queue + 1] = { x = x, y = y, z = z + 1, r = 1, roof = true }
    elseif z >= 1 and SC.isFloorObj(obj) then
        -- an upper floor tile went (dismantled, burnt, ...): it may have cut its group in two, leaving a piece
        -- with no support under it. Check the pieces around it on the same level.
        SC.queue[#SC.queue + 1] = { x = x, y = y, z = z, loose = true }
        SC.queue[#SC.queue + 1] = { x = x, y = y, z = z, r = 1 }
        SC.queue[#SC.queue + 1] = { x = x, y = y, z = z, r = 1, roof = true }
    elseif z >= 1 and SC.isRoofObj(obj) then
        -- a roof piece went (sledgehammer): the rest of its layer and the roof straight above may now hang
        SC.queue[#SC.queue + 1] = { x = x, y = y, z = z, r = 1, roof = true }
        SC.queue[#SC.queue + 1] = { x = x, y = y, z = z + 1, r = 1, roof = true }
    end
end

SC.tickNo = 0
SC.SLOW_TICK_MS = 30   -- a tick of the mod's work this long is logged with what it was doing

local function tick()
    SC.tickNo = SC.tickNo + 1
    if #SC.jobs > 0 then
        local job = SC.jobs[1]
        SC.phase = job.wireList and ("wires " .. tostring(job.kind)) or (job.free and "piece drop") or (job.loose and "floor tile drop")
            or (job.roof and "roof drop") or "collapse"
        local t0 = getTimestampMs()
        local done
        if job.wireList then done = stepWires(job, t0 + SC.TICK_BUDGET_MS) else done = stepJob(job, t0 + SC.TICK_BUDGET_MS) end
        local ms = getTimestampMs() - t0
        job.ticks = job.ticks + 1
        job.workMs = job.workMs + ms
        if ms > job.maxTickMs then job.maxTickMs = ms end
        if done then
            table.remove(SC.jobs, 1)
            finishJob(job)
        end
        return   -- checks wait until no job is moving things
    end
    SC.phase = "judging (" .. #SC.queue .. " queued, " .. #SC.seeds .. " seeds, pass " .. (SC.pass and (SC.pass.step .. ":" .. SC.pass.i .. "/" .. #SC.pass.q) or "-") .. ")"
    judge(getTimestampMs() + SC.TICK_BUDGET_MS)
end

local function onTick()
    if isClient() then return end
    if #SC.jobs == 0 and #SC.queue == 0 and #SC.seeds == 0 and SC.bfs == nil and SC.pass == nil then return end
    local t0 = getTimestampMs()
    local ok, err = pcall(tick)
    local ms = getTimestampMs() - t0
    if ms >= SC.SLOW_TICK_MS then log(string.format("slow tick %d ms: %s", ms, tostring(SC.phase))) end
    if not ok then
        SC.busy = false
        SC.jobs, SC.bfs, SC.seeds, SC.pass = {}, nil, {}, nil   -- work that errors would error again every tick
        log("ERROR " .. tostring(err))
    end
end

Events.OnObjectAboutToBeRemoved.Add(onAboutToBeRemoved)
Events.OnInitGlobalModData.Add(onInitGlobalModData)
Events.LoadGridsquare.Add(onLoadGridsquare)
Events.OnTick.Add(onTick)
