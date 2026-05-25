--[[
	SignPlacement
	Handles placement of sign blocks (standing signs and wall signs)
	
	Sign Types:
	1. SignStanding - Standing sign with post
	   - Can ONLY be placed on TOP of blocks (not sides or bottom)
	   - Supports 16-direction rotation (22.5° increments like Minecraft)
	   - Post remains constant color, only Sign part gets wood color
	   - Pivot is at bottom center of post
	   - Cannot be placed on decoration blocks (except fences are OK)
	
	2. Sign (wall sign) - Flat sign attached to walls
	   - Can ONLY be placed on SIDE faces (North, South, East, West) - NOT top or bottom
	   - Rotates to face outward from the wall it's attached to
	   - Cannot be placed on any decoration blocks (fences are OK)
	   - Pivot is at center of the sign
	
	Model orientation:
	- SignStanding: Post vertical, Sign facing -Z (North) by default
	- Sign (wall): Front face facing -Z (North) by default, attaches to +Z (South) wall
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SignPlacement = {}

-- ============================================
-- CONFIGURATION
-- ============================================

local BLOCK_SIZE = 3
local SIGN_THICKNESS = 0.3 -- Wall sign thickness

-- 16-direction rotation increments (22.5° each, like Minecraft)
local ROTATION_INCREMENT = 22.5
local TOTAL_DIRECTIONS = 16

-- Debug flag
local DEBUG_SIGNS = false

-- ============================================
-- SIGN TYPE DETECTION
-- ============================================

-- Check if a block type is a standing sign
function SignPlacement.IsSignStanding(blockId)
	if not blockId then return false end
	if blockId == "SignStandingFrame" then return true end
	return string.match(blockId, "SignStanding$") ~= nil
end

-- Check if a block type is a wall sign
function SignPlacement.IsWallSign(blockId)
	if not blockId then return false end
	if blockId == "SignFrame" then return true end
	-- Match "Sign" at end but NOT "SignStanding"
	if string.match(blockId, "SignStanding$") then return false end
	return string.match(blockId, "Sign$") ~= nil
end

-- Check if a block type is any kind of sign
function SignPlacement.IsSign(blockId)
	if not blockId then return false end
	return SignPlacement.IsSignStanding(blockId) or SignPlacement.IsWallSign(blockId)
end

-- Get the base wood type for a sign (used for coloring)
-- e.g., "OakSignStanding" -> "OakPlanks", "BirchSign" -> "BirchPlanks"
function SignPlacement.GetSignBaseMaterial(blockId)
	if not blockId then return nil end
	
	-- Extract base from "*SignStanding" or "*Sign" pattern
	local base = string.match(blockId, "^(.+)SignStanding$")
	if not base then
		base = string.match(blockId, "^(.+)Sign$")
	end
	
	if base then
		return base .. "Planks"
	end
	
	return blockId
end

-- Check if a part/model is a sign block
function SignPlacement.IsSignBlock(block)
	if not block then return false end
	
	-- Check attributes
	if block:GetAttribute("IsSignStanding") or block:GetAttribute("IsWallSign") then 
		return true 
	end
	
	-- Check BlockType attribute
	local blockType = block:GetAttribute("BlockType")
	if blockType and SignPlacement.IsSign(blockType) then return true end
	
	return false
end

-- ============================================
-- FACE DETECTION
-- ============================================

-- Get the face from a raycast normal
function SignPlacement.GetFaceFromNormal(normal)
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

-- Check if face is valid for standing sign (top only)
function SignPlacement.IsValidFaceForStandingSign(face)
	return face == "Top"
end

-- Check if face is valid for wall sign (sides only)
function SignPlacement.IsValidFaceForWallSign(face)
	return face == "North" or face == "South" or face == "East" or face == "West"
end

-- ============================================
-- STANDING SIGN ROTATION (16 directions)
-- ============================================

-- Get the rotation index (0-15) from camera look vector
-- Returns the closest of 16 directions
-- Sign should face TOWARD the player (opposite of look direction)
function SignPlacement.GetRotationIndexFromLookVector(lookVector)
	-- Calculate angle so sign faces toward the camera
	-- Sign model faces -Z (North) at 0 rotation
	-- We want sign to face opposite of camera look direction
	local angle = math.atan2(lookVector.X, lookVector.Z)
	
	-- Convert to degrees (0-360)
	local degrees = math.deg(angle)
	if degrees < 0 then
		degrees = degrees + 360
	end
	
	-- Round to nearest 22.5° increment
	local index = math.round(degrees / ROTATION_INCREMENT) % TOTAL_DIRECTIONS
	
	return index
end

-- Get rotation in degrees from rotation index (0-15)
function SignPlacement.GetRotationFromIndex(index)
	return index * ROTATION_INCREMENT
end

-- Get rotation for standing sign based on camera look vector
function SignPlacement.GetStandingSignRotation(lookVector)
	local index = SignPlacement.GetRotationIndexFromLookVector(lookVector)
	return SignPlacement.GetRotationFromIndex(index), index
end

-- ============================================
-- WALL SIGN ROTATION
-- ============================================

-- Get rotation for wall sign based on which face it attaches to
-- Sign model default: front face facing -Z (North), attaches to +Z (South) wall
-- Rotation makes sign face outward from the wall
function SignPlacement.GetWallSignRotation(face)
	if face == "North" then
		-- Attaching to North face (-Z), sign faces South (+Z)
		return 0
	elseif face == "South" then
		-- Attaching to South face (+Z), sign faces North (-Z)
		return 180
	elseif face == "East" then
		-- Attaching to East face (+X), sign faces West (-X)
		return -90
	elseif face == "West" then
		-- Attaching to West face (-X), sign faces East (+X)
		return 90
	end
	
	return 0
end

-- ============================================
-- POSITION CALCULATION
-- ============================================

-- Get the grid position for a standing sign (on top of host block)
function SignPlacement.GetStandingSignGridPosition(hostBlockPosition)
	return hostBlockPosition + Vector3.new(0, BLOCK_SIZE, 0)
end

-- Get the grid position for a wall sign (adjacent to host block)
function SignPlacement.GetWallSignGridPosition(hostBlockPosition, face)
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

-- ============================================
-- CFRAME CALCULATION
-- ============================================

-- Get the CFrame for a standing sign
-- Pivot is at bottom center of post
function SignPlacement.GetStandingSignCFrame(gridPosition, rotation)
	-- Build CFrame with rotation (pivot at center of grid cell)
	local baseCFrame = CFrame.new(gridPosition) * CFrame.Angles(0, math.rad(rotation), 0)
	
	-- Apply offset for bottom-center pivot: move down so base is at bottom of grid cell
	return baseCFrame * CFrame.new(0, -BLOCK_SIZE / 2, 0)
end

-- Get the CFrame for a wall sign
-- Sign is thin, positioned against the wall
-- For fence posts, sign is pushed much closer to touch the post
function SignPlacement.GetWallSignCFrame(gridPosition, face, isOnFencePost)
	local rotation = SignPlacement.GetWallSignRotation(face)
	
	-- Calculate offset to push sign against the wall
	-- Sign is SIGN_THICKNESS thick, so offset is (BLOCK_SIZE/2 - SIGN_THICKNESS/2)
	local wallOffset
	
	if isOnFencePost then
		-- For fence posts: push sign close but not clipping into the post
		-- Sign grid position is BLOCK_SIZE (3) away from fence
		wallOffset = BLOCK_SIZE - 0.6 -- 2.4 studs offset
		print(string.format("[SignPlacement] Using fence post offset: %.2f for face=%s", wallOffset, tostring(face)))
	else
		-- Normal blocks: standard offset with small gap
		wallOffset = BLOCK_SIZE / 2 - SIGN_THICKNESS / 2 + 0.1
		print(string.format("[SignPlacement] Using normal offset: %.2f for face=%s", wallOffset, tostring(face)))
	end
	
	local positionOffset = Vector3.new(0, 0, 0)
	
	if face == "North" then
		-- Sign in North cell, pushed against the South side of that cell (touching host block)
		positionOffset = Vector3.new(0, 0, wallOffset)
	elseif face == "South" then
		-- Sign in South cell, pushed against the North side of that cell
		positionOffset = Vector3.new(0, 0, -wallOffset)
	elseif face == "East" then
		-- Sign in East cell, pushed against the West side of that cell
		positionOffset = Vector3.new(-wallOffset, 0, 0)
	elseif face == "West" then
		-- Sign in West cell, pushed against the East side of that cell
		positionOffset = Vector3.new(wallOffset, 0, 0)
	end
	
	local finalPosition = gridPosition + positionOffset
	
	if DEBUG_SIGNS then
		print(string.format("[Sign] WallSign CFrame: grid=(%.1f, %.1f, %.1f), face=%s, rotation=%d",
			gridPosition.X, gridPosition.Y, gridPosition.Z, face, rotation))
	end
	
	-- Wall signs have center pivot, so no additional offset needed
	return CFrame.new(finalPosition) * CFrame.Angles(0, math.rad(rotation), 0)
end

-- ============================================
-- HOST BLOCK VALIDATION
-- ============================================

-- Find the block at a given position in the blocksFolder
function SignPlacement.GetBlockAtPosition(position, blocksFolder)
	if not blocksFolder then return nil end
	
	-- Snap input position to grid for comparison
	local gridX = math.round(position.X / BLOCK_SIZE) * BLOCK_SIZE
	local gridY = math.round(position.Y / BLOCK_SIZE) * BLOCK_SIZE
	local gridZ = math.round(position.Z / BLOCK_SIZE) * BLOCK_SIZE
	
	for _, block in ipairs(blocksFolder:GetChildren()) do
		-- Special-case: chests (single + double) use center pivots, not bottom-center,
		-- so we can't use the standard "pivot + BLOCK_SIZE/2" trick. Their grid cell(s)
		-- are authoritative via the BlockPosX/Y/Z (+ ChestSecondaryX/Y/Z) attributes
		-- that BlockHandler sets at placement time.
		if block:GetAttribute("IsChest") then
			local cx = block:GetAttribute("BlockPosX")
			local cy = block:GetAttribute("BlockPosY")
			local cz = block:GetAttribute("BlockPosZ")
			if cx and cy and cz then
				local pgX = math.round(cx / BLOCK_SIZE) * BLOCK_SIZE
				local pgY = math.round(cy / BLOCK_SIZE) * BLOCK_SIZE
				local pgZ = math.round(cz / BLOCK_SIZE) * BLOCK_SIZE
				if gridX == pgX and gridY == pgY and gridZ == pgZ then
					return block
				end
			end
			if block:GetAttribute("IsDoubleChest") then
				local sx = block:GetAttribute("ChestSecondaryX")
				local sy = block:GetAttribute("ChestSecondaryY")
				local sz = block:GetAttribute("ChestSecondaryZ")
				if sx and sy and sz then
					local sgX = math.round(sx / BLOCK_SIZE) * BLOCK_SIZE
					local sgY = math.round(sy / BLOCK_SIZE) * BLOCK_SIZE
					local sgZ = math.round(sz / BLOCK_SIZE) * BLOCK_SIZE
					if gridX == sgX and gridY == sgY and gridZ == sgZ then
						return block
					end
				end
			end
			continue
		end

		local blockPos
		if block:IsA("Model") then
			-- For models, pivot is at bottom-center, so add BLOCK_SIZE/2 to get grid center
			local pivot = block:GetPivot().Position
			blockPos = Vector3.new(pivot.X, pivot.Y + BLOCK_SIZE / 2, pivot.Z)
		elseif block:IsA("BasePart") then
			blockPos = block.Position
		end
		
		if blockPos then
			-- Snap block position to grid
			local blockGridX = math.round(blockPos.X / BLOCK_SIZE) * BLOCK_SIZE
			local blockGridY = math.round(blockPos.Y / BLOCK_SIZE) * BLOCK_SIZE
			local blockGridZ = math.round(blockPos.Z / BLOCK_SIZE) * BLOCK_SIZE
			
			-- Check if same grid cell
			if gridX == blockGridX and gridY == blockGridY and gridZ == blockGridZ then
				return block
			end
		end
	end
	
	return nil
end

-- Check if a block is a decoration (signs can't attach to most decorations)
function SignPlacement.IsBlockDecoration(block)
	if not block then return false end
	return block:GetAttribute("IsDecoration") == true
end

-- Check if a block is a fence (signs CAN attach to fences)
function SignPlacement.IsBlockFence(block)
	if not block then return false end
	return block:GetAttribute("IsFence") == true
end

-- Check if a block is a ladder (signs can't attach to ladders)
function SignPlacement.IsBlockLadder(block)
	if not block then return false end
	return block:GetAttribute("IsLadder") == true
end

-- Check if a block is a torch
function SignPlacement.IsBlockTorch(block)
	if not block then return false end
	return block:GetAttribute("IsTorch") == true
end

-- Check if a block is a lantern
function SignPlacement.IsBlockLantern(block)
	if not block then return false end
	return block:GetAttribute("IsLantern") == true
end

-- Check if a block is a bed (signs can't attach to beds)
function SignPlacement.IsBlockBed(block)
	if not block then return false end
	return block:GetAttribute("IsBed") == true
end

-- Check if host block is valid for sign placement
function SignPlacement.IsValidHostBlock(block, isStandingSign)
	if not block then return false, "No block to attach to" end
	
	-- Can't place on ladders
	if SignPlacement.IsBlockLadder(block) then
		return false, "Signs cannot be placed on ladders"
	end
	
	-- Can't place on torches
	if SignPlacement.IsBlockTorch(block) then
		return false, "Signs cannot be placed on torches"
	end
	
	-- Can't place on lanterns
	if SignPlacement.IsBlockLantern(block) then
		return false, "Signs cannot be placed on lanterns"
	end
	
	-- Can't place on beds
	if SignPlacement.IsBlockBed(block) then
		return false, "Signs cannot be placed on beds"
	end
	
	-- Can't place on columns
	if block:GetAttribute("IsColumn") then
		return false, "Signs cannot be placed on columns"
	end
	
	-- Fences are OK for both sign types
	if SignPlacement.IsBlockFence(block) then
		return true, nil
	end
	
	-- Other decorations are NOT allowed
	if SignPlacement.IsBlockDecoration(block) then
		return false, "Signs cannot be placed on decorations"
	end
	
	return true, nil
end

-- ============================================
-- COLLISION DETECTION
-- ============================================

-- Check if a sign already exists at the given grid position
function SignPlacement.GetSignAtPosition(position, blocksFolder)
	if not blocksFolder then return nil end
	
	-- Snap input position to grid
	local gridX = math.round(position.X / BLOCK_SIZE) * BLOCK_SIZE
	local gridY = math.round(position.Y / BLOCK_SIZE) * BLOCK_SIZE
	local gridZ = math.round(position.Z / BLOCK_SIZE) * BLOCK_SIZE
	
	for _, block in ipairs(blocksFolder:GetChildren()) do
		if SignPlacement.IsSignBlock(block) then
			local blockPos
			if block:IsA("Model") then
				-- For sign models, pivot is at bottom-center (standing) or center (wall)
				-- Use pivot + offset to get approximate grid center
				local pivot = block:GetPivot().Position
				if block:GetAttribute("IsSignStanding") then
					-- Standing signs have pivot at bottom
					blockPos = Vector3.new(pivot.X, pivot.Y + BLOCK_SIZE / 2, pivot.Z)
				else
					-- Wall signs have center pivot
					blockPos = pivot
				end
			elseif block:IsA("BasePart") then
				blockPos = block.Position
			end
			
			if blockPos then
				-- Snap block position to grid
				local blockGridX = math.round(blockPos.X / BLOCK_SIZE) * BLOCK_SIZE
				local blockGridY = math.round(blockPos.Y / BLOCK_SIZE) * BLOCK_SIZE
				local blockGridZ = math.round(blockPos.Z / BLOCK_SIZE) * BLOCK_SIZE
				
				if gridX == blockGridX and gridY == blockGridY and gridZ == blockGridZ then
					if DEBUG_SIGNS then
						print(string.format("[Sign] Found existing sign at grid (%.1f, %.1f, %.1f)",
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

-- Check if placement is valid (no existing sign in grid cell)
function SignPlacement.CanPlaceAt(gridPosition, blocksFolder)
	local existing = SignPlacement.GetSignAtPosition(gridPosition, blocksFolder)
	return existing == nil
end

-- Check if a sign already exists on a specific face of a fence post
-- This allows multiple signs on different faces of the same fence
function SignPlacement.GetSignOnFenceFace(fencePosition, face, blocksFolder)
	if not blocksFolder then return nil end
	
	-- Snap fence position to grid
	local fenceGridX = math.round(fencePosition.X / BLOCK_SIZE) * BLOCK_SIZE
	local fenceGridY = math.round(fencePosition.Y / BLOCK_SIZE) * BLOCK_SIZE
	local fenceGridZ = math.round(fencePosition.Z / BLOCK_SIZE) * BLOCK_SIZE
	
	for _, block in ipairs(blocksFolder:GetChildren()) do
		if block:GetAttribute("IsWallSign") and block:GetAttribute("IsOnFencePost") then
			-- Check if this sign's host matches the fence position
			local hostX = block:GetAttribute("HostBlockX")
			local hostY = block:GetAttribute("HostBlockY")
			local hostZ = block:GetAttribute("HostBlockZ")
			local signFace = block:GetAttribute("SignFace")
			
			if hostX and hostY and hostZ and signFace then
				local hostGridX = math.round(hostX / BLOCK_SIZE) * BLOCK_SIZE
				local hostGridY = math.round(hostY / BLOCK_SIZE) * BLOCK_SIZE
				local hostGridZ = math.round(hostZ / BLOCK_SIZE) * BLOCK_SIZE
				
				-- Check if same fence and same face
				if hostGridX == fenceGridX and hostGridY == fenceGridY and hostGridZ == fenceGridZ then
					if signFace == face then
						if DEBUG_SIGNS then
							print(string.format("[Sign] Found existing sign on fence face %s at (%.1f, %.1f, %.1f)",
								face, fenceGridX, fenceGridY, fenceGridZ))
						end
						return block
					end
				end
			end
		end
	end
	
	return nil
end

-- Get all signs attached to a specific fence post
-- Returns a table of {face, sign} pairs
function SignPlacement.GetAllSignsOnFence(fencePosition, blocksFolder)
	if not blocksFolder then return {} end
	
	local signs = {}
	
	-- Snap fence position to grid
	local fenceGridX = math.round(fencePosition.X / BLOCK_SIZE) * BLOCK_SIZE
	local fenceGridY = math.round(fencePosition.Y / BLOCK_SIZE) * BLOCK_SIZE
	local fenceGridZ = math.round(fencePosition.Z / BLOCK_SIZE) * BLOCK_SIZE
	
	for _, block in ipairs(blocksFolder:GetChildren()) do
		if block:GetAttribute("IsWallSign") and block:GetAttribute("IsOnFencePost") then
			local hostX = block:GetAttribute("HostBlockX")
			local hostY = block:GetAttribute("HostBlockY")
			local hostZ = block:GetAttribute("HostBlockZ")
			local signFace = block:GetAttribute("SignFace")
			
			if hostX and hostY and hostZ and signFace then
				local hostGridX = math.round(hostX / BLOCK_SIZE) * BLOCK_SIZE
				local hostGridY = math.round(hostY / BLOCK_SIZE) * BLOCK_SIZE
				local hostGridZ = math.round(hostZ / BLOCK_SIZE) * BLOCK_SIZE
				
				if hostGridX == fenceGridX and hostGridY == fenceGridY and hostGridZ == fenceGridZ then
					table.insert(signs, {face = signFace, sign = block})
				end
			end
		end
	end
	
	return signs
end

-- Check if a face is compatible with existing signs on a fence
-- Only opposite faces are allowed (N/S or E/W, not adjacent like N/E)
function SignPlacement.IsFaceCompatibleWithExistingSigns(newFace, fencePosition, blocksFolder)
	local existingSigns = SignPlacement.GetAllSignsOnFence(fencePosition, blocksFolder)
	
	if #existingSigns == 0 then
		return true -- No existing signs, any face is OK
	end
	
	-- Define opposite face pairs
	local oppositeFaces = {
		North = "South",
		South = "North",
		East = "West",
		West = "East",
	}
	
	-- Check each existing sign
	for _, signData in ipairs(existingSigns) do
		local existingFace = signData.face
		
		-- Same face = not allowed (handled elsewhere, but check anyway)
		if existingFace == newFace then
			return false
		end
		
		-- Only the opposite face is allowed
		if oppositeFaces[existingFace] ~= newFace then
			-- This is an adjacent face (like N+E), not allowed
			return false
		end
	end
	
	return true
end

-- ============================================
-- PLACEMENT INFO
-- ============================================

-- Get complete placement info for a STANDING SIGN
-- Returns nil if placement is invalid
function SignPlacement.GetStandingSignPlacementInfo(blockId, hitPosition, hitNormal, hitBlockPosition, lookVector, blocksFolder)
	local face = SignPlacement.GetFaceFromNormal(hitNormal)
	
	-- Check if face is valid (top only)
	if not SignPlacement.IsValidFaceForStandingSign(face) then
		if DEBUG_SIGNS then
			print(string.format("[Sign] Standing sign invalid face: %s (must be Top)", face))
		end
		return nil, "Standing signs can only be placed on top of blocks"
	end
	
	-- Find the host block to validate
	local hostBlock = SignPlacement.GetBlockAtPosition(hitBlockPosition, blocksFolder)
	local isValid, errorMsg = SignPlacement.IsValidHostBlock(hostBlock, true)
	if not isValid then
		if DEBUG_SIGNS then
			print("[Sign] Invalid host block: " .. tostring(errorMsg))
		end
		return nil, errorMsg
	end
	
	-- Calculate grid position
	local gridPosition = SignPlacement.GetStandingSignGridPosition(hitBlockPosition)
	
	-- Check if position is already occupied
	if blocksFolder and not SignPlacement.CanPlaceAt(gridPosition, blocksFolder) then
		if DEBUG_SIGNS then
			print(string.format("[Sign] Position already occupied at grid (%.1f, %.1f, %.1f)",
				gridPosition.X, gridPosition.Y, gridPosition.Z))
		end
		return nil, "A block already exists at this position"
	end
	
	-- Calculate rotation from look vector (16 directions)
	local rotation, rotationIndex = SignPlacement.GetStandingSignRotation(lookVector)
	local cframe = SignPlacement.GetStandingSignCFrame(gridPosition, rotation)
	
	if DEBUG_SIGNS then
		print(string.format("[Sign] StandingSign PlacementInfo: face=%s, gridPos=(%.1f, %.1f, %.1f), rotation=%d, index=%d",
			face, gridPosition.X, gridPosition.Y, gridPosition.Z, rotation, rotationIndex))
	end
	
	return {
		face = face,
		gridPosition = gridPosition,
		cframe = cframe,
		rotation = rotation,
		rotationIndex = rotationIndex,
		hostPosition = hitBlockPosition,
		signType = "standing",
		modelName = "SignStanding",
	}, nil
end

-- Get complete placement info for a WALL SIGN
-- Returns nil if placement is invalid
function SignPlacement.GetWallSignPlacementInfo(blockId, hitPosition, hitNormal, hitBlockPosition, blocksFolder)
	local face = SignPlacement.GetFaceFromNormal(hitNormal)
	
	-- Check if face is valid (sides only)
	if not SignPlacement.IsValidFaceForWallSign(face) then
		if DEBUG_SIGNS then
			print(string.format("[Sign] Wall sign invalid face: %s (must be side face)", face))
		end
		return nil, "Wall signs can only be placed on the sides of blocks"
	end
	
	-- Find the host block to validate
	local hostBlock = SignPlacement.GetBlockAtPosition(hitBlockPosition, blocksFolder)
	local isValid, errorMsg = SignPlacement.IsValidHostBlock(hostBlock, false)
	if not isValid then
		if DEBUG_SIGNS then
			print("[Sign] Invalid host block: " .. tostring(errorMsg))
		end
		return nil, errorMsg
	end
	
	-- Check if host is a fence post (for special positioning)
	local isOnFencePost = SignPlacement.IsBlockFence(hostBlock)
	
	-- Calculate grid position
	local gridPosition = SignPlacement.GetWallSignGridPosition(hitBlockPosition, face)
	
	-- Check if position is already occupied
	-- For fence posts, check by face instead of grid position (multiple signs allowed on same fence)
	if blocksFolder then
		if isOnFencePost then
			-- Check if a sign already exists on this face of this fence
			local existingSign = SignPlacement.GetSignOnFenceFace(hitBlockPosition, face, blocksFolder)
			if existingSign then
				if DEBUG_SIGNS then
					print(string.format("[Sign] Fence already has sign on %s face", face))
				end
				return nil, "A sign already exists on this side of the fence"
			end
			
			-- Check if this face is compatible with existing signs (only opposite faces allowed)
			if not SignPlacement.IsFaceCompatibleWithExistingSigns(face, hitBlockPosition, blocksFolder) then
				if DEBUG_SIGNS then
					print(string.format("[Sign] Face %s is not compatible with existing signs (must use opposite faces)", face))
				end
				return nil, "Signs on fence posts can only be placed on opposite sides"
			end
		else
			-- Normal grid-based collision check
			if not SignPlacement.CanPlaceAt(gridPosition, blocksFolder) then
				if DEBUG_SIGNS then
					print(string.format("[Sign] Position already occupied at grid (%.1f, %.1f, %.1f)",
						gridPosition.X, gridPosition.Y, gridPosition.Z))
				end
				return nil, "A block already exists at this position"
			end
		end
	end
	
	-- Calculate rotation from face
	local rotation = SignPlacement.GetWallSignRotation(face)
	local cframe = SignPlacement.GetWallSignCFrame(gridPosition, face, isOnFencePost)
	
	if DEBUG_SIGNS then
		print(string.format("[Sign] WallSign PlacementInfo: face=%s, gridPos=(%.1f, %.1f, %.1f), rotation=%d, onFence=%s",
			face, gridPosition.X, gridPosition.Y, gridPosition.Z, rotation, tostring(isOnFencePost)))
	end
	
	return {
		face = face,
		gridPosition = gridPosition,
		cframe = cframe,
		rotation = rotation,
		hostPosition = hitBlockPosition,
		signType = "wall",
		modelName = "Sign",
		isOnFencePost = isOnFencePost,
	}, nil
end

-- ============================================
-- DEBUG HELPERS
-- ============================================

function SignPlacement.GetFaceName(face)
	return face or "Unknown"
end

function SignPlacement.GetDirectionName(rotationIndex)
	local directions = {
		[0] = "South",
		[1] = "SSW",
		[2] = "SW",
		[3] = "WSW",
		[4] = "West",
		[5] = "WNW",
		[6] = "NW",
		[7] = "NNW",
		[8] = "North",
		[9] = "NNE",
		[10] = "NE",
		[11] = "ENE",
		[12] = "East",
		[13] = "ESE",
		[14] = "SE",
		[15] = "SSE",
	}
	return directions[rotationIndex] or "Unknown"
end

return SignPlacement
