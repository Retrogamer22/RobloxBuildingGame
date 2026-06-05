--[[
	WallpaperPlacement
	Handles placement of WallpaperFrame blocks on any face of solid blocks
	These are ultra-thin (0.001) frame blocks that snap to block surfaces
	Can be placed on: all 6 faces of solid blocks, stair bottom face, and stair back wall
	Multiple wallpapers can overlap at inner corners (no wallpaper-wallpaper collision)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BLOCK_SIZE = 3
local WALLPAPER_THICKNESS = 0.001

local WallpaperPlacement = {}

-- ============================================
-- DETECTION
-- ============================================

function WallpaperPlacement.IsWallpaperFrame(blockId)
	if not blockId or type(blockId) ~= "string" then return false end
	return blockId == "WallpaperFrame"
end

function WallpaperPlacement.IsWallpaperFrameInstance(block)
	if not block then return false end
	return block:GetAttribute("IsWallpaperFrame") == true
end

-- ============================================
-- FACE DETECTION
-- ============================================

-- Get the face from a raycast normal
function WallpaperPlacement.GetFaceFromNormal(normal)
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

-- ============================================
-- HOST BLOCK VALIDATION
-- ============================================

-- Check if the hit block is a valid host for wallpaper placement
-- Returns true and the face, or false
function WallpaperPlacement.IsValidHost(hitBlock, face)
	if not hitBlock then return false end
	
	-- Check if it's a stair - allow Bottom face and the back wall face
	local blockType = hitBlock:GetAttribute("BlockType") or ""
	local shape = hitBlock:GetAttribute("Shape")
	local isStair = string.find(blockType, "Stair") ~= nil 
		or shape == "Stair"
		or hitBlock:GetAttribute("IsStair") == true
	
	if isStair then
		if face == "Bottom" then
			return true
		end
		
		-- Allow the back wall face (the tall flat side opposite the open/stepped side)
		-- Stair direction = where the open side faces; back wall is opposite
		local stairDir = hitBlock:GetAttribute("StairDirection")
		if stairDir == nil then
			local rotation = hitBlock:GetAttribute("Rotation") or 0
			-- Convert rotation to direction (matching StairPlacement logic)
			local norm = rotation % 360
			if norm < 0 then norm = norm + 360 end
			if norm >= 315 or norm < 45 then
				stairDir = 3   -- WEST
			elseif norm >= 45 and norm < 135 then
				stairDir = 0   -- NORTH
			elseif norm >= 135 and norm < 225 then
				stairDir = 1   -- EAST
			else
				stairDir = 2   -- SOUTH
			end
		end
		
		-- Map stair direction to the back wall (tall flat solid side, opposite the
		-- stepped/open side). Verified against live StairDirection values: e.g. dir 2
		-- has its solid back on the -Z (North) face. The previous table was 180 deg
		-- off, which silently rejected the real back wall on every orientation.
		-- Dir 0: back wall = "South" (+Z)
		-- Dir 1: back wall = "East"  (+X)
		-- Dir 2: back wall = "North" (-Z)
		-- Dir 3: back wall = "West"  (-X)
		local backWallFaces = {
			[0] = "South",
			[1] = "East",
			[2] = "North",
			[3] = "West",
		}
		local backFace = backWallFaces[stairDir]
		return face == backFace
	end
	
	-- Reject non-solid blocks (decorations, fences, glass, etc.)
	-- We want full solid blocks, slabs (top/bottom faces), etc.
	if hitBlock:GetAttribute("IsDecoration") then return false end
	if hitBlock:GetAttribute("IsFence") then return false end
	if hitBlock:GetAttribute("IsGlass") then return false end
	if hitBlock:GetAttribute("IsTorch") then return false end
	if hitBlock:GetAttribute("IsCampfire") then return false end
	if hitBlock:GetAttribute("IsLantern") then return false end
	if hitBlock:GetAttribute("IsLadder") then return false end
	if hitBlock:GetAttribute("IsWallpaperFrame") then return false end
	if hitBlock:GetAttribute("IsDoor") then return false end
	
	-- Surface blocks (buttons, pressure plates) aren't valid hosts
	local bt = hitBlock:GetAttribute("BlockType") or ""
	if string.find(bt, "Button") or string.find(bt, "PressurePlate") then return false end
	if string.find(bt, "Sign") then return false end
	
	-- Slabs are valid hosts
	-- Snow layers are not valid hosts
	if bt == "SnowLayer" or bt == "Snow" or bt == "SnowBlock" then return false end
	
	return true
end

-- ============================================
-- CFRAME CALCULATION
-- ============================================

--[[
	WallpaperFrame placement uses explicit per-face rotations.
	Model default: vertical panel, thin in Z, decorative face pointing -Z
	
	Position: flush against the host block surface, offset by half thickness outward
	Rotation: model's -Z (front face) points outward along the face normal
]]

-- Face normals (pointing outward from the host block)
local FACE_NORMALS = {
	Top = Vector3.new(0, 1, 0),
	Bottom = Vector3.new(0, -1, 0),
	North = Vector3.new(0, 0, -1),
	South = Vector3.new(0, 0, 1),
	East = Vector3.new(1, 0, 0),
	West = Vector3.new(-1, 0, 0),
}

-- Explicit rotation for each face
-- Assumes model default: vertical panel, thin in Z, front face = -Z, up = +Y
-- Wall faces: rotate around Y so -Z points outward, model stays upright
-- Top/Bottom: tilt around X so -Z points up/down
-- Each rotation orients the panel to the face, then spins 90° around the face normal (local Z)
local SPIN = CFrame.Angles(0, math.pi / 2, 0)
local FACE_ROTATIONS = {
	North = CFrame.Angles(0, 0, 0) * SPIN,
	South = CFrame.Angles(0, math.pi, 0) * SPIN,
	East  = CFrame.Angles(0, -math.pi / 2, 0) * SPIN,
	West  = CFrame.Angles(0, math.pi / 2, 0) * SPIN,
	Top   = CFrame.Angles(-math.pi / 2, 0, 0) * SPIN,
	Bottom = CFrame.Angles(math.pi / 2, 0, 0) * SPIN,
}

function WallpaperPlacement.GetWallpaperCFrame(hostBlockPosition, face)
	local halfBlock = BLOCK_SIZE / 2
	local halfThickness = WALLPAPER_THICKNESS / 2
	
	local normal = FACE_NORMALS[face] or FACE_NORMALS.Top
	local position = hostBlockPosition + normal * (halfBlock + halfThickness)
	local rotation = FACE_ROTATIONS[face] or FACE_ROTATIONS.Top
	
	return CFrame.new(position) * rotation
end

-- ============================================
-- PLACEMENT INFO
-- ============================================

-- Get full placement info from raycast data
-- hitBlock: the block instance that was hit
-- hitPosition: world position of the raycast hit
-- hitNormal: surface normal at the hit point
-- hitBlockPosition: grid center of the host block
function WallpaperPlacement.GetPlacementInfo(hitBlock, hitPosition, hitNormal, hitBlockPosition)
	local face = WallpaperPlacement.GetFaceFromNormal(hitNormal)
	
	-- [BB-WPDEBUG] TEMP diagnostic for wallpaper-on-stair placement. Remove after fix.
	local _valid = WallpaperPlacement.IsValidHost(hitBlock, face)
	print(string.format("[BB-WPDEBUG] host=%s type=%s shape=%s isStairAttr=%s stairDir=%s rot=%s normal=(%.3f,%.3f,%.3f) face=%s valid=%s",
		hitBlock and hitBlock.Name or "nil",
		tostring(hitBlock and hitBlock:GetAttribute("BlockType")),
		tostring(hitBlock and hitBlock:GetAttribute("Shape")),
		tostring(hitBlock and hitBlock:GetAttribute("IsStair")),
		tostring(hitBlock and hitBlock:GetAttribute("StairDirection")),
		tostring(hitBlock and hitBlock:GetAttribute("Rotation")),
		hitNormal.X, hitNormal.Y, hitNormal.Z,
		tostring(face), tostring(_valid)))
	
	-- Validate the host block
	if not _valid then
		return nil
	end
	
	-- For Top face on models (like GrassBlock), use hit position Y to find true surface
	local adjustedHostPosition = hitBlockPosition
	if face == "Top" then
		local halfBlock = BLOCK_SIZE / 2
		adjustedHostPosition = Vector3.new(
			hitBlockPosition.X,
			hitPosition.Y - halfBlock,
			hitBlockPosition.Z
		)
	end
	
	local cframe = WallpaperPlacement.GetWallpaperCFrame(adjustedHostPosition, face)
	
	return {
		face = face,
		hostPosition = adjustedHostPosition,
		cframe = cframe,
		position = cframe.Position,
	}
end

return WallpaperPlacement
