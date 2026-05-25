--[[
	ArchitravePlacement
	Dynamic architrave connection system with vertical stacking
	
	Horizontal Connection Types:
	- single: 0 neighbors (standalone)
	- end: 1 neighbor (end cap)
	- middle: 2 opposite neighbors (straight line)
	- corner: 2 perpendicular neighbors (L-shape)
	
	Vertical Stacking:
	- 1 high: base names (ArchitraveSingle, etc.)
	- Top of stack: base + "Top" suffix
	- Bottom of stack: base + "Bottom" suffix
	- 3+ high middle: base + "Middle" suffix
	
	Models are stored in ReplicatedStorage > Architraves folder.
	All models use CENTER pivot (like BlockTemplates).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ArchitravePlacement = {}

-- ============================================
-- CONFIGURATION
-- ============================================

local BLOCK_SIZE = 3
local DEBUG_ARCHITRAVES = false

-- Spatial index for O(1) lookups
local BlockSpatialIndex = nil
local function getSpatialIndex(blocksFolder)
	if not BlockSpatialIndex then
		local mod = ReplicatedStorage:FindFirstChild("BlockSpatialIndex")
		if mod then
			BlockSpatialIndex = require(mod)
		end
	end
	if BlockSpatialIndex then
		return BlockSpatialIndex.GetOrCreate(blocksFolder)
	end
	return nil
end

-- Base template names for each horizontal connection type
local BASE_TEMPLATE_NAMES = {
	single = "ArchitraveSingle",
	["end"] = "ArchitraveSingleEnd",
	middle = "ArchitraveSingleMiddle",
	corner = "ArchitraveSingleCorner",
}

-- Vertical suffixes
local VERTICAL_SUFFIXES = {
	single = "",
	top = "Top",
	bottom = "Bottom",
	middle = "Middle",
}

function ArchitravePlacement.GetTemplateName(horizontalType, verticalType)
	local base = BASE_TEMPLATE_NAMES[horizontalType] or "ArchitraveSingle"
	local suffix = VERTICAL_SUFFIXES[verticalType] or ""
	return base .. suffix
end

-- ============================================
-- DIRECTION SYSTEM
-- ============================================

ArchitravePlacement.Direction = {
	NORTH = 0, EAST = 1, SOUTH = 2, WEST = 3,
}

local DIRECTION_OFFSETS = {
	[0] = Vector3.new(0, 0, -BLOCK_SIZE),
	[1] = Vector3.new(BLOCK_SIZE, 0, 0),
	[2] = Vector3.new(0, 0, BLOCK_SIZE),
	[3] = Vector3.new(-BLOCK_SIZE, 0, 0),
}

local DIRECTION_NAMES = {
	[0] = "NORTH (-Z)", [1] = "EAST (+X)", [2] = "SOUTH (+Z)", [3] = "WEST (-X)",
}

local function areOppositeDirections(dir1, dir2)
	return (dir1 + 2) % 4 == dir2
end

-- ============================================
-- ARCHITRAVE TYPE DETECTION
-- ============================================

function ArchitravePlacement.IsArchitrave(blockType)
	if not blockType then return false end
	return blockType == "Architrave"
end

function ArchitravePlacement.IsArchitraveInstance(block)
	if not block then return false end
	if block:GetAttribute("IsArchitrave") then return true end
	return ArchitravePlacement.IsArchitrave(block:GetAttribute("BlockType"))
end

-- ============================================
-- NEIGHBOR LOOKUPS
-- ============================================

function ArchitravePlacement.GetArchitraveAtPosition(position, blocksFolder)
	if not blocksFolder then return nil end
	
	local index = getSpatialIndex(blocksFolder)
	local candidates
	if index then
		candidates = index:GetBlocksAt(position)
	else
		candidates = blocksFolder:GetChildren()
	end
	
	for _, block in ipairs(candidates) do
		if ArchitravePlacement.IsArchitraveInstance(block) then
			local bx = block:GetAttribute("BlockPosX")
			local by = block:GetAttribute("BlockPosY")
			local bz = block:GetAttribute("BlockPosZ")
			local blockPos
			if bx and by and bz then
				blockPos = Vector3.new(bx, by, bz)
			elseif block:IsA("Model") then
				blockPos = block:GetPivot().Position
			elseif block:IsA("BasePart") then
				blockPos = block.Position
			end
			
			if blockPos then
				local diff = position - blockPos
				if math.abs(diff.X) < 1.5 and math.abs(diff.Y) < 1.5 and math.abs(diff.Z) < 1.5 then
					return {
						instance = block,
						connectionType = block:GetAttribute("ArchitraveConnectionType") or "single",
						modelName = block:GetAttribute("ArchitraveModelName") or "ArchitraveSingle",
						position = blockPos,
					}
				end
			end
		end
	end
	return nil
end

function ArchitravePlacement.GetArchitraveNeighbors(position, blocksFolder)
	local neighbors = { [0] = false, [1] = false, [2] = false, [3] = false }
	
	for dir = 0, 3 do
		local checkPos = position + DIRECTION_OFFSETS[dir]
		local neighbor = ArchitravePlacement.GetArchitraveAtPosition(checkPos, blocksFolder)
		if neighbor then
			neighbors[dir] = true
			if DEBUG_ARCHITRAVES then
				print(string.format("[Architrave] Found neighbor at %s", DIRECTION_NAMES[dir]))
			end
		end
	end
	
	return neighbors
end

function ArchitravePlacement.GetVerticalNeighbors(position, blocksFolder)
	local hasAbove = ArchitravePlacement.GetArchitraveAtPosition(
		position + Vector3.new(0, BLOCK_SIZE, 0), blocksFolder) ~= nil
	local hasBelow = ArchitravePlacement.GetArchitraveAtPosition(
		position - Vector3.new(0, BLOCK_SIZE, 0), blocksFolder) ~= nil
	return hasAbove, hasBelow
end

function ArchitravePlacement.DetermineVerticalType(hasAbove, hasBelow)
	if hasAbove and hasBelow then return "middle"
	elseif hasAbove then return "bottom"
	elseif hasBelow then return "top"
	else return "single" end
end

-- ============================================
-- HORIZONTAL CONNECTION TYPE DETERMINATION
-- ============================================

local function lookVectorToDirection(lookVector)
	if not lookVector then return nil end
	local absX = math.abs(lookVector.X)
	local absZ = math.abs(lookVector.Z)
	if absX > absZ then
		return lookVector.X > 0 and 1 or 3
	else
		return lookVector.Z > 0 and 2 or 0
	end
end

function ArchitravePlacement.DetermineConnectionType(neighbors, position, blocksFolder, lookVector)
	local neighborCount = 0
	local connectedDirs = {}
	
	for dir = 0, 3 do
		if neighbors[dir] then
			neighborCount = neighborCount + 1
			table.insert(connectedDirs, dir)
		end
	end
	
	if DEBUG_ARCHITRAVES then
		print(string.format("[Architrave] Neighbor count: %d, directions: %s",
			neighborCount, table.concat(connectedDirs, ", ")))
	end
	
	if neighborCount == 0 then
		return "single", nil, nil
		
	elseif neighborCount == 1 then
		local neighborDir = connectedDirs[1]
		if lookVector then
			local lookDir = lookVectorToDirection(lookVector)
			if lookDir and not areOppositeDirections(neighborDir, lookDir) and lookDir ~= neighborDir then
				if DEBUG_ARCHITRAVES then
					print(string.format("[Architrave] Smart corner: neighbor=%s, lookDir=%s",
						DIRECTION_NAMES[neighborDir], DIRECTION_NAMES[lookDir]))
				end
				return "corner", neighborDir, lookDir
			end
		end
		return "end", connectedDirs[1], nil
		
	elseif neighborCount == 2 then
		local dir1, dir2 = connectedDirs[1], connectedDirs[2]
		if areOppositeDirections(dir1, dir2) then
			return "middle", math.min(dir1, dir2), nil
		else
			return "corner", dir1, dir2
		end
		
	elseif neighborCount == 3 then
		for _, d in ipairs(connectedDirs) do
			local opposite = (d + 2) % 4
			if neighbors[opposite] then
				return "middle", math.min(d, opposite), nil
			end
		end
		return "single", nil, nil
		
	else
		return "middle", 0, nil
	end
end

-- ============================================
-- ROTATION CALCULATION
-- ============================================

-- These rotations are tuned for the single-height models as they exist in Studio.
-- The Top/Bottom/Middle variants are all at 0,0,0 orientation in Studio,
-- while SingleEnd and SingleCorner are at 0,90,0.
-- We apply a -90 correction for non-single vertical variants of end/corner.

function ArchitravePlacement.GetArchitraveRotation(connectionType, primaryDir, secondaryDir, verticalType)
	local rotation = 0
	
	if connectionType == "single" then
		rotation = 0
		
	elseif connectionType == "end" then
		local rotations = {
			[0] = 0, [1] = -90, [2] = 180, [3] = 90,
		}
		rotation = rotations[primaryDir] or 0
		
	elseif connectionType == "middle" then
		if primaryDir == 0 or primaryDir == 2 then
			rotation = 90
		else
			rotation = 0
		end
		
	elseif connectionType == "corner" then
		local dirs = {primaryDir, secondaryDir}
		table.sort(dirs)
		
		local hasNorth = dirs[1] == 0 or dirs[2] == 0
		local hasEast = dirs[1] == 1 or dirs[2] == 1
		local hasSouth = dirs[1] == 2 or dirs[2] == 2
		
		if hasNorth and hasEast then rotation = 90
		elseif hasEast and hasSouth then rotation = 0
		elseif hasSouth then rotation = -90 -- hasSouth and hasWest
		else rotation = 180 end -- hasWest and hasNorth
	end
	
	-- Correct for Studio orientation difference:
	-- SingleEnd and SingleCorner are at 0,90,0 in Studio
	-- Their Top/Bottom/Middle variants are at 0,0,0
	-- So non-single vertical variants need -90 to compensate
	if verticalType ~= "single" and (connectionType == "end" or connectionType == "corner") then
		rotation = rotation - 90
	end
	
	return rotation
end

-- ============================================
-- PLACEMENT INFO
-- ============================================

function ArchitravePlacement.GetPlacementInfo(blockType, position, blocksFolder, debugOutput, lookVector)
	-- Horizontal connection
	local neighbors = ArchitravePlacement.GetArchitraveNeighbors(position, blocksFolder)
	local connectionType, primaryDir, secondaryDir = ArchitravePlacement.DetermineConnectionType(neighbors, position, blocksFolder, lookVector)
	
	-- Vertical stacking
	local hasAbove, hasBelow = ArchitravePlacement.GetVerticalNeighbors(position, blocksFolder)
	local verticalType = ArchitravePlacement.DetermineVerticalType(hasAbove, hasBelow)
	
	-- Get rotation (includes vertical correction for end/corner)
	local rotation = ArchitravePlacement.GetArchitraveRotation(connectionType, primaryDir, secondaryDir, verticalType)
	
	-- Combined template name
	local templateName = ArchitravePlacement.GetTemplateName(connectionType, verticalType)
	
	if debugOutput or DEBUG_ARCHITRAVES then
		print(string.format("[Architrave] PlacementInfo: hType=%s, vType=%s, template=%s, rotation=%d",
			connectionType, verticalType, templateName, rotation))
	end
	
	return {
		templateName = templateName,
		connectionType = connectionType,
		verticalType = verticalType,
		rotation = rotation,
		primaryDirection = primaryDir,
		secondaryDirection = secondaryDir,
		neighbors = neighbors,
	}
end

-- Get CFrame for architrave placement (center pivot, just position + Y rotation)
function ArchitravePlacement.GetArchitraveCFrame(position, rotation)
	return CFrame.new(position) * CFrame.Angles(0, math.rad(rotation), 0)
end

-- ============================================
-- NEIGHBOR UPDATES (horizontal + vertical)
-- ============================================

function ArchitravePlacement.UpdateAdjacentArchitraves(position, blocksFolder, createArchitraveFunc)
	local updated = {}
	
	local allOffsets = {
		DIRECTION_OFFSETS[0], DIRECTION_OFFSETS[1], DIRECTION_OFFSETS[2], DIRECTION_OFFSETS[3],
		Vector3.new(0, BLOCK_SIZE, 0),
		Vector3.new(0, -BLOCK_SIZE, 0),
	}
	
	for _, offset in ipairs(allOffsets) do
		local adjPos = position + offset
		local existing = ArchitravePlacement.GetArchitraveAtPosition(adjPos, blocksFolder)
		
		if existing then
			local actualPos = existing.position
			
			local newInfo = ArchitravePlacement.GetPlacementInfo(
				"Architrave", actualPos, blocksFolder, DEBUG_ARCHITRAVES
			)
			
			local currentModelName = existing.modelName
			if newInfo.templateName ~= currentModelName then
				if DEBUG_ARCHITRAVES then
					print(string.format("[Architrave] Updating adjacent from %s to %s",
						currentModelName, newInfo.templateName))
				end
				
				local placedBy = existing.instance:GetAttribute("PlacedBy")
				existing.instance:Destroy()
				
				if createArchitraveFunc then
					local newBlock = createArchitraveFunc(
						newInfo.templateName,
						actualPos,
						newInfo.rotation,
						placedBy,
						newInfo.connectionType,
						newInfo.templateName
					)
					if newBlock then
						table.insert(updated, {
							position = actualPos,
							connectionType = newInfo.connectionType,
						})
					end
				end
			end
		end
	end
	
	return updated
end

-- ============================================
-- DEBUG HELPERS
-- ============================================

function ArchitravePlacement.GetDirectionName(dir)
	return DIRECTION_NAMES[dir] or "UNKNOWN"
end

return ArchitravePlacement
