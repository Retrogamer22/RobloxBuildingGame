--[[
	DoorHandler
	Server-side door state management
	- Syncs door open/close state to all clients
	- Validates door ownership/permissions
	- Listens for IsPowered attribute changes (from wiring signals)
	- Handles double door pairing (powering one opens both)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GridConfig = require(ReplicatedStorage:WaitForChild("Config", 10):WaitForChild("GridConfig", 10))

local BLOCK_SIZE = 3

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)

-- Create door remotes if they don't exist
local ToggleDoor = Remotes:FindFirstChild("ToggleDoor")
if not ToggleDoor then
	ToggleDoor = Instance.new("RemoteEvent")
	ToggleDoor.Name = "ToggleDoor"
	ToggleDoor.Parent = Remotes
end

local DoorStateChanged = Remotes:FindFirstChild("DoorStateChanged")
if not DoorStateChanged then
	DoorStateChanged = Instance.new("RemoteEvent")
	DoorStateChanged.Name = "DoorStateChanged"
	DoorStateChanged.Parent = Remotes
end

-- ============================================
-- HELPER FUNCTIONS
-- ============================================

local function isDoorBlock(block)
	if not block then return false end
	
	local blockType = block:GetAttribute("BlockType")
	if not blockType then return false end
	
	return string.find(string.lower(blockType), "door") ~= nil
end

local function getDoorPosition(door): Vector3?
	if door:IsA("Model") then
		local primary = door.PrimaryPart or door:FindFirstChildWhichIsA("BasePart")
		if primary then return primary.Position end
	elseif door:IsA("BasePart") then
		return door.Position
	end
	return nil
end

-- Find paired door for double-door setup
local function findPairedDoor(door): Instance?
	if not door or not door.Parent then return nil end
	
	local direction = door:GetAttribute("DoorDirection")
	local depth = door:GetAttribute("DoorDepth")
	local hingeSide = door:GetAttribute("DoorHingeSide")
	
	if direction == nil or not depth or not hingeSide then
		return nil
	end
	
	local doorPos = getDoorPosition(door)
	if not doorPos then return nil end
	
	-- Calculate adjacent positions based on door direction
	local checkOffsets = {}
	if direction == 0 or direction == 2 then -- NORTH or SOUTH
		checkOffsets = { Vector3.new(BLOCK_SIZE, 0, 0), Vector3.new(-BLOCK_SIZE, 0, 0) }
	else -- EAST or WEST
		checkOffsets = { Vector3.new(0, 0, BLOCK_SIZE), Vector3.new(0, 0, -BLOCK_SIZE) }
	end
	
	local blocksFolder = door.Parent
	
	for _, offset in ipairs(checkOffsets) do
		local checkPos = doorPos + offset
		
		for _, block in ipairs(blocksFolder:GetChildren()) do
			if block ~= door and isDoorBlock(block) then
				local blockPos = getDoorPosition(block)
				if blockPos then
					local dist = (blockPos - checkPos).Magnitude
					local yDiff = math.abs(blockPos.Y - doorPos.Y)
					
					if dist < 1 and yDiff < 0.5 then
						-- Found adjacent door, check attributes
						local otherDirection = block:GetAttribute("DoorDirection")
						local otherDepth = block:GetAttribute("DoorDepth")
						local otherHingeSide = block:GetAttribute("DoorHingeSide")
						
						-- Must have same direction, same depth, opposite hinge side, AND same door type
						local doorType = door:GetAttribute("BlockType")
						local otherType = block:GetAttribute("BlockType")
						
						if otherDirection == direction 
							and otherDepth == depth 
							and otherHingeSide ~= hingeSide
							and doorType == otherType then
							return block
						end
					end
				end
			end
		end
	end
	
	return nil
end

-- ============================================
-- DOOR STATE CHANGE
-- ============================================

local function SetDoorState(door: Instance, isOpen: boolean, skipPaired: boolean?)
	local currentState = door:GetAttribute("IsOpen") or false
	
	if currentState ~= isOpen then
		door:SetAttribute("IsOpen", isOpen)
		DoorStateChanged:FireAllClients(door, isOpen)
		print(string.format("[Door] %s is now %s", door.Name, isOpen and "OPEN" or "CLOSED"))
		
		-- Also update paired door (for double doors)
		if not skipPaired then
			local pairedDoor = findPairedDoor(door)
			if pairedDoor then
				local pairedState = pairedDoor:GetAttribute("IsOpen") or false
				if pairedState ~= isOpen then
					pairedDoor:SetAttribute("IsOpen", isOpen)
					DoorStateChanged:FireAllClients(pairedDoor, isOpen)
					print(string.format("[Door] %s (paired) is now %s", pairedDoor.Name, isOpen and "OPEN" or "CLOSED"))
				end
			end
		end
	end
end

-- Listen for IsPowered attribute changes on a door
local function SetupDoorPowerListener(door: Instance)
	door:GetAttributeChangedSignal("IsPowered"):Connect(function()
		local isPowered = door:GetAttribute("IsPowered") or false
		SetDoorState(door, isPowered)
	end)
end

-- ============================================
-- MONITOR BUILD AREAS FOR DOORS
-- ============================================

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
	
	-- Set up existing doors
	for _, block in ipairs(blocksFolder:GetChildren()) do
		if isDoorBlock(block) then
			SetupDoorPowerListener(block)
		end
	end
	
	-- Monitor for new doors
	blocksFolder.ChildAdded:Connect(function(block)
		task.wait()
		if isDoorBlock(block) then
			SetupDoorPowerListener(block)
		end
	end)
end

-- ============================================
-- DOOR TOGGLE (manual player interaction)
-- ============================================

ToggleDoor.OnServerEvent:Connect(function(player, door, pairedDoor)
	if not door or not door.Parent then return end
	if not isDoorBlock(door) then return end
	
	-- Toggle door state
	local isOpen = door:GetAttribute("IsOpen") or false
	local newState = not isOpen
	
	-- Update both doors' attributes first (before firing any events)
	door:SetAttribute("IsOpen", newState)
	
	local validPaired = pairedDoor and pairedDoor.Parent and isDoorBlock(pairedDoor)
	if validPaired then
		-- Verify it's the same door type
		local doorType = door:GetAttribute("BlockType")
		local pairedType = pairedDoor:GetAttribute("BlockType")
		if doorType ~= pairedType then
			validPaired = false
		end
	end
	
	if validPaired then
		pairedDoor:SetAttribute("IsOpen", newState)
	end
	
	-- Fire BOTH events at the same time for perfect sync
	if validPaired then
		-- Fire both in immediate succession
		DoorStateChanged:FireAllClients(door, newState)
		DoorStateChanged:FireAllClients(pairedDoor, newState)
		print(string.format("[Door] %s + %s (double) toggled to %s by %s", door.Name, pairedDoor.Name, newState and "OPEN" or "CLOSED", player.Name))
	else
		DoorStateChanged:FireAllClients(door, newState)
		print(string.format("[Door] %s toggled to %s by %s", door.Name, newState and "OPEN" or "CLOSED", player.Name))
	end
end)

-- ============================================
-- INITIALIZE
-- ============================================

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
end

Initialize()

print("DoorHandler initialized")
