--[[
	TreeGenerator
	Spawns trees from text-based structure templates
	Uses WoodLog and Leaves blocks from ReplicatedStorage
	
	Provides methods to get tree block data for layer-by-layer world generation.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TreeStructures = require(ReplicatedStorage:WaitForChild("TreeStructures"))
local BiomeConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("BiomeConfig"))
local GridConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GridConfig"))

local TreeGenerator = {}

local BLOCK_SIZE = GridConfig.BLOCK_SIZE

local BlocksFolder = nil

local function waitForBlocks()
	if BlocksFolder then return BlocksFolder end
	BlocksFolder = ReplicatedStorage:WaitForChild("Blocks", 10)
	return BlocksFolder
end

local LOG_BLOCK_NAMES = {
	Oak = "OakLog",
	Spruce = "SpruceLog",
	Birch = "BirchLog",
	Acacia = "AcaciaLog",
	DarkOak = "DarkOakLog",
	Ebony = "EbonyLog",
	Redwood = "RedwoodLog",
}

-- Leaf block per tree type. Only Oak/Birch/Spruce have dedicated leaf blocks;
-- every other tree type falls back to OakLeaves (see resolveLeafBlockName).
-- The single "Leaves" block was split into these per-type variants.
local LEAF_BLOCK_NAMES = {
	Oak = "OakLeaves",
	Birch = "BirchLeaves",
	Spruce = "SpruceLeaves",
}
local DEFAULT_LEAF_BLOCK = "OakLeaves"

local function resolveLeafBlockName(leafType)
	return LEAF_BLOCK_NAMES[leafType] or DEFAULT_LEAF_BLOCK
end

-- Create a log block at position (position = top of block)
function TreeGenerator.CreateLog(position, parent, woodType)
	local blocks = waitForBlocks()
	if not blocks then return nil end
	
	local logBlockName = LOG_BLOCK_NAMES[woodType] or "OakLog"
	local template = blocks:FindFirstChild(logBlockName)
	if not template then
		warn("[TreeGenerator] " .. logBlockName .. " template not found!")
		return nil
	end
	
	local log = template:Clone()
	log.Name = "TreeLog_" .. math.random(100000, 999999)
	
	if log:IsA("Model") then
		local pivotPos = position - Vector3.new(0, BLOCK_SIZE / 2, 0)
		log:PivotTo(CFrame.new(pivotPos))
		for _, part in ipairs(log:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Anchored = true
				part.CanCollide = true
			end
		end
	elseif log:IsA("BasePart") then
		log.Position = position - Vector3.new(0, BLOCK_SIZE / 2, 0)
		log.Anchored = true
		log.CanCollide = true
	end
	
	log:SetAttribute("BlockType", logBlockName)
	log:SetAttribute("TreeType", woodType)
	log:SetAttribute("IsTreeBlock", true)
	log:SetAttribute("BlockPosX", position.X)
	log:SetAttribute("BlockPosY", position.Y)
	log:SetAttribute("BlockPosZ", position.Z)
	
	log.Parent = parent
	return log
end

-- Create a leaves block at position (position = top of block)
-- biomeName: optional biome name for tinted leaf colors
-- seasonName: optional season name for seasonal color tinting
function TreeGenerator.CreateLeaves(position, parent, leafType, isGenerated, biomeName, seasonName)
	local blocks = waitForBlocks()
	if not blocks then return nil end
	
	local leafBlockName = resolveLeafBlockName(leafType)
	local template = blocks:FindFirstChild(leafBlockName)
	if not template then
		warn("[TreeGenerator] " .. leafBlockName .. " template not found!")
		return nil
	end
	
	local leaves = template:Clone()
	leaves.Name = "TreeLeaves_" .. math.random(100000, 999999)
	
	-- Get leaf color with biome tint and seasonal variation
	local leafColor
	if biomeName then
		-- Use the combined biome + season + randomization function
		leafColor = BiomeConfig.GetRandomizedTintedLeafColor(leafType, biomeName, seasonName)
	else
		local leafConfig = BiomeConfig.LeafTypes[leafType] or BiomeConfig.LeafTypes.Oak
		leafColor = leafConfig.Color
		-- Still apply random variation even without biome
		leafColor = BiomeConfig.GetRandomizedLeafColor(leafColor)
	end
	
	-- The per-type leaf blocks are textured on all 6 faces; the visible colour comes
	-- from those Texture/Decal faces, not the part .Color. Tint every face so the
	-- per-block random/biome variation actually shows (restores the old look).
	for _, d in ipairs(leaves:GetDescendants()) do
		if d:IsA("Decal") then  -- Texture is a subclass of Decal, so this covers both
			d.Color3 = leafColor
		end
	end
	
	if leaves:IsA("BasePart") then
		leaves.Color = leafColor
		leaves.Position = position  -- Position is center, no offset needed for BaseParts
		leaves.Anchored = true
		leaves.CanCollide = true
	elseif leaves:IsA("Model") then
		-- Models have bottom-center pivot, so offset down by half block
		local pivotPos = position - Vector3.new(0, BLOCK_SIZE / 2, 0)
		leaves:PivotTo(CFrame.new(pivotPos))
		for _, part in ipairs(leaves:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Color = leafColor
				part.Anchored = true
				part.CanCollide = true
			end
		end
	end
	
	leaves:SetAttribute("BlockType", leafBlockName)
	leaves:SetAttribute("TreeType", leafType)
	leaves:SetAttribute("IsTreeBlock", true)
	leaves:SetAttribute("BlockPosX", position.X)
	leaves:SetAttribute("BlockPosY", position.Y)
	leaves:SetAttribute("BlockPosZ", position.Z)
	if biomeName then
		leaves:SetAttribute("Biome", biomeName)
	end
	if seasonName then
		leaves:SetAttribute("Season", seasonName)
	end
	
	-- Mark as decayable if generated (not player-placed)
	if isGenerated then
		leaves:SetAttribute("CanDecay", true)
	end
	
	leaves.Parent = parent
	return leaves
end

-- Check if position is within plot bounds
local function isWithinPlotBounds(position, blocksFolder)
	local buildArea = blocksFolder.Parent
	if not buildArea then 
		print("[TreeGenerator] isWithinPlotBounds: No buildArea, returning true")
		return true 
	end
	
	local posX = buildArea:GetAttribute("BasePlatePositionX")
	local posZ = buildArea:GetAttribute("BasePlatePositionZ")
	local sizeX = buildArea:GetAttribute("BasePlateSizeX")
	local sizeZ = buildArea:GetAttribute("BasePlateSizeZ")
	
	if not (posX and posZ and sizeX and sizeZ) then 
		print("[TreeGenerator] isWithinPlotBounds: Missing plot attributes, returning true")
		return true 
	end
	
	local halfX, halfZ = sizeX / 2, sizeZ / 2
	
	if position.X < posX - halfX or position.X > posX + halfX then 
		print(string.format("[TreeGenerator] Out of X bounds: pos.X=%.1f, range=[%.1f, %.1f]",
			position.X, posX - halfX, posX + halfX))
		return false 
	end
	if position.Z < posZ - halfZ or position.Z > posZ + halfZ then 
		print(string.format("[TreeGenerator] Out of Z bounds: pos.Z=%.1f, range=[%.1f, %.1f]",
			position.Z, posZ - halfZ, posZ + halfZ))
		return false 
	end
	
	return true
end

-- Check if a tree can be placed at position
-- skipDistanceCheck: if true, only checks trunk is within bounds (for sapling growth)
function TreeGenerator.CanPlaceTree(basePosition, structure, blocksFolder, skipDistanceCheck)
	local width, height, depth = TreeStructures.GetStructureDimensions(structure)
	local halfW = math.floor(width / 2)
	local halfD = math.floor(depth / 2)
	
	-- Minimum distance from other tree blocks (accounts for canopy overlap)
	-- OakMedium has 5x5 canopy, so trees need ~5 block gap to not overlap
	-- Only enforced for terrain generation, not sapling growth
	local MIN_TREE_DISTANCE = BLOCK_SIZE * 5
	
	print(string.format("[TreeGenerator] CanPlaceTree at (%.1f, %.1f, %.1f), skipDistanceCheck=%s",
		basePosition.X, basePosition.Y, basePosition.Z, tostring(skipDistanceCheck)))
	
	-- For sapling growth, only check that the base position is within bounds
	-- Leaves can extend beyond plot edges
	if skipDistanceCheck then
		if not isWithinPlotBounds(basePosition, blocksFolder) then
			print("[TreeGenerator] FAILED: Base position out of plot bounds")
			return false
		end
		print("[TreeGenerator] CanPlaceTree: SUCCESS (sapling mode - only checked base)")
		return true
	end
	
	-- For terrain generation, check all blocks
	for layerIndex, layer in ipairs(structure) do
		for rowIndex, row in ipairs(layer) do
			for colIndex = 1, #row do
				local char = row:sub(colIndex, colIndex)
				if char ~= "." then
					local offsetX = (colIndex - 1 - halfW) * BLOCK_SIZE
					local offsetY = (layerIndex - 1) * BLOCK_SIZE
					local offsetZ = (rowIndex - 1 - halfD) * BLOCK_SIZE
					
					local checkPos = basePosition + Vector3.new(offsetX, offsetY, offsetZ)
					
					if not isWithinPlotBounds(checkPos, blocksFolder) then
						print(string.format("[TreeGenerator] FAILED: Block at (%.1f, %.1f, %.1f) out of plot bounds",
							checkPos.X, checkPos.Y, checkPos.Z))
						return false
					end
					
					-- Check distance from other trees
					for _, block in ipairs(blocksFolder:GetChildren()) do
						if block:GetAttribute("IsTreeBlock") then
							local blockPos
							if block:IsA("BasePart") then
								blockPos = block.Position
							elseif block:IsA("Model") then
								local primary = block.PrimaryPart or block:FindFirstChildWhichIsA("BasePart")
								if primary then blockPos = primary.Position end
							end
							
							if blockPos and (blockPos - checkPos).Magnitude < MIN_TREE_DISTANCE then
								return false
							end
						end
					end
				end
			end
		end
	end
	
	print("[TreeGenerator] CanPlaceTree: SUCCESS")
	return true
end

-- Get all block positions for a tree (for layer-by-layer world generation)
-- Returns array of {position, blockType, treeType, biomeName, seasonName} where blockType is "L" (log) or "l" (leaves)
-- skipDistanceCheck: if true, skip the tree spacing check (for sapling growth)
-- rngFunc: optional function(min, max) for deterministic variant selection (e.g. terrain RNG)
function TreeGenerator.GetTreeBlocks(basePosition, treeType, blocksFolder, biomeName, seasonName, skipDistanceCheck, rngFunc)
	print(string.format("[TreeGenerator] GetTreeBlocks called: treeType=%s, pos=(%.1f, %.1f, %.1f), skip=%s",
		treeType, basePosition.X, basePosition.Y, basePosition.Z, tostring(skipDistanceCheck)))
	
	local structure, structureName = TreeStructures.GetRandomStructure(treeType, rngFunc)
	if not structure then
		warn("[TreeGenerator] GetTreeBlocks: No structure found for tree type: " .. tostring(treeType))
		return nil
	end
	print("[TreeGenerator] Using structure: " .. tostring(structureName))
	
	if not TreeGenerator.CanPlaceTree(basePosition, structure, blocksFolder, skipDistanceCheck) then
		print("[TreeGenerator] GetTreeBlocks: CanPlaceTree returned false")
		return nil
	end
	
	local width, height, depth = TreeStructures.GetStructureDimensions(structure)
	local halfW = math.floor(width / 2)
	local halfD = math.floor(depth / 2)
	
	local blocks = {}
	local logPositions = {}  -- Track log positions to prevent leaf overlap
	
	-- First pass: collect all log positions
	for layerIndex, layer in ipairs(structure) do
		for rowIndex, row in ipairs(layer) do
			for colIndex = 1, #row do
				local char = row:sub(colIndex, colIndex)
				
				if char == "L" then
					local offsetX = (colIndex - 1 - halfW) * BLOCK_SIZE
					local offsetY = (layerIndex - 1) * BLOCK_SIZE
					local offsetZ = (rowIndex - 1 - halfD) * BLOCK_SIZE
					
					local blockPos = basePosition + Vector3.new(offsetX, offsetY, offsetZ)
					table.insert(logPositions, blockPos)
					
					table.insert(blocks, {
						position = blockPos,
						blockType = "L",
						treeType = treeType,
						biomeName = biomeName,
						seasonName = seasonName,
					})
				end
			end
		end
	end
	
	-- Helper to check if position is too close to any log
	local function isTooCloseToLog(pos)
		for _, logPos in ipairs(logPositions) do
			-- Check each axis separately with nearly full block tolerance
			if math.abs(pos.X - logPos.X) < BLOCK_SIZE * 0.9 and
			   math.abs(pos.Y - logPos.Y) < BLOCK_SIZE * 0.9 and
			   math.abs(pos.Z - logPos.Z) < BLOCK_SIZE * 0.9 then
				return true
			end
		end
		return false
	end
	
	-- Second pass: collect leaves, skipping any that overlap with logs
	for layerIndex, layer in ipairs(structure) do
		for rowIndex, row in ipairs(layer) do
			for colIndex = 1, #row do
				local char = row:sub(colIndex, colIndex)
				
				if char == "l" then
					local offsetX = (colIndex - 1 - halfW) * BLOCK_SIZE
					local offsetY = (layerIndex - 1) * BLOCK_SIZE
					local offsetZ = (rowIndex - 1 - halfD) * BLOCK_SIZE
					
					local blockPos = basePosition + Vector3.new(offsetX, offsetY, offsetZ)
					
					-- Only add leaf if not too close to any log
					if not isTooCloseToLog(blockPos) then
						table.insert(blocks, {
							position = blockPos,
							blockType = "l",
							treeType = treeType,
							biomeName = biomeName,
							seasonName = seasonName,
						})
					end
				end
			end
		end
	end
	
	-- SNOWY BIOME: cap the sky-exposed top leaves with a thin SnowLayer (the same
	-- block snow-on-grass uses). A leaf is "sky-exposed" when it's the highest tree
	-- block in its X/Z column; the cap goes in the cell above and the spawner drops
	-- it to rest on the leaf's top face. Only the canopy crown gets snow, not leaves
	-- buried under an overhang.
	if biomeName == "Snowy" then
		local function colKey(p)
			return string.format("%d_%d", math.round(p.X / BLOCK_SIZE), math.round(p.Z / BLOCK_SIZE))
		end
		local topY = {}
		for _, b in ipairs(blocks) do
			if b.blockType == "L" or b.blockType == "l" then
				local k = colKey(b.position)
				if not topY[k] or b.position.Y > topY[k] then topY[k] = b.position.Y end
			end
		end
		local snowCaps = {}
		for _, b in ipairs(blocks) do
			if b.blockType == "l" and topY[colKey(b.position)]
				and math.abs(b.position.Y - topY[colKey(b.position)]) < BLOCK_SIZE * 0.5 then
				table.insert(snowCaps, {
					position = b.position + Vector3.new(0, BLOCK_SIZE, 0),
					blockType = "SnowLayer",
					treeType = treeType,
					biomeName = biomeName,
					seasonName = seasonName,
				})
			end
		end
		for _, cap in ipairs(snowCaps) do
			table.insert(blocks, cap)
		end
	end
	
	return blocks
end

-- Spawn a tree instantly (for non-animated use)
function TreeGenerator.SpawnTree(basePosition, treeType, blocksFolder)
	local treeBlocks = TreeGenerator.GetTreeBlocks(basePosition, treeType, blocksFolder)
	if not treeBlocks then
		return false
	end
	
	local blocksCreated = 0
	
	-- Spawn logs first, then leaves (GetTreeBlocks already filters overlaps)
	for _, blockData in ipairs(treeBlocks) do
		if blockData.blockType == "L" then
			if TreeGenerator.CreateLog(blockData.position, blocksFolder, blockData.treeType) then
				blocksCreated = blocksCreated + 1
			end
		end
	end
	
	for _, blockData in ipairs(treeBlocks) do
		if blockData.blockType == "l" then
			if TreeGenerator.CreateLeaves(blockData.position, blocksFolder, blockData.treeType) then
				blocksCreated = blocksCreated + 1
			end
		end
	end
	
	return true, blocksCreated
end

function TreeGenerator.GetTreeBaseOffset()
	return BLOCK_SIZE
end

return TreeGenerator
