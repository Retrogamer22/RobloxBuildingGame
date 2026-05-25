--[[
	FencePlacement
	Minecraft-style fence placement with auto-connecting
	Fences connect horizontally to adjacent fences
	
	Connection Types:
	- post: No neighbors (uses FenceEnd with no rotation)
	- end: 1 neighbor
	- middle: 2 opposite neighbors (straight line)
	- corner: 2 perpendicular neighbors (L-shape)
	- tee: 3 neighbors (T-junction, uses FenceMiddleCorner)
	- cross: 4 neighbors (uses FenceMiddleFour)
	
	Blocked Directions:
	Players can right-click on fences to toggle connections to adjacent solid blocks.
	Blocked directions are stored as a comma-separated string in the "BlockedDirections" attribute.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FencePlacement = {}

-- ============================================
-- CONFIGURATION
-- ============================================

-- Block size constants (should match GridConfig)
local BLOCK_SIZE = 3

-- Debug flag
local DEBUG_FENCES = false

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

-- Get candidate blocks at a position using spatial index (or fall back to full scan)
local function getCandidatesAt(position, blocksFolder)
	local index = getSpatialIndex(blocksFolder)
	if index then
		return index:GetBlocksAt(position)
	end
	return blocksFolder:GetChildren()
end

-- Get candidates at a position checking multiple Y levels (for Y tolerance)
local function getCandidatesNearY(position, blocksFolder)
	local index = getSpatialIndex(blocksFolder)
	if index then
		-- Check position and +/- one Y grid level for Y tolerance
		local results = {}
		for _, block in ipairs(index:GetBlocksAt(position)) do
			table.insert(results, block)
		end
		for _, block in ipairs(index:GetBlocksAt(position + Vector3.new(0, BLOCK_SIZE, 0))) do
			table.insert(results, block)
		end
		for _, block in ipairs(index:GetBlocksAt(position - Vector3.new(0, BLOCK_SIZE, 0))) do
			table.insert(results, block)
		end
		return results
	end
	return blocksFolder:GetChildren()
end

-- Template names for each connection type
FencePlacement.TEMPLATE_NAMES = {
	post = "FencePost",          -- No neighbors - just a post
	["end"] = "FenceEnd",       -- One connection
	middle = "FenceMiddle",     -- Straight line (2 opposite)
	corner = "FenceCorner",     -- L-shape (2 perpendicular)
	tee = "FenceMiddleCorner",  -- T-junction (3 connections)
	cross = "FenceMiddleFour",  -- 4-way intersection
}

-- Frame fence template names (in FrameBlocks folder)
FencePlacement.FRAME_TEMPLATE_NAMES = {
	post = "FencePostFrame",
	["end"] = "FenceEndFrame",
	middle = "FenceMiddleFrame",
	corner = "FenceCornerFrame",      -- NOTE: Must exist in FrameBlocks!
	tee = "FenceMiddleCornerFrame",
	cross = "FenceMiddleFourFrame",
}

-- Check if a block type is a frame fence
function FencePlacement.IsFrameFence(blockType: string?)
	if not blockType then return false end
	return blockType == "FrameFence"
end

-- Check if a block instance is a frame fence
function FencePlacement.IsFrameFenceInstance(block)
	if not block then return false end
	local blockType = block:GetAttribute("BlockType")
	if blockType == "FrameFence" then return true end
	-- Also check IsFrameBlock + IsFence combo
	if block:GetAttribute("IsFrameBlock") and block:GetAttribute("IsFence") then return true end
	return false
end

-- Get the correct template name for a fence (standard or frame)
function FencePlacement.GetTemplateName(connectionType, isFrameFence)
	if isFrameFence then
		local frameName = FencePlacement.FRAME_TEMPLATE_NAMES[connectionType]
		if frameName then
			-- Verify the template exists in FrameBlocks
			local frameFolder = ReplicatedStorage:FindFirstChild("FrameBlocks")
			if frameFolder and frameFolder:FindFirstChild(frameName) then
				return frameName, "FrameBlocks"
			end
			-- Fallback to standard template if frame version doesn't exist
			warn("[FencePlacement] Frame template not found: " .. frameName .. ", falling back to standard")
		end
	end
	return FencePlacement.TEMPLATE_NAMES[connectionType] or "FenceEnd", "BlockTemplates"
end

-- Legacy fence type mappings (kept for backward compatibility)
-- New fences use pattern matching instead
FencePlacement.LEGACY_FENCE_TYPES = {
	["OakFence"] = "OakPlanks",
	["SpruceFence"] = "SprucePlanks",
	["BirchFence"] = "BirchPlanks",
	["StoneFence"] = "Stone",
	["StoneBrickFence"] = "StoneBrick",
}

-- ============================================
-- DIRECTION SYSTEM
-- ============================================

-- Cardinal directions for fence connections
FencePlacement.Direction = {
	NORTH = 0,  -- -Z
	EAST = 1,   -- +X
	SOUTH = 2,  -- +Z
	WEST = 3,   -- -X
}

-- Direction offsets for checking neighbors
local DIRECTION_OFFSETS = {
	[0] = Vector3.new(0, 0, -BLOCK_SIZE),  -- North (-Z)
	[1] = Vector3.new(BLOCK_SIZE, 0, 0),   -- East (+X)
	[2] = Vector3.new(0, 0, BLOCK_SIZE),   -- South (+Z)
	[3] = Vector3.new(-BLOCK_SIZE, 0, 0),  -- West (-X)
}

-- Direction names for debugging
local DIRECTION_NAMES = {
	[0] = "NORTH (-Z)",
	[1] = "EAST (+X)",
	[2] = "SOUTH (+Z)",
	[3] = "WEST (-X)",
}

-- Get opposite direction
local function getOppositeDirection(direction)
	return (direction + 2) % 4
end

-- Check if two directions are opposite (180° apart)
local function areOppositeDirections(dir1, dir2)
	return (dir1 + 2) % 4 == dir2
end

-- ============================================
-- BLOCKED DIRECTIONS SYSTEM
-- ============================================

-- Parse blocked directions from attribute string (e.g. "0,2" -> {[0]=true, [2]=true})
function FencePlacement.ParseBlockedDirections(blockedStr)
	local blocked = {}
	if not blockedStr or blockedStr == "" then
		return blocked
	end
	
	for dirStr in string.gmatch(blockedStr, "(%d)") do
		local dir = tonumber(dirStr)
		if dir and dir >= 0 and dir <= 3 then
			blocked[dir] = true
		end
	end
	
	return blocked
end

-- Convert blocked directions table to string (e.g. {[0]=true, [2]=true} -> "0,2")
function FencePlacement.SerializeBlockedDirections(blocked)
	if not blocked then return "" end
	
	local dirs = {}
	for dir = 0, 3 do
		if blocked[dir] then
			table.insert(dirs, tostring(dir))
		end
	end
	
	return table.concat(dirs, ",")
end

-- Check if a direction is blocked for a fence
function FencePlacement.IsDirectionBlocked(fence, direction)
	if not fence then return false end
	
	local blockedStr = fence:GetAttribute("BlockedDirections")
	local blocked = FencePlacement.ParseBlockedDirections(blockedStr)
	
	return blocked[direction] == true
end

-- Toggle a blocked direction for a fence
-- Returns the new blocked state (true if now blocked, false if now unblocked)
function FencePlacement.ToggleBlockedDirection(fence, direction)
	if not fence then return false end
	
	local blockedStr = fence:GetAttribute("BlockedDirections") or ""
	local blocked = FencePlacement.ParseBlockedDirections(blockedStr)
	
	-- Toggle the direction
	if blocked[direction] then
		blocked[direction] = nil
	else
		blocked[direction] = true
	end
	
	-- Save back to attribute
	local newStr = FencePlacement.SerializeBlockedDirections(blocked)
	fence:SetAttribute("BlockedDirections", newStr)
	
	return blocked[direction] == true
end

-- Get the direction from a fence to a click position
function FencePlacement.GetDirectionFromClickPosition(fencePosition, clickPosition)
	local diff = clickPosition - fencePosition
	
	-- Determine dominant axis
	local absX = math.abs(diff.X)
	local absZ = math.abs(diff.Z)
	
	if absX > absZ then
		-- X is dominant
		if diff.X > 0 then
			return 1 -- EAST (+X)
		else
			return 3 -- WEST (-X)
		end
	else
		-- Z is dominant
		if diff.Z > 0 then
			return 2 -- SOUTH (+Z)
		else
			return 0 -- NORTH (-Z)
		end
	end
end

-- Get all directions that have solid blocks (for toggle feature)
-- Returns array of directions and the solid block info
function FencePlacement.GetAdjacentSolidBlockDirections(fencePosition, blocksFolder)
	local results = {}
	
	for dir = 0, 3 do
		local offset = DIRECTION_OFFSETS[dir]
		local checkPos = fencePosition + offset
		
		-- Pass direction so signs can be checked for back-only connection
		local solidBlock = FencePlacement.GetSolidBlockAtPosition(checkPos, blocksFolder, dir)
		if solidBlock then
			table.insert(results, {
				direction = dir,
				block = solidBlock,
			})
		end
	end
	
	return results
end

-- ============================================
-- FENCE TYPE DETECTION
-- ============================================

-- Check if a block type is a fence
-- Now uses pattern matching so ANY "*Fence" block type works
function FencePlacement.IsFence(blockType: string?)
	if not blockType then return false end
	
	-- Check legacy types for backward compatibility
	if FencePlacement.LEGACY_FENCE_TYPES[blockType] then return true end
	
	-- Pattern match: anything ending with "Fence" is a fence
	if string.match(blockType, "Fence$") then return true end
	
	return false
end

-- Get the base material type for a fence (used for texturing)
-- e.g., "AcaciaFence" -> "AcaciaPlanks", "StoneBrickFence" -> "StoneBrick"
function FencePlacement.GetFenceBaseMaterial(blockType: string?)
	if not blockType then return nil end
	
	-- Check legacy mappings first
	if FencePlacement.LEGACY_FENCE_TYPES[blockType] then
		return FencePlacement.LEGACY_FENCE_TYPES[blockType]
	end
	
	-- Extract base from "*Fence" pattern
	local base = string.match(blockType, "^(.+)Fence$")
	if base then
		-- Most fences are planks-based
		-- Check if it looks like a non-planks material (Stone, Brick, etc.)
		if string.match(base, "Stone") or string.match(base, "Brick") or string.match(base, "Deepslate") then
			return base
		else
			-- Assume planks-based (e.g., "Acacia" -> "AcaciaPlanks")
			return base .. "Planks"
		end
	end
	
	return blockType
end

-- Check if a part/model is a fence block
function FencePlacement.IsFenceBlock(block)
	if not block then return false end
	
	-- Check attribute first
	if block:GetAttribute("IsFence") then return true end
	
	-- Check BlockType attribute
	local blockType = block:GetAttribute("BlockType")
	if blockType and FencePlacement.IsFence(blockType) then return true end
	
	return false
end

-- ============================================
-- SOLID BLOCK DETECTION (for fence connections)
-- ============================================

-- Block types that fences should NOT connect to
FencePlacement.NON_CONNECTABLE_BLOCKS = {
	-- Transparent/partial blocks
	["Glass"] = true,
	-- Decorations (flowers, grass, etc.)
	["Decoration"] = true,
	-- Leaves are partial
	["Leaves"] = true,
	-- Snow blocks and layers
	["Snow"] = true,
	["SnowLayer"] = true,
	["SnowBlock"] = true,
	-- Vines are decorative growth, not a solid neighbor
	["Vine"] = true,
	["VineTrimmed"] = true,
	["VineTrimmedEnd"] = true,
}

-- Check if a block type is a solid, connectable block
function FencePlacement.IsSolidBlock(blockType: string?)
	if not blockType then return false end
	
	-- Fences don't count as solid blocks (handled separately)
	if FencePlacement.IsFence(blockType) then return false end
	
	-- Check explicit non-connectable list
	if FencePlacement.NON_CONNECTABLE_BLOCKS[blockType] then return false end
	
	-- Slabs are partial blocks
	if string.find(blockType, "Slab") then return false end
	
	-- Stairs are partial blocks
	if string.find(blockType, "Stair") then return false end
	
	-- Doors/trapdoors are partial
	if string.find(blockType, "Door") then return false end
	
	-- Buttons and pressure plates are partial
	if string.find(blockType, "Button") then return false end
	if string.find(blockType, "PressurePlate") then return false end
	if string.find(blockType, "Plate") then return false end
	
	-- Saplings are decorations
	if string.find(blockType, "Sapling") then return false end
	
	-- Snow layers are not solid for fence connections (but SnowyGrassBlock etc. ARE solid)
	if blockType == "Snow" or blockType == "SnowBlock" or blockType == "SnowLayer" then return false end
	
	-- Cactus is a special block
	if blockType == "Cactus" then return false end
	
	-- Lamps are partial (smaller than full block)
	if blockType == "Lamp" then return false end
	
	-- Architraves are decorative molding, not solid
	if blockType == "Architrave" then return false end
	
	-- Wiring components
	if string.find(blockType, "Piston") then return false end
	if string.find(blockType, "Gate") then return false end
	if blockType == "Inverter" then return false end
	
	-- Torches, campfires, and lanterns are decorative, not solid
	if string.find(blockType, "Torch") then return false end
	if string.find(blockType, "Campfire") then return false end
	if string.find(blockType, "Lantern") then return false end
	
	-- Signs are not solid (wall signs have special back-only handling in IsSolidBlockInstance)
	if string.find(blockType, "Sign") then return false end
	
	-- Carpets are thin floor coverings, not solid
	if string.find(blockType, "Carpet") then return false end
	
	-- Wallpaper is paper-thin, not solid
	if string.find(blockType, "Wallpaper") then return false end
	
	-- Columns are narrow, fences don't connect to them
	if blockType == "Column" then return false end
	
	-- Beds are low-profile decoration, not solid for fence connections
	if string.match(blockType, "Bed$") then return false end
	
	-- Everything else is considered solid
	return true
end

-- Check if a part/model is a solid block that fences can connect to
function FencePlacement.IsSolidBlockInstance(block)
	if not block then return false end
	
	-- Check IsFence first - fences are handled separately
	if block:GetAttribute("IsFence") then return false end
	
	-- Check IsTorch - torches are decorative, not solid
	if block:GetAttribute("IsTorch") then return false end
	
	-- Check IsCampfire - campfires are decorative, not solid
	if block:GetAttribute("IsCampfire") then return false end
	
	-- Check IsLantern - lanterns are decorative, not solid
	if block:GetAttribute("IsLantern") then return false end
	
	-- Check IsArchitrave - architraves are decorative molding, not solid
	if block:GetAttribute("IsArchitrave") then return false end
	
	-- Check IsDecoration attribute
	if block:GetAttribute("IsDecoration") then return false end
	
	-- Check IsDoor attribute
	if block:GetAttribute("IsDoor") then return false end
	
	-- Check IsGlass attribute
	if block:GetAttribute("IsGlass") then return false end
	
	-- Check IsColumn attribute
	if block:GetAttribute("IsColumn") then return false end
	
	-- Check IsLadder attribute
	if block:GetAttribute("IsLadder") then return false end
	
	-- Check IsCarpet - carpets are thin floor coverings, not solid
	if block:GetAttribute("IsCarpet") then return false end
	
	-- Check IsWallpaperFrame - wallpaper is paper-thin, not solid
	if block:GetAttribute("IsWallpaperFrame") then return false end
	
	-- Check IsBed - beds are low-profile decoration, not solid for fence connections
	if block:GetAttribute("IsBed") then return false end
	
	-- Check IsVine - vines are decorative growth, not solid
	if block:GetAttribute("IsVine") then return false end
	
	-- NOTE: Wall signs ARE considered solid for fence connections, but only from the back
	-- The back-only filtering is handled in GetSolidBlockAtPosition using approachDirection
	-- Standing signs are NOT solid (too thin to connect to)
	if block:GetAttribute("IsWallSign") then return true end
	if block:GetAttribute("IsSignStanding") then return false end
	
	-- Check BlockType attribute
	local blockType = block:GetAttribute("BlockType")
	if blockType then
		return FencePlacement.IsSolidBlock(blockType)
	end
	
	-- If no BlockType, check if it's a BasePart with reasonable size (probably a block)
	if block:IsA("BasePart") then
		local size = block.Size
		-- Full blocks are roughly BLOCK_SIZE in all dimensions
		if size.X >= BLOCK_SIZE * 0.9 and size.Y >= BLOCK_SIZE * 0.9 and size.Z >= BLOCK_SIZE * 0.9 then
			return true
		end
	end
	
	return false
end

-- Get solid block at position in blocks folder
-- Checks for solid blocks that are horizontally adjacent to the fence
-- Uses Y distance check (max 2 studs difference) to distinguish walls from floor blocks
-- approachDirection: optional - the direction the fence is checking (0=North, 1=East, 2=South, 3=West)
--                   Used to determine if we're looking at the back of a sign
function FencePlacement.GetSolidBlockAtPosition(position, blocksFolder, approachDirection)
	if not blocksFolder then return nil end
	
	-- Snap the check position to grid for X/Z comparison
	local checkGridX = math.round(position.X / BLOCK_SIZE) * BLOCK_SIZE
	local checkGridZ = math.round(position.Z / BLOCK_SIZE) * BLOCK_SIZE
	local checkRawY = position.Y
	
	-- Max Y difference for a block to count as "adjacent wall" vs "floor below"
	-- Surface grass pivots are ~1.5 studs below fence pivot
	-- Underground dirt pivots are ~3+ studs below fence pivot
	local MAX_Y_DIFFERENCE = 2.5
	
	if DEBUG_FENCES then
		print(string.format("[Fence] GetSolidBlockAtPosition: checking grid X=%.1f, Z=%.1f, rawY=%.1f (maxYDiff=%.1f)",
			checkGridX, checkGridZ, checkRawY, MAX_Y_DIFFERENCE))
	end
	
	-- Direction name to index mapping for sign checks
	local SIGN_FACE_TO_DIR = {
		["North"] = 0,
		["East"] = 1,
		["South"] = 2,
		["West"] = 3,
	}
	
	-- Use spatial index for O(1) lookup - check target position + adjacent Y levels
	local index = getSpatialIndex(blocksFolder)
	local candidates = {}
	if index then
		-- Check at target Y and ±1 grid level (for Y tolerance)
		for _, yOff in ipairs({0, -BLOCK_SIZE, BLOCK_SIZE}) do
			local checkPos = Vector3.new(checkGridX, checkRawY + yOff, checkGridZ)
			for _, b in ipairs(index:GetBlocksAt(checkPos)) do
				table.insert(candidates, b)
			end
		end
	else
		-- Fallback: scan all blocks
		candidates = blocksFolder:GetChildren()
	end
	
	for _, block in ipairs(candidates) do
		if FencePlacement.IsSolidBlockInstance(block) then
			-- Get block position (handle both Models and BaseParts)
			-- For wall signs, use grid position from host block since they're offset from grid center
			local blockPos
			local isWallSign = block:GetAttribute("IsWallSign")
			
			if isWallSign then
				-- Wall signs are ON the surface of their host block, not in an adjacent cell
				-- Use the HOST's grid position as the sign's effective position
				local hostX = block:GetAttribute("HostBlockX")
				local hostY = block:GetAttribute("HostBlockY")
				local hostZ = block:GetAttribute("HostBlockZ")
				local signFace = block:GetAttribute("SignFace") or "North"
				
				if hostX and hostY and hostZ then
					-- Snap host to grid (in case slightly off)
					local hostGridX = math.round(hostX / BLOCK_SIZE) * BLOCK_SIZE
					local hostGridZ = math.round(hostZ / BLOCK_SIZE) * BLOCK_SIZE
					-- Use host position directly - sign is on host's surface
					blockPos = Vector3.new(hostGridX, hostY, hostGridZ)
					if DEBUG_FENCES then
						print(string.format("[Fence] Wall sign at host grid pos: (%.1f,%.1f,%.1f), face=%s",
							hostGridX, hostY, hostGridZ, signFace))
					end
				else
					-- Fallback: use pivot but snap to grid
					local pivot = block:GetPivot().Position
					blockPos = Vector3.new(
						math.round(pivot.X / BLOCK_SIZE) * BLOCK_SIZE,
						pivot.Y,
						math.round(pivot.Z / BLOCK_SIZE) * BLOCK_SIZE
					)
					if DEBUG_FENCES then
						print(string.format("[Fence] Wall sign fallback grid position: pivot(%.1f,%.1f,%.1f) -> grid(%.1f,%.1f,%.1f)",
							pivot.X, pivot.Y, pivot.Z, blockPos.X, blockPos.Y, blockPos.Z))
					end
				end
			else
				-- Normal block position handling
				-- Prefer stored grid position attributes (most accurate, avoids PivotOffset issues)
				local bpX = block:GetAttribute("BlockPosX")
				local bpY = block:GetAttribute("BlockPosY")
				local bpZ = block:GetAttribute("BlockPosZ")
				if bpX and bpY and bpZ then
					blockPos = Vector3.new(bpX, bpY, bpZ)
				elseif block:IsA("Model") then
					blockPos = block:GetPivot().Position
				elseif block:IsA("BasePart") then
					blockPos = block.Position
				end
			end
			
			if blockPos then
				-- Snap block position to grid for X/Z
				local blockGridX = math.round(blockPos.X / BLOCK_SIZE) * BLOCK_SIZE
				local blockGridZ = math.round(blockPos.Z / BLOCK_SIZE) * BLOCK_SIZE
				
				-- Check X/Z grid match
				local xMatch = blockGridX == checkGridX
				local zMatch = blockGridZ == checkGridZ
				
				-- Check Y distance (not grid level) - allows walls but rejects floor blocks
				local yDifference = math.abs(blockPos.Y - checkRawY)
				local yClose = yDifference <= MAX_Y_DIFFERENCE
				
				if xMatch and zMatch and yClose then
					-- Special handling for wall signs: only connect from the back
					local isStandingSign = block:GetAttribute("IsSignStanding")
					
					if isWallSign and approachDirection ~= nil then
						-- For wall signs, only allow connection if fence is on the same side as the sign
						-- SignFace tells us which face of the host the sign is attached to
						-- The fence must be approaching from that direction to connect
						local signFace = block:GetAttribute("SignFace") or "North"
						local signFaceDir = SIGN_FACE_TO_DIR[signFace] or 0
						
						-- Fence is approaching from 'approachDirection', which means the fence
						-- is on the opposite side
						-- If fence checks North (0), fence is to the South (2) of the check position
						local fenceIsAtSide = (approachDirection + 2) % 4
						
						if DEBUG_FENCES then
							print(string.format("[Fence] Wall sign check: signFace=%s (dir=%d), approachDir=%d, fenceIsAtSide=%d",
								signFace, signFaceDir, approachDirection, fenceIsAtSide))
						end
						
						-- Fence connects if it's on the same side as the sign (signFaceDir)
						if fenceIsAtSide ~= signFaceDir then
							if DEBUG_FENCES then
								print(string.format("[Fence] REJECTED wall sign %s - fence at %s side, sign is on %s side",
									block:GetAttribute("BlockType") or block.Name,
									DIRECTION_NAMES[fenceIsAtSide] or "?",
									DIRECTION_NAMES[signFaceDir] or "?"))
							end
							continue -- Skip this sign, fence is on wrong side
						end
						
						if DEBUG_FENCES then
							print(string.format("[Fence] ACCEPTED wall sign %s - fence is on same side as sign",
								block:GetAttribute("BlockType") or block.Name))
						end
					end
					
					if DEBUG_FENCES then
						print(string.format("[Fence] FOUND solid block %s at grid (%.1f, %.1f), rawY=%.1f (yDiff=%.1f)",
							block:GetAttribute("BlockType") or block.Name, blockGridX, blockGridZ, blockPos.Y, yDifference))
					end
					return {
						instance = block,
						blockType = block:GetAttribute("BlockType") or "Unknown",
						position = blockPos,
					}
				elseif xMatch and zMatch and DEBUG_FENCES then
					print(string.format("[Fence] REJECTED solid block %s - too far in Y (yDiff=%.1f > %.1f)",
						block:GetAttribute("BlockType") or block.Name, yDifference, MAX_Y_DIFFERENCE))
				end
			end
		end
	end
	
	if DEBUG_FENCES then
		print(string.format("[Fence] NO solid block found at grid X=%.1f, Z=%.1f near Y=%.1f",
			checkGridX, checkGridZ, checkRawY))
	end
	
	return nil
end

-- Get fence at position in blocks folder
function FencePlacement.GetFenceAtPosition(position, blocksFolder)
	if not blocksFolder then return nil end
	
	-- Use spatial index for O(1) lookup
	local index = getSpatialIndex(blocksFolder)
	if index then
		local candidates = index:GetBlocksAt(position)
		for _, block in ipairs(candidates) do
			if FencePlacement.IsFenceBlock(block) then
				local blockPos = block:GetPivot().Position
				if blockPos then
					local diff = position - blockPos
					if math.abs(diff.X) < 1.5 and math.abs(diff.Y) < 1.5 and math.abs(diff.Z) < 1.5 then
						return {
							instance = block,
							fenceType = block:GetAttribute("BlockType"),
							connectionType = block:GetAttribute("FenceConnectionType") or "post",
							position = blockPos,
							blockedDirections = FencePlacement.ParseBlockedDirections(block:GetAttribute("BlockedDirections")),
						}
					end
				end
			end
		end
		return nil
	end
	
	-- Fallback: scan all blocks (shouldn't happen if spatial index is available)
	for _, block in ipairs(blocksFolder:GetChildren()) do
		if FencePlacement.IsFenceBlock(block) then
			local blockPos = block:GetPivot().Position
			if blockPos then
				local diff = position - blockPos
				if math.abs(diff.X) < 1.5 and math.abs(diff.Y) < 1.5 and math.abs(diff.Z) < 1.5 then
					return {
						instance = block,
						fenceType = block:GetAttribute("BlockType"),
						connectionType = block:GetAttribute("FenceConnectionType") or "post",
						position = blockPos,
						blockedDirections = FencePlacement.ParseBlockedDirections(block:GetAttribute("BlockedDirections")),
					}
				end
			end
		end
	end
	return nil
end

-- Check for fence neighbors in all 4 directions
-- checkSolidBlocks: if true, also checks for solid blocks (only use on actual placement, not preview)
-- fenceInstance: optional - the fence we're checking neighbors for (to respect blocked directions)
function FencePlacement.GetFenceNeighbors(position, blocksFolder, checkSolidBlocks, fenceInstance)
	if DEBUG_FENCES then
		print(string.format("[Fence] GetFenceNeighbors at position (%.1f, %.1f, %.1f), checkSolidBlocks=%s",
			position.X, position.Y, position.Z, tostring(checkSolidBlocks)))
	end
	
	local neighbors = {
		[0] = false,  -- North
		[1] = false,  -- East
		[2] = false,  -- South
		[3] = false,  -- West
	}
	
	-- Get blocked directions if we have a fence instance
	local blockedDirs = {}
	if fenceInstance then
		blockedDirs = FencePlacement.ParseBlockedDirections(fenceInstance:GetAttribute("BlockedDirections"))
	end
	
	for dir = 0, 3 do
		local offset = DIRECTION_OFFSETS[dir]
		local checkPos = position + offset
		
		if DEBUG_FENCES then
			print(string.format("[Fence] Checking %s: offset (%.1f, %.1f, %.1f) -> checkPos (%.1f, %.1f, %.1f)",
				DIRECTION_NAMES[dir], offset.X, offset.Y, offset.Z, checkPos.X, checkPos.Y, checkPos.Z))
		end
		
		-- Always check for fences (fences always connect to other fences)
		local fence = FencePlacement.GetFenceAtPosition(checkPos, blocksFolder)
		if fence then
			neighbors[dir] = true
			if DEBUG_FENCES then
				print(string.format("[Fence] Found fence neighbor at %s position (%.1f, %.1f, %.1f)", 
					DIRECTION_NAMES[dir], checkPos.X, checkPos.Y, checkPos.Z))
			end
		elseif checkSolidBlocks then
			-- Only check solid blocks when explicitly requested (placement, not preview)
			-- AND only if this direction is not blocked
			if not blockedDirs[dir] then
				-- Pass direction so signs can be checked for back-only connection
				local solidBlock = FencePlacement.GetSolidBlockAtPosition(checkPos, blocksFolder, dir)
				if solidBlock then
					neighbors[dir] = true
					if DEBUG_FENCES then
						print(string.format("[Fence] Found solid block (%s) at %s position (%.1f, %.1f, %.1f)", 
							solidBlock.blockType, DIRECTION_NAMES[dir], checkPos.X, checkPos.Y, checkPos.Z))
					end
				end
			elseif DEBUG_FENCES then
				print(string.format("[Fence] Direction %s is BLOCKED by user", DIRECTION_NAMES[dir]))
			end
		end
	end
	
	return neighbors
end

-- ============================================
-- CONNECTION TYPE DETERMINATION
-- ============================================

-- Determine what type of fence piece to use based on neighbors
-- Returns: connectionType, primaryDirection, secondaryDirection
function FencePlacement.DetermineConnectionType(neighbors)
	local neighborCount = 0
	local connectedDirs = {}
	
	for dir = 0, 3 do
		if neighbors[dir] then
			neighborCount = neighborCount + 1
			table.insert(connectedDirs, dir)
		end
	end
	
	if DEBUG_FENCES then
		print(string.format("[Fence] Neighbor count: %d, directions: %s", 
			neighborCount, table.concat(connectedDirs, ", ")))
	end
	
	-- Determine piece type based on neighbor count and positions
	if neighborCount == 0 then
		-- No neighbors = simple post
		return "post", nil, nil
		
	elseif neighborCount == 1 then
		-- One neighbor = end piece facing that direction
		return "end", connectedDirs[1], nil
		
	elseif neighborCount == 2 then
		local dir1, dir2 = connectedDirs[1], connectedDirs[2]
		
		if areOppositeDirections(dir1, dir2) then
			-- Opposite directions = middle piece (straight line)
			local primaryDir = math.min(dir1, dir2)
			return "middle", primaryDir, nil
		else
			-- Perpendicular = corner piece
			return "corner", dir1, dir2
		end
		
	elseif neighborCount == 3 then
		-- Three neighbors = T-junction
		local missingDir = nil
		for dir = 0, 3 do
			if not neighbors[dir] then
				missingDir = dir
				break
			end
		end
		return "tee", getOppositeDirection(missingDir), missingDir
		
	else -- neighborCount == 4
		-- Four neighbors = cross/intersection
		return "cross", 0, nil
	end
end

-- ============================================
-- ROTATION CALCULATION
-- ============================================

--[[
	Rotation depends on connection type and model orientation.
	Models are assumed to have:
	- FenceMiddle: rail runs along X axis (East-West) by default
	- FenceEnd: rail extends toward +X (East) by default
	- FenceCorner: rails point toward +X (East) and +Z (South) by default = SE corner
]]

function FencePlacement.GetFenceRotation(connectionType, primaryDir, secondaryDir)
	if connectionType == "post" then
		-- Posts don't need rotation
		return 0
		
	elseif connectionType == "end" then
		-- End piece extends toward -X by default
		-- Rotate so rail points TOWARD the connected neighbor
		local rotations = {
			[0] = -90,   -- Neighbor North (-Z): point toward -Z
			[1] = 180,   -- Neighbor East (+X): point toward +X
			[2] = 90,    -- Neighbor South (+Z): point toward +Z
			[3] = 0,     -- Neighbor West (-X): point toward -X
		}
		return rotations[primaryDir] or 0
		
	elseif connectionType == "middle" then
		-- Middle piece runs along X axis by default (East-West)
		-- For North-South alignment, rotate 90°
		if primaryDir == 0 or primaryDir == 2 then
			return 90  -- North-South: rotate 90°
		else
			return 0   -- East-West: no rotation (default)
		end
		
	elseif connectionType == "corner" then
		-- Corner piece - determine which corner based on neighbor directions
		-- Default model orientation is NW corner (-X and -Z)
		local dirs = {primaryDir, secondaryDir}
		table.sort(dirs)
		
		local hasNorth = dirs[1] == 0 or dirs[2] == 0
		local hasEast = dirs[1] == 1 or dirs[2] == 1
		local hasSouth = dirs[1] == 2 or dirs[2] == 2
		local hasWest = dirs[1] == 3 or dirs[2] == 3
		
		if hasNorth and hasEast then
			return 180   -- NE corner
		elseif hasEast and hasSouth then
			return 90    -- SE corner
		elseif hasSouth and hasWest then
			return 0     -- SW corner
		else  -- hasWest and hasNorth
			return -90   -- NW corner
		end
		
	elseif connectionType == "tee" then
		-- T-junction: secondaryDir is the missing/open side
		-- Model default: open side faces -Z (North)
		local rotations = {
			[0] = 0,     -- Open North: no rotation
			[1] = -90,   -- Open East: rotate -90°
			[2] = 180,   -- Open South: rotate 180°
			[3] = 90,    -- Open West: rotate 90°
		}
		return rotations[secondaryDir] or 0
		
	elseif connectionType == "cross" then
		-- Cross doesn't need rotation
		return 0
	end
	
	return 0
end

-- ============================================
-- PLACEMENT INFO
-- ============================================

-- Get full placement info for a fence
-- checkSolidBlocks: pass true when actually placing (server), false/nil for preview (client)
-- fenceInstance: optional - pass existing fence to respect its blocked directions
function FencePlacement.GetPlacementInfo(blockType, position, blocksFolder, debugOutput, checkSolidBlocks, fenceInstance)
	-- Detect if this is a frame fence
	local isFrameFence = FencePlacement.IsFrameFence(blockType)
		 or (fenceInstance and FencePlacement.IsFrameFenceInstance(fenceInstance))
	
	local neighbors = FencePlacement.GetFenceNeighbors(position, blocksFolder, checkSolidBlocks, fenceInstance)
	local connectionType, primaryDir, secondaryDir = FencePlacement.DetermineConnectionType(neighbors)
	local rotation = FencePlacement.GetFenceRotation(connectionType, primaryDir, secondaryDir)
	
	-- Frame fence models have different default orientations vs standard fences
	if isFrameFence then
		if connectionType == "corner" then
			rotation = rotation - 90
		end
	end
	
	-- Choose template based on whether this is a frame fence or regular fence
	local templateName, templateFolder
	if isFrameFence then
		templateName, templateFolder = FencePlacement.GetTemplateName(connectionType, true)
	else
		templateName = FencePlacement.TEMPLATE_NAMES[connectionType] or "FenceEnd"
		templateFolder = "BlockTemplates"
	end
	
	if debugOutput or DEBUG_FENCES then
		print(string.format("[Fence] PlacementInfo: type=%s, template=%s, folder=%s, rotation=%d, isFrame=%s", 
			connectionType, templateName, templateFolder, rotation, tostring(isFrameFence)))
	end
	
	return {
		templateName = templateName,
		templateFolder = templateFolder,
		connectionType = connectionType,
		rotation = rotation,
		primaryDirection = primaryDir,
		secondaryDirection = secondaryDir,
		neighbors = neighbors,
		isFrameFence = isFrameFence,
	}
end

-- Get CFrame for fence placement
function FencePlacement.GetFenceCFrame(position, rotation, isFrameFence)
	local rotationOffset = isFrameFence and 90 or 0
	return CFrame.new(position) * CFrame.Angles(0, math.rad(rotation + rotationOffset), 0)
end

-- ============================================
-- NEIGHBOR UPDATES
-- ============================================

-- Update all adjacent fences when a fence is placed or broken
-- Returns list of positions that were updated
function FencePlacement.UpdateAdjacentFences(position, blocksFolder, BlockTemplates, createBlockFunc)
	local updated = {}
	
	for dir = 0, 3 do
		local offset = DIRECTION_OFFSETS[dir]
		local adjPos = position + offset
		local existingFence = FencePlacement.GetFenceAtPosition(adjPos, blocksFolder)
		
		if existingFence then
			-- Use the fence's ACTUAL position, not the calculated adjPos
			-- This prevents position drift when fences are updated
			local fenceActualPos = existingFence.position
			
			-- Recalculate what this fence should be (pass the existing fence to respect blocked directions)
			local newPlacementInfo = FencePlacement.GetPlacementInfo(
				existingFence.fenceType,
				fenceActualPos,
				blocksFolder,
				DEBUG_FENCES,
				true, -- checkSolidBlocks
				existingFence.instance -- pass fence instance for blocked directions
			)
			
			-- Check if connection type changed
			local currentType = existingFence.connectionType
			if newPlacementInfo.connectionType ~= currentType then
				if DEBUG_FENCES then
					print(string.format("[Fence] Updating adjacent from %s to %s at %s",
						currentType, newPlacementInfo.connectionType, DIRECTION_NAMES[dir]))
				end
				
				-- Store info before destroying (including color/material/materialVariant and blocked directions)
				local fenceType = existingFence.fenceType
				local placedBy = existingFence.instance:GetAttribute("PlacedBy")
				local blockedDirs = existingFence.instance:GetAttribute("BlockedDirections")
				local isFilledFence = existingFence.instance:GetAttribute("IsFilledFence")
				local oldColor, oldMaterial, oldMaterialVariant
				if existingFence.instance:IsA("BasePart") then
					oldColor = existingFence.instance.Color
					oldMaterial = existingFence.instance.Material
					oldMaterialVariant = existingFence.instance.MaterialVariant
				end
				
				-- Save fill attributes if this is a filled fence
				local fillAttrs = nil
				if isFilledFence then
					fillAttrs = {
						FrameFillBlockId = existingFence.instance:GetAttribute("FrameFillBlockId"),
						FrameFillColorR = existingFence.instance:GetAttribute("FrameFillColorR"),
						FrameFillColorG = existingFence.instance:GetAttribute("FrameFillColorG"),
						FrameFillColorB = existingFence.instance:GetAttribute("FrameFillColorB"),
						FrameFillMaterialVariant = existingFence.instance:GetAttribute("FrameFillMaterialVariant"),
					}
				end
				
				-- Destroy old fence
				existingFence.instance:Destroy()
				
				-- Create new fence with updated connections at the ACTUAL position
				if createBlockFunc then
					local newFence = createBlockFunc(
						newPlacementInfo.templateName,
						fenceType,
						fenceActualPos,
						newPlacementInfo.rotation,
						placedBy,
						newPlacementInfo.connectionType,
						oldColor,
						oldMaterial,
						oldMaterialVariant
					)
					if newFence then
						-- Restore blocked directions
						if blockedDirs and blockedDirs ~= "" then
							newFence:SetAttribute("BlockedDirections", blockedDirs)
						end
						
						-- Restore filled fence attributes
						if isFilledFence and fillAttrs then
							newFence:SetAttribute("IsFilledFence", true)
							for attrName, attrValue in pairs(fillAttrs) do
								newFence:SetAttribute(attrName, attrValue)
							end
						end
						
						table.insert(updated, {
							position = fenceActualPos,
							connectionType = newPlacementInfo.connectionType,
						})
					end
				end
			end
		end
	end
	
	return updated
end

-- ============================================
-- SOLID BLOCK UPDATES
-- ============================================

-- Called when a solid block is placed or removed near fences
-- Updates any fences adjacent to the given position
-- Also checks one level above since fence pivots are higher than grass block pivots
function FencePlacement.UpdateFencesNearSolidBlock(position, blocksFolder, BlockTemplates, createBlockFunc)
	if DEBUG_FENCES then
		print(string.format("[Fence] UpdateFencesNearSolidBlock called at position (%.1f, %.1f, %.1f)",
			position.X, position.Y, position.Z))
	end
	
	local updated = {}
	
	-- Check all 4 directions for fences, at same level AND one level above
	for dir = 0, 3 do
		local offset = DIRECTION_OFFSETS[dir]
		local adjPos = position + offset
		
		if DEBUG_FENCES then
			print(string.format("[Fence] Checking %s: adjPos (%.1f, %.1f, %.1f)",
				DIRECTION_NAMES[dir], adjPos.X, adjPos.Y, adjPos.Z))
		end
		
		-- Check at same Y level
		local existingFence = FencePlacement.GetFenceAtPosition(adjPos, blocksFolder)
		
		if DEBUG_FENCES and existingFence then
			print(string.format("[Fence] Found fence at same level: %s", existingFence.fenceType))
		end
		
		-- Also check one level above (fence pivots are at Y=0, grass pivots at Y=-3)
		if not existingFence then
			local adjPosAbove = adjPos + Vector3.new(0, BLOCK_SIZE, 0)
			if DEBUG_FENCES then
				print(string.format("[Fence] No fence at same level, checking above: (%.1f, %.1f, %.1f)",
					adjPosAbove.X, adjPosAbove.Y, adjPosAbove.Z))
			end
			existingFence = FencePlacement.GetFenceAtPosition(adjPosAbove, blocksFolder)
			if existingFence and DEBUG_FENCES then
				print(string.format("[Fence] Found fence one level above: %s", existingFence.fenceType))
			end
		end
		
		if existingFence then
			-- Use the fence's ACTUAL position, not the calculated adjPos
			-- This prevents position drift when fences are updated
			local fenceActualPos = existingFence.position
			
			-- Recalculate what this fence should be (pass the existing fence to respect blocked directions)
			local newPlacementInfo = FencePlacement.GetPlacementInfo(
				existingFence.fenceType,
				fenceActualPos,
				blocksFolder,
				DEBUG_FENCES,
				true, -- checkSolidBlocks
				existingFence.instance -- pass fence instance for blocked directions
			)
			
			-- Check if connection type changed
			local currentType = existingFence.connectionType
			if newPlacementInfo.connectionType ~= currentType then
				if DEBUG_FENCES then
					print(string.format("[Fence] Updating fence from %s to %s due to solid block change at %s",
						currentType, newPlacementInfo.connectionType, DIRECTION_NAMES[dir]))
				end
				
				-- Store info before destroying (including color/material/materialVariant and blocked directions)
				local fenceType = existingFence.fenceType
				local placedBy = existingFence.instance:GetAttribute("PlacedBy")
				local blockedDirs = existingFence.instance:GetAttribute("BlockedDirections")
				local isFilledFence = existingFence.instance:GetAttribute("IsFilledFence")
				local oldColor, oldMaterial, oldMaterialVariant
				if existingFence.instance:IsA("BasePart") then
					oldColor = existingFence.instance.Color
					oldMaterial = existingFence.instance.Material
					oldMaterialVariant = existingFence.instance.MaterialVariant
				end
				
				-- Save fill attributes if this is a filled fence
				local fillAttrs = nil
				if isFilledFence then
					fillAttrs = {
						FrameFillBlockId = existingFence.instance:GetAttribute("FrameFillBlockId"),
						FrameFillColorR = existingFence.instance:GetAttribute("FrameFillColorR"),
						FrameFillColorG = existingFence.instance:GetAttribute("FrameFillColorG"),
						FrameFillColorB = existingFence.instance:GetAttribute("FrameFillColorB"),
						FrameFillMaterialVariant = existingFence.instance:GetAttribute("FrameFillMaterialVariant"),
					}
				end
				
				-- Destroy old fence
				existingFence.instance:Destroy()
				
				-- Create new fence with updated connections at the ACTUAL position
				if createBlockFunc then
					local newFence = createBlockFunc(
						newPlacementInfo.templateName,
						fenceType,
						fenceActualPos,
						newPlacementInfo.rotation,
						placedBy,
						newPlacementInfo.connectionType,
						oldColor,
						oldMaterial,
						oldMaterialVariant
					)
					if newFence then
						-- Restore blocked directions
						if blockedDirs and blockedDirs ~= "" then
							newFence:SetAttribute("BlockedDirections", blockedDirs)
						end
						
						-- Restore filled fence attributes
						if isFilledFence and fillAttrs then
							newFence:SetAttribute("IsFilledFence", true)
							for attrName, attrValue in pairs(fillAttrs) do
								newFence:SetAttribute(attrName, attrValue)
							end
						end
						
						table.insert(updated, {
							position = fenceActualPos,
							connectionType = newPlacementInfo.connectionType,
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

function FencePlacement.GetDirectionName(dir)
	return DIRECTION_NAMES[dir] or "UNKNOWN"
end

function FencePlacement.GetConnectionTypeName(connectionType)
	return connectionType or "unknown"
end

return FencePlacement
