--[[
	WiringHandler
	Server-side handler for the wiring system
	
	Manages:
	- Creating and removing connections
	- Processing input signals
	- Triggering output actions
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local WiringSystem = require(ReplicatedStorage:WaitForChild("WiringSystem"))
local GridConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GridConfig"))

-- Wait for LogicGates module
local LogicGates = nil
pcall(function()
	LogicGates = require(ReplicatedStorage:WaitForChild("LogicGates", 5))
end)
if not LogicGates then
	warn("[WiringHandler] LogicGates module not found - logic gates will not function")
end

-- Remotes
local Remotes = ReplicatedStorage:WaitForChild("Remotes")

local CreateConnectionRemote = Instance.new("RemoteEvent")
CreateConnectionRemote.Name = "CreateWireConnection"
CreateConnectionRemote.Parent = Remotes

local RemoveConnectionRemote = Instance.new("RemoteEvent")
RemoveConnectionRemote.Name = "RemoveWireConnection"
RemoveConnectionRemote.Parent = Remotes

local ActivateInputRemote = Instance.new("RemoteEvent")
ActivateInputRemote.Name = "ActivateWireInput"
ActivateInputRemote.Parent = Remotes

local WireStateChangedRemote = Instance.new("RemoteEvent")
WireStateChangedRemote.Name = "WireStateChanged"
WireStateChangedRemote.Parent = Remotes

local ConnectionUpdatedRemote = Instance.new("RemoteEvent")
ConnectionUpdatedRemote.Name = "WireConnectionUpdated"
ConnectionUpdatedRemote.Parent = Remotes

local ClearAllConnectionsRemote = Instance.new("RemoteEvent")
ClearAllConnectionsRemote.Name = "ClearAllWireConnections"
ClearAllConnectionsRemote.Parent = Remotes

-- Track active pulse signals (for buttons that auto-deactivate)
local ActivePulses = {}

-- Forward declarations for logic gate functions
local updateLogicGateInput
local setLogicGateOutput

-- ============================================
-- HELPER FUNCTIONS
-- ============================================

local function getPlayerPlot(player)
	-- Check MegaPlot mode first
	local modeValue = ReplicatedStorage:FindFirstChild("PrivateServerMode")
	if modeValue and modeValue.Value == "MegaPlot" then
		local megaPlotRoom = workspace:FindFirstChild("MegaPlotRoom")
		if megaPlotRoom then
			local megaBuildArea = megaPlotRoom:FindFirstChild("MegaPlotBuildArea")
			if megaBuildArea then
				return megaBuildArea
			end
		end
	end
	-- Individual plots
	for i = 1, GridConfig.TOTAL_PLOTS do
		local buildArea = workspace:FindFirstChild(GridConfig.BUILD_AREA_PREFIX .. i)
		if buildArea and buildArea:GetAttribute("OwnerUserId") == player.UserId then
			return buildArea
		end
	end
	return nil
end

local function getBlocksFolder(player)
	local plot = getPlayerPlot(player)
	if plot then
		return plot:FindFirstChild("Blocks")
	end
	return nil
end

local function isBlockInPlayerPlot(player, block)
	local blocksFolder = getBlocksFolder(player)
	if not blocksFolder then return false end
	return block:IsDescendantOf(blocksFolder) or block.Parent == blocksFolder
end

local function findBlockById(blocksFolder, blockId)
	for _, block in ipairs(blocksFolder:GetChildren()) do
		if block:GetAttribute("BlockId") == blockId then
			return block
		end
	end
	return nil
end

-- Generate a unique block ID if one doesn't exist
local function ensureBlockId(block)
	local blockId = block:GetAttribute("BlockId")
	if not blockId then
		blockId = tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999))
		block:SetAttribute("BlockId", blockId)
	end
	return blockId
end

-- ============================================
-- OUTPUT ACTIONS
-- ============================================

local function triggerDoor(doorBlock, isActivating)
	-- Toggle the door state
	local isOpen = doorBlock:GetAttribute("IsOpen") or false
	doorBlock:SetAttribute("IsOpen", not isOpen)
	
	-- Notify clients to animate
	local DoorStateChanged = Remotes:FindFirstChild("DoorStateChanged")
	if DoorStateChanged then
		DoorStateChanged:FireAllClients(doorBlock, not isOpen)
	end
	
	print("[Wiring] Door toggled:", doorBlock.Name, "-> IsOpen:", not isOpen)
end

local function triggerPiston(pistonBlock, isActivating)
	-- Get current extended state
	local isExtended = pistonBlock:GetAttribute("IsExtended") or false
	local newState = not isExtended
	
	-- Only change state if power state differs from extended state
	if isActivating == isExtended then
		return -- Already in correct state
	end
	
	-- Find the PistonTop part (the part that moves)
	local pistonTop = pistonBlock:FindFirstChild("PistonTop")
	if not pistonTop then
		warn("[Wiring] PistonTop not found in piston model")
		return
	end
	
	-- Check if this is a sticky piston
	local blockType = pistonBlock:GetAttribute("BlockType") or ""
	local isSticky = string.find(string.lower(blockType), "sticky") ~= nil
	
	-- Get blocks folder for pushing/pulling
	local blocksFolder = pistonBlock.Parent
	
	-- Handle block pushing/pulling BEFORE animation
	local PistonPushHandler = nil
	pcall(function()
		PistonPushHandler = require(script.Parent:WaitForChild("Modules"):WaitForChild("PistonPushHandler"))
	end)
	
	if PistonPushHandler and blocksFolder then
		if newState then
			-- EXTENDING - try to push blocks first
			local canPush, blockCount = PistonPushHandler.CanPush(pistonBlock, blocksFolder)
			if not canPush then
				print("[Wiring] Piston cannot extend - blocked by " .. blockCount .. " blocks")
				return -- Don't extend if we can't push
			end
			
			-- Push the blocks
			PistonPushHandler.PushBlocks(pistonBlock, blocksFolder)
		else
			-- RETRACTING - sticky pistons pull blocks back
			if isSticky then
				PistonPushHandler.PullBlocks(pistonBlock, blocksFolder)
			end
		end
	end
	
	-- Find the PistonArm for scaling
	local pistonArm = pistonTop:FindFirstChild("PistonArm")
	
	-- Get the piston's orientation to determine extension direction
	local pistonCFrame
	if pistonBlock:IsA("Model") then
		pistonCFrame = pistonBlock:GetPivot()
	else
		pistonCFrame = pistonBlock.CFrame
	end
	
	-- The extension direction is the piston's UpVector (local Y+)
	local moveDirection = pistonCFrame.UpVector
	
	local EXTENSION_DISTANCE = 3  -- 3 studs
	local TWEEN_TIME = 0.15  -- Fast but smooth
	local ARM_SCALE_AMOUNT = 3  -- How much to stretch the arm (in studs)
	local moveOffset = moveDirection * EXTENSION_DISTANCE
	
	-- Tween settings
	local TweenService = game:GetService("TweenService")
	local tweenInfo = TweenInfo.new(
		TWEEN_TIME,
		Enum.EasingStyle.Quad,
		Enum.EasingDirection.Out
	)
	
	-- Scale the PistonArm if it exists
	if pistonArm and pistonArm:IsA("BasePart") then
		local currentSize = pistonArm.Size
		local targetSize
		local targetPosition
		
		if newState then
			targetSize = Vector3.new(currentSize.X, currentSize.Y + ARM_SCALE_AMOUNT, currentSize.Z)
			targetPosition = pistonArm.Position + (moveDirection * (ARM_SCALE_AMOUNT / 2))
		else
			targetSize = Vector3.new(currentSize.X, currentSize.Y - ARM_SCALE_AMOUNT, currentSize.Z)
			targetPosition = pistonArm.Position - (moveDirection * (ARM_SCALE_AMOUNT / 2))
		end
		
		local armTween = TweenService:Create(pistonArm, tweenInfo, {
			Size = targetSize,
			Position = targetPosition
		})
		armTween:Play()
	end
	
	-- Move the PistonTop (head) with tweening - move each part EXCEPT PistonArm
	if pistonTop:IsA("Model") then
		for _, part in ipairs(pistonTop:GetDescendants()) do
			if part:IsA("BasePart") and part.Name ~= "PistonArm" then
				local targetCFrame
				if newState then
					targetCFrame = part.CFrame + moveOffset
				else
					targetCFrame = part.CFrame - moveOffset
				end
				local tween = TweenService:Create(part, tweenInfo, {CFrame = targetCFrame})
				tween:Play()
			end
		end
	elseif pistonTop:IsA("BasePart") then
		local targetPosition
		if newState then
			targetPosition = pistonTop.Position + moveOffset
		else
			targetPosition = pistonTop.Position - moveOffset
		end
		local tween = TweenService:Create(pistonTop, tweenInfo, {Position = targetPosition})
		tween:Play()
	end
	
	-- Update state
	pistonBlock:SetAttribute("IsExtended", newState)
	
	-- Notify clients
	WireStateChangedRemote:FireAllClients(pistonBlock, "piston", newState)
	
	print("[Wiring] Piston toggled:", pistonBlock.Name, "-> IsExtended:", newState)
end

local function triggerLight(lightBlock, isActivating)
	-- Toggle light state (for button presses)
	local isOn = lightBlock:GetAttribute("IsPowered")
	if isOn == nil then isOn = false end -- Default to off (matches BlockHandler init)
	
	local newState = not isOn
	lightBlock:SetAttribute("IsPowered", newState)
	
	-- Update visual (find light parts and toggle)
	local function updatePart(part)
		if part:IsA("BasePart") then
			-- Toggle point lights
			for _, child in ipairs(part:GetChildren()) do
				if child:IsA("Light") then
					child.Enabled = newState
				end
			end
			
			-- Update material for neon parts
			if newState then
				part.Material = Enum.Material.Neon
			else
				part.Material = Enum.Material.SmoothPlastic
			end
		end
	end
	
	if lightBlock:IsA("Model") then
		for _, desc in ipairs(lightBlock:GetDescendants()) do
			updatePart(desc)
		end
	else
		updatePart(lightBlock)
	end
	
	-- Notify clients
	WireStateChangedRemote:FireAllClients(lightBlock, "light", newState)
	
	print("[Wiring] Light toggled:", lightBlock.Name, "-> IsPowered:", newState)
end

-- Set light to a specific state (for logic gates)
local function setLightState(lightBlock, shouldBeOn)
	local currentState = lightBlock:GetAttribute("IsPowered") or false
	
	-- Only update if state actually changes
	if currentState == shouldBeOn then
		return
	end
	
	lightBlock:SetAttribute("IsPowered", shouldBeOn)
	
	-- Update visual
	local function updatePart(part)
		if part:IsA("BasePart") then
			for _, child in ipairs(part:GetChildren()) do
				if child:IsA("Light") then
					child.Enabled = shouldBeOn
				end
			end
			
			if shouldBeOn then
				part.Material = Enum.Material.Neon
			else
				part.Material = Enum.Material.SmoothPlastic
			end
		end
	end
	
	if lightBlock:IsA("Model") then
		for _, desc in ipairs(lightBlock:GetDescendants()) do
			updatePart(desc)
		end
	else
		updatePart(lightBlock)
	end
	
	WireStateChangedRemote:FireAllClients(lightBlock, "light", shouldBeOn)
	print("[Wiring] Light set:", lightBlock.Name, "-> IsPowered:", shouldBeOn)
end

local function triggerOutput(outputBlock)
	local blockType = outputBlock:GetAttribute("BlockType")
	local deviceInfo = WiringSystem.GetDeviceInfo(blockType)
	
	if not deviceInfo then
		warn("[Wiring] Unknown output type:", blockType)
		return
	end
	
	-- Check what type of output this is
	local lowerType = string.lower(blockType or "")
	
	if string.find(lowerType, "door") then
		triggerDoor(outputBlock, true)
	elseif string.find(lowerType, "piston") then
		triggerPiston(outputBlock, true)
	elseif string.find(lowerType, "lamp") or string.find(lowerType, "light") then
		triggerLight(outputBlock, true)
	else
		-- Generic toggle
		local isActive = outputBlock:GetAttribute("IsActive") or false
		outputBlock:SetAttribute("IsActive", not isActive)
		WireStateChangedRemote:FireAllClients(outputBlock, "generic", not isActive)
		print("[Wiring] Generic output toggled:", blockType)
	end
end

-- ============================================
-- LOGIC GATE PROCESSING
-- ============================================

-- Track which logic gates are pending delay updates
local PendingDelayGates = {}

-- Update a logic gate's input state and recalculate output
updateLogicGateInput = function(gateBlock, attachPointName, isActive, blocksFolder)
	if not LogicGates then return end
	
	local blockType = gateBlock:GetAttribute("BlockType")
	if not LogicGates.IsLogicGate(blockType) then return end
	
	-- Update the input state attribute
	gateBlock:SetAttribute("Input_" .. attachPointName, isActive)
	
	print("[Wiring] Logic gate input updated:", blockType, attachPointName, "->", isActive)
	
	-- Collect all input states
	local inputStates = {}
	local inputPoints = LogicGates.GetInputAttachPoints(blockType)
	for _, inputPoint in ipairs(inputPoints) do
		inputStates[inputPoint.Name] = gateBlock:GetAttribute("Input_" .. inputPoint.Name) or false
	end
	
	-- Calculate new output
	local newOutput = LogicGates.ProcessGate(blockType, inputStates)
	local currentOutput = gateBlock:GetAttribute("IsOutputting") or false
	
	-- Handle delay gates specially
	local gateDef = LogicGates.GetGateDefinition(blockType)
	if gateDef and gateDef.DelayTime and gateDef.DelayTime > 0 then
		local gateId = gateBlock:GetAttribute("BlockId")
		
		-- Cancel any pending delay
		if PendingDelayGates[gateId] then
			task.cancel(PendingDelayGates[gateId])
			PendingDelayGates[gateId] = nil
		end
		
		-- Schedule the output change
		if newOutput ~= currentOutput then
			PendingDelayGates[gateId] = task.delay(gateDef.DelayTime, function()
				PendingDelayGates[gateId] = nil
				if gateBlock and gateBlock.Parent then
					setLogicGateOutput(gateBlock, newOutput, blocksFolder)
				end
			end)
		end
		return
	end
	
	-- Immediate update for non-delay gates
	if newOutput ~= currentOutput then
		setLogicGateOutput(gateBlock, newOutput, blocksFolder)
	end
end

-- Set logic gate output and propagate to connected devices
setLogicGateOutput = function(gateBlock, isOutputting, blocksFolder)
	if not LogicGates then return end
	
	local blockType = gateBlock:GetAttribute("BlockType")
	
	-- Update state
	gateBlock:SetAttribute("IsOutputting", isOutputting)
	
	-- Update visuals
	LogicGates.UpdateGateVisuals(gateBlock, blockType, isOutputting)
	
	-- Notify clients
	WireStateChangedRemote:FireAllClients(gateBlock, "logic_gate", isOutputting)
	
	print("[Wiring] Logic gate output changed:", blockType, "->", isOutputting)
	
	-- Propagate to connected outputs
	-- Logic gate outputs act like inputs (they SEND signals)
	-- So we need to find what's connected to the gate's output attach point
	
	local gateId = gateBlock:GetAttribute("BlockId")
	if not gateId then return end
	
	-- Get output attach points for this gate
	local outputPoints = LogicGates.GetOutputAttachPoints(blockType)
	
	-- Find connections FROM this gate's output
	-- These are stored on the gate block itself with the attach point specified
	local connections = WiringSystem.GetOutputConnectionsDetailed(gateBlock)
	
	for _, conn in ipairs(connections) do
		local targetBlock = findBlockById(blocksFolder, conn.blockId)
		if targetBlock then
			local targetType = targetBlock:GetAttribute("BlockType")
			
			-- If target is another logic gate, update its input
			if LogicGates.IsLogicGate(targetType) then
				local targetAttachPoint = conn.attachPoint
				if targetAttachPoint then
					updateLogicGateInput(targetBlock, targetAttachPoint, isOutputting, blocksFolder)
				end
			else
				-- Regular output (door, lamp, etc.)
				-- For lamps, SET the state to match the output
				local lowerType = string.lower(targetType or "")
				if string.find(lowerType, "lamp") or string.find(lowerType, "light") then
					setLightState(targetBlock, isOutputting)
				else
					-- For other outputs (doors, pistons), only trigger on rising edge
					if isOutputting then
						triggerOutput(targetBlock)
					end
				end
			end
		end
	end
end



-- ============================================
-- CONNECTION MANAGEMENT
-- ============================================

-- Extended createConnection with attach point support
-- sourceBlock: the block that SENDS the signal (input device or logic gate output)
-- targetBlock: the block that RECEIVES the signal (output device or logic gate input)
-- sourceAttachPoint: (optional) which attach point on the source to connect from
-- targetAttachPoint: (optional) which attach point on the target to connect to
local function createConnection(player, sourceBlock, targetBlock, sourceAttachPoint, targetAttachPoint)
	-- Validate blocks
	if not sourceBlock or not targetBlock then
		warn("[Wiring] Invalid blocks for connection")
		return false
	end
	
	-- Check ownership
	if not isBlockInPlayerPlot(player, sourceBlock) or not isBlockInPlayerPlot(player, targetBlock) then
		warn("[Wiring] Blocks not in player's plot")
		return false
	end
	
	-- Validate device types
	local sourceType = sourceBlock:GetAttribute("BlockType")
	local targetType = targetBlock:GetAttribute("BlockType")
	
	-- Determine if source can send signals
	local sourceCanSend = WiringSystem.IsInput(sourceType)
	if LogicGates and LogicGates.IsLogicGate(sourceType) then
		-- Logic gates can send from their output attach points
		local outputPoints = LogicGates.GetOutputAttachPoints(sourceType)
		sourceCanSend = #outputPoints > 0
	end
	
	if not sourceCanSend then
		warn("[Wiring] Source block cannot send signals:", sourceType)
		return false
	end
	
	-- Determine if target can receive signals
	local targetCanReceive = WiringSystem.IsOutput(targetType)
	if LogicGates and LogicGates.IsLogicGate(targetType) then
		-- Logic gates can receive on their input attach points
		local inputPoints = LogicGates.GetInputAttachPoints(targetType)
		targetCanReceive = #inputPoints > 0
	end
	
	if not targetCanReceive then
		warn("[Wiring] Target block cannot receive signals:", targetType)
		return false
	end
	
	-- Ensure both blocks have IDs
	local sourceId = ensureBlockId(sourceBlock)
	local targetId = ensureBlockId(targetBlock)
	
	-- Format target with optional attach point
	local connectionValue = WiringSystem.FormatConnectionTarget(targetId, targetAttachPoint)
	
	-- Check if connection already exists
	local existingConnections = WiringSystem.GetOutputConnectionsDetailed(sourceBlock)
	for _, conn in ipairs(existingConnections) do
		if conn.blockId == targetId and conn.attachPoint == targetAttachPoint then
			print("[Wiring] Connection already exists")
			return false
		end
	end
	
	-- Create the connection
	local connectionId = WiringSystem.GenerateConnectionId()
	
	-- Store on source: which target it controls (with optional attach point)
	sourceBlock:SetAttribute(WiringSystem.GetConnectionAttributeName(connectionId), connectionValue)
	
	-- Store on target: which source controls it (for back-reference)
	local sourceRef = sourceAttachPoint and (sourceId .. ":" .. sourceAttachPoint) or sourceId
	targetBlock:SetAttribute(WiringSystem.GetInputRefAttributeName(connectionId), sourceRef)
	
	-- Initialize logic gate if it's the first connection to it
	if LogicGates and LogicGates.IsLogicGate(targetType) then
		if not targetBlock:GetAttribute("IsLogicGate") then
			LogicGates.InitializeGate(targetBlock, targetType)
		end
	end
	
	-- If the source is a logic gate that's already outputting, update the target now
	if LogicGates and LogicGates.IsLogicGate(sourceType) then
		local isOutputting = sourceBlock:GetAttribute("IsOutputting") or false
		if isOutputting then
			-- Get the blocks folder for propagation
			local blocksFolder = sourceBlock.Parent
			
			-- Check if target is a logic gate
			if LogicGates.IsLogicGate(targetType) then
				-- Update the target logic gate's input
				if targetAttachPoint then
					updateLogicGateInput(targetBlock, targetAttachPoint, true, blocksFolder)
				end
			else
				-- Regular output - set lamp state or trigger others
				local lowerType = string.lower(targetType or "")
				if string.find(lowerType, "lamp") or string.find(lowerType, "light") then
					setLightState(targetBlock, true)
				else
					triggerOutput(targetBlock)
				end
			end
			print("[Wiring] Updated target because source logic gate is already outputting")
		end
	end
	
	-- Notify clients
	ConnectionUpdatedRemote:FireAllClients(sourceBlock, targetBlock, "created", connectionId)
	
	local attachInfo = ""
	if targetAttachPoint then
		attachInfo = " (attach: " .. targetAttachPoint .. ")"
	end
	print("[Wiring] Connection created:", sourceType, "->", targetType .. attachInfo, "ID:", connectionId)
	return true
end

local function removeConnection(player, inputBlock, outputBlock)
	if not inputBlock or not outputBlock then return false end
	
	-- Check ownership
	if not isBlockInPlayerPlot(player, inputBlock) then
		return false
	end
	
	local outputId = outputBlock:GetAttribute("BlockId")
	if not outputId then return false end
	
	-- Find the connection attribute
	local attributes = inputBlock:GetAttributes()
	local foundConnectionId = nil
	
	for name, value in pairs(attributes) do
		if string.sub(name, 1, 9) == "WireConn_" and value == outputId then
			foundConnectionId = string.sub(name, 10)
			inputBlock:SetAttribute(name, nil)
			break
		end
	end
	
	if foundConnectionId then
		-- Also remove back-reference from output
		outputBlock:SetAttribute(WiringSystem.GetInputRefAttributeName(foundConnectionId), nil)
		
		-- Notify clients
		ConnectionUpdatedRemote:FireAllClients(inputBlock, outputBlock, "removed", foundConnectionId)
		
		print("[Wiring] Connection removed")
		return true
	end
	
	return false
end

-- ============================================
-- INPUT ACTIVATION
-- ============================================

local function activateInput(player, inputBlock)
	if not inputBlock then return end
	
	-- Check ownership
	if not isBlockInPlayerPlot(player, inputBlock) then
		return
	end
	
	local blockType = inputBlock:GetAttribute("BlockType")
	local deviceInfo = WiringSystem.GetDeviceInfo(blockType)
	
	if not deviceInfo or deviceInfo.type ~= WiringSystem.DeviceType.INPUT then
		return
	end
	
	print("[Wiring] Input activated:", blockType)
	
	-- Get the blocks folder to find connected outputs
	local blocksFolder = getBlocksFolder(player)
	if not blocksFolder then return end
	
	-- Determine signal state based on signal type
	local isActivating = true
	local signalDuration = nil
	
	if deviceInfo.signal == WiringSystem.SignalType.PULSE then
		-- Pulse: momentary activation
		signalDuration = 0.5
		inputBlock:SetAttribute("IsActivated", true)
		WireStateChangedRemote:FireAllClients(inputBlock, "input", true)
	elseif deviceInfo.signal == WiringSystem.SignalType.TOGGLE then
		-- Toggle: flip the state
		local wasOn = inputBlock:GetAttribute("IsActivated") or false
		isActivating = not wasOn
		inputBlock:SetAttribute("IsActivated", isActivating)
		WireStateChangedRemote:FireAllClients(inputBlock, "input", isActivating)
	end
	
	-- Get connections with attach point info
	local connections = WiringSystem.GetOutputConnectionsDetailed(inputBlock)
	
	for _, conn in ipairs(connections) do
		local targetBlock = findBlockById(blocksFolder, conn.blockId)
		if targetBlock then
			local targetType = targetBlock:GetAttribute("BlockType")
			
			-- Check if target is a logic gate
			if LogicGates and LogicGates.IsLogicGate(targetType) then
				-- Update the logic gate's input
				local attachPoint = conn.attachPoint
				if attachPoint then
					updateLogicGateInput(targetBlock, attachPoint, isActivating, blocksFolder)
				else
					-- No attach point specified - try to find the first input
					local inputPoints = LogicGates.GetInputAttachPoints(targetType)
					if #inputPoints > 0 then
						updateLogicGateInput(targetBlock, inputPoints[1].Name, isActivating, blocksFolder)
					end
				end
			else
				-- Regular output - trigger on rising edge only
				if isActivating then
					triggerOutput(targetBlock)
				end
			end
		else
			warn("[Wiring] Could not find target block:", conn.blockId)
		end
	end
	
	-- Handle pulse auto-deactivation
	if signalDuration then
		task.delay(signalDuration, function()
			if inputBlock and inputBlock.Parent then
				inputBlock:SetAttribute("IsActivated", false)
				WireStateChangedRemote:FireAllClients(inputBlock, "input", false)
				
				-- Also deactivate connected logic gates
				for _, conn in ipairs(connections) do
					local targetBlock = findBlockById(blocksFolder, conn.blockId)
					if targetBlock then
						local targetType = targetBlock:GetAttribute("BlockType")
						if LogicGates and LogicGates.IsLogicGate(targetType) then
							local attachPoint = conn.attachPoint
							if attachPoint then
								updateLogicGateInput(targetBlock, attachPoint, false, blocksFolder)
							else
								local inputPoints = LogicGates.GetInputAttachPoints(targetType)
								if #inputPoints > 0 then
									updateLogicGateInput(targetBlock, inputPoints[1].Name, false, blocksFolder)
								end
							end
						end
					end
				end
			end
		end)
	end
end

-- ============================================
-- REMOTE EVENT HANDLERS
-- ============================================

CreateConnectionRemote.OnServerEvent:Connect(function(player, sourceBlock, targetBlock, sourceAttachPoint, targetAttachPoint)
	createConnection(player, sourceBlock, targetBlock, sourceAttachPoint, targetAttachPoint)
end)

RemoveConnectionRemote.OnServerEvent:Connect(function(player, inputBlock, outputBlock)
	removeConnection(player, inputBlock, outputBlock)
end)

ActivateInputRemote.OnServerEvent:Connect(function(player, inputBlock)
	activateInput(player, inputBlock)
end)

-- Clear all connections from a block (both as source and as target)
ClearAllConnectionsRemote.OnServerEvent:Connect(function(player, block)
	if not block then return end
	
	-- Check ownership
	if not isBlockInPlayerPlot(player, block) then
		warn("[Wiring] Block not in player's plot")
		return
	end
	
	local blocksFolder = getBlocksFolder(player)
	if not blocksFolder then return end
	
	local blockType = block:GetAttribute("BlockType")
	local blockId = block:GetAttribute("BlockId")
	local clearedCount = 0
	local affectedTargets = {} -- Track targets that lost connections
	
	-- Helper to check if a block can send signals
	local function canSendSignals(bType)
		if WiringSystem.IsInput(bType) then return true end
		if LogicGates and LogicGates.IsLogicGate(bType) then return true end
		return false
	end
	
	-- Helper to check if a block can receive signals
	local function canReceiveSignals(bType)
		if WiringSystem.IsOutput(bType) then return true end
		if LogicGates and LogicGates.IsLogicGate(bType) then return true end
		return false
	end
	
	-- If this block can SEND signals, clear all its outgoing connections
	if canSendSignals(blockType) then
		local attributes = block:GetAttributes()
		for name, value in pairs(attributes) do
			if string.sub(name, 1, 9) == "WireConn_" then
				local connectionId = string.sub(name, 10)
				-- Value might be "blockId" or "blockId:attachPoint"
				local targetId = string.match(value, "^([^:]+)")
				
				-- Remove from this block
				block:SetAttribute(name, nil)
				
				-- Remove back-reference from target block
				local targetBlock = findBlockById(blocksFolder, targetId)
				if targetBlock then
					targetBlock:SetAttribute(WiringSystem.GetInputRefAttributeName(connectionId), nil)
					ConnectionUpdatedRemote:FireAllClients(block, targetBlock, "removed", connectionId)
					
					-- Track this target for depowering
					affectedTargets[targetBlock] = true
				end
				
				clearedCount = clearedCount + 1
			end
		end
	end
	
	-- If this block can RECEIVE signals, clear all incoming connections TO it
	if canReceiveSignals(blockType) and blockId then
		for _, sourceBlock in ipairs(blocksFolder:GetChildren()) do
			local sourceType = sourceBlock:GetAttribute("BlockType")
			if not canSendSignals(sourceType) then continue end
			
			local attributes = sourceBlock:GetAttributes()
			for name, value in pairs(attributes) do
				if string.sub(name, 1, 9) == "WireConn_" then
					-- Value might be "blockId" or "blockId:attachPoint"
					local targetId = string.match(value, "^([^:]+)")
					
					if targetId == blockId then
						local connectionId = string.sub(name, 10)
						
						-- Remove from source block
						sourceBlock:SetAttribute(name, nil)
						
						-- Remove back-reference from this block
						block:SetAttribute(WiringSystem.GetInputRefAttributeName(connectionId), nil)
						
						ConnectionUpdatedRemote:FireAllClients(sourceBlock, block, "removed", connectionId)
						clearedCount = clearedCount + 1
						
						-- This block lost its connection, track it for depowering
						affectedTargets[block] = true
					end
				end
			end
		end
	end
	
	-- Depower affected targets that no longer have any connections
	for targetBlock, _ in pairs(affectedTargets) do
		local targetType = targetBlock:GetAttribute("BlockType")
		local lowerType = string.lower(targetType or "")
		
		-- Check if target still has any incoming connections
		local hasConnections = false
		local targetAttrs = targetBlock:GetAttributes()
		for attrName, _ in pairs(targetAttrs) do
			if string.sub(attrName, 1, 10) == "WireInput_" then
				hasConnections = true
				break
			end
		end
		
		-- If no connections remain, depower the device
		if not hasConnections then
			if string.find(lowerType, "piston") then
				-- Retract piston if extended
				local isExtended = targetBlock:GetAttribute("IsExtended") or false
				if isExtended then
					print("[Wiring] Retracting piston due to disconnection:", targetBlock.Name)
					triggerPiston(targetBlock, false) -- false = not powered, should retract
				end
			elseif string.find(lowerType, "lamp") or string.find(lowerType, "light") then
				-- Turn off lamp
				local isPowered = targetBlock:GetAttribute("IsPowered") or false
				if isPowered then
					print("[Wiring] Turning off lamp due to disconnection:", targetBlock.Name)
					setLightState(targetBlock, false)
				end
			elseif string.find(lowerType, "door") then
				-- Close door
				local isOpen = targetBlock:GetAttribute("IsOpen") or false
				if isOpen then
					print("[Wiring] Closing door due to disconnection:", targetBlock.Name)
					targetBlock:SetAttribute("IsOpen", false)
					local DoorStateChanged = Remotes:FindFirstChild("DoorStateChanged")
					if DoorStateChanged then
						DoorStateChanged:FireAllClients(targetBlock, false)
					end
				end
			elseif LogicGates and LogicGates.IsLogicGate(targetType) then
				-- Reset logic gate inputs
				local inputPoints = LogicGates.GetInputAttachPoints(targetType)
				for _, inputPoint in ipairs(inputPoints) do
					targetBlock:SetAttribute("Input_" .. inputPoint.Name, false)
				end
				-- Recalculate output
				local inputStates = {}
				for _, inputPoint in ipairs(inputPoints) do
					inputStates[inputPoint.Name] = false
				end
				local newOutput = LogicGates.ProcessGate(targetType, inputStates)
				local currentOutput = targetBlock:GetAttribute("IsOutputting") or false
				if newOutput ~= currentOutput then
					setLogicGateOutput(targetBlock, newOutput, blocksFolder)
				end
			end
		end
	end
	
	print("[Wiring] Cleared", clearedCount, "connections from", blockType)
end)

-- ============================================
-- CLEANUP ON BLOCK REMOVAL
-- ============================================

-- Listen for block removal to clean up connections
local function onBlockRemoved(block)
	-- Skip if being removed by save system (batch removal)
	if block:GetAttribute("BeingRemovedBySaveSystem") then return end
	
	-- Remove all wire attributes (they'll be orphaned anyway)
	local attributes = block:GetAttributes()
	for name, _ in pairs(attributes) do
		if string.sub(name, 1, 9) == "WireConn_" or string.sub(name, 1, 10) == "WireInput_" then
			block:SetAttribute(name, nil)
		end
	end
end

-- Connect to block removal for all build areas
for i = 1, GridConfig.TOTAL_PLOTS do
	local buildArea = workspace:FindFirstChild(GridConfig.BUILD_AREA_PREFIX .. i)
	if buildArea then
		local blocksFolder = buildArea:FindFirstChild("Blocks")
		if blocksFolder then
			blocksFolder.ChildRemoved:Connect(onBlockRemoved)
		end
	end
end

-- Also connect block removal for MegaPlot build area
local function setupMegaPlotWiringMonitor(megaPlotRoom)
	local megaBuildArea = megaPlotRoom:FindFirstChild("MegaPlotBuildArea")
	if megaBuildArea then
		local blocksFolder = megaBuildArea:FindFirstChild("Blocks")
		if blocksFolder then
			blocksFolder.ChildRemoved:Connect(onBlockRemoved)
		end
		megaBuildArea.ChildAdded:Connect(function(child)
			if child.Name == "Blocks" and child:IsA("Folder") then
				child.ChildRemoved:Connect(onBlockRemoved)
			end
		end)
	end
	megaPlotRoom.ChildAdded:Connect(function(child)
		if child.Name == "MegaPlotBuildArea" then
			local blocksFolder = child:FindFirstChild("Blocks")
			if blocksFolder then
				blocksFolder.ChildRemoved:Connect(onBlockRemoved)
			end
			child.ChildAdded:Connect(function(subChild)
				if subChild.Name == "Blocks" and subChild:IsA("Folder") then
					subChild.ChildRemoved:Connect(onBlockRemoved)
				end
			end)
		end
	end)
end

local megaPlotRoom = workspace:FindFirstChild("MegaPlotRoom")
if megaPlotRoom then
	setupMegaPlotWiringMonitor(megaPlotRoom)
end
workspace.ChildAdded:Connect(function(child)
	if child.Name == "MegaPlotRoom" then
		setupMegaPlotWiringMonitor(child)
	end
end)

-- ============================================
-- EXTERNAL TRIGGER SUPPORT
-- ============================================

-- Listen for TriggerPiston events from ButtonHandler (for logic gate -> piston propagation)
local TriggerPistonRemote = Remotes:FindFirstChild("TriggerPiston")
if not TriggerPistonRemote then
	TriggerPistonRemote = Instance.new("BindableEvent")
	TriggerPistonRemote.Name = "TriggerPiston"
	TriggerPistonRemote.Parent = Remotes
end

TriggerPistonRemote.Event:Connect(function(pistonBlock, isPowered)
	if not pistonBlock then return end
	print("[Wiring] TriggerPiston event received for", pistonBlock.Name, "powered:", isPowered)
	triggerPiston(pistonBlock, isPowered)
end)

print("[WiringHandler] Initialized")
