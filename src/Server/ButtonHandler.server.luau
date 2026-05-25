--[[
	ButtonHandler
	Server-side handler for button press mechanics
	- Sinks button in by 0.15 studs when pressed
	- Waits 2 seconds then resets
	- Emits signal via SignalRouter AND WiringHandler
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SurfacePlacement = require(ReplicatedStorage:WaitForChild("SurfacePlacement", 10))
local SignalRouter = require(script.Parent:WaitForChild("SignalRouter"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)

-- Create the PressButton remote if it doesn't exist
local PressButton = Remotes:FindFirstChild("PressButton")
if not PressButton then
	PressButton = Instance.new("RemoteEvent")
	PressButton.Name = "PressButton"
	PressButton.Parent = Remotes
end

-- Get the ActivateWireInput remote for wiring system integration
local ActivateWireInput = Remotes:WaitForChild("ActivateWireInput", 5)

-- Get WiringSystem module for reading connections
local WiringSystem = require(ReplicatedStorage:WaitForChild("WiringSystem"))

-- Try to load LogicGates module
local LogicGates = nil
pcall(function()
	LogicGates = require(ReplicatedStorage:WaitForChild("LogicGates", 5))
end)

local PRESS_DEPTH = 0.15 -- How far button sinks in
local PRESS_DURATION = 2 -- How long button stays pressed

-- Track which buttons are currently pressed (to prevent double-press)
local PressedButtons = {}

-- Helper to find a block by ID in the same folder
local function findBlockById(blocksFolder, blockId)
	for _, block in ipairs(blocksFolder:GetChildren()) do
		if block:GetAttribute("BlockId") == blockId then
			return block
		end
	end
	return nil
end

-- Trigger wire connections from a button
local function triggerWireConnections(button, isActivating)
	local blocksFolder = button.Parent
	if not blocksFolder then return end
	
	-- Get wire connections
	local connections = WiringSystem.GetOutputConnectionsDetailed(button)
	if #connections == 0 then return end
	
	print(string.format("[Button] Triggering %d wire connections (state: %s)", #connections, tostring(isActivating)))
	
	for _, conn in ipairs(connections) do
		local targetBlock = findBlockById(blocksFolder, conn.blockId)
		if targetBlock then
			local targetType = targetBlock:GetAttribute("BlockType")
			
			-- Check if target is a logic gate
			if LogicGates and LogicGates.IsLogicGate(targetType) then
				-- Update the logic gate's input via attribute
				local attachPoint = conn.attachPoint
				if attachPoint then
					-- Set input attribute - WiringHandler will process this
					targetBlock:SetAttribute("Input_" .. attachPoint, isActivating)
					
					-- Also fire the WireStateChanged to trigger recalculation
					local WireStateChangedRemote = Remotes:FindFirstChild("WireStateChanged")
					if WireStateChangedRemote then
						-- Force a recalculation by calling the logic gate processing
						local inputStates = {}
						local inputPoints = LogicGates.GetInputAttachPoints(targetType)
						for _, inputPoint in ipairs(inputPoints) do
							inputStates[inputPoint.Name] = targetBlock:GetAttribute("Input_" .. inputPoint.Name) or false
						end
						
						local newOutput = LogicGates.ProcessGate(targetType, inputStates)
						local currentOutput = targetBlock:GetAttribute("IsOutputting") or false
						
						if newOutput ~= currentOutput then
							targetBlock:SetAttribute("IsOutputting", newOutput)
							LogicGates.UpdateGateVisuals(targetBlock, targetType, newOutput)
							WireStateChangedRemote:FireAllClients(targetBlock, "logic_gate", newOutput)
							print(string.format("[Button] Logic gate %s output changed to %s", targetType, tostring(newOutput)))
							
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
											print(string.format("[Button] Lamp %s set to %s", outputTarget.Name, tostring(newOutput)))
										end
									
									elseif string.find(lowerType, "piston") then
										-- Trigger piston based on output state
										local isExtended = outputTarget:GetAttribute("IsExtended") or false
										-- Piston should be extended when powered, retracted when not
										if newOutput ~= isExtended then
											-- Use SignalRouter to trigger the piston properly
											outputTarget:SetAttribute("IsPowered", newOutput)
											SignalRouter.EmitSignal(targetBlock, newOutput) -- This won't work directly
											-- Directly call the piston trigger via firing a custom event
											local TriggerPistonRemote = Remotes:FindFirstChild("TriggerPiston")
											if not TriggerPistonRemote then
												TriggerPistonRemote = Instance.new("BindableEvent")
												TriggerPistonRemote.Name = "TriggerPiston"
												TriggerPistonRemote.Parent = Remotes
											end
											TriggerPistonRemote:Fire(outputTarget, newOutput)
											print(string.format("[Button] Piston %s triggered (powered: %s)", outputTarget.Name, tostring(newOutput)))
										end
									
									elseif string.find(lowerType, "door") then
										-- Trigger door based on output state
										local isOpen = outputTarget:GetAttribute("IsOpen") or false
										if newOutput ~= isOpen then
											outputTarget:SetAttribute("IsOpen", newOutput)
											local DoorStateChanged = Remotes:FindFirstChild("DoorStateChanged")
											if DoorStateChanged then
												DoorStateChanged:FireAllClients(outputTarget, newOutput)
											end
											print(string.format("[Button] Door %s set to %s", outputTarget.Name, tostring(newOutput)))
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

-- Get the inward direction based on the surface face
local function GetPressDirection(face: string): Vector3
	if face == "Top" then
		return Vector3.new(0, -1, 0)
	elseif face == "Bottom" then
		return Vector3.new(0, 1, 0)
	elseif face == "North" then
		return Vector3.new(0, 0, 1)
	elseif face == "South" then
		return Vector3.new(0, 0, -1)
	elseif face == "East" then
		return Vector3.new(-1, 0, 0)
	elseif face == "West" then
		return Vector3.new(1, 0, 0)
	end
	return Vector3.new(0, -1, 0)
end

-- Move the button by an offset
local function MoveButton(button, offset: Vector3)
	if button:IsA("BasePart") then
		button.Position = button.Position + offset
	elseif button:IsA("Model") then
		local primaryPart = button.PrimaryPart or button:FindFirstChildWhichIsA("BasePart")
		if primaryPart then
			button:PivotTo(button:GetPivot() * CFrame.new(offset))
		end
	end
end

-- Press a button
local function PressButtonHandler(player, button)
	if not button then return end
	if not button.Parent then return end
	
	-- Check if it's actually a button
	local blockType = button:GetAttribute("BlockType")
	if not blockType or not SurfacePlacement.IsButton(blockType) then
		return
	end
	
	-- Check if already pressed
	if PressedButtons[button] then
		return
	end
	
	-- Mark as pressed
	PressedButtons[button] = true
	
	-- Get the face direction
	local face = button:GetAttribute("SurfaceFace") or "Top"
	local pressDirection = GetPressDirection(face)
	local pressOffset = pressDirection * PRESS_DEPTH
	
	-- Press the button (sink in)
	MoveButton(button, pressOffset)
	
	-- Set pressed attribute
	button:SetAttribute("IsPressed", true)
	
	-- Emit signal ON (SignalRouter for old system)
	SignalRouter.EmitSignal(button, true)
	
	-- Trigger wire connections (new wiring system)
	triggerWireConnections(button, true)
	
	print(string.format("[Button] %s pressed by %s", button.Name, player.Name))
	
	-- Wait for press duration
	task.delay(PRESS_DURATION, function()
		-- Check if button still exists
		if not button or not button.Parent then
			PressedButtons[button] = nil
			return
		end
		
		-- Release the button (pop back out)
		MoveButton(button, -pressOffset)
		
		-- Clear pressed attribute
		button:SetAttribute("IsPressed", false)
		
		-- Emit signal OFF (SignalRouter for old system)
		SignalRouter.EmitSignal(button, false)
		
		-- Trigger wire connections (new wiring system)
		triggerWireConnections(button, false)
		
		-- Allow pressing again
		PressedButtons[button] = nil
		
		print(string.format("[Button] %s released", button.Name))
	end)
end

-- Listen for button press events
PressButton.OnServerEvent:Connect(PressButtonHandler)

print("ButtonHandler initialized")
