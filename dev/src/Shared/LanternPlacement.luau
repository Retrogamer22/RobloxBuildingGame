--[[
	LanternPlacement
	Handles placement of lanterns on blocks
	
	Rules:
	- Lanterns can ONLY be placed on TOP or BOTTOM faces of solid blocks
	- NOT on sides (unlike torches)
	- Cannot be placed on decorations, ladders, glass, leaves
	- Can be placed on top or bottom of fences
	- Lanterns are decorative and don't support other blocks
	- Fences should NOT connect to lanterns
	
	Model orientation:
	- Lantern model must have TOP pivot (at the hanging point/top of lantern)
	- This allows hanging lanterns to swing naturally from the pivot point
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LanternPlacement = {}

-- ============================================
-- CONFIGURATION
-- ============================================

local BLOCK_SIZE = 3

-- Lantern positioning uses standard grid cell offsets
-- Sitting lanterns go at bottom of cell, hanging lanterns at top of cell

-- Debug flag
local DEBUG_LANTERNS = false

-- ============================================
-- LANTERN TYPE DETECTION
-- ============================================

-- Check if a block type is a lantern
function LanternPlacement.IsLantern(blockId)
	if not blockId then return false end
	
	-- Exact match for "Lantern" or pattern match for future colored lanterns
	return blockId == "Lantern" or string.match(blockId, "Lantern$") ~= nil
end

-- Check if a part/model is a lantern block
function LanternPlacement.IsLanternBlock(block)
	if not block then return false end
	
	-- Check attribute first
	if block:GetAttribute("IsLantern") then return true end
	
	-- Check BlockType attribute
	local blockType = block:GetAttribute("BlockType")
	if blockType and LanternPlacement.IsLantern(blockType) then return true end
	
	return false
end

-- ============================================
-- FACE DETECTION
-- ============================================

-- Get the face from a raycast normal
function LanternPlacement.GetFaceFromNormal(normal)
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

-- Check if a face is valid for lantern placement (only top or bottom)
function LanternPlacement.IsValidFace(face)
	return face == "Top" or face == "Bottom"
end

-- Check if placing on top face
function LanternPlacement.IsTopFace(face)
	return face == "Top"
end

-- Check if placing on bottom face (hanging lantern)
function LanternPlacement.IsBottomFace(face)
	return face == "Bottom"
end

-- ============================================
-- POSITION CALCULATION
-- ============================================

-- Get the grid position for the lantern
-- Top lanterns: placed in the cell above the host block
-- Bottom lanterns: placed in the cell below the host block
function LanternPlacement.GetLanternGridPosition(hostBlockPosition, face)
	local offset = Vector3.new(0, 0, 0)
	
	if face == "Top" then
		offset = Vector3.new(0, BLOCK_SIZE, 0)
	elseif face == "Bottom" then
		offset = Vector3.new(0, -BLOCK_SIZE, 0)
	end
	
	return hostBlockPosition + offset
end

-- Get the CFrame for lantern placement
function LanternPlacement.GetLanternCFrame(gridPosition, face)
	-- The grid position is the center of the cell
	-- Lantern pivot is at the CENTER of the model
	-- For TOP placement: lantern sits at bottom of grid cell (on top of host block)
	-- For BOTTOM placement: lantern hangs at top of grid cell (under host block)
	
	local yOffset
	if face == "Top" then
		-- Sitting: move up so bottom of lantern rests on host surface
		yOffset = BLOCK_SIZE / 2
	else
		-- Hanging: move up to top of cell, lantern hangs from ceiling
		yOffset = BLOCK_SIZE / 2
	end
	
	local finalPosition = gridPosition + Vector3.new(0, yOffset, 0)
	
	if DEBUG_LANTERNS then
		print(string.format("[Lantern] CFrame: grid=(%.1f, %.1f, %.1f), face=%s, yOffset=%.1f",
			gridPosition.X, gridPosition.Y, gridPosition.Z, face, yOffset))
	end
	
	-- No rotation needed for lanterns - they just hang/sit vertically
	return CFrame.new(finalPosition)
end

-- ============================================
-- COLLISION DETECTION
-- ============================================

-- Check if a lantern already exists at the given grid position
function LanternPlacement.GetLanternAtPosition(position, blocksFolder)
	if not blocksFolder then return nil end
	
	for _, block in ipairs(blocksFolder:GetChildren()) do
		if LanternPlacement.IsLanternBlock(block) then
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
					if DEBUG_LANTERNS then
						print(string.format("[Lantern] Found existing lantern at grid (%.1f, %.1f, %.1f)",
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

-- Check if placement is valid (no existing lantern in grid cell)
function LanternPlacement.CanPlaceAt(gridPosition, blocksFolder)
	local existing = LanternPlacement.GetLanternAtPosition(gridPosition, blocksFolder)
	return existing == nil
end

-- ============================================
-- HOST BLOCK VALIDATION
-- ============================================

-- Find the block at a given position in the blocksFolder
function LanternPlacement.GetBlockAtPosition(position, blocksFolder)
	if not blocksFolder then return nil end
	
	for _, block in ipairs(blocksFolder:GetChildren()) do
		local blockPos
		if block:IsA("Model") then
			blockPos = block:GetPivot().Position
		elseif block:IsA("BasePart") then
			blockPos = block:GetPivot().Position
		end
		
		if blockPos then
			-- Check if in same grid cell (within 1.5 stud tolerance)
			if (blockPos - position).Magnitude < 1.5 then
				return block
			end
		end
	end
	
	return nil
end

-- Check if a block is a fence
function LanternPlacement.IsBlockFence(block)
	if not block then return false end
	return block:GetAttribute("IsFence") == true
end

-- Check if a block is a decoration
function LanternPlacement.IsBlockDecoration(block)
	if not block then return false end
	return block:GetAttribute("IsDecoration") == true
end

-- Check if a block is a ladder
function LanternPlacement.IsBlockLadder(block)
	if not block then return false end
	return block:GetAttribute("IsLadder") == true
end

-- Check if a block is glass
function LanternPlacement.IsBlockGlass(block)
	if not block then return false end
	return block:GetAttribute("IsGlass") == true
end

-- Check if a block is leaves
function LanternPlacement.IsBlockLeaves(block)
	if not block then return false end
	local blockType = block:GetAttribute("BlockType")
	return blockType == "Leaves"
end

-- ============================================
-- PLACEMENT INFO
-- ============================================

-- Get complete placement info from raycast data
-- Returns nil if placement is invalid
function LanternPlacement.GetPlacementInfo(blockId, hitPosition, hitNormal, hitBlockPosition, blocksFolder)
	local face = LanternPlacement.GetFaceFromNormal(hitNormal)
	
	-- Check if face is valid (only top or bottom)
	if not LanternPlacement.IsValidFace(face) then
		if DEBUG_LANTERNS then
			print(string.format("[Lantern] Invalid face: %s (can only place on top or bottom)", face))
		end
		return nil, "Lanterns can only be placed on top or bottom of blocks"
	end
	
	-- Find the host block to check its type
	local hostBlock = LanternPlacement.GetBlockAtPosition(hitBlockPosition, blocksFolder)
	
	-- Check if trying to place on a decoration (not allowed on any face)
	if LanternPlacement.IsBlockDecoration(hostBlock) then
		if DEBUG_LANTERNS then
			print("[Lantern] Cannot place lantern on a decoration")
		end
		return nil, "Lanterns cannot be placed on decorations"
	end
	
	-- Check if trying to place on a ladder (not allowed on any face)
	if LanternPlacement.IsBlockLadder(hostBlock) then
		if DEBUG_LANTERNS then
			print("[Lantern] Cannot place lantern on a ladder")
		end
		return nil, "Lanterns cannot be placed on ladders"
	end
	
	-- Check if trying to place on glass (not allowed)
	if LanternPlacement.IsBlockGlass(hostBlock) then
		if DEBUG_LANTERNS then
			print("[Lantern] Cannot place lantern on glass")
		end
		return nil, "Lanterns cannot be placed on glass"
	end
	
	-- Check if trying to place on leaves (not allowed)
	if LanternPlacement.IsBlockLeaves(hostBlock) then
		if DEBUG_LANTERNS then
			print("[Lantern] Cannot place lantern on leaves")
		end
		return nil, "Lanterns cannot be placed on leaves"
	end
	
	-- Fences allow both top and bottom placement (no restriction)
	
	-- Calculate grid position for the lantern
	local gridPosition = LanternPlacement.GetLanternGridPosition(hitBlockPosition, face)
	
	-- Check if a lantern already exists at this position
	if blocksFolder and not LanternPlacement.CanPlaceAt(gridPosition, blocksFolder) then
		if DEBUG_LANTERNS then
			print(string.format("[Lantern] Position already occupied at grid (%.1f, %.1f, %.1f)",
				gridPosition.X, gridPosition.Y, gridPosition.Z))
		end
		return nil, "A lantern already exists at this position"
	end
	
	-- Get the CFrame for placement
	local cframe = LanternPlacement.GetLanternCFrame(gridPosition, face)
	local isHanging = LanternPlacement.IsBottomFace(face)
	
	if DEBUG_LANTERNS then
		print(string.format("[Lantern] PlacementInfo: face=%s, gridPos=(%.1f, %.1f, %.1f), hanging=%s",
			face, gridPosition.X, gridPosition.Y, gridPosition.Z, tostring(isHanging)))
	end
	
	return {
		face = face,
		gridPosition = gridPosition,
		cframe = cframe,
		isHanging = isHanging,
		hostPosition = hitBlockPosition,
	}, nil
end

-- ============================================
-- DEBUG HELPERS
-- ============================================

function LanternPlacement.GetFaceName(face)
	return face or "Unknown"
end

return LanternPlacement
