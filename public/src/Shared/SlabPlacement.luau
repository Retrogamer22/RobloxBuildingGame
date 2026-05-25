--[[
	SlabPlacement
	Handles Minecraft-style slab placement based on surface hit and click position
	
	Slab Types:
	- Horizontal Bottom: Slab sits on bottom half of block space
	- Horizontal Top: Slab sits on top half of block space  
	- Vertical: Slab stands vertically against a wall
	
	Placement Logic (side faces use 3x3 grid):
	- Click TOP of block → Bottom slab
	- Click BOTTOM of block → Top slab
	- Click SIDE of block:
	  - Upper third → Top slab
	  - Lower third → Bottom slab
	  - Middle third:
	    - Center → Vertical slab facing you
	    - Left edge → Vertical slab on left wall
	    - Right edge → Vertical slab on right wall
]]

local BLOCK_SIZE = 3
local SLAB_HEIGHT = BLOCK_SIZE / 2 -- 1.5
local HALF_SLAB = SLAB_HEIGHT / 2  -- 0.75 (distance from slab center to edge)
local THIRD_BLOCK = BLOCK_SIZE / 3 -- 1.0 (zone size)

-- Debug logging (throttled)
local DEBUG_SLAB = false
local lastDebugTime = 0
local DEBUG_INTERVAL = 2 -- seconds

local function debugLog(...)
	if not DEBUG_SLAB then return end
	local now = tick()
	if now - lastDebugTime < DEBUG_INTERVAL then return end
	lastDebugTime = now
	print("[SlabDebug]", ...)
end

local SlabPlacement = {}

-- Check if a block type is a slab
function SlabPlacement.IsSlab(blockId: string): boolean
	if not blockId then return false end
	return string.find(blockId, "Slab") ~= nil
end

-- Slab orientation types
SlabPlacement.Orientation = {
	BOTTOM = "bottom",     -- Horizontal, bottom half
	TOP = "top",           -- Horizontal, top half
	NORTH = "north",       -- Vertical, on south wall facing north (-Z)
	SOUTH = "south",       -- Vertical, on north wall facing south (+Z)
	EAST = "east",         -- Vertical, on west wall facing east (+X)
	WEST = "west",         -- Vertical, on east wall facing west (-X)
}

-- Get vertical zone (upper/middle/lower third)
local function getVerticalZone(hitPosition: Vector3, blockPosition: Vector3): string
	local relativeY = hitPosition.Y - blockPosition.Y
	
	if relativeY > THIRD_BLOCK / 2 then
		return "upper"
	elseif relativeY < -THIRD_BLOCK / 2 then
		return "lower"
	else
		return "middle"
	end
end

-- Get horizontal zone (left/center/right third) relative to the face being looked at
local function getHorizontalZone(hitPosition: Vector3, blockPosition: Vector3, hitNormal: Vector3): string
	local absNormalX = math.abs(hitNormal.X)
	local absNormalZ = math.abs(hitNormal.Z)
	
	local horizontalOffset
	
	if absNormalX > absNormalZ then
		-- Face is perpendicular to X axis, horizontal direction on face is Z
		horizontalOffset = hitPosition.Z - blockPosition.Z
		-- When looking at +X face (from -X side), +Z is to your left, -Z is to your right
		-- When looking at -X face (from +X side), -Z is to your left, +Z is to your right
		if hitNormal.X > 0 then
			horizontalOffset = -horizontalOffset -- Flip for +X face
		end
	else
		-- Face is perpendicular to Z axis, horizontal direction on face is X
		horizontalOffset = hitPosition.X - blockPosition.X
		-- When looking at +Z face (from -Z side), -X is to your left, +X is to your right
		-- When looking at -Z face (from +Z side), +X is to your left, -X is to your right
		if hitNormal.Z < 0 then
			horizontalOffset = -horizontalOffset -- Flip for -Z face
		end
	end
	
	if horizontalOffset > THIRD_BLOCK / 2 then
		return "right"
	elseif horizontalOffset < -THIRD_BLOCK / 2 then
		return "left"
	else
		return "center"
	end
end

-- Get vertical slab direction from surface normal (for center of face)
local function getVerticalDirectionFromNormal(normal: Vector3): string
	local absX = math.abs(normal.X)
	local absZ = math.abs(normal.Z)
	
	if absX > absZ then
		if normal.X > 0 then
			return SlabPlacement.Orientation.EAST
		else
			return SlabPlacement.Orientation.WEST
		end
	else
		if normal.Z > 0 then
			return SlabPlacement.Orientation.SOUTH
		else
			return SlabPlacement.Orientation.NORTH
		end
	end
end

-- Get vertical slab direction for left/right zones on a face
local function getVerticalDirectionForSide(hitNormal: Vector3, side: string): string
	local absNormalX = math.abs(hitNormal.X)
	local absNormalZ = math.abs(hitNormal.Z)
	
	if absNormalX > absNormalZ then
		-- Looking at ±X face, left/right walls are on Z axis
		if hitNormal.X > 0 then
			-- Looking at +X face
			return side == "left" and SlabPlacement.Orientation.NORTH or SlabPlacement.Orientation.SOUTH
		else
			-- Looking at -X face
			return side == "left" and SlabPlacement.Orientation.SOUTH or SlabPlacement.Orientation.NORTH
		end
	else
		-- Looking at ±Z face, left/right walls are on X axis
		if hitNormal.Z > 0 then
			-- Looking at +Z face
			return side == "left" and SlabPlacement.Orientation.WEST or SlabPlacement.Orientation.EAST
		else
			-- Looking at -Z face
			return side == "left" and SlabPlacement.Orientation.EAST or SlabPlacement.Orientation.WEST
		end
	end
end

-- Determine slab orientation based on placement context
function SlabPlacement.GetOrientation(
	hitPosition: Vector3,
	hitNormal: Vector3,
	hitBlockPosition: Vector3,
	lookVector: Vector3,
	forceVertical: boolean?
): string
	local absNormalX = math.abs(hitNormal.X)
	local absNormalY = math.abs(hitNormal.Y)
	local absNormalZ = math.abs(hitNormal.Z)
	
	-- Clicking on TOP face (normal pointing up)
	if absNormalY > 0.7 and hitNormal.Y > 0 then
		if forceVertical then
			-- Place vertical slab based on WHERE on the top face the crosshair is pointing
			-- If crosshair is on +Z half of face, slab goes on +Z edge
			-- If crosshair is on -Z half of face, slab goes on -Z edge
			local relativeX = hitPosition.X - hitBlockPosition.X
			local relativeZ = hitPosition.Z - hitBlockPosition.Z
			local absRelX = math.abs(relativeX)
			local absRelZ = math.abs(relativeZ)
			
			local orientation
			if absRelX > absRelZ then
				-- Crosshair is more toward X edge
				if relativeX > 0 then
					orientation = SlabPlacement.Orientation.WEST -- slab on +X edge, faces -X
				else
					orientation = SlabPlacement.Orientation.EAST -- slab on -X edge, faces +X
				end
			else
				-- Crosshair is more toward Z edge
				if relativeZ > 0 then
					orientation = SlabPlacement.Orientation.NORTH -- slab on +Z edge, faces -Z
				else
					orientation = SlabPlacement.Orientation.SOUTH -- slab on -Z edge, faces +Z
				end
			end
			
			debugLog(string.format(
				"TOP face + forceVertical | hitRel=(%.2f, %.2f) | absX=%.2f absZ=%.2f | orientation=%s",
				relativeX, relativeZ,
				absRelX, absRelZ,
				orientation
			))
			
			return orientation
		end
		return SlabPlacement.Orientation.BOTTOM
	end
	
	-- Clicking on BOTTOM face (normal pointing down)
	if absNormalY > 0.7 and hitNormal.Y < 0 then
		if forceVertical then
			-- Same logic as TOP face - use crosshair position on face
			local relativeX = hitPosition.X - hitBlockPosition.X
			local relativeZ = hitPosition.Z - hitBlockPosition.Z
			local absRelX = math.abs(relativeX)
			local absRelZ = math.abs(relativeZ)
			
			if absRelX > absRelZ then
				if relativeX > 0 then
					return SlabPlacement.Orientation.WEST
				else
					return SlabPlacement.Orientation.EAST
				end
			else
				if relativeZ > 0 then
					return SlabPlacement.Orientation.NORTH
				else
					return SlabPlacement.Orientation.SOUTH
				end
			end
		end
		return SlabPlacement.Orientation.TOP
	end
	
	-- Clicking on a SIDE face - use 3x3 grid zones
	local vertZone = getVerticalZone(hitPosition, hitBlockPosition)
	local horizZone = getHorizontalZone(hitPosition, hitBlockPosition, hitNormal)
	
	-- Force vertical overrides everything
	if forceVertical then
		if horizZone == "left" then
			return getVerticalDirectionForSide(hitNormal, "left")
		elseif horizZone == "right" then
			return getVerticalDirectionForSide(hitNormal, "right")
		else
			return getVerticalDirectionFromNormal(hitNormal)
		end
	end
	
	-- Upper third → Top slab
	if vertZone == "upper" then
		return SlabPlacement.Orientation.TOP
	end
	
	-- Lower third → Bottom slab
	if vertZone == "lower" then
		return SlabPlacement.Orientation.BOTTOM
	end
	
	-- Middle third - check horizontal zone
	if horizZone == "left" then
		return getVerticalDirectionForSide(hitNormal, "left")
	elseif horizZone == "right" then
		return getVerticalDirectionForSide(hitNormal, "right")
	else
		-- Middle-center → vertical slab facing you
		return getVerticalDirectionFromNormal(hitNormal)
	end
end

-- Check if orientation is vertical
function SlabPlacement.IsVertical(orientation: string): boolean
	return orientation == SlabPlacement.Orientation.NORTH
		or orientation == SlabPlacement.Orientation.SOUTH
		or orientation == SlabPlacement.Orientation.EAST
		or orientation == SlabPlacement.Orientation.WEST
end

-- Get the CFrame rotation for a slab orientation
function SlabPlacement.GetRotationForOrientation(orientation: string): CFrame
	if orientation == SlabPlacement.Orientation.BOTTOM then
		return CFrame.new()
	elseif orientation == SlabPlacement.Orientation.TOP then
		return CFrame.new()
	elseif orientation == SlabPlacement.Orientation.NORTH then
		return CFrame.Angles(math.rad(90), 0, 0)
	elseif orientation == SlabPlacement.Orientation.SOUTH then
		return CFrame.Angles(math.rad(-90), 0, 0)
	elseif orientation == SlabPlacement.Orientation.EAST then
		-- Rotate Y to face +X, then tip forward
		return CFrame.Angles(0, math.rad(-90), 0) * CFrame.Angles(math.rad(90), 0, 0)
	elseif orientation == SlabPlacement.Orientation.WEST then
		-- Rotate Y to face -X, then tip forward
		return CFrame.Angles(0, math.rad(90), 0) * CFrame.Angles(math.rad(90), 0, 0)
	end
	return CFrame.new()
end

-- Get the position offset for a slab based on orientation
-- The offset positions the slab flush against the wall it's attached to
function SlabPlacement.GetPositionOffset(orientation: string): Vector3
	local offset
	if orientation == SlabPlacement.Orientation.BOTTOM then
		offset = Vector3.new(0, -HALF_SLAB, 0)  -- Bottom of cell
	elseif orientation == SlabPlacement.Orientation.TOP then
		offset = Vector3.new(0, HALF_SLAB, 0)   -- Top of cell
	elseif orientation == SlabPlacement.Orientation.NORTH then
		-- Slab faces north (-Z), positioned at +Z edge (so it faces toward -Z)
		offset = Vector3.new(0, 0, HALF_SLAB)
	elseif orientation == SlabPlacement.Orientation.SOUTH then
		-- Slab faces south (+Z), positioned at -Z edge (so it faces toward +Z)
		offset = Vector3.new(0, 0, -HALF_SLAB)
	elseif orientation == SlabPlacement.Orientation.EAST then
		-- Slab faces east (+X), positioned at -X edge (so it faces toward +X)
		offset = Vector3.new(-HALF_SLAB, 0, 0)
	elseif orientation == SlabPlacement.Orientation.WEST then
		-- Slab faces west (-X), positioned at +X edge (so it faces toward -X)
		offset = Vector3.new(HALF_SLAB, 0, 0)
	else
		offset = Vector3.new(0, 0, 0)
	end
	
	debugLog(string.format(
		"GetPositionOffset | orientation=%s | offset=(%.2f, %.2f, %.2f)",
		orientation,
		offset.X, offset.Y, offset.Z
	))
	
	return offset
end

-- Get the full CFrame for slab placement
function SlabPlacement.GetSlabCFrame(gridPosition: Vector3, orientation: string): CFrame
	local offset = SlabPlacement.GetPositionOffset(orientation)
	local rotation = SlabPlacement.GetRotationForOrientation(orientation)
	local position = gridPosition + offset
	
	return CFrame.new(position) * rotation
end

-- Get orientation name for display/debugging
function SlabPlacement.GetOrientationName(orientation: string): string
	local names = {
		[SlabPlacement.Orientation.BOTTOM] = "Bottom",
		[SlabPlacement.Orientation.TOP] = "Top",
		[SlabPlacement.Orientation.NORTH] = "Vertical North",
		[SlabPlacement.Orientation.SOUTH] = "Vertical South",
		[SlabPlacement.Orientation.EAST] = "Vertical East",
		[SlabPlacement.Orientation.WEST] = "Vertical West",
	}
	return names[orientation] or "Unknown"
end

return SlabPlacement
