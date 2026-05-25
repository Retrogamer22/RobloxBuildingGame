--[[
	LadderPlacement
	Handles placement of ladder blocks on the side faces of blocks
	
	Rules:
	- Ladders can only attach to side faces (North, South, East, West) - NOT top or bottom
	- Only one ladder per grid position (can't stack multiple in same space)
	- Ladders are 0.5 studs thick with pivot in the center
	- Ladder faces outward from the block it's attached to
	
	Model orientation:
	- The Ladder template model is oriented with:
	  - Front face (rungs visible) facing -Z (North) by default
	  - The ladder attaches to the block behind it (in +Z direction)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LadderPlacement = {}

-- ============================================
-- CONFIGURATION
-- ============================================

local BLOCK_SIZE = 3
local LADDER_THICKNESS = 0.5

-- Debug flag
local DEBUG_LADDERS = false

-- ============================================
-- LADDER TYPE DETECTION
-- ============================================

-- Check if a block type is a ladder
-- Uses pattern matching so ANY "*Ladder" block type works
function LadderPlacement.IsLadder(blockId)
	if not blockId then return false end
	
	-- Pattern match: anything ending with "Ladder" is a ladder
	if string.match(blockId, "Ladder$") then return true end
	
	return false
end

-- Get the base material type for a ladder (used for texturing)
-- e.g., "OakLadder" -> "OakPlanks", "SpruceLadder" -> "SprucePlanks"
function LadderPlacement.GetLadderBaseMaterial(blockId)
	if not blockId then return nil end
	
	-- Extract base from "*Ladder" pattern
	local base = string.match(blockId, "^(.+)Ladder$")
	if base then
		-- Ladders are planks-based
		return base .. "Planks"
	end
	
	return blockId
end

-- Check if a part/model is a ladder block
function LadderPlacement.IsLadderBlock(block)
	if not block then return false end
	
	-- Check attribute first
	if block:GetAttribute("IsLadder") then return true end
	
	-- Check BlockType attribute
	local blockType = block:GetAttribute("BlockType")
	if blockType and LadderPlacement.IsLadder(blockType) then return true end
	
	return false
end

-- ============================================
-- FACE DETECTION
-- ============================================

-- Get the face from a raycast normal
function LadderPlacement.GetFaceFromNormal(normal)
	local absX = math.abs(normal.X)
	local absY = math.abs(normal.Y)
	local absZ = math.abs(normal.Z)
	
	if absY > absX and absY > absZ then
		if normal.Y > 0 then
			return "Top"
		else
			return "Bottom"
		end
	elseif absX > absZ then
		if normal.X > 0 then
			return "East" -- +X
		else
			return "West" -- -X
		end
	else
		if normal.Z > 0 then
			return "South" -- +Z
		else
			return "North" -- -Z
		end
	end
end

-- Check if a face is valid for ladder placement (sides only, not top/bottom)
function LadderPlacement.IsValidFace(face)
	return face == "North" or face == "South" or face == "East" or face == "West"
end

-- ============================================
-- ROTATION CALCULATION
-- ============================================

-- Get rotation for ladder based on which face it attaches to
-- Ladder model default: rungs face -Z (North), attaches to +Z (South) wall
-- Rotation makes ladder face outward from the wall it's attached to
function LadderPlacement.GetLadderRotation(face)
	if face == "North" then
		-- Attaching to North face (-Z), ladder faces South (+Z)
		return 180 -- Rotate 180° so rungs face +Z
	elseif face == "South" then
		-- Attaching to South face (+Z), ladder faces North (-Z)
		return 0 -- No rotation, rungs face -Z (default)
	elseif face == "East" then
		-- Attaching to East face (+X), ladder faces West (-X)
		return 90 -- Rotate 90° so rungs face -X
	elseif face == "West" then
		-- Attaching to West face (-X), ladder faces East (+X)
		return -90 -- Rotate -90° so rungs face +X
	end
	
	return 0
end

-- ============================================
-- POSITION CALCULATION
-- ============================================

-- Get the grid position for the ladder
-- Ladders occupy their own grid cell, positioned against the host block's face
function LadderPlacement.GetLadderGridPosition(hostBlockPosition, face)
	local offset = Vector3.new(0, 0, 0)
	
	if face == "North" then
		offset = Vector3.new(0, 0, -BLOCK_SIZE)
	elseif face == "South" then
		offset = Vector3.new(0, 0, BLOCK_SIZE)
	elseif face == "East" then
		offset = Vector3.new(BLOCK_SIZE, 0, 0)
	elseif face == "West" then
		offset = Vector3.new(-BLOCK_SIZE, 0, 0)
	end
	
	return hostBlockPosition + offset
end

-- Get the CFrame for ladder placement
-- The ladder occupies the adjacent grid cell but is positioned against the host block's face
function LadderPlacement.GetLadderCFrame(gridPosition, face)
	local rotation = LadderPlacement.GetLadderRotation(face)
	
	-- Calculate offset to push ladder against the wall
	-- Ladder is LADDER_THICKNESS (0.5) thick, so offset is (BLOCK_SIZE/2 - LADDER_THICKNESS/2)
	local wallOffset = BLOCK_SIZE / 2 - LADDER_THICKNESS / 2
	local positionOffset = Vector3.new(0, 0, 0)
	
	if face == "North" then
		-- Ladder in North cell, pushed against the South side of that cell (touching host block)
		positionOffset = Vector3.new(0, 0, wallOffset)
	elseif face == "South" then
		-- Ladder in South cell, pushed against the North side of that cell
		positionOffset = Vector3.new(0, 0, -wallOffset)
	elseif face == "East" then
		-- Ladder in East cell, pushed against the West side of that cell
		positionOffset = Vector3.new(-wallOffset, 0, 0)
	elseif face == "West" then
		-- Ladder in West cell, pushed against the East side of that cell
		positionOffset = Vector3.new(wallOffset, 0, 0)
	end
	
	local finalPosition = gridPosition + positionOffset
	
	if DEBUG_LADDERS then
		print(string.format("[Ladder] CFrame: grid=(%.1f, %.1f, %.1f), face=%s, rotation=%d, offset=(%.1f, %.1f, %.1f)",
			gridPosition.X, gridPosition.Y, gridPosition.Z, face, rotation,
			positionOffset.X, positionOffset.Y, positionOffset.Z))
	end
	
	return CFrame.new(finalPosition) * CFrame.Angles(0, math.rad(rotation), 0)
end

-- ============================================
-- COLLISION DETECTION
-- ============================================

-- Check if a ladder already exists at the given grid position
function LadderPlacement.GetLadderAtPosition(position, blocksFolder)
	if not blocksFolder then return nil end
	
	for _, block in ipairs(blocksFolder:GetChildren()) do
		if LadderPlacement.IsLadderBlock(block) then
			local blockPos
			if block:IsA("Model") then
				blockPos = block:GetPivot().Position
			elseif block:IsA("BasePart") then
				blockPos = block:GetPivot().Position
			end
			
			if blockPos then
				-- Check if in same grid cell (within 1 stud tolerance)
				local gridX = math.round(position.X / BLOCK_SIZE) * BLOCK_SIZE
				local gridY = math.round(position.Y / BLOCK_SIZE) * BLOCK_SIZE
				local gridZ = math.round(position.Z / BLOCK_SIZE) * BLOCK_SIZE
				
				local blockGridX = math.round(blockPos.X / BLOCK_SIZE) * BLOCK_SIZE
				local blockGridY = math.round(blockPos.Y / BLOCK_SIZE) * BLOCK_SIZE
				local blockGridZ = math.round(blockPos.Z / BLOCK_SIZE) * BLOCK_SIZE
				
				if gridX == blockGridX and gridY == blockGridY and gridZ == blockGridZ then
					if DEBUG_LADDERS then
						print(string.format("[Ladder] Found existing ladder at grid (%.1f, %.1f, %.1f)",
							gridX, gridY, gridZ))
					end
					return {
						instance = block,
						blockType = block:GetAttribute("BlockType"),
						position = blockPos,
					}
				end
			end
		end
	end
	
	return nil
end

-- Check if placement is valid (no existing ladder in grid cell)
function LadderPlacement.CanPlaceAt(gridPosition, blocksFolder)
	local existing = LadderPlacement.GetLadderAtPosition(gridPosition, blocksFolder)
	return existing == nil
end

-- ============================================
-- PLACEMENT INFO
-- ============================================

-- Get complete placement info from raycast data
-- Returns nil if placement is invalid (top/bottom face or ladder already exists)
function LadderPlacement.GetPlacementInfo(blockId, hitPosition, hitNormal, hitBlockPosition, blocksFolder)
	local face = LadderPlacement.GetFaceFromNormal(hitNormal)
	
	-- Check if face is valid (sides only)
	if not LadderPlacement.IsValidFace(face) then
		if DEBUG_LADDERS then
			print(string.format("[Ladder] Invalid face: %s (must be side face)", face))
		end
		return nil, "Ladders can only be placed on the sides of blocks"
	end
	
	-- Calculate grid position for the ladder
	local gridPosition = LadderPlacement.GetLadderGridPosition(hitBlockPosition, face)
	
	-- Check if a ladder already exists at this position
	if blocksFolder and not LadderPlacement.CanPlaceAt(gridPosition, blocksFolder) then
		if DEBUG_LADDERS then
			print(string.format("[Ladder] Position already occupied at grid (%.1f, %.1f, %.1f)",
				gridPosition.X, gridPosition.Y, gridPosition.Z))
		end
		return nil, "A ladder already exists at this position"
	end
	
	-- Get the CFrame for placement
	local cframe = LadderPlacement.GetLadderCFrame(gridPosition, face)
	local rotation = LadderPlacement.GetLadderRotation(face)
	
	if DEBUG_LADDERS then
		print(string.format("[Ladder] PlacementInfo: face=%s, gridPos=(%.1f, %.1f, %.1f), rotation=%d",
			face, gridPosition.X, gridPosition.Y, gridPosition.Z, rotation))
	end
	
	return {
		face = face,
		gridPosition = gridPosition,
		cframe = cframe,
		rotation = rotation,
		hostPosition = hitBlockPosition,
	}, nil
end

-- ============================================
-- DEBUG HELPERS
-- ============================================

function LadderPlacement.GetFaceName(face)
	return face or "Unknown"
end

return LadderPlacement
