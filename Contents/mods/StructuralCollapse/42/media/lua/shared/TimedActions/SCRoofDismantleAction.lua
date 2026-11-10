-- StructuralCollapse: dismantle a roof piece (user 2026-11-10). Vanilla roof tiles have no CanScrap, so they can't
-- be dismantled; this action takes one roof piece off with a hammer and gives back some of what it was made of.
-- Reach is vanilla's: the player stands on the roof's level (stairs, a ladder, or a roof that came down).
-- complete() runs where the world is simulated (single player, or the server), like vanilla ISDismantleAction.
require "TimedActions/ISBaseTimedAction"

SCRoofDismantleAction = ISBaseTimedAction:derive("SCRoofDismantleAction")
local A = SCRoofDismantleAction

-- What a roof piece gives back, by kind. Chance in %, rolled once per entry; +3% per level of the skill.
-- Kinds come from the roof sheets' pictures (2026-11-10): grid = shingles, brown boards = wood, coloured boards =
-- sheet metal, plain = flat roof membrane, trims and burnt roofs.
A.DROPS = {
    shingle = { perk = "Woodwork", items = { { "Base.Nails", 50 }, { "Base.Plank", 20 }, { "Base.UnusableWood", 20 } } },
    wood = { perk = "Woodwork", items = { { "Base.Nails", 50 }, { "Base.Plank", 30 } } },
    metal = { perk = "MetalWelding", items = { { "Base.SmallSheetMetal", 40 }, { "Base.ScrapMetal", 30 } } },
    flat = { perk = "Woodwork", items = { { "Base.UnusableWood", 20 } } },
    trim = { perk = "Woodwork", items = { { "Base.UnusableWood", 20 } } },
}
A.SKILL_BONUS = 3     -- % per skill level
A.CHANCE_MAX = 95

-- sheets with two roofs: the second roof group starts at tile 32 of its row block (RoofGroup in the tile defs)
local TWO = {
    roofs_01 = { "shingle", "metal" },   -- grey shingles / red boards
    roofs_02 = { "shingle", "flat" },    -- brown shingles / blue-grey flat
    roofs_03 = { "wood", "metal" },      -- brown boards / green boards
    roofs_04 = { "metal", "metal" },     -- pink boards / white boards
    roofs_05 = { "shingle", "shingle" }, -- green / grey shingles
}
local ONE = {
    roofs_30_01 = "shingle", roofs_30_02 = "shingle", roofs_30_05 = "shingle", roofs_30_06 = "shingle",
    roofs_shallow_01 = "shingle",
    roofs_30_07 = "wood", roofs_30_10 = "wood",
    roofs_30_03 = "metal", roofs_30_08 = "metal", roofs_30_09 = "metal",
    roofs_30_04 = "flat",
}

local function spriteName(o)
    local sp = o and o:getSprite()
    return (sp and sp:getName()) or (o and o:getSpriteName())
end

-- the kind of a roof piece; nil when it is not a roof piece
function A.kindOf(o)
    if not o or instanceof(o, "IsoWorldInventoryObject") then return nil end
    local n = spriteName(o)
    if n then
        local sheet, idx = string.match(n, "^(roofs_.-)_(%d+)$")
        if sheet then
            if string.find(sheet, "accents", 1, true) or string.find(sheet, "burnt", 1, true) then return "trim" end
            if ONE[sheet] then return ONE[sheet] end
            local two = TWO[sheet]
            if two then
                local props = o:getProperties()
                local g = props and props:has("RoofGroup") and tonumber(props:get("RoofGroup"))
                -- odd groups (1, 3, 5, 7, 9) are each sheet's first roof
                if g then return (g % 2 == 1) and two[1] or two[2] end
                return two[1]
            end
            return "shingle"
        end
    end
    local t = o:getType()
    if t == IsoObjectType.WestRoofB or t == IsoObjectType.WestRoofM or t == IsoObjectType.WestRoofT then return "shingle" end
    return nil
end

local function predicateNotBroken(item) return not item:isBroken() end

function A.hasTool(character)
    return character:getInventory():containsTagEval(ItemTag.HAMMER, predicateNotBroken)
end

function A:isValid()
    local sq = self.roof:getSquare()
    if not sq or self.roof:getObjectIndex() == -1 then return false end
    if math.floor(self.character:getZ()) ~= sq:getZ() then return false end
    local dx = math.abs(sq:getX() + 0.5 - self.character:getX())
    local dy = math.abs(sq:getY() + 0.5 - self.character:getY())
    return A.hasTool(self.character) and dx <= 1.6 and dy <= 1.6
end

function A:waitToStart()
    self.character:faceThisObject(self.roof)
    return self.character:shouldBeTurning()
end

function A:update()
    self.character:faceThisObject(self.roof)
    self.character:setMetabolicTarget(Metabolics.UsingTools)
end

function A:start()
    self:setActionAnim("Build")
    self:setOverrideHandModels("Hammer", nil)
end

function A:stop()
    ISBaseTimedAction.stop(self)
end

function A:perform()
    ISBaseTimedAction.perform(self)
end

-- items for one roof piece of this kind, for this character
function A.rollDrops(kind, character)
    local def = A.DROPS[kind]
    local out = {}
    if not def then return out end
    local level = 0
    if character and Perks[def.perk] then level = character:getPerkLevel(Perks[def.perk]) end
    for _, e in ipairs(def.items) do
        local chance = math.min(A.CHANCE_MAX, e[2] + level * A.SKILL_BONUS)
        if ZombRand(100) < chance then out[#out + 1] = e[1] end
    end
    return out
end

function A:complete()
    local sq = self.roof:getSquare()
    if not sq then return true end
    local kind = A.kindOf(self.roof) or "shingle"
    -- the items land on the floor under the piece (a roof square usually has no floor of its own)
    local land = sq
    for z = sq:getZ(), 0, -1 do
        local s = getCell():getGridSquare(sq:getX(), sq:getY(), z)
        if s and s:getFloor() then land = s; break end
    end
    for _, fullType in ipairs(A.rollDrops(kind, self.character)) do
        land:AddWorldInventoryItem(fullType, ZombRandFloat(0.1, 0.9), ZombRandFloat(0.1, 0.9), 0)
    end
    -- removing it is what the rest of the mod watches: the roof layer around it is judged again
    sq:transmitRemoveItemFromSquare(self.roof)
    return true
end

function A:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return 150 - (self.character:getPerkLevel(Perks.Strength) * 5)
end

function A:new(character, roof)
    local o = ISBaseTimedAction.new(self, character)
    o.roof = roof
    o.maxTime = o:getDuration()
    o.caloriesModifier = 2
    return o
end
