--[[
	GrassSpreadManager
	Handles grass spreading mechanics similar to Minecraft:
	- Dirt blocks exposed to sky (nothing above) can turn into grass
	- Grass can spread to adjacent dirt blocks
	
	Uses a tick-based system that periodically checks blocks
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GridConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GridConfig"))

local GrassSpreadManager = {}

-- Debug flag for grass spread logs (disable for production)
local DEBUG_GRASS_SPREAD = false

-- ============================================
-- CONFIGURATION
-- ============================================
local CONFIG = {
	-- How often to run a spread tick (seconds)
	TICK_INTERVAL = 2.0,
	
	-- Chance for grass to spread to adjacent dirt per tick (0-1)
	GRASS_SPREAD_CHANCE = 0.3,
	
	-- Chance for covered grass to turn back into dirt per tick (0-1)
	-- Higher than spread chance because decay should happen faster
	GRASS_DECAY_CHANCE = 0.4,
	
	-- Maximum number of blocks to CONVERT per tick (Clone+Destroy is expensive for replication)
	MAX_BLOCKS_PER_TICK = 10,
	
	-- Block types that can become grass
	DIRT_BLOCKS = {
		["Dirt"] = true,
		["DirtSlab"] = true,
	},
	
	-- Block types that are grass (can spread)
	GRASS_BLOCKS = {
		["GrassBlock"] = true,
		["SnowyGrassBlock"] = true,
		["SnowGrassBlock"] = true,
		["TaigaGrassBlock"] = true,
		["GrassSlab"] = true,
	},
	
	-- Mapping from dirt slab types to their grass slab equivalents
	DIRT_TO_GRASS_SLAB = {
		["DirtSlab"] = "GrassSlab",
	},
	
	-- Mapping from grass slab types back to their dirt slab equivalents
	GRASS_TO_DIRT_SLAB = {
		["GrassSlab"] = "DirtSlab",
	},
}

local BLOCK_SIZE = GridConfig.BLOCK_SIZE

-- Track active plots
local ActivePlots = {}
local IsRunning = false
local LastTickTime = 0

-- BiomeConfig for grass coloring
local BiomeConfig = nil

local function loadBiomeConfig()
	if BiomeConfig then return BiomeConfig end
	pcall(function()
		BiomeConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("BiomeConfig"))
	end)
	return BiomeConfig
end

-- ============================================
-- HELPER FUNCTIONS
-- ============================================

-- Get block template from ReplicatedStorage
local function getBlockTemplate(blockType)
	local blocksFolder = ReplicatedStorage:FindFirstChild("Blocks")
	if not blocksFolder then return nil end
	return blocksFolder:FindFirstChild(blockType)
end

-- Create a grid position key for the spatial lookup table
local function getGridKey(gx, gy, gz)
	-- Use string.format to normalize -0 to 0
	return string.format("%d,%d,%d", gx, gy, gz)
end

-- Get grid position from a block
local function getBlockGridPos(block)
	local blockPos
	if block:IsA("BasePart") then
		blockPos = block.Position
	elseif block:IsA("Model") then
		local pivot = block:GetPivot()
		blockPos = pivot.Position + Vector3.new(0, BLOCK_SIZE / 2, 0)
	end
	
	if not blockPos then return nil, nil, nil end
	
	local gx = math.round(blockPos.X / BLOCK_SIZE)
	local gy = math.round(blockPos.Y / BLOCK_SIZE)
	local gz = math.round(blockPos.Z / BLOCK_SIZE)
	
	return gx, gy, gz
end

-- Check if a block should count as "covering" a grass block below
-- Decorations, fences, torches, signs, etc. don't block grass
-- SnowBlocks don't cause grass decay (SnowyGrassManager handles snow-on-grass)
local function isBlockingBlock(block)
	-- Snow blocks don't cause grass decay - SnowyGrassManager handles this
	local blockType: string? = block:GetAttribute("BlockType")
	if blockType == "SnowBlock" or blockType == "SnowLayer" then return false end
	
	-- Check attributes for non-blocking types
	if block:GetAttribute("IsDecoration") then return false end
	if block:GetAttribute("IsFence") then return false end
	if block:GetAttribute("IsTorch") then return false end
	if block:GetAttribute("IsLantern") then return false end
	if block:GetAttribute("IsCampfire") then return false end
	if block:GetAttribute("IsLadder") then return false end
	if block:GetAttribute("IsSignStanding") then return false end
	if block:GetAttribute("IsWallSign") then return false end
	if block:GetAttribute("IsGlass") then return false end -- Glass panes let light through
	if block:GetAttribute("IsWallpaperFrame") then return false end -- Paper-thin wallpaper frames (filled or unfilled)
	if block:GetAttribute("IsCarpet") then return false end -- Thin carpet frames (filled or unfilled)
	if block:GetAttribute("IsVine") then return false end -- Paper-thin vines on wall faces
	if block:GetAttribute("IsArchitrave") then return false end -- Decorative molding doesn't fully cover
	-- Full glass blocks also let light through
	if blockType and string.find(blockType, "Glass") then return false end
	-- Doors don't block grass
	if block:GetAttribute("IsDoor") then return false end
	-- Chests don't block grass (smaller than full block)
	if block:GetAttribute("IsChest") then return false end
	-- Cacti don't block grass
	if blockType and string.find(blockType, "Cactus") then return false end
	
	-- Check block type patterns for non-blocking types
	if blockType then
		-- Slabs (half-blocks in any orientation don't fully cover grass)
		if string.find(blockType, "Slab") then return false end
		-- Upside-down stairs (flat side up, gap at bottom) don't block grass
		if string.find(blockType, "Stair") and block:GetAttribute("IsUpsideDown") then return false end
		-- Fences
		if string.match(blockType, "Fence$") then return false end
		-- Flowers and grass decorations
		if string.match(blockType, "Flower") then return false end
		if blockType == "ShortGrass" or blockType == "TallGrass" then return false end
		if blockType == "DeadBush" then return false end
		-- Saplings
		if string.match(blockType, "Sapling") then return false end
		-- Torches and lights
		if string.match(blockType, "Torch") then return false end
		if string.match(blockType, "Lantern") then return false end
		-- Pressure plates and buttons (small items)
		if string.match(blockType, "Plate") then return false end
		if string.match(blockType, "Button") then return false end
	end
	
	-- Everything else is a blocking block
	return true
end

-- Build spatial lookup tables from blocks folder (call once per tick)
-- Yields periodically to avoid freezing on large plots
local YIELD_EVERY = 500 -- yield after processing this many blocks

local function buildSpatialLookup(blocksFolder)
	local occupiedPositions = {} -- key -> true (solid/blocking blocks only)
	local grassPositions = {}   -- key -> true (grass block at position)
	local count = 0
	
	for _, block in ipairs(blocksFolder:GetChildren()) do
		local gx, gy, gz = getBlockGridPos(block)
		if gx then
			local key = getGridKey(gx, gy, gz)
			
			-- Only count blocking blocks for the "occupied" lookup
			if isBlockingBlock(block) then
				occupiedPositions[key] = true
			end
			
			local blockType = block:GetAttribute("BlockType")
			if blockType and CONFIG.GRASS_BLOCKS[blockType] then
				grassPositions[key] = true
			end
		end
		
		count = count + 1
		if count % YIELD_EVERY == 0 then
			task.wait()
		end
	end
	
	return occupiedPositions, grassPositions
end

-- Check if there's a block directly above using spatial lookup (O(1))
local function hasBlockAboveFast(gx, gy, gz, occupiedPositions)
	local aboveKey = getGridKey(gx, gy + 1, gz)
	return occupiedPositions[aboveKey] == true
end

-- Check if a dirt block has adjacent grass using spatial lookup (O(1))
local function hasAdjacentGrassFast(gx, gy, gz, grassPositions)
	-- Check all 26 neighboring positions (3x3x3 cube around the block)
	for dx = -1, 1 do
		for dy = -1, 1 do
			for dz = -1, 1 do
				if not (dx == 0 and dy == 0 and dz == 0) then
					local key = getGridKey(gx + dx, gy + dy, gz + dz)
					if grassPositions[key] then
						return true
					end
				end
			end
		end
	end
	
	return false
end

-- Get the appropriate grass block type for the biome
local function getGrassTypeForBiome(biomeName)
	if not biomeName then
		return GridConfig.TERRAIN.GRASS_BLOCK
	end
	
	loadBiomeConfig()
	if BiomeConfig then
		local biomeData = BiomeConfig.GetBiome(biomeName)
		if biomeData and biomeData.GrassBlock then
			return biomeData.GrassBlock
		end
	end
	
	return GridConfig.TERRAIN.GRASS_BLOCK
end

-- Apply biome grass color to a grass block
local function applyBiomeGrassColor(block, biomeName, seasonName)
	loadBiomeConfig()
	if not BiomeConfig then return end
	
	local biomeColors = BiomeConfig.GetBiomeColors(biomeName)
	if not biomeColors or not biomeColors.GrassColor then return end
	
	-- Apply random variation for more natural look (with optional season tint)
	local grassColor = BiomeConfig.GetRandomizedGrassColor(biomeColors.GrassColor, seasonName)
	
	-- Find the "Grass" part inside the model and tint it
	if block:IsA("Model") then
		local grassPart = block:FindFirstChild("Grass")
		if grassPart and grassPart:IsA("BasePart") then
			grassPart.Color = grassColor
		end
	elseif block:IsA("BasePart") then
		block.Color = grassColor
	end
	
	-- Store the biome and season for reference
	block:SetAttribute("Biome", biomeName)
	if seasonName then
		block:SetAttribute("Season", seasonName)
	end
end

-- Get the Slab template from BlockTemplates
local function getSlabTemplate()
	local blockTemplates = ReplicatedStorage:FindFirstChild("BlockTemplates")
	if not blockTemplates then return nil end
	return blockTemplates:FindFirstChild("Slab")
end

-- Get dirt block properties (color, material, materialVariant) for creating dirt slabs
local function getDirtProperties()
	local dirtTemplate = getBlockTemplate("Dirt")
	if not dirtTemplate then
		return Color3.fromRGB(107, 76, 55), Enum.Material.Slate, ""
	end
	
	if dirtTemplate:IsA("BasePart") then
		return dirtTemplate.Color, dirtTemplate.Material, dirtTemplate.MaterialVariant or ""
	elseif dirtTemplate:IsA("Model") then
		for _, part in ipairs(dirtTemplate:GetDescendants()) do
			if part:IsA("BasePart") and part.Transparency < 1 then
				return part.Color, part.Material, part.MaterialVariant or ""
			end
		end
	end
	
	return Color3.fromRGB(107, 76, 55), Enum.Material.Slate, ""
end

-- Check if a block type is a slab variant
local function isDirtSlab(blockType)
	return CONFIG.DIRT_TO_GRASS_SLAB[blockType] ~= nil
end

local function isGrassSlab(blockType)
	return CONFIG.GRASS_TO_DIRT_SLAB[blockType] ~= nil
end

-- Convert a grass block back to dirt (when covered)
local function convertGrassToDirt(grassBlock, blocksFolder)
	local blockType = grassBlock:GetAttribute("BlockType")
	if not blockType or not CONFIG.GRASS_BLOCKS[blockType] then
		return false
	end
	
	-- Get the position of the grass block from attributes (preferred)
	local posX = grassBlock:GetAttribute("BlockPosX")
	local posY = grassBlock:GetAttribute("BlockPosY")
	local posZ = grassBlock:GetAttribute("BlockPosZ")
	
	-- Get the actual CFrame of the grass block to copy exactly
	local grassCFrame
	if grassBlock:IsA("BasePart") then
		grassCFrame = grassBlock.CFrame
	elseif grassBlock:IsA("Model") then
		grassCFrame = grassBlock:GetPivot()
	end
	
	if not grassCFrame then
		return false
	end
	
	-- If no stored position, calculate from CFrame
	if not (posX and posY and posZ) then
		local blockPos
		if grassBlock:IsA("BasePart") then
			blockPos = grassCFrame.Position
		elseif grassBlock:IsA("Model") then
			blockPos = grassCFrame.Position + Vector3.new(0, BLOCK_SIZE / 2, 0)
		end
		
		if blockPos then
			posX = math.round(blockPos.X / BLOCK_SIZE) * BLOCK_SIZE
			posY = math.round(blockPos.Y / BLOCK_SIZE) * BLOCK_SIZE
			posZ = math.round(blockPos.Z / BLOCK_SIZE) * BLOCK_SIZE
		end
	end
	
	if not (posX and posY and posZ) then
		return false
	end
	
	-- Determine if this is a slab or full block
	local isSlab = isGrassSlab(blockType)
	local template
	local dirtBlockType
	
	if isSlab then
		-- For grass slabs, create a dirt slab using the Slab template
		template = getSlabTemplate()
		dirtBlockType = CONFIG.GRASS_TO_DIRT_SLAB[blockType]
		if not template then
			warn("[GrassSpread] Could not find Slab template in BlockTemplates")
			return false
		end
	else
		-- For full grass blocks, use the Dirt block template
		template = getBlockTemplate("Dirt")
		dirtBlockType = "Dirt"
		if not template then
			warn("[GrassSpread] Could not find Dirt template")
			return false
		end
	end
	
	-- Preserve relevant attributes from the grass block
	local rotation = grassBlock:GetAttribute("Rotation") or 0
	local placedBy = grassBlock:GetAttribute("PlacedBy")
	local isTerrainBlock = grassBlock:GetAttribute("IsTerrainBlock")
	local isLazyLoaded = grassBlock:GetAttribute("IsLazyLoaded")
	local slabPosition = grassBlock:GetAttribute("SlabPosition") -- top/bottom slab placement
	local slabOrientation = grassBlock:GetAttribute("SlabOrientation") -- slab orientation (bottom/top/north/south/east/west)
	
	-- Create the new dirt block
	local dirtBlock = template:Clone()
	dirtBlock.Name = (dirtBlockType or "Dirt") .. "_" .. math.random(100000, 999999)
	
	if isSlab then
		-- For slabs: copy exact CFrame to preserve orientation (top/bottom/vertical)
		if dirtBlock:IsA("BasePart") then
			if grassBlock:IsA("BasePart") then
				dirtBlock.CFrame = grassCFrame
			else
				local centerPos = grassCFrame.Position + Vector3.new(0, BLOCK_SIZE / 2, 0)
				dirtBlock.CFrame = CFrame.new(centerPos) * grassCFrame.Rotation
			end
			dirtBlock.Anchored = true
			dirtBlock.CanCollide = true
		elseif dirtBlock:IsA("Model") then
			if grassBlock:IsA("Model") then
				dirtBlock:PivotTo(grassCFrame)
			else
				local pivotPos = grassCFrame.Position - Vector3.new(0, BLOCK_SIZE / 2, 0)
				dirtBlock:PivotTo(CFrame.new(pivotPos) * grassCFrame.Rotation)
			end
			for _, part in ipairs(dirtBlock:GetDescendants()) do
				if part:IsA("BasePart") then
					part.Anchored = true
					part.CanCollide = true
				end
			end
		end
	else
		-- For full blocks: apply random Y rotation for natural look
		local randomYRotation = math.rad(math.random(0, 3) * 90)
		rotation = math.deg(randomYRotation) -- Update rotation for attribute storage
		
		if dirtBlock:IsA("BasePart") then
			if grassBlock:IsA("BasePart") then
				dirtBlock.CFrame = CFrame.new(grassCFrame.Position) * CFrame.Angles(0, randomYRotation, 0)
			else
				local centerPos = grassCFrame.Position + Vector3.new(0, BLOCK_SIZE / 2, 0)
				dirtBlock.CFrame = CFrame.new(centerPos) * CFrame.Angles(0, randomYRotation, 0)
			end
			dirtBlock.Anchored = true
			dirtBlock.CanCollide = true
		elseif dirtBlock:IsA("Model") then
			if grassBlock:IsA("Model") then
				dirtBlock:PivotTo(CFrame.new(grassCFrame.Position) * CFrame.Angles(0, randomYRotation, 0))
			else
				local pivotPos = grassCFrame.Position - Vector3.new(0, BLOCK_SIZE / 2, 0)
				dirtBlock:PivotTo(CFrame.new(pivotPos) * CFrame.Angles(0, randomYRotation, 0))
			end
			for _, part in ipairs(dirtBlock:GetDescendants()) do
				if part:IsA("BasePart") then
					part.Anchored = true
					part.CanCollide = true
				end
			end
		end
	end
	
	-- Apply dirt color/material to slab template
	if isSlab then
		local dirtColor, dirtMaterial, dirtMaterialVariant = getDirtProperties()
		if dirtBlock:IsA("BasePart") then
			dirtBlock.Color = dirtColor
			dirtBlock.Material = dirtMaterial
			if type(dirtMaterialVariant) == "string" and dirtMaterialVariant ~= "" then
				dirtBlock.MaterialVariant = dirtMaterialVariant
			end
		elseif dirtBlock:IsA("Model") then
			for _, part in ipairs(dirtBlock:GetDescendants()) do
				if part:IsA("BasePart") then
					part.Color = dirtColor
					part.Material = dirtMaterial
					if type(dirtMaterialVariant) == "string" and dirtMaterialVariant ~= "" then
						part.MaterialVariant = dirtMaterialVariant
					end
				end
			end
		end
	end
	
	-- Set attributes
	dirtBlock:SetAttribute("BlockType", dirtBlockType or "Dirt")
	dirtBlock:SetAttribute("Rotation", rotation)
	dirtBlock:SetAttribute("BlockPosX", posX)
	dirtBlock:SetAttribute("BlockPosY", posY)
	dirtBlock:SetAttribute("BlockPosZ", posZ)
	
	if slabPosition then
		dirtBlock:SetAttribute("SlabPosition", slabPosition)
	end
	
	if slabOrientation then
		dirtBlock:SetAttribute("SlabOrientation", slabOrientation)
	end
	
	if placedBy then
		dirtBlock:SetAttribute("PlacedBy", placedBy)
	end
	
	-- FIX: A block with no PlacedBy is natural terrain. Always flag decayed dirt as terrain
	-- so its lineage isn't lost (which previously orphaned grass that later regrew on it).
	local treatAsTerrain = isTerrainBlock or not placedBy
	if treatAsTerrain then
		dirtBlock:SetAttribute("IsTerrainBlock", true)
		dirtBlock:SetAttribute("TerrainDepth", 1) -- Now underground
	end
	
	if isLazyLoaded or treatAsTerrain then
		dirtBlock:SetAttribute("IsLazyLoaded", true)
	end
	
	-- Mark as decayed from grass (for debugging/tracking)
	dirtBlock:SetAttribute("DecayedFromGrass", true)
	
	-- Parent the new block and destroy the old one
	dirtBlock.Parent = blocksFolder
	grassBlock:Destroy()
	
	return true
end

-- Convert a dirt block to grass
local function convertDirtToGrass(dirtBlock, blocksFolder, biomeName, seasonName)
	local blockType = dirtBlock:GetAttribute("BlockType")
	if not blockType or not CONFIG.DIRT_BLOCKS[blockType] then
		return false
	end
	
	-- Get the position of the dirt block from attributes (preferred)
	local posX = dirtBlock:GetAttribute("BlockPosX")
	local posY = dirtBlock:GetAttribute("BlockPosY")
	local posZ = dirtBlock:GetAttribute("BlockPosZ")
	
	-- Get the actual CFrame of the dirt block to copy exactly
	local dirtCFrame
	if dirtBlock:IsA("BasePart") then
		dirtCFrame = dirtBlock.CFrame
	elseif dirtBlock:IsA("Model") then
		dirtCFrame = dirtBlock:GetPivot()
	end
	
	if not dirtCFrame then
		return false
	end
	
	-- If no stored position, calculate from CFrame
	if not (posX and posY and posZ) then
		local blockPos
		if dirtBlock:IsA("BasePart") then
			blockPos = dirtCFrame.Position
		elseif dirtBlock:IsA("Model") then
			-- Model pivot is at bottom, add half block to get center
			blockPos = dirtCFrame.Position + Vector3.new(0, BLOCK_SIZE / 2, 0)
		end
		
		if blockPos then
			posX = math.round(blockPos.X / BLOCK_SIZE) * BLOCK_SIZE
			posY = math.round(blockPos.Y / BLOCK_SIZE) * BLOCK_SIZE
			posZ = math.round(blockPos.Z / BLOCK_SIZE) * BLOCK_SIZE
		end
	end
	
	if not (posX and posY and posZ) then
		return false
	end
	
	-- Determine if this is a slab or full block
	local isSlab = isDirtSlab(blockType)
	local grassType
	local template
	
	if isSlab then
		-- For dirt slabs, convert to the corresponding grass slab
		grassType = CONFIG.DIRT_TO_GRASS_SLAB[blockType]
		template = getBlockTemplate(grassType)
		if not template then
			warn("[GrassSpread] Could not find grass slab template: " .. tostring(grassType))
			return false
		end
	else
		-- For full dirt blocks, convert to the biome's grass block
		grassType = getGrassTypeForBiome(biomeName)
		template = getBlockTemplate(grassType)
		if not template then
			warn("[GrassSpread] Could not find grass template: " .. grassType)
			return false
		end
	end
	
	-- Preserve relevant attributes from the dirt block
	local rotation = dirtBlock:GetAttribute("Rotation") or 0
	local placedBy = dirtBlock:GetAttribute("PlacedBy")
	local isTerrainBlock = dirtBlock:GetAttribute("IsTerrainBlock")
	local terrainDepth = dirtBlock:GetAttribute("TerrainDepth")
	local isLazyLoaded = dirtBlock:GetAttribute("IsLazyLoaded")
	local slabPosition = dirtBlock:GetAttribute("SlabPosition") -- top/bottom slab placement
	local slabOrientation = dirtBlock:GetAttribute("SlabOrientation") -- slab orientation (bottom/top/north/south/east/west)
	
	-- Create the new grass block
	local grassBlock = template:Clone()
	grassBlock.Name = grassType .. "_" .. math.random(100000, 999999)
	
	if isSlab then
		-- For slabs: copy exact CFrame to preserve orientation (top/bottom/vertical)
		if grassBlock:IsA("BasePart") then
			if dirtBlock:IsA("BasePart") then
				grassBlock.CFrame = dirtCFrame
			else
				local centerPos = dirtCFrame.Position + Vector3.new(0, BLOCK_SIZE / 2, 0)
				grassBlock.CFrame = CFrame.new(centerPos) * dirtCFrame.Rotation
			end
			grassBlock.Anchored = true
			grassBlock.CanCollide = true
		elseif grassBlock:IsA("Model") then
			if dirtBlock:IsA("Model") then
				grassBlock:PivotTo(dirtCFrame)
			else
				local pivotPos = dirtCFrame.Position - Vector3.new(0, BLOCK_SIZE / 2, 0)
				grassBlock:PivotTo(CFrame.new(pivotPos) * dirtCFrame.Rotation)
			end
			for _, part in ipairs(grassBlock:GetDescendants()) do
				if part:IsA("BasePart") then
					part.Anchored = true
					part.CanCollide = true
				end
			end
		end
	else
		-- For full blocks: apply random Y rotation for natural look
		local randomYRotation = math.rad(math.random(0, 3) * 90)
		rotation = math.deg(randomYRotation) -- Update rotation for attribute storage
		
		if grassBlock:IsA("BasePart") then
			if dirtBlock:IsA("BasePart") then
				grassBlock.CFrame = CFrame.new(dirtCFrame.Position) * CFrame.Angles(0, randomYRotation, 0)
			else
				local centerPos = dirtCFrame.Position + Vector3.new(0, BLOCK_SIZE / 2, 0)
				grassBlock.CFrame = CFrame.new(centerPos) * CFrame.Angles(0, randomYRotation, 0)
			end
			grassBlock.Anchored = true
			grassBlock.CanCollide = true
		elseif grassBlock:IsA("Model") then
			if dirtBlock:IsA("Model") then
				grassBlock:PivotTo(CFrame.new(dirtCFrame.Position) * CFrame.Angles(0, randomYRotation, 0))
			else
				local pivotPos = dirtCFrame.Position - Vector3.new(0, BLOCK_SIZE / 2, 0)
				grassBlock:PivotTo(CFrame.new(pivotPos) * CFrame.Angles(0, randomYRotation, 0))
			end
			for _, part in ipairs(grassBlock:GetDescendants()) do
				if part:IsA("BasePart") then
					part.Anchored = true
					part.CanCollide = true
				end
			end
		end
	end
	
	-- Apply biome grass color to both full blocks and slabs
	if biomeName then
		applyBiomeGrassColor(grassBlock, biomeName, seasonName)
	end
	
	-- Set attributes
	grassBlock:SetAttribute("BlockType", grassType)
	-- For slabs, preserve original rotation; for full blocks, store the random rotation applied above
	-- (randomYRotation is only defined in the full block branch, so we use the preserved 'rotation' for slabs)
	grassBlock:SetAttribute("Rotation", rotation)
	grassBlock:SetAttribute("BlockPosX", posX)
	grassBlock:SetAttribute("BlockPosY", posY)
	grassBlock:SetAttribute("BlockPosZ", posZ)
	
	if slabPosition then
		grassBlock:SetAttribute("SlabPosition", slabPosition)
	end
	
	if slabOrientation then
		grassBlock:SetAttribute("SlabOrientation", slabOrientation)
	end
	
	if placedBy then
		grassBlock:SetAttribute("PlacedBy", placedBy)
	end
	
	-- FIX: A block with no PlacedBy is, by definition, natural terrain. Always flag it as
	-- terrain so that breaking it routes through OnTerrainBlockBroken (marks the position
	-- dug). Previously this was inherited only if the source dirt still had IsTerrainBlock,
	-- so a grass block whose lineage lost the flag during decay/spread became an orphan:
	-- not saved, not mark-dug, and thus regenerated on every load.
	local treatAsTerrain = isTerrainBlock or not placedBy
	if treatAsTerrain then
		grassBlock:SetAttribute("IsTerrainBlock", true)
		grassBlock:SetAttribute("TerrainDepth", 0) -- Grass is always surface
	end
	
	-- Grown grass is a state change from the originally generated surface, so it must be
	-- saved to persist. Lazy-load it if it was already lazy OR if it's terrain (so the
	-- grown state round-trips and the block is mark-dug correctly when broken).
	if isLazyLoaded or treatAsTerrain then
		grassBlock:SetAttribute("IsLazyLoaded", true)
	end
	
	-- Mark as grown from grass spread (for debugging/tracking)
	grassBlock:SetAttribute("GrownFromSpread", true)
	
	-- Parent the new block and destroy the old one
	grassBlock.Parent = blocksFolder
	dirtBlock:Destroy()
	
	return true
end

-- ============================================
-- MAIN TICK FUNCTION
-- ============================================

local function processTick()
	for plotNumber, plotData in pairs(ActivePlots) do
		local buildArea = plotData.buildArea
		local blocksFolder = buildArea:FindFirstChild("Blocks")
		
		if not blocksFolder then
			continue
		end
		
		-- Skip if terrain is still generating
		if buildArea:GetAttribute("TerrainGenerationInProgress") then
			continue
		end
		
		-- Get biome and season info
		local biomeName = buildArea:GetAttribute("CurrentBiome")
		local seasonName = buildArea:GetAttribute("CurrentSeason") or "Summer"
		
		-- Build spatial lookup table ONCE (O(n) instead of O(n²))
		local occupiedPositions, grassPositions = buildSpatialLookup(blocksFolder)
		
		-- Collect ELIGIBLE dirt blocks (exposed + adjacent grass) and COVERED grass blocks
		-- Only process blocks that can actually change state
		local eligibleDirtBlocks = {}
		local coveredGrassBlocks = {}
		local scanCount = 0
		
		for _, block in ipairs(blocksFolder:GetChildren()) do
			local blockType = block:GetAttribute("BlockType")
			if blockType then
				local gx, gy, gz = getBlockGridPos(block)
				if gx then
					if CONFIG.DIRT_BLOCKS[blockType] then
						-- Only add dirt if it's exposed AND has adjacent grass
						if not hasBlockAboveFast(gx, gy, gz, occupiedPositions) then
							if hasAdjacentGrassFast(gx, gy, gz, grassPositions) then
								table.insert(eligibleDirtBlocks, block)
							end
						end
					elseif CONFIG.GRASS_BLOCKS[blockType] then
						-- Only add grass if it's covered (O(1) lookup)
						if hasBlockAboveFast(gx, gy, gz, occupiedPositions) then
							table.insert(coveredGrassBlocks, block)
						end
					end
				end
			end
			
			scanCount = scanCount + 1
			if scanCount % YIELD_EVERY == 0 then
				task.wait()
			end
		end
		
		local blocksConverted = 0
		local blocksDecayed = 0
		local totalChanges = 0
		local maxChanges = CONFIG.MAX_BLOCKS_PER_TICK
		
		-- Shuffle to avoid always processing the same blocks first
		local function shuffleInPlace(t)
			for i = #t, 2, -1 do
				local j = math.random(1, i)
				t[i], t[j] = t[j], t[i]
			end
		end
		
		shuffleInPlace(coveredGrassBlocks)
		shuffleInPlace(eligibleDirtBlocks)
		
		-- Process covered grass blocks (decay to dirt) - capped
		for _, grassBlock in ipairs(coveredGrassBlocks) do
			if totalChanges >= maxChanges then break end
			if math.random() < CONFIG.GRASS_DECAY_CHANCE then
				if convertGrassToDirt(grassBlock, blocksFolder) then
					blocksDecayed = blocksDecayed + 1
					totalChanges = totalChanges + 1
				end
			end
		end
		
		-- Process eligible dirt blocks (spread grass) - capped
		for _, dirtBlock in ipairs(eligibleDirtBlocks) do
			if totalChanges >= maxChanges then break end
			if math.random() < CONFIG.GRASS_SPREAD_CHANCE then
				if convertDirtToGrass(dirtBlock, blocksFolder, biomeName, seasonName) then
					blocksConverted = blocksConverted + 1
					totalChanges = totalChanges + 1
				end
			end
		end
		
		if blocksConverted > 0 or blocksDecayed > 0 then
			if blocksConverted > 0 and DEBUG_GRASS_SPREAD then
				print(string.format("[GrassSpread] Plot %d: Converted %d dirt blocks to grass", plotNumber, blocksConverted))
			end
			if blocksDecayed > 0 and DEBUG_GRASS_SPREAD then
				print(string.format("[GrassSpread] Plot %d: Decayed %d grass blocks to dirt (covered)", plotNumber, blocksDecayed))
			end
		end
	end
end

-- ============================================
-- PUBLIC API
-- ============================================

-- Register a build area for grass spreading
function GrassSpreadManager.RegisterPlot(buildArea, plotNumber)
	if ActivePlots[plotNumber] then
		return -- Already registered
	end
	
	ActivePlots[plotNumber] = {
		buildArea = buildArea,
		plotNumber = plotNumber,
	}
	
	print(string.format("[GrassSpread] Registered plot %d for grass spreading", plotNumber))
	
	-- Start the tick loop if not already running
	if not IsRunning then
		GrassSpreadManager.Start()
	end
end

-- Unregister a build area
function GrassSpreadManager.UnregisterPlot(plotNumber)
	if ActivePlots[plotNumber] then
		ActivePlots[plotNumber] = nil
		print(string.format("[GrassSpread] Unregistered plot %d", plotNumber))
	end
	
	-- Stop if no active plots
	local hasActivePlots = false
	for _ in pairs(ActivePlots) do
		hasActivePlots = true
		break
	end
	
	if not hasActivePlots then
		GrassSpreadManager.Stop()
	end
end

-- Start the grass spread tick loop
function GrassSpreadManager.Start()
	if IsRunning then return end
	IsRunning = true
	LastTickTime = tick()
	
	print("[GrassSpread] Started grass spreading system")
	
	-- Use a coroutine-based tick system
	task.spawn(function()
		while IsRunning do
			local currentTime = tick()
			
			if currentTime - LastTickTime >= CONFIG.TICK_INTERVAL then
				LastTickTime = currentTime
				
				-- Process tick in protected call
				local success, err = pcall(processTick)
				if not success then
					warn("[GrassSpread] Tick error: " .. tostring(err))
				end
			end
			
			task.wait(0.5) -- Check every 0.5 seconds
		end
	end)
end

-- Stop the grass spread system
function GrassSpreadManager.Stop()
	IsRunning = false
	print("[GrassSpread] Stopped grass spreading system")
end

-- Force a tick (for testing)
function GrassSpreadManager.ForceTick()
	processTick()
end

-- Update configuration
function GrassSpreadManager.SetConfig(key, value)
	if CONFIG[key] ~= nil then
		CONFIG[key] = value
		print(string.format("[GrassSpread] Config updated: %s = %s", key, tostring(value)))
	end
end

-- Get current configuration
function GrassSpreadManager.GetConfig()
	return CONFIG
end

-- Check if grass spreading is active
function GrassSpreadManager.IsActive()
	return IsRunning
end

-- Initialize the manager (call from PlotManager or similar)
function GrassSpreadManager.Initialize()
	print("[GrassSpread] GrassSpreadManager initialized")
	-- Will start automatically when first plot is registered
end

return GrassSpreadManager
