--[[
	StairPlacement
	Minecraft-style stair placement with auto-corners
	Based on Ashborne's working implementation
	
	DIRECTION: Based on camera look vector (stair faces same direction you're looking)
	UPSIDE-DOWN: Based on where you click on the block (bottom face or upper half of side = upside down)
	CORNERS: Auto-detect based on adjacent perpendicular stairs using turn direction
	
	At rotation 0°, the stair's open/stepped side faces WEST (-X)
	The stair "goes up" toward EAST (+X)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StairPlacement = {}

-- Spatial index for O(1) lookups
local BlockSpatialIndex = nil
local function getSpatialIndex(blocksFolder)
	if not BlockSpatialIndex then
		local mod = ReplicatedStorage:FindFirstChild("BlockSpatialIndex")
		if mod then BlockSpatialIndex = require(mod) end
	end
	if BlockSpatialIndex then return BlockSpatialIndex.GetOrCreate(blocksFolder) end
	return nil
end

-- ============================================
-- CONFIGURATION
-- ============================================

-- Block dimensions (must match GridConfig)
local BLOCK_SIZE = 3
local BLOCK_HEIGHT = 3  -- Using 3 for this game

-- Template names (from BlockTemplates folder)
StairPlacement.TEMPLATE_NAMES = {
	Normal = "Stair",
	Inner = "StairInnerCorner",
	Outer = "StairOuterCorner",
}

-- Arch template names (arches use same placement logic as stairs)
StairPlacement.ARCH_TEMPLATE_NAMES = {
	Normal = "Arch",
	Inner = "ArchInner",
	Outer = "ArchOuter",
}

StairPlacement.ARCH_LARGE_TEMPLATE_NAMES = {
	Normal = "ArchLarge",
	Inner = "ArchLargeInner",
	Outer = "ArchLargeOuter",
}

-- Map stair block IDs to their base type (for color/material inheritance)
StairPlacement.STAIR_BASE_TYPES = {
	["OakPlanksStair"] = "OakPlanks",
	["SprucePlanksStair"] = "SprucePlanks",
	["StoneStair"] = "Stone",
	["StoneBrickStair"] = "StoneBrick",
	["DirtStair"] = "Dirt",
	["LimestoneStair"] = "Limestone",
	["SandstoneStair"] = "Sandstone",
}

-- ============================================
-- DIRECTION SYSTEM
-- ============================================

-- Direction enum (compass directions the stair FACES - where the open/stepped side points)
-- This is the direction you WALK FROM when going up the stairs
StairPlacement.Direction = {
	NORTH = 0,   -- Open side faces +Z, goes up toward -Z
	EAST = 1,    -- Open side faces +X, goes up toward -X
	SOUTH = 2,   -- Open side faces -Z, goes up toward +Z
	WEST = 3,    -- Open side faces -X, goes up toward +X
}

-- Direction offsets (unit vectors for each direction)
local DIRECTION_OFFSETS = {
	[0] = Vector3.new(0, 0, 1),   -- NORTH: +Z
	[1] = Vector3.new(1, 0, 0),   -- EAST: +X
	[2] = Vector3.new(0, 0, -1),  -- SOUTH: -Z
	[3] = Vector3.new(-1, 0, 0),  -- WEST: -X
}

-- Direction names for debugging
local DIRECTION_NAMES = {
	[0] = "NORTH (+Z)",
	[1] = "EAST (+X)",
	[2] = "SOUTH (-Z)",
	[3] = "WEST (-X)",
}

-- ============================================
-- CORNER ROTATION LOOKUP TABLE
-- ============================================

--[[
	Corner rotation depends on which two directions are being connected.
	Key format: "existingDir_newDir" where dirs are 0-3 (NORTH/EAST/SOUTH/WEST)
	
	OUTER corners (right turn from existing to new):
	- NORTH(0) → EAST(1)
	- EAST(1) → SOUTH(2)
	- SOUTH(2) → WEST(3)
	- WEST(3) → NORTH(0)
	
	INNER corners (left turn from existing to new):
	- NORTH(0) → WEST(3)
	- EAST(1) → NORTH(0)
	- SOUTH(2) → EAST(1)
	- WEST(3) → SOUTH(2)
	
	The rotation value is the Y-axis rotation in degrees that makes
	the corner model connect the two stair paths visually.
]]

-- Outer corner rotations: key = existingDir * 10 + newDir
-- Includes BOTH clockwise and counterclockwise turns for square corners
local OUTER_CORNER_ROTATIONS = {
	-- Clockwise turns:
	[1] = 180,   -- NORTH(0) → EAST(1) - fixed rotation v2
	[12] = 270,  -- EAST(1) → SOUTH(2)
	[23] = 0,    -- SOUTH(2) → WEST(3)
	[30] = 90,   -- WEST(3) → NORTH(0)
	-- Counterclockwise turns (rotated 90° from inner):
	[3] = 90,    -- NORTH(0) → WEST(3) - fixed
	[10] = 180,  -- EAST(1) → NORTH(0) - fixed rotation
	[21] = 270,  -- SOUTH(2) → EAST(1) - fixed rotation
	[32] = 0,    -- WEST(3) → SOUTH(2)
}

-- Inner corner rotations: key = existingDir * 10 + newDir
local INNER_CORNER_ROTATIONS = {
	-- Counterclockwise turns:
	[3] = 270,   -- NORTH(0) → WEST(3) - fixed
	[10] = 0,    -- EAST(1) → NORTH(0) - fixed rotation
	[21] = 90,   -- SOUTH(2) → EAST(1) - fixed rotation
	[32] = 180,  -- WEST(3) → SOUTH(2) - fixed rotation
	-- Clockwise turns (for BACK check with swapped logic):
	[1] = 0,     -- NORTH(0) → EAST(1) - fixed rotation v2
	[12] = 90,   -- EAST(1) → SOUTH(2) - fixed rotation v2
	[23] = 180,  -- SOUTH(2) → WEST(3) - fixed
	[30] = 270,  -- WEST(3) → NORTH(0) - fixed rotation v2
}

-- Get the correct rotation for a corner piece
-- existingDir: direction the existing stair was facing
-- newDir: direction the new stair is facing
-- cornerType: "inner" or "outer"
-- upsideDown: whether the stair is upside-down (needs 90° adjustment)
function StairPlacement.GetCornerRotation(existingDir, newDir, cornerType, upsideDown)
	local key = existingDir * 10 + newDir
	
	local rotation
	if cornerType == "outer" then
		rotation = OUTER_CORNER_ROTATIONS[key]
	else
		rotation = INNER_CORNER_ROTATIONS[key]
	end
	
	if rotation == nil then
		-- Fallback: use existing direction's rotation
		warn(string.format("[StairPlacement] Unknown corner config: existing=%d, new=%d, type=%s", 
			existingDir, newDir, cornerType))
		rotation = StairPlacement.DirectionToRotation(existingDir)
	end
	
	-- Upside-down corners need -90° adjustment due to the X-axis flip
	if upsideDown then
		rotation = (rotation - 90) % 360
	end
	
	return rotation
end

-- ============================================
-- ROTATION MAPPING
-- ============================================

-- Convert direction to Y-axis rotation in degrees
-- IMPORTANT: These values depend on how the stair model is oriented at 0°
-- At 0° rotation, stair faces WEST (-X) based on your model orientation
function StairPlacement.DirectionToRotation(direction)
	local rotations = {
		[0] = 90,    -- NORTH (+Z): 90° from base
		[1] = 180,   -- EAST (+X): 180° from base
		[2] = 270,   -- SOUTH (-Z): 270° from base (or -90°)
		[3] = 0,     -- WEST (-X): base orientation
	}
	return rotations[direction] or 0
end

-- Convert Y-axis rotation in degrees to direction
function StairPlacement.RotationToDirection(rotation)
	-- Normalize to 0-359 range
	local normalizedRotation = rotation % 360
	if normalizedRotation < 0 then 
		normalizedRotation = normalizedRotation + 360 
	end
	
	-- Map rotation ranges to directions
	if normalizedRotation >= 315 or normalizedRotation < 45 then
		return StairPlacement.Direction.WEST      -- 0° ± 45°
	elseif normalizedRotation >= 45 and normalizedRotation < 135 then
		return StairPlacement.Direction.NORTH     -- 90° ± 45°
	elseif normalizedRotation >= 135 and normalizedRotation < 225 then
		return StairPlacement.Direction.EAST      -- 180° ± 45°
	else
		return StairPlacement.Direction.SOUTH     -- 270° ± 45°
	end
end

-- Get rotation CFrame for a direction
function StairPlacement.GetRotationCFrame(direction)
	local degrees = StairPlacement.DirectionToRotation(direction)
	return CFrame.Angles(0, math.rad(degrees), 0)
end

-- ============================================
-- DIRECTION HELPERS
-- ============================================

function StairPlacement.GetDirectionOffset(direction)
	return DIRECTION_OFFSETS[direction] or Vector3.new(0, 0, 0)
end

function StairPlacement.GetOppositeDirection(direction)
	return (direction + 2) % 4
end

function StairPlacement.GetLeftDirection(direction)
	return (direction + 3) % 4  -- -1 mod 4
end

function StairPlacement.GetRightDirection(direction)
	return (direction + 1) % 4
end

function StairPlacement.GetDirectionName(direction)
	return DIRECTION_NAMES[direction] or "UNKNOWN"
end

-- Get turn direction from one facing to another
-- Returns: "left" (CCW), "right" (CW), or "none" (same or opposite)
function StairPlacement.GetTurnDirection(fromDir, toDir)
	local diff = (toDir - fromDir + 4) % 4
	if diff == 1 then 
		return "right"  -- Clockwise turn
	elseif diff == 3 then 
		return "left"   -- Counter-clockwise turn
	else 
		return "none"   -- Same direction or 180°
	end
end

-- ============================================
-- LOOK VECTOR TO DIRECTION
-- ============================================

-- Convert player's camera look vector to stair facing direction
-- Stair faces the same direction you're looking
function StairPlacement.GetDirectionFromLookVector(lookVector)
	local absX = math.abs(lookVector.X)
	local absZ = math.abs(lookVector.Z)
	
	if absX > absZ then
		-- Looking mostly along X axis
		if lookVector.X > 0 then
			return StairPlacement.Direction.EAST   -- Looking +X, stair faces +X
		else
			return StairPlacement.Direction.WEST   -- Looking -X, stair faces -X
		end
	else
		-- Looking mostly along Z axis
		if lookVector.Z > 0 then
			return StairPlacement.Direction.NORTH  -- Looking +Z, stair faces +Z
		else
			return StairPlacement.Direction.SOUTH  -- Looking -Z, stair faces -Z
		end
	end
end

-- ============================================
-- UPSIDE-DOWN DETECTION
-- ============================================

-- Determine if stair should be placed upside-down
function StairPlacement.ShouldBeUpsideDown(hitPosition, hitNormal, blockPosition)
	if not hitPosition or not hitNormal then
		return false
	end
	
	-- Placing on bottom face of a block = upside down
	if hitNormal.Y < -0.5 then
		return true
	end
	
	-- Placing on top face of a block = right-side up
	if hitNormal.Y > 0.5 then
		return false
	end
	
	-- Side face: check if hit upper or lower half
	local relativeY = hitPosition.Y - blockPosition.Y
	return relativeY > 0
end

-- ============================================
-- STAIR DETECTION
-- ============================================

-- Check if a block type is a stair
function StairPlacement.IsStairType(blockType)
	if not blockType then return false end
	
	-- Check explicit mapping
	if StairPlacement.STAIR_BASE_TYPES[blockType] then 
		return true 
	end
	
	-- Check name pattern
	return string.find(blockType, "Stair") ~= nil
end

-- Check if a block type is any arch (arches use stair placement logic)
function StairPlacement.IsArchType(blockType)
	if not blockType then return false end
	return StairPlacement.IsArchSmallType(blockType) or StairPlacement.IsArchLargeType(blockType)
end

-- Small arch only (corners only with other small arches)
function StairPlacement.IsArchSmallType(blockType)
	if not blockType then return false end
	return blockType == "Arch" or blockType == "ArchFrame"
		or blockType == "ArchInner" or blockType == "ArchOuter"
		or blockType == "ArchInnerFrame" or blockType == "ArchOuterFrame"
end

-- Large arch only (corners only with other large arches)
function StairPlacement.IsArchLargeType(blockType)
	if not blockType then return false end
	return blockType == "ArchLarge" or blockType == "ArchLargeFrame"
		or blockType == "ArchLargeInner" or blockType == "ArchLargeOuter"
		or blockType == "ArchLargeInnerFrame" or blockType == "ArchLargeOuterFrame"
end

-- Get the right type checker for a specific arch block (so arches only corner with same size)
function StairPlacement.GetArchTypeChecker(blockType)
	if StairPlacement.IsArchLargeType(blockType) then
		return StairPlacement.IsArchLargeType
	end
	return StairPlacement.IsArchSmallType
end

-- Get the right template names for a specific arch block
function StairPlacement.GetArchTemplateNames(blockType)
	if StairPlacement.IsArchLargeType(blockType) then
		return StairPlacement.ARCH_LARGE_TEMPLATE_NAMES
	end
	return StairPlacement.ARCH_TEMPLATE_NAMES
end

-- Check if a block type uses stair-style placement (stairs OR arches)
function StairPlacement.IsStairOrArchType(blockType)
	return StairPlacement.IsStairType(blockType) or StairPlacement.IsArchType(blockType)
end

-- Debug flag for stair detection (set to false to reduce spam)
local DEBUG_STAIR_DETECTION = false

-- Find a stair at a specific position
-- typeChecker: optional function to filter block types (default: IsStairType)
function StairPlacement.GetStairAt(position, blocksFolder, typeChecker)
	typeChecker = typeChecker or StairPlacement.IsStairType
	if not blocksFolder then 
		if DEBUG_STAIR_DETECTION then print("[GetStairAt] No blocksFolder!") end
		return nil 
	end
	
	-- Use spatial index for O(1) lookup, fall back to full scan
	local index = getSpatialIndex(blocksFolder)
	local candidates = index and index:GetBlocksAt(position) or blocksFolder:GetChildren()
	
	for _, block in ipairs(candidates) do
		local blockPos
		
		if block:IsA("BasePart") then
			blockPos = block.Position
		elseif block:IsA("Model") then
			-- Try PrimaryPart first, then look for any BasePart
			local primaryPart = block.PrimaryPart
			if not primaryPart then
				-- For stair models, the union is usually the main part
				primaryPart = block:FindFirstChildWhichIsA("UnionOperation") or block:FindFirstChildWhichIsA("BasePart")
			end
			if primaryPart then
				blockPos = primaryPart.Position
			end
		end
		
		if blockPos then
			local distance = (blockPos - position).Magnitude
			
			-- Use larger tolerance for finding stairs
			if distance < BLOCK_SIZE * 0.8 then
				local blockType = block:GetAttribute("BlockType")
				
				if typeChecker(blockType) then
					if DEBUG_STAIR_DETECTION then
						print(string.format("[GetStairAt] FOUND stair at dist %.2f: %s", distance, blockType))
					end
					
					-- Get direction (prefer stored attribute, fallback to rotation)
					local direction = block:GetAttribute("StairDirection")
					if direction == nil then
						local rotation = block:GetAttribute("Rotation") or 0
						direction = StairPlacement.RotationToDirection(rotation)
					end
					
					local upsideDown = block:GetAttribute("IsUpsideDown") or false
					
					return {
						direction = direction,
						upsideDown = upsideDown,
						blockType = blockType,
						object = block,
						cornerType = block:GetAttribute("CornerType") or "normal",
					}
				end
			end
		end
	end
	
	return nil
end

-- Get stair at adjacent position
function StairPlacement.GetAdjacentStair(position, direction, blocksFolder, typeChecker)
	local offset = StairPlacement.GetDirectionOffset(direction) * BLOCK_SIZE
	local adjacentPos = position + offset
	return StairPlacement.GetStairAt(adjacentPos, blocksFolder, typeChecker)
end

-- ============================================
-- CORNER DETECTION (Minecraft-style)
-- ============================================
-- Updated: BACK check turn RIGHT = INNER, turn LEFT = OUTER

--[[
	Minecraft corner detection logic:
	
	INNER CORNER: When you place a stair and there's a perpendicular stair 
	              BEHIND it (where the stair goes up toward), and the back stair
	              would turn LEFT to connect to the new stair.
	
	OUTER CORNER: When you place a stair and there's a perpendicular stair
	              BEHIND it, and the back stair would turn RIGHT to connect.
	
	The key insight is checking the stair in the "back" direction (opposite of facing)
	and using the turn direction to determine inner vs outer.
]]

function StairPlacement.DetermineCornerType(position, direction, upsideDown, blocksFolder, debugMode, typeChecker)
	-- Only debug when explicitly requested (e.g., from server on actual placement)
	
	if debugMode then
		print(string.format("[DetermineCornerType] Checking pos (%.1f, %.1f, %.1f) dir %s", 
			position.X, position.Y, position.Z, StairPlacement.GetDirectionName(direction)))
		
		-- List all existing stairs
		if blocksFolder then
			local stairCount = 0
			for _, block in ipairs(blocksFolder:GetChildren()) do
				local blockType = block:GetAttribute("BlockType")
				if blockType and StairPlacement.IsStairType(blockType) then
					local blockPos
					if block:IsA("BasePart") then
						blockPos = block.Position
					elseif block:IsA("Model") then
						local pp = block.PrimaryPart or block:FindFirstChildWhichIsA("UnionOperation") or block:FindFirstChildWhichIsA("BasePart")
						if pp then blockPos = pp.Position end
					end
					if blockPos then
						stairCount = stairCount + 1
						print(string.format("  [Existing stair %d] %s at (%.1f, %.1f, %.1f) dir=%s", 
							stairCount, blockType, blockPos.X, blockPos.Y, blockPos.Z,
							StairPlacement.GetDirectionName(block:GetAttribute("StairDirection") or 0)))
					end
				end
			end
			if stairCount == 0 then
				print("  [No existing stairs found]")
			end
		end
	end
	
	-- Direction helpers
	local backDir = StairPlacement.GetOppositeDirection(direction)  -- Where stair goes UP toward
	local frontDir = direction  -- Where stair FACES (open side)
	local leftDir = StairPlacement.GetLeftDirection(direction)
	local rightDir = StairPlacement.GetRightDirection(direction)
	
	-- Check stair BEHIND us (where our stair ascends toward) - INNER CORNER
	-- This is when WE should become a corner (existing stair is behind us)
	local backStair = StairPlacement.GetAdjacentStair(position, backDir, blocksFolder, typeChecker)
	
	if backStair and backStair.upsideDown == upsideDown then
		local backStairDir = backStair.direction
		local dirDiff = math.abs(direction - backStairDir)
		local isPerpendicular = (dirDiff == 1) or (dirDiff == 3)
		
		if isPerpendicular then
			local turnDirection = StairPlacement.GetTurnDirection(direction, backStairDir)
			
			if debugMode then
				print(string.format("[Corner] BACK stair found: %s, turn=%s", 
					StairPlacement.GetDirectionName(backStairDir), turnDirection))
			end
			
			-- BACK check: perpendicular stair behind = ALWAYS INNER
			-- (You're filling the inside of an L-shape)
			-- Key format is existingDir * 10 + newDir, so pass (backStairDir, direction)
			local cornerRotation = StairPlacement.GetCornerRotation(backStairDir, direction, "inner", upsideDown)
			return "inner", direction, cornerRotation
		end
	end
	
	-- NOTE: Check FRONT for L-shape corners
	-- If perpendicular stair in front AND same-direction stair on left/right, we complete an L
	-- SKIP if front stair is already a corner (corners don't influence other corners via FRONT check)
	local frontStair = StairPlacement.GetAdjacentStair(position, frontDir, blocksFolder, typeChecker)
	
	if frontStair and frontStair.upsideDown == upsideDown and frontStair.cornerType == "normal" then
		local frontStairDir = frontStair.direction
		local dirDiff = math.abs(direction - frontStairDir)
		local isPerpendicular = (dirDiff == 1) or (dirDiff == 3)
		
		if isPerpendicular then
			-- Check if we form an L-connection:
			-- Our LEFT or RIGHT direction should match front stair's BACK direction
			local frontStairBackDir = StairPlacement.GetOppositeDirection(frontStairDir)
			local connectsOnLeft = (leftDir == frontStairBackDir)
			local connectsOnRight = (rightDir == frontStairBackDir)
			
			if debugMode then
				print(string.format("[Corner] FRONT perp stair: %s, frontBack=%s, connectsLeft=%s, connectsRight=%s",
					StairPlacement.GetDirectionName(frontStairDir),
					StairPlacement.GetDirectionName(frontStairBackDir),
					tostring(connectsOnLeft),
					tostring(connectsOnRight)))
			end
			
			if connectsOnLeft or connectsOnRight then
				-- Check if there's a same-direction stair BEHIND us
				-- If yes, we're extending a straight run, not making a corner
				-- (A same-dir stair to the SIDE is a parallel line, doesn't block corners)
				local backStairSameCheck = StairPlacement.GetAdjacentStair(position, backDir, blocksFolder, typeChecker)
				local hasSameDirBehind = backStairSameCheck and backStairSameCheck.direction == direction and backStairSameCheck.upsideDown == upsideDown
				
				if debugMode then
					print(string.format("[Corner] Checking BACK (%s) for same-dir: hasSameDirBehind=%s",
						StairPlacement.GetDirectionName(backDir),
						tostring(hasSameDirBehind)))
				end
				
				if not hasSameDirBehind then
					-- No same-dir stair behind, so we ARE making a corner
					-- FRONT check = completing a square corner = always OUTER (convex)
					-- (INNER corners only come from the BACK check when filling in an L)
					local cornerType = "outer"
					
					-- For FRONT check, path goes frontStairDir → direction
					local cornerRotation = StairPlacement.GetCornerRotation(frontStairDir, direction, cornerType, upsideDown)
					return cornerType, direction, cornerRotation
				end
			end
		end
	end
	
	-- Check LEFT and RIGHT - REMOVED: These were incorrectly triggering.
	-- The LEFT/RIGHT case is handled by ShouldExistingStairBecomeCorner instead.
	
	if debugMode then
		print("[DetermineCornerType] No corner condition met, returning NORMAL")
	end
	
	return "normal", direction, nil
end

-- ============================================
-- MAIN PLACEMENT FUNCTIONS
-- ============================================

-- Get placement info using camera look vector (primary method)
function StairPlacement.GetPlacementInfoFromLookVector(stairType, position, lookVector, upsideDown, blocksFolder, debugMode, typeChecker, templateNames)
	local direction = StairPlacement.GetDirectionFromLookVector(lookVector)
	
	local cornerType, finalDirection, cornerRotation = StairPlacement.DetermineCornerType(
		position, direction, upsideDown, blocksFolder, debugMode, typeChecker
	)
	
	-- Select template based on corner type
	templateNames = templateNames or StairPlacement.TEMPLATE_NAMES
	local templateName
	if cornerType == "inner" then
		templateName = templateNames.Inner
	elseif cornerType == "outer" then
		templateName = templateNames.Outer
	else
		templateName = templateNames.Normal
	end
	
	-- Use corner rotation if provided, otherwise use direction rotation
	local finalRotation
	if cornerRotation ~= nil then
		finalRotation = cornerRotation
	else
		finalRotation = StairPlacement.DirectionToRotation(finalDirection)
	end
	
	return {
		templateName = templateName,
		rotation = finalRotation,
		direction = finalDirection,
		upsideDown = upsideDown,
		cornerType = cornerType,
	}
end

-- Get placement info using rotation value (for hotbar rotation)
function StairPlacement.GetPlacementInfo(stairType, position, rotation, upsideDown, blocksFolder, debugMode, typeChecker, templateNames)
	local direction = StairPlacement.RotationToDirection(rotation)
	
	local cornerType, finalDirection, cornerRotation = StairPlacement.DetermineCornerType(
		position, direction, upsideDown, blocksFolder, debugMode, typeChecker
	)
	
	-- Select template based on corner type
	templateNames = templateNames or StairPlacement.TEMPLATE_NAMES
	local templateName
	if cornerType == "inner" then
		templateName = templateNames.Inner
	elseif cornerType == "outer" then
		templateName = templateNames.Outer
	else
		templateName = templateNames.Normal
	end
	
	-- Use corner rotation if provided, otherwise use direction rotation
	local finalRotation
	if cornerRotation ~= nil then
		finalRotation = cornerRotation
	else
		finalRotation = StairPlacement.DirectionToRotation(finalDirection)
	end
	
	return {
		templateName = templateName,
		rotation = finalRotation,
		direction = finalDirection,
		upsideDown = upsideDown,
		cornerType = cornerType,
	}
end

-- Build the final CFrame for stair placement
function StairPlacement.GetStairCFrame(position, rotation, upsideDown)
	local cf = CFrame.new(position) * CFrame.Angles(0, math.rad(rotation), 0)
	
	if upsideDown then
		-- Flip 180° on X axis
		cf = cf * CFrame.Angles(math.pi, 0, 0)
	end
	
	return cf
end

-- ============================================
-- ADJACENT STAIR UPDATE (for auto-corners)
-- ============================================

-- Check if an existing stair should become a corner after a new stair is placed
-- Returns "inner", "outer", or nil
function StairPlacement.ShouldExistingStairBecomeCorner(existingPos, existingDir, existingUpsideDown, newPos, newDir, blocksFolder, typeChecker)
	-- Are the stairs perpendicular?
	local dirDiff = math.abs(existingDir - newDir)
	local isPerpendicular = (dirDiff == 1) or (dirDiff == 3)
	
	if not isPerpendicular then
		return nil
	end
	
	-- Find which direction the new stair is from the existing stair
	local delta = newPos - existingPos
	local newStairDirectionFromExisting = nil
	
	if math.abs(delta.X) > math.abs(delta.Z) then
		newStairDirectionFromExisting = delta.X > 0 and 1 or 3  -- EAST or WEST
	else
		newStairDirectionFromExisting = delta.Z > 0 and 0 or 2  -- NORTH or SOUTH
	end
	
	-- Get existing stair's directions
	local existingBackDir = StairPlacement.GetOppositeDirection(existingDir)
	local existingLeftDir = StairPlacement.GetLeftDirection(existingDir)
	local existingRightDir = StairPlacement.GetRightDirection(existingDir)
	
	-- Case 1: New stair is BEHIND existing stair (existing stair's ascending direction)
	-- When a perpendicular stair is placed behind, existing becomes INNER corner
	-- (You're filling in the inside of an L-turn)
	if newStairDirectionFromExisting == existingBackDir then
		return "inner"
	end
	
	-- Case 2: New stair is in FRONT of existing stair (where existing stair faces)
	-- Existing should become corner if: new is perpendicular AND we form an L-connection
	if newStairDirectionFromExisting == existingDir then
		-- Check if existing stair's LEFT or RIGHT matches new stair's BACK direction
		local existingLeftDir = StairPlacement.GetLeftDirection(existingDir)
		local existingRightDir = StairPlacement.GetRightDirection(existingDir)
		local newStairBackDir = StairPlacement.GetOppositeDirection(newDir)
		
		local connectsOnLeft = (existingLeftDir == newStairBackDir)
		local connectsOnRight = (existingRightDir == newStairBackDir)
		
		if connectsOnLeft or connectsOnRight then
			-- Check if there's a same-direction stair BEHIND existing stair
			-- If yes, existing is extending a run, not making a corner
			-- (A same-dir stair to the SIDE is a parallel line, doesn't block corners)
			local backOffset = StairPlacement.GetDirectionOffset(existingBackDir) * BLOCK_SIZE
			local backStair = StairPlacement.GetStairAt(existingPos + backOffset, blocksFolder, typeChecker)
			local hasSameDirBehind = backStair and backStair.direction == existingDir and backStair.upsideDown == existingUpsideDown
			
			if not hasSameDirBehind then
				-- No same-dir stair behind, so existing becomes a corner
				-- FRONT check = completing a square corner = always OUTER
				return "outer"
			end
		end
	end
	
	return nil
end

return StairPlacement
