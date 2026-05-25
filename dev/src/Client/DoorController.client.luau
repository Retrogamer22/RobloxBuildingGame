--[[
	DoorController
	Client-side door interaction handling
	- Right-click on doors to open/close them
	- Animated door swing using TweenService
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera

local REACH_DISTANCE = 15
local DOOR_OPEN_ANGLE = 90 -- Degrees
local DOOR_TWEEN_TIME = 0.3
local BLOCK_SIZE = 3 -- For detecting adjacent doors

-- Remotes for door sync
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
local ToggleDoor = nil
local DoorStateChanged = nil

-- Wait for remotes (they're created by DoorHandler)
task.spawn(function()
	ToggleDoor = Remotes:WaitForChild("ToggleDoor", 10)
	DoorStateChanged = Remotes:WaitForChild("DoorStateChanged", 10)
	
	-- Listen for door state changes from server
	if DoorStateChanged then
		DoorStateChanged.OnClientEvent:Connect(function(doorModel, isOpen)
			if doorModel and doorModel.Parent then
				animateDoor(doorModel, isOpen)
			end
		end)
	end
end)

-- Track currently tweening doors to prevent spam
local TweeningDoors = {}

-- ============================================
-- HELPER FUNCTIONS
-- ============================================

local function isDoorBlock(instance)
	if not instance then return false end
	
	-- Check if it's a door or part of a door model
	local block = instance
	if instance:GetAttribute("BlockType") then
		block = instance
	elseif instance.Parent and instance.Parent:GetAttribute("BlockType") then
		block = instance.Parent
	elseif instance.Parent and instance.Parent.Parent and instance.Parent.Parent:GetAttribute("BlockType") then
		block = instance.Parent.Parent
	else
		return false, nil
	end
	
	local blockType = block:GetAttribute("BlockType")
	if not blockType then return false, nil end
	
	-- Check if it's a door type
	if string.find(string.lower(blockType), "door") then
		return true, block
	end
	
	return false, nil
end

local function getDoorPart(doorModel)
	-- Find the "Door" part that should rotate
	if doorModel:IsA("Model") then
		local doorPart = doorModel:FindFirstChild("Door")
		if doorPart then return doorPart end
		
		-- Fallback: find largest part
		local largest = nil
		local largestSize = 0
		for _, part in ipairs(doorModel:GetDescendants()) do
			if part:IsA("BasePart") and part.Name ~= "Hinge" then
				local size = part.Size.X * part.Size.Y * part.Size.Z
				if size > largestSize then
					largestSize = size
					largest = part
				end
			end
		end
		return largest
	elseif doorModel:IsA("BasePart") then
		return doorModel
	end
	return nil
end

local function getHingePosition(doorModel, doorPart)
	-- Try to find a hinge part
	if doorModel:IsA("Model") then
		local hinge = doorModel:FindFirstChild("Hinge")
		if hinge and hinge:IsA("BasePart") then
			return hinge.Position
		end
	end
	
	-- Fallback: hinge is always on the local -X edge of the door
	-- (For right-hinged doors, the model is flipped 180° so local -X is on the visual right)
	if doorPart then
		local size = doorPart.Size
		local cf = doorPart.CFrame
		return (cf * CFrame.new(-size.X / 2, 0, 0)).Position
	end
	
	return doorModel:IsA("BasePart") and doorModel.Position or doorModel:GetPivot().Position
end

function animateDoor(doorModel, isOpening)
	if TweeningDoors[doorModel] then return end
	
	local doorPart = getDoorPart(doorModel)
	if not doorPart then return end
	
	TweeningDoors[doorModel] = true
	
	local hingePos = getHingePosition(doorModel, doorPart)
	local currentAngle = doorModel:GetAttribute("DoorAngle") or 0
	
	-- Get hinge side to determine rotation direction
	local hingeSide = doorModel:GetAttribute("DoorHingeSide") or "left"
	local angleMultiplier = (hingeSide == "right") and -1 or 1
	
	local targetAngle = isOpening and (DOOR_OPEN_ANGLE * angleMultiplier) or 0
	
	-- Store original CFrame if not stored
	if not doorModel:GetAttribute("OriginalCFrameStored") then
		if doorModel:IsA("Model") then
			local pivot = doorModel:GetPivot()
			doorModel:SetAttribute("OriginalPivotX", pivot.X)
			doorModel:SetAttribute("OriginalPivotY", pivot.Y)
			doorModel:SetAttribute("OriginalPivotZ", pivot.Z)
			-- Store rotation as matrix components
			local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = pivot:GetComponents()
			doorModel:SetAttribute("OriginalR00", r00)
			doorModel:SetAttribute("OriginalR01", r01)
			doorModel:SetAttribute("OriginalR02", r02)
			doorModel:SetAttribute("OriginalR10", r10)
			doorModel:SetAttribute("OriginalR11", r11)
			doorModel:SetAttribute("OriginalR12", r12)
			doorModel:SetAttribute("OriginalR20", r20)
			doorModel:SetAttribute("OriginalR21", r21)
			doorModel:SetAttribute("OriginalR22", r22)
		else
			local cf = doorPart.CFrame
			doorModel:SetAttribute("OriginalCFrameX", cf.X)
			doorModel:SetAttribute("OriginalCFrameY", cf.Y)
			doorModel:SetAttribute("OriginalCFrameZ", cf.Z)
			local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
			doorModel:SetAttribute("OriginalR00", r00)
			doorModel:SetAttribute("OriginalR01", r01)
			doorModel:SetAttribute("OriginalR02", r02)
			doorModel:SetAttribute("OriginalR10", r10)
			doorModel:SetAttribute("OriginalR11", r11)
			doorModel:SetAttribute("OriginalR12", r12)
			doorModel:SetAttribute("OriginalR20", r20)
			doorModel:SetAttribute("OriginalR21", r21)
			doorModel:SetAttribute("OriginalR22", r22)
		end
		doorModel:SetAttribute("HingeX", hingePos.X)
		doorModel:SetAttribute("HingeY", hingePos.Y)
		doorModel:SetAttribute("HingeZ", hingePos.Z)
		doorModel:SetAttribute("OriginalCFrameStored", true)
	end
	
	-- Get stored hinge position
	local storedHinge = Vector3.new(
		doorModel:GetAttribute("HingeX"),
		doorModel:GetAttribute("HingeY"),
		doorModel:GetAttribute("HingeZ")
	)
	
	-- Animate from current to target
	local startAngle = currentAngle
	local startTime = tick()
	
	-- Animate using RenderStepped for smooth door movement
	local connection
	connection = RunService.RenderStepped:Connect(function()
		local elapsed = tick() - startTime
		local alpha = math.min(elapsed / DOOR_TWEEN_TIME, 1)
		
		-- Ease out
		alpha = 1 - (1 - alpha) ^ 2
		
		local angle = startAngle + (targetAngle - startAngle) * alpha
		
		-- Apply rotation around hinge
		if doorModel:IsA("Model") then
			-- Reconstruct original CFrame
			local ox = doorModel:GetAttribute("OriginalPivotX")
			local oy = doorModel:GetAttribute("OriginalPivotY")
			local oz = doorModel:GetAttribute("OriginalPivotZ")
			local r00 = doorModel:GetAttribute("OriginalR00")
			local r01 = doorModel:GetAttribute("OriginalR01")
			local r02 = doorModel:GetAttribute("OriginalR02")
			local r10 = doorModel:GetAttribute("OriginalR10")
			local r11 = doorModel:GetAttribute("OriginalR11")
			local r12 = doorModel:GetAttribute("OriginalR12")
			local r20 = doorModel:GetAttribute("OriginalR20")
			local r21 = doorModel:GetAttribute("OriginalR21")
			local r22 = doorModel:GetAttribute("OriginalR22")
			
			local originalCFrame = CFrame.new(ox, oy, oz, r00, r01, r02, r10, r11, r12, r20, r21, r22)
			
			-- Rotate around hinge (Y axis)
			local rotationCFrame = CFrame.new(storedHinge) 
				* CFrame.Angles(0, math.rad(angle), 0) 
				* CFrame.new(-storedHinge)
			
			doorModel:PivotTo(rotationCFrame * originalCFrame)
		else
			-- Reconstruct original CFrame for BasePart
			local ox = doorModel:GetAttribute("OriginalCFrameX")
			local oy = doorModel:GetAttribute("OriginalCFrameY")
			local oz = doorModel:GetAttribute("OriginalCFrameZ")
			local r00 = doorModel:GetAttribute("OriginalR00")
			local r01 = doorModel:GetAttribute("OriginalR01")
			local r02 = doorModel:GetAttribute("OriginalR02")
			local r10 = doorModel:GetAttribute("OriginalR10")
			local r11 = doorModel:GetAttribute("OriginalR11")
			local r12 = doorModel:GetAttribute("OriginalR12")
			local r20 = doorModel:GetAttribute("OriginalR20")
			local r21 = doorModel:GetAttribute("OriginalR21")
			local r22 = doorModel:GetAttribute("OriginalR22")
			
			local originalCFrame = CFrame.new(ox, oy, oz, r00, r01, r02, r10, r11, r12, r20, r21, r22)
			
			local rotationCFrame = CFrame.new(storedHinge) 
				* CFrame.Angles(0, math.rad(angle), 0) 
				* CFrame.new(-storedHinge)
			
			doorPart.CFrame = rotationCFrame * originalCFrame
		end
		
		doorModel:SetAttribute("DoorAngle", angle)
		
		if alpha >= 1 then
			connection:Disconnect()
			TweeningDoors[doorModel] = nil
			doorModel:SetAttribute("IsOpen", isOpening)
		end
	end)
end

local function raycastForDoor()
	local viewportSize = Camera.ViewportSize
	local ray = Camera:ViewportPointToRay(viewportSize.X / 2, viewportSize.Y / 2)
	
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = {LocalPlayer.Character}
	
	local result = workspace:Raycast(ray.Origin, ray.Direction * REACH_DISTANCE, raycastParams)
	
	if result and result.Instance then
		local isDoor, doorBlock = isDoorBlock(result.Instance)
		if isDoor then
			return doorBlock
		end
	end
	
	return nil
end

-- Find a paired door for double-door configuration
-- Returns the paired door if found, nil otherwise
local function findPairedDoor(door)
	if not door then return nil end
	
	-- Get door attributes
	local direction = door:GetAttribute("DoorDirection")
	local depth = door:GetAttribute("DoorDepth")
	local hingeSide = door:GetAttribute("DoorHingeSide")
	local doorType = door:GetAttribute("BlockType")
	
	if direction == nil or not depth or not hingeSide then
		return nil
	end
	
	-- Get door position - use stored original if door has been opened (pivot moves when rotated)
	local doorPos
	if door:GetAttribute("OriginalCFrameStored") and door:IsA("Model") then
		local ox = door:GetAttribute("OriginalPivotX")
		local oy = door:GetAttribute("OriginalPivotY")
		local oz = door:GetAttribute("OriginalPivotZ")
		if ox and oy and oz then
			doorPos = Vector3.new(ox, oy, oz)
		end
	end
	-- Fallback to current position for fresh doors
	if not doorPos then
		if door:IsA("Model") then
			doorPos = door:GetPivot().Position
		elseif door:IsA("BasePart") then
			doorPos = door.Position
		end
	end
	
	if not doorPos then return nil end
	
	-- Get the blocks folder
	local blocksFolder = door.Parent
	if not blocksFolder then return nil end
	
	-- Search for adjacent door - use simple distance check
	-- Paired doors should be within BLOCK_SIZE distance horizontally and same Y level
	for _, block in ipairs(blocksFolder:GetChildren()) do
		-- Check if this block is a door by checking BlockType
		local blockType = block:GetAttribute("BlockType")
		local isBlockDoor = blockType and string.find(string.lower(blockType), "door")
		
		if block ~= door and isBlockDoor then
			-- Get block position - use stored original if opened
			local blockPos
			if block:GetAttribute("OriginalCFrameStored") and block:IsA("Model") then
				local ox = block:GetAttribute("OriginalPivotX")
				local oy = block:GetAttribute("OriginalPivotY")
				local oz = block:GetAttribute("OriginalPivotZ")
				if ox and oy and oz then
					blockPos = Vector3.new(ox, oy, oz)
				end
			end
			-- Fallback to current position for fresh doors
			if not blockPos then
				if block:IsA("Model") then
					blockPos = block:GetPivot().Position
				elseif block:IsA("BasePart") then
					blockPos = block.Position
				end
			end
			
			if blockPos then
				-- Check if within one block distance horizontally and same Y level
				local dx = math.abs(blockPos.X - doorPos.X)
				local dy = math.abs(blockPos.Y - doorPos.Y)
				local dz = math.abs(blockPos.Z - doorPos.Z)
				
				-- Should be adjacent (one block away in X or Z, same Y)
				local isAdjacent = false
				if direction == 0 or direction == 2 then -- NORTH or SOUTH - check X axis
					isAdjacent = (dx > 1 and dx < BLOCK_SIZE + 1) and dz < 1 and dy < 1
				else -- EAST or WEST - check Z axis
					isAdjacent = (dz > 1 and dz < BLOCK_SIZE + 1) and dx < 1 and dy < 1
				end
				
				if isAdjacent then
					-- Found adjacent door, now check attributes
					local otherDirection = block:GetAttribute("DoorDirection")
					local otherDepth = block:GetAttribute("DoorDepth")
					local otherHingeSide = block:GetAttribute("DoorHingeSide")
					
					-- Must have same direction, same depth, opposite hinge side, AND same door type
					if otherDirection == direction 
						and otherDepth == depth 
						and otherHingeSide ~= hingeSide
						and doorType == blockType then
						return block
					end
				end
			end
		end
	end
	
	return nil
end

-- ============================================
-- PUBLIC API (for BuildingController to check)
-- ============================================

local DoorController = {}

-- Check if we're looking at a door (called by BuildingController before placing)
function DoorController.IsLookingAtDoor()
	return raycastForDoor() ~= nil
end

-- Check if player is holding a block that can fill frame blocks
local function isHoldingFillableBlock()
	local blockData = _G.InventoryController and _G.InventoryController.GetSelectedBlock()
	if not blockData or blockData.IsTool then return false end
	
	local isRegular = (blockData.Shape == "Block")
		and not blockData.IsFrameBlock
		and not blockData.IsDecoration
		and not blockData.IsDoor
		and not blockData.IsFence
		and blockData.Id ~= "SnowLayer"
	
	return isRegular
end

-- Try to interact with door, returns true if we did interact
function DoorController.TryInteract()
	local door = raycastForDoor()
	if not door then return false end
	
	-- If this is an unfilled frame door and player is holding a fillable block,
	-- let the fill system handle it instead of opening/closing
	local isUnfilledFrameDoor = door:GetAttribute("IsFrameBlock")
		and not door:GetAttribute("FrameFillBlockId")
	if isUnfilledFrameDoor and isHoldingFillableBlock() then
		return false
	end
	
	-- Don't interact if already tweening
	if TweeningDoors[door] then return true end -- Return true to block placement
	
	-- Check for paired double door
	local pairedDoor = findPairedDoor(door)
	
	-- Send toggle request to server for main door (include paired door for sync)
	if ToggleDoor then
		-- Send both doors in one request so server can sync them properly
		ToggleDoor:FireServer(door, pairedDoor)
	end
	
	return true
end

-- Expose globally for BuildingController
_G.DoorController = DoorController

print("DoorController initialized (Right-click to interact with doors)")

return DoorController
