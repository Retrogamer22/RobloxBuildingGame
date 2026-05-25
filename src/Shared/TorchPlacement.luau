--[[
	TorchPlacement
	Handles placement of torches on blocks
	
	Rules:
	- TorchStraight: placed on TOP face of a solid block (no stacking, no decorations beneath)
	- TorchAngled: placed on SIDE faces (North, South, East, West) of solid blocks
	- Torches cannot be placed on bottom faces
	- Torches are decorative and don't support other blocks
	
	Model orientation:
	- TorchStraight: Upright, no rotation needed
	- TorchAngled: Tilted 22.5° away from wall, rotated to face outward from attached surface
	  - Default model orientation: tilted toward -Z (North), attaches to +Z (South) wall
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TorchPlacement = {}

-- ============================================
-- CONFIGURATION
-- ============================================

local BLOCK_SIZE = 3
local TORCH_ANGLE = 22.5 -- Degrees to tilt angled torch (positive = lean away from wall)

-- Debug flag
local DEBUG_TORCHES = false

-- ============================================
-- TORCH TYPE DETECTION
-- ============================================

-- Check if a block type is a torch
function TorchPlacement.IsTorch(blockId)
	if not blockId then return false end
	
	-- Exact match for "Torch" or pattern match for future colored torches
	return blockId == "Torch" or string.match(blockId, "Torch$") ~= nil
end

-- Check if a part/model is a torch block
function TorchPlacement.IsTorchBlock(block)
	if not block then return false end
	
	-- Check attribute first
	if block:GetAttribute("IsTorch") then return true end
	
	-- Check BlockType attribute
	local blockType = block:GetAttribute("BlockType")
	if blockType and TorchPlacement.IsTorch(blockType) then return true end
	
	return false
end

-- ============================================
-- FACE DETECTION
-- ============================================

-- Get the face from a raycast normal
function TorchPlacement.GetFaceFromNormal(normal)
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

-- Check if a face is valid for torch placement (not bottom)
function TorchPlacement.IsValidFace(face)
	return face ~= "Bottom"
end

-- Check if placing on top face (uses straight torch)
function TorchPlacement.IsTopFace(face)
	return face == "Top"
end

-- Check if placing on side face (uses angled torch)
function TorchPlacement.IsSideFace(face)
	return face == "North" or face == "South" or face == "East" or face == "West"
end

-- ============================================
-- MODEL SELECTION
-- ============================================

-- Get the appropriate torch model name based on placement face
function TorchPlacement.GetTorchModelName(face)
	if TorchPlacement.IsTopFace(face) then
		return "TorchStraight"
	else
		return "TorchAngled"
	end
end

-- ============================================
-- ROTATION CALCULATION
-- ============================================

-- Get Y rotation for angled torch based on which face it attaches to
-- Torch model default: tilted toward -Z (North), attaches to +Z (South) wall
function TorchPlacement.GetTorchYRotation(face)
	if face == "Top" then
		return 0 -- No Y rotation for straight torch
	elseif face == "North" then
		-- Attaching to North face (-Z), torch faces South (+Z)
		return 180
	elseif face == "South" then
		-- Attaching to South face (+Z), torch faces North (-Z)
		return 0
	elseif face == "East" then
		-- Attaching to East face (+X), torch faces West (-X)
		return 90
	elseif face == "West" then
		-- Attaching to West face (-X), torch faces East (+X)
		return -90
	end
	
	return 0
end

-- ============================================
-- POSITION CALCULATION
-- ============================================

-- Get the grid position for the torch
-- Top torches: placed in the cell above the host block
-- Side torches: placed in the adjacent cell, pushed against the host block
function TorchPlacement.GetTorchGridPosition(hostBlockPosition, face)
	local offset = Vector3.new(0, 0, 0)
	
	if face == "Top" then
		offset = Vector3.new(0, BLOCK_SIZE, 0)
	elseif face == "North" then
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

-- Get the CFrame for torch placement
function TorchPlacement.GetTorchCFrame(gridPosition, face)
	local yRotation = TorchPlacement.GetTorchYRotation(face)
	local isAngled = TorchPlacement.IsSideFace(face)
	
	-- For angled torches, offset toward the wall they're attached to
	local positionOffset = Vector3.new(0, 0, 0)
	
	if isAngled then
		-- Push torch against the wall (similar to ladder placement)
		-- The amount depends on torch model size, adjust as needed
		local wallOffset = BLOCK_SIZE * 0.35 -- Adjust this value based on your torch model
		
		if face == "North" then
			positionOffset = Vector3.new(0, 0, wallOffset)
		elseif face == "South" then
			positionOffset = Vector3.new(0, 0, -wallOffset)
		elseif face == "East" then
			positionOffset = Vector3.new(-wallOffset, 0, 0)
		elseif face == "West" then
			positionOffset = Vector3.new(wallOffset, 0, 0)
		end
	end
	
	local finalPosition = gridPosition + positionOffset
	
	if DEBUG_TORCHES then
		print(string.format("[Torch] CFrame: grid=(%.1f, %.1f, %.1f), face=%s, yRot=%d, angled=%s",
			gridPosition.X, gridPosition.Y, gridPosition.Z, face, yRotation, tostring(isAngled)))
	end
	
	-- Build the CFrame with rotation
	-- Apply Y offset for bottom-center pivot: move down by BLOCK_SIZE/2 so base is at bottom of grid cell
	local baseCFrame = CFrame.new(finalPosition)
	
	-- Model correction: rotate 90 degrees clockwise (when viewed from above) to orient fire particles upward
	local modelCorrection = CFrame.Angles(0, math.rad(-90), 0)
	
	if isAngled then
		-- For angled torches: apply model correction, then Y rotation, then local Z tilt to lean away from wall
		-- (Z tilt instead of X because model correction rotated the axes)
		baseCFrame = baseCFrame * modelCorrection * CFrame.Angles(0, math.rad(yRotation), 0) * CFrame.Angles(0, 0, math.rad(-TORCH_ANGLE))
	else
		-- Straight torch on top - just apply model correction
		baseCFrame = baseCFrame * modelCorrection * CFrame.Angles(0, math.rad(yRotation), 0)
	end
	
	return baseCFrame * CFrame.new(0, -BLOCK_SIZE / 2, 0)
end

-- ============================================
-- COLLISION DETECTION
-- ============================================

-- Check if a torch already exists at the given grid position
function TorchPlacement.GetTorchAtPosition(position, blocksFolder)
	if not blocksFolder then return nil end
	
	for _, block in ipairs(blocksFolder:GetChildren()) do
		if TorchPlacement.IsTorchBlock(block) then
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
					if DEBUG_TORCHES then
						print(string.format("[Torch] Found existing torch at grid (%.1f, %.1f, %.1f)",
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

-- Check if placement is valid (no existing torch in grid cell)
function TorchPlacement.CanPlaceAt(gridPosition, blocksFolder)
	local existing = TorchPlacement.GetTorchAtPosition(gridPosition, blocksFolder)
	return existing == nil
end

-- ============================================
-- HOST BLOCK VALIDATION
-- ============================================

-- Find the block at a given position in the blocksFolder
function TorchPlacement.GetBlockAtPosition(position, blocksFolder)
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
function TorchPlacement.IsBlockFence(block)
	if not block then return false end
	return block:GetAttribute("IsFence") == true
end

-- Check if a block is a decoration
function TorchPlacement.IsBlockDecoration(block)
	if not block then return false end
	return block:GetAttribute("IsDecoration") == true
end

-- Check if a block is a ladder
function TorchPlacement.IsBlockLadder(block)
	if not block then return false end
	return block:GetAttribute("IsLadder") == true
end

-- ============================================
-- PLACEMENT INFO
-- ============================================

-- Get complete placement info from raycast data
-- Returns nil if placement is invalid
function TorchPlacement.GetPlacementInfo(blockId, hitPosition, hitNormal, hitBlockPosition, blocksFolder)
	local face = TorchPlacement.GetFaceFromNormal(hitNormal)
	
	-- Check if face is valid (not bottom)
	if not TorchPlacement.IsValidFace(face) then
		if DEBUG_TORCHES then
			print(string.format("[Torch] Invalid face: %s (cannot place on bottom)", face))
		end
		return nil, "Torches cannot be placed on the bottom of blocks"
	end
	
	-- Find the host block to check its type
	local hostBlock = TorchPlacement.GetBlockAtPosition(hitBlockPosition, blocksFolder)
	
	-- Check if trying to place on a decoration (not allowed on any face)
	if TorchPlacement.IsBlockDecoration(hostBlock) then
		if DEBUG_TORCHES then
			print("[Torch] Cannot place torch on a decoration")
		end
		return nil, "Torches cannot be placed on decorations"
	end
	
	-- Check if trying to place on a ladder (not allowed on any face)
	if TorchPlacement.IsBlockLadder(hostBlock) then
		if DEBUG_TORCHES then
			print("[Torch] Cannot place torch on a ladder")
		end
		return nil, "Torches cannot be placed on ladders"
	end
	
	-- Check if trying to place on a campfire-type block (Campfire, ColumnTorch)
	if hostBlock and hostBlock:GetAttribute("IsCampfire") then
		if DEBUG_TORCHES then
			print("[Torch] Cannot place torch on a campfire/column torch")
		end
		return nil, "Torches cannot be placed on this block"
	end
	
	-- Check if trying to place on a fence - only top face allowed
	if TorchPlacement.IsBlockFence(hostBlock) then
		if TorchPlacement.IsSideFace(face) then
			if DEBUG_TORCHES then
				print("[Torch] Cannot place torch on side of fence")
			end
			return nil, "Torches can only be placed on top of fences"
		end
	end
	
	-- Calculate grid position for the torch
	local gridPosition = TorchPlacement.GetTorchGridPosition(hitBlockPosition, face)
	
	-- Check if a torch already exists at this position
	if blocksFolder and not TorchPlacement.CanPlaceAt(gridPosition, blocksFolder) then
		if DEBUG_TORCHES then
			print(string.format("[Torch] Position already occupied at grid (%.1f, %.1f, %.1f)",
				gridPosition.X, gridPosition.Y, gridPosition.Z))
		end
		return nil, "A torch already exists at this position"
	end
	
	-- Get the CFrame for placement
	local cframe = TorchPlacement.GetTorchCFrame(gridPosition, face)
	local rotation = TorchPlacement.GetTorchYRotation(face)
	local modelName = TorchPlacement.GetTorchModelName(face)
	
	if DEBUG_TORCHES then
		print(string.format("[Torch] PlacementInfo: face=%s, gridPos=(%.1f, %.1f, %.1f), rotation=%d, model=%s",
			face, gridPosition.X, gridPosition.Y, gridPosition.Z, rotation, modelName))
	end
	
	return {
		face = face,
		gridPosition = gridPosition,
		cframe = cframe,
		rotation = rotation,
		modelName = modelName, -- "TorchStraight" or "TorchAngled"
		isAngled = TorchPlacement.IsSideFace(face),
		hostPosition = hitBlockPosition,
	}, nil
end

-- ============================================
-- DEBUG HELPERS
-- ============================================

function TorchPlacement.GetFaceName(face)
	return face or "Unknown"
end

return TorchPlacement
