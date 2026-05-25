--[[
	WiringTypes
	Defines what blocks can be controlled and what blocks can control them
	
	Controllers: Things that SEND signals (buttons, switches, levers, pressure plates)
	Controllables: Things that RECEIVE signals (doors, lights, pistons, trapdoors)
]]

local WiringTypes = {}

-- Controller types and their behavior
WiringTypes.Controllers = {
	-- Buttons: momentary press, auto-reset after delay
	Button = {
		type = "momentary",
		signalDuration = 1.0, -- seconds before auto-off
		patterns = {"button"},
	},
	
	-- Switches/Levers: toggle on/off, stays in position
	Switch = {
		type = "toggle",
		patterns = {"switch", "lever"},
	},
	
	-- Pressure Plates: active while stepped on
	PressurePlate = {
		type = "presence",
		patterns = {"pressureplate", "pressure_plate", "plate"},
	},
	
	-- Daylight Sensor: active during day/night
	DaylightSensor = {
		type = "daylight",
		patterns = {"daylight", "daylightsensor"},
	},
}

-- Controllable types and what happens when they receive a signal
WiringTypes.Controllables = {
	-- Doors: open/close
	Door = {
		action = "toggle",
		patterns = {"door"},
		exclude = {"trapdoor"}, -- trapdoor is separate
	},
	
	-- Trapdoors: open/close (different animation)
	Trapdoor = {
		action = "toggle",
		patterns = {"trapdoor", "trap_door"},
	},
	
	-- Lights: turn on/off
	Light = {
		action = "toggle",
		patterns = {"light", "lamp", "lantern", "torch", "glowstone", "redstone_lamp"},
	},
	
	-- Pistons: extend/retract (future)
	Piston = {
		action = "toggle",
		patterns = {"piston"},
	},
	
	-- Note Blocks: play sound (future)
	NoteBlock = {
		action = "trigger",
		patterns = {"noteblock", "note_block"},
	},
	
	-- Dispensers: dispense item (future)
	Dispenser = {
		action = "trigger",
		patterns = {"dispenser"},
	},
}

-- Check if a block ID matches any pattern in a list
local function matchesPatterns(blockId, patterns, excludePatterns)
	if not blockId then return false end
	local lowerId = string.lower(blockId)
	
	-- Check exclusions first
	if excludePatterns then
		for _, pattern in ipairs(excludePatterns) do
			if string.find(lowerId, pattern) then
				return false
			end
		end
	end
	
	-- Check for matches
	for _, pattern in ipairs(patterns) do
		if string.find(lowerId, pattern) then
			return true
		end
	end
	
	return false
end

-- Get the controller type for a block (or nil if not a controller)
function WiringTypes.GetControllerType(blockId: string): (string?, table?)
	if not blockId then return nil, nil end
	
	for typeName, typeData in pairs(WiringTypes.Controllers) do
		if matchesPatterns(blockId, typeData.patterns) then
			return typeName, typeData
		end
	end
	
	return nil, nil
end

-- Get the controllable type for a block (or nil if not controllable)
function WiringTypes.GetControllableType(blockId: string): (string?, table?)
	if not blockId then return nil, nil end
	
	for typeName, typeData in pairs(WiringTypes.Controllables) do
		if matchesPatterns(blockId, typeData.patterns, typeData.exclude) then
			return typeName, typeData
		end
	end
	
	return nil, nil
end

-- Check if a block is a controller
function WiringTypes.IsController(blockId: string): boolean
	local typeName = WiringTypes.GetControllerType(blockId)
	return typeName ~= nil
end

-- Check if a block is controllable
function WiringTypes.IsControllable(blockId: string): boolean
	local typeName = WiringTypes.GetControllableType(blockId)
	return typeName ~= nil
end

-- Check if a block can be wired (either controller or controllable)
function WiringTypes.IsWireable(blockId: string): boolean
	return WiringTypes.IsController(blockId) or WiringTypes.IsControllable(blockId)
end

return WiringTypes
