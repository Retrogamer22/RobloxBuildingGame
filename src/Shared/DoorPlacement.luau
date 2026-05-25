--[[
	DoorPlacement
	Handles Minecraft-style door placement:
	- Depth-based placement (front/middle/back of block based on click position)
	- Orientation based on camera look direction
	- Door occupies 2 vertical blocks (bottom and top halves)
	
	Depth Placement:
	- Click front third of face → Door at front of placement cell
	- Click middle third → Door at middle
	- Click back third → Door at back
	
	The depth is measured ALONG the face normal (how deep into the block space)
]]

local BLOCK_SIZE = 3
local DOOR_THICKNESS = 0.3 -- Thin door
local THIRD_BLOCK = BLOCK_SIZE / 3

local DoorPlacement = {}

-- Door depth positions within a block cell
DoorPlacement.Depth = {
	FRONT = "front",   -- Closest to you when placing
	MIDDLE = "middle", -- Center of block
	BACK = "back",     -- Furthest from you
}

-- Door facing directions (which way you face when walking through)
DoorPlacement.Direction = {
	NORTH = 0,  -- Facing -Z
	EAST = 1,   -- Facing +X
	SOUTH = 2,  -- Facing +Z
	WEST = 3,   -- Facing -X
}

-- Door hinge side (which side the hinge is on when looking at the door)
DoorPlacement.HingeSide = {
	LEFT = "left",
	RIGHT = "right",
}

-- Check if a block type is a door
function DoorPlacement.IsDoor(blockId: string): boolean
	if not blockId then return false end
	return string.find(string.lower(blockId), "door") ~= nil
end

-- Get direction from camera look vector
function DoorPlacement.GetDirectionFromLookVector(lookVector: Vector3): number
	local absX = math.abs(lookVector.X)
	local absZ = math.abs(lookVector.Z)
	
	if absX > absZ then
		if lookVector.X > 0 then
			return DoorPlacement.Direction.EAST
		else
			return DoorPlacement.Direction.WEST
		end
	else
		if lookVector.Z > 0 then
			return DoorPlacement.Direction.SOUTH
		else
			return DoorPlacement.Direction.NORTH
		end
	end
end

-- Get the depth zone based on where the player clicked on the face
-- Uses the relationship between hit position and grid position relative to camera
function DoorPlacement.GetDepthFromHit(
	hitPosition: Vector3,
	hitNormal: Vector3,
	hitBlockPosition: Vector3,
	gridPosition: Vector3,
	lookVector: Vector3
): string
	-- Project the look vector onto the horizontal plane
	local horizLook = Vector3.new(lookVector.X, 0, lookVector.Z)
	if horizLook.Magnitude < 0.01 then
		return DoorPlacement.Depth.MIDDLE
	end
	horizLook = horizLook.Unit
	
	-- Calculate where on the face the player clicked relative to the grid center
	-- Use the component of the hit position along the look direction
	local hitOffset = hitPosition - gridPosition
	local forwardComponent = hitOffset:Dot(horizLook)
	
	-- Positive = hit is further from camera (back of placement cell)
	-- Negative = hit is closer to camera (front of placement cell)
	
	if forwardComponent > THIRD_BLOCK / 2 then
		return DoorPlacement.Depth.BACK
	elseif forwardComponent < -THIRD_BLOCK / 2 then
		return DoorPlacement.Depth.FRONT
	else
		return DoorPlacement.Depth.MIDDLE
	end
end

-- Get the hinge side based on where the player clicked (left or right of your view)
-- The door HANDLE will appear on the side you click, hinge on the opposite side
function DoorPlacement.GetHingeSideFromHit(
	hitPosition: Vector3,
	hitNormal: Vector3,
	hitBlockPosition: Vector3,
	lookVector: Vector3
): string
	-- Project the look vector onto the horizontal plane
	local horizLook = Vector3.new(lookVector.X, 0, lookVector.Z)
	if horizLook.Magnitude < 0.01 then
		return DoorPlacement.HingeSide.LEFT
	end
	horizLook = horizLook.Unit
	
	-- Get the right vector (perpendicular to look, on horizontal plane)
	local rightVector = Vector3.new(-horizLook.Z, 0, horizLook.X)
	
	-- Calculate where on the block face the player clicked relative to the block center
	local hitOffset = hitPosition - hitBlockPosition
	local rightComponent = hitOffset:Dot(rightVector)
	
	-- Positive = right side of your view, Negative = left side of your view
	-- Handle goes where you click, hinge goes on opposite side
	-- Click right → handle right → hinge LEFT
	-- Click left → handle left → hinge RIGHT
	if rightComponent > 0 then
		return DoorPlacement.HingeSide.RIGHT  -- Click right, hinge right, handle left
	else
		return DoorPlacement.HingeSide.LEFT   -- Click left, hinge left, handle right
	end
end

-- Get position offset based on depth and direction
function DoorPlacement.GetDepthOffset(depth: string, direction: number): Vector3
	local depthValue
	
	if depth == DoorPlacement.Depth.FRONT then
		depthValue = BLOCK_SIZE / 2 - DOOR_THICKNESS / 2 -- Near front edge
	elseif depth == DoorPlacement.Depth.BACK then
		depthValue = -(BLOCK_SIZE / 2 - DOOR_THICKNESS / 2) -- Near back edge
	else
		depthValue = 0 -- Middle
	end
	
	-- Apply offset based on door facing direction
	-- Door is placed on the OPPOSITE side of where it faces (you place it, then walk through facing that direction)
	if direction == DoorPlacement.Direction.NORTH then
		return Vector3.new(0, 0, depthValue) -- Offset along Z
	elseif direction == DoorPlacement.Direction.SOUTH then
		return Vector3.new(0, 0, -depthValue) -- Opposite
	elseif direction == DoorPlacement.Direction.EAST then
		return Vector3.new(-depthValue, 0, 0) -- Offset along X
	elseif direction == DoorPlacement.Direction.WEST then
		return Vector3.new(depthValue, 0, 0) -- Opposite
	end
	
	return Vector3.new(0, 0, 0)
end

-- Get rotation CFrame based on direction
function DoorPlacement.GetRotationForDirection(direction: number): CFrame
	local rotations = {
		[DoorPlacement.Direction.NORTH] = CFrame.Angles(0, math.rad(180), 0), -- Face -Z
		[DoorPlacement.Direction.EAST] = CFrame.Angles(0, math.rad(270), 0),  -- Face +X
		[DoorPlacement.Direction.SOUTH] = CFrame.Angles(0, 0, 0),             -- Face +Z
		[DoorPlacement.Direction.WEST] = CFrame.Angles(0, math.rad(90), 0),   -- Face -X
	}
	return rotations[direction] or CFrame.new()
end

-- Get full CFrame for door placement
function DoorPlacement.GetDoorCFrame(gridPosition: Vector3, direction: number, depth: string, hingeSide: string?): CFrame
	local depthOffset = DoorPlacement.GetDepthOffset(depth, direction)
	local rotation = DoorPlacement.GetRotationForDirection(direction)
	local position = gridPosition + depthOffset
	
	-- If hinge is on the right, flip the door 180 degrees so the hinge appears on the other side
	local hingeFlip = CFrame.new()
	if hingeSide == DoorPlacement.HingeSide.RIGHT then
		hingeFlip = CFrame.Angles(0, math.rad(180), 0)
	end
	
	return CFrame.new(position) * rotation * hingeFlip
end

-- Get direction name for debugging
function DoorPlacement.GetDirectionName(direction: number): string
	local names = {
		[DoorPlacement.Direction.NORTH] = "North (-Z)",
		[DoorPlacement.Direction.EAST] = "East (+X)",
		[DoorPlacement.Direction.SOUTH] = "South (+Z)",
		[DoorPlacement.Direction.WEST] = "West (-X)",
	}
	return names[direction] or "Unknown"
end

-- Get depth name for debugging
function DoorPlacement.GetDepthName(depth: string): string
	local names = {
		[DoorPlacement.Depth.FRONT] = "Front",
		[DoorPlacement.Depth.MIDDLE] = "Middle",
		[DoorPlacement.Depth.BACK] = "Back",
	}
	return names[depth] or "Unknown"
end

-- Get hinge side name for debugging
function DoorPlacement.GetHingeSideName(hingeSide: string): string
	local names = {
		[DoorPlacement.HingeSide.LEFT] = "Left",
		[DoorPlacement.HingeSide.RIGHT] = "Right",
	}
	return names[hingeSide] or "Unknown"
end

-- Get placement info combining direction and depth
function DoorPlacement.GetPlacementInfo(
	hitPosition: Vector3,
	hitNormal: Vector3,
	hitBlockPosition: Vector3,
	gridPosition: Vector3,
	lookVector: Vector3
): {direction: number, depth: string, rotation: CFrame, offset: Vector3}
	
	local direction = DoorPlacement.GetDirectionFromLookVector(lookVector)
	
	-- Determine depth based on hit position relative to grid position
	local depth = DoorPlacement.GetDepthFromHit(hitPosition, hitNormal, hitBlockPosition, gridPosition, lookVector)
	
	local rotation = DoorPlacement.GetRotationForDirection(direction)
	local offset = DoorPlacement.GetDepthOffset(depth, direction)
	
	return {
		direction = direction,
		depth = depth,
		rotation = rotation,
		offset = offset,
	}
end

return DoorPlacement
