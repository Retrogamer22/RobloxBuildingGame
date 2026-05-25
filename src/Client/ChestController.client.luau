--[[
	ChestController
	Client-side chest interaction handling
	- Right-click on chests to open/close the lid
	- Animated lid swing using RenderStepped
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
local Camera = workspace.CurrentCamera

local BlockPresetsModule = ReplicatedStorage:WaitForChild("BlockPresets", 10)
local BlockPresets = BlockPresetsModule and require(BlockPresetsModule)

local REACH_DISTANCE = 15
local LID_OPEN_ANGLE = 90 -- Degrees, positive to flip backward on local X
local LID_TWEEN_TIME = 0.4

-- Remotes for chest sync
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
local ToggleChest = nil
local ChestStateChanged = nil

-- Store closed pivots for each chest's Top model
local ClosedPivots = {} -- [topModel] = CFrame

-- Track currently animating chests
local AnimatingChests = {}

-- ============================================
-- HELPER FUNCTIONS
-- ============================================

local function isChestBlock(instance)
	if not instance then return false end
	
	-- Walk up to find the chest model (could click on a sub-part)
	local block = instance
	if instance:GetAttribute("BlockType") then
		block = instance
	elseif instance.Parent and instance.Parent:GetAttribute("BlockType") then
		block = instance.Parent
	elseif instance.Parent and instance.Parent.Parent and instance.Parent.Parent:GetAttribute("BlockType") then
		block = instance.Parent.Parent
	elseif instance.Parent and instance.Parent.Parent and instance.Parent.Parent.Parent and instance.Parent.Parent.Parent:GetAttribute("BlockType") then
		-- Parts inside Bottom/Top sub-models
		block = instance.Parent.Parent.Parent
	else
		return false, nil
	end
	
	local blockType = block:GetAttribute("BlockType")
	if not blockType then return false, nil end
	
	if BlockPresets and BlockPresets.IsChest and BlockPresets.IsChest(blockType) then
		return true, block
	end
	
	return false, nil
end

local function initChestPivot(chestModel)
	local top = chestModel:FindFirstChild("Top")
	if not top or ClosedPivots[top] then return end
	ClosedPivots[top] = top:GetPivot()
end

local function animateChestLid(chestModel, isOpening)
	if AnimatingChests[chestModel] then return end
	
	local top = chestModel:FindFirstChild("Top")
	if not top then return end
	
	-- Initialize closed pivot if not stored
	if not ClosedPivots[top] then
		ClosedPivots[top] = top:GetPivot()
	end
	
	AnimatingChests[chestModel] = true
	chestModel:SetAttribute("IsAnimating", true)
	
	local closedPivot = ClosedPivots[top]
	local targetAngle = isOpening and math.rad(LID_OPEN_ANGLE) or 0
	local startAngle = isOpening and 0 or math.rad(LID_OPEN_ANGLE)
	local startTime = tick()
	
	local connection
	connection = RunService.RenderStepped:Connect(function()
		local elapsed = tick() - startTime
		local alpha = math.min(elapsed / LID_TWEEN_TIME, 1)
		
		-- Ease out quad
		alpha = 1 - (1 - alpha) ^ 2
		
		local angle = startAngle + (targetAngle - startAngle) * alpha
		local pivot = closedPivot * CFrame.Angles(angle, 0, 0)
		top:PivotTo(pivot)
		
		if alpha >= 1 then
			connection:Disconnect()
			AnimatingChests[chestModel] = nil
			chestModel:SetAttribute("IsAnimating", false)
			chestModel:SetAttribute("IsOpen", isOpening)
		end
	end)
end

-- ============================================
-- REMOTES
-- ============================================

task.spawn(function()
	ToggleChest = Remotes:WaitForChild("ToggleChest", 10)
	ChestStateChanged = Remotes:WaitForChild("ChestStateChanged", 10)
	
	if ChestStateChanged then
		ChestStateChanged.OnClientEvent:Connect(function(chestModel, isOpen)
			if chestModel and chestModel.Parent then
				initChestPivot(chestModel)
				animateChestLid(chestModel, isOpen)
			end
		end)
	end
end)

-- ============================================
-- RAYCAST
-- ============================================

local function raycastForChest()
	local viewportSize = Camera.ViewportSize
	local ray = Camera:ViewportPointToRay(viewportSize.X / 2, viewportSize.Y / 2)
	
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = {LocalPlayer.Character}
	
	local result = workspace:Raycast(ray.Origin, ray.Direction * REACH_DISTANCE, raycastParams)
	
	if result and result.Instance then
		local isChest, chestBlock = isChestBlock(result.Instance)
		if isChest then
			return chestBlock
		end
	end
	
	return nil
end

-- ============================================
-- PUBLIC API
-- ============================================

local ChestController = {}

function ChestController.IsLookingAtChest()
	return raycastForChest() ~= nil
end

function ChestController.TryInteract()
	local chest = raycastForChest()
	if not chest then return false end
	
	-- Don't interact if already animating
	if AnimatingChests[chest] then return true end -- Return true to block placement
	
	-- Send toggle request to server
	if ToggleChest then
		ToggleChest:FireServer(chest)
	end
	
	return true
end

-- Clean up stored pivots when chest is destroyed
workspace.DescendantRemoving:Connect(function(descendant)
	if descendant.Name == "Top" and ClosedPivots[descendant] then
		ClosedPivots[descendant] = nil
	end
end)

-- ============================================
-- RESTORE OPEN CHESTS ON LOAD
-- ============================================
-- Scan all build areas for chests saved in the open state and snap their lid open instantly

local function restoreOpenChest(chestModel)
	if not chestModel:GetAttribute("IsChest") then return end
	if not chestModel:GetAttribute("IsOpen") then return end
	
	local top = chestModel:FindFirstChild("Top")
	if not top then return end
	
	-- Store closed pivot then snap to open
	if not ClosedPivots[top] then
		ClosedPivots[top] = top:GetPivot()
	end
	
	local openAngle = math.rad(LID_OPEN_ANGLE)
	top:PivotTo(ClosedPivots[top] * CFrame.Angles(openAngle, 0, 0))
end

local function scanForOpenChests(container)
	if not container then return end
	local blocksFolder = container:FindFirstChild("Blocks")
	if not blocksFolder then return end
	
	for _, block in ipairs(blocksFolder:GetChildren()) do
		if block:GetAttribute("IsChest") and block:GetAttribute("IsOpen") then
			restoreOpenChest(block)
		end
	end
end

-- Scan existing build areas
task.defer(function()
	task.wait(2) -- Wait for plot to load
	local GridConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GridConfig"))
	for i = 1, GridConfig.TOTAL_PLOTS do
		local buildArea = workspace:FindFirstChild(GridConfig.BUILD_AREA_PREFIX .. i)
		if buildArea then
			scanForOpenChests(buildArea)
		end
	end
	-- Also check MegaPlot
	local megaPlotRoom = workspace:FindFirstChild("MegaPlotRoom")
	if megaPlotRoom then
		local megaBuildArea = megaPlotRoom:FindFirstChild("MegaPlotBuildArea")
		if megaBuildArea then
			scanForOpenChests(megaBuildArea)
		end
	end
end)

-- Expose globally for BuildingController
_G.ChestController = ChestController

print("ChestController initialized (Right-click to interact with chests)")

return ChestController
