--[[
	WiringSystem
	Shared utilities for the wiring/connection system
	
	Connections are stored as attributes on controller blocks:
	- Controller stores a list of controllable block IDs it's connected to
	- Format: "WiringConnections" attribute contains comma-separated unique IDs
	
	Each wireable block gets a unique WiringID when first wired
	
	Signal flow:
	- Controllers (buttons, levers, pressure plates) send signals
	- Controllables (lamps, doors, lights) receive and respond to signals
	- A controllable is ON if ANY connected controller is sending a signal
]]

local HttpService = game:GetService("HttpService")

local WiringSystem = {}

-- Track active signals: controllableId -> {controllerId -> true}
-- This lets us know which controllers are currently powering each controllable
local ActiveSignals = {}

-- Generate a unique wiring ID for a block
function WiringSystem.GenerateWiringID(): string
	return HttpService:GenerateGUID(false)
end

-- Get or create a wiring ID for a block
function WiringSystem.GetOrCreateWiringID(block: Instance): string
	local existingId = block:GetAttribute("WiringID")
	if existingId then
		return existingId
	end
	
	local newId = WiringSystem.GenerateWiringID()
	block:SetAttribute("WiringID", newId)
	return newId
end

-- Get all connection IDs from a controller
function WiringSystem.GetConnections(controller: Instance): {string}
	local connectionsStr = controller:GetAttribute("WiringConnections")
	if not connectionsStr or connectionsStr == "" then
		return {}
	end
	
	local connections = {}
	for id in string.gmatch(connectionsStr, "[^,]+") do
		table.insert(connections, id)
	end
	return connections
end

-- Add a connection from controller to controllable
function WiringSystem.AddConnection(controller: Instance, controllableId: string): boolean
	local connections = WiringSystem.GetConnections(controller)
	
	-- Check if already connected
	for _, id in ipairs(connections) do
		if id == controllableId then
			return false -- Already connected
		end
	end
	
	-- Add new connection
	table.insert(connections, controllableId)
	controller:SetAttribute("WiringConnections", table.concat(connections, ","))
	
	return true
end

-- Remove a connection from controller to controllable
function WiringSystem.RemoveConnection(controller: Instance, controllableId: string): boolean
	local connections = WiringSystem.GetConnections(controller)
	
	local newConnections = {}
	local found = false
	for _, id in ipairs(connections) do
		if id == controllableId then
			found = true
		else
			table.insert(newConnections, id)
		end
	end
	
	if found then
		if #newConnections > 0 then
			controller:SetAttribute("WiringConnections", table.concat(newConnections, ","))
		else
			controller:SetAttribute("WiringConnections", nil)
		end
	end
	
	return found
end

-- Remove all connections from a controller
function WiringSystem.ClearConnections(controller: Instance)
	controller:SetAttribute("WiringConnections", nil)
end

-- Check if controller is connected to a specific controllable
function WiringSystem.IsConnected(controller: Instance, controllableId: string): boolean
	local connections = WiringSystem.GetConnections(controller)
	for _, id in ipairs(connections) do
		if id == controllableId then
			return true
		end
	end
	return false
end

-- Find a block by its WiringID in a folder
function WiringSystem.FindBlockByWiringID(wiringId: string, searchFolder: Instance): Instance?
	for _, block in ipairs(searchFolder:GetChildren()) do
		if block:GetAttribute("WiringID") == wiringId then
			return block
		end
	end
	return nil
end

-- Get all controllers connected to a controllable (reverse lookup)
function WiringSystem.GetControllersFor(controllable: Instance, searchFolder: Instance): {Instance}
	local controllableId = controllable:GetAttribute("WiringID")
	if not controllableId then
		return {}
	end
	
	local controllers = {}
	for _, block in ipairs(searchFolder:GetChildren()) do
		if WiringSystem.IsConnected(block, controllableId) then
			table.insert(controllers, block)
		end
	end
	
	return controllers
end

-- ============================================
-- SIGNAL SYSTEM
-- ============================================

-- Check if a controllable has any active signals
function WiringSystem.HasActiveSignal(controllableId: string): boolean
	local signals = ActiveSignals[controllableId]
	if not signals then
		return false
	end
	
	-- Check if any controller is still sending a signal
	for _, _ in pairs(signals) do
		return true
	end
	
	return false
end

-- Get the number of active signals for a controllable
function WiringSystem.GetSignalCount(controllableId: string): number
	local signals = ActiveSignals[controllableId]
	if not signals then
		return 0
	end
	
	local count = 0
	for _, _ in pairs(signals) do
		count = count + 1
	end
	
	return count
end

-- Send a signal from a controller to all its connected controllables
-- Returns a list of affected controllable IDs and their new states
function WiringSystem.SendSignal(controller: Instance, isActive: boolean, blocksFolder: Instance): {{id: string, block: Instance, powered: boolean}}
	local controllerId = controller:GetAttribute("WiringID")
	if not controllerId then
		return {}
	end
	
	local connections = WiringSystem.GetConnections(controller)
	local affectedBlocks = {}
	
	for _, controllableId in ipairs(connections) do
		-- Initialize signal tracking for this controllable if needed
		if not ActiveSignals[controllableId] then
			ActiveSignals[controllableId] = {}
		end
		
		local wasPowered = WiringSystem.HasActiveSignal(controllableId)
		
		-- Update the signal state
		if isActive then
			ActiveSignals[controllableId][controllerId] = true
		else
			ActiveSignals[controllableId][controllerId] = nil
		end
		
		local isPowered = WiringSystem.HasActiveSignal(controllableId)
		
		-- If power state changed, add to affected list
		if wasPowered ~= isPowered then
			local block = WiringSystem.FindBlockByWiringID(controllableId, blocksFolder)
			if block then
				table.insert(affectedBlocks, {
					id = controllableId,
					block = block,
					powered = isPowered,
				})
			end
		end
	end
	
	return affectedBlocks
end

-- Clear all signals (used when a block is destroyed)
function WiringSystem.ClearSignalsFrom(controllerId: string)
	for controllableId, signals in pairs(ActiveSignals) do
		signals[controllerId] = nil
	end
end

function WiringSystem.ClearSignalsTo(controllableId: string)
	ActiveSignals[controllableId] = nil
end

-- Connection state colors
WiringSystem.Colors = {
	Controller = Color3.fromRGB(255, 200, 50),     -- Yellow/gold for controllers
	Controllable = Color3.fromRGB(100, 200, 255),  -- Blue for controllables
	Connected = Color3.fromRGB(100, 255, 100),     -- Green for connected
	Selected = Color3.fromRGB(255, 100, 255),      -- Magenta for currently selected
	Wire = Color3.fromRGB(255, 50, 50),            -- Red for wire lines
}

return WiringSystem
