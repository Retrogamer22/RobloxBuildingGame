--[[
	LogicGates
	Defines logic gate types, their attach points, and processing logic
	
	Attach points are named child Parts in the gate model that serve as connection nodes.
	Each attach point can be an INPUT (receives signals) or OUTPUT (sends signals).
	
	Logic Gates:
	- Inverter (NOT gate): 1 input, 1 output - output is inverted from input
	- ORGate: 2 inputs, 1 output - output is ON if ANY input is ON
	- DelayGate: 1 input, 1 output - output follows input with a delay
]]

local LogicGates = {}

-- Gate type enum
LogicGates.GateType = {
	INVERTER = "Inverter",
	OR_GATE = "ORGate",
	DELAY_GATE = "DelayGate",
}

-- Attach point types
LogicGates.AttachPointType = {
	INPUT = "input",   -- Receives signals
	OUTPUT = "output", -- Sends signals
}

-- Gate definitions with attach point configuration
-- PartName: the name of the Part in the model that serves as the attach point
-- Type: input or output
-- Position: relative position hint for UI (e.g., "left", "right", "front", "back")
LogicGates.GateDefinitions = {
	["Inverter"] = {
		DisplayName = "Inverter (NOT Gate)",
		Description = "Outputs when there's no input. Turns off when receiving input.",
		AttachPoints = {
			{
				Name = "Wire1",
				Type = LogicGates.AttachPointType.INPUT,
				Position = "back",
			},
			{
				Name = "Wire3",
				Type = LogicGates.AttachPointType.OUTPUT,
				Position = "front",
			},
		},
		-- Visual parts that change based on state
		-- FollowsInput = true means it lights up when receiving input
		-- FollowsInput = false (or nil) means it lights up when outputting
		VisualParts = {
			{ Name = "Wire1", FollowsInput = true, OnMaterial = "Neon", OffMaterial = "SmoothPlastic", OnColor = {181, 64, 64}, OffColor = {36, 26, 26} },
			{ Name = "Wire2", FollowsInput = true, OnMaterial = "Neon", OffMaterial = "SmoothPlastic", OnColor = {181, 64, 64}, OffColor = {36, 26, 26} },
			{ Name = "Wire3", FollowsInput = false, OnMaterial = "Neon", OffMaterial = "SmoothPlastic", OnColor = {181, 64, 64}, OffColor = {36, 26, 26} },
		},
		-- Input torch (lights up when receiving input)
		InputTorchPart = "WiredTorch",  -- First torch on input side
		-- Output torch (lights up when outputting)
		OutputTorchPart = "WiredTorch2", -- Second torch on output side
		-- Default state: Inverter outputs when NO input (starts outputting)
		DefaultOutput = true,
	},
	
	["ORGate"] = {
		DisplayName = "OR Gate",
		Description = "Outputs when ANY input is receiving a signal.",
		AttachPoints = {
			{
				Name = "WireIN1",
				Type = LogicGates.AttachPointType.INPUT,
				Position = "back-left",
			},
			{
				Name = "WireIN2",
				Type = LogicGates.AttachPointType.INPUT,
				Position = "back-right",
			},
			{
				Name = "WireOUT",
				Type = LogicGates.AttachPointType.OUTPUT,
				Position = "front",
			},
		},
		VisualParts = {
			{ Name = "Wire1", OnMaterial = "Neon", OffMaterial = "SmoothPlastic", OnColor = {181, 64, 64}, OffColor = {36, 26, 26} },
			{ Name = "Wire2", OnMaterial = "Neon", OffMaterial = "SmoothPlastic", OnColor = {181, 64, 64}, OffColor = {36, 26, 26} },
		},
		TorchPart = "WiredTorch",
		DefaultOutput = false,
	},
	
	["DelayGate"] = {
		DisplayName = "Delay Gate",
		Description = "Outputs after a short delay when receiving input.",
		AttachPoints = {
			{
				Name = "WireIN",
				Type = LogicGates.AttachPointType.INPUT,
				Position = "back",
			},
			{
				Name = "WireOUT",
				Type = LogicGates.AttachPointType.OUTPUT,
				Position = "front",
			},
		},
		VisualParts = {},
		TorchPart = "WiredTorch",
		DefaultOutput = false,
		DelayTime = 0.4, -- Delay in seconds (2 redstone ticks)
	},
}

-- Check if a block type is a logic gate
function LogicGates.IsLogicGate(blockType: string): boolean
	if not blockType then return false end
	return LogicGates.GateDefinitions[blockType] ~= nil
end

-- Get gate definition
function LogicGates.GetGateDefinition(blockType: string)
	return LogicGates.GateDefinitions[blockType]
end

-- Get all attach points for a gate
function LogicGates.GetAttachPoints(blockType: string): {{Name: string, Type: string, Position: string}}?
	local def = LogicGates.GateDefinitions[blockType]
	if not def then return nil end
	return def.AttachPoints
end

-- Get input attach points only
function LogicGates.GetInputAttachPoints(blockType: string): {{Name: string, Type: string, Position: string}}
	local attachPoints = LogicGates.GetAttachPoints(blockType)
	if not attachPoints then return {} end
	
	local inputs = {}
	for _, point in ipairs(attachPoints) do
		if point.Type == LogicGates.AttachPointType.INPUT then
			table.insert(inputs, point)
		end
	end
	return inputs
end

-- Get output attach points only
function LogicGates.GetOutputAttachPoints(blockType: string): {{Name: string, Type: string, Position: string}}
	local attachPoints = LogicGates.GetAttachPoints(blockType)
	if not attachPoints then return {} end
	
	local outputs = {}
	for _, point in ipairs(attachPoints) do
		if point.Type == LogicGates.AttachPointType.OUTPUT then
			table.insert(outputs, point)
		end
	end
	return outputs
end

-- Find the attach point Part in a gate model
function LogicGates.FindAttachPointPart(gateModel: Instance, attachPointName: string): BasePart?
	if not gateModel then return nil end
	
	-- Direct child
	local part = gateModel:FindFirstChild(attachPointName)
	if part and part:IsA("BasePart") then
		return part
	end
	
	-- Search descendants
	for _, desc in ipairs(gateModel:GetDescendants()) do
		if desc.Name == attachPointName and desc:IsA("BasePart") then
			return desc
		end
	end
	
	return nil
end

-- Get the world position of an attach point on a placed gate
function LogicGates.GetAttachPointPosition(gateModel: Instance, attachPointName: string): Vector3?
	local part = LogicGates.FindAttachPointPart(gateModel, attachPointName)
	if part then
		-- Return the end of the wire (furthest from center)
		local gateCenter = gateModel:GetPivot().Position
		local partPos = part.Position
		
		-- For wire parts, return the far end
		if part.Size.Z > part.Size.X and part.Size.Z > part.Size.Y then
			-- Wire is along Z axis
			local dir = (partPos - gateCenter).Unit
			if dir.Magnitude > 0 then
				return partPos + dir * (part.Size.Z / 2)
			end
		end
		
		return partPos
	end
	return nil
end

-- Process logic gate based on input states
-- Returns: new output state (boolean)
function LogicGates.ProcessGate(blockType: string, inputStates: {[string]: boolean}): boolean
	local def = LogicGates.GateDefinitions[blockType]
	if not def then return false end
	
	if blockType == "Inverter" then
		-- NOT gate: output is inverted from input
		-- Get the first (and only) input
		for inputName, isActive in pairs(inputStates) do
			-- If any input is active, output is OFF
			if isActive then
				return false
			end
		end
		-- No active inputs = output is ON
		return true
		
	elseif blockType == "ORGate" then
		-- OR gate: output is ON if ANY input is ON
		for inputName, isActive in pairs(inputStates) do
			if isActive then
				return true
			end
		end
		return false
		
	elseif blockType == "DelayGate" then
		-- Delay gate: output follows input (delay handled separately)
		for inputName, isActive in pairs(inputStates) do
			if isActive then
				return true
			end
		end
		return false
	end
	
	return false
end

-- Helper to update a torch's visual state
local function updateTorchVisual(torch, isLit)
	if not torch then return end
	
	-- Find the Light part inside the torch
	local lightPart = torch:FindFirstChild("Light")
	if lightPart and lightPart:IsA("BasePart") then
		if isLit then
			-- ON state: Neon material with dusty rose color
			lightPart.Material = Enum.Material.Neon
			lightPart.Color = Color3.fromRGB(181, 64, 64) -- Dusty Rose
			lightPart.Transparency = 0
			-- Enable any actual light objects
			for _, light in ipairs(lightPart:GetChildren()) do
				if light:IsA("Light") then
					light.Enabled = true
				end
			end
		else
			-- OFF state: Plastic with really black color
			lightPart.Material = Enum.Material.Plastic
			lightPart.Color = Color3.fromRGB(36, 26, 26) -- Really black
			lightPart.Transparency = 0
			for _, light in ipairs(lightPart:GetChildren()) do
				if light:IsA("Light") then
					light.Enabled = false
				end
			end
		end
	end
end

-- Update the visual state of a logic gate
-- isOutputting: whether the gate is currently outputting a signal
-- hasInput: whether the gate is currently receiving input (optional, for dual-torch gates)
function LogicGates.UpdateGateVisuals(gateModel: Instance, blockType: string, isOutputting: boolean, hasInput: boolean?)
	local def = LogicGates.GateDefinitions[blockType]
	if not def then return end
	
	-- For inverter, hasInput is the opposite of isOutputting
	if hasInput == nil then
		hasInput = not isOutputting
	end
	
	-- Update wire parts
	if def.VisualParts then
		for _, visualDef in ipairs(def.VisualParts) do
			local part = gateModel:FindFirstChild(visualDef.Name) or gateModel:FindFirstChild(visualDef.Name, true)
			if part and part:IsA("BasePart") then
				-- Determine if this wire should be ON based on FollowsInput setting
				local shouldBeOn
				if visualDef.FollowsInput then
					shouldBeOn = hasInput  -- Lights up when receiving input
				else
					shouldBeOn = isOutputting  -- Lights up when outputting
				end
				
				if shouldBeOn then
					part.Material = Enum.Material[visualDef.OnMaterial] or Enum.Material.Neon
					if visualDef.OnColor then
						part.Color = Color3.fromRGB(visualDef.OnColor[1], visualDef.OnColor[2], visualDef.OnColor[3])
					end
				else
					part.Material = Enum.Material[visualDef.OffMaterial] or Enum.Material.SmoothPlastic
					if visualDef.OffColor then
						part.Color = Color3.fromRGB(visualDef.OffColor[1], visualDef.OffColor[2], visualDef.OffColor[3])
					end
				end
			end
		end
	end
	
	-- Update INPUT torch (lights up when receiving input)
	if def.InputTorchPart then
		local inputTorch = gateModel:FindFirstChild(def.InputTorchPart)
		updateTorchVisual(inputTorch, hasInput)
	end
	
	-- Update OUTPUT torch (lights up when outputting)
	if def.OutputTorchPart then
		local outputTorch = gateModel:FindFirstChild(def.OutputTorchPart)
		updateTorchVisual(outputTorch, isOutputting)
	end
	
	-- Legacy: single TorchPart (for gates with only one torch, follows output state)
	if def.TorchPart and not def.InputTorchPart and not def.OutputTorchPart then
		local torch = gateModel:FindFirstChild(def.TorchPart)
		updateTorchVisual(torch, isOutputting)
	end
end

-- Initialize a newly placed logic gate (set default state)
function LogicGates.InitializeGate(gateModel: Instance, blockType: string)
	local def = LogicGates.GateDefinitions[blockType]
	if not def then return end
	
	-- Set initial output state
	local defaultOutput = def.DefaultOutput or false
	gateModel:SetAttribute("IsOutputting", defaultOutput)
	gateModel:SetAttribute("IsLogicGate", true)
	
	-- Initialize input states (all start as false = no input)
	local inputPoints = LogicGates.GetInputAttachPoints(blockType)
	for _, inputPoint in ipairs(inputPoints) do
		gateModel:SetAttribute("Input_" .. inputPoint.Name, false)
	end
	
	-- Update visuals to match default state
	-- For inverter: defaultOutput=true means no input, so hasInput=false
	local hasInput = not defaultOutput  -- If outputting by default, no input
	LogicGates.UpdateGateVisuals(gateModel, blockType, defaultOutput, hasInput)
end

return LogicGates
