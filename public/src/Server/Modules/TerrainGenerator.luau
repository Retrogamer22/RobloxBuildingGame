--[[
	TerrainGenerator
	Generates flat terrain for plots - LAZY LOADING SYSTEM
	
	Only generates the grass surface layer on startup.
	Underground blocks (dirt, stone) are generated dynamically
	when the player breaks blocks above them.
	
	Features 3D PRINTER style spawning - each horizontal Y slice
	of EVERYTHING (terrain + trees) appears together!
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local GridConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GridConfig"))
local BulkOperationFlags = require(ReplicatedStorage:WaitForChild("BulkOperationFlags", 10))
local BlockSpatialIndex = require(ReplicatedStorage:WaitForChild("BlockSpatialIndex", 10))

local TerrainGenerator = {}

local BLOCK_SIZE = GridConfig.BLOCK_SIZE
local TERRAIN = GridConfig.TERRAIN

-- Debug flag for lazy loading prints (disable for production)
local DEBUG_LAZY_LOAD = false
local DEBUG_TERRAIN_NET = false  -- [BB-NET] TERRAIN logs (very spammy, disable for production)

-- ============================================
-- GENERATION SETTINGS
-- ============================================
local GENERATION_SETTINGS = {
	-- Delay between spawning each Y layer (seconds)
	LAYER_DELAY = 0.03,  -- Small delay for 3D printer effect
	
	-- Animation settings
	ANIMATION_ENABLED = true,
	ANIMATION_OFFSET = 10,  -- How far below to spawn blocks (studs)
	ANIMATION_TIME = 0.25,  -- How long the tween takes
	ANIMATION_STYLE = Enum.EasingStyle.Back,
	ANIMATION_DIRECTION = Enum.EasingDirection.Out,
	
	-- Mega plot optimizations (disable fancy effects for speed)
	MEGA_PLOT_FAST_MODE = true,  -- Skip animations and 3D printer for mega plots
	MEGA_PLOT_BATCH_SIZE = 1000,  -- Blocks per batch before yielding
	
	-- Height compression for non-flat terrain
	-- Reduces peak heights to keep terrain from towering too tall
	-- Peaks are compressed more aggressively than valleys for natural feel
	HEIGHT_COMPRESSION_ENABLED = true,
	PEAK_SCALE = 0.55,           -- Multiply positive heights by this (0.55 = peaks ~half as tall)
	VALLEY_SCALE = 0.8,          -- Multiply negative heights by this (keep valleys a bit deeper)
	MAX_HEIGHT_CAP = 8,          -- Hard cap: no point higher than this many blocks above base
}

-- Tween info for block animations (cached)
local blockTweenInfo = TweenInfo.new(
	GENERATION_SETTINGS.ANIMATION_TIME,
	GENERATION_SETTINGS.ANIMATION_STYLE,
	GENERATION_SETTINGS.ANIMATION_DIRECTION
)

-- Animate a block rising up from below
local function animateBlockUp(block, targetPosition)
	if not GENERATION_SETTINGS.ANIMATION_ENABLED then return end
	
	local offset = Vector3.new(0, -GENERATION_SETTINGS.ANIMATION_OFFSET, 0)
	
	if block:IsA("BasePart") then
		-- Store original CFrame rotation
		local targetCFrame = block.CFrame
		block.CFrame = targetCFrame + offset
		
		local tween = TweenService:Create(block, blockTweenInfo, {CFrame = targetCFrame})
		tween:Play()
		
	elseif block:IsA("Model") then
		-- For models, move via PrimaryPart or first BasePart
		local targetCFrame = block:GetPivot()
		block:PivotTo(targetCFrame + offset)
		
		-- Tween all parts in the model
		for _, part in ipairs(block:GetDescendants()) do
			if part:IsA("BasePart") then
				local partTarget = part.CFrame + Vector3.new(0, GENERATION_SETTINGS.ANIMATION_OFFSET, 0)
				local tween = TweenService:Create(part, blockTweenInfo, {CFrame = partTarget})
				tween:Play()
			end
		end
	end
end

-- Track which plots have been generated to prevent duplicates
local GeneratedPlots = {}

-- Track which plots are currently generating (to prevent save during generation)
local GeneratingPlots = {}

-- Track dug out positions per plot (so we don't refill them)
local DugPositions = {}

-- Track removed terrain-generated decorations and trees per plot
-- These are blocks without PlacedBy that the player destroyed at runtime
-- Format: { [plotNumber] = { {type="deco", blockType="ShortGrass", parentX=..., parentY=..., parentZ=...}, ... } }
local RemovedGeneratedBlocks = {}

-- Isolated RNG for terrain generation (prevents other scripts from affecting placement)
-- Set to Random.new(seed) during generation, nil otherwise
local terrainRng: Random? = nil

-- Helper: get next random number using terrain RNG if available, else math.random
local function tRandom(min: number?, max: number?): number
	if terrainRng then
		if min and max then
			return terrainRng:NextInteger(min, max)
		elseif min then
			-- Single arg: treat as NextNumber() * min (unusual, avoid)
			return terrainRng:NextInteger(1, min)
		else
			return terrainRng:NextNumber()
		end
	else
		if min and max then
			return math.random(min, max)
		elseif min then
			return math.random(min)
		else
			return math.random()
		end
	end
end

local function getPositionKey(position)
	local x = math.round(position.X / BLOCK_SIZE) * BLOCK_SIZE
	local y = math.round(position.Y / BLOCK_SIZE) * BLOCK_SIZE
	local z = math.round(position.Z / BLOCK_SIZE) * BLOCK_SIZE
	return string.format("%d,%d,%d", x, y, z)
end

local function markPositionAsDug(position, plotNumber)
	if not DugPositions[plotNumber] then
		DugPositions[plotNumber] = {}
	end
	DugPositions[plotNumber][getPositionKey(position)] = true
end

local function isPositionDug(position, plotNumber)
	if not DugPositions[plotNumber] then return false end
	return DugPositions[plotNumber][getPositionKey(position)] == true
end

-- Cache for block templates
local BlocksFolder = nil
local DecorationsFolder = nil
local BiomeConfig = nil

local function loadBiomeConfig()
	if BiomeConfig then return BiomeConfig end
	pcall(function()
		BiomeConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("BiomeConfig"))
	end)
	return BiomeConfig
end

local function waitForBlocks()
	if BlocksFolder then return BlocksFolder end
	BlocksFolder = ReplicatedStorage:WaitForChild("Blocks", 10)
	return BlocksFolder
end

local function waitForDecorations()
	if DecorationsFolder then return DecorationsFolder end
	DecorationsFolder = ReplicatedStorage:WaitForChild("Decorations", 10)
	return DecorationsFolder
end

local function getBlockTemplate(blockType)
	local blocks = waitForBlocks()
	if not blocks then 
		warn("[LazyLoad] Blocks folder not found!")
		return nil 
	end
	local template = blocks:FindFirstChild(blockType)
	if not template then
		warn("[LazyLoad] Template not found for: " .. tostring(blockType))
	end
	return template
end

local function getDecorationTemplate(decorationType)
	local decorations = waitForDecorations()
	if not decorations then return nil end
	return decorations:FindFirstChild(decorationType)
end

-- Apply biome color to grass decorations (ShortGrass, TallGrass)
-- seasonName is optional - applies seasonal tint if provided
-- Grass decorations should match GRASS colors closely
local function applyBiomeDecorationColor(decoration, decorationType, biomeName, seasonName)
	if not biomeName then return end
	
	-- Only tint grass-type decorations
	if decorationType ~= "ShortGrass" and decorationType ~= "TallGrass" then return end
	
	local config = loadBiomeConfig()
	if not config then return end
	
	local biomeColors = config.GetBiomeColors(biomeName)
	if not biomeColors or not biomeColors.GrassColor then return end
	
	-- Use DecorationMultiplier for grass decorations (matches grass blocks in most seasons)
	local baseColor = biomeColors.GrassColor
	local decorationColor = config.GetSeasonalDecorationColor(baseColor, seasonName)
	
	-- Apply very slight random brightness variation (smaller than grass blocks for consistency)
	local h, s, v = Color3.toHSV(decorationColor)
	local valVariation = (tRandom() - 0.5) * 0.03  -- ±1.5% brightness only
	local finalColor = Color3.fromHSV(h, s, math.clamp(v + valVariation, 0.3, 1))
	
	-- Tint all parts in the decoration
	if decoration:IsA("BasePart") then
		decoration.Color = finalColor
	elseif decoration:IsA("Model") then
		for _, part in ipairs(decoration:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Color = finalColor
			end
		end
	end
	
	-- Store season on decoration for reference
	if seasonName then
		decoration:SetAttribute("Season", seasonName)
	end
end

-- Create a decoration on top of a block
-- biomeName: optional biome name for grass decoration coloring
-- seasonName: optional season name for seasonal color tinting
local function createDecoration(decorationType, blockPosition, parent, biomeName, seasonName)
	local template = getDecorationTemplate(decorationType)
	if not template then return nil end
	
	local decoration = template:Clone()
	decoration.Name = decorationType .. "_" .. tRandom(100000, 999999)
	
	local decorationY = blockPosition.Y + BLOCK_SIZE / 2
	local maxOffset = 0.8
	local offsetX = (tRandom() - 0.5) * 2 * maxOffset
	local offsetZ = (tRandom() - 0.5) * 2 * maxOffset
	
	local decorationPos = Vector3.new(blockPosition.X + offsetX, decorationY, blockPosition.Z + offsetZ)
	local rotation45 = CFrame.Angles(0, math.rad(45), 0)
	
	if decoration:IsA("BasePart") then
		decoration.CFrame = CFrame.new(decorationPos + Vector3.new(0, decoration.Size.Y / 2, 0)) * rotation45
		decoration.Anchored = true
		decoration.CanCollide = false
	elseif decoration:IsA("Model") then
		decoration:PivotTo(CFrame.new(decorationPos) * rotation45)
		for _, part in ipairs(decoration:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Anchored = true
				part.CanCollide = false
			end
		end
	end
	
	decoration:SetAttribute("BlockType", decorationType)
	decoration:SetAttribute("IsDecoration", true)
	
	-- Store parent block position for cleanup when block is broken
	decoration:SetAttribute("ParentBlockX", blockPosition.X)
	decoration:SetAttribute("ParentBlockY", blockPosition.Y)
	decoration:SetAttribute("ParentBlockZ", blockPosition.Z)
	
	-- Apply biome color to grass decorations (with optional season tint)
	applyBiomeDecorationColor(decoration, decorationType, biomeName, seasonName)
	
	decoration.Parent = parent
	return decoration
end

-- Apply biome grass color to a grass block
-- seasonName is optional - applies seasonal tint if provided
local function applyBiomeGrassColor(block, biomeName, seasonName)
	local config = loadBiomeConfig()
	if not config then return end
	
	local biomeColors = config.GetBiomeColors(biomeName)
	if not biomeColors or not biomeColors.GrassColor then return end
	
	-- Apply random variation for more natural look (with optional season tint)
	local grassColor = config.GetRandomizedGrassColor(biomeColors.GrassColor, seasonName)
	
	-- Find the "Grass" part inside the model and tint it
	if block:IsA("Model") then
		local grassPart = block:FindFirstChild("Grass")
		if grassPart and grassPart:IsA("BasePart") then
			grassPart.Color = grassColor
		end
	elseif block:IsA("BasePart") then
		-- If the grass block is a simple part, tint the whole thing
		block.Color = grassColor
	end
	
	-- Store the biome and season for reference (useful if block is saved/loaded)
	block:SetAttribute("Biome", biomeName)
	if seasonName then
		block:SetAttribute("Season", seasonName)
	end
end

-- Create a terrain block at position
-- isLazyLoaded: if true, mark as saveable (will be saved even though it's a terrain block)
-- biomeName: optional biome name for grass coloring
-- seasonName: optional season name for seasonal color tinting
local function createBlock(blockType, position, parent, terrainDepth, isLazyLoaded, biomeName, seasonName)
	local template = getBlockTemplate(blockType)
	if not template then return nil end
	
	local block = template:Clone()
	block.Name = blockType .. "_" .. tRandom(100000, 999999)
	
	-- Random Y-axis rotation for grass blocks to break up tiling (0, 90, 180, or 270 degrees)
	local randomYRotation = 0
	if blockType == "GrassBlock" or blockType == "SnowGrassBlock" or blockType == "TaigaGrassBlock" then
		randomYRotation = math.rad(tRandom(0, 3) * 90)
	end
	
	if block:IsA("BasePart") then
		block.CFrame = CFrame.new(position) * CFrame.Angles(0, randomYRotation, 0)
		block.Anchored = true
		block.CanCollide = true
		block.CanTouch = false      -- Terrain doesn't need touch events
		block.CastShadow = false    -- Massive memory savings (~285MB for 9 plots)
	elseif block:IsA("Model") then
		local offsetCFrame = CFrame.new(position - Vector3.new(0, BLOCK_SIZE / 2, 0)) * CFrame.Angles(0, randomYRotation, 0)
		block:PivotTo(offsetCFrame)
		for _, part in ipairs(block:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Anchored = true
				part.CanCollide = true
				part.CanTouch = false      -- Terrain doesn't need touch events
				part.CastShadow = false    -- Massive memory savings
			end
		end
	end
	
	-- Apply biome grass color if this is a grass block (with optional season tint)
	if biomeName and (blockType == "GrassBlock" or blockType == "SnowGrassBlock" or blockType == "TaigaGrassBlock") then
		applyBiomeGrassColor(block, biomeName, seasonName)
	end
	
	block:SetAttribute("BlockType", blockType)
	block:SetAttribute("Rotation", math.deg(randomYRotation))
	
	-- All terrain blocks (including lazy-loaded) need IsTerrainBlock for lazy loading chain
	block:SetAttribute("IsTerrainBlock", true)
	block:SetAttribute("TerrainDepth", terrainDepth or 0)
	
	-- Mark lazy-loaded blocks so they get saved (unlike initial terrain)
	if isLazyLoaded then
		block:SetAttribute("IsLazyLoaded", true)
	end
	
	-- Store original position for decoration cleanup
	block:SetAttribute("BlockPosX", position.X)
	block:SetAttribute("BlockPosY", position.Y)
	block:SetAttribute("BlockPosZ", position.Z)
	
	block.Parent = parent
	return block
end

-- ============================================
-- HEIGHT MAP UTILITIES
-- ============================================

-- Apply terrain shaping curve to raw noise value
-- This transforms raw noise into more natural terrain profiles
local function shapeHeight(rawHeight, terrainShape, amplitude)
	if not terrainShape then return rawHeight end
	
	if terrainShape == "ridged" then
		-- Ridged noise: fold negative values upward to create ridge-like peaks
		-- Result: mountain ridges with valleys between them instead of random spikes
		local normalized = rawHeight / amplitude  -- -1 to 1 range
		local ridged = 1 - math.abs(normalized)   -- 0 at extremes, 1 at center
		ridged = ridged * ridged                   -- Square for sharper ridges
		return ridged * amplitude
		
	elseif terrainShape == "dunes" then
		-- Smooth sine-like dunes: soft rolling hills
		local normalized = rawHeight / amplitude
		-- Bias toward positive (dunes rise above base), smooth with cosine
		local shaped = (math.cos(normalized * math.pi) + 1) * 0.5
		return shaped * amplitude * 0.8  -- Scale down slightly for gentler dunes
		
	elseif terrainShape == "plateaus" then
		-- Flat tops with steep edges
		local normalized = rawHeight / amplitude
		local shaped = math.clamp(normalized * 2, -1, 1)  -- Steepen transitions
		shaped = shaped * shaped * shaped * 0.5 + shaped * 0.5  -- S-curve
		return shaped * amplitude
	end
	
	return rawHeight
end

-- Smooth height map with box blur (averages each cell with its neighbors)
-- Reduces jagged single-block spikes and creates more natural gradients
local function smoothHeightMap(heightMap, gridSizeX, gridSizeZ, passes)
	passes = passes or 1
	
	for pass = 1, passes do
		local smoothed = {}
		for gridX = 0, gridSizeX - 1 do
			smoothed[gridX] = {}
			for gridZ = 0, gridSizeZ - 1 do
				local sum = 0
				local count = 0
				
				-- Sample 3x3 neighborhood
				for dx = -1, 1 do
					for dz = -1, 1 do
						local nx = gridX + dx
						local nz = gridZ + dz
						if nx >= 0 and nx < gridSizeX and nz >= 0 and nz < gridSizeZ then
							-- Center cell has higher weight (weighted box blur)
							local weight = (dx == 0 and dz == 0) and 2 or 1
							sum = sum + heightMap[nx][nz] * weight
							count = count + weight
						end
					end
				end
				
				smoothed[gridX][gridZ] = sum / count
			end
		end
		
		-- Copy smoothed values back (round to integer block heights)
		for gridX = 0, gridSizeX - 1 do
			for gridZ = 0, gridSizeZ - 1 do
				heightMap[gridX][gridZ] = math.round(smoothed[gridX][gridZ])
			end
		end
	end
	
	return heightMap
end

-- Clamp maximum height difference between adjacent cells to prevent sheer cliffs
-- maxStep: maximum allowed height difference (in block units) between neighbors
local function enforceMaxSlope(heightMap, gridSizeX, gridSizeZ, maxStep)
	maxStep = maxStep or 2
	
	-- Multiple passes to propagate constraints
	for pass = 1, 3 do
		for gridX = 0, gridSizeX - 1 do
			for gridZ = 0, gridSizeZ - 1 do
				local h = heightMap[gridX][gridZ]
				-- Check 4-connected neighbors
				for _, offset in ipairs({{1,0},{-1,0},{0,1},{0,-1}}) do
					local nx = gridX + offset[1]
					local nz = gridZ + offset[2]
					if nx >= 0 and nx < gridSizeX and nz >= 0 and nz < gridSizeZ then
						local nh = heightMap[nx][nz]
						if nh - h > maxStep then
							heightMap[nx][nz] = h + maxStep
						elseif h - nh > maxStep then
							heightMap[gridX][gridZ] = nh + maxStep
							h = nh + maxStep  -- Update for next neighbor check
						end
					end
				end
			end
		end
	end
	
	return heightMap
end

-- Compress height map to reduce peak heights while preserving terrain shape
-- Peaks (positive) are scaled down more aggressively than valleys (negative)
-- This keeps terrain interesting but prevents towering mountains
local function compressHeightMap(heightMap, gridSizeX, gridSizeZ)
	if not GENERATION_SETTINGS.HEIGHT_COMPRESSION_ENABLED then
		return heightMap
	end
	
	local peakScale = GENERATION_SETTINGS.PEAK_SCALE
	local valleyScale = GENERATION_SETTINGS.VALLEY_SCALE
	local maxCap = GENERATION_SETTINGS.MAX_HEIGHT_CAP
	
	for gridX = 0, gridSizeX - 1 do
		for gridZ = 0, gridSizeZ - 1 do
			local h = heightMap[gridX][gridZ]
			if h > 0 then
				-- Compress peaks
				h = math.round(h * peakScale)
				if h > maxCap then h = maxCap end
			elseif h < 0 then
				-- Compress valleys (less aggressively)
				h = math.round(h * valleyScale)
			end
			heightMap[gridX][gridZ] = h
		end
	end
	
	return heightMap
end

-- ============================================
-- DEPTH CALCULATIONS
-- ============================================

function TerrainGenerator.GetBlockTypeAtDepth(depthFromSurface)
	if depthFromSurface < TERRAIN.GRASS_LAYERS then
		return TERRAIN.GRASS_BLOCK
	elseif depthFromSurface < TERRAIN.GRASS_LAYERS + TERRAIN.DIRT_LAYERS then
		return TERRAIN.DIRT_BLOCK
	else
		return TERRAIN.STONE_BLOCK
	end
end

function TerrainGenerator.GetDepthFromY(y, surfaceY)
	return math.max(0, math.round((surfaceY - y) / BLOCK_SIZE))
end

local function getSurfaceYAtPosition(position, buildArea)
	local baseSurfaceY = buildArea:GetAttribute("TerrainSurfaceY")
	local terrainStyle = buildArea:GetAttribute("TerrainStyle")
	
	if terrainStyle ~= "Natural" then return baseSurfaceY end
	
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
	
	local heights = string.split(heightMapStr, ",")
	local index = gridX * gridSizeZ + gridZ + 1
	local heightOffset = tonumber(heights[index]) or 0
	
	return baseSurfaceY + (heightOffset * BLOCK_SIZE)
end

function TerrainGenerator.ShouldHaveTerrainAt(position, buildArea)
	local baseSurfaceY = buildArea:GetAttribute("TerrainSurfaceY")
	if not baseSurfaceY then return false, nil end
	
	local surfaceY = getSurfaceYAtPosition(position, buildArea)
	local depth = TerrainGenerator.GetDepthFromY(position.Y, surfaceY)
	
	if depth < 0 or depth >= TERRAIN.MAX_DEPTH then return false, nil end
	
	local posX = buildArea:GetAttribute("BasePlatePositionX")
	local posZ = buildArea:GetAttribute("BasePlatePositionZ")
	local sizeX = buildArea:GetAttribute("BasePlateSizeX")
	local sizeZ = buildArea:GetAttribute("BasePlateSizeZ")
	
	if not (posX and posZ and sizeX and sizeZ) then return false, nil end
	
	local halfX, halfZ = sizeX / 2, sizeZ / 2
	if position.X < posX - halfX or position.X > posX + halfX then return false, nil end
	if position.Z < posZ - halfZ or position.Z > posZ + halfZ then return false, nil end
	
	return true, TerrainGenerator.GetBlockTypeAtDepth(depth), depth
end

-- ============================================
-- LAZY TERRAIN SPAWNING (when blocks are broken)
-- ============================================

local function snapToTerrainGrid(position, buildArea)
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

local ADJACENT_OFFSETS = {
	Vector3.new(0, -BLOCK_SIZE, 0),  -- DOWN
	Vector3.new(0, BLOCK_SIZE, 0),   -- UP (needed for digging upward)
	Vector3.new(BLOCK_SIZE, 0, 0),   -- +X
	Vector3.new(-BLOCK_SIZE, 0, 0),  -- -X
	Vector3.new(0, 0, BLOCK_SIZE),   -- +Z
	Vector3.new(0, 0, -BLOCK_SIZE),  -- -Z
}

-- Horizontal-only offsets for checking wall blocks
local HORIZONTAL_OFFSETS = {
	Vector3.new(BLOCK_SIZE, 0, 0),   -- +X
	Vector3.new(-BLOCK_SIZE, 0, 0),  -- -X
	Vector3.new(0, 0, BLOCK_SIZE),   -- +Z
	Vector3.new(0, 0, -BLOCK_SIZE),  -- -Z
}

local function blockExistsAt(position, blocksFolder)
	-- Use spatial index for O(1) lookup instead of scanning all children
	if BlockSpatialIndex then
		local index = BlockSpatialIndex.GetOrCreate(blocksFolder)
		if index then
			return index:HasBlockAt(position)
		end
	end
	-- Fallback: scan all blocks (shouldn't happen if spatial index is available)
	for _, block in ipairs(blocksFolder:GetChildren()) do
		local blockPos
		local posX = block:GetAttribute("BlockPosX")
		local posY = block:GetAttribute("BlockPosY")
		local posZ = block:GetAttribute("BlockPosZ")
		if posX and posY and posZ then
			blockPos = Vector3.new(posX, posY, posZ)
		elseif block:IsA("BasePart") then
			blockPos = block.Position
		elseif block:IsA("Model") then
			blockPos = block:GetPivot().Position + Vector3.new(0, BLOCK_SIZE / 2, 0)
		end
		if blockPos and (blockPos - position).Magnitude < 1 then return true end
	end
	return false
end

local function isOutsidePlotBounds(position, buildArea)
	local posX = buildArea:GetAttribute("BasePlatePositionX")
	local posZ = buildArea:GetAttribute("BasePlatePositionZ")
	local sizeX = buildArea:GetAttribute("BasePlateSizeX")
	local sizeZ = buildArea:GetAttribute("BasePlateSizeZ")
	
	if not (posX and posZ and sizeX and sizeZ) then return false end
	
	local halfX, halfZ = sizeX / 2, sizeZ / 2
	return position.X < posX - halfX or position.X > posX + halfX or
	       position.Z < posZ - halfZ or position.Z > posZ + halfZ
end

function TerrainGenerator.OnTerrainBlockBroken(position, buildArea, plotNumber, skipMarkingAsDug)
	if DEBUG_LAZY_LOAD then print("[LazyLoad] OnTerrainBlockBroken called!") end
	if DEBUG_TERRAIN_NET then print(string.format("[BB-NET] TERRAIN OnTerrainBlockBroken pos=(%.1f,%.1f,%.1f) plot=%s skipDug=%s", position.X, position.Y, position.Z, tostring(plotNumber), tostring(skipMarkingAsDug))) end
	
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder then 
		warn("[LazyLoad] ERROR: No Blocks folder found!")
		return 0
	end
	
	local snappedPos = snapToTerrainGrid(position, buildArea)
	if DEBUG_TERRAIN_NET then print(string.format("[BB-NET] TERRAIN snapped=(%.1f,%.1f,%.1f) from input=(%.1f,%.1f,%.1f)", snappedPos.X, snappedPos.Y, snappedPos.Z, position.X, position.Y, position.Z)) end
	if DEBUG_LAZY_LOAD then print(string.format("[LazyLoad] Snapped position: (%.1f, %.1f, %.1f)", snappedPos.X, snappedPos.Y, snappedPos.Z)) end
	
	-- Only mark as dug if not skipped (shovel uses skip to avoid marking below-path position)
	if plotNumber and not skipMarkingAsDug then 
		markPositionAsDug(snappedPos, plotNumber)
		if DEBUG_TERRAIN_NET then print(string.format("[BB-NET] TERRAIN marked as dug: key=%s", getPositionKey(snappedPos))) end
	end
	
	local blocksSpawned = 0
	local skippedDugPositions = {} -- Track positions skipped because they're dug (for client prediction cleanup)
	local surfaceY = getSurfaceYAtPosition(snappedPos, buildArea)
	local baseSurfaceY = buildArea:GetAttribute("TerrainSurfaceY")
	if DEBUG_LAZY_LOAD then print(string.format("[LazyLoad] surfaceY=%s, baseSurfaceY=%s", tostring(surfaceY), tostring(baseSurfaceY))) end
	
	if not baseSurfaceY then
		warn("[LazyLoad] ERROR: TerrainSurfaceY attribute not set on buildArea!")
		return 0
	end
	
	-- Track positions we need to check (includes wall fill positions)
	local positionsToCheck = {}
	
	-- Add standard adjacent positions
	for _, offset in ipairs(ADJACENT_OFFSETS) do
		table.insert(positionsToCheck, snappedPos + offset)
	end
	
	-- Also check positions BELOW adjacent horizontal blocks (wall fill)
	-- This handles the case where digging down exposes the bottom of wall blocks
	for _, offset in ipairs(HORIZONTAL_OFFSETS) do
		local adjacentPos = snappedPos + offset
		local adjacentSurfaceY = getSurfaceYAtPosition(adjacentPos, buildArea)
		
		-- If the adjacent position's surface is above where we're digging,
		-- we need to fill blocks below it down to our level
		if adjacentSurfaceY and adjacentSurfaceY > snappedPos.Y then
			-- Add all positions below the adjacent block down to our Y level
			local fillY = snappedPos.Y
			while fillY < adjacentSurfaceY do
				local fillPos = Vector3.new(adjacentPos.X, fillY, adjacentPos.Z)
				table.insert(positionsToCheck, fillPos)
				fillY = fillY + BLOCK_SIZE
			end
		end
	end
	
	if DEBUG_TERRAIN_NET then print(string.format("[BB-NET] TERRAIN checking %d adjacent positions", #positionsToCheck)) end
	for _, adjacentPos in ipairs(positionsToCheck) do
		if plotNumber and isPositionDug(adjacentPos, plotNumber) then 
			if DEBUG_TERRAIN_NET then print(string.format("[BB-NET] TERRAIN SKIP (dug) pos=(%.1f,%.1f,%.1f) key=%s", adjacentPos.X, adjacentPos.Y, adjacentPos.Z, getPositionKey(adjacentPos))) end
			if DEBUG_LAZY_LOAD then print(string.format("[LazyLoad] Skipping (%.1f, %.1f, %.1f) - already dug", adjacentPos.X, adjacentPos.Y, adjacentPos.Z)) end
			table.insert(skippedDugPositions, adjacentPos)
			continue 
		end
		
		if isOutsidePlotBounds(adjacentPos, buildArea) and surfaceY and baseSurfaceY then
		-- Skip edge walls entirely (floor is deep enough now)
		do continue end
		-- Legacy edge wall code (disabled):
			for depth = 1, TERRAIN.MAX_DEPTH - 1 do
				local blockType = TerrainGenerator.GetBlockTypeAtDepth(depth)
				local wallPosY = depth == 1 and (baseSurfaceY - 1.25) or (baseSurfaceY - 2.5 - (BLOCK_SIZE / 2) - ((depth - 2) * BLOCK_SIZE))
				local wallPos = Vector3.new(adjacentPos.X, wallPosY, adjacentPos.Z)
				
				if not blockExistsAt(wallPos, blocksFolder) then
					local newBlock
					if depth == 1 then
						newBlock = Instance.new("Part")
						newBlock.Name = "EdgeWall_" .. math.random(100000, 999999)
						newBlock.Size = Vector3.new(BLOCK_SIZE, 2.5, BLOCK_SIZE)
						newBlock.Position = wallPos
						newBlock.Anchored = true
						newBlock.CanCollide = true
						newBlock.CanQuery = false
						newBlock.CanTouch = false
						newBlock.CastShadow = false
						newBlock.Color = Color3.fromRGB(126, 92, 60)
						newBlock.Material = Enum.Material.Ground
						newBlock.MaterialVariant = "Dirt 1"
						newBlock:SetAttribute("BlockType", blockType)
						newBlock:SetAttribute("IsTerrainBlock", true)
						newBlock:SetAttribute("IsEdgeWall", true)
						newBlock.Parent = blocksFolder
					else
						newBlock = createBlock(blockType, wallPos, blocksFolder, depth)
						if newBlock then
							newBlock:SetAttribute("IsEdgeWall", true)
							if newBlock:IsA("BasePart") then newBlock.CanQuery = false
							else for _, p in ipairs(newBlock:GetDescendants()) do if p:IsA("BasePart") then p.CanQuery = false end end end
						end
					end
					if newBlock then blocksSpawned = blocksSpawned + 1 end
				end
			end
			continue
		end
		
		local shouldHave, blockType, depth = TerrainGenerator.ShouldHaveTerrainAt(adjacentPos, buildArea)
		local alreadyExists = blockExistsAt(adjacentPos, blocksFolder)
		if DEBUG_LAZY_LOAD then
			print(string.format("[LazyLoad] Checking (%.1f, %.1f, %.1f): shouldHave=%s, blockType=%s, depth=%s, exists=%s",
				adjacentPos.X, adjacentPos.Y, adjacentPos.Z,
				tostring(shouldHave), tostring(blockType), tostring(depth), tostring(alreadyExists)))
		end
		
		if not shouldHave then
			if DEBUG_TERRAIN_NET then print(string.format("[BB-NET] TERRAIN SKIP (no terrain) pos=(%.1f,%.1f,%.1f)", adjacentPos.X, adjacentPos.Y, adjacentPos.Z)) end
		elseif alreadyExists then
			if DEBUG_TERRAIN_NET then print(string.format("[BB-NET] TERRAIN SKIP (exists) pos=(%.1f,%.1f,%.1f) type=%s", adjacentPos.X, adjacentPos.Y, adjacentPos.Z, tostring(blockType))) end
		elseif depth < 1 then
			if DEBUG_TERRAIN_NET then print(string.format("[BB-NET] TERRAIN SKIP (depth<1) pos=(%.1f,%.1f,%.1f) depth=%s", adjacentPos.X, adjacentPos.Y, adjacentPos.Z, tostring(depth))) end
		end
		
		if shouldHave and blockType and depth >= 1 and not alreadyExists then
			-- Pass isLazyLoaded=true so these blocks get saved (not marked as terrain)
			if DEBUG_TERRAIN_NET then print(string.format("[BB-NET] TERRAIN SPAWN pos=(%.1f,%.1f,%.1f) type=%s depth=%d", adjacentPos.X, adjacentPos.Y, adjacentPos.Z, blockType, depth)) end
			if DEBUG_LAZY_LOAD then print(string.format("[LazyLoad] Creating %s at depth %d", blockType, depth)) end
			local newBlock = createBlock(blockType, adjacentPos, blocksFolder, depth, true)
			if newBlock then
				blocksSpawned = blocksSpawned + 1
				if DEBUG_LAZY_LOAD then
					-- Debug: log creation position
					local actualPos
					if newBlock:IsA("BasePart") then
						actualPos = newBlock.Position
					elseif newBlock:IsA("Model") then
						local pp = newBlock.PrimaryPart or newBlock:FindFirstChildWhichIsA("BasePart")
						actualPos = pp and pp.Position or Vector3.zero
					end
					print(string.format("[LazyDebug] Created %s -> TargetPos(%.2f,%.2f,%.2f) StoredPos(%.2f,%.2f,%.2f) ActualCenter(%.2f,%.2f,%.2f)",
						blockType, adjacentPos.X, adjacentPos.Y, adjacentPos.Z,
						newBlock:GetAttribute("BlockPosX") or 0,
						newBlock:GetAttribute("BlockPosY") or 0,
						newBlock:GetAttribute("BlockPosZ") or 0,
						actualPos.X, actualPos.Y, actualPos.Z))
				end
			end
		end
	end
	
	if DEBUG_TERRAIN_NET then print(string.format("[BB-NET] TERRAIN OnTerrainBlockBroken DONE spawned=%d dugSkipped=%d at pos=(%.1f,%.1f,%.1f)", blocksSpawned, #skippedDugPositions, snappedPos.X, snappedPos.Y, snappedPos.Z)) end
	return blocksSpawned, skippedDugPositions
end

-- Get all dug positions in a cube around a center point.
-- Used to tell the client which nearby positions are dug, so it can clean up
-- phantom prediction blocks that were spawned into saved holes.
-- radius is in grid cells (e.g., 3 = 3 blocks in each direction = 7x7x7 cube)
function TerrainGenerator.GetDugPositionsInArea(centerPos, plotNumber, buildArea, radius)
	if not plotNumber or not DugPositions[plotNumber] then return {} end
	
	radius = radius or 3
	local snapped = snapToTerrainGrid(centerPos, buildArea)
	local result = {}
	
	for dx = -radius, radius do
		for dy = -radius, radius do
			for dz = -radius, radius do
				local checkPos = Vector3.new(
					snapped.X + dx * BLOCK_SIZE,
					snapped.Y + dy * BLOCK_SIZE,
					snapped.Z + dz * BLOCK_SIZE
				)
				if isPositionDug(checkPos, plotNumber) then
					table.insert(result, checkPos)
				end
			end
		end
	end
	
	return result
end

-- ============================================
-- BIOME-AWARE TERRAIN GENERATION (3D PRINTER STYLE)
-- ============================================

-- TreeGenerator and LeafDecayManager loaded separately (BiomeConfig already cached above)
local TreeGenerator = nil
local LeafDecayManager = nil

local function loadBiomeDependencies()
	-- BiomeConfig is already loaded via loadBiomeConfig() at the top
	if not BiomeConfig then
		loadBiomeConfig()
	end
	if not TreeGenerator then
		pcall(function()
			TreeGenerator = require(game:GetService("ServerScriptService"):WaitForChild("Modules"):WaitForChild("TreeGenerator"))
		end)
	end
	if not LeafDecayManager then
		pcall(function()
			LeafDecayManager = require(game:GetService("ServerScriptService"):WaitForChild("Modules"):WaitForChild("LeafDecayManager"))
		end)
	end
end

-- ============================================
-- CHUNK-BASED PROGRESSIVE SPAWNING
-- Loads terrain in 16x16 chunks, closest to player first
-- Player sees ground under them in ~0.1s instead of waiting
-- for the entire plot to generate
-- ============================================
local TERRAIN_CHUNK_SIZE = 16 -- blocks per chunk side

-- Get the first player's position for chunk priority sorting
local function getPlayerSpawnPosition()
	for _, player in ipairs(Players:GetPlayers()) do
		local char = player.Character
		if char then
			local root = char:FindFirstChild("HumanoidRootPart")
			if root then return root.Position end
		end
	end
	return nil
end

-- Reorganize Y-layer data into XZ chunks and spawn progressively
-- from the player outward. This replaces the old layer-by-layer
-- (3D printer) spawning with distance-based chunk loading.
local function spawnBlocksInChunks(params)
	local layers = params.layers
	local startX = params.startX
	local startZ = params.startZ
	local blocksFolder = params.blocksFolder
	local isMegaPlot = params.isMegaPlot
	local useFastMode = params.useFastMode
	local progressValue = params.progressValue
	
	-- Get player position for chunk priority
	local playerPos = getPlayerSpawnPosition()
	
	-- ========================================
	-- Step 1: Reorganize layers into XZ chunks
	-- ========================================
	local chunkBuckets = {}
	
	local function getOrCreateChunk(worldX, worldZ)
		local cx = math.floor((worldX - startX) / (TERRAIN_CHUNK_SIZE * BLOCK_SIZE))
		local cz = math.floor((worldZ - startZ) / (TERRAIN_CHUNK_SIZE * BLOCK_SIZE))
		local key = cx .. "_" .. cz
		if not chunkBuckets[key] then
			chunkBuckets[key] = {
				cx = cx, cz = cz,
				centerX = startX + (cx + 0.5) * TERRAIN_CHUNK_SIZE * BLOCK_SIZE,
				centerZ = startZ + (cz + 0.5) * TERRAIN_CHUNK_SIZE * BLOCK_SIZE,
				terrainBlocks = {},
				decorations = {},
				treeBlocks = {},
			}
		end
		return chunkBuckets[key]
	end
	
	-- Sort all collected blocks from Y-layers into XZ chunks
	for _, layerData in pairs(layers) do
		for _, bd in ipairs(layerData.terrainBlocks) do
			local chunk = getOrCreateChunk(bd.position.X, bd.position.Z)
			table.insert(chunk.terrainBlocks, bd)
		end
		for _, dd in ipairs(layerData.decorations) do
			local chunk = getOrCreateChunk(dd.parentPosition.X, dd.parentPosition.Z)
			table.insert(chunk.decorations, dd)
		end
		for _, td in ipairs(layerData.treeBlocks) do
			local chunk = getOrCreateChunk(td.position.X, td.position.Z)
			table.insert(chunk.treeBlocks, td)
		end
	end
	
	-- ========================================
	-- Step 2: Sort chunks by distance to player (closest first)
	-- ========================================
	local sortedChunks = {}
	for _, chunk in pairs(chunkBuckets) do
		table.insert(sortedChunks, chunk)
	end
	
	if playerPos then
		table.sort(sortedChunks, function(a, b)
			local dA = (playerPos.X - a.centerX)^2 + (playerPos.Z - a.centerZ)^2
			local dB = (playerPos.X - b.centerX)^2 + (playerPos.Z - b.centerZ)^2
			return dA < dB
		end)
	end
	
	local totalChunks = #sortedChunks
	local totalBlocks = 0
	for _, c in ipairs(sortedChunks) do
		totalBlocks = totalBlocks + #c.terrainBlocks + #c.decorations + #c.treeBlocks
	end
	
	print(string.format("[TerrainGenerator] Chunk-based loading: %d chunks (%d total blocks)", totalChunks, totalBlocks))
	if playerPos then
		print(string.format("[TerrainGenerator] Player at (%.0f, %.0f) - loading nearest chunks first", playerPos.X, playerPos.Z))
	end
	
	-- ========================================
	-- Step 3: Spawn chunks progressively
	-- ========================================
	local blocksCreated = 0
	local decorationsCreated = 0
	local treeBlocksCreated = 0
	local spawnedCount = 0
	
	for chunkIndex, chunk in ipairs(sortedChunks) do
		local pendingInChunk = {}
		
		-- Spawn terrain blocks in this chunk
		for _, blockData in ipairs(chunk.terrainBlocks) do
			local block = createBlock(blockData.blockType, blockData.position, nil, blockData.depth, false, blockData.biomeName, blockData.seasonName)
			if block then
				block:SetAttribute("SurfaceY", blockData.surfaceY)
				-- Apply blended grass color at biome borders (Default terrain)
				if blockData.blendedGrassColor then
					if block:IsA("Model") then
						local grassPart = block:FindFirstChild("Grass")
						if grassPart and grassPart:IsA("BasePart") then
							grassPart.Color = blockData.blendedGrassColor
						end
					elseif block:IsA("BasePart") then
						block.Color = blockData.blendedGrassColor
					end
				end
				table.insert(pendingInChunk, block)
				blocksCreated = blocksCreated + 1
				spawnedCount = spawnedCount + 1
			end
		end
		
		-- Spawn decorations in this chunk
		for _, decoData in ipairs(chunk.decorations) do
			local deco = createDecoration(decoData.decorationType, decoData.parentPosition, nil, decoData.biomeName, decoData.seasonName)
			if deco then
				table.insert(pendingInChunk, deco)
				decorationsCreated = decorationsCreated + 1
				spawnedCount = spawnedCount + 1
			end
		end
		
		-- Spawn tree/log/cactus blocks in this chunk
		for _, treeData in ipairs(chunk.treeBlocks) do
			local treeBlock = nil
			
			if treeData.blockType == "L" then
				treeBlock = TreeGenerator.CreateLog(treeData.position, nil, treeData.treeType)
				if treeBlock then treeBlocksCreated = treeBlocksCreated + 1; spawnedCount = spawnedCount + 1 end
			elseif treeData.blockType == "l" then
				treeBlock = TreeGenerator.CreateLeaves(treeData.position, nil, treeData.treeType, true, treeData.biomeName, treeData.seasonName)
				if treeBlock then treeBlocksCreated = treeBlocksCreated + 1; spawnedCount = spawnedCount + 1 end
			elseif treeData.blockType == "FallenLog" then
				local logTemplate = getBlockTemplate(treeData.logType)
				if logTemplate then
					local fallenLog = logTemplate:Clone()
					fallenLog.Name = treeData.logType .. "_" .. tRandom(100000, 999999)
					local rotation = CFrame.Angles(0, math.rad(treeData.rotation or 0), 0)
					if fallenLog:IsA("BasePart") then
						fallenLog.CFrame = CFrame.new(treeData.position) * rotation
						fallenLog.Anchored = true; fallenLog.CanCollide = true
					elseif fallenLog:IsA("Model") then
						fallenLog:PivotTo(CFrame.new(treeData.position - Vector3.new(0, BLOCK_SIZE / 2, 0)) * rotation)
						for _, part in ipairs(fallenLog:GetDescendants()) do
							if part:IsA("BasePart") then part.Anchored = true; part.CanCollide = true end
						end
					end
					fallenLog:SetAttribute("BlockType", treeData.logType)
					fallenLog:SetAttribute("IsFallenLog", true)
					fallenLog:SetAttribute("Rotation", treeData.rotation or 0)
					treeBlock = fallenLog
					treeBlocksCreated = treeBlocksCreated + 1; spawnedCount = spawnedCount + 1
				end
			elseif treeData.blockType == "CactusSegment" then
				local cactusTemplate = getBlockTemplate("Cactus")
				if cactusTemplate then
					local cactusBlock = cactusTemplate:Clone()
					cactusBlock.Name = "Cactus_" .. tRandom(100000, 999999)
					if cactusBlock:IsA("BasePart") then
						cactusBlock.CFrame = CFrame.new(treeData.position)
						cactusBlock.Anchored = true; cactusBlock.CanCollide = true
					elseif cactusBlock:IsA("Model") then
						cactusBlock:PivotTo(CFrame.new(treeData.position - Vector3.new(0, BLOCK_SIZE / 2, 0)))
						for _, part in ipairs(cactusBlock:GetDescendants()) do
							if part:IsA("BasePart") then part.Anchored = true; part.CanCollide = true end
						end
					end
					cactusBlock:SetAttribute("BlockType", "Cactus")
					cactusBlock:SetAttribute("IsCactus", true)
					cactusBlock:SetAttribute("BlockPosX", treeData.position.X)
					cactusBlock:SetAttribute("BlockPosY", treeData.position.Y)
					cactusBlock:SetAttribute("BlockPosZ", treeData.position.Z)
					treeBlock = cactusBlock
					treeBlocksCreated = treeBlocksCreated + 1; spawnedCount = spawnedCount + 1
				end
			end
			
			if treeBlock then
				table.insert(pendingInChunk, treeBlock)
			end
		end
		
		-- Parent all blocks in this chunk at once (batched for performance)
		for _, block in ipairs(pendingInChunk) do
			block.Parent = blocksFolder
		end
		
		-- Update progress
		if progressValue then
			progressValue.Value = math.clamp(spawnedCount / math.max(totalBlocks, 1), 0, 0.95)
		end
		
		-- Yield between chunks
		-- Skip yield for first 2 chunks so player sees terrain instantly
		if chunkIndex > 2 then
			task.wait()
		end
		
		-- Progress logging every 25%
		if chunkIndex == 1 or chunkIndex == totalChunks or chunkIndex % math.max(1, math.floor(totalChunks / 4)) == 0 then
			print(string.format("[TerrainGenerator] Chunk %d/%d spawned (%d blocks)", chunkIndex, totalChunks, spawnedCount))
		end
	end
	
	if progressValue then progressValue.Value = 1 end
	
	print(string.format("[TerrainGenerator] Chunk loading complete: %d terrain + %d deco + %d tree blocks",
		blocksCreated, decorationsCreated, treeBlocksCreated))
	
	return blocksCreated, decorationsCreated, treeBlocksCreated
end

function TerrainGenerator.GenerateFlatTerrainWithBiome(buildArea, plotNumber, biomeName, terrainStyle, savedSeed)
	if not TERRAIN.ENABLED then return end
	
	loadBiomeDependencies()
	
	-- Default to Flat if not specified
	terrainStyle = terrainStyle or "Flat"
	
	if GeneratedPlots[plotNumber] then return end
	GeneratedPlots[plotNumber] = true
	GeneratingPlots[plotNumber] = true  -- Mark as generating (prevents save corruption)
	buildArea:SetAttribute("TerrainGenerationInProgress", true)  -- Attribute flag for serializer
	BulkOperationFlags.StartBulkOperation(buildArea, "terrain_generation")  -- Disable handlers during generation
	
	-- Get biome config (optional - only needed for Natural terrain)
	local biomeConfig = nil
	if BiomeConfig then
		biomeConfig = BiomeConfig.GetBiome(biomeName)
	end
	
	-- Get plot dimensions
	local posX = buildArea:GetAttribute("BasePlatePositionX")
	local posZ = buildArea:GetAttribute("BasePlatePositionZ")
	local sizeX = buildArea:GetAttribute("BasePlateSizeX")
	local sizeZ = buildArea:GetAttribute("BasePlateSizeZ")
	
	if not (posX and posZ and sizeX and sizeZ) then
		local basePlate = buildArea:FindFirstChild("BasePlate")
		if not basePlate then return end
		posX, posZ = basePlate.Position.X, basePlate.Position.Z
		sizeX, sizeZ = basePlate.Size.X, basePlate.Size.Z
		buildArea:SetAttribute("BasePlatePositionX", posX)
		buildArea:SetAttribute("BasePlatePositionZ", posZ)
		buildArea:SetAttribute("BasePlateSizeX", sizeX)
		buildArea:SetAttribute("BasePlateSizeZ", sizeZ)
		buildArea:SetAttribute("BasePlateTop", basePlate.Position.Y + basePlate.Size.Y / 2)
	end
	
	local plateTop = buildArea:GetAttribute("BasePlateTop") or 1.5
	local blocksFolder = buildArea:FindFirstChild("Blocks") or Instance.new("Folder", buildArea)
	blocksFolder.Name = "Blocks"
	
	local gridSizeX = math.floor(sizeX / BLOCK_SIZE)
	local gridSizeZ = math.floor(sizeZ / BLOCK_SIZE)
	local startX = posX - sizeX / 2 + BLOCK_SIZE / 2
	local startZ = posZ - sizeZ / 2 + BLOCK_SIZE / 2
	local baseSurfaceY = plateTop - BLOCK_SIZE / 2
	
	buildArea:SetAttribute("TerrainSurfaceY", baseSurfaceY)
	buildArea:SetAttribute("CurrentBiome", biomeName)
	buildArea:SetAttribute("TerrainStyle", terrainStyle)
	
	-- Store exact grid dimensions to prevent floating-point mismatches during save/load
	-- This prevents the "missing stripe" bug where serialization calculates a different gridSize
	buildArea:SetAttribute("TerrainGridSizeX", gridSizeX)
	buildArea:SetAttribute("TerrainGridSizeZ", gridSizeZ)
	buildArea:SetAttribute("TerrainStartX", startX)
	buildArea:SetAttribute("TerrainStartZ", startZ)
	
	-- Get current season for color tinting (defaults to Summer if not set)
	local currentSeason = buildArea:GetAttribute("CurrentSeason") or "Summer"
	
	local startTime = tick()
	
	-- ============================================
	-- FLAT TERRAIN: Simple grass-only generation
	-- ============================================
	if terrainStyle == "Flat" then
		print("[TerrainGenerator] Generating flat grass terrain (Season: " .. currentSeason .. ")...")
		
		local grassType = TERRAIN.GRASS_BLOCK
		local blocksCreated = 0
		
		-- Flat terrain - spawn everything instantly (no animation)
		for gridX = 0, gridSizeX - 1 do
			for gridZ = 0, gridSizeZ - 1 do
				local x = startX + gridX * BLOCK_SIZE
				local z = startZ + gridZ * BLOCK_SIZE
				local grassPos = Vector3.new(x, baseSurfaceY, z)
				
				-- Pass biome name and season for grass coloring
				local block = createBlock(grassType, grassPos, blocksFolder, 0, false, biomeName, currentSeason)
				if block then
					block:SetAttribute("SurfaceY", baseSurfaceY)
					blocksCreated = blocksCreated + 1
				end
			end
			-- Yield occasionally to prevent freezing
			if gridX % 20 == 0 then task.wait() end
		end
		
		local elapsed = tick() - startTime
		print(string.format("[TerrainGenerator] Done! %d grass blocks in %.2fs", blocksCreated, elapsed))
		GeneratingPlots[plotNumber] = nil  -- Mark generation complete
		buildArea:SetAttribute("TerrainGenerationInProgress", nil)  -- Clear flag
		BulkOperationFlags.EndBulkOperation(buildArea)  -- Re-enable handlers
		return blocksCreated
	end
	
	-- ============================================
	-- NATURAL TERRAIN: Full biome with hills, trees, decorations
	-- ============================================
	if not biomeConfig then
		print("[TerrainGenerator] No biome config found, falling back to flat terrain")
		-- Fall back to flat if no biome config
		GeneratedPlots[plotNumber] = nil
		return TerrainGenerator.GenerateFlatTerrainWithBiome(buildArea, plotNumber, biomeName, "Flat", savedSeed)
	end
	
	-- Check if this is a mega plot that should use fast mode
	local isMegaPlot = plotNumber == 0
	local useFastMode = isMegaPlot and GENERATION_SETTINGS.MEGA_PLOT_FAST_MODE
	
	if useFastMode then
		print("[TerrainGenerator] Generating " .. biomeName .. " (Natural) - FAST MODE for MegaPlot...")
	else
		print("[TerrainGenerator] Generating " .. biomeName .. " (Natural) 3D-printer style...")
	end
	
	-- Noise settings from biome
	local noiseScale = biomeConfig.NoiseScale or 0.03
	local noiseAmplitude = biomeConfig.NoiseAmplitude or 6
	local noiseOctaves = biomeConfig.NoiseOctaves or 2
	local noiseSeed = savedSeed or math.random(1, 10000)
	local grassType = biomeConfig.GrassBlock or TERRAIN.GRASS_BLOCK
	
	buildArea:SetAttribute("TerrainSeed", noiseSeed)
	terrainRng = Random.new(noiseSeed)  -- Isolated RNG for deterministic generation
	print("[TerrainGenerator] Using seed: " .. noiseSeed)
	
	-- Pre-calculate height map (or restore from saved data for exact terrain reproduction)
	local heightMap = {}
	local minHeight, maxHeight = 0, 0
	
	-- Check if a saved height map was restored by SaveManager (exact terrain restoration)
	local savedHeightMapStr = buildArea:GetAttribute("TerrainHeightMap")
	local savedGridSizeX = buildArea:GetAttribute("TerrainGridSizeX")
	local savedGridSizeZ = buildArea:GetAttribute("TerrainGridSizeZ")
	
	if savedHeightMapStr and savedGridSizeX and savedGridSizeZ 
		and savedGridSizeX == gridSizeX and savedGridSizeZ == gridSizeZ then
		-- Use saved height map for exact terrain restoration (load from save)
		local heights = string.split(savedHeightMapStr, ",")
		for gx = 0, gridSizeX - 1 do
			heightMap[gx] = {}
			for gz = 0, gridSizeZ - 1 do
				local index = gx * gridSizeZ + gz + 1
				local h = tonumber(heights[index]) or 0
				heightMap[gx][gz] = h
				minHeight = math.min(minHeight, h)
				maxHeight = math.max(maxHeight, h)
			end
		end
		print(string.format("[TerrainGenerator] Using SAVED height map for exact terrain restoration (%dx%d, range %d to %d)",
			gridSizeX, gridSizeZ, minHeight, maxHeight))
	else
		-- Generate new height map from noise (first-time generation)
		if savedHeightMapStr then
			-- Clear stale height map that doesn't match current grid dimensions
			buildArea:SetAttribute("TerrainHeightMap", nil)
			print("[TerrainGenerator] Cleared stale saved height map (grid size mismatch)")
		end
		
		local terrainShape = biomeConfig.TerrainShape  -- Optional shaping curve
		local smoothingPasses = biomeConfig.SmoothingPasses or 0
		
		-- Continental noise settings from biome (or defaults)
		local continentalScale = biomeConfig.ContinentalScale or 0.005
		local continentalAmp = biomeConfig.ContinentalAmplitude or (noiseAmplitude * 0.6)
		
		for gridX = 0, gridSizeX - 1 do
			heightMap[gridX] = {}
			for gridZ = 0, gridSizeZ - 1 do
				local x, z = startX + gridX * BLOCK_SIZE, startZ + gridZ * BLOCK_SIZE
				
				-- Layer 1: Continental noise for broad rolling terrain shape
				local continental = math.noise(x * continentalScale + noiseSeed + 500, z * continentalScale + noiseSeed + 500) * continentalAmp
				continental = continental + math.noise(x * continentalScale * 2.3 + noiseSeed + 700, z * continentalScale * 2.3 + noiseSeed + 700) * continentalAmp * 0.4
				
				-- Layer 2: Detail noise for biome-specific terrain features
				local detail = 0
				local amp, freq = noiseAmplitude, noiseScale
				for _ = 1, noiseOctaves do
					detail = detail + math.noise(x * freq + noiseSeed, z * freq + noiseSeed) * amp
					amp, freq = amp * 0.5, freq * 2  -- Standard persistence for natural detail layers
				end
				
				-- Apply terrain shaping curve (ridged mountains, dunes, etc.)
				detail = shapeHeight(detail, terrainShape, noiseAmplitude)
				
				local height = math.round(continental + detail)
				heightMap[gridX][gridZ] = height
			end
			if gridX % 5 == 0 then task.wait() end
		end
		
		-- Post-process: smooth the height map to remove jagged single-block spikes
		if smoothingPasses > 0 then
			heightMap = smoothHeightMap(heightMap, gridSizeX, gridSizeZ, smoothingPasses)
		end
		
		-- Enforce max slope to prevent sheer cliff faces (max 3 block step between neighbors)
		heightMap = enforceMaxSlope(heightMap, gridSizeX, gridSizeZ, 3)
		
		-- Compress peak heights to keep terrain lower profile
		heightMap = compressHeightMap(heightMap, gridSizeX, gridSizeZ)
		
		-- Calculate min/max after all processing
		for gridX = 0, gridSizeX - 1 do
			for gridZ = 0, gridSizeZ - 1 do
				local h = heightMap[gridX][gridZ]
				minHeight = math.min(minHeight, h)
				maxHeight = math.max(maxHeight, h)
			end
		end
		
		print(string.format("[TerrainGenerator] Generated NEW height map from noise (%dx%d, range %d to %d)",
			gridSizeX, gridSizeZ, minHeight, maxHeight))
	end
	
	-- Collect all blocks by Y level (terrain + trees)
	local layers = {}
	
	local function getOrCreateLayer(y)
		local yKey = tostring(y)
		if not layers[yKey] then
			layers[yKey] = { y = y, terrainBlocks = {}, decorations = {}, treeBlocks = {} }
		end
		return layers[yKey]
	end
	
	local treeTypes = biomeConfig.TreeTypes or {}
	local treeDensity = biomeConfig.TreeDensity or 0
	local canSpawnTrees = TreeGenerator and treeDensity > 0 and #treeTypes > 0
	
	-- Fallen log settings
	local fallenLogTypes = biomeConfig.FallenLogTypes or {}
	local fallenLogDensity = biomeConfig.FallenLogDensity or 0
	local canSpawnFallenLogs = fallenLogDensity > 0 and #fallenLogTypes > 0
	
	-- Cactus settings (desert biome feature)
	local cactusDensity = biomeConfig.CactusDensity or 0
	local cactusMinHeight = biomeConfig.CactusMinHeight or 1
	local cactusMaxHeight = biomeConfig.CactusMaxHeight or 4
	local cactusMinSpacing = biomeConfig.CactusMinSpacing or 5
	local canSpawnCactus = cactusDensity > 0
	
	local treesPlanned = 0
	local fallenLogsPlanned = 0
	local cactusPlanned = 0
	local plannedTreeBases = {}
	local plannedFallenLogs = {}  -- Track fallen log positions to avoid overlap
	local plannedCactusPositions = {}  -- Track cactus positions for spacing
	local MIN_TREE_SPACING = BLOCK_SIZE * 6
	local MIN_LOG_SPACING = BLOCK_SIZE * 8  -- Fallen logs need more spacing
	local MIN_CACTUS_SPACING = BLOCK_SIZE * cactusMinSpacing
	
	local function isTooCloseToPlannedTree(pos)
		for _, treePos in ipairs(plannedTreeBases) do
			local dx = math.abs(pos.X - treePos.X)
			local dz = math.abs(pos.Z - treePos.Z)
			if dx < MIN_TREE_SPACING and dz < MIN_TREE_SPACING then
				return true
			end
		end
		return false
	end
	
	-- Collect terrain blocks and tree candidates
	for gridX = 0, gridSizeX - 1 do
		for gridZ = 0, gridSizeZ - 1 do
			local x = startX + gridX * BLOCK_SIZE
			local z = startZ + gridZ * BLOCK_SIZE
			local surfaceY = baseSurfaceY + (heightMap[gridX][gridZ] or 0) * BLOCK_SIZE
			
			local grassPos = Vector3.new(x, surfaceY, z)
			local layer = getOrCreateLayer(surfaceY)
			
			table.insert(layer.terrainBlocks, {
				blockType = grassType,
				position = grassPos,
				depth = 0,
				surfaceY = surfaceY,
				biomeName = biomeName,  -- Pass biome for grass coloring
				seasonName = currentSeason,  -- Pass season for seasonal tinting
			})
			
			-- Check for decoration
			local hasDecoration = false
			for _, decoConfig in ipairs(biomeConfig.Decorations or {}) do
				if tRandom() < decoConfig.Chance then
					table.insert(layer.decorations, {
						decorationType = decoConfig.Type,
						parentPosition = grassPos,
						biomeName = biomeName,  -- Pass biome for grass decoration coloring
						seasonName = currentSeason,  -- Pass season for seasonal tinting
					})
					hasDecoration = true
					break
				end
			end
			
			-- Check for tree
			local hasTree = false
			if canSpawnTrees and not hasDecoration and tRandom() < treeDensity then
				local treeBase = grassPos + Vector3.new(0, BLOCK_SIZE, 0)
				if not isTooCloseToPlannedTree(treeBase) then
					local treeType = treeTypes[tRandom(1, #treeTypes)]
					-- Pass biomeName and seasonName for biome/season-tinted leaf colors
					-- Pass tRandom for deterministic variant selection from terrain seed
					local treeBlocks = TreeGenerator.GetTreeBlocks(treeBase, treeType, blocksFolder, biomeName, currentSeason, false, tRandom)
					if treeBlocks then
						treesPlanned = treesPlanned + 1
						hasTree = true
						table.insert(plannedTreeBases, treeBase)
						for _, blockData in ipairs(treeBlocks) do
							local treeLayer = getOrCreateLayer(blockData.position.Y)
							-- Add seasonName to tree block data
							blockData.seasonName = currentSeason
							table.insert(treeLayer.treeBlocks, blockData)
						end
					end
				end
			end
			
			-- Check for fallen log (only if no tree or decoration)
			if canSpawnFallenLogs and not hasDecoration and not hasTree and tRandom() < fallenLogDensity then
				-- Check spacing from other fallen logs and trees
				local tooClose = false
				for _, logPos in ipairs(plannedFallenLogs) do
					if (grassPos - logPos).Magnitude < MIN_LOG_SPACING then
						tooClose = true
						break
					end
				end
				if not tooClose then
					for _, treePos in ipairs(plannedTreeBases) do
						if (grassPos - treePos).Magnitude < MIN_LOG_SPACING then
							tooClose = true
							break
						end
					end
				end
				
				if not tooClose then
					local logType = fallenLogTypes[tRandom(1, #fallenLogTypes)]
					local logPos = grassPos + Vector3.new(0, BLOCK_SIZE, 0)  -- On top of grass
					local logRotation = tRandom(0, 3) * 90  -- Random rotation
					
					-- Add to the surface layer
					table.insert(layer.treeBlocks, {
						blockType = "FallenLog",
						position = logPos,
						logType = logType,
						rotation = logRotation,
					})
					
					fallenLogsPlanned = fallenLogsPlanned + 1
					table.insert(plannedFallenLogs, grassPos)
				end
			end
			
			-- Check for cactus (desert biome - stacked 1-4 blocks tall)
			if canSpawnCactus and not hasDecoration and not hasTree and tRandom() < cactusDensity then
				-- Check spacing from other cacti and trees
				local cactusTooClose = false
				for _, cactusPos in ipairs(plannedCactusPositions) do
					if (grassPos - cactusPos).Magnitude < MIN_CACTUS_SPACING then
						cactusTooClose = true
						break
					end
				end
				if not cactusTooClose then
					for _, treePos in ipairs(plannedTreeBases) do
						if (grassPos - treePos).Magnitude < MIN_CACTUS_SPACING then
							cactusTooClose = true
							break
						end
					end
				end
				
				if not cactusTooClose then
					local cactusHeight = tRandom(cactusMinHeight, cactusMaxHeight)
					for cy = 1, cactusHeight do
						local cactusPos = grassPos + Vector3.new(0, BLOCK_SIZE * cy, 0)
						local cactusLayer = getOrCreateLayer(cactusPos.Y)
						table.insert(cactusLayer.treeBlocks, {
							blockType = "CactusSegment",
							position = cactusPos,
						})
					end
					cactusPlanned = cactusPlanned + 1
					table.insert(plannedCactusPositions, grassPos)
				end
			end
			
			-- Fill dirt below surface to prevent gaps
			-- Check adjacent positions to find the lowest neighbor (for valley walls)
			local lowestAdjacentSurface = surfaceY
			for dx = -1, 1 do
				for dz = -1, 1 do
					if dx == 0 and dz == 0 then continue end
					local adjX = gridX + dx
					local adjZ = gridZ + dz
					if adjX >= 0 and adjX < gridSizeX and adjZ >= 0 and adjZ < gridSizeZ then
						local adjHeight = heightMap[adjX] and heightMap[adjX][adjZ] or 0
						local adjSurfaceY = baseSurfaceY + adjHeight * BLOCK_SIZE
						lowestAdjacentSurface = math.min(lowestAdjacentSurface, adjSurfaceY)
					end
				end
			end
			
			-- Fill from the lower of (baseSurfaceY, lowestAdjacent) up to current surface
			-- This handles both: elevated terrain AND valley walls
			local fillStartY = math.min(baseSurfaceY, lowestAdjacentSurface)
			local fillY = fillStartY
			while fillY < surfaceY - 0.5 do
				local depthFromSurface = math.round((surfaceY - fillY) / BLOCK_SIZE)
				local fillLayer = getOrCreateLayer(fillY)
				table.insert(fillLayer.terrainBlocks, {
					blockType = "Dirt",
					position = Vector3.new(x, fillY, z),
					depth = depthFromSurface,
					surfaceY = surfaceY,
				})
				fillY = fillY + BLOCK_SIZE
			end
		end
		if gridX % 5 == 0 then task.wait() end
	end
	
	-- Edge walls disabled - floor is deep enough now that they aren't needed
	local edgeBlocksCreated = 0
	if false then -- Previously: not isMegaPlot
		print("[TerrainGenerator] Spawning edge walls for individual plot...")
		local edgeBatchCount = 0
		local edgeYieldInterval = 50
		
		for gridX = 0, gridSizeX - 1 do
			for gridZ = 0, gridSizeZ - 1 do
				local isEdge = gridX == 0 or gridX == gridSizeX - 1 or gridZ == 0 or gridZ == gridSizeZ - 1
				if not isEdge then continue end
				
				local x, z = startX + gridX * BLOCK_SIZE, startZ + gridZ * BLOCK_SIZE
				local surfaceY = baseSurfaceY + (heightMap[gridX] and heightMap[gridX][gridZ] or 0) * BLOCK_SIZE
				
				if surfaceY < baseSurfaceY - 1 then
					local outsidePositions = {}
					if gridX == 0 then table.insert(outsidePositions, {x - BLOCK_SIZE, z}) end
					if gridX == gridSizeX - 1 then table.insert(outsidePositions, {x + BLOCK_SIZE, z}) end
					if gridZ == 0 then table.insert(outsidePositions, {x, z - BLOCK_SIZE}) end
					if gridZ == gridSizeZ - 1 then table.insert(outsidePositions, {x, z + BLOCK_SIZE}) end
					
					for _, pos in ipairs(outsidePositions) do
						local fillY = baseSurfaceY - 1.25
						local depth = 1
						while fillY >= surfaceY do
							local fillBlock
							if depth == 1 then
								fillBlock = Instance.new("Part")
								fillBlock.Name = "EdgeWall_" .. math.random(100000, 999999)
								fillBlock.Size = Vector3.new(BLOCK_SIZE, 2.5, BLOCK_SIZE)
								fillBlock.Position = Vector3.new(pos[1], fillY, pos[2])
								fillBlock.Anchored = true
								fillBlock.CanCollide = true
								fillBlock.CanQuery = false
								fillBlock.CanTouch = false
								fillBlock.CastShadow = false
								fillBlock.Color = Color3.fromRGB(126, 92, 60)
								fillBlock.Material = Enum.Material.Ground
								fillBlock.MaterialVariant = "Dirt 1"
								fillBlock:SetAttribute("BlockType", "Dirt")
								fillBlock:SetAttribute("IsTerrainBlock", true)
								fillBlock:SetAttribute("IsEdgeWall", true)
								fillBlock.Parent = blocksFolder
								fillY = fillY - 2.5
							else
								fillBlock = createBlock("Dirt", Vector3.new(pos[1], fillY, pos[2]), blocksFolder, depth)
								if fillBlock then
									fillBlock:SetAttribute("IsEdgeWall", true)
									if fillBlock:IsA("BasePart") then fillBlock.CanQuery = false end
								end
								fillY = fillY - BLOCK_SIZE
							end
							if fillBlock then 
								edgeBlocksCreated = edgeBlocksCreated + 1
								edgeBatchCount = edgeBatchCount + 1
								if edgeBatchCount >= edgeYieldInterval then
									edgeBatchCount = 0
									task.wait()
								end
							end
							depth = depth + 1
						end
					end
				end
			end
			if gridX % 10 == 0 then task.wait() end
		end
	else
		print("[TerrainGenerator] MegaPlot: Skipping edge walls")
	end
	
	-- ============================================
	-- CHUNK-BASED PROGRESSIVE SPAWNING
	-- Spawns terrain in 16x16 chunks from player outward
	-- ============================================
	local progressValue = nil
	if useFastMode then
		progressValue = ReplicatedStorage:FindFirstChild("MegaPlotTerrainProgress")
		if progressValue then progressValue.Value = 0 end
	end
	
	local blocksCreated, decorationsCreated, treeBlocksCreated = spawnBlocksInChunks({
		layers = layers,
		startX = startX,
		startZ = startZ,
		blocksFolder = blocksFolder,
		isMegaPlot = isMegaPlot,
		useFastMode = useFastMode,
		progressValue = progressValue,
	})
	

	

		
	-- Store height map for lazy loading
	buildArea:SetAttribute("TerrainMinHeight", minHeight)
	buildArea:SetAttribute("TerrainMaxHeight", maxHeight)
	buildArea:SetAttribute("TerrainGridSizeX", gridSizeX)
	buildArea:SetAttribute("TerrainGridSizeZ", gridSizeZ)
	buildArea:SetAttribute("TerrainStartX", startX)
	buildArea:SetAttribute("TerrainStartZ", startZ)
	
	local heightData = {}
	for gx = 0, gridSizeX - 1 do
		for gz = 0, gridSizeZ - 1 do
			table.insert(heightData, tostring(heightMap[gx][gz]))
		end
	end
	buildArea:SetAttribute("TerrainHeightMap", table.concat(heightData, ","))
	
	local elapsed = tick() - startTime
	print(string.format("[TerrainGenerator] Done! %d terrain + %d edge + %d deco + %d tree/log/cactus blocks (%d trees, %d fallen logs, %d cacti) in %.2fs",
		blocksCreated, edgeBlocksCreated, decorationsCreated, treeBlocksCreated, treesPlanned, fallenLogsPlanned, cactusPlanned, elapsed))
	
	if LeafDecayManager and treesPlanned > 0 then
		LeafDecayManager.Initialize(buildArea)
	end
	
	TerrainGenerator.InitializeDecorationCleanup(buildArea)
	
	terrainRng = nil  -- Clear isolated RNG after generation
	GeneratingPlots[plotNumber] = nil  -- Mark generation complete
	buildArea:SetAttribute("TerrainGenerationInProgress", nil)  -- Clear flag
	BulkOperationFlags.EndBulkOperation(buildArea)  -- Re-enable handlers
	return blocksCreated
end

-- ============================================
-- BASIC FLAT TERRAIN
-- ============================================

function TerrainGenerator.GenerateFlatTerrain(buildArea, plotNumber)
	if not TERRAIN.ENABLED or GeneratedPlots[plotNumber] then return end
	GeneratedPlots[plotNumber] = true
	
	local basePlate = buildArea:FindFirstChild("BasePlate")
	if not basePlate then return end
	
	local blocksFolder = buildArea:FindFirstChild("Blocks") or Instance.new("Folder", buildArea)
	blocksFolder.Name = "Blocks"
	
	local platePos, plateSize = basePlate.Position, basePlate.Size
	local plateTop = platePos.Y + plateSize.Y / 2
	local gridSizeX = math.floor(plateSize.X / BLOCK_SIZE)
	local gridSizeZ = math.floor(plateSize.Z / BLOCK_SIZE)
	local startX = platePos.X - plateSize.X / 2 + BLOCK_SIZE / 2
	local startZ = platePos.Z - plateSize.Z / 2 + BLOCK_SIZE / 2
	local surfaceY = plateTop - BLOCK_SIZE / 2
	
	buildArea:SetAttribute("TerrainSurfaceY", surfaceY)
	
	-- Store exact grid dimensions to prevent floating-point mismatches during save/load
	buildArea:SetAttribute("TerrainGridSizeX", gridSizeX)
	buildArea:SetAttribute("TerrainGridSizeZ", gridSizeZ)
	buildArea:SetAttribute("TerrainStartX", startX)
	buildArea:SetAttribute("TerrainStartZ", startZ)
	
	local blocksCreated = 0
	for gridX = 0, gridSizeX - 1 do
		for gridZ = 0, gridSizeZ - 1 do
			if createBlock(TERRAIN.GRASS_BLOCK, Vector3.new(startX + gridX * BLOCK_SIZE, surfaceY, startZ + gridZ * BLOCK_SIZE), blocksFolder, 0) then
				blocksCreated = blocksCreated + 1
			end
		end
	end
	
	-- Initialize decoration cleanup
	TerrainGenerator.InitializeDecorationCleanup(buildArea)
	
	print("[TerrainGenerator] Flat terrain: " .. blocksCreated .. " blocks")
	return blocksCreated
end

-- ============================================
-- UTILITY FUNCTIONS
-- ============================================

-- Check and remove floating decorations after a block is broken
function TerrainGenerator.CleanupFloatingDecorations(brokenBlockPosition, blocksFolder)
	local cleaned = 0
	
	for _, child in ipairs(blocksFolder:GetChildren()) do
		if child:GetAttribute("IsDecoration") then
			local parentX = child:GetAttribute("ParentBlockX")
			local parentY = child:GetAttribute("ParentBlockY")
			local parentZ = child:GetAttribute("ParentBlockZ")
			
			if parentX and parentY and parentZ then
				local dx = math.abs(brokenBlockPosition.X - parentX)
				local dy = math.abs(brokenBlockPosition.Y - parentY)
				local dz = math.abs(brokenBlockPosition.Z - parentZ)
				
				if dx < 1 and dy < 1 and dz < 1 then
					child:Destroy()
					cleaned = cleaned + 1
				end
			end
		end
	end
	
	return cleaned
end

-- Initialize decoration cleanup listener for a build area
-- Also tracks removal of terrain-generated blocks (decorations, trees) for save persistence
function TerrainGenerator.InitializeDecorationCleanup(buildArea)
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder then return end
	
	-- Check if already initialized to prevent duplicate listeners
	if blocksFolder:GetAttribute("DecorationCleanupInitialized") then return end
	blocksFolder:SetAttribute("DecorationCleanupInitialized", true)
	
	-- Determine plot number for tracking
	local plotNumber = nil
	for i = 1, 20 do
		local prefix = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GridConfig")).BUILD_AREA_PREFIX
		if buildArea.Name == prefix .. tostring(i) then
			plotNumber = i
			break
		end
	end
	-- Also check mega plot
	if buildArea.Name == "MegaPlotBuildArea" then plotNumber = 0 end
	
	blocksFolder.ChildRemoved:Connect(function(child)
		-- Skip during bulk removal (folder being cleared)
		if blocksFolder:GetAttribute("BulkRemoving") then return end
		
		-- Skip if folder is no longer parented (being destroyed)
		if not blocksFolder.Parent then return end
		
		-- Skip if being removed by save system (batch removal during load)
		if child:GetAttribute("BeingRemovedBySaveSystem") then return end
		
		-- Skip during terrain generation
		if buildArea:GetAttribute("TerrainGenerationInProgress") then return end
		
		-- ============================================
		-- TRACK REMOVED GENERATED BLOCKS (decorations & trees)
		-- These have no PlacedBy attribute, meaning they were terrain-generated
		-- ============================================
		local hasPlacedBy = child:GetAttribute("PlacedBy") ~= nil
		
		if not hasPlacedBy and plotNumber then
			local blockType = child:GetAttribute("BlockType")
			local isDecoration = child:GetAttribute("IsDecoration")
			local isTreeBlock = child:GetAttribute("IsTreeBlock")
			local isFallenLog = child:GetAttribute("IsFallenLog")
			
			-- Track removed decorations (grass, flowers, cactus, etc.)
			if isDecoration then
				local parentX = child:GetAttribute("ParentBlockX")
				local parentY = child:GetAttribute("ParentBlockY")
				local parentZ = child:GetAttribute("ParentBlockZ")
				
				if parentX and parentY and parentZ and blockType then
					if not RemovedGeneratedBlocks[plotNumber] then
						RemovedGeneratedBlocks[plotNumber] = {}
					end
					table.insert(RemovedGeneratedBlocks[plotNumber], {
						kind = "deco",
						blockType = blockType,
						parentX = parentX,
						parentY = parentY,
						parentZ = parentZ,
					})
				end
				return -- Don't also do decoration cleanup for decorations themselves
			end
			
			-- Track removed tree blocks (logs and leaves)
			if isTreeBlock or (blockType == "Leaves" and not hasPlacedBy) then
				local posX = child:GetAttribute("BlockPosX")
				local posY = child:GetAttribute("BlockPosY")
				local posZ = child:GetAttribute("BlockPosZ")
				
				if posX and posY and posZ and blockType then
					if not RemovedGeneratedBlocks[plotNumber] then
						RemovedGeneratedBlocks[plotNumber] = {}
					end
					table.insert(RemovedGeneratedBlocks[plotNumber], {
						kind = "tree",
						blockType = blockType,
						posX = posX,
						posY = posY,
						posZ = posZ,
					})
				end
			end
			
			-- Track removed cactus blocks
			local isCactus = child:GetAttribute("IsCactus")
			if isCactus then
				local posX = child:GetAttribute("BlockPosX")
				local posY = child:GetAttribute("BlockPosY")
				local posZ = child:GetAttribute("BlockPosZ")
				
				if posX and posY and posZ and blockType then
					if not RemovedGeneratedBlocks[plotNumber] then
						RemovedGeneratedBlocks[plotNumber] = {}
					end
					table.insert(RemovedGeneratedBlocks[plotNumber], {
						kind = "tree",  -- Reuse "tree" kind since save system already handles it
						blockType = blockType,
						posX = posX,
						posY = posY,
						posZ = posZ,
					})
				end
			end
			
			-- Track removed fallen logs
			if isFallenLog then
				local posX = child:GetAttribute("BlockPosX")
				local posY = child:GetAttribute("BlockPosY")
				local posZ = child:GetAttribute("BlockPosZ")
				
				-- Fallen logs might not have BlockPosX/Y/Z, try to get from position
				if not posX then
					if child:IsA("BasePart") then
						posX = child.Position.X
						posY = child.Position.Y
						posZ = child.Position.Z
					elseif child:IsA("Model") then
						local pivot = child:GetPivot().Position
						posX = pivot.X
						posY = pivot.Y + BLOCK_SIZE / 2
						posZ = pivot.Z
					end
				end
				
				if posX and posY and posZ and blockType then
					if not RemovedGeneratedBlocks[plotNumber] then
						RemovedGeneratedBlocks[plotNumber] = {}
					end
					table.insert(RemovedGeneratedBlocks[plotNumber], {
						kind = "tree",
						blockType = blockType,
						posX = posX,
						posY = posY,
						posZ = posZ,
					})
				end
			end
		end
		
		-- ============================================
		-- DECORATION CLEANUP (when parent terrain block is broken)
		-- ============================================
		-- Skip if the removed child IS a decoration (we only clean up decos when their PARENT is removed)
		if child:GetAttribute("IsDecoration") then return end
		
		-- Get the stored position of the removed block
		local posX = child:GetAttribute("BlockPosX")
		local posY = child:GetAttribute("BlockPosY")
		local posZ = child:GetAttribute("BlockPosZ")
		
		if posX and posY and posZ then
			local blockPos = Vector3.new(posX, posY, posZ)
			TerrainGenerator.CleanupFloatingDecorations(blockPos, blocksFolder)
		end
	end)
end

-- ============================================
-- UPDATE TERRAIN COLORS (no regeneration)
-- Recolors existing grass blocks + decorations for biome/season changes
-- ============================================
function TerrainGenerator.UpdateTerrainColors(buildArea, biomeName, seasonName)
	loadBiomeConfig()
	if not BiomeConfig then
		warn("[TerrainGenerator] BiomeConfig not available for color update")
		return 0
	end
	
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder then
		warn("[TerrainGenerator] No Blocks folder found in", buildArea.Name)
		return 0
	end
	
	local biomeColors = BiomeConfig.GetBiomeColors(biomeName)
	print(string.format("[TerrainGenerator] UpdateTerrainColors: biome=%s season=%s grassColor=%s",
		biomeName, seasonName, biomeColors.GrassColor and tostring(biomeColors.GrassColor) or "nil"))
	
	local updated = 0
	local skipped = 0
	local grassBlockTypes = {
		GrassBlock = true,
		SnowGrassBlock = true,
		TaigaGrassBlock = true,
	}
	local grassDecoTypes = {
		ShortGrass = true,
		TallGrass = true,
	}
	
	local children = blocksFolder:GetChildren()
	print("[TerrainGenerator] Total children in Blocks folder:", #children)
	
	for i, child in ipairs(children) do
		local blockType = child:GetAttribute("BlockType")
		if not blockType then continue end
		
		if grassBlockTypes[blockType] then
			-- Recolor grass blocks
			applyBiomeGrassColor(child, biomeName, seasonName)
			updated = updated + 1
		elseif grassDecoTypes[blockType] or child:GetAttribute("IsDecoration") then
			-- Recolor grass decorations
			applyBiomeDecorationColor(child, blockType, biomeName, seasonName)
			updated = updated + 1
		else
			skipped = skipped + 1
		end
		
		-- Yield occasionally to avoid freezing on large plots
		if i % 500 == 0 then task.wait() end
	end
	
	print(string.format("[TerrainGenerator] Color update done: %d updated, %d skipped (biome=%s season=%s)", updated, skipped, biomeName, seasonName))
	return updated
end

-- ============================================
-- DEFAULT TERRAIN: Multi-biome world segment
-- Generates 2-3 biomes per plot using Voronoi regions
-- with temperature-based clustering
-- ============================================

function TerrainGenerator.GenerateDefaultTerrain(buildArea, plotNumber, savedSeed, preferredBiomes)
	if not TERRAIN.ENABLED then return end
	
	loadBiomeDependencies()
	if not BiomeConfig then
		warn("[TerrainGenerator] BiomeConfig required for Default terrain")
		return
	end
	
	if GeneratedPlots[plotNumber] then return end
	GeneratedPlots[plotNumber] = true
	GeneratingPlots[plotNumber] = true
	buildArea:SetAttribute("TerrainGenerationInProgress", true)
	BulkOperationFlags.StartBulkOperation(buildArea, "terrain_generation")
	
	-- Get plot dimensions
	local posX = buildArea:GetAttribute("BasePlatePositionX")
	local posZ = buildArea:GetAttribute("BasePlatePositionZ")
	local sizeX = buildArea:GetAttribute("BasePlateSizeX")
	local sizeZ = buildArea:GetAttribute("BasePlateSizeZ")
	
	if not (posX and posZ and sizeX and sizeZ) then
		local basePlate = buildArea:FindFirstChild("BasePlate")
		if not basePlate then return end
		posX, posZ = basePlate.Position.X, basePlate.Position.Z
		sizeX, sizeZ = basePlate.Size.X, basePlate.Size.Z
		buildArea:SetAttribute("BasePlatePositionX", posX)
		buildArea:SetAttribute("BasePlatePositionZ", posZ)
		buildArea:SetAttribute("BasePlateSizeX", sizeX)
		buildArea:SetAttribute("BasePlateSizeZ", sizeZ)
		buildArea:SetAttribute("BasePlateTop", basePlate.Position.Y + basePlate.Size.Y / 2)
	end
	
	local plateTop = buildArea:GetAttribute("BasePlateTop") or 1.5
	local blocksFolder = buildArea:FindFirstChild("Blocks") or Instance.new("Folder", buildArea)
	blocksFolder.Name = "Blocks"
	
	local gridSizeX = math.floor(sizeX / BLOCK_SIZE)
	local gridSizeZ = math.floor(sizeZ / BLOCK_SIZE)
	local startX = posX - sizeX / 2 + BLOCK_SIZE / 2
	local startZ = posZ - sizeZ / 2 + BLOCK_SIZE / 2
	local baseSurfaceY = plateTop - BLOCK_SIZE / 2
	
	local noiseSeed = savedSeed or math.random(1, 10000)
	terrainRng = Random.new(noiseSeed)  -- Isolated RNG for deterministic generation
	
	-- Select biomes: use preferred biomes if provided, otherwise random
	local allBiomes = BiomeConfig.GetGeneratableBiomeNames()
	local selectedBiomes = {}
	local selectedSet = {}
	
	-- Validate and use preferred biomes if provided
	local validPreferred = {}
	if preferredBiomes and type(preferredBiomes) == "table" then
		local allBiomeSet = {}
		for _, name in ipairs(allBiomes) do allBiomeSet[name] = true end
		for _, name in ipairs(preferredBiomes) do
			if type(name) == "string" and allBiomeSet[name] and not selectedSet[name] then
				table.insert(validPreferred, name)
				selectedSet[name] = true
			end
		end
	end
	
	if #validPreferred > 0 then
		-- Player specified preferred biomes
		if #validPreferred > 5 then
			-- Too many: shuffle and pick 3-5 from their selections
			for i = #validPreferred, 2, -1 do
				local j = tRandom(1, i)
				validPreferred[i], validPreferred[j] = validPreferred[j], validPreferred[i]
			end
			local count = tRandom(3, 5)
			for i = 1, math.min(count, #validPreferred) do
				table.insert(selectedBiomes, validPreferred[i])
			end
		elseif #validPreferred == 1 then
			-- Only 1 preferred: include it + 1-2 random compatible biomes
			table.insert(selectedBiomes, validPreferred[1])
			local compatible = {}
			for _, name in ipairs(allBiomes) do
				if not selectedSet[name] then
					table.insert(compatible, name)
				end
			end
			for i = #compatible, 2, -1 do
				local j = tRandom(1, i)
				compatible[i], compatible[j] = compatible[j], compatible[i]
			end
			local extraCount = tRandom(1, 2)
			for i = 1, math.min(extraCount, #compatible) do
				table.insert(selectedBiomes, compatible[i])
			end
		else
			-- 2-5 preferred: use them all
			for _, name in ipairs(validPreferred) do
				table.insert(selectedBiomes, name)
			end
		end
	else
		-- No preferred biomes: fully random selection (original behavior)
		-- Group biomes by temperature for variety
		local tempGroups = { hot = {}, warm = {}, temperate = {}, cold = {} }
		for _, name in ipairs(allBiomes) do
			local temp = BiomeConfig.BiomeTemperatures[name] or "temperate"
			if tempGroups[temp] then
				table.insert(tempGroups[temp], name)
			end
		end
		
		-- Shuffle each group
		for _, group in pairs(tempGroups) do
			for i = #group, 2, -1 do
				local j = tRandom(1, i)
				group[i], group[j] = group[j], group[i]
			end
		end
		
		-- Pick 2-3 biomes from different temperature groups for variety
		local pickOrder = {"warm", "cold", "temperate", "hot"}
		for i = #pickOrder, 2, -1 do
			local j = tRandom(1, i)
			pickOrder[i], pickOrder[j] = pickOrder[j], pickOrder[i]
		end
		
		local targetCount = tRandom(2, 3)
		for _, temp in ipairs(pickOrder) do
			if #selectedBiomes >= targetCount then break end
			local group = tempGroups[temp]
			if group and #group > 0 then
				local pick = table.remove(group)
				table.insert(selectedBiomes, pick)
				selectedSet[pick] = true
			end
		end
	end
	
	local numBiomes = #selectedBiomes
	
	print("[TerrainGenerator] Default terrain with biomes: " .. table.concat(selectedBiomes, ", "))
	print("[TerrainGenerator] Using seed: " .. noiseSeed)
	
	-- Generate Voronoi control points for biome regions
	local biomePoints = {}
	for i, biomeName in ipairs(selectedBiomes) do
		biomePoints[i] = {
			biome = biomeName,
			gridX = tRandom(math.floor(gridSizeX * 0.15), math.floor(gridSizeX * 0.85)),
			gridZ = tRandom(math.floor(gridSizeZ * 0.15), math.floor(gridSizeZ * 0.85)),
		}
	end
	
	-- Spread points apart so biomes are distinct and visible
	local minSpacing = math.min(gridSizeX, gridSizeZ) * (numBiomes <= 3 and 0.25 or 0.18)
	for attempt = 1, 40 do
		local tooClose = false
		for i = 1, #biomePoints do
			for j = i + 1, #biomePoints do
				local dx = biomePoints[i].gridX - biomePoints[j].gridX
				local dz = biomePoints[i].gridZ - biomePoints[j].gridZ
				local dist = math.sqrt(dx * dx + dz * dz)
				if dist < minSpacing then
					tooClose = true
					biomePoints[j].gridX = math.clamp(
						tRandom(math.floor(gridSizeX * 0.05), math.floor(gridSizeX * 0.95)),
						0, gridSizeX - 1
					)
					biomePoints[j].gridZ = math.clamp(
						tRandom(math.floor(gridSizeZ * 0.05), math.floor(gridSizeZ * 0.95)),
						0, gridSizeZ - 1
					)
				end
			end
		end
		if not tooClose then break end
	end
	
	-- Build biome map: for each grid cell, find nearest biome point (Voronoi)
	-- Also track second-nearest biome + blend factor for smooth border transitions
	local biomeMap = {}
	local blendMap = {} -- [gridX][gridZ] = { secondBiome, factor (0-1) }
	local BLEND_WIDTH = 14 -- How many grid cells wide the transition zone is (wider = smoother biome borders)
	
	for gridX = 0, gridSizeX - 1 do
		biomeMap[gridX] = {}
		blendMap[gridX] = {}
		for gridZ = 0, gridSizeZ - 1 do
			local nearestBiome = selectedBiomes[1]
			local secondBiome = selectedBiomes[1]
			local minDist = math.huge
			local secondDist = math.huge
			
			-- Add multi-scale noise warp for organic, natural-looking borders
			-- Large warp creates broad curves, small warp adds fine detail along edges
			local warpLargeX = math.noise(gridX * 0.02 + noiseSeed, gridZ * 0.02) * 14
			local warpLargeZ = math.noise(gridX * 0.02, gridZ * 0.02 + noiseSeed) * 14
			local warpSmallX = math.noise(gridX * 0.08 + noiseSeed + 100, gridZ * 0.08) * 5
			local warpSmallZ = math.noise(gridX * 0.08, gridZ * 0.08 + noiseSeed + 100) * 5
			local warpedX = gridX + warpLargeX + warpSmallX
			local warpedZ = gridZ + warpLargeZ + warpSmallZ
			
			for _, point in ipairs(biomePoints) do
				local dx = warpedX - point.gridX
				local dz = warpedZ - point.gridZ
				local dist = dx * dx + dz * dz  -- Squared distance (faster)
				if dist < minDist then
					secondDist = minDist
					secondBiome = nearestBiome
					minDist = dist
					nearestBiome = point.biome
				elseif dist < secondDist then
					secondDist = dist
					secondBiome = point.biome
				end
			end
			
			biomeMap[gridX][gridZ] = nearestBiome
			
			-- Compute blend factor: how close to the border between two biomes
			-- Uses the ratio of (second - nearest) distances
			-- Near border: distances are similar, factor approaches 1
			-- Deep inside biome: nearest much smaller, factor approaches 0
			local blendFactor = 0
			if secondDist > 0 and nearestBiome ~= secondBiome then
				local nearSqrt = math.sqrt(minDist)
				local secondSqrt = math.sqrt(secondDist)
				local edgeDist = (secondSqrt - nearSqrt) / 2 -- Distance from the Voronoi edge
				if edgeDist < BLEND_WIDTH then
					-- Smooth hermite interpolation for natural fade
					local t = math.clamp(edgeDist / BLEND_WIDTH, 0, 1)
					blendFactor = 1 - (t * t * (3 - 2 * t)) -- smoothstep: 1 at edge, 0 deep inside
				end
			end
			blendMap[gridX][gridZ] = { secondBiome = secondBiome, factor = blendFactor }
		end
		if gridX % 10 == 0 then task.wait() end
	end
	
	-- Store biome map as attribute for save/load
	local biomeMapData = {}
	local biomeIndexMap = {}
	for i, name in ipairs(selectedBiomes) do
		biomeIndexMap[name] = i
	end
	for gx = 0, gridSizeX - 1 do
		for gz = 0, gridSizeZ - 1 do
			table.insert(biomeMapData, tostring(biomeIndexMap[biomeMap[gx][gz]] or 1))
		end
	end
	
	buildArea:SetAttribute("TerrainSurfaceY", baseSurfaceY)
	buildArea:SetAttribute("CurrentBiome", "Default")
	buildArea:SetAttribute("TerrainStyle", "Default")
	buildArea:SetAttribute("TerrainSeed", noiseSeed)
	buildArea:SetAttribute("TerrainGridSizeX", gridSizeX)
	buildArea:SetAttribute("TerrainGridSizeZ", gridSizeZ)
	buildArea:SetAttribute("TerrainStartX", startX)
	buildArea:SetAttribute("TerrainStartZ", startZ)
	buildArea:SetAttribute("DefaultBiomes", table.concat(selectedBiomes, ","))
	buildArea:SetAttribute("DefaultBiomeMap", table.concat(biomeMapData, ","))
	
	local currentSeason = buildArea:GetAttribute("CurrentSeason") or "Summer"
	local isMegaPlot = plotNumber == 0
	local useFastMode = isMegaPlot and GENERATION_SETTINGS.MEGA_PLOT_FAST_MODE
	
	local startTime = tick()
	print("[TerrainGenerator] Generating Default multi-biome terrain (Season: " .. currentSeason .. ")...")
	
	-- Pre-calculate height map using per-cell biome settings
	-- Heights are blended at biome borders for smooth transitions
	local heightMap = {}
	local minHeight, maxHeight = 0, 0
	
	-- Check if a saved height map was restored by SaveManager (exact terrain restoration)
	local savedHeightMapStr = buildArea:GetAttribute("TerrainHeightMap")
	local savedGridSizeX = buildArea:GetAttribute("TerrainGridSizeX")
	local savedGridSizeZ = buildArea:GetAttribute("TerrainGridSizeZ")
	
	if savedHeightMapStr and savedGridSizeX and savedGridSizeZ 
		and savedGridSizeX == gridSizeX and savedGridSizeZ == gridSizeZ then
		-- Use saved height map for exact terrain restoration (load from save)
		local heights = string.split(savedHeightMapStr, ",")
		for gx = 0, gridSizeX - 1 do
			heightMap[gx] = {}
			for gz = 0, gridSizeZ - 1 do
				local index = gx * gridSizeZ + gz + 1
				local h = tonumber(heights[index]) or 0
				heightMap[gx][gz] = h
				minHeight = math.min(minHeight, h)
				maxHeight = math.max(maxHeight, h)
			end
		end
		print(string.format("[TerrainGenerator] Default: Using SAVED height map for exact terrain restoration (%dx%d, range %d to %d)",
			gridSizeX, gridSizeZ, minHeight, maxHeight))
	else
		-- Generate new height map from noise (first-time generation)
		if savedHeightMapStr then
			buildArea:SetAttribute("TerrainHeightMap", nil)
			print("[TerrainGenerator] Default: Cleared stale saved height map (grid size mismatch)")
		end
		
		-- Helper: compute raw height for a biome config at world position
		-- Uses 3-layer approach like Minecraft: continental shape + biome detail + fine roughness
		local function computeRawHeight(x, z, biomeConf)
			local noiseScale = biomeConf.NoiseScale or 0.03
			local noiseAmplitude = biomeConf.NoiseAmplitude or 6
			local noiseOctaves = biomeConf.NoiseOctaves or 3
			local terrainShape = biomeConf.TerrainShape
			
			-- Layer 1: Continental noise - very large scale rolling hills/valleys
			local continentalScale = biomeConf.ContinentalScale or 0.005
			local continentalAmp = biomeConf.ContinentalAmplitude or (noiseAmplitude * 0.6)
			local continental = math.noise(x * continentalScale + noiseSeed + 500, z * continentalScale + noiseSeed + 500) * continentalAmp
			continental = continental + math.noise(x * continentalScale * 2.3 + noiseSeed + 700, z * continentalScale * 2.3 + noiseSeed + 700) * continentalAmp * 0.4
			
			-- Layer 2: Biome detail noise - medium scale terrain features
			local detail = 0
			local amp, freq = noiseAmplitude, noiseScale
			for _ = 1, noiseOctaves do
				detail = detail + math.noise(x * freq + noiseSeed, z * freq + noiseSeed) * amp
				amp, freq = amp * 0.5, freq * 2  -- Standard persistence for natural detail
			end
			
			-- Apply terrain shaping curve to detail layer
			detail = shapeHeight(detail, terrainShape, noiseAmplitude)
			
			-- Combine: continental base + biome detail
			return continental + detail
		end
		
		for gridX = 0, gridSizeX - 1 do
			heightMap[gridX] = {}
			for gridZ = 0, gridSizeZ - 1 do
				local cellBiome = biomeMap[gridX][gridZ]
				local biomeConf = BiomeConfig.GetBiome(cellBiome)
				
				local x = startX + gridX * BLOCK_SIZE
				local z = startZ + gridZ * BLOCK_SIZE
				local height = computeRawHeight(x, z, biomeConf)
				
				-- Blend height at biome borders for smooth terrain transitions
				local blendData = blendMap[gridX] and blendMap[gridX][gridZ]
				if blendData and blendData.factor > 0.05 then
					local secondConf = BiomeConfig.GetBiome(blendData.secondBiome)
					local secondHeight = computeRawHeight(x, z, secondConf)
					height = height + (secondHeight - height) * blendData.factor * 0.5
				end
				
				height = math.round(height)
				heightMap[gridX][gridZ] = height
			end
			if gridX % 5 == 0 then task.wait() end
		end
		
		-- Post-process: smooth the height map to remove jagged spikes
		local maxSmoothPasses = 0
		for _, biomeName in ipairs(selectedBiomes) do
			local conf = BiomeConfig.GetBiome(biomeName)
			maxSmoothPasses = math.max(maxSmoothPasses, conf.SmoothingPasses or 0)
		end
		if maxSmoothPasses > 0 then
			heightMap = smoothHeightMap(heightMap, gridSizeX, gridSizeZ, maxSmoothPasses)
		end
		
		-- Enforce max slope to prevent sheer cliff faces (3 blocks allows natural hills)
		heightMap = enforceMaxSlope(heightMap, gridSizeX, gridSizeZ, 3)
		
		-- Compress peak heights to keep terrain lower profile
		heightMap = compressHeightMap(heightMap, gridSizeX, gridSizeZ)
		
		-- Calculate min/max after all processing
		for gridX = 0, gridSizeX - 1 do
			for gridZ = 0, gridSizeZ - 1 do
				local h = heightMap[gridX][gridZ]
				minHeight = math.min(minHeight, h)
				maxHeight = math.max(maxHeight, h)
			end
		end
		
		print(string.format("[TerrainGenerator] Default: Generated NEW height map from noise (%dx%d, range %d to %d)",
			gridSizeX, gridSizeZ, minHeight, maxHeight))
	end
	
	-- Store height map
	local heightData = {}
	for gx = 0, gridSizeX - 1 do
		for gz = 0, gridSizeZ - 1 do
			table.insert(heightData, tostring(heightMap[gx][gz]))
		end
	end
	buildArea:SetAttribute("TerrainHeightMap", table.concat(heightData, ","))
	buildArea:SetAttribute("TerrainMinHeight", minHeight)
	buildArea:SetAttribute("TerrainMaxHeight", maxHeight)
	
	-- Collect all blocks by Y level (same 3D printer system)
	local layers = {}
	local function getOrCreateLayer(y)
		local yKey = tostring(y)
		if not layers[yKey] then
			layers[yKey] = { y = y, terrainBlocks = {}, decorations = {}, treeBlocks = {} }
		end
		return layers[yKey]
	end
	
	local treesPlanned = 0
	local fallenLogsPlanned = 0
	local cactusPlanned = 0
	local plannedTreeBases = {}
	local plannedFallenLogs = {}
	local plannedCactusPositions = {}
	local MIN_TREE_SPACING = BLOCK_SIZE * 6
	local MIN_LOG_SPACING = BLOCK_SIZE * 8
	
	local function isTooCloseToPlannedTree(pos)
		for _, treePos in ipairs(plannedTreeBases) do
			local dx = math.abs(pos.X - treePos.X)
			local dz = math.abs(pos.Z - treePos.Z)
			if dx < MIN_TREE_SPACING and dz < MIN_TREE_SPACING then
				return true
			end
		end
		return false
	end
	
	for gridX = 0, gridSizeX - 1 do
		for gridZ = 0, gridSizeZ - 1 do
			local cellBiome = biomeMap[gridX][gridZ]
			local biomeConfig = BiomeConfig.GetBiome(cellBiome)
			
			local x = startX + gridX * BLOCK_SIZE
			local z = startZ + gridZ * BLOCK_SIZE
			local surfaceY = baseSurfaceY + (heightMap[gridX][gridZ] or 0) * BLOCK_SIZE
			local grassType = biomeConfig.GrassBlock or TERRAIN.GRASS_BLOCK
			
			local grassPos = Vector3.new(x, surfaceY, z)
			local layer = getOrCreateLayer(surfaceY)
			
			-- Compute blended grass color for border cells
			local blendData = blendMap[gridX] and blendMap[gridX][gridZ]
			local blendedGrassColor = nil
			if blendData and blendData.factor > 0.05 then
				local primaryColors = BiomeConfig.GetBiomeColors(cellBiome)
				local secondaryColors = BiomeConfig.GetBiomeColors(blendData.secondBiome)
				local primaryGrass = primaryColors and primaryColors.GrassColor
				local secondaryGrass = secondaryColors and secondaryColors.GrassColor
				if primaryGrass and secondaryGrass then
					-- Lerp using blend factor for gradual color transition across border zone
					blendedGrassColor = primaryGrass:Lerp(secondaryGrass, blendData.factor * 0.5)
				end
			end
			
			table.insert(layer.terrainBlocks, {
				blockType = grassType,
				position = grassPos,
				depth = 0,
				surfaceY = surfaceY,
				biomeName = cellBiome,
				seasonName = currentSeason,
				blendedGrassColor = blendedGrassColor,
			})
			
			-- Decorations
			local hasDecoration = false
			for _, decoConfig in ipairs(biomeConfig.Decorations or {}) do
				if tRandom() < decoConfig.Chance then
					table.insert(layer.decorations, {
						decorationType = decoConfig.Type,
						parentPosition = grassPos,
						biomeName = cellBiome,
						seasonName = currentSeason,
					})
					hasDecoration = true
					break
				end
			end
			
			-- Trees
			local treeTypes = biomeConfig.TreeTypes or {}
			local treeDensity = biomeConfig.TreeDensity or 0
			local hasTree = false
			if TreeGenerator and treeDensity > 0 and #treeTypes > 0 and not hasDecoration and tRandom() < treeDensity then
				local treeBase = grassPos + Vector3.new(0, BLOCK_SIZE, 0)
				if not isTooCloseToPlannedTree(treeBase) then
					local treeType = treeTypes[tRandom(1, #treeTypes)]
					-- Pass tRandom for deterministic variant selection from terrain seed
					local treeBlocks = TreeGenerator.GetTreeBlocks(treeBase, treeType, blocksFolder, cellBiome, currentSeason, false, tRandom)
					if treeBlocks then
						treesPlanned = treesPlanned + 1
						hasTree = true
						table.insert(plannedTreeBases, treeBase)
						for _, blockData in ipairs(treeBlocks) do
							local treeLayer = getOrCreateLayer(blockData.position.Y)
							blockData.seasonName = currentSeason
							table.insert(treeLayer.treeBlocks, blockData)
						end
					end
				end
			end
			
			-- Fallen logs
			local fallenLogTypes = biomeConfig.FallenLogTypes or {}
			local fallenLogDensity = biomeConfig.FallenLogDensity or 0
			if fallenLogDensity > 0 and #fallenLogTypes > 0 and not hasDecoration and not hasTree and tRandom() < fallenLogDensity then
				local tooClose = false
				for _, logPos in ipairs(plannedFallenLogs) do
					if (grassPos - logPos).Magnitude < MIN_LOG_SPACING then tooClose = true break end
				end
				if not tooClose then
					for _, treePos in ipairs(plannedTreeBases) do
						if (grassPos - treePos).Magnitude < MIN_LOG_SPACING then tooClose = true break end
					end
				end
				if not tooClose then
					local logType = fallenLogTypes[tRandom(1, #fallenLogTypes)]
					local logPos = grassPos + Vector3.new(0, BLOCK_SIZE, 0)
					table.insert(layer.treeBlocks, {
						blockType = "FallenLog",
						position = logPos,
						logType = logType,
						rotation = tRandom(0, 3) * 90,
					})
					fallenLogsPlanned = fallenLogsPlanned + 1
					table.insert(plannedFallenLogs, grassPos)
				end
			end
			
			-- Cactus columns (desert biome - stacked 1-4 blocks tall)
			local cellCactusDensity = biomeConfig.CactusDensity or 0
			if cellCactusDensity > 0 and not hasDecoration and not hasTree and tRandom() < cellCactusDensity then
				local cellCactusMinSpacing = BLOCK_SIZE * (biomeConfig.CactusMinSpacing or 5)
				local cactusTooClose = false
				for _, cactusPos in ipairs(plannedCactusPositions) do
					if (grassPos - cactusPos).Magnitude < cellCactusMinSpacing then
						cactusTooClose = true
						break
					end
				end
				if not cactusTooClose then
					for _, treePos in ipairs(plannedTreeBases) do
						if (grassPos - treePos).Magnitude < cellCactusMinSpacing then
							cactusTooClose = true
							break
						end
					end
				end
				if not cactusTooClose then
					local cMinH = biomeConfig.CactusMinHeight or 1
					local cMaxH = biomeConfig.CactusMaxHeight or 4
					local cactusHeight = tRandom(cMinH, cMaxH)
					for cy = 1, cactusHeight do
						local cactusPos = grassPos + Vector3.new(0, BLOCK_SIZE * cy, 0)
						local cactusLayer = getOrCreateLayer(cactusPos.Y)
						table.insert(cactusLayer.treeBlocks, {
							blockType = "CactusSegment",
							position = cactusPos,
						})
					end
					cactusPlanned = cactusPlanned + 1
					table.insert(plannedCactusPositions, grassPos)
				end
			end
			
			-- Fill dirt below surface
			local lowestAdjacentSurface = surfaceY
			for dx = -1, 1 do
				for dz = -1, 1 do
					if dx == 0 and dz == 0 then continue end
					local adjX = gridX + dx
					local adjZ = gridZ + dz
					if adjX >= 0 and adjX < gridSizeX and adjZ >= 0 and adjZ < gridSizeZ then
						local adjHeight = heightMap[adjX] and heightMap[adjX][adjZ] or 0
						local adjSurfaceY = baseSurfaceY + adjHeight * BLOCK_SIZE
						lowestAdjacentSurface = math.min(lowestAdjacentSurface, adjSurfaceY)
					end
				end
			end
			
			local fillStartY = math.min(baseSurfaceY, lowestAdjacentSurface)
			local fillY = fillStartY
			while fillY < surfaceY - 0.5 do
				local depthFromSurface = math.round((surfaceY - fillY) / BLOCK_SIZE)
				local fillLayer = getOrCreateLayer(fillY)
				table.insert(fillLayer.terrainBlocks, {
					blockType = "Dirt",
					position = Vector3.new(x, fillY, z),
					depth = depthFromSurface,
					surfaceY = surfaceY,
				})
				fillY = fillY + BLOCK_SIZE
			end
		end
		if gridX % 5 == 0 then task.wait() end
	end
	
	-- ============================================
	-- CHUNK-BASED PROGRESSIVE SPAWNING
	-- Spawns terrain in 16x16 chunks from player outward
	-- ============================================
	local progressValue = nil
	if useFastMode then
		progressValue = ReplicatedStorage:FindFirstChild("MegaPlotTerrainProgress")
		if progressValue then progressValue.Value = 0 end
	end
	
	local blocksCreated, decorationsCreated, treeBlocksCreated = spawnBlocksInChunks({
		layers = layers,
		startX = startX,
		startZ = startZ,
		blocksFolder = blocksFolder,
		isMegaPlot = isMegaPlot,
		useFastMode = useFastMode,
		progressValue = progressValue,
	})
	
	local elapsed = tick() - startTime
	print(string.format("[TerrainGenerator] Default terrain done! %d terrain + %d deco + %d tree/cactus blocks (%d trees, %d logs, %d cacti) in %.2fs",
		blocksCreated, decorationsCreated, treeBlocksCreated, treesPlanned, fallenLogsPlanned, cactusPlanned, elapsed))
	print("[TerrainGenerator] Biomes: " .. table.concat(selectedBiomes, ", "))
	
	if LeafDecayManager and treesPlanned > 0 then
		LeafDecayManager.Initialize(buildArea)
	end
	
	TerrainGenerator.InitializeDecorationCleanup(buildArea)
	
	terrainRng = nil  -- Clear isolated RNG after generation
	GeneratingPlots[plotNumber] = nil
	buildArea:SetAttribute("TerrainGenerationInProgress", nil)
	BulkOperationFlags.EndBulkOperation(buildArea)
	return blocksCreated
end

-- ============================================
-- CLEAR/UTILITY FUNCTIONS
-- ============================================

function TerrainGenerator.ClearTerrain(buildArea, plotNumber)
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if blocksFolder then
		for _, block in ipairs(blocksFolder:GetChildren()) do
			if block:GetAttribute("IsTerrainBlock") then block:Destroy() end
		end
	end
	if plotNumber then GeneratedPlots[plotNumber] = nil end
end

function TerrainGenerator.ClearAllBlocks(buildArea, plotNumber)
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if blocksFolder then
		-- Mark that we're doing bulk removal
		blocksFolder:SetAttribute("BulkRemoving", true)
		
		-- Parent to nil to disconnect from game (stops replication)
		blocksFolder.Parent = nil
		
		-- Destroy asynchronously to prevent freezing
		task.defer(function()
			blocksFolder:Destroy()
		end)
		
		-- Create fresh folder immediately
		local newFolder = Instance.new("Folder")
		newFolder.Name = "Blocks"
		newFolder.Parent = buildArea
	end
	if plotNumber then
		GeneratedPlots[plotNumber] = nil
		DugPositions[plotNumber] = nil
		RemovedGeneratedBlocks[plotNumber] = nil
	end
end

function TerrainGenerator.ResetPlot(plotNumber)
	if plotNumber then
		GeneratedPlots[plotNumber] = nil
		DugPositions[plotNumber] = nil
		RemovedGeneratedBlocks[plotNumber] = nil
	end
end

-- Mark a position as dug (called by SaveManager when loading saved dug positions)
-- This prevents the lazy loading system from refilling these positions
function TerrainGenerator.MarkPositionAsDug(position, plotNumber)
	if not plotNumber then return end
	markPositionAsDug(position, plotNumber)
	if DEBUG_TERRAIN_NET then print(string.format("[BB-NET] TERRAIN MarkPositionAsDug pos=(%.1f,%.1f,%.1f) key=%s plot=%d", position.X, position.Y, position.Z, getPositionKey(position), plotNumber)) end
end

-- Mark multiple positions as dug (more efficient for batch operations)
function TerrainGenerator.MarkPositionsAsDug(positions, plotNumber)
	if not plotNumber or not positions then return end
	if not DugPositions[plotNumber] then
		DugPositions[plotNumber] = {}
	end
	for _, position in ipairs(positions) do
		DugPositions[plotNumber][getPositionKey(position)] = true
	end
	print(string.format("[TerrainGenerator] Marked %d positions as dug for plot %d", #positions, plotNumber))
	if DEBUG_TERRAIN_NET then print(string.format("[BB-NET] TERRAIN MarkPositionsAsDug count=%d plot=%d totalDugKeys=%d", #positions, plotNumber, (function() local c=0 for _ in pairs(DugPositions[plotNumber]) do c=c+1 end return c end)())) end
end

-- Scan all terrain positions and mark any "missing" blocks as dug
-- This catches lazy-loaded blocks that were broken in a previous session
-- but weren't tracked in the surface-only dug positions list
-- Called by SaveManager after loading all blocks and initial dug marking
function TerrainGenerator.ScanAndMarkMissingTerrainAsDug(buildArea, plotNumber)
	if not plotNumber then return 0 end
	
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder then return 0 end
	
	local baseSurfaceY = buildArea:GetAttribute("TerrainSurfaceY")
	local posX = buildArea:GetAttribute("BasePlatePositionX")
	local posZ = buildArea:GetAttribute("BasePlatePositionZ")
	local sizeX = buildArea:GetAttribute("BasePlateSizeX")
	local sizeZ = buildArea:GetAttribute("BasePlateSizeZ")
	
	if not (baseSurfaceY and posX and posZ and sizeX and sizeZ) then return 0 end
	
	local originX = posX - sizeX / 2 + BLOCK_SIZE / 2
	local originZ = posZ - sizeZ / 2 + BLOCK_SIZE / 2
	local gridSizeX = math.floor(sizeX / BLOCK_SIZE)
	local gridSizeZ = math.floor(sizeZ / BLOCK_SIZE)
	
	if not DugPositions[plotNumber] then
		DugPositions[plotNumber] = {}
	end
	
	local newlyMarked = 0
	
	for gx = 0, gridSizeX - 1 do
		for gz = 0, gridSizeZ - 1 do
			local worldX = gx * BLOCK_SIZE + originX
			local worldZ = gz * BLOCK_SIZE + originZ
			
			-- Get surface Y at this column (handles natural terrain height variation)
			local testPos = Vector3.new(worldX, baseSurfaceY, worldZ)
			local surfaceY = getSurfaceYAtPosition(testPos, buildArea)
			if not surfaceY then continue end
			
			-- Check from surface down to max depth
			for depth = 0, TERRAIN.MAX_DEPTH - 1 do
				local worldY = surfaceY - (depth * BLOCK_SIZE)
				local worldPos = Vector3.new(worldX, worldY, worldZ)
				local posKey = getPositionKey(worldPos)
				
				-- Skip if already marked as dug
				if DugPositions[plotNumber][posKey] then continue end
				
				-- Skip if a block exists here (terrain or player-placed)
				if blockExistsAt(worldPos, blocksFolder) then continue end
				
				-- Position should have terrain but doesn't and isn't marked dug
				-- This means it was a lazy-loaded block broken in a previous session
				DugPositions[plotNumber][posKey] = true
				newlyMarked = newlyMarked + 1
			end
		end
	end
	
	if newlyMarked > 0 then
		print(string.format("[TerrainGenerator] ScanAndMarkMissingTerrainAsDug: Marked %d additional positions as dug for plot %d", newlyMarked, plotNumber))
		if DEBUG_TERRAIN_NET then print(string.format("[BB-NET] TERRAIN ScanMissing marked=%d totalDugKeys=%d plot=%d", newlyMarked, (function() local c=0 for _ in pairs(DugPositions[plotNumber]) do c=c+1 end return c end)(), plotNumber)) end
	else
		if DEBUG_TERRAIN_NET then print(string.format("[BB-NET] TERRAIN ScanMissing marked=0 (all accounted for) plot=%d", plotNumber)) end
	end
	
	return newlyMarked
end

-- Spawn edge wall blocks for dug positions at plot boundaries
-- Called by SaveManager during load to fill gaps at plot edges
function TerrainGenerator.SpawnEdgeWallsForDugPositions(buildArea, plotNumber, dugWorldPositions)
	if not dugWorldPositions or #dugWorldPositions == 0 then return 0 end
	if plotNumber == 0 then return 0 end -- Skip mega plots
	
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder then return 0 end
	
	local baseSurfaceY = buildArea:GetAttribute("TerrainSurfaceY")
	local posX = buildArea:GetAttribute("BasePlatePositionX")
	local posZ = buildArea:GetAttribute("BasePlatePositionZ")
	local sizeX = buildArea:GetAttribute("BasePlateSizeX")
	local sizeZ = buildArea:GetAttribute("BasePlateSizeZ")
	
	if not (baseSurfaceY and posX and posZ and sizeX and sizeZ) then return 0 end
	
	local edgeWallsCreated = 0
	local checkedOutsidePositions = {} -- Deduplicate outside positions
	
	for _, dugPos in ipairs(dugWorldPositions) do
		-- Check 4 horizontal neighbors of the dug position
		for _, offset in ipairs(HORIZONTAL_OFFSETS) do
			local adjacentPos = dugPos + offset
			
			-- Only process positions outside the plot boundary
			if not isOutsidePlotBounds(adjacentPos, buildArea) then continue end
			
			-- Deduplicate: only process each outside column once
			local colKey = string.format("%d,%d", math.round(adjacentPos.X / BLOCK_SIZE), math.round(adjacentPos.Z / BLOCK_SIZE))
			if checkedOutsidePositions[colKey] then continue end
			checkedOutsidePositions[colKey] = true
			
			-- Spawn edge walls from baseSurfaceY down (same logic as OnTerrainBlockBroken)
			for depth = 1, TERRAIN.MAX_DEPTH - 1 do
				local blockType = TerrainGenerator.GetBlockTypeAtDepth(depth)
				local wallPosY = depth == 1 and (baseSurfaceY - 1.25) or (baseSurfaceY - 2.5 - (BLOCK_SIZE / 2) - ((depth - 2) * BLOCK_SIZE))
				local wallPos = Vector3.new(adjacentPos.X, wallPosY, adjacentPos.Z)
				
				if not blockExistsAt(wallPos, blocksFolder) then
					local newBlock
					if depth == 1 then
						newBlock = Instance.new("Part")
						newBlock.Name = "EdgeWall_" .. math.random(100000, 999999)
						newBlock.Size = Vector3.new(BLOCK_SIZE, 2.5, BLOCK_SIZE)
						newBlock.Position = wallPos
						newBlock.Anchored = true
						newBlock.CanCollide = true
						newBlock.CanQuery = false
						newBlock.CanTouch = false
						newBlock.CastShadow = false
						newBlock.Color = Color3.fromRGB(126, 92, 60)
						newBlock.Material = Enum.Material.Ground
						newBlock.MaterialVariant = "Dirt 1"
						newBlock:SetAttribute("BlockType", blockType)
						newBlock:SetAttribute("IsTerrainBlock", true)
						newBlock:SetAttribute("IsEdgeWall", true)
						newBlock.Parent = blocksFolder
					else
						newBlock = createBlock(blockType, wallPos, blocksFolder, depth)
						if newBlock then
							newBlock:SetAttribute("IsEdgeWall", true)
							if newBlock:IsA("BasePart") then newBlock.CanQuery = false
							else for _, p in ipairs(newBlock:GetDescendants()) do if p:IsA("BasePart") then p.CanQuery = false end end end
						end
					end
					if newBlock then edgeWallsCreated = edgeWallsCreated + 1 end
				end
			end
		end
	end
	
	if edgeWallsCreated > 0 then
		print(string.format("[TerrainGenerator] Spawned %d edge wall blocks for %d dug boundary positions on plot %d",
			edgeWallsCreated, #dugWorldPositions, plotNumber))
	end
	return edgeWallsCreated
end

function TerrainGenerator.GetSurfaceY(buildArea)
	return buildArea:GetAttribute("TerrainSurfaceY") or 0
end

function TerrainGenerator.GetTerrainDepth()
	return TERRAIN.MAX_DEPTH
end

function TerrainGenerator.IsPlotGenerated(plotNumber)
	return GeneratedPlots[plotNumber] == true
end

-- Check if terrain generation is currently in progress for a plot
-- Used by save system to avoid saving during generation (prevents corruption)
function TerrainGenerator.IsGenerationInProgress(plotNumber)
	return GeneratingPlots[plotNumber] == true
end



function TerrainGenerator.SetGenerationSettings(settings)
	for key, value in pairs(settings) do
		if GENERATION_SETTINGS[key] ~= nil then GENERATION_SETTINGS[key] = value end
	end
end

function TerrainGenerator.GetGenerationSettings()
	return GENERATION_SETTINGS
end

-- ============================================
-- REMOVED GENERATED BLOCKS TRACKING
-- Used by SaveManager to persist decoration/tree removals
-- ============================================

-- Get list of removed generated blocks for a plot
-- Returns array of {kind, blockType, parentX/Y/Z or posX/Y/Z}
function TerrainGenerator.GetRemovedGeneratedBlocks(plotNumber)
	return RemovedGeneratedBlocks[plotNumber] or {}
end

-- Set removed generated blocks (used when loading from save data)
function TerrainGenerator.SetRemovedGeneratedBlocks(plotNumber, removals)
	RemovedGeneratedBlocks[plotNumber] = removals
end

-- Clear tracked removals (called during terrain regeneration/reset)
function TerrainGenerator.ClearRemovedGeneratedBlocks(plotNumber)
	RemovedGeneratedBlocks[plotNumber] = nil
end

-- ============================================
-- REPAIR MISSING TERRAIN STRIPS
-- Fixes the edge strip bug where save/load falsely marks edge terrain as "dug"
-- Runs after every plot load to auto-fix corrupted saves
-- ============================================

function TerrainGenerator.RepairMissingTerrain(buildArea, plotNumber)
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder then return 0 end
	
	local terrainSurfaceY = buildArea:GetAttribute("TerrainSurfaceY")
	local posX = buildArea:GetAttribute("BasePlatePositionX")
	local posZ = buildArea:GetAttribute("BasePlatePositionZ")
	local sizeX = buildArea:GetAttribute("BasePlateSizeX")
	local sizeZ = buildArea:GetAttribute("BasePlateSizeZ")
	local terrainStyle = buildArea:GetAttribute("TerrainStyle") or "Flat"
	local currentBiome = buildArea:GetAttribute("CurrentBiome") or "Plains"
	local currentSeason = buildArea:GetAttribute("CurrentSeason") or "Summer"
	
	if not (terrainSurfaceY and posX and posZ and sizeX and sizeZ) then return 0 end
	
	local gridSizeX = buildArea:GetAttribute("TerrainGridSizeX") or math.floor(sizeX / BLOCK_SIZE)
	local gridSizeZ = buildArea:GetAttribute("TerrainGridSizeZ") or math.floor(sizeZ / BLOCK_SIZE)
	local startX = buildArea:GetAttribute("TerrainStartX") or (posX - sizeX / 2 + BLOCK_SIZE / 2)
	local startZ = buildArea:GetAttribute("TerrainStartZ") or (posZ - sizeZ / 2 + BLOCK_SIZE / 2)
	
	-- Build a spatial lookup of existing blocks at the surface level
	local surfaceBlocks = {}  -- key: "gx,gz" -> true if surface occupied
	local allBlockPositions = {}  -- key: "gx,gy,gz" -> true for ALL blocks
	for _, block in ipairs(blocksFolder:GetChildren()) do
		local bx = block:GetAttribute("BlockPosX")
		local by = block:GetAttribute("BlockPosY")
		local bz = block:GetAttribute("BlockPosZ")
		
		if not (bx and by and bz) then
			if block:IsA("BasePart") then
				bx, by, bz = block.Position.X, block.Position.Y, block.Position.Z
			elseif block:IsA("Model") then
				local pp = block.PrimaryPart or block:FindFirstChildWhichIsA("BasePart")
				if pp then bx, by, bz = pp.Position.X, pp.Position.Y, pp.Position.Z end
			end
		end
		
		if bx and by and bz then
			local gx = math.round((bx - startX) / BLOCK_SIZE)
			local gy = math.round((by - terrainSurfaceY) / BLOCK_SIZE)
			local gz = math.round((bz - startZ) / BLOCK_SIZE)
			allBlockPositions[gx .. "," .. gy .. "," .. gz] = true
			
			-- Track surface-level blocks (any block at gy == 0 or gy == heightMap height)
			if gy == 0 then
				surfaceBlocks[gx .. "," .. gz] = true
			end
		end
	end
	
	-- For natural terrain, load the height map
	local heightMap = nil
	if terrainStyle ~= "Flat" then
		local heightMapStr = buildArea:GetAttribute("TerrainHeightMap")
		local storedGridSizeX = buildArea:GetAttribute("TerrainGridSizeX")
		local storedGridSizeZ = buildArea:GetAttribute("TerrainGridSizeZ")
		if heightMapStr and storedGridSizeX and storedGridSizeZ then
			local heights = string.split(heightMapStr, ",")
			heightMap = {}
			for gx = 0, storedGridSizeX - 1 do
				heightMap[gx] = {}
				for gz = 0, storedGridSizeZ - 1 do
					local index = gx * storedGridSizeZ + gz + 1
					heightMap[gx][gz] = tonumber(heights[index]) or 0
				end
			end
		end
	end
	
	-- Scan for missing surface terrain blocks and repair them
	local repaired = 0
	for gx = 0, gridSizeX - 1 do
		for gz = 0, gridSizeZ - 1 do
			-- Calculate expected surface Y for this grid position
			local relGridY = 0
			local expectedSurfaceY = terrainSurfaceY
			if terrainStyle ~= "Flat" and heightMap and heightMap[gx] and heightMap[gx][gz] then
				local heightOffset = heightMap[gx][gz]
				expectedSurfaceY = terrainSurfaceY + (heightOffset * BLOCK_SIZE)
				relGridY = heightOffset
			end
			
			local posKey = gx .. "," .. relGridY .. "," .. gz
			
			-- Check if surface block exists at expected position
			if not allBlockPositions[posKey] then
				-- SMART CHECK: Only repair if there are NO blocks below this position
				-- This distinguishes the strip bug from intentional digging
				local hasBlocksBelow = false
				for depth = 1, 5 do
					local belowKey = gx .. "," .. (relGridY - depth) .. "," .. gz
					if allBlockPositions[belowKey] then
						hasBlocksBelow = true
						break
					end
				end
				
				if not hasBlocksBelow then
					-- This is a strip bug — repair by placing a grass block
					local worldX = startX + gx * BLOCK_SIZE
					local worldZ = startZ + gz * BLOCK_SIZE
					local worldPos = Vector3.new(worldX, expectedSurfaceY, worldZ)
					
					local grassType = TERRAIN.GRASS_BLOCK
					local block = createBlock(grassType, worldPos, blocksFolder, 0, false, currentBiome, currentSeason)
					if block then
						block:SetAttribute("SurfaceY", expectedSurfaceY)
						repaired = repaired + 1
					end
				end
			end
		end
		
		if gx % 20 == 0 then task.wait() end
	end
	
	-- Clear incorrect dug markers so the fix persists across future save/load cycles
	if repaired > 0 and plotNumber then
		local dugPositions = DugPositions[plotNumber]
		if dugPositions then
			-- Rebuild: only keep dug keys that don't have a block at their position now
			local blockPositionSet = {}
			for _, block in ipairs(blocksFolder:GetChildren()) do
				local bx = block:GetAttribute("BlockPosX")
				local by = block:GetAttribute("BlockPosY")
				local bz = block:GetAttribute("BlockPosZ")
				if bx and by and bz then
					blockPositionSet[string.format("%.0f,%.0f,%.0f", bx, by, bz)] = true
				end
			end
			
			local newDug = {}
			for key, val in pairs(dugPositions) do
				if not blockPositionSet[key] then
					newDug[key] = val
				end
			end
			DugPositions[plotNumber] = newDug
		end
		
		print(string.format("[TerrainRepair] Repaired %d missing terrain blocks on plot %s", repaired, tostring(plotNumber)))
	end
	
	return repaired
end

return TerrainGenerator
