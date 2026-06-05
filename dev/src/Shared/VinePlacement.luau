--[[
	VinePlacement
	Handles placement of vine blocks on the side faces of blocks
	Vines are 0.01 studs thick, 3x3, with pivot in the center
	
	Rules:
	- Vines can only attach to side faces (North, South, East, West)
	- One vine per grid position
	- Vine faces outward from the block it's attached to
	- Placed in the adjacent grid cell, flush against the host block
	
	Model orientation:
	- The Vine union is oriented with front face facing -Z (North) by default
	- Pivot is in the dead center of the 3x3x0.01 part
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VinePlacement = {}

-- ============================================
-- CONFIGURATION
-- ============================================

local BLOCK_SIZE = 3
local VINE_THICKNESS = 0.01

local DEBUG_VINES = false

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
-- VINE TYPE DETECTION
-- ============================================

function VinePlacement.IsVine(blockId)
	if not blockId then return false end
	return blockId == "Vine" or blockId == "VineTrimmed" or blockId == "VineTrimmedEnd"
		or blockId == "VineHalf"
end

-- Returns true ONLY for the half-height vine variant (used when the host face only
-- has material in its bottom half, e.g. a bottom slab or the open front of a stair).
function VinePlacement.IsVineHalf(blockId)
	if not blockId then return false end
	return blockId == "VineHalf"
end

function VinePlacement.IsVineHalfInstance(block)
	if not block then return false end
	return block:GetAttribute("IsVineHalf") == true
end

-- Returns true ONLY if the vine is trimmed (won't spread, blocks further growth).
function VinePlacement.IsVineTrimmed(blockId)
	if not blockId then return false end
	return blockId == "VineTrimmed" or blockId == "VineTrimmedEnd"
end

function VinePlacement.IsVineInstance(block)
	if not block then return false end
	return block:GetAttribute("IsVine") == true
end

-- Returns true if this vine instance is a trimmed (growth-stopped) variant.
function VinePlacement.IsVineTrimmedInstance(block)
	if not block then return false end
	return block:GetAttribute("IsVineTrimmed") == true
end

-- ============================================
-- FACE DETECTION
-- ============================================

function VinePlacement.GetFaceFromNormal(normal)
	local absX = math.abs(normal.X)
	local absY = math.abs(normal.Y)
	local absZ = math.abs(normal.Z)
	
	if absY > absX and absY > absZ then
		return normal.Y > 0 and "Top" or "Bottom"
	elseif absX > absZ then
		return normal.X > 0 and "East" or "West"
	else
		return normal.Z > 0 and "South" or "North"
	end
end

function VinePlacement.IsValidFace(face)
	return face == "North" or face == "South" or face == "East" or face == "West"
end

-- ============================================
-- ROTATION CALCULATION
-- ============================================

-- Vine model default: front face facing -Z (North)
-- Rotate so vine faces outward from the wall
function VinePlacement.GetVineRotation(face)
	if face == "North" then
		return 180 -- Attached to North face, vine faces South (+Z)
	elseif face == "South" then
		return 0   -- Attached to South face, vine faces North (-Z)
	elseif face == "East" then
		return 90  -- Attached to East face, vine faces West (-X)
	elseif face == "West" then
		return -90 -- Attached to West face, vine faces East (+X)
	end
	return 0
end

-- ============================================
-- POSITION CALCULATION
-- ============================================

-- Get the grid position for the vine (occupies adjacent cell)
function VinePlacement.GetVineGridPosition(hostBlockPosition, face)
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

-- Get the face direction as a Vector3 offset (pointing from host into vine cell)
function VinePlacement.GetFaceOffset(face)
	if face == "North" then return Vector3.new(0, 0, -1)
	elseif face == "South" then return Vector3.new(0, 0, 1)
	elseif face == "East" then return Vector3.new(1, 0, 0)
	elseif face == "West" then return Vector3.new(-1, 0, 0)
	end
	return Vector3.new(0, 0, 0)
end

-- Get opposite face
function VinePlacement.GetOppositeFace(face)
	if face == "North" then return "South"
	elseif face == "South" then return "North"
	elseif face == "East" then return "West"
	elseif face == "West" then return "East"
	end
	return face
end

-- Get CFrame for vine placement (flush against the host block).
-- `flipped` (optional) rotates the model 180° around the wall's face-perpendicular
-- axis so the model appears upside-down — used for the TOP of a trimmed vine chain
-- (so VineTrimmedEnd's ragged end points up instead of down).
function VinePlacement.GetVineCFrame(gridPosition, face, flipped)
	local rotation = VinePlacement.GetVineRotation(face)
	
	-- Push vine flush against the wall
	local wallOffset = BLOCK_SIZE / 2 - VINE_THICKNESS / 2
	local positionOffset = Vector3.new(0, 0, 0)
	
	if face == "North" then
		positionOffset = Vector3.new(0, 0, wallOffset)
	elseif face == "South" then
		positionOffset = Vector3.new(0, 0, -wallOffset)
	elseif face == "East" then
		positionOffset = Vector3.new(-wallOffset, 0, 0)
	elseif face == "West" then
		positionOffset = Vector3.new(wallOffset, 0, 0)
	end
	
	local finalPosition = gridPosition + positionOffset
	
	if DEBUG_VINES then
		print(string.format("[Vine] CFrame: grid=(%.1f, %.1f, %.1f), face=%s, rotation=%d, flipped=%s",
			gridPosition.X, gridPosition.Y, gridPosition.Z, face, rotation, tostring(flipped)))
	end
	
	local yRotation = CFrame.Angles(0, math.rad(rotation), 0)
	
	if flipped then
		-- Flip 180° around the world-space axis that is perpendicular to the wall.
		-- This rotation, when composed BEFORE the Y rotation, flips world-Y (top/bottom)
		-- while preserving the outward-facing direction (front of the vine still faces
		-- the same direction).
		--   N/S vines (wall in XY plane, face-perpendicular axis = world Z) → rotate around Z
		--   E/W vines (wall in YZ plane, face-perpendicular axis = world X) → rotate around X
		local flipRotation
		if face == "North" or face == "South" then
			flipRotation = CFrame.Angles(0, 0, math.rad(180))
		else -- East or West
			flipRotation = CFrame.Angles(math.rad(180), 0, 0)
		end
		return CFrame.new(finalPosition) * flipRotation * yRotation
	end
	
	return CFrame.new(finalPosition) * yRotation
end

-- Distance the half-vine is dropped from the cell center so its 1.5-stud-tall
-- geometry sits flush in the BOTTOM half of the cell. The VineHalf model's pivot
-- is at its own center, so a -0.75 world-Y shift bottom-aligns it.
local VINE_HALF_DROP = BLOCK_SIZE / 4 -- 0.75

-- Same as GetVineCFrame, but lowered so the half-height vine fills the bottom half
-- of the cell (matching a bottom slab / open stair front host).
function VinePlacement.GetVineHalfCFrame(gridPosition, face, flipped)
	local base = VinePlacement.GetVineCFrame(gridPosition, face, flipped)
	return base + Vector3.new(0, -VINE_HALF_DROP, 0)
end

-- ============================================
-- HALF-HOST DETECTION
-- ============================================

-- Convention-free geometry probe: is the host's TOP half empty just behind the vine
-- face? Raycasts the host's actual geometry, so it works for stairs (open front),
-- slabs, and any partial block without relying on orientation attributes. The probe
-- is shallow so a stair's set-back top step (at the BACK) doesn't count as "solid"
-- behind the FRONT face.
local function hostTopHalfEmpty(hostBlock, face, vineGridPosition)
	if not vineGridPosition then return false end
	local faceOut = VinePlacement.GetFaceOffset(face) -- host outward normal on this face
	if faceOut.Magnitude < 0.5 then return false end

	local hostCenter = vineGridPosition - faceOut * BLOCK_SIZE
	-- Start just outside the face, centered in the TOP half; cast a short distance in.
	local rayStart = hostCenter + faceOut * (BLOCK_SIZE / 2 + 0.1) + Vector3.new(0, BLOCK_SIZE / 4, 0)
	local rayDir = -faceOut * 0.85

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { hostBlock }
	params.IgnoreWater = true

	return workspace:Raycast(rayStart, rayDir, params) == nil
end

-- Returns true if the host face the vine attaches to only has material in its BOTTOM
-- half, so the vine has nothing in the top half to "grab" onto (bottom slab, open
-- stair front, etc.). Top slabs / upside-down stairs are top-half-only and correctly
-- do NOT match (their top half is solid, so the probe hits).
function VinePlacement.HostIsBottomHalfOnly(hostBlock, face, vineGridPosition)
	if not hostBlock or not face then return false end

	-- Fast path: a bottom slab is always bottom-half-only.
	if hostBlock:GetAttribute("SlabOrientation") == "bottom" then
		return true
	end

	-- General case: probe the host's real geometry (needs the vine's grid position).
	return hostTopHalfEmpty(hostBlock, face, vineGridPosition)
end

-- Find the solid host block a vine at `vineGridPosition` is attached to on `face`.
-- The host sits one cell behind the vine (opposite the outward face direction).
function VinePlacement.GetHostBlock(vineGridPosition, face, blocksFolder)
	if not blocksFolder then return nil end
	local hostPos = vineGridPosition - VinePlacement.GetFaceOffset(face) * BLOCK_SIZE

	local index = getSpatialIndex(blocksFolder)
	local candidates = index and index:GetBlocksAt(hostPos) or blocksFolder:GetChildren()
	for _, block in ipairs(candidates) do
		if block:GetAttribute("IsVine") then continue end
		if block:GetAttribute("IsDecoration") then continue end
		return block
	end
	return nil
end

-- Resolve which vine variant belongs at a position given its host's shape.
-- Returns ("VineHalf" | "Vine"), hostBlock. Only meaningful for non-trimmed vines.
function VinePlacement.ResolveVineType(vineGridPosition, face, blocksFolder)
	local host = VinePlacement.GetHostBlock(vineGridPosition, face, blocksFolder)
	if host and VinePlacement.HostIsBottomHalfOnly(host, face, vineGridPosition) then
		return "VineHalf", host
	end
	return "Vine", host
end

-- ============================================
-- COLLISION / EXISTENCE CHECK
-- ============================================

function VinePlacement.GetVineAtPosition(position, blocksFolder)
	if not blocksFolder then return nil end
	
	local index = getSpatialIndex(blocksFolder)
	local candidates = index and index:GetBlocksAt(position) or blocksFolder:GetChildren()
	
	for _, block in ipairs(candidates) do
		if VinePlacement.IsVineInstance(block) then
			local blockPos
			local bpx = block:GetAttribute("BlockPosX")
			local bpy = block:GetAttribute("BlockPosY")
			local bpz = block:GetAttribute("BlockPosZ")
			if bpx and bpy and bpz then
				blockPos = Vector3.new(bpx, bpy, bpz)
			elseif block:IsA("BasePart") then
				blockPos = block:GetPivot().Position
			elseif block:IsA("Model") then
				blockPos = block:GetPivot().Position
			end
			
			if blockPos then
				local gridX = math.round(position.X / BLOCK_SIZE) * BLOCK_SIZE
				local gridY = math.round(position.Y / BLOCK_SIZE) * BLOCK_SIZE
				local gridZ = math.round(position.Z / BLOCK_SIZE) * BLOCK_SIZE
				
				local blockGridX = math.round(blockPos.X / BLOCK_SIZE) * BLOCK_SIZE
				local blockGridY = math.round(blockPos.Y / BLOCK_SIZE) * BLOCK_SIZE
				local blockGridZ = math.round(blockPos.Z / BLOCK_SIZE) * BLOCK_SIZE
				
				if gridX == blockGridX and gridY == blockGridY and gridZ == blockGridZ then
					return {
						instance = block,
						blockType = block:GetAttribute("BlockType"),
						position = blockPos,
						face = block:GetAttribute("VineFace") or "North",
					}
				end
			end
		end
	end
	
	return nil
end

-- Check if any non-trivial block exists at position (for spread-stop detection)
function VinePlacement.HasAnyBlockAt(position, blocksFolder)
	if not blocksFolder then return false end
	
	local index = getSpatialIndex(blocksFolder)
	if index then
		local blocks = index:GetBlocksAt(position)
		for _, block in ipairs(blocks) do
			if not block:GetAttribute("IsDecoration")
				and not block:GetAttribute("IsTorch")
				and not block:GetAttribute("IsLantern") then
				return true
			end
		end
	end
	return false
end

-- Check if a solid block exists at position (for vine host validation)
function VinePlacement.HasSolidBlockAt(position, blocksFolder)
	if not blocksFolder then return false end
	
	local index = getSpatialIndex(blocksFolder)
	if index then
		local blocks = index:GetBlocksAt(position)
		for _, block in ipairs(blocks) do
			if block:GetAttribute("IsDecoration") then continue end
			if block:GetAttribute("IsTorch") then continue end
			if block:GetAttribute("IsLantern") then continue end
			if block:GetAttribute("IsLadder") then continue end
			if block:GetAttribute("IsVine") then continue end
			if block:GetAttribute("IsWallpaperFrame") then continue end
			if block:GetAttribute("IsCarpet") then continue end
			if block:GetAttribute("IsCampfire") then continue end
			local bt = block:GetAttribute("BlockType") or ""
			if string.find(bt, "Button") or string.find(bt, "PressurePlate") then continue end
			if string.find(bt, "Sign") then continue end
			return true
		end
	end
	return false
end

function VinePlacement.CanPlaceAt(gridPosition, blocksFolder)
	local existing = VinePlacement.GetVineAtPosition(gridPosition, blocksFolder)
	return existing == nil
end

-- ============================================
-- PLACEMENT INFO
-- ============================================

function VinePlacement.GetPlacementInfo(blockId, hitPosition, hitNormal, hitBlockPosition, blocksFolder)
	local face = VinePlacement.GetFaceFromNormal(hitNormal)
	
	if not VinePlacement.IsValidFace(face) then
		if DEBUG_VINES then
			print(string.format("[Vine] Invalid face: %s (must be side face)", face))
		end
		return nil, "Vines can only be placed on the sides of blocks"
	end
	
	local gridPosition = VinePlacement.GetVineGridPosition(hitBlockPosition, face)
	
	if blocksFolder and not VinePlacement.CanPlaceAt(gridPosition, blocksFolder) then
		if DEBUG_VINES then
			print(string.format("[Vine] Position already occupied at grid (%.1f, %.1f, %.1f)",
				gridPosition.X, gridPosition.Y, gridPosition.Z))
		end
		return nil, "A block already exists at this position"
	end
	
	local cframe = VinePlacement.GetVineCFrame(gridPosition, face)
	local rotation = VinePlacement.GetVineRotation(face)
	
	return {
		face = face,
		gridPosition = gridPosition,
		cframe = cframe,
		rotation = rotation,
		hostPosition = hitBlockPosition,
	}, nil
end

-- ============================================
-- CONSTANTS
-- ============================================

VinePlacement.VINE_THICKNESS = VINE_THICKNESS
VinePlacement.BLOCK_SIZE = BLOCK_SIZE

return VinePlacement
