-- StructuralCollapse in-game test (pzt). Installed only into the test env (pzt.conf TEST_FILES), into server/
-- next to the mod file so it loads after it (same Lua state in single player).
-- Builds small scenes on open ground next to the player, removes supports through the vanilla sledgehammer
-- path (ISDestroyStuffAction:complete) and checks where every tagged object ended up.
--
-- Scenes (relative to the origin o = player + (4, 4)):
--   P  floor 3x3 at z1, x 0..2, y 0..2, held by pole A at z0 (1,1). On it: wall (N edge of (0,0)), crate C1 at (0,1)
--      with 3 apples, a two-tile furniture at (1,0)/(2,0) when a 2-tile sprite grid is found, a world item at (2,0).
--      Above: pole at z1 (1,1) holding a one-tile floor at z2 (1,1). At z0 (0,1), under C1: blocker crate B1.
--   Q  floor 3x3 at z1, x 6..8, y 0..2, pole B at z0 (7,1) and a wall D at z0 (W edge of (6,0)). Control: removing D
--      must find B ("supported") and move nothing.
--   R  floor 3x3 at z1, x 0..2, y 5..7, pole C at z0 (1,6). Crate S (player-built, need:Base.Plank=4, 2 apples)
--      at (2,7); blocker B2 under it. PUSH_RADIUS 0 and DROP_CHANCE 100 for this scene: S must break and drop
--      2 apples + 4 planks at z0 (2,7).
--   F, T, V, U, H, L, K, J, B, Z, W, X: described above their build functions (U, J, B, Z and X lie outside the cleared area and
--      clear their own squares).
StructuralCollapseTest = StructuralCollapseTest or {}
local T = StructuralCollapseTest
local SC = StructuralCollapse
T.pass, T.fail = 0, 0
T.i = nil   -- a hot reload (pzt live) starts the stages again

local FLOOR = "carpentry_02_58"        -- wooden floor lvl1 (entity_wood_floorlvl1)
local WALL_N = "walls_exterior_wooden_01_45"
local WALL_W = "walls_exterior_wooden_01_44"
local POLE = "walls_exterior_wooden_01_27"   -- WoodenPole / wall corner
local CRATE = "carpentry_01_19"

local function log(m) print("[SCTest] " .. m) end
local function ok(cond, m)
    if cond then T.pass = T.pass + 1; log("OK " .. m)
    else T.fail = T.fail + 1; PZTest.fail("[SCTest] " .. m) end
end

local function sq(x, y, z) return getCell():getOrCreateGridSquare(T.ox + x, T.oy + y, z) end
local function rel(s) return (s:getX() - T.ox) .. "," .. (s:getY() - T.oy) .. "," .. s:getZ() end

local function tag(o, t) o:getModData().scTag = t; return o end

local function thump(s, sprite, north, needs)
    local o = IsoThumpable.new(getCell(), s, sprite, north, ISSimpleFurniture:new("SCTest", sprite, sprite))
    -- vanilla moves modData "need:" keys into getBuildMaterials() only when the object is built or loaded,
    -- so a test object gets them straight into the build-materials table
    for k, v in pairs(needs or {}) do o:getBuildMaterials()[k] = tostring(v) end
    s:AddSpecialObject(o)
    return o
end

local function plain(s, sprite)
    -- with the shared sprite (vanilla building code does the same): IsoObject.new(sq, name) leaves the sprite
    -- without its name, so name-based rules (poles, wires, pylons, same-object pieces) would not see it
    local o = IsoObject.new(getCell(), s, getSprite(sprite))
    s:AddTileObject(o)
    return o
end

local function floorAt(x, y, z)
    local o = sq(x, y, z):addFloor(FLOOR)
    return o
end

-- remove everything but the ground floor in the test area (trees, bushes, map objects)
local function clearArea()
    for z = 0, 2 do
        for x = -1, 16 do
            for y = -1, 11 do
                local s = getCell():getGridSquare(T.ox + x, T.oy + y, z)
                if s then
                    local objs = s:getObjects()
                    for i = objs:size() - 1, 0, -1 do
                        local o = objs:get(i)
                        if not (z == 0 and o == s:getFloor()) then s:transmitRemoveItemFromSquare(o) end
                    end
                end
            end
        end
    end
end

-- first sprite in a few furniture sheets whose sprite grid is two tiles on one level
local function findTwoTileGrid()
    for _, sheet in ipairs({ "furniture_seating_indoor_01_", "furniture_bedding_01_", "furniture_tables_low_01_",
        "furniture_seating_indoor_02_", "furniture_tables_high_01_" }) do
        for i = 0, 63 do
            local spr = getSprite(sheet .. i)
            local g = spr and spr:getSpriteGrid()
            if g and g:getLevels() == 1 and g:getWidth() * g:getHeight() == 2 then return g end
        end
    end
    return nil
end

-- B42 crates are entities: a plain crate sprite object gets no container from its sprite, so give it one
local function ensureContainer(o, s)
    if o:getContainer() == nil then o:setContainer(ItemContainer.new("crate", s, o)) end
    return o
end

local function crate(s, t, apples)
    local o = ensureContainer(plain(s, CRATE), s)
    tag(o, t)
    for _ = 1, (apples or 0) do o:getContainer():AddItem("Base.Apple") end
    return o
end

function T.build()
    -- P
    for x = 0, 2 do for y = 0, 2 do floorAt(x, y, 1) end end
    T.poleA = thump(sq(1, 1, 0), POLE, false, { ["Base.Plank"] = 1 })
    tag(thump(sq(0, 0, 1), WALL_N, true, { ["Base.Plank"] = 2 }), "wallP")
    T.c1 = crate(sq(0, 1, 1), "C1", 3)
    T.c1:getModData().scKeep = 42
    tag(crate(sq(0, 1, 0), "B1", 0), "B1")
    local g = findTwoTileGrid()
    T.twoTile = g ~= nil
    if g then
        local i = 0
        for gx = 0, g:getWidth() - 1 do
            for gy = 0, g:getHeight() - 1 do
                local o = plain(sq(1 + gx, 0 + gy, 1), g:getSprite(gx, gy):getName())
                i = i + 1
                tag(o, "TT" .. i)
            end
        end
        log("two-tile furniture " .. g:getSprite(0, 0):getName() .. " " .. g:getWidth() .. "x" .. g:getHeight())
    else
        log("no two-tile sprite grid found; that check is skipped")
    end
    local item = sq(2, 0, 1):AddWorldInventoryItem("Base.Pen", 0.5, 0.5, 0)
    item:getModData().scTag = "pen"
    tag(thump(sq(1, 1, 1), POLE, false, {}), "poleUpper")
    tag(floorAt(1, 1, 2), "z2floor")
    -- a corpse lying on P (z1, tile 2,1): it must fall to z0 with the floor
    local zc = createZombie(T.ox + 2 + 0.5, T.oy + 1 + 0.5, 1, nil, 0, IsoDirections.S)
    if zc then IsoDeadBody.new(zc, false) end
    -- Q
    for x = 6, 8 do for y = 0, 2 do floorAt(x, y, 1) end end
    thump(sq(7, 1, 0), POLE, false, {})
    T.wallD = thump(sq(6, 0, 0), WALL_W, false, {})
    -- R
    for x = 0, 2 do for y = 5, 7 do floorAt(x, y, 1) end end
    T.poleC = thump(sq(1, 6, 0), POLE, false, {})
    local s = ensureContainer(thump(sq(2, 7, 1), CRATE, false, { ["Base.Plank"] = 4 }), sq(2, 7, 1))
    tag(s, "S")
    if s:getContainer() then
        s:getContainer():AddItem("Base.Apple"); s:getContainer():AddItem("Base.Apple")
    end
    T.sHasContainer = s:getContainer() ~= nil
    tag(crate(sq(2, 7, 0), "B2", 0), "B2")
    -- F: a 5-tile floor strip at z1 (x 0..4, y 9), pole only under x 0. Cutting x 2 must drop x 3..4 only.
    for x = 0, 4 do tag(floorAt(x, 9, 1), "F" .. x) end
    thump(sq(0, 9, 0), POLE, false, {})
    -- a crate with one apple on the tile that gets cut: it must fall to z0 with its apple
    crate(sq(2, 9, 1), "FC", 1)
end

-- T: a tall roof at x 6..8, y 6. Level 1 roof pieces (z1) sit on a wall at z0 (N edge of y 6); level 2 pieces
-- (z2) sit straight above them. Sledging the three z1 pieces must drop the z2 layer to z1 (roof rule), and
-- the layer then stays at z1 (roofs on level 1 never drop).
local function roofSprite()
    if T.roofName then return T.roofName end
    local s = sq(6, 6, 1)
    for i = 0, 127 do
        local n = "roofs_01_" .. i
        if getSprite(n) then
            local o = IsoObject.new(getCell(), s, getSprite(n))
            if SC.isRoofObj(o) then T.roofName = n; return n end
        end
    end
    return nil
end

function T.buildRoof()
    local name = roofSprite()
    ok(name ~= nil, "T: a roof sprite found (" .. tostring(name) .. ")")
    if not name then return end
    T.roofLow = {}
    for x = 6, 8 do
        thump(sq(x, 6, 0), WALL_N, true, {})
        T.roofLow[#T.roofLow + 1] = tag(plain(sq(x, 6, 1), name), "RL" .. x)
        tag(plain(sq(x, 6, 2), name), "RH" .. x)
    end
    -- a crate sitting on the upper roof: it must ride the roof down each time
    crate(sq(7, 6, 2), "RC", 1)
end

function T.sledgeLowRoof()
    T.roofDropsBefore = SC.stats.roofDrops or 0
    for _, o in ipairs(T.roofLow or {}) do
        if o:getSquare() then T.destroy(o) end
    end
end

function T.checkRoof()
    if not T.roofName then return end
    ok((SC.stats.roofDrops or 0) == T.roofDropsBefore + 1, "T: one roof drop (" .. ((SC.stats.roofDrops or 0) - T.roofDropsBefore) .. ")")
    for x = 6, 8 do
        ok(T.find("RL" .. x) == nil, "T: low roof piece " .. x .. " sledged")
        local _, s = T.find("RH" .. x)
        ok(s ~= nil and s:getZ() == 1, "T: upper roof piece " .. x .. " now at z1 (" .. (s and rel(s) or "missing") .. ")")
    end
end

local function bodiesAt(x, y, z)
    local s = getCell():getGridSquare(T.ox + x, T.oy + y, z)
    local l = s and s:getDeadBodys()
    return l and l:size() or 0
end

function T.checkBody()
    local up, down = 0, 0
    for x = 0, 2 do for y = 0, 2 do up = up + bodiesAt(x, y, 1); down = down + bodiesAt(x, y, 0) end end
    ok(up == 0 and down >= 1, "P: corpse fell with the floor (z1 " .. up .. ", z0 " .. down .. ")")
end

-- T again: the roof that came down to z1 rests on the walls at z0. Sledge those walls: a level-1 roof layer
-- with no support left comes down too (single-storey roof rule).
function T.sledgeRoofWalls()
    T.roofDropsBefore2 = SC.stats.roofDrops or 0
    for x = 6, 8 do
        local s = getCell():getGridSquare(T.ox + x, T.oy + 6, 0)
        local objs = s and s:getObjects()
        for i = (objs and objs:size() or 0) - 1, 0, -1 do
            local o = objs:get(i)
            local n = SC.wallEdges(o)
            if n then T.destroy(o) end
        end
    end
end

function T.checkRoofOnGround()
    if not T.roofName then return end
    ok((SC.stats.roofDrops or 0) > T.roofDropsBefore2, "T: level-1 roof dropped once its walls were gone")
    for x = 6, 8 do
        local _, s = T.find("RH" .. x)
        ok(s ~= nil and s:getZ() == 0, "T: roof piece " .. x .. " now on the ground (" .. (s and rel(s) or "missing") .. ")")
    end
    local _, cs = T.find("RC")
    ok(cs ~= nil and cs:getZ() == 0, "T: crate on the roof came down with it (" .. (cs and rel(cs) or "missing") .. ")")
end

-- V: a car under a 3x6 floor at z1 (x 12..14, y 0..5) held by one pole at (12,0). Drop it: the car is hit.
local function carCondition(v)
    local sum = 0
    for i = 0, v:getPartCount() - 1 do sum = sum + v:getPartByIndex(i):getCondition() end
    return sum
end

-- the car is placed in the first stage: a new car joins the cell's vehicle list (what the mod looks at)
-- only some time later, while a real car under a house has long been there
function T.spawnCarV()
    T.car = addVehicleDebug("Base.CarNormal", IsoDirections.N, nil, sq(13, 3, 0))
end

function T.buildCar()
    for x = 12, 14 do for y = 0, 5 do floorAt(x, y, 1) end end
    T.poleV = thump(sq(12, 0, 0), POLE, false, {})
    ok(T.car ~= nil, "V: car placed")
end

function T.dropOnCar()
    if not T.car then return end
    T.carBefore = carCondition(T.car)
    log("V: car at " .. (T.car:getX() - T.ox) .. "," .. (T.car:getY() - T.oy) .. "," .. T.car:getZ())
    T.destroy(T.poleV)
end

function T.checkCar()
    if not T.car then return end
    local after = carCondition(T.car)
    ok(after < T.carBefore, "V: car parts damaged (" .. T.carBefore .. " -> " .. after .. ")")
    local floorsUp = 0
    for x = 12, 14 do for y = 0, 5 do
        local s = getCell():getGridSquare(T.ox + x, T.oy + y, 1)
        if s and s:getFloor() then floorsUp = floorsUp + 1 end
    end end
    ok(floorsUp == 0, "V: the floor over the car came down (left at z1: " .. floorsUp .. ")")
end

-- U: a car standing ON a 4x6 floor at z1 (x 18..21, y 8..13), held by one pole at (18,8). Sledge the pole: the
-- floor comes down to z0 and the car should fall with vanilla physics (user, 2026-11-10: "probably free fall,
-- check with the client"). Checks the car's height a little later; the mod does not move vehicles itself.
function T.buildCarUp()
    for z = 0, 2 do for x = 17, 22 do for y = 7, 14 do
        local s = getCell():getGridSquare(T.ox + x, T.oy + y, z)
        if s then
            local objs = s:getObjects()
            for i = objs:size() - 1, 0, -1 do
                local o = objs:get(i)
                if not (z == 0 and o == s:getFloor()) then s:transmitRemoveItemFromSquare(o) end
            end
        end
    end end end
    for x = 18, 21 do for y = 8, 13 do floorAt(x, y, 1) end end
    T.poleU = thump(sq(18, 8, 0), POLE, false, {})
    T.carUp = addVehicleDebug("Base.CarNormal", IsoDirections.N, nil, sq(20, 11, 1))
    ok(T.carUp ~= nil, "U: car placed on the z1 floor")
    if T.carUp then log("U: car z before " .. T.carUp:getZ()) end
end

function T.dropCarUp()
    if not T.carUp then return end
    T.carUpZ = T.carUp:getZ()
    T.destroy(T.poleU)
end

function T.checkCarUp()
    if not T.carUp then return end
    local z = T.carUp:getZ()
    log("U: car z " .. tostring(T.carUpZ) .. " -> " .. z .. " (x " .. (T.carUp:getX() - T.ox) .. ", y " .. (T.carUp:getY() - T.oy) .. ")")
    local floorsUp = 0
    for x = 18, 21 do for y = 8, 13 do
        local s = getCell():getGridSquare(T.ox + x, T.oy + y, 1)
        if s and s:getFloor() then floorsUp = floorsUp + 1 end
    end end
    ok(floorsUp == 0, "U: the floor under the car came down (left at z1: " .. floorsUp .. ")")
    ok(z < 0.5, "U: the car came down to the ground (z " .. z .. ")")
end

-- H: a double-height hall at x 12..13, y 8..9: walls on z0 and the same walls again on z1 (no floor on z1),
-- a 2x2 floor on z2 resting on the z1 walls. Sledging every z0 wall must bring the z1 walls down to z0 (they are
-- a structure of their own now) and then the z2 floor down to z1 (it rests on those walls again).
local HALL = { { 12, 8, true }, { 13, 8, true }, { 12, 10, true }, { 13, 10, true },
    { 12, 8, false }, { 12, 9, false }, { 14, 8, false }, { 14, 9, false } }

function T.buildHall()
    T.hallLow = {}
    for i, w in ipairs(HALL) do
        local spr = w[3] and WALL_N or WALL_W
        T.hallLow[#T.hallLow + 1] = thump(sq(w[1], w[2], 0), spr, w[3], {})
        tag(thump(sq(w[1], w[2], 1), spr, w[3], {}), "HW" .. i)
    end
    for x = 12, 13 do for y = 8, 9 do tag(floorAt(x, y, 2), "HF" .. x .. y) end end
end

function T.sledgeHall()
    for _, o in ipairs(T.hallLow) do if o:getSquare() then T.destroy(o) end end
end

function T.checkHall()
    local down = 0
    for i = 1, #HALL do
        local _, s = T.find("HW" .. i)
        if s and s:getZ() == 0 then down = down + 1 end
    end
    ok(down == #HALL, "H: upper hall walls came down to z0 (" .. down .. "/" .. #HALL .. ")")
    local fl = 0
    for x = 12, 13 do for y = 8, 9 do
        local _, s = T.find("HF" .. x .. y)
        if s and s:getZ() == 1 then fl = fl + 1 end
    end end
    ok(fl == 4, "H: rooftop floor came down to z1 onto the fallen walls (" .. fl .. "/4)")
end

-- L: free-standing upper pieces. A street-light base at z0 (16,2) with a head at z1; a sign post at z0 (16,5)
-- with pieces at z1 and z2. Removing the bottoms must bring every piece above down to the ground.
function T.buildPieces()
    T.lampBase = plain(sq(16, 2, 0), "lighting_outdoor_01_16")
    tag(plain(sq(16, 2, 1), "lighting_outdoor_01_0"), "LH")
    T.signBase = plain(sq(16, 5, 0), "street_decoration_01_22")
    tag(plain(sq(16, 5, 1), "street_decoration_01_22"), "S1")
    tag(plain(sq(16, 5, 2), "street_decoration_01_22"), "S2")
end

function T.removeBottoms()
    for _, o in ipairs({ T.lampBase, T.signBase }) do
        if o and o:getSquare() then o:getSquare():transmitRemoveItemFromSquare(o) end
    end
end

function T.checkPieces()
    -- the lamp head falls to the ground; the sign's two pieces are one object and come down keeping their shape
    for _, e in ipairs({ { "LH", 0 }, { "S1", 0 }, { "S2", 1 } }) do
        local _, s = T.find(e[1])
        ok(s ~= nil and s:getZ() == e[2], "L: " .. e[1] .. " at z" .. e[2] .. " (" .. (s and rel(s) or "missing") .. ")")
    end
end

-- K: a big free-standing object of one sheet (billboard-like): legs at z0 (16,8) and (16,10), a panel at z1..z2
-- over x 16, y 8..10 whose middle column has nothing under it at z1 (y 9). Removing both legs must bring the
-- whole panel down one level, keeping its shape (z1 pieces to z0, z2 pieces to z1); removing only one leg must not.
function T.buildBillboard()
    T.bbLegs = { plain(sq(16, 8, 0), "advertising_01_0"), plain(sq(16, 10, 0), "advertising_01_0") }
    for y = 8, 10 do
        tag(plain(sq(16, y, 1), "advertising_01_1"), "K1" .. y)
        tag(plain(sq(16, y, 2), "advertising_01_2"), "K2" .. y)
    end
end

function T.removeOneLeg()
    local o = T.bbLegs[1]
    if o and o:getSquare() then o:getSquare():transmitRemoveItemFromSquare(o) end
end

function T.checkBillboardHeld()
    local _, s = T.find("K18")
    ok(s ~= nil and s:getZ() == 1, "K: one leg left holds the panel (" .. (s and rel(s) or "missing") .. ")")
end

function T.removeOtherLeg()
    local o = T.bbLegs[2]
    if o and o:getSquare() then o:getSquare():transmitRemoveItemFromSquare(o) end
end

-- J: a hanging object. A 2x2 floor at z1 (x 25..26, y 9..10) held by a pole at (25,9); beside it at z1 (27,10) a
-- piece that floats in vanilla style (nothing under it), touching the floor's edge. A crate at z0 (28,12).
-- Removing the crate (2 squares away) judges the piece again: it touches the floor, it stays. Sledging the pole
-- brings the floor down to z0; the piece then touches nothing and falls to the ground.
local function clearBox(x0, x1, y0, y1, z1)
    for z = 0, z1 do for x = x0, x1 do for y = y0, y1 do
        local s = getCell():getGridSquare(T.ox + x, T.oy + y, z)
        if s then
            local objs = s:getObjects()
            for i = objs:size() - 1, 0, -1 do
                local o = objs:get(i)
                if not (z == 0 and o == s:getFloor()) then s:transmitRemoveItemFromSquare(o) end
            end
        end
    end end end
end

local function taggedAt(x, y, z, t)
    local s = getCell():getGridSquare(T.ox + x, T.oy + y, z)
    local objs = s and s:getObjects()
    for i = 0, (objs and objs:size() or 0) - 1 do
        if objs:get(i):getModData().scTag == t then return true end
    end
    return false
end

function T.buildHanging()
    clearBox(23, 29, 7, 13, 2)
    for x = 25, 26 do for y = 9, 10 do floorAt(x, y, 1) end end
    T.poleJ = thump(sq(25, 9, 0), POLE, false, {})
    tag(plain(sq(27, 10, 1), "advertising_01_1"), "JH")
    T.crateJ = plain(sq(28, 12, 0), CRATE)
    ok(taggedAt(27, 10, 1, "JH"), "J: hanging piece placed")
end

function T.removeNearJ()
    local o = T.crateJ
    if o and o:getSquare() then o:getSquare():transmitRemoveItemFromSquare(o) end
end

function T.checkHangingHeld()
    ok(taggedAt(27, 10, 1, "JH"), "J: piece still hangs on the floor's edge after a removal 2 squares away")
end

function T.sledgeJ()
    T.destroy(T.poleJ)
end

function T.checkHanging()
    local floorsUp = 0
    for x = 25, 26 do for y = 9, 10 do
        local s = getCell():getGridSquare(T.ox + x, T.oy + y, 1)
        if s and s:getFloor() then floorsUp = floorsUp + 1 end
    end end
    ok(floorsUp == 0, "J: the floor came down (left at z1: " .. floorsUp .. ")")
    ok(not taggedAt(27, 10, 1, "JH") and taggedAt(27, 10, 0, "JH"), "J: the piece it hung on fell to the ground")
end

-- B: a vanilla-style floating piece above a wall the player built, then sledged (user 2026-11-10).
--   B1 at (32,9): pole z0, floor z1, wall on the N edge of the same square at z1, piece at z2 standing on the
--      wall. Sledging the wall: the piece falls onto the z1 floor (judged from below).
--   B2 at (35,9): pole z0, floor z1, piece at z2 touching a wall built on the N edge of the square south of it
--      (35,10) at z1 (not under the piece). Sledging the wall: nothing else touches the piece, it falls onto the
--      z1 floor (judged as a hanging object).
-- Z: the zombie path: a player-built wall (IsoThumpable) under a one-tile floor at z1 (32,12) is destroyed the
--    way a zombie's thumps end (IsoThumpable:destroy). The floor must come down to z0.
function T.buildBuilt()
    clearBox(30, 38, 7, 13, 2)
    T.poleB1 = thump(sq(32, 9, 0), POLE, false, {})
    floorAt(32, 9, 1)
    T.wallB1 = thump(sq(32, 9, 1), WALL_N, true, {})
    tag(plain(sq(32, 9, 2), "advertising_01_2"), "B1")
    T.poleB2 = thump(sq(35, 9, 0), POLE, false, {})
    floorAt(35, 9, 1)
    T.wallB2 = thump(sq(35, 10, 1), WALL_N, true, {})
    tag(plain(sq(35, 9, 2), "advertising_01_2"), "B2")
    T.wallZ = thump(sq(32, 12, 0), WALL_N, true, {})
    floorAt(32, 12, 1)
    ok(taggedAt(32, 9, 2, "B1") and taggedAt(35, 9, 2, "B2"), "B: pieces placed at z2")
end

function T.sledgeBuiltWalls()
    T.destroy(T.wallB1)
    T.destroy(T.wallB2)
end

function T.checkBuilt()
    ok(taggedAt(32, 9, 1, "B1"), "B1: piece on the sledged wall fell onto the z1 floor")
    ok(taggedAt(35, 9, 1, "B2"), "B2: piece beside the sledged wall fell onto the z1 floor")
end

function T.zombieBreaksWall()
    local okD, err = pcall(function() T.wallZ:destroy() end)
    ok(okD, "Z: IsoThumpable:destroy ran (" .. tostring(err) .. ")")
end

function T.checkZombieWall()
    local up = getCell():getGridSquare(T.ox + 32, T.oy + 12, 1)
    local down = getCell():getGridSquare(T.ox + 32, T.oy + 12, 0)
    ok(not (up and up:getFloor() and up:getFloor():getSprite() and up:getFloor():getSprite():getName() == FLOOR),
        "Z: the floor left z1 after its wall was broken")
    ok(down and down:getFloor() and down:getFloor():getSprite() and down:getFloor():getSprite():getName() == FLOOR,
        "Z: the floor is now at z0")
end

-- save round trip (two pzt runs, see pzt.conf comment): run 1 starts a collapse and quits a few frames later
-- (the game saves); run 2 continues that save and checks that the rest came down after loading.
function T.persistStart()
    local pl = getPlayer()
    pl:setGodMod(true); pl:setInvisible(true); pl:setZombiesDontAttack(true)
    T.ox, T.oy = math.floor(pl:getX()) + 4, math.floor(pl:getY()) + 4
    clearBox(-1, 6, -1, 6, 3)
    -- like P: a pole in the middle holds a 5x5 floor at z1, a second pole on it holds a 5x5 floor at z2
    for x = 0, 4 do for y = 0, 4 do floorAt(x, y, 1); floorAt(x, y, 2) end end
    T.poleS = thump(sq(2, 2, 0), POLE, false, {})
    thump(sq(2, 2, 1), POLE, false, {})
    getGameTime():getModData().scPersist = { ox = T.ox, oy = T.oy, n = 25 }
    -- slow the wave down (this run only) so the game quits while the collapse is still moving
    SC.RING_TICKS = 40
    T.poleS:getSquare():transmitRemoveItemFromSquare(T.poleS)
    log("persist: collapse of 5x5x2 started, quitting in a few frames")
end

function T.persistDiag()
    local res, n = SC.findGroup(T.ox + 2, T.oy + 2, 1)
    log("persist diag: findGroup -> " .. tostring(type(res) == "table" and "unsupported" or res) .. " visited " .. tostring(n))
    for x = -1, 5 do for y = -1, 5 do
        local s0 = getCell():getGridSquare(T.ox + x, T.oy + y, 0)
        local objs = s0 and s0:getObjects()
        for i = 0, (objs and objs:size() or 0) - 1 do
            local o = objs:get(i)
            if SC.isSupport(o) then log("persist diag: support at " .. x .. "," .. y .. ",0 " .. tostring(SC.spriteNameOf(o)) .. " " .. tostring(o)) end
        end
        local s1 = getCell():getGridSquare(T.ox + x, T.oy + y, 1)
        objs = s1 and s1:getObjects()
        for i = 0, (objs and objs:size() or 0) - 1 do
            local o = objs:get(i)
            if not SC.isFloorObj(o) then log("persist diag: z1 object at " .. x .. "," .. y .. " " .. tostring(SC.spriteNameOf(o))) end
        end
    end end
end

function T.persistCheck()
    local d = getGameTime():getModData().scPersist
    if not d then ok(false, "persist: no data from run 1"); return end
    local up, z1, z0 = 0, 0, 0
    for x = 0, 4 do for y = 0, 4 do
        local s2 = getCell():getGridSquare(d.ox + x, d.oy + y, 2)
        local s1 = getCell():getGridSquare(d.ox + x, d.oy + y, 1)
        local s0 = getCell():getGridSquare(d.ox + x, d.oy + y, 0)
        local function ours(sq_) return sq_ and sq_:getFloor() and sq_:getFloor():getSprite() and sq_:getFloor():getSprite():getName() == FLOOR end
        if ours(s2) then up = up + 1 end
        if ours(s1) then z1 = z1 + 1 end
        if ours(s0) then z0 = z0 + 1 end
    end end
    log("persist: floors z2=" .. up .. " z1=" .. z1 .. " z0=" .. z0)
    ok(up == 0 and z1 == d.n and z0 == d.n, "persist: after reload both levels came down one (z2 " .. up .. ", z1 " .. z1 .. ", z0 " .. z0 .. ")")
    PZTest.log("SCTest pass " .. T.pass .. " fail " .. T.fail)
end

-- Measure a real map pylon (steps in pzt.conf comment): frame time before, then all legs of the pylon at
-- (cx,cy) removed at once, frame time and the wire job while it runs.
local function frameSampler(store)
    local last = getTimestampMs()
    return function()
        local now = getTimestampMs()
        local dt = now - last
        last = now
        store.n = store.n + 1
        store.sum = store.sum + dt
        if dt > store.max then store.max = dt end
        if dt > 33 then
            store.slow = store.slow + 1
            store.slowAt = (store.slowAt or "") .. string.format(" frame %d: %d ms (mod busy %s, jobs %d)", store.n, dt,
                tostring(SC.pending()), #SC.jobs)
        end
    end
end

local function zombiesNear(x, y, r)
    local n = 0
    local list = getCell():getZombieList()
    for i = 0, list:size() - 1 do
        local z = list:get(i)
        if math.abs(z:getX() - x) <= r and math.abs(z:getY() - y) <= r then n = n + 1 end
    end
    return n
end

function T.pylonBaseline()
    getPlayer():setGodMod(true); getPlayer():setInvisible(true); getPlayer():setZombiesDontAttack(true)
    T.base = { n = 0, sum = 0, max = 0, slow = 0 }
    T.baseFn = frameSampler(T.base)
    Events.OnTick.Add(T.baseFn)
end

function T.pylonBaselineReport()
    Events.OnTick.Remove(T.baseFn)
    log(string.format("pylon measure control (nothing removed): frames %d avg %.1fms max %dms slow(>33ms) %d:%s",
        T.base.n, T.base.sum / math.max(1, T.base.n), T.base.max, T.base.slow, T.base.slowAt or ""))
    PZTest.log("SCTest pass " .. T.pass .. " fail " .. T.fail)
end

function T.pylonMeasureStart(cx, cy)
    Events.OnTick.Remove(T.baseFn)
    local legs = {}
    for x = cx - 6, cx + 6 do for y = cy - 6, cy + 6 do
        local s = getCell():getGridSquare(x, y, 0)
        local objs = s and s:getObjects()
        for i = 0, (objs and objs:size() or 0) - 1 do
            local o = objs:get(i)
            local n = SC.spriteNameOf(o)
            local idx = n and tonumber(string.match(n, "^electricity_pylon_(%d+)$"))
            if idx and idx <= 11 then legs[#legs + 1] = o end
        end
    end end
    local lines = 0
    for z = 1, 8 do for x = cx - 120, cx + 120 do for y = cy - 120, cy + 120 do
        local s = getCell():getGridSquare(x, y, z)
        local objs = s and s:getObjects()
        for i = 0, (objs and objs:size() or 0) - 1 do
            if SC.isHVLine(objs:get(i)) then lines = lines + 1 end
        end
    end end end
    log(string.format("pylon measure: %d legs, %d HV line pieces loaded within 120, zombies within 60: %d, baseline frames %d avg %.1fms max %dms slow(>33ms) %d",
        #legs, lines, zombiesNear(cx, cy, 60), T.base.n, T.base.sum / math.max(1, T.base.n), T.base.max, T.base.slow))
    T.lines0 = lines
    T.meas = { n = 0, sum = 0, max = 0, slow = 0 }
    T.measFn = frameSampler(T.meas)
    Events.OnTick.Add(T.measFn)
    T.measT0 = getTimestampMs()
    SC.lastWires = nil
    local tr = getTimestampMs()
    for _, o in ipairs(legs) do
        if o:getSquare() then o:getSquare():transmitRemoveItemFromSquare(o) end
    end
    log("pylon measure: removing the legs took " .. (getTimestampMs() - tr) .. " ms (vanilla removal + the mod's event handler)")
    T.mcx, T.mcy = cx, cy
end

function T.pylonMeasureEnd()
    Events.OnTick.Remove(T.measFn)
    local w = SC.lastWires
    local lines = 0
    for z = 1, 8 do for x = T.mcx - 120, T.mcx + 120 do for y = T.mcy - 120, T.mcy + 120 do
        local s = getCell():getGridSquare(x, y, z)
        local objs = s and s:getObjects()
        for i = 0, (objs and objs:size() or 0) - 1 do
            if SC.isHVLine(objs:get(i)) then lines = lines + 1 end
        end
    end end end
    log(string.format("pylon measure: pending=%s wires=%s squares=%s broken=%s items=%s tower=%s ticks=%s; lines left within 120: %d of %d",
        tostring(SC.pending()), tostring(w and w.kind), tostring(w and w.squares), tostring(w and w.broken),
        tostring(w and w.items), tostring(w and w.tower), tostring(w and w.ticks), lines, T.lines0 or -1))
    log(string.format("pylon measure: frames during %d avg %.1fms max %dms slow(>33ms) %d:%s",
        T.meas.n, T.meas.sum / math.max(1, T.meas.n), T.meas.max, T.meas.slow, T.meas.slowAt or ""))
    ok(w ~= nil and w.kind == "pylon" and (w.broken or 0) > 0, "pylon measure: the tower fell and lines broke")
    PZTest.log("SCTest pass " .. T.pass .. " fail " .. T.fail)
end

function T.checkBillboard()
    for y = 8, 10 do
        for lvl = 1, 2 do
            local _, s = T.find("K" .. lvl .. y)
            ok(s ~= nil and s:getZ() == lvl - 1, "K: K" .. lvl .. y .. " at z" .. (lvl - 1) .. " (" .. (s and rel(s) or "missing") .. ")")
        end
    end
end

-- W: a utility pole at (15,9) (foot z0, trunk z1, cross-arm top z2) with a wire line at z2 along x 15, y 6..11.
-- Sledging the foot must break all six wire pieces and drop ElectricWire (every 2nd piece in this test -> 3).
function T.buildPole()
    T.poleFoot = plain(sq(15, 9, 0), "appliances_com_01_88")
    plain(sq(15, 9, 1), "appliances_com_01_89")
    plain(sq(15, 9, 2), "appliances_com_01_90")
    for y = 6, 11 do plain(sq(15, y, 2), "appliances_com_01_109") end
end

local function wiresLeft()
    local n = 0
    for y = 6, 11 do
        local s = getCell():getGridSquare(T.ox + 15, T.oy + y, 2)
        local objs = s and s:getObjects()
        for i = 0, (objs and objs:size() or 0) - 1 do
            if SC.isWire(objs:get(i)) then n = n + 1 end
        end
    end
    return n
end

function T.sledgePole()
    T.wireEvery = SC.WIRE_ITEM_EVERY
    SC.WIRE_ITEM_EVERY = 2
    ok(wiresLeft() == 6, "W: six wire pieces before")
    T.destroy(T.poleFoot)
end

function T.checkPole()
    SC.WIRE_ITEM_EVERY = T.wireEvery
    ok(wiresLeft() == 0, "W: wires broke (" .. wiresLeft() .. " left)")
    local items = 0
    for y = 6, 11 do items = items + T.countItems(15, y, 0, "Base.ElectricWire") end
    ok(items == 3, "W: electric wire dropped (" .. items .. ")")
end

-- X: two high-voltage pylons and a line at z6 along y 1, x 18..40, passing 2 squares off both towers (as on the
-- map). A: legs at z0 (20,3) and (22,3), a body piece at z1 (21,3), an arm at z6 (21,3). B: a leg at (34,3) and an
-- arm at z6. Sledging one of A's legs changes nothing (the tower stands on the other one). Sledging the second
-- makes A fall: its pieces go, the span from A up to B's reach breaks (x 18..30, 13 pieces) and the part at B
-- (x 31..40, 10 pieces) stays.
function T.buildPylons()
    for z = 0, 7 do
        for x = 17, 41 do
            for y = 0, 6 do
                local s = getCell():getGridSquare(T.ox + x, T.oy + y, z)
                if s then
                    local objs = s:getObjects()
                    for i = objs:size() - 1, 0, -1 do
                        local o = objs:get(i)
                        if not (z == 0 and o == s:getFloor()) then s:transmitRemoveItemFromSquare(o) end
                    end
                end
            end
        end
    end
    T.pylonLegs = { plain(sq(20, 3, 0), "electricity_pylon_1"), plain(sq(22, 3, 0), "electricity_pylon_3") }
    tag(plain(sq(21, 3, 1), "electricity_pylon_12"), "XB")
    tag(plain(sq(21, 3, 6), "electricity_pylon_64"), "XA")
    plain(sq(34, 3, 0), "electricity_pylon_1")
    plain(sq(34, 3, 6), "electricity_pylon_64")
    for x = 18, 40 do plain(sq(x, 1, 6), "electricity_pylon_165") end
end

local function hvLeft(x0, x1)
    local n = 0
    for x = x0, x1 do
        local s = getCell():getGridSquare(T.ox + x, T.oy + 1, 6)
        local objs = s and s:getObjects()
        for i = 0, (objs and objs:size() or 0) - 1 do
            if SC.isHVLine(objs:get(i)) then n = n + 1 end
        end
    end
    return n
end

-- is the tagged tower piece still on its square (T.find only looks at the main test area, z0..2)
local function towerPiece(x, y, z, t)
    local s = getCell():getGridSquare(T.ox + x, T.oy + y, z)
    local objs = s and s:getObjects()
    for i = 0, (objs and objs:size() or 0) - 1 do
        if objs:get(i):getModData().scTag == t then return true end
    end
    return false
end

function T.sledgePylon()
    T.wireEvery = SC.WIRE_ITEM_EVERY
    SC.WIRE_ITEM_EVERY = 2
    ok(hvLeft(18, 40) == 23, "X: 23 line pieces before (" .. hvLeft(18, 40) .. ")")
    T.destroy(T.pylonLegs[1])
end

function T.checkPylonStands()
    ok(hvLeft(18, 40) == 23, "X: one leg left: no line broke (" .. hvLeft(18, 40) .. "/23)")
    ok(towerPiece(21, 3, 6, "XA") and towerPiece(21, 3, 1, "XB"), "X: one leg left: tower pieces still there")
end

function T.sledgePylon2()
    T.destroy(T.pylonLegs[2])
end

function T.checkPylon()
    ok(not towerPiece(21, 3, 6, "XA") and not towerPiece(21, 3, 1, "XB"), "X: the fallen tower's pieces are gone")
    SC.WIRE_ITEM_EVERY = T.wireEvery
    ok(hvLeft(18, 30) == 0, "X: span from A broke (" .. hvLeft(18, 30) .. " left)")
    ok(hvLeft(31, 40) == 10, "X: line at B stayed (" .. hvLeft(31, 40) .. "/10)")
    local items = 0
    for x = 18, 30 do items = items + T.countItems(x, 1, 0, "Base.ElectricWire") end
    ok(items == 6, "X: electric wire dropped (" .. items .. "/6)")
    ok(SC.lastWires and SC.lastWires.kind == "pylon", "X: wire job was a pylon job")
end

-- a zombie standing under P (z0, tile 2,2): the falling floor must hit it
function T.zombieUnderP()
    local list = addZombiesInOutfit(T.ox + 2, T.oy + 2, 0, 1, nil, 0)
    T.zed = list and list:size() > 0 and list:get(0) or nil
    if T.zed then T.zedHealth = T.zed:getHealth() end
    ok(T.zed ~= nil, "zombie placed under P")
end

local function floorObjAt(x, y, z)
    local s = getCell():getGridSquare(T.ox + x, T.oy + y, z)
    return s and s:getFloor()
end

function T.cutStrip()
    T.collapsesBeforeF = SC.stats.collapses
    local f = floorObjAt(2, 9, 1)
    ok(f ~= nil, "F: middle floor exists before the cut")
    if f then f:getSquare():transmitRemoveItemFromSquare(f) end
end


-- the player stands under R (z0, tile 0,5) with god mode off for this one hit
function T.playerUnderR()
    local pl = getPlayer()
    PZTest.teleport(T.ox + 0, T.oy + 5, 0)
    pl:setGodMod(false)
    pl:getBodyDamage():RestoreToFullHealth()
    T.headBefore = pl:getBodyDamage():getBodyPart(BodyPartType.Head):getHealth()
end

function T.checkPlayerHit()
    local pl = getPlayer()
    local head = pl:getBodyDamage():getBodyPart(BodyPartType.Head)
    local after = head:getHealth()
    ok(after < T.headBefore, string.format("R: player under the falling floor hit on the head (%.1f -> %.1f)", T.headBefore, after))
    ok(SC.last and SC.last.report.hit >= 1, "R: collapse report counts the hit")
    pl:getBodyDamage():RestoreToFullHealth()
    pl:setGodMod(true)
end

function T.checkZombieHit()
    if not T.zed then return end
    ok(T.zed:isDead(), "P: zombie under the falling floor killed (health " .. tostring(T.zedHealth) .. " - " .. SC.ZOMBIE_DAMAGE .. "; dead=" .. tostring(T.zed:isDead()) .. ")")
end

-- find a tagged object anywhere in the test area: returns object, square
local function find(t)
    for z = 0, 2 do
        for x = -1, 16 do
            for y = -1, 11 do
                local s = getCell():getGridSquare(T.ox + x, T.oy + y, z)
                if s then
                    local objs = s:getObjects()
                    for i = 0, objs:size() - 1 do
                        local o = objs:get(i)
                        if o:getModData().scTag == t then return o, s end
                        if instanceof(o, "IsoWorldInventoryObject") and o:getItem()
                            and o:getItem():getModData().scTag == t then return o, s end
                    end
                end
            end
        end
    end
    return nil
end
T.find = find

function T.checkStrip()
    ok(SC.stats.collapses == T.collapsesBeforeF + 1, "F: one collapse after the cut (" .. (SC.stats.collapses - T.collapsesBeforeF) .. ")")
    for x = 0, 1 do
        local _, s = T.find("F" .. x)
        ok(s ~= nil and s:getZ() == 1, "F: x" .. x .. " (held by the pole) stays at z1")
    end
    for x = 3, 4 do
        local _, s = T.find("F" .. x)
        ok(s ~= nil and s:getZ() == 0, "F: x" .. x .. " (cut off) dropped to z0")
    end
    local fc, fs = T.find("FC")
    ok(fc ~= nil and fs:getZ() == 0, "F: crate on the cut tile fell to z0 (" .. (fs and rel(fs) or "missing") .. ")")
    if fc then ok(fc:getContainer():getItems():size() == 1, "F: fallen crate still holds its apple") end
end

local function floors(x, y, z)
    local s = getCell():getGridSquare(T.ox + x, T.oy + y, z)
    local n, ours = 0, 0
    if not s then return 0, 0 end
    local objs = s:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        if o:getProperties() and o:getProperties():has(IsoFlagType.solidfloor) then
            n = n + 1
            if o:getSprite() and o:getSprite():getName() == FLOOR then ours = ours + 1 end
        end
    end
    return n, ours
end

local function countItems(x, y, z, fullType)
    local s = getCell():getGridSquare(T.ox + x, T.oy + y, z)
    local n = 0
    if not s then return 0 end
    local wo = s:getWorldObjects()
    for i = 0, wo:size() - 1 do
        local it = wo:get(i):getItem()
        if it and it:getFullType() == fullType then n = n + 1 end
    end
    return n
end
T.countItems = countItems

local function destroy(obj)
    local a = ISDestroyStuffAction:new(getPlayer(), obj)
    return a:complete()
end
T.destroy = destroy

function T.checkP()
    ok(SC.stats.collapses == 1, "P: one collapse (" .. SC.stats.collapses .. ")")
    for x = 0, 2 do
        for y = 0, 2 do
            local n, ours = floors(x, y, 0)
            ok(n == 1 and ours == 1, "P: z0 " .. x .. "," .. y .. " one floor, ours (floors " .. n .. ", ours " .. ours .. ")")
            if not (x == 1 and y == 1) then
                local n1 = floors(x, y, 1)
                ok(n1 == 0, "P: z1 " .. x .. "," .. y .. " empty (floors " .. n1 .. ")")
            end
        end
    end
    local w, ws = find("wallP")
    ok(w ~= nil and rel(ws) == "0,0,0" and w:getProperties():has(IsoFlagType.WallN), "P: wall moved to 0,0,0 (" .. (ws and rel(ws) or "missing") .. ")")
    local c1, cs = find("C1")
    ok(c1 ~= nil and cs:getZ() == 0, "P: crate C1 at z0 (" .. (cs and rel(cs) or "missing") .. ")")
    if c1 then
        ok(rel(cs) ~= "0,1,0", "P: C1 pushed off the blocker tile")
        local dx, dy = math.abs(cs:getX() - (T.ox + 0)), math.abs(cs:getY() - (T.oy + 1))
        ok(dx + dy == 1, "P: C1 on a neighbour tile (dist " .. (dx + dy) .. ")")
        ok(c1:getContainer():getItems():size() == 3, "P: C1 still holds 3 apples (" .. c1:getContainer():getItems():size() .. ")")
        ok(c1:getModData().scKeep == 42, "P: C1 modData kept")
        ok(c1:getContainer():getSourceGrid() == cs, "P: C1 container source square updated")
    end
    local b1, bs = find("B1")
    ok(b1 ~= nil and rel(bs) == "0,1,0", "P: blocker B1 stays at 0,1,0")
    if T.twoTile then
        local a, as = find("TT1"); local b, bsq = find("TT2")
        ok(a and b and as:getZ() == 0 and bsq:getZ() == 0, "P: two-tile furniture both parts at z0")
        if a and b then
            ok((bsq:getX() - as:getX()) + (bsq:getY() - as:getY()) == 1, "P: two-tile parts still side by side")
        end
    end
    local pen, ps = find("pen")
    ok(pen ~= nil and rel(ps) == "2,0,0", "P: world item at 2,0,0 (" .. (ps and rel(ps) or "missing") .. ")")
    local pu, pus = find("poleUpper")
    ok(pu ~= nil and rel(pus) == "1,1,0", "P: upper pole now at 1,1,0 (" .. (pus and rel(pus) or "missing") .. ")")
    local f2, f2s = find("z2floor")
    ok(f2 ~= nil and rel(f2s) == "1,1,1", "P: z2 floor now at 1,1,1 (" .. (f2s and rel(f2s) or "missing") .. ")")
    for x = 6, 8 do for y = 0, 2 do
        ok(floors(x, y, 1) == 1, "Q untouched: z1 " .. x .. "," .. y)
    end end
end

function T.checkQ()
    ok(SC.lastCheck and SC.lastCheck.res == "supported", "Q: wall D removed, group still supported (" .. tostring(SC.lastCheck and SC.lastCheck.res) .. ")")
    log("Q check visited=" .. tostring(SC.lastCheck and SC.lastCheck.visited) .. " ms=" .. tostring(SC.lastCheck and SC.lastCheck.ms))
    ok(SC.stats.collapses == 1, "Q: no new collapse")
    for x = 6, 8 do for y = 0, 2 do
        ok(floors(x, y, 1) == 1, "Q: z1 " .. x .. "," .. y .. " still there")
    end end
end

function T.checkR()
    ok(SC.stats.collapses == 2, "R: collapsed (" .. SC.stats.collapses .. ")")
    ok(find("S") == nil, "R: crate S broken")
    local b2, bs = find("B2")
    ok(b2 ~= nil and rel(bs) == "2,7,0", "R: blocker B2 stays")
    if T.sHasContainer then
        ok(countItems(2, 7, 0, "Base.Apple") == 2, "R: S contents dropped (apples " .. countItems(2, 7, 0, "Base.Apple") .. ")")
    end
    ok(countItems(2, 7, 0, "Base.Plank") == 4, "R: S materials dropped (planks " .. countItems(2, 7, 0, "Base.Plank") .. ")")
end

-- ---------------------------------------------------------------- vanilla building
-- The smallest loaded map building with an upper floor near the player: remove every support on its ground
-- floor in one tick (sledgehammer path) and check that each upper floor tile's floor sprite is now one level down.

local function floorSprite(s)
    if not s then return nil end
    local objs = s:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        if not instanceof(o, "IsoWorldInventoryObject") and o:getProperties()
            and o:getProperties():has(IsoFlagType.solidfloor) and SC.edgeOf(o) == nil then
            return o:getSprite() and o:getSprite():getName()
        end
    end
    return nil
end

function T.findHouse()
    local pl = getPlayer()
    local px, py = math.floor(pl:getX()), math.floor(pl:getY())
    local houses = {}
    for x = px - 60, px + 60 do
        for y = py - 60, py + 60 do
            local s = getCell():getGridSquare(x, y, 1)
            local b = s and s:getBuilding()
            if b and floorSprite(s) then
                local k = tostring(b)
                houses[k] = houses[k] or { tiles = {} }
                table.insert(houses[k].tiles, { x = x, y = y, sprite = floorSprite(s) })
            end
        end
    end
    local best
    for _, h in pairs(houses) do
        if #h.tiles >= 6 and (best == nil or #h.tiles < #best.tiles) then best = h end
    end
    return best
end

function T.vanillaFind()
    T.house = T.findHouse()
    if not T.house then ok(false, "vanilla: no loaded building with an upper floor within 60 tiles"); return end
    local minx, miny, maxx, maxy = 1e9, 1e9, -1e9, -1e9
    for _, t in ipairs(T.house.tiles) do
        minx = math.min(minx, t.x); miny = math.min(miny, t.y); maxx = math.max(maxx, t.x); maxy = math.max(maxy, t.y)
    end
    T.house.box = { minx, miny, maxx, maxy }
    log(string.format("vanilla house: %d upper floor tiles, box %d,%d..%d,%d", #T.house.tiles, minx, miny, maxx, maxy))
    -- stand outside the south-east corner, ground level, looking at the house
    PZTest.teleport(maxx + 3, maxy + 3, 0)
end

function T.vanillaDemolish()
    if not T.house then return end
    T.collapsesBefore = SC.stats.collapses
    -- the whole upper floor group the house belongs to: it can reach past the building (porch roofs, eaves)
    local group, queue, inG = {}, {}, {}
    for _, t in ipairs(T.house.tiles) do
        local k = t.x .. "," .. t.y
        if not inG[k] then inG[k] = true; queue[#queue + 1] = { x = t.x, y = t.y } end
    end
    local head = 1
    while head <= #queue and #queue < 3000 do
        local t = queue[head]; head = head + 1
        group[#group + 1] = t
        for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
            local nx, ny = t.x + d[1], t.y + d[2]
            local k = nx .. "," .. ny
            if not inG[k] and SC.isGroupTile(getCell():getGridSquare(nx, ny, 1)) then
                inG[k] = true; queue[#queue + 1] = { x = nx, y = ny }
            end
        end
    end
    T.house.group = #group
    log("vanilla: upper floor group " .. #group .. " tiles (house " .. #T.house.tiles .. ")")
    -- every support on the ground floor under the group and 2 squares around it: the upper walls and posts are
    -- joined into one structure with the floor, and one wall left standing next to the footprint holds it all
    local list, seen = {}, {}
    for _, t in ipairs(group) do
        for dx = -2, 2 do for dy = -2, 2 do
            local s = getCell():getGridSquare(t.x + dx, t.y + dy, 0)
            if s then
                local objs = s:getObjects()
                for i = 0, objs:size() - 1 do
                    local o = objs:get(i)
                    if SC.isSupport(o) and not seen[o] then seen[o] = true; list[#list + 1] = o end
                end
            end
        end end
    end
    local n = 0
    for _, o in ipairs(list) do
        if o:getSquare() then
            local okD = pcall(function() ISDestroyStuffAction:new(getPlayer(), o):complete() end)
            if o:getSquare() and o:getSquare():getObjects():contains(o) then
                -- the action declined (e.g. a stair part removed with its staircase): remove it directly
                o:getSquare():transmitRemoveItemFromSquare(o)
            end
            n = n + 1
        end
    end
    T.house.removed = n
    log("vanilla: removed " .. n .. " ground-floor supports in one tick")
end

function T.vanillaCheck()
    if not T.house then return end
    -- what is left holding it (if anything): a fresh search from the first house tile
    local t1 = T.house.tiles[1]
    local res, visited = SC.findGroup(t1.x, t1.y, 1)
    log("vanilla: search at the first house tile on z1 (nofloor = it came down) -> " .. tostring(type(res) == "table" and "unsupported" or res)
        .. " visited " .. tostring(visited))
    ok(SC.stats.collapses > T.collapsesBefore, "vanilla: collapsed (" .. (SC.stats.collapses - T.collapsesBefore) .. " groups)")
    local same, total = 0, #T.house.tiles
    for _, t in ipairs(T.house.tiles) do
        if floorSprite(getCell():getGridSquare(t.x, t.y, 0)) == t.sprite then same = same + 1 end
    end
    ok(same == total, "vanilla: upper floor sprite now on the ground floor at " .. same .. "/" .. total .. " tiles")
    -- the emptied top level stops being part of a map room
    if SC.last and SC.last.top then
        local empty, cleared = 0, 0
        for _, t in ipairs(T.house.tiles) do
            local s = getCell():getGridSquare(t.x, t.y, SC.last.top)
            if s and not s:getFloor() then
                empty = empty + 1
                if s:getRoomID() == -1 then cleared = cleared + 1 end
            end
        end
        ok(cleared == empty, "vanilla: emptied top-level squares left their room (" .. cleared .. "/" .. empty .. ")")
    end
    if SC.last then
        local r = SC.last.report
        log(string.format("vanilla last collapse: tiles=%d moved=%d pushed=%d furnitureBroken=%d",
            SC.last.tiles, r.moved, r.pushed, r.broken))
    end
end

-- what still holds the house up: every object on the ground floor around the box that counts as a support
function T.probe()
    if not T.house then log("probe: no house"); return end
    local b = T.house.box
    for x = b[1] - 1, b[3] + 1 do
        for y = b[2] - 1, b[4] + 1 do
            local s = getCell():getGridSquare(x, y, 0)
            if s then
                local objs = s:getObjects()
                for i = 0, objs:size() - 1 do
                    local o = objs:get(i)
                    if SC.isSupport(o) then
                        local p = o:getProperties()
                        local f = {}
                        for _, n in ipairs({ "WallN", "WallW", "WallNW", "WallSE", "cutN", "cutW", "WallOverlay", "attachedN", "attachedW", "halfheight", "doorFrN" }) do
                            if IsoFlagType[n] and p:has(IsoFlagType[n]) then f[#f + 1] = n end
                        end
                        log(string.format("probe support %d,%d %s %s edge=%s stairs=%s flags=%s", x, y,
                            tostring(o:getSprite() and o:getSprite():getName()), tostring(o:getObjectName()),
                            tostring(SC.edgeOf(o)), tostring(SC.isStairs(o)), table.concat(f, "|")))
                    end
                end
            end
        end
    end
    local held = 0
    for _, t in ipairs(T.house.tiles) do
        if SC.tileSupported(t.x, t.y, 1) then held = held + 1 end
    end
    log("probe: " .. held .. "/" .. #T.house.tiles .. " upper tiles directly supported now")
end

T.stage, T.waited = "build", 0

local stages = {
    { "build", function()
        local pl = getPlayer()
        pl:setGodMod(true); pl:setInvisible(true); pl:setZombiesDontAttack(true)
        pl:setBuildCheat(true)
        T.ox, T.oy = math.floor(pl:getX()) + 4, math.floor(pl:getY()) + 4
        log("origin " .. T.ox .. "," .. T.oy)
        clearArea()
        SC.stats.collapses = 0
        T.build()
        T.spawnCarV()
    end },
    { "shot before", function() PZTest.shot("before") end },
    { "zombie under P", T.zombieUnderP },
    { "destroy A", function() ok(destroy(T.poleA) ~= false, "destroy pole A ran") end },
    { "check P", function() T.checkP(); T.checkZombieHit(); T.checkBody() end },
    { "destroy D", function() ok(destroy(T.wallD) ~= false, "destroy wall D ran") end },
    { "check Q", T.checkQ },
    { "player under R", T.playerUnderR },
    { "destroy C", function()
        T.radius, T.chance = SC.PUSH_RADIUS, SC.DROP_CHANCE
        SC.PUSH_RADIUS, SC.DROP_CHANCE = 0, 100
        ok(destroy(T.poleC) ~= false, "destroy pole C ran")
    end },
    { "check R", function()
        T.checkR()
        T.checkPlayerHit()
        SC.PUSH_RADIUS, SC.DROP_CHANCE = T.radius, T.chance
    end },
    { "cut floor strip F", T.cutStrip },
    { "check F", T.checkStrip },
    { "build roof T", T.buildRoof },
    { "sledge low roof T", T.sledgeLowRoof },
    { "check T", T.checkRoof },
    { "sledge roof walls T", T.sledgeRoofWalls },
    { "check T ground", T.checkRoofOnGround },
    { "build hall H", T.buildHall },
    { "sledge hall H", T.sledgeHall },
    { "check H", T.checkHall },
    { "build pieces L", T.buildPieces },
    { "remove bottoms L", T.removeBottoms },
    { "check L", T.checkPieces },
    { "build billboard K", T.buildBillboard },
    { "remove one leg K", T.removeOneLeg },
    { "check K held", T.checkBillboardHeld },
    { "remove other leg K", T.removeOtherLeg },
    { "check K", T.checkBillboard },
    { "build hanging J", T.buildHanging },
    { "remove crate near J", T.removeNearJ },
    { "check J held", T.checkHangingHeld },
    { "sledge pole J", T.sledgeJ },
    { "check J", T.checkHanging },
    { "build built walls B", T.buildBuilt },
    { "sledge built walls B", T.sledgeBuiltWalls },
    { "check B", T.checkBuilt },
    { "zombie breaks wall Z", T.zombieBreaksWall },
    { "check Z", T.checkZombieWall },
    { "build pole W", T.buildPole },
    { "sledge pole W", T.sledgePole },
    { "check W", T.checkPole },
    { "build pylons X", T.buildPylons },
    { "sledge pylon X", T.sledgePylon },
    { "check X stands", T.checkPylonStands },
    { "sledge last leg X", T.sledgePylon2 },
    { "check X", T.checkPylon },
    { "build car V", T.buildCar },
    { "drop on car V", T.dropOnCar },
    { "check V", T.checkCar },
    { "build car on floor U", T.buildCarUp },
    { "drop floor under car U", T.dropCarUp },
    { "let car settle U", function() end },
    { "check U", T.checkCarUp },
    { "shot", function() PZTest.shot("after") end },
    { "vanilla find", T.vanillaFind },
    { "vanilla shot before", function() PZTest.shot("house_before") end },
    { "vanilla demolish", T.vanillaDemolish },
    { "vanilla check", T.vanillaCheck },
    { "vanilla shot after", function() PZTest.shot("house_after") end },
}

function T.poll()
    -- collapses move things over several ticks: wait until nothing is pending before the next stage
    if SC.pending and SC.pending() then
        PZTest.step("wait 10")
        PZTest.step("lua StructuralCollapseTest.poll()")
        return
    end
    T.i = (T.i or 0) + 1
    local st = stages[T.i]
    if not st then
        PZTest.log("SCTest pass " .. T.pass .. " fail " .. T.fail)
        return
    end
    log("stage " .. st[1])
    local okRun, err = pcall(st[2])
    if not okRun then ok(false, "stage " .. st[1] .. " error: " .. tostring(err)) end
    PZTest.step("wait 20")
    PZTest.step("lua StructuralCollapseTest.poll()")
end
