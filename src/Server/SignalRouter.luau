--[[
	SignalRouter
	Central signal routing system for wiring
	
	Input blocks (buttons, pressure plates) call EmitSignal()
	Output blocks are triggered when their power state changes
	
	Supports multiple inputs powering a single output (OR logic)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local TweenService = game:GetService("TweenService")
local GridConfig = require(ReplicatedStorage:WaitForChild("Config", 10):WaitForChild("GridConfig", 10))

-- Load PistonPushHandler
local PistonPushHandler
task.spawn(function()
	local modulesFolder = ServerScriptService:WaitForChild("Modules", 10)
	if modulesFolder then
		local pushModule = modulesFolder:WaitForChild("PistonPushHandler", 10)
		if pushModule then
			PistonPushHandler = require(pushModule)
			print("[SignalRouter] PistonPushHandler loaded")
		end
	end
end)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local WireStateChangedRemote = Remotes:WaitForChild("WireStateChanged")

local SignalRouter = {}

-- Track active signals per output: outputBlockId -> {inputBlockId -> true}
local ActiveSignals = {}

-- Get all connected output IDs from an input block (using WireConn_ attributes)
local function GetConnectedOutputs(inputBlock: Instance): {string}
	local outputs = {}
	local attributes = inputBlock:GetAttributes()
	
	for name, value in pairs(attributes) do
		if string.sub(name, 1, 9) == "WireConn_" then
			table.insert(outputs, value)
		end
	end
	
	return outputs
end

-- Get the blocks folder for a block
local function GetBlocksFolder(block: Instance): Folder?
	local parent = block.Parent
	if parent and parent:IsA("Folder") and parent.Name == "Blocks" then
		return parent
	end
	return nil
end

-- Find a block by its BlockId in a folder
local function FindBlockById(blocksFolder: Folder, blockId: string): Instance?
	for _, block in ipairs(blocksFolder:GetChildren()) do
		if block:GetAttribute("BlockId") == blockId then
			return block
		end
	end
	return nil
end

-- Check if an output has any active signals (OR logic)
local function HasActiveSignal(outputBlockId: string): boolean
	local signals = ActiveSignals[outputBlockId]
	if not signals then
		return false
	end
	
	for _, _ in pairs(signals) do
		return true
	end
	
	return false
end

-- ============================================
-- OUTPUT TRIGGER FUNCTIONS
-- ============================================

local function triggerPiston(pistonBlock, isPowered)
	-- Minecraft-style: if this piston is being pushed by another piston, skip extension this tick
	if pistonBlock:GetAttribute("BeingPushed") then
		pistonBlock:SetAttribute("BeingPushed", nil) -- Clear the flag
		return
	end
	
	-- Get current extended state
	local isExtended = pistonBlock:GetAttribute("IsExtended") or false
	
	-- Only change state if power state differs from extended state
	if isPowered == isExtended then
		return -- Already in correct state
	end
	
	-- If extending, check if another piston is about to push us (handles wiring order issues)
	if isPowered and PistonPushHandler then
		local blocksFolder = GetBlocksFolder(pistonBlock)
		if blocksFolder then
			-- Get this piston's input sources (what buttons/plates wire to it)
			local myBlockId = pistonBlock:GetAttribute("BlockId")
			local myInputSources = {}
			
			-- Find all blocks that wire TO this piston
			for _, block in ipairs(blocksFolder:GetChildren()) do
				local attrs = block:GetAttributes()
				for name, value in pairs(attrs) do
					if string.sub(name, 1, 9) == "WireConn_" and value == myBlockId then
						myInputSources[block] = true
					end
				end
			end
			
			-- Check all other pistons to see if any shares the same input and would push this one
			for _, otherBlock in ipairs(blocksFolder:GetChildren()) do
				if otherBlock ~= pistonBlock then
					local otherType = otherBlock:GetAttribute("BlockType") or ""
					if string.find(string.lower(otherType), "piston") then
						local otherBlockId = otherBlock:GetAttribute("BlockId")
						local otherExtended = otherBlock:GetAttribute("IsExtended")
						
						-- Skip if already extended
						if otherExtended then
							continue
						end
						
						-- Check if this other piston shares any input source with us
						local sharesInput = false
						for inputBlock, _ in pairs(myInputSources) do
							local attrs = inputBlock:GetAttributes()
							for name, value in pairs(attrs) do
								if string.sub(name, 1, 9) == "WireConn_" and value == otherBlockId then
									sharesInput = true
									break
								end
							end
							if sharesInput then break end
						end
						
						if sharesInput then
							-- Would it push us?
							local wouldPush = PistonPushHandler.WouldPushBlock(otherBlock, pistonBlock, blocksFolder)
							if wouldPush then
								-- Another piston sharing our input is about to push us
								-- Delay our extension until after the push completes (0.15s push + extra buffer)
								task.delay(0.3, function()
									if pistonBlock and pistonBlock:GetAttribute("IsPowered") then
										triggerPiston(pistonBlock, true)
									end
								end)
								return
							end
						end
					end
				end
			end
		end
	end
	
	-- Find the PistonTop part
	local pistonTop = pistonBlock:FindFirstChild("PistonTop")
	if not pistonTop then
		warn("[SignalRouter] PistonTop not found in piston model")
		return
	end
	
	-- Check if this is a sticky piston
	local blockType = pistonBlock:GetAttribute("BlockType") or ""
	local isSticky = string.find(string.lower(blockType), "sticky") ~= nil
	
	-- Get blocks folder for pushing/pulling
	local blocksFolder = GetBlocksFolder(pistonBlock)
	
	-- Handle block pushing/pulling
	if PistonPushHandler and blocksFolder then
		if isPowered then
			-- EXTENDING - try to push blocks first
			local canPush, blockCount = PistonPushHandler.CanPush(pistonBlock, blocksFolder)
			if not canPush then
				print("[SignalRouter] Piston cannot extend - blocked by " .. blockCount .. " blocks")
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
	
	-- Get the piston's actual orientation to determine extension direction
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
	
	-- Tween settings - fast with slight ease out for snappy feel
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
		
		-- The arm's length is always its local Y axis (how it's modeled)
		-- Just scale Y regardless of piston orientation
		if isPowered then
			targetSize = Vector3.new(currentSize.X, currentSize.Y + ARM_SCALE_AMOUNT, currentSize.Z)
			targetPosition = pistonArm.Position + (moveDirection * (ARM_SCALE_AMOUNT / 2))
		else
			targetSize = Vector3.new(currentSize.X, currentSize.Y - ARM_SCALE_AMOUNT, currentSize.Z)
			targetPosition = pistonArm.Position - (moveDirection * (ARM_SCALE_AMOUNT / 2))
		end
		
		-- Tween the arm size and position
		local armTween = TweenService:Create(pistonArm, tweenInfo, {
			Size = targetSize,
			Position = targetPosition
		})
		armTween:Play()
	end
	
	-- Move the PistonTop (head) with tweening
	if pistonTop:IsA("Model") then
		-- For models, tween each part by the same offset (except the arm which we handled)
		for _, part in ipairs(pistonTop:GetDescendants()) do
			if part:IsA("BasePart") and part.Name ~= "PistonArm" then
				local targetCFrame
				if isPowered then
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
		if isPowered then
			targetPosition = pistonTop.Position + moveOffset
		else
			targetPosition = pistonTop.Position - moveOffset
		end
		
		local tween = TweenService:Create(pistonTop, tweenInfo, {Position = targetPosition})
		tween:Play()
	end
	
	-- Update state immediately (animation will catch up)
	pistonBlock:SetAttribute("IsExtended", isPowered)
	
	-- Notify clients
	WireStateChangedRemote:FireAllClients(pistonBlock, "piston", isPowered)
end

local function triggerDoor(doorBlock, isPowered)
	-- Toggle the door state based on power
	local isOpen = doorBlock:GetAttribute("IsOpen") or false
	
	-- Only toggle if power state changed
	if isPowered and not isOpen then
		-- Power on -> open door
		doorBlock:SetAttribute("IsOpen", true)
		local DoorStateChanged = Remotes:FindFirstChild("DoorStateChanged")
		if DoorStateChanged then
			DoorStateChanged:FireAllClients(doorBlock, true)
		end
		print("[SignalRouter] Door opened")
	elseif not isPowered and isOpen then
		-- Power off -> close door
		doorBlock:SetAttribute("IsOpen", false)
		local DoorStateChanged = Remotes:FindFirstChild("DoorStateChanged")
		if DoorStateChanged then
			DoorStateChanged:FireAllClients(doorBlock, false)
		end
		print("[SignalRouter] Door closed")
	end
end

local function triggerLight(lightBlock, isPowered)
	lightBlock:SetAttribute("IsOn", isPowered)
	
	-- Update visual
	local function updatePart(part)
		if part:IsA("BasePart") then
			for _, child in ipairs(part:GetChildren()) do
				if child:IsA("Light") then
					child.Enabled = isPowered
				end
			end
			if part.Material == Enum.Material.Neon then
				part.Transparency = isPowered and 0 or 0.5
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
	
	WireStateChangedRemote:FireAllClients(lightBlock, "light", isPowered)
	print("[SignalRouter] Light", isPowered and "on" or "off")
end

-- Trigger an output block based on its type
local function triggerOutput(outputBlock, isPowered)
	local blockType = outputBlock:GetAttribute("BlockType")
	if not blockType then return end
	
	local lowerType = string.lower(blockType)
	
	if string.find(lowerType, "piston") then
		triggerPiston(outputBlock, isPowered)
	elseif string.find(lowerType, "door") then
		triggerDoor(outputBlock, isPowered)
	elseif string.find(lowerType, "lamp") or string.find(lowerType, "light") then
		triggerLight(outputBlock, isPowered)
	else
		-- Generic output - just set attribute
		outputBlock:SetAttribute("IsActive", isPowered)
		WireStateChangedRemote:FireAllClients(outputBlock, "generic", isPowered)
	end
end

-- Emit a signal from an input block
-- Called by buttons, pressure plates, levers, etc.
function SignalRouter.EmitSignal(inputBlock: Instance, isActive: boolean)
	local inputId = inputBlock:GetAttribute("BlockId")
	if not inputId then
		-- Generate an ID if missing
		inputId = tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999))
		inputBlock:SetAttribute("BlockId", inputId)
	end
	
	local blocksFolder = GetBlocksFolder(inputBlock)
	if not blocksFolder then
		warn("[SignalRouter] Could not find blocks folder for input block")
		return
	end
	
	local connectedOutputs = GetConnectedOutputs(inputBlock)
	
	for _, outputId in ipairs(connectedOutputs) do
		-- Initialize signal tracking
		if not ActiveSignals[outputId] then
			ActiveSignals[outputId] = {}
		end
		
		local wasPowered = HasActiveSignal(outputId)
		
		-- Update signal state
		if isActive then
			ActiveSignals[outputId][inputId] = true
		else
			ActiveSignals[outputId][inputId] = nil
		end
		
		local isPowered = HasActiveSignal(outputId)
		
		-- If power state changed, update the output block's IsPowered attribute and trigger it
		if wasPowered ~= isPowered then
			local outputBlock = FindBlockById(blocksFolder, outputId)
			if outputBlock then
				outputBlock:SetAttribute("IsPowered", isPowered)
				
				-- Trigger the output action (piston, door, light, etc.)
				triggerOutput(outputBlock, isPowered)
				
				print(string.format("[SignalRouter] %s -> %s (powered=%s)", 
					inputBlock.Name, outputBlock.Name, tostring(isPowered)))
			end
		end
	end
end

-- Clean up signals when an input block is removed
function SignalRouter.CleanupInput(inputBlock: Instance)
	local inputId = inputBlock:GetAttribute("BlockId")
	if not inputId then return end
	
	local blocksFolder = GetBlocksFolder(inputBlock)
	
	-- Remove this input's signals from all outputs
	for outputId, signals in pairs(ActiveSignals) do
		if signals[inputId] then
			signals[inputId] = nil
			
			-- Update the output's powered state
			local isPowered = HasActiveSignal(outputId)
			if blocksFolder then
				local outputBlock = FindBlockById(blocksFolder, outputId)
				if outputBlock then
					outputBlock:SetAttribute("IsPowered", isPowered)
				end
			end
		end
	end
end

-- Clean up signals when an output block is removed
function SignalRouter.CleanupOutput(outputBlock: Instance)
	local outputId = outputBlock:GetAttribute("BlockId")
	if not outputId then return end
	
	ActiveSignals[outputId] = nil
end

return SignalRouter
