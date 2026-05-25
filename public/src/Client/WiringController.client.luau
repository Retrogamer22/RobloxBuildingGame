--[[
	WiringController
	Client-side controller for the wiring tool
	
	When holding the wiring tool:
	- Click ANY wireable block to start a connection
	- If you click an OUT source (button, lever), only IN targets show dots
	- If you click an IN target (door, lamp), only OUT sources show dots
	- Click a valid target to complete the connection
	- Right-click or click empty space to cancel
	
	Terminology:
	- OUT source: Sends signals (buttons, levers, pressure plates)
	- IN target: Receives signals (doors, lamps, lights)
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

-- Mobile detection
local IsMobile = UserInputService.TouchEnabled and not UserInputService.MouseEnabled

-- Wait for modules
local WiringSystem = require(ReplicatedStorage:WaitForChild("WiringSystem"))

-- Try to load LogicGates module
local LogicGates = nil
pcall(function()
	LogicGates = require(ReplicatedStorage:WaitForChild("LogicGates", 5))
end)

-- Wait for remotes
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local CreateConnectionRemote = Remotes:WaitForChild("CreateWireConnection")
local RemoveConnectionRemote = Remotes:WaitForChild("RemoveWireConnection")
local ClearAllConnectionsRemote = Remotes:WaitForChild("ClearAllWireConnections")
local ActivateInputRemote = Remotes:WaitForChild("ActivateWireInput")
local WireStateChangedRemote = Remotes:WaitForChild("WireStateChanged")
local ConnectionUpdatedRemote = Remotes:WaitForChild("WireConnectionUpdated")

-- Constants
local REACH_DISTANCE = 50
local WIRE_PART_THICKNESS = 0.15
local CONNECTION_DOT_SIZE = 0.6
local HOVER_DOT_SIZE = 0.8
local ATTACH_POINT_DOT_SIZE = 0.7
local DOT_CLICK_RADIUS = 2.0 -- How close you need to click to a dot

-- Colors
local Colors = {
	OutSource = Color3.fromRGB(255, 180, 50),      -- Orange/gold for OUT sources (buttons, etc)
	InTarget = Color3.fromRGB(80, 180, 255),       -- Blue for IN targets (doors, lamps)
	LogicGate = Color3.fromRGB(200, 100, 255),     -- Purple for logic gates
	AttachInput = Color3.fromRGB(80, 180, 255),    -- Blue for input attach points
	AttachOutput = Color3.fromRGB(255, 180, 50),   -- Orange for output attach points
	Selected = Color3.fromRGB(50, 255, 100),       -- Green for currently selected
	ValidTarget = Color3.fromRGB(50, 255, 100),    -- Green for valid connection targets
	InvalidTarget = Color3.fromRGB(255, 80, 80),   -- Red for invalid
	Wire = Color3.fromRGB(255, 50, 50),            -- Red wire
	WireActive = Color3.fromRGB(255, 255, 50),     -- Yellow when active
	ConnectionDot = Color3.fromRGB(100, 255, 100), -- Bright green connection dots
	HoverHighlight = Color3.fromRGB(255, 255, 255), -- White hover
	ClearMode = Color3.fromRGB(255, 80, 80),       -- Red for clear mode
	ClearDot = Color3.fromRGB(255, 100, 100),      -- Red dots for clearing
}

-- State
local WiringModeActive = false
local ClearModeActive = false        -- Shift held = clear mode
local SelectedBlock = nil           -- The block we've selected (first click)
local SelectedBlockType = nil       -- "out", "in", or "logic" - what type of block is selected
local SelectedAttachPoint = nil     -- For logic gates: which attach point is selected
local ConnectionDots = {}           -- Table of dot instances showing valid targets
local AttachPointDots = {}          -- Dots for logic gate attach points
local ClearModeDots = {}            -- Dots showing blocks with connections (for clear mode)
local WireVisuals = {}              -- Table of wire line instances
local HoverHighlight = nil          -- Highlight for block we're hovering over
local SelectionHighlight = nil      -- Highlight for selected block
local HoverDot = nil                -- Dot that appears when hovering over valid target
local PendingWire = nil             -- Wire from selected block to player/cursor

-- ============================================
-- HELPER FUNCTIONS
-- ============================================

local function getBlocksFolder()
	local plotData = _G.PlotClient and _G.PlotClient.GetMyPlot()
	if plotData and plotData.BuildArea then
		return plotData.BuildArea:FindFirstChild("Blocks")
	end
	return nil
end

local function isWiringToolSelected()
	if _G.InventoryController then
		local selected = _G.InventoryController.GetSelectedBlock()
		if selected and selected.IsWiringTool then
			return true
		end
	end
	return false
end

local function getBlockFromInstance(instance)
	if not instance then return nil end
	
	if instance:GetAttribute("BlockType") then
		return instance
	elseif instance.Parent and instance.Parent:GetAttribute("BlockType") then
		return instance.Parent
	elseif instance.Parent and instance.Parent.Parent and instance.Parent.Parent:GetAttribute("BlockType") then
		return instance.Parent.Parent
	end
	
	return nil
end

local function raycastForBlock()
	local mousePos = UserInputService:GetMouseLocation()
	local ray = Camera:ViewportPointToRay(mousePos.X, mousePos.Y)
	
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = {LocalPlayer.Character}
	
	local result = workspace:Raycast(ray.Origin, ray.Direction * REACH_DISTANCE, raycastParams)
	
	if result and result.Instance then
		return getBlockFromInstance(result.Instance), result.Position
	end
	
	return nil, nil
end

-- Check if block is an OUT source (sends signals)
local function isOutSource(blockType)
	return WiringSystem.IsInput(blockType) -- Inputs in the system = OUT sources (send signals)
end

-- Check if block is an IN target (receives signals)
local function isInTarget(blockType)
	return WiringSystem.IsOutput(blockType) -- Outputs in the system = IN targets (receive signals)
end

-- Check if block is a logic gate
local function isLogicGate(blockType)
	if LogicGates and LogicGates.IsLogicGate then
		return LogicGates.IsLogicGate(blockType)
	end
	return false
end

-- Get what type of wireable block this is
local function getWireableType(blockType)
	if isLogicGate(blockType) then
		return "logic"
	elseif isOutSource(blockType) then
		return "out"
	elseif isInTarget(blockType) then
		return "in"
	end
	return nil
end

-- ============================================
-- VISUAL HELPERS
-- ============================================

local function getBlockCenter(block)
	if block:IsA("Model") then
		local primary = block.PrimaryPart or block:FindFirstChildWhichIsA("BasePart")
		if primary then return primary.Position end
		return block:GetPivot().Position
	elseif block:IsA("BasePart") then
		return block.Position
	end
	return Vector3.new(0, 0, 0)
end

local function getBlockTopCenter(block)
	local center = getBlockCenter(block)
	local size = Vector3.new(4, 4, 4) -- Default block size
	
	if block:IsA("Model") then
		local primary = block.PrimaryPart or block:FindFirstChildWhichIsA("BasePart")
		if primary then
			size = primary.Size
		end
	elseif block:IsA("BasePart") then
		size = block.Size
	end
	
	return center + Vector3.new(0, size.Y / 2 + 0.3, 0)
end

local function createHighlight(block, color, name)
	local highlight = Instance.new("Highlight")
	highlight.Name = name or "WireHighlight"
	highlight.Adornee = block
	highlight.FillColor = color
	highlight.FillTransparency = 0.7
	highlight.OutlineColor = color
	highlight.OutlineTransparency = 0.3
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Parent = LocalPlayer.PlayerGui
	return highlight
end

local function createConnectionDot(position, color, size)
	local dot = Instance.new("Part")
	dot.Name = "ConnectionDot"
	dot.Shape = Enum.PartType.Ball
	dot.Size = Vector3.new(size, size, size)
	dot.Position = position
	dot.Anchored = true
	dot.CanCollide = false
	dot.Material = Enum.Material.Neon
	dot.Color = color
	dot.CastShadow = false
	dot.Parent = workspace
	
	return dot
end

local function createWireLine(startPos, endPos, color, isActive)
	local distance = (endPos - startPos).Magnitude
	if distance < 0.1 then distance = 0.1 end -- Prevent zero-size parts
	local midpoint = (startPos + endPos) / 2
	
	local wirePart = Instance.new("Part")
	wirePart.Name = "WireLine"
	wirePart.Anchored = true
	wirePart.CanCollide = false
	wirePart.Material = Enum.Material.Neon
	wirePart.Color = color
	wirePart.Size = Vector3.new(WIRE_PART_THICKNESS, WIRE_PART_THICKNESS, distance)
	wirePart.CFrame = CFrame.lookAt(midpoint, endPos)
	wirePart.CastShadow = false
	wirePart.Parent = workspace
	
	return wirePart
end

local function updatePendingWire(startPos, endPos, color)
	if not PendingWire then
		PendingWire = Instance.new("Part")
		PendingWire.Name = "PendingWire"
		PendingWire.Anchored = true
		PendingWire.CanCollide = false
		PendingWire.Material = Enum.Material.Neon
		PendingWire.CastShadow = false
		PendingWire.Parent = workspace
	end
	
	local distance = (endPos - startPos).Magnitude
	if distance < 0.1 then distance = 0.1 end
	local midpoint = (startPos + endPos) / 2
	
	PendingWire.Color = color
	PendingWire.Size = Vector3.new(WIRE_PART_THICKNESS * 1.5, WIRE_PART_THICKNESS * 1.5, distance)
	PendingWire.CFrame = CFrame.lookAt(midpoint, endPos)
end

local function clearPendingWire()
	if PendingWire then
		PendingWire:Destroy()
		PendingWire = nil
	end
end

-- Get attach point position for a logic gate (must be before updateWireVisuals)
local function getAttachPointPosition(block, attachPointName)
	if not LogicGates then return getBlockTopCenter(block) end
	
	-- Find the attach point part directly
	local attachPart = block:FindFirstChild(attachPointName)
	if not attachPart then
		-- Search in descendants
		for _, desc in ipairs(block:GetDescendants()) do
			if desc.Name == attachPointName and desc:IsA("BasePart") then
				attachPart = desc
				break
			end
		end
	end
	
	if attachPart and attachPart:IsA("BasePart") then
		-- Return position above the part
		return attachPart.Position + Vector3.new(0, 0.5, 0)
	end
	
	-- Fallback to block top center
	return getBlockTopCenter(block)
end

-- ============================================
-- WIRE VISUALS (existing connections) - MUST BE BEFORE CLEAR MODE
-- ============================================

local function clearWireVisuals()
	for _, visual in pairs(WireVisuals) do
		if visual and visual.Parent then
			visual:Destroy()
		end
	end
	WireVisuals = {}
end

local function updateWireVisuals()
	clearWireVisuals()
	
	local blocksFolder = getBlocksFolder()
	if not blocksFolder then return end
	
	-- Find all blocks that can SEND signals and draw wires to their targets
	for _, block in ipairs(blocksFolder:GetChildren()) do
		local blockType = block:GetAttribute("BlockType")
		if not blockType then continue end
		
		-- Check if this block can send signals (OUT source or logic gate)
		local canSend = isOutSource(blockType) or isLogicGate(blockType)
		if not canSend then continue end
		
		local connections = WiringSystem.GetOutputConnectionsDetailed(block)
		local sourcePos = getBlockCenter(block)
		
		for _, conn in ipairs(connections) do
			-- Find the target block
			for _, otherBlock in ipairs(blocksFolder:GetChildren()) do
				if otherBlock:GetAttribute("BlockId") == conn.blockId then
					local targetPos
					
					-- If target has an attach point, use that position
					if conn.attachPoint then
						targetPos = getAttachPointPosition(otherBlock, conn.attachPoint)
					else
						targetPos = getBlockCenter(otherBlock)
					end
					
					-- Check if signal is active
					local isActive = block:GetAttribute("IsActivated") or block:GetAttribute("IsOutputting") or false
					local color = isActive and Colors.WireActive or Colors.Wire
					
					local wire = createWireLine(sourcePos, targetPos, color, isActive)
					table.insert(WireVisuals, wire)
					break
				end
			end
		end
	end
end

-- ============================================
-- CONNECTION DOTS (show valid targets)
-- ============================================

local function clearConnectionDots()
	for _, dotInfo in pairs(ConnectionDots) do
		-- Handle both old format (just dot) and new format (table with dot property)
		local dot = dotInfo.dot or dotInfo
		if dot and dot.Parent then
			dot:Destroy()
		end
	end
	ConnectionDots = {}
end

-- Clear attach point dots
local function clearAttachPointDots()
	for _, dotInfo in pairs(AttachPointDots) do
		local dot = dotInfo.dot or dotInfo -- Handle both formats
		if dot and dot.Parent then
			dot:Destroy()
		end
	end
	AttachPointDots = {}
end

-- Show dots on valid connection targets
local function showConnectionDots()
	clearConnectionDots()
	
	if not SelectedBlock or not SelectedBlockType then return end
	
	local blocksFolder = getBlocksFolder()
	if not blocksFolder then return end
	
	-- Determine what we're connecting FROM
	local connectingFromOutput = false -- Are we connecting FROM an output (sending signal)?
	
	if SelectedBlockType == "out" then
		-- OUT source sends signals -> look for things that RECEIVE (IN targets, logic gate inputs)
		connectingFromOutput = true
	elseif SelectedBlockType == "in" then
		-- IN target receives signals -> look for things that SEND (OUT sources, logic gate outputs)
		connectingFromOutput = false
	elseif SelectedBlockType == "logic" then
		-- Logic gate: depends on which attach point is selected
		if SelectedAttachPoint then
			local selectedBlockType = SelectedBlock:GetAttribute("BlockType")
			local attachPoints = LogicGates and LogicGates.GetAttachPoints(selectedBlockType) or {}
			for _, ap in ipairs(attachPoints) do
				if ap.Name == SelectedAttachPoint then
					connectingFromOutput = (ap.Type == "output")
					break
				end
			end
		end
	end
	
	for _, block in ipairs(blocksFolder:GetChildren()) do
		if block == SelectedBlock then continue end
		
		local blockType = block:GetAttribute("BlockType")
		if not blockType then continue end
		
		local wireableType = getWireableType(blockType)
		
		if wireableType == "logic" and LogicGates then
			-- For logic gates, show dots on specific attach points
			local attachPoints = LogicGates.GetAttachPoints(blockType)
			if attachPoints then
				for _, ap in ipairs(attachPoints) do
					-- Show input attach points if we're sending FROM an output
					-- Show output attach points if we're receiving INTO an input
					local isValidAttachPoint = false
					if connectingFromOutput and ap.Type == "input" then
						isValidAttachPoint = true
					elseif not connectingFromOutput and ap.Type == "output" then
						isValidAttachPoint = true
					end
					
					if isValidAttachPoint then
						local dotPos = getAttachPointPosition(block, ap.Name)
						local dotColor = (ap.Type == "input") and Colors.AttachInput or Colors.AttachOutput
						local dot = createConnectionDot(dotPos, dotColor, CONNECTION_DOT_SIZE)
						-- Store with block and attach point info (use BlockId for uniqueness)
						local blockId = block:GetAttribute("BlockId") or block.Name
						local key = blockId .. "_" .. ap.Name
						ConnectionDots[key] = {
							dot = dot,
							block = block,
							attachPoint = ap.Name,
							attachType = ap.Type,
						}
						print("[Wiring] Created dot for", blockType, ap.Name, "(", ap.Type, ") at", dotPos)
					end
				end
			end
		elseif wireableType == "in" and connectingFromOutput then
			-- IN target can receive from OUT source
			local dotPos = getBlockTopCenter(block)
			local dot = createConnectionDot(dotPos, Colors.InTarget, CONNECTION_DOT_SIZE)
			ConnectionDots[block] = { dot = dot, block = block }
		elseif wireableType == "out" and not connectingFromOutput then
			-- OUT source can send to IN target
			local dotPos = getBlockTopCenter(block)
			local dot = createConnectionDot(dotPos, Colors.OutSource, CONNECTION_DOT_SIZE)
			ConnectionDots[block] = { dot = dot, block = block }
		end
	end
end

-- ============================================
-- CLEAR MODE (Shift held)
-- ============================================

local function clearClearModeDots()
	for _, dot in pairs(ClearModeDots) do
		if dot and dot.Parent then
			dot:Destroy()
		end
	end
	ClearModeDots = {}
end

local function blockHasConnections(block)
	local blockType = block:GetAttribute("BlockType")
	if not blockType then return false end
	
	-- Check if it's an OUT source with connections
	if isOutSource(blockType) then
		local connections = WiringSystem.GetOutputConnections(block)
		if #connections > 0 then
			return true, "out", #connections
		end
	end
	
	-- Check if it's a logic gate with connections
	if isLogicGate(blockType) then
		local connections = WiringSystem.GetOutputConnectionsDetailed(block)
		if #connections > 0 then
			return true, "logic", #connections
		end
	end
	
	-- Check if it's an IN target with connections
	if isInTarget(blockType) then
		local connections = WiringSystem.GetInputConnections(block)
		if #connections > 0 then
			return true, "in", #connections
		end
	end
	
	return false, nil, 0
end

local function showClearModeDots()
	clearClearModeDots()
	
	local blocksFolder = getBlocksFolder()
	if not blocksFolder then return end
	
	for _, block in ipairs(blocksFolder:GetChildren()) do
		local hasConnections, connType, count = blockHasConnections(block)
		
		if hasConnections then
			local dotPos = getBlockTopCenter(block)
			local dot = createConnectionDot(dotPos, Colors.ClearDot, CONNECTION_DOT_SIZE * 1.2)
			ClearModeDots[block] = dot
		end
	end
end

local function tryClearConnections(block)
	if not block then return false end
	
	local hasConnections, connType, count = blockHasConnections(block)
	if not hasConnections then return false end
	
	print("[Wiring] Clearing all connections from:", block:GetAttribute("BlockType"), "(", count, "connections)")
	
	-- Fire remote to clear all connections
	ClearAllConnectionsRemote:FireServer(block)
	
	-- Update visuals after a short delay
	task.delay(0.15, function()
		updateWireVisuals()
		if ClearModeActive then
			showClearModeDots()
		end
	end)
	
	return true
end

-- ============================================
-- SELECTION AND CONNECTION
-- ============================================

local function clearSelection()
	SelectedBlock = nil
	SelectedBlockType = nil
	SelectedAttachPoint = nil
	
	if SelectionHighlight then
		SelectionHighlight:Destroy()
		SelectionHighlight = nil
	end
	
	clearConnectionDots()
	clearAttachPointDots()
	clearPendingWire()
end

-- Clear mode functions (need clearSelection to be defined first)
local function enterClearMode()
	if ClearModeActive then return end
	
	ClearModeActive = true
	clearSelection() -- Cancel any pending connection
	showClearModeDots()
	print("[Wiring] Clear mode - click a red dot to remove all connections from that block")
end

local function exitClearMode()
	if not ClearModeActive then return end
	
	ClearModeActive = false
	clearClearModeDots()
	print("[Wiring] Exited clear mode")
end

-- Show attach point dots on a logic gate for selection
local function showAttachPointDotsOnBlock(block)
	clearAttachPointDots()
	
	local blockType = block:GetAttribute("BlockType")
	if not LogicGates then return end
	
	local attachPoints = LogicGates.GetAttachPoints(blockType)
	if not attachPoints then return end
	
	for _, ap in ipairs(attachPoints) do
		local dotPos = getAttachPointPosition(block, ap.Name)
		local dotColor = (ap.Type == "input") and Colors.AttachInput or Colors.AttachOutput
		local dot = createConnectionDot(dotPos, dotColor, ATTACH_POINT_DOT_SIZE)
		AttachPointDots[ap.Name] = {
			dot = dot,
			block = block,
			attachPoint = ap.Name,
			attachType = ap.Type,
		}
	end
	
	print("[Wiring] Showing", #attachPoints, "attach points - click a dot to select")
end

local function selectBlock(block, attachPointName)
	clearSelection()
	
	local blockType = block:GetAttribute("BlockType")
	local wireableType = getWireableType(blockType)
	
	if not wireableType then
		print("[Wiring] Block is not wireable:", blockType)
		return
	end
	
	SelectedBlock = block
	SelectedBlockType = wireableType
	
	-- Create selection highlight
	SelectionHighlight = createHighlight(block, Colors.Selected, "SelectionHighlight")
	SelectionHighlight.FillTransparency = 0.5
	
	-- Handle logic gates specially
	if wireableType == "logic" and LogicGates then
		if attachPointName then
			-- Attach point already selected, show connection targets
			SelectedAttachPoint = attachPointName
			showConnectionDots()
			print("[Wiring] Selected logic gate attach point:", blockType, "->", attachPointName, "- click a valid target")
		else
			-- Show attach point dots for user to select
			showAttachPointDotsOnBlock(block)
			print("[Wiring] Selected logic gate:", blockType, "- click an attach point (blue=input, orange=output)")
		end
		return
	end
	
	-- For regular blocks, show connection targets immediately
	showConnectionDots()
	
	local typeLabel = (wireableType == "out") and "OUT source" or "IN target"
	print("[Wiring] Selected", typeLabel .. ":", blockType, "- click a valid target to connect")
end

local function tryCreateConnection(targetBlock, targetAttachPoint)
	if not SelectedBlock then return end
	
	local selectedBlockType = SelectedBlock:GetAttribute("BlockType")
	local targetBlockType = targetBlock:GetAttribute("BlockType")
	
	-- Determine which block is the source (sends signal) and which is the target (receives signal)
	local sourceBlock, targetReceiverBlock
	local sourceAttachPoint, targetReceiverAttachPoint
	
	if SelectedBlockType == "out" then
		-- OUT source sends to target
		sourceBlock = SelectedBlock
		targetReceiverBlock = targetBlock
		sourceAttachPoint = nil
		targetReceiverAttachPoint = targetAttachPoint
	elseif SelectedBlockType == "logic" and SelectedAttachPoint then
		-- Logic gate with selected attach point
		local attachPoints = LogicGates and LogicGates.GetAttachPoints(selectedBlockType) or {}
		local selectedType = nil
		for _, ap in ipairs(attachPoints) do
			if ap.Name == SelectedAttachPoint then
				selectedType = ap.Type
				break
			end
		end
		
		if selectedType == "output" then
			-- Logic gate output sends to target
			sourceBlock = SelectedBlock
			targetReceiverBlock = targetBlock
			sourceAttachPoint = SelectedAttachPoint
			targetReceiverAttachPoint = targetAttachPoint
		else
			-- Logic gate input receives from target (target must be an output)
			sourceBlock = targetBlock
			targetReceiverBlock = SelectedBlock
			sourceAttachPoint = targetAttachPoint
			targetReceiverAttachPoint = SelectedAttachPoint
		end
	else
		-- IN target receives from target (target must be an output)
		sourceBlock = targetBlock
		targetReceiverBlock = SelectedBlock
		sourceAttachPoint = targetAttachPoint
		targetReceiverAttachPoint = nil
	end
	
	local sourceType = sourceBlock:GetAttribute("BlockType")
	local receiverType = targetReceiverBlock:GetAttribute("BlockType")
	
	local sourceInfo = sourceAttachPoint and (sourceType .. ":" .. sourceAttachPoint) or sourceType
	local targetInfo = targetReceiverAttachPoint and (receiverType .. ":" .. targetReceiverAttachPoint) or receiverType
	print("[Wiring] Creating connection:", sourceInfo, "->", targetInfo)
	
	-- Send to server with attach point info
	CreateConnectionRemote:FireServer(sourceBlock, targetReceiverBlock, sourceAttachPoint, targetReceiverAttachPoint)
	
	-- Clear selection
	clearSelection()
	
	-- Update wire visuals after a short delay
	task.delay(0.1, updateWireVisuals)
end

local function isValidTarget(block, attachPointName)
	if not SelectedBlock or not SelectedBlockType then return false end
	if block == SelectedBlock then return false end
	
	local blockType = block:GetAttribute("BlockType")
	local wireableType = getWireableType(blockType)
	
	-- Determine what we're connecting FROM
	local connectingFromOutput = false
	
	if SelectedBlockType == "out" then
		connectingFromOutput = true
	elseif SelectedBlockType == "in" then
		connectingFromOutput = false
	elseif SelectedBlockType == "logic" and SelectedAttachPoint then
		local selectedBlockType = SelectedBlock:GetAttribute("BlockType")
		local attachPoints = LogicGates and LogicGates.GetAttachPoints(selectedBlockType) or {}
		for _, ap in ipairs(attachPoints) do
			if ap.Name == SelectedAttachPoint then
				connectingFromOutput = (ap.Type == "output")
				break
			end
		end
	else
		-- Logic gate without attach point selected - not ready to connect
		return false
	end
	
	-- Check if target is valid based on what we're connecting from
	if wireableType == "logic" and LogicGates then
		-- For logic gates, need to check the specific attach point
		if attachPointName then
			local attachPoints = LogicGates.GetAttachPoints(blockType)
			for _, ap in ipairs(attachPoints) do
				if ap.Name == attachPointName then
					if connectingFromOutput then
						return ap.Type == "input" -- Output connects to input
					else
						return ap.Type == "output" -- Input receives from output
					end
				end
			end
		end
		return false
	elseif wireableType == "in" then
		return connectingFromOutput -- IN targets receive from outputs
	elseif wireableType == "out" then
		return not connectingFromOutput -- OUT sources send to inputs
	end
	
	return false
end

-- ============================================
-- INPUT HANDLING
-- ============================================

-- Check if a position is near an attach point dot
local function findNearbyAttachPointDot(hitPos, dotsTable)
	local closestDist = math.huge
	local closestDot = nil
	
	for key, dotInfo in pairs(dotsTable) do
		local dot = dotInfo.dot or dotInfo -- Handle both formats
		if dot and dot.Parent then
			local dist = (dot.Position - hitPos).Magnitude
			if dist < DOT_CLICK_RADIUS and dist < closestDist then
				closestDist = dist
				closestDot = dotInfo
			end
		end
	end
	
	return closestDot
end

local function handleRightClick()
	-- Clear mode: click to clear connections
	if ClearModeActive then
		local block, hitPos = raycastForBlock()
		if block then
			local hasConnections = blockHasConnections(block)
			if hasConnections then
				tryClearConnections(block)
			else
				print("[Wiring] This block has no connections to clear")
			end
		end
		return
	end
	
	-- Normal mode: select/connect
	local block, hitPos = raycastForBlock()
	
	if not block and not hitPos then
		-- Clicked empty space - cancel selection
		clearSelection()
		return
	end
	
	-- PRIORITY 1: If we have a selected logic gate but no attach point, 
	-- check if clicking on attach point FIRST (even if clicking same block)
	if SelectedBlock and SelectedBlockType == "logic" and not SelectedAttachPoint and hitPos then
		local clickedAttachPoint = findNearbyAttachPointDot(hitPos, AttachPointDots)
		if clickedAttachPoint then
			-- Select this attach point
			SelectedAttachPoint = clickedAttachPoint.attachPoint
			clearAttachPointDots()
			showConnectionDots()
			print("[Wiring] Selected attach point:", clickedAttachPoint.attachPoint, "(", clickedAttachPoint.attachType, ")")
			return
		end
		
		-- If clicked on the same logic gate but not on an attach point, do nothing
		-- (user needs to click an attach point)
		if block == SelectedBlock then
			print("[Wiring] Click on a colored dot to select an attach point")
			return
		end
	end
	
	-- PRIORITY 2: Check if clicking on a connection dot (target attach point)
	if SelectedBlock and hitPos then
		local clickedDot = findNearbyAttachPointDot(hitPos, ConnectionDots)
		if clickedDot then
			if clickedDot.attachPoint then
				-- Clicking on a logic gate attach point
				if isValidTarget(clickedDot.block, clickedDot.attachPoint) then
					tryCreateConnection(clickedDot.block, clickedDot.attachPoint)
					return
				end
			else
				-- Regular block dot (no attach point)
				if isValidTarget(clickedDot.block) then
					tryCreateConnection(clickedDot.block)
					return
				end
			end
		end
	end
	
	if not block then
		clearSelection()
		return
	end
	
	local blockType = block:GetAttribute("BlockType")
	local wireableType = getWireableType(blockType)
	
	-- If no selection, start new selection
	if not SelectedBlock then
		if wireableType then
			selectBlock(block)
		else
			print("[Wiring] This block cannot be wired:", blockType or "unknown")
		end
		return
	end
	
	-- We have a selection with attach point ready
	-- Check if this is a valid target
	if wireableType ~= "logic" and isValidTarget(block) then
		tryCreateConnection(block)
	elseif block == SelectedBlock then
		-- Clicked same block - deselect
		clearSelection()
	elseif wireableType then
		-- Clicked different wireable block - switch selection
		selectBlock(block)
	else
		-- Clicked non-wireable block - cancel
		clearSelection()
	end
end

local function handleLeftClick()
	-- Left click cancels selection (both modes)
	if SelectedBlock then
		clearSelection()
		print("[Wiring] Selection cancelled")
	end
end

-- Input connections
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if not WiringModeActive then return end
	
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		handleRightClick()
	elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
		handleLeftClick()
	elseif input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.RightShift then
		enterClearMode()
	end
end)

UserInputService.InputEnded:Connect(function(input, gameProcessed)
	if not WiringModeActive then return end
	
	if input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.RightShift then
		exitClearMode()
	end
end)

-- Mobile touch input - tap acts like right-click for wiring
if IsMobile then
	UserInputService.TouchTap:Connect(function(touchPositions, gameProcessed)
		if gameProcessed then return end
		if not WiringModeActive then return end
		
		-- Ignore taps on mobile button areas
		local screenSize = Camera.ViewportSize
		local pos = touchPositions[1]
		if pos then
			-- Ignore left side (joystick), bottom (hotbar), right side (buttons)
			if pos.X < screenSize.X * 0.25 then return end
			if pos.Y > screenSize.Y - 80 then return end
			if pos.X > screenSize.X - 100 and pos.Y < 450 then return end
		end
		
		handleRightClick() -- Tap does the same as right-click
	end)
end

-- ============================================
-- HOVER VISUALS
-- ============================================

local function getPlayerPosition()
	local character = LocalPlayer.Character
	if character then
		local hrp = character:FindFirstChild("HumanoidRootPart")
		if hrp then
			return hrp.Position
		end
	end
	return Camera.CFrame.Position
end

local function updateHoverVisuals()
	local block, hitPos = raycastForBlock()
	
	-- Clear existing hover visuals
	if HoverHighlight and (not block or HoverHighlight.Adornee ~= block) then
		HoverHighlight:Destroy()
		HoverHighlight = nil
	end
	
	if HoverDot then
		HoverDot:Destroy()
		HoverDot = nil
	end
	
	-- Handle clear mode differently
	if ClearModeActive then
		clearPendingWire()
		
		if block then
			local hasConnections = blockHasConnections(block)
			
			if hasConnections then
				-- Show red highlight for blocks with connections
				if not HoverHighlight then
					HoverHighlight = createHighlight(block, Colors.ClearMode, "HoverHighlight")
					HoverHighlight.FillTransparency = 0.6
				else
					HoverHighlight.Adornee = block
					HoverHighlight.FillColor = Colors.ClearMode
					HoverHighlight.OutlineColor = Colors.ClearMode
				end
				
				-- Show larger dot
				local dotPos = getBlockTopCenter(block)
				HoverDot = createConnectionDot(dotPos, Colors.ClearMode, HOVER_DOT_SIZE)
			end
		end
		return
	end
	
	-- Normal mode: Update pending wire from selected block to player
	if SelectedBlock then
		local startPos = getBlockCenter(SelectedBlock)
		local endPos
		
		-- If hovering over valid target, wire goes to that block
		if block and isValidTarget(block) then
			endPos = getBlockCenter(block)
			updatePendingWire(startPos, endPos, Colors.ValidTarget)
		else
			-- Wire follows player
			endPos = getPlayerPosition()
			updatePendingWire(startPos, endPos, Colors.Selected)
		end
	else
		clearPendingWire()
	end
	
	if not block then return end
	
	local blockType = block:GetAttribute("BlockType")
	local wireableType = getWireableType(blockType)
	
	-- Determine hover color based on context
	local hoverColor
	
	if block == SelectedBlock then
		hoverColor = Colors.Selected
	elseif SelectedBlock then
		-- We have a selection - show if this is valid target
		if isValidTarget(block) then
			hoverColor = Colors.ValidTarget
			-- Show enlarged dot for valid hover target
			local dotPos = getBlockTopCenter(block)
			HoverDot = createConnectionDot(dotPos, Colors.ValidTarget, HOVER_DOT_SIZE)
		elseif wireableType then
			hoverColor = (wireableType == "out") and Colors.OutSource or Colors.InTarget
		else
			hoverColor = Colors.InvalidTarget
		end
	else
		-- No selection - show block type or invalid
		if wireableType then
			hoverColor = (wireableType == "out") and Colors.OutSource or Colors.InTarget
		else
			-- Non-wireable block - subtle indicator
			return -- Don't show highlight for non-wireable blocks
		end
	end
	
	-- Create or update highlight
	if not HoverHighlight then
		HoverHighlight = createHighlight(block, hoverColor, "HoverHighlight")
		HoverHighlight.FillTransparency = 0.8
	else
		HoverHighlight.Adornee = block
		HoverHighlight.FillColor = hoverColor
		HoverHighlight.OutlineColor = hoverColor
	end
end

-- ============================================
-- MOBILE WIRING UI
-- ============================================

local WiringMobileUI = nil
local ClearModeToggle = nil

local function createWiringMobileUI()
	if not IsMobile then return end
	if WiringMobileUI then return end
	
	WiringMobileUI = Instance.new("ScreenGui")
	WiringMobileUI.Name = "WiringMobileUI"
	WiringMobileUI.ResetOnSpawn = false
	WiringMobileUI.Enabled = false
	WiringMobileUI.Parent = PlayerGui
	
	-- Clear mode toggle button
	ClearModeToggle = Instance.new("TextButton")
	ClearModeToggle.Name = "ClearModeToggle"
	ClearModeToggle.Size = UDim2.new(0, 80, 0, 50)
	ClearModeToggle.Position = UDim2.new(0, 20, 0.5, -25)
	ClearModeToggle.BackgroundColor3 = Color3.fromRGB(80, 60, 60)
	ClearModeToggle.BackgroundTransparency = 0.3
	ClearModeToggle.Text = "\u{1F5D1}\nClear"
	ClearModeToggle.TextColor3 = Color3.fromRGB(255, 255, 255)
	ClearModeToggle.TextSize = 14
	ClearModeToggle.Font = Enum.Font.GothamBold
	ClearModeToggle.Parent = WiringMobileUI
	
	local toggleCorner = Instance.new("UICorner")
	toggleCorner.CornerRadius = UDim.new(0, 10)
	toggleCorner.Parent = ClearModeToggle
	
	-- Cancel selection button
	local cancelBtn = Instance.new("TextButton")
	cancelBtn.Name = "CancelButton"
	cancelBtn.Size = UDim2.new(0, 80, 0, 50)
	cancelBtn.Position = UDim2.new(0, 20, 0.5, 35)
	cancelBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 80)
	cancelBtn.BackgroundTransparency = 0.3
	cancelBtn.Text = "\u{274C}\nCancel"
	cancelBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	cancelBtn.TextSize = 14
	cancelBtn.Font = Enum.Font.GothamBold
	cancelBtn.Parent = WiringMobileUI
	
	local cancelCorner = Instance.new("UICorner")
	cancelCorner.CornerRadius = UDim.new(0, 10)
	cancelCorner.Parent = cancelBtn
	
	ClearModeToggle.MouseButton1Click:Connect(function()
		if ClearModeActive then
			exitClearMode()
			ClearModeToggle.BackgroundColor3 = Color3.fromRGB(80, 60, 60)
			ClearModeToggle.Text = "\u{1F5D1}\nClear"
		else
			enterClearMode()
			ClearModeToggle.BackgroundColor3 = Color3.fromRGB(200, 80, 80)
			ClearModeToggle.Text = "\u{1F5D1}\nCLEAR ON"
		end
	end)
	
	cancelBtn.MouseButton1Click:Connect(function()
		clearSelection()
	end)
end

local function showWiringMobileUI()
	if WiringMobileUI then
		WiringMobileUI.Enabled = true
	end
end

local function hideWiringMobileUI()
	if WiringMobileUI then
		WiringMobileUI.Enabled = false
	end
	if ClearModeToggle then
		ClearModeToggle.BackgroundColor3 = Color3.fromRGB(80, 60, 60)
		ClearModeToggle.Text = "\u{1F5D1}\nClear"
	end
end

-- Create mobile UI early
createWiringMobileUI()

-- ============================================
-- MODE MANAGEMENT
-- ============================================

local function enterWiringMode()
	if WiringModeActive then return end
	
	WiringModeActive = true
	print("[Wiring] Wiring mode active - click any wireable block to start")
	
	updateWireVisuals()
	showWiringMobileUI()
end

local function exitWiringMode()
	if not WiringModeActive then return end
	
	WiringModeActive = false
	ClearModeActive = false
	print("[Wiring] Exiting wiring mode")
	
	clearSelection()
	clearWireVisuals()
	clearPendingWire()
	clearClearModeDots()
	clearAttachPointDots()
	clearConnectionDots()
	hideWiringMobileUI()
	
	if HoverHighlight then
		HoverHighlight:Destroy()
		HoverHighlight = nil
	end
	
	if HoverDot then
		HoverDot:Destroy()
		HoverDot = nil
	end
end

-- Main update loop
RunService.RenderStepped:Connect(function()
	local shouldBeActive = isWiringToolSelected()
	
	if shouldBeActive and not WiringModeActive then
		enterWiringMode()
	elseif not shouldBeActive and WiringModeActive then
		exitWiringMode()
	end
	
	if WiringModeActive then
		updateHoverVisuals()
	end
end)

-- ============================================
-- REMOTE EVENT HANDLERS
-- ============================================

ConnectionUpdatedRemote.OnClientEvent:Connect(function(inputBlock, outputBlock, action, connectionId)
	if WiringModeActive then
		updateWireVisuals()
	end
end)

WireStateChangedRemote.OnClientEvent:Connect(function(block, signalType, state)
	if WiringModeActive then
		updateWireVisuals()
	end
end)

-- ============================================
-- PUBLIC API
-- ============================================

local WiringController = {}

function WiringController.IsWiringModeActive()
	return WiringModeActive
end

function WiringController.GetSelectedBlock()
	return SelectedBlock
end

function WiringController.GetSelectedBlockType()
	return SelectedBlockType
end

-- Try to activate an OUT source device (called when clicking a button without wiring tool)
function WiringController.TryActivateOutSource(block)
	if not block then return false end
	
	local blockType = block:GetAttribute("BlockType")
	if not isOutSource(blockType) then
		return false
	end
	
	ActivateInputRemote:FireServer(block)
	return true
end

-- Expose globally
_G.WiringController = WiringController

if IsMobile then
	print("[WiringController] Initialized (Mobile) - Tap wireable blocks to connect!")
else
	print("[WiringController] Initialized (Desktop) - Right-click wireable blocks to connect, Shift for clear mode")
end

return WiringController
