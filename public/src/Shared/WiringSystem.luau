--[[
	WiringSystem
	Shared module for the wiring/connection system
	
	Allows players to connect INPUT devices (buttons, levers, switches)
	to OUTPUT devices (doors, lights, pistons, etc.)
	
	Connection flow:
	1. Player selects Wiring Tool
	2. Right-click an OUTPUT (thing to control) - it gets highlighted
	3. Right-click an INPUT (controller) - connection is made
	4. When INPUT is activated, all connected OUTPUTs respond
]]

local WiringSystem = {}

-- Try to load LogicGates module (may not exist yet during initial setup)
local LogicGates = nil
pcall(function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local logicGatesModule = ReplicatedStorage:FindFirstChild("LogicGates")
	if logicGatesModule then
		LogicGates = require(logicGatesModule)
	end
end)

-- Device categories
WiringSystem.DeviceType = {
	NONE = "none",
	INPUT = "input",       -- Things that send signals (buttons, levers, pressure plates)
	OUTPUT = "output",     -- Things that receive signals (doors, lights, pistons)
	BOTH = "both",         -- Can be both input and output (for chaining)
	LOGIC_GATE = "logic",  -- Logic gates with multiple attach points
}

-- Signal types
WiringSystem.SignalType = {
	TOGGLE = "toggle",     -- Flip between on/off (lever, switch)
	PULSE = "pulse",       -- Momentary signal (button, pressure plate)
	HOLD = "hold",         -- Active while held (pressure plate with entity)
}

-- Output actions
WiringSystem.OutputAction = {
	TOGGLE = "toggle",     -- Toggle state (door open/close, light on/off)
	ACTIVATE = "activate", -- One-shot activation
	DEACTIVATE = "deactivate",
}

-- Block type to device type mapping
-- Add new connectable blocks here
WiringSystem.DeviceRegistry = {
	-- Outputs (things that get controlled)
	["OakDoor"] = { type = WiringSystem.DeviceType.OUTPUT, action = WiringSystem.OutputAction.TOGGLE },
	["SpruceDoor"] = { type = WiringSystem.DeviceType.OUTPUT, action = WiringSystem.OutputAction.TOGGLE },
	["BirchDoor"] = { type = WiringSystem.DeviceType.OUTPUT, action = WiringSystem.OutputAction.TOGGLE },
	["JungleDoor"] = { type = WiringSystem.DeviceType.OUTPUT, action = WiringSystem.OutputAction.TOGGLE },
	["AcaciaDoor"] = { type = WiringSystem.DeviceType.OUTPUT, action = WiringSystem.OutputAction.TOGGLE },
	["DarkOakDoor"] = { type = WiringSystem.DeviceType.OUTPUT, action = WiringSystem.OutputAction.TOGGLE },
	["IronDoor"] = { type = WiringSystem.DeviceType.OUTPUT, action = WiringSystem.OutputAction.TOGGLE },
	["TrapDoor"] = { type = WiringSystem.DeviceType.OUTPUT, action = WiringSystem.OutputAction.TOGGLE },
	["RedstoneLamp"] = { type = WiringSystem.DeviceType.OUTPUT, action = WiringSystem.OutputAction.TOGGLE },
	["Lamp"] = { type = WiringSystem.DeviceType.OUTPUT, action = WiringSystem.OutputAction.TOGGLE },
	["Light"] = { type = WiringSystem.DeviceType.OUTPUT, action = WiringSystem.OutputAction.TOGGLE },
	["Piston"] = { type = WiringSystem.DeviceType.OUTPUT, action = WiringSystem.OutputAction.TOGGLE },
	
	-- Inputs (things that send signals)
	["Button"] = { type = WiringSystem.DeviceType.INPUT, signal = WiringSystem.SignalType.PULSE },
	["StoneButton"] = { type = WiringSystem.DeviceType.INPUT, signal = WiringSystem.SignalType.PULSE },
	["WoodButton"] = { type = WiringSystem.DeviceType.INPUT, signal = WiringSystem.SignalType.PULSE },
	["Lever"] = { type = WiringSystem.DeviceType.INPUT, signal = WiringSystem.SignalType.TOGGLE },
	["Switch"] = { type = WiringSystem.DeviceType.INPUT, signal = WiringSystem.SignalType.TOGGLE },
	["PressurePlate"] = { type = WiringSystem.DeviceType.INPUT, signal = WiringSystem.SignalType.HOLD },
	["StonePressurePlate"] = { type = WiringSystem.DeviceType.INPUT, signal = WiringSystem.SignalType.HOLD },
	["WoodPressurePlate"] = { type = WiringSystem.DeviceType.INPUT, signal = WiringSystem.SignalType.HOLD },
	
	-- Logic Gates (have both inputs and outputs)
	["Inverter"] = { type = WiringSystem.DeviceType.LOGIC_GATE },
	["ORGate"] = { type = WiringSystem.DeviceType.LOGIC_GATE },
	["DelayGate"] = { type = WiringSystem.DeviceType.LOGIC_GATE },
}

-- Check if a block type is a connectable device
function WiringSystem.GetDeviceInfo(blockType: string): {type: string, action: string?, signal: string?}?
	if not blockType then return nil end
	
	-- Direct match
	if WiringSystem.DeviceRegistry[blockType] then
		return WiringSystem.DeviceRegistry[blockType]
	end
	
	-- Check for partial matches (e.g., "OakDoor" matches "Door")
	local lowerType = string.lower(blockType)
	
	-- Check for doors
	if string.find(lowerType, "door") then
		return { type = WiringSystem.DeviceType.OUTPUT, action = WiringSystem.OutputAction.TOGGLE }
	end
	
	-- Check for buttons
	if string.find(lowerType, "button") then
		return { type = WiringSystem.DeviceType.INPUT, signal = WiringSystem.SignalType.PULSE }
	end
	
	-- Check for levers/switches
	if string.find(lowerType, "lever") or string.find(lowerType, "switch") then
		return { type = WiringSystem.DeviceType.INPUT, signal = WiringSystem.SignalType.TOGGLE }
	end
	
	-- Check for pressure plates
	if string.find(lowerType, "pressure") or string.find(lowerType, "plate") then
		return { type = WiringSystem.DeviceType.INPUT, signal = WiringSystem.SignalType.HOLD }
	end
	
	-- Check for lights/lamps
	if string.find(lowerType, "lamp") or string.find(lowerType, "light") then
		return { type = WiringSystem.DeviceType.OUTPUT, action = WiringSystem.OutputAction.TOGGLE }
	end
	
	-- Check for pistons
	if string.find(lowerType, "piston") then
		return { type = WiringSystem.DeviceType.OUTPUT, action = WiringSystem.OutputAction.TOGGLE }
	end
	
	return nil
end

-- Check if a block is an input device
function WiringSystem.IsInput(blockType: string): boolean
	local info = WiringSystem.GetDeviceInfo(blockType)
	if not info then return false end
	return info.type == WiringSystem.DeviceType.INPUT or info.type == WiringSystem.DeviceType.BOTH
end

-- Check if a block is an output device
function WiringSystem.IsOutput(blockType: string): boolean
	local info = WiringSystem.GetDeviceInfo(blockType)
	if not info then return false end
	return info.type == WiringSystem.DeviceType.OUTPUT or info.type == WiringSystem.DeviceType.BOTH
end

-- Check if a block is connectable at all
function WiringSystem.IsConnectable(blockType: string): boolean
	return WiringSystem.GetDeviceInfo(blockType) ~= nil
end

-- Generate a unique connection ID
function WiringSystem.GenerateConnectionId(): string
	return tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999))
end

-- Connection data structure
-- Connections are stored as attributes on the INPUT device
-- Format: "WireConnection_<id>" = "<outputBlockId>"
-- The output block stores back-references: "WireInput_<id>" = "<inputBlockId>"

function WiringSystem.GetConnectionAttributeName(connectionId: string): string
	return "WireConn_" .. connectionId
end

function WiringSystem.GetInputRefAttributeName(connectionId: string): string
	return "WireInput_" .. connectionId
end

-- Parse a block's connections
function WiringSystem.GetOutputConnections(inputBlock: Instance): {string}
	local connections = {}
	
	for _, attr in ipairs(inputBlock:GetAttributes()) do
		-- This doesn't work, need different approach
	end
	
	-- Get all attributes that start with "WireConn_"
	local attributes = inputBlock:GetAttributes()
	for name, value in pairs(attributes) do
		if string.sub(name, 1, 9) == "WireConn_" then
			table.insert(connections, value)
		end
	end
	
	return connections
end

-- Get all input devices connected to an output
function WiringSystem.GetInputConnections(outputBlock: Instance): {string}
	local connections = {}
	
	local attributes = outputBlock:GetAttributes()
	for name, value in pairs(attributes) do
		if string.sub(name, 1, 10) == "WireInput_" then
			table.insert(connections, value)
		end
	end
	
	return connections
end

-- Colors for wiring visualization
WiringSystem.Colors = {
	Wire = Color3.fromRGB(255, 50, 50),        -- Red wire
	WireActive = Color3.fromRGB(255, 255, 50), -- Yellow when signal active
	InputHighlight = Color3.fromRGB(50, 150, 255),   -- Blue for inputs
	OutputHighlight = Color3.fromRGB(255, 150, 50),  -- Orange for outputs
	SelectedHighlight = Color3.fromRGB(50, 255, 50), -- Green for selected
	InvalidHighlight = Color3.fromRGB(255, 50, 50),  -- Red for invalid
}

-- ============================================
-- SIGNAL SYSTEM
-- ============================================

-- Track active signals: outputBlockId -> {inputBlockId -> true}
-- This lets us know which inputs are currently powering each output
local ActiveSignals = {}

-- Check if an output has any active signals
function WiringSystem.HasActiveSignal(outputBlockId: string): boolean
	local signals = ActiveSignals[outputBlockId]
	if not signals then
		return false
	end
	
	-- Check if any input is still sending a signal
	for _, _ in pairs(signals) do
		return true
	end
	
	return false
end

-- Get the number of active signals for an output
function WiringSystem.GetSignalCount(outputBlockId: string): number
	local signals = ActiveSignals[outputBlockId]
	if not signals then
		return 0
	end
	
	local count = 0
	for _, _ in pairs(signals) do
		count = count + 1
	end
	
	return count
end

-- Find a block by its BlockId in a folder
function WiringSystem.FindBlockByBlockId(blockId: string, searchFolder: Instance): Instance?
	for _, block in ipairs(searchFolder:GetChildren()) do
		if block:GetAttribute("BlockId") == blockId then
			return block
		end
	end
	return nil
end

-- Send a signal from an input to all its connected outputs
-- Returns a list of affected output IDs and their new states
function WiringSystem.SendSignal(inputBlock: Instance, isActive: boolean, blocksFolder: Instance): {{id: string, block: Instance, powered: boolean}}
	local inputBlockId = inputBlock:GetAttribute("BlockId")
	if not inputBlockId then
		-- Generate BlockId if missing
		inputBlockId = tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999))
		inputBlock:SetAttribute("BlockId", inputBlockId)
	end
	
	local outputConnections = WiringSystem.GetOutputConnections(inputBlock)
	local affectedBlocks = {}
	
	for _, outputBlockId in ipairs(outputConnections) do
		-- Initialize signal tracking for this output if needed
		if not ActiveSignals[outputBlockId] then
			ActiveSignals[outputBlockId] = {}
		end
		
		local wasPowered = WiringSystem.HasActiveSignal(outputBlockId)
		
		-- Update the signal state
		if isActive then
			ActiveSignals[outputBlockId][inputBlockId] = true
		else
			ActiveSignals[outputBlockId][inputBlockId] = nil
		end
		
		local isPowered = WiringSystem.HasActiveSignal(outputBlockId)
		
		-- If power state changed, add to affected list
		if wasPowered ~= isPowered then
			local block = WiringSystem.FindBlockByBlockId(outputBlockId, blocksFolder)
			if block then
				table.insert(affectedBlocks, {
					id = outputBlockId,
					block = block,
					powered = isPowered,
				})
			end
		end
	end
	
	return affectedBlocks
end

-- Clear all signals from a specific input (used when input is destroyed)
function WiringSystem.ClearSignalsFrom(inputBlockId: string)
	for outputBlockId, signals in pairs(ActiveSignals) do
		signals[inputBlockId] = nil
	end
end

-- Clear all signals to a specific output (used when output is destroyed)
function WiringSystem.ClearSignalsTo(outputBlockId: string)
	ActiveSignals[outputBlockId] = nil
end

-- ============================================
-- LOGIC GATE SUPPORT
-- ============================================

-- Check if a block type is a logic gate
function WiringSystem.IsLogicGate(blockType: string): boolean
	if not blockType then return false end
	local info = WiringSystem.DeviceRegistry[blockType]
	if info and info.type == WiringSystem.DeviceType.LOGIC_GATE then
		return true
	end
	-- Also check via LogicGates module if available
	if LogicGates and LogicGates.IsLogicGate then
		return LogicGates.IsLogicGate(blockType)
	end
	return false
end

-- Get the LogicGates module (for access to attach points, etc.)
function WiringSystem.GetLogicGatesModule()
	if LogicGates then return LogicGates end
	-- Try loading again if not loaded yet
	pcall(function()
		local ReplicatedStorage = game:GetService("ReplicatedStorage")
		local logicGatesModule = ReplicatedStorage:FindFirstChild("LogicGates")
		if logicGatesModule then
			LogicGates = require(logicGatesModule)
		end
	end)
	return LogicGates
end

-- Connection attribute format for logic gate attach points:
-- "WireConn_<connectionId>" = "<targetBlockId>:<attachPointName>"
-- This allows specifying which attach point on the target to connect to

-- Parse a connection value that may include an attach point
-- Returns: blockId, attachPointName (or nil if no attach point specified)
function WiringSystem.ParseConnectionTarget(connectionValue: string): (string, string?)
	if not connectionValue then return "", nil end
	
	local colonPos = string.find(connectionValue, ":")
	if colonPos then
		local blockId = string.sub(connectionValue, 1, colonPos - 1)
		local attachPoint = string.sub(connectionValue, colonPos + 1)
		return blockId, attachPoint
	end
	
	return connectionValue, nil
end

-- Format a connection target with optional attach point
function WiringSystem.FormatConnectionTarget(blockId: string, attachPointName: string?): string
	if attachPointName then
		return blockId .. ":" .. attachPointName
	end
	return blockId
end

-- Get output connections with attach point info
function WiringSystem.GetOutputConnectionsDetailed(inputBlock: Instance): {{blockId: string, attachPoint: string?}}
	local connections = {}
	
	local attributes = inputBlock:GetAttributes()
	for name, value in pairs(attributes) do
		if string.sub(name, 1, 9) == "WireConn_" then
			local blockId, attachPoint = WiringSystem.ParseConnectionTarget(value)
			table.insert(connections, {
				blockId = blockId,
				attachPoint = attachPoint,
			})
		end
	end
	
	return connections
end

return WiringSystem
