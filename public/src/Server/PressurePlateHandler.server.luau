--[[
	PressurePlateHandler
	Server-side handler for pressure plate mechanics
	- Detects when entities step on the plate using distance checks
	- Compresses down 0.15 studs when activated
	- Stays compressed while any entity is on it
	- Emits signal via SignalRouter AND WiringHandler
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local SurfacePlacement = require(ReplicatedStorage:WaitForChild("SurfacePlacement", 10))
local BulkOperationFlags = require(ReplicatedStorage:WaitForChild("BulkOperationFlags", 10))
local GridConfig = require(ReplicatedStorage:WaitForChild("Config", 10):WaitForChild("GridConfig", 10))
local SignalRouter = require(script.Parent:WaitForChild("SignalRouter"))

-- Get WiringSystem module for reading connections
local WiringSystem = require(ReplicatedStorage:WaitForChild("WiringSystem"))

-- Try to load LogicGates module
local LogicGates = nil
pcall(function()
	LogicGates = require(ReplicatedStorage:WaitForChild("LogicGates", 5))
end)

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)

local PRESS_DEPTH = 0.15 -- How far plate sinks in
local CHECK_INTERVAL = 0.1 -- How often to check for entities (seconds)
local VERTICAL_TOLERANCE = 3 -- How high above plate player can be
local HORIZONTAL_PADDING = 0.5 -- Extra padding for horizontal bounds

-- Track pressure plate states
local PlateStates = {} -- plate -> { isPressed, position, halfX, halfZ }

-- Helper to find a block by ID in the same folder
local function findBlockById(blocksFolder, blockId)
	for _, block in ipairs(blocksFolder:GetChildren()) do
		if block:GetAttribute("BlockId") == blockId then
			return block
		end
	end
	return nil
end

-- Trigger wire connections from a pressure plate
local function triggerWireConnections(plate, isActivating)
	local blocksFolder = plate.Parent
	if not blocksFolder then return end
	
	-- Get wire connections
	local connections = WiringSystem.GetOutputConnectionsDetailed(plate)
	if #connections == 0 then return end
	
	print(string.format("[PressurePlate] Triggering %d wire connections (state: %s)", #connections, tostring(isActivating)))
	
	for _, conn in ipairs(connections) do
		local targetBlock = findBlockById(blocksFolder, conn.blockId)
		if targetBlock then
			local targetType = targetBlock:GetAttribute("BlockType")
			
			-- Check if target is a logic gate
			if LogicGates and LogicGates.IsLogicGate(targetType) then
				-- Update the logic gate's input via attribute
				local attachPoint = conn.attachPoint
				if attachPoint then
					-- Set input attribute
					targetBlock:SetAttribute("Input_" .. attachPoint, isActivating)
					
					-- Recalculate logic gate output
					local WireStateChangedRemote = Remotes:FindFirstChild("WireStateChanged")
					if WireStateChangedRemote then
						local inputStates = {}
						local inputPoints = LogicGates.GetInputAttachPoints(targetType)
						for _, inputPoint in ipairs(inputPoints) do
							inputStates[inputPoint.Name] = targetBlock:GetAttribute("Input_" .. inputPoint.Name) or false
						end
						
						local newOutput = LogicGates.ProcessGate(targetType, inputStates)
						local currentOutput = targetBlock:GetAttribute("IsOutputting") or false
						
						if newOutput ~= currentOutput then
							local hasInput = not newOutput -- For inverter: if outputting, no input
							targetBlock:SetAttribute("IsOutputting", newOutput)
							LogicGates.UpdateGateVisuals(targetBlock, targetType, newOutput, hasInput)
							WireStateChangedRemote:FireAllClients(targetBlock, "logic_gate", newOutput)
							print(string.format("[PressurePlate] Logic gate %s output changed to %s", targetType, tostring(newOutput)))
							
							-- Propagate to logic gate's outputs
							local gateConnections = WiringSystem.GetOutputConnectionsDetailed(targetBlock)
							for _, gateConn in ipairs(gateConnections) do
								local outputTarget = findBlockById(blocksFolder, gateConn.blockId)
								if outputTarget then
									local outputTargetType = outputTarget:GetAttribute("BlockType")
									local lowerType = string.lower(outputTargetType or "")
									
									if string.find(lowerType, "lamp") or string.find(lowerType, "light") then
										-- Set lamp state to match output
										local currentState = outputTarget:GetAttribute("IsPowered") or false
										if currentState ~= newOutput then
											outputTarget:SetAttribute("IsPowered", newOutput)
											-- Update visuals
											for _, desc in ipairs(outputTarget:GetDescendants()) do
												if desc:IsA("BasePart") then
													for _, child in ipairs(desc:GetChildren()) do
														if child:IsA("Light") then
															child.Enabled = newOutput
														end
													end
													if newOutput then
														desc.Material = Enum.Material.Neon
													else
														desc.Material = Enum.Material.SmoothPlastic
													end
												end
											end
											WireStateChangedRemote:FireAllClients(outputTarget, "light", newOutput)
											print(string.format("[PressurePlate] Lamp %s set to %s", outputTarget.Name, tostring(newOutput)))
										end
									end
								end
							end
						end
					end
				end
			end
		end
	end
end

-- Move the pressure plate by an offset
local function MovePlate(plate, offset: Vector3)
	if plate:IsA("BasePart") then
		plate.Position = plate.Position + offset
	elseif plate:IsA("Model") then
		local primaryPart = plate.PrimaryPart or plate:FindFirstChildWhichIsA("BasePart")
		if primaryPart then
			plate:PivotTo(plate:GetPivot() * CFrame.new(offset))
		end
	end
end

-- Get plate info (position and size)
local function GetPlateInfo(plate: Instance): (Vector3?, number?, number?)
	local touchPart
	if plate:IsA("BasePart") then
		touchPart = plate
	elseif plate:IsA("Model") then
		touchPart = plate.PrimaryPart or plate:FindFirstChildWhichIsA("BasePart")
	end
	
	if not touchPart then
		return nil, nil, nil
	end
	
	local pos = touchPart.Position
	local size = touchPart.Size
	
	local halfX = math.max(size.X, size.Z) / 2 + HORIZONTAL_PADDING
	local halfZ = halfX
	
	return pos, halfX, halfZ
end

-- Check if a player's HumanoidRootPart is above the pressure plate
local function IsPlayerOnPlate(player: Player, platePos: Vector3, halfX: number, halfZ: number): boolean
	local character = player.Character
	if not character then return false end
	
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then return false end
	
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then return false end
	
	local rootPos = rootPart.Position
	
	-- Check horizontal distance
	local dx = math.abs(rootPos.X - platePos.X)
	local dz = math.abs(rootPos.Z - platePos.Z)
	
	if dx > halfX or dz > halfZ then
		return false
	end
	
	-- Check vertical distance
	local dy = rootPos.Y - platePos.Y
	if dy < 0 or dy > VERTICAL_TOLERANCE then
		return false
	end
	
	return true
end

-- Check if any player is on the plate
local function IsAnyPlayerOnPlate(platePos: Vector3, halfX: number, halfZ: number): boolean
	for _, player in ipairs(Players:GetPlayers()) do
		if IsPlayerOnPlate(player, platePos, halfX, halfZ) then
			return true
		end
	end
	return false
end

-- Activate the pressure plate
local function ActivatePlate(plate: Instance)
	local state = PlateStates[plate]
	if not state or state.isPressed then return end
	
	state.isPressed = true
	
	-- Move plate down
	MovePlate(plate, Vector3.new(0, -PRESS_DEPTH, 0))
	state.position = state.position - Vector3.new(0, PRESS_DEPTH, 0)
	
	-- Set attribute
	plate:SetAttribute("IsPressed", true)
	
	-- Emit signal ON (SignalRouter for old system)
	SignalRouter.EmitSignal(plate, true)
	
	-- Trigger wire connections (new wiring system)
	triggerWireConnections(plate, true)
	
	print(string.format("[PressurePlate] %s activated", plate.Name))
end

-- Deactivate the pressure plate
local function DeactivatePlate(plate: Instance)
	local state = PlateStates[plate]
	if not state or not state.isPressed then return end
	
	state.isPressed = false
	
	-- Move plate up
	MovePlate(plate, Vector3.new(0, PRESS_DEPTH, 0))
	state.position = state.position + Vector3.new(0, PRESS_DEPTH, 0)
	
	-- Clear attribute
	plate:SetAttribute("IsPressed", false)
	
	-- Emit signal OFF (SignalRouter for old system)
	SignalRouter.EmitSignal(plate, false)
	
	-- Trigger wire connections (new wiring system)
	triggerWireConnections(plate, false)
	
	print(string.format("[PressurePlate] %s deactivated", plate.Name))
end

-- Set up detection for a pressure plate
local function SetupPressurePlate(plate: Instance)
	local pos, halfX, halfZ = GetPlateInfo(plate)
	if not pos then return end
	
	PlateStates[plate] = {
		isPressed = false,
		position = pos,
		halfX = halfX,
		halfZ = halfZ,
	}
	
	print(string.format("[PressurePlate] Set up %s", plate.Name))
end

-- Clean up when a pressure plate is removed
local function CleanupPressurePlate(plate: Instance)
	local state = PlateStates[plate]
	if state and state.isPressed then
		SignalRouter.EmitSignal(plate, false)
	end
	SignalRouter.CleanupInput(plate)
	PlateStates[plate] = nil
end

-- Periodic check for all pressure plates
local function CheckAllPlates()
	for plate, state in pairs(PlateStates) do
		if not plate.Parent then
			PlateStates[plate] = nil
			continue
		end
		
		local playerOnPlate = IsAnyPlayerOnPlate(state.position, state.halfX, state.halfZ)
		
		if playerOnPlate and not state.isPressed then
			ActivatePlate(plate)
		elseif not playerOnPlate and state.isPressed then
			DeactivatePlate(plate)
		end
	end
end

-- Monitor build areas for pressure plates
local function MonitorBuildArea(buildArea: Instance)
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder then
		buildArea.ChildAdded:Connect(function(child)
			if child.Name == "Blocks" and child:IsA("Folder") then
				MonitorBuildArea(buildArea)
			end
		end)
		return
	end
	
	-- Set up existing pressure plates
	for _, block in ipairs(blocksFolder:GetChildren()) do
		local blockType = block:GetAttribute("BlockType")
		if blockType and SurfacePlacement.IsPressurePlate(blockType) then
			SetupPressurePlate(block)
		end
	end
	
	-- Monitor for new pressure plates
	blocksFolder.ChildAdded:Connect(function(block)
		-- Skip during bulk operations (terrain gen, save loading)
		if BulkOperationFlags.IsBulkOperation(buildArea) then return end
		if blocksFolder:GetAttribute("BulkOperationInProgress") then return end
		
		task.wait()
		local blockType = block:GetAttribute("BlockType")
		if blockType and SurfacePlacement.IsPressurePlate(blockType) then
			SetupPressurePlate(block)
		end
	end)
	
	-- Clean up removed pressure plates
	blocksFolder.ChildRemoved:Connect(function(block)
		-- Skip during bulk operations (terrain gen, save loading)
		if BulkOperationFlags.IsBulkOperation(buildArea) then return end
		if blocksFolder:GetAttribute("BulkOperationInProgress") then return end
		
		-- Skip if being removed by save system (batch removal)
		if block:GetAttribute("BeingRemovedBySaveSystem") then return end
		
		if PlateStates[block] then
			CleanupPressurePlate(block)
		end
	end)
end

-- Initialize
local function Initialize()
	for i = 1, GridConfig.TOTAL_PLOTS do
		local buildArea = workspace:FindFirstChild(GridConfig.BUILD_AREA_PREFIX .. i)
		if buildArea then
			MonitorBuildArea(buildArea)
		end
	end
	
	workspace.ChildAdded:Connect(function(child)
		if string.find(child.Name, GridConfig.BUILD_AREA_PREFIX) then
			MonitorBuildArea(child)
		end
	end)
	
	-- Also monitor MegaPlot build area (for private server MegaPlot mode)
	local function setupMegaPlotMonitoring(megaPlotRoom)
		local megaBuildArea = megaPlotRoom:FindFirstChild("MegaPlotBuildArea")
		if megaBuildArea then
			MonitorBuildArea(megaBuildArea)
		end
		megaPlotRoom.ChildAdded:Connect(function(child)
			if child.Name == "MegaPlotBuildArea" then
				task.wait(0.5)
				MonitorBuildArea(child)
			end
		end)
	end
	
	local megaPlotRoom = workspace:FindFirstChild("MegaPlotRoom")
	if megaPlotRoom then
		setupMegaPlotMonitoring(megaPlotRoom)
	end
	workspace.ChildAdded:Connect(function(child)
		if child.Name == "MegaPlotRoom" then
			setupMegaPlotMonitoring(child)
		end
	end)
	
	-- Start periodic checking loop
	task.spawn(function()
		while true do
			CheckAllPlates()
			task.wait(CHECK_INTERVAL)
		end
	end)
end

Initialize()

print("PressurePlateHandler initialized")
