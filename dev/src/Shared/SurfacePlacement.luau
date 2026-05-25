--[[
	SurfacePlacement
	Handles placement of surface-mounted blocks like buttons, levers, pressure plates
	These blocks attach to the face of another block and rotate to face outward
]]

local BLOCK_SIZE = 3

-- Check if a block ID is a surface-mounted block
local function IsSurfaceBlock(blockId: string): boolean
	if not blockId or type(blockId) ~= "string" then return false end
	return string.find(blockId, "Button") ~= nil or string.find(blockId, "PressurePlate") ~= nil
end

-- Check if block is a pressure plate (top-only placement)
local function IsPressurePlate(blockId: string): boolean
	if not blockId or type(blockId) ~= "string" then return false end
	return string.find(blockId, "PressurePlate") ~= nil
end

-- Check if block is a button
local function IsButton(blockId: string): boolean
	if not blockId or type(blockId) ~= "string" then return false end
	return string.find(blockId, "Button") ~= nil
end

-- Get the face from a raycast normal
local function GetFaceFromNormal(normal: Vector3): string
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

-- Get rotation CFrame for a BUTTON
-- Assumes button model has pressable part facing -Z by default, with +Y as up
local function GetButtonRotation(face: string): CFrame
	if face == "Top" then
		-- Button laying flat on top, pressable part facing UP
		return CFrame.Angles(-math.pi / 2, 0, 0)
	elseif face == "Bottom" then
		-- Button hanging from bottom, pressable part facing DOWN
		return CFrame.Angles(math.pi / 2, 0, 0)
	elseif face == "North" then
		-- Attached to -Z face, button sticking out toward +Z (south)
		return CFrame.Angles(0, math.pi, 0)
	elseif face == "South" then
		-- Attached to +Z face, button sticking out toward -Z (north)
		return CFrame.Angles(0, 0, 0)
	elseif face == "East" then
		-- Attached to +X face, button sticking out toward -X (west)
		return CFrame.Angles(0, math.pi / 2, 0)
	elseif face == "West" then
		-- Attached to -X face, button sticking out toward +X (east)
		return CFrame.Angles(0, -math.pi / 2, 0)
	end
	
	return CFrame.new()
end

-- Get rotation CFrame for a PRESSURE PLATE
-- Pressure plate model is already oriented flat, no rotation needed
local function GetPressurePlateRotation(face: string): CFrame
	return CFrame.new()
end

-- Get the CFrame for a surface-mounted block
-- hitBlockPosition: center of the block being attached to
-- face: which face to attach to
-- blockThickness: how thick the surface block is
-- isPressurePlate: whether this is a pressure plate (different rotation)
local function GetSurfaceCFrame(hitBlockPosition: Vector3, face: string, blockThickness: number?, isPressurePlate: boolean?): CFrame
	local thickness = blockThickness or 0.3 -- Default button thickness
	local halfBlock = BLOCK_SIZE / 2
	
	-- Calculate position: place against the surface
	local position = hitBlockPosition
	
	if face == "Top" then
		position = position + Vector3.new(0, halfBlock + thickness / 2, 0)
	elseif face == "Bottom" then
		position = position + Vector3.new(0, -halfBlock - thickness / 2, 0)
	elseif face == "North" then
		position = position + Vector3.new(0, 0, -halfBlock - thickness / 2)
	elseif face == "South" then
		position = position + Vector3.new(0, 0, halfBlock + thickness / 2)
	elseif face == "East" then
		position = position + Vector3.new(halfBlock + thickness / 2, 0, 0)
	elseif face == "West" then
		position = position + Vector3.new(-halfBlock - thickness / 2, 0, 0)
	end
	
	-- Use different rotation based on block type
	local rotation
	if isPressurePlate then
		rotation = GetPressurePlateRotation(face)
	else
		rotation = GetButtonRotation(face)
	end
	
	return CFrame.new(position) * rotation
end

-- Get placement info from raycast data
local function GetPlacementInfo(blockId: string, hitPosition: Vector3, hitNormal: Vector3, hitBlockPosition: Vector3)
	local face = GetFaceFromNormal(hitNormal)
	local isPressurePlate = IsPressurePlate(blockId)
	
	-- Pressure plates can only go on top
	if isPressurePlate and face ~= "Top" then
		face = "Top"
	end
	
	-- Get appropriate thickness based on block type
	local thickness = 0.3 -- Default for buttons
	if isPressurePlate then
		thickness = 0.15 -- Pressure plates are thinner
	end
	
	-- For Top face, use the hit position Y to determine surface height
	-- This handles Models (like grass) where internal part positions may vary
	local adjustedHostPosition = hitBlockPosition
	if face == "Top" then
		-- The hit position Y is on the surface, so the block center is halfBlock below that
		local halfBlock = BLOCK_SIZE / 2
		adjustedHostPosition = Vector3.new(
			hitBlockPosition.X,
			hitPosition.Y - halfBlock,
			hitBlockPosition.Z
		)
	end
	
	local cframe = GetSurfaceCFrame(adjustedHostPosition, face, thickness, isPressurePlate)
	
	return {
		hostPosition = adjustedHostPosition, -- The block we're attaching to
		face = face,
		cframe = cframe,
		position = cframe.Position,
		thickness = thickness,
	}
end

return {
	IsSurfaceBlock = IsSurfaceBlock,
	IsPressurePlate = IsPressurePlate,
	IsButton = IsButton,
	GetFaceFromNormal = GetFaceFromNormal,
	GetButtonRotation = GetButtonRotation,
	GetPressurePlateRotation = GetPressurePlateRotation,
	GetSurfaceCFrame = GetSurfaceCFrame,
	GetPlacementInfo = GetPlacementInfo,
}
