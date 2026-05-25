--[[
	TerrainLogic (Shared)
	Terrain calculation functions shared between server (TerrainGenerator) and client (ClientPrediction).
	
	Contains pure functions that determine what block type should exist at any given position,
	without any instance creation or modification. This allows the client to predict what
	adjacent terrain blocks the server will spawn when a terrain block is broken.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GridConfig = require(ReplicatedStorage:WaitForChild("Config", 10):WaitForChild("GridConfig", 10))

local TerrainLogic = {}

local BLOCK_SIZE = GridConfig.BLOCK_SIZE
local TERRAIN = GridConfig.TERRAIN

-- Cache parsed height maps to avoid string.split on every ShouldHaveTerrainAt call
-- Key: raw heightMapStr, Value: { heights table }
local heightMapCache = {}

-- ============================================
-- DEPTH CALCULATIONS
-- ============================================

function TerrainLogic.GetBlockTypeAtDepth(depthFromSurface)
	if depthFromSurface < TERRAIN.GRASS_LAYERS then
		return TERRAIN.GRASS_BLOCK
	elseif depthFromSurface < TERRAIN.GRASS_LAYERS + TERRAIN.DIRT_LAYERS then
		return TERRAIN.DIRT_BLOCK
	else
		return TERRAIN.STONE_BLOCK
	end
end

function TerrainLogic.GetDepthFromY(y, surfaceY)
	return math.max(0, math.round((surfaceY - y) / BLOCK_SIZE))
end

-- ============================================
-- SURFACE Y CALCULATION
-- Reads build area attributes to determine the terrain surface height at any position.
-- Works on both client and server since buildArea attributes replicate.
-- ============================================

function TerrainLogic.GetSurfaceYAtPosition(position, buildArea)
	local baseSurfaceY = buildArea:GetAttribute("TerrainSurfaceY")
	local terrainStyle = buildArea:GetAttribute("TerrainStyle")
	
	if not baseSurfaceY then return nil end
	if terrainStyle ~= "Natural" and terrainStyle ~= "Default" then return baseSurfaceY end
	
	local heightMapStr = buildArea:GetAttribute("TerrainHeightMap")
	local gridSizeX = buildArea:GetAttribute("TerrainGridSizeX")
	local gridSizeZ = buildArea:GetAttribute("TerrainGridSizeZ")
	local startX = buildArea:GetAttribute("TerrainStartX")
	local startZ = buildArea:GetAttribute("TerrainStartZ")
	
	if not (heightMapStr and gridSizeX and gridSizeZ and startX and startZ) then
		return baseSurfaceY
	end
	
	local gridX = math.round((position.X - startX) / BLOCK_SIZE)
	local gridZ = math.round((position.Z - startZ) / BLOCK_SIZE)
	
	if gridX < 0 or gridX >= gridSizeX or gridZ < 0 or gridZ >= gridSizeZ then
		return baseSurfaceY
	end
	
	-- Use cached parsed heights to avoid string.split every call
	local heights = heightMapCache[heightMapStr]
	if not heights then
		heights = string.split(heightMapStr, ",")
		heightMapCache[heightMapStr] = heights
	end
	local index = gridX * gridSizeZ + gridZ + 1
	local heightOffset = tonumber(heights[index]) or 0
	
	return baseSurfaceY + (heightOffset * BLOCK_SIZE)
end

-- ============================================
-- SHOULD HAVE TERRAIN AT
-- Determines if a terrain block should exist at a given position.
-- Returns: shouldHave (bool), blockType (string|nil), depth (number|nil)
-- ============================================

function TerrainLogic.ShouldHaveTerrainAt(position, buildArea)
	local baseSurfaceY = buildArea:GetAttribute("TerrainSurfaceY")
	if not baseSurfaceY then return false, nil end
	
	local surfaceY = TerrainLogic.GetSurfaceYAtPosition(position, buildArea)
	if not surfaceY then return false, nil end
	
	-- Positions ABOVE the surface should never have terrain.
	-- Must check raw value before GetDepthFromY clamps to 0 via math.max.
	local rawDepth = (surfaceY - position.Y) / BLOCK_SIZE
	if rawDepth < -0.4 then return false, nil end -- Small tolerance for floating-point
	
	local depth = TerrainLogic.GetDepthFromY(position.Y, surfaceY)
	
	if depth < 0 or depth >= TERRAIN.MAX_DEPTH then return false, nil end
	
	local posX = buildArea:GetAttribute("BasePlatePositionX")
	local posZ = buildArea:GetAttribute("BasePlatePositionZ")
	local sizeX = buildArea:GetAttribute("BasePlateSizeX")
	local sizeZ = buildArea:GetAttribute("BasePlateSizeZ")
	
	if not (posX and posZ and sizeX and sizeZ) then return false, nil end
	
	local halfX, halfZ = sizeX / 2, sizeZ / 2
	if position.X < posX - halfX or position.X > posX + halfX then return false, nil end
	if position.Z < posZ - halfZ or position.Z > posZ + halfZ then return false, nil end
	
	return true, TerrainLogic.GetBlockTypeAtDepth(depth), depth
end

-- ============================================
-- GRID SNAPPING
-- ============================================

function TerrainLogic.SnapToTerrainGrid(position, buildArea)
	local surfaceY = buildArea:GetAttribute("TerrainSurfaceY")
	local posX = buildArea:GetAttribute("BasePlatePositionX")
	local posZ = buildArea:GetAttribute("BasePlatePositionZ")
	local sizeX = buildArea:GetAttribute("BasePlateSizeX")
	local sizeZ = buildArea:GetAttribute("BasePlateSizeZ")
	
	if not (surfaceY and posX and posZ and sizeX and sizeZ) then return position end
	
	local originX = posX - sizeX / 2 + BLOCK_SIZE / 2
	local originZ = posZ - sizeZ / 2 + BLOCK_SIZE / 2
	
	local gridX = math.round((position.X - originX) / BLOCK_SIZE) * BLOCK_SIZE + originX
	local gridY = math.round((position.Y - surfaceY) / BLOCK_SIZE) * BLOCK_SIZE + surfaceY
	local gridZ = math.round((position.Z - originZ) / BLOCK_SIZE) * BLOCK_SIZE + originZ
	
	return Vector3.new(gridX, gridY, gridZ)
end

-- ============================================
-- ADJACENT OFFSETS
-- ============================================

TerrainLogic.ADJACENT_OFFSETS = {
	Vector3.new(0, -BLOCK_SIZE, 0),  -- DOWN
	Vector3.new(0, BLOCK_SIZE, 0),   -- UP
	Vector3.new(BLOCK_SIZE, 0, 0),   -- +X
	Vector3.new(-BLOCK_SIZE, 0, 0),  -- -X
	Vector3.new(0, 0, BLOCK_SIZE),   -- +Z
	Vector3.new(0, 0, -BLOCK_SIZE),  -- -Z
}

TerrainLogic.HORIZONTAL_OFFSETS = {
	Vector3.new(BLOCK_SIZE, 0, 0),   -- +X
	Vector3.new(-BLOCK_SIZE, 0, 0),  -- -X
	Vector3.new(0, 0, BLOCK_SIZE),   -- +Z
	Vector3.new(0, 0, -BLOCK_SIZE),  -- -Z
}

TerrainLogic.BLOCK_SIZE = BLOCK_SIZE
TerrainLogic.TERRAIN = TERRAIN

-- ============================================
-- BOUNDS CHECK
-- ============================================

function TerrainLogic.IsOutsidePlotBounds(position, buildArea)
	local posX = buildArea:GetAttribute("BasePlatePositionX")
	local posZ = buildArea:GetAttribute("BasePlatePositionZ")
	local sizeX = buildArea:GetAttribute("BasePlateSizeX")
	local sizeZ = buildArea:GetAttribute("BasePlateSizeZ")
	
	if not (posX and posZ and sizeX and sizeZ) then return false end
	
	local halfX, halfZ = sizeX / 2, sizeZ / 2
	return position.X < posX - halfX or position.X > posX + halfX or
	       position.Z < posZ - halfZ or position.Z > posZ + halfZ
end

return TerrainLogic
