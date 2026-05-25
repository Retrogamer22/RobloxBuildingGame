--[[
	LogPlacement
	Handles Minecraft-style log rotation based on placement surface
	
	Logs can be placed in 3 orientations:
	- Y axis (vertical) - placed on top/bottom of a block
	- X axis (horizontal) - placed on left/right side of a block
	- Z axis (horizontal) - placed on front/back side of a block
]]

local LogPlacement = {}

-- Log block IDs that support axis rotation
local LOG_BLOCKS = {
	["OakLog"] = true,
	["SpruceLog"] = true,
	["BirchLog"] = true,
	["JungleLog"] = true,
	["AcaciaLog"] = true,
	["DarkOakLog"] = true,
	["HayBale"] = true,
}

-- Other blocks that use axis rotation (like pistons)
local AXIS_BLOCKS = {
	["Piston"] = true,
}

-- Check if a block type is a log (has CENTER pivot)
function LogPlacement.IsLog(blockId: string): boolean
	if not blockId then return false end
	-- Check exact match first
	if LOG_BLOCKS[blockId] then
		return true
	end
	-- Check if it contains "Log" (for future log types)
	if string.find(blockId, "Log") ~= nil then
		return true
	end
	return false
end

-- Check if block uses axis rotation (logs + pistons) but may have different pivots
function LogPlacement.UsesAxisRotation(blockId: string): boolean
	if not blockId then return false end
	-- Logs use axis rotation
	if LogPlacement.IsLog(blockId) then
		return true
	end
	-- Pistons use axis rotation
	if AXIS_BLOCKS[blockId] then
		return true
	end
	if string.find(blockId, "Piston") ~= nil then
		return true
	end
	return false
end

-- Get axis from surface normal
-- Returns "Y", "X", or "Z"
function LogPlacement.GetAxisFromNormal(normal: Vector3): string
	if not normal then return "Y" end
	
	local absX = math.abs(normal.X)
	local absY = math.abs(normal.Y)
	local absZ = math.abs(normal.Z)
	
	-- Find dominant axis
	if absY >= absX and absY >= absZ then
		-- Top or bottom face - vertical log
		return "Y"
	elseif absX >= absY and absX >= absZ then
		-- Left or right face - horizontal X log
		return "X"
	else
		-- Front or back face - horizontal Z log
		return "Z"
	end
end

-- Get directional axis from surface normal (includes + or - direction)
-- Returns "Y+", "Y-", "X+", "X-", "Z+", or "Z-"
function LogPlacement.GetDirectionalAxisFromNormal(normal: Vector3): string
	if not normal then return "Y+" end
	
	local absX = math.abs(normal.X)
	local absY = math.abs(normal.Y)
	local absZ = math.abs(normal.Z)
	
	-- Find dominant axis and direction
	if absY >= absX and absY >= absZ then
		return normal.Y >= 0 and "Y+" or "Y-"
	elseif absX >= absY and absX >= absZ then
		return normal.X >= 0 and "X+" or "X-"
	else
		return normal.Z >= 0 and "Z+" or "Z-"
	end
end

-- Get the CFrame rotation for a given axis (for logs - direction doesn't matter)
function LogPlacement.GetRotationForAxis(axis: string): CFrame
	-- Strip direction suffix if present (for backward compatibility)
	local baseAxis = string.sub(axis, 1, 1)
	
	if baseAxis == "X" then
		-- Rotate 90 degrees around Z axis to lay horizontal along X
		return CFrame.Angles(0, 0, math.rad(90))
	elseif baseAxis == "Z" then
		-- Rotate 90 degrees around X axis to lay horizontal along Z
		return CFrame.Angles(math.rad(90), 0, 0)
	else
		-- Default Y axis - no rotation needed (vertical)
		return CFrame.new()
	end
end

-- Get the CFrame rotation for a directional axis (for pistons - direction matters)
-- Piston faces the direction it will extend
function LogPlacement.GetDirectionalRotation(axis: string): CFrame
	if axis == "Y+" then
		-- Facing up (default orientation)
		return CFrame.new()
	elseif axis == "Y-" then
		-- Facing down - rotate 180 around X
		return CFrame.Angles(math.rad(180), 0, 0)
	elseif axis == "X+" then
		-- Facing +X (East) - tip to point X+, then rotate to lay flat
		return CFrame.Angles(0, 0, math.rad(-90)) * CFrame.Angles(0, math.rad(90), 0)
	elseif axis == "X-" then
		-- Facing -X (West) - tip to point X-, then rotate to lay flat
		return CFrame.Angles(0, 0, math.rad(90)) * CFrame.Angles(0, math.rad(-90), 0)
	elseif axis == "Z+" then
		-- Facing +Z (South) - tip to point Z+
		return CFrame.Angles(math.rad(90), 0, 0)
	elseif axis == "Z-" then
		-- Facing -Z (North) - tip to point Z-
		return CFrame.Angles(math.rad(-90), 0, 0)
	else
		return CFrame.new()
	end
end

-- Get the full CFrame for a log placement
function LogPlacement.GetLogCFrame(position: Vector3, axis: string): CFrame
	local rotation = LogPlacement.GetRotationForAxis(axis)
	return CFrame.new(position) * rotation
end

-- Get the full CFrame for a piston placement (directional)
function LogPlacement.GetPistonCFrame(position: Vector3, axis: string): CFrame
	local rotation = LogPlacement.GetDirectionalRotation(axis)
	return CFrame.new(position) * rotation
end

-- Check if a block needs directional placement (pistons) vs just axis (logs)
function LogPlacement.NeedsDirectionalPlacement(blockId: string): boolean
	if not blockId then return false end
	if AXIS_BLOCKS[blockId] then return true end
	if string.find(blockId, "Piston") then return true end
	return false
end

-- Get the appropriate CFrame based on block type
function LogPlacement.GetPlacementCFrame(position: Vector3, axis: string, blockId: string): CFrame
	if LogPlacement.NeedsDirectionalPlacement(blockId) then
		return LogPlacement.GetPistonCFrame(position, axis)
	else
		return LogPlacement.GetLogCFrame(position, axis)
	end
end

-- Get axis name for display/debugging
function LogPlacement.GetAxisName(axis: string): string
	local names = {
		["Y"] = "Vertical",
		["Y+"] = "Vertical (Up)",
		["Y-"] = "Vertical (Down)",
		["X"] = "Horizontal (East-West)",
		["X+"] = "Horizontal (East/+X)",
		["X-"] = "Horizontal (West/-X)",
		["Z"] = "Horizontal (North-South)",
		["Z+"] = "Horizontal (South/+Z)",
		["Z-"] = "Horizontal (North/-Z)",
	}
	return names[axis] or "Unknown"
end

return LogPlacement
