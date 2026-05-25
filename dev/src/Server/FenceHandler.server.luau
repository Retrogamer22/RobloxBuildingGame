--[[
	FenceHandler
	Server-side handler for fence interactions
	- Toggle fence connections to adjacent solid blocks
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FencePlacement = require(ReplicatedStorage:WaitForChild("FencePlacement", 10))
local GridConfig = require(ReplicatedStorage:WaitForChild("Config", 10):WaitForChild("GridConfig", 10))
local BlockTemplates = ReplicatedStorage:WaitForChild("BlockTemplates", 10)
local FrameBlocksFolder = ReplicatedStorage:FindFirstChild("FrameBlocks")

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)

-- Create the toggle remote
local ToggleFenceConnection = Instance.new("RemoteEvent")
ToggleFenceConnection.Name = "ToggleFenceConnection"
ToggleFenceConnection.Parent = Remotes

local BLOCK_SIZE = GridConfig.BLOCK_SIZE
local DEBUG_FENCES = false

-- ============================================
-- HELPER FUNCTIONS
-- ============================================

local function getPlayerBuildArea(player)
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

-- Create a fence block (copy of the function from BlockHandler)
local function createFenceBlock(templateName, fenceType, fencePos, fenceRotation, placedBy, connectionType, oldColor, oldMaterial, oldMaterialVariant, blocksFolder)
	-- Check if this is a frame fence - look in FrameBlocks folder
	local isFrameFence = FencePlacement.IsFrameFence(fenceType)
	local template
	if isFrameFence and FrameBlocksFolder then
		template = FrameBlocksFolder:FindFirstChild(templateName)
	end
	if not template then
		template = BlockTemplates:FindFirstChild(templateName)
	end
	if not template then
		warn("[FenceHandler] Template not found: " .. tostring(templateName))
		return nil
	end
	
	local newFence = template:Clone()
	newFence.Name = fenceType
	
	-- Anchor the fence
	if newFence:IsA("BasePart") then
		newFence.Anchored = true
	elseif newFence:IsA("Model") then
		for _, part in ipairs(newFence:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Anchored = true
			end
		end
	end
	
	-- Position the fence
	local fenceCFrame = FencePlacement.GetFenceCFrame(fencePos, fenceRotation, isFrameFence)
	if newFence:IsA("BasePart") then
		newFence:PivotTo(fenceCFrame)
	elseif newFence:IsA("Model") then
		newFence:PivotTo(fenceCFrame)
	end
	
	-- Apply color/material (skip for frame fences - they keep original appearance)
	if not isFrameFence and oldColor and oldMaterial and newFence:IsA("BasePart") then
		newFence.Color = oldColor
		newFence.Material = oldMaterial
		if oldMaterialVariant and oldMaterialVariant ~= "" then
			newFence.MaterialVariant = oldMaterialVariant
		end
	end
	
	-- Set attributes
	newFence:SetAttribute("BlockType", fenceType)
	newFence:SetAttribute("PlacedBy", placedBy)
	newFence:SetAttribute("Rotation", fenceRotation)
	newFence:SetAttribute("IsFence", true)
	newFence:SetAttribute("FenceConnectionType", connectionType)
	-- Store grid position for spatial index (fence unions have offset geometric centers)
	newFence:SetAttribute("BlockPosX", fencePos.X)
	newFence:SetAttribute("BlockPosY", fencePos.Y)
	newFence:SetAttribute("BlockPosZ", fencePos.Z)
	if isFrameFence then
		newFence:SetAttribute("IsFrameBlock", true)
	end
	
	newFence.Parent = blocksFolder
	return newFence
end

-- ============================================
-- TOGGLE FENCE CONNECTION
-- ============================================

ToggleFenceConnection.OnServerEvent:Connect(function(player, fence, clickPosition)
	if not fence then return end
	if not fence:GetAttribute("IsFence") then return end
	
	-- Verify player owns this plot
	local buildArea = getPlayerBuildArea(player)
	if not buildArea then return end
	
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder then return end
	
	-- Verify fence is in player's blocks folder
	if fence.Parent ~= blocksFolder then return end
	
	-- Get fence position
	local fencePos = fence:GetPivot().Position
	
	-- Get all adjacent solid blocks (not fences)
	local adjacentSolids = FencePlacement.GetAdjacentSolidBlockDirections(fencePos, blocksFolder)
	
	-- Get currently blocked directions
	local blockedDirs = FencePlacement.ParseBlockedDirections(fence:GetAttribute("BlockedDirections"))
	
	-- Build list of solid block directions (excluding fence-to-fence connections)
	local DIRECTION_OFFSETS = {
		[0] = Vector3.new(0, 0, -BLOCK_SIZE),
		[1] = Vector3.new(BLOCK_SIZE, 0, 0),
		[2] = Vector3.new(0, 0, BLOCK_SIZE),
		[3] = Vector3.new(-BLOCK_SIZE, 0, 0),
	}
	
	local solidBlockDirections = {}
	for _, adj in ipairs(adjacentSolids) do
		local adjacentPos = fencePos + DIRECTION_OFFSETS[adj.direction]
		local adjacentFence = FencePlacement.GetFenceAtPosition(adjacentPos, blocksFolder)
		if not adjacentFence then
			-- This is a solid block, not a fence
			table.insert(solidBlockDirections, adj.direction)
		end
	end
	
	-- Also include currently blocked directions (so we can unblock them)
	for dir, _ in pairs(blockedDirs) do
		local alreadyInList = false
		for _, existingDir in ipairs(solidBlockDirections) do
			if existingDir == dir then
				alreadyInList = true
				break
			end
		end
		if not alreadyInList then
			table.insert(solidBlockDirections, dir)
		end
	end
	
	if #solidBlockDirections == 0 then
		-- No solid blocks adjacent (only fences or nothing)
		if DEBUG_FENCES then
			print("[FenceHandler] No solid block connections to toggle")
		end
		return
	end
	
	-- Determine if we should block or unblock ALL solid block connections
	-- If ANY are unblocked, block all. If ALL are blocked, unblock all.
	local anyUnblocked = false
	for _, dir in ipairs(solidBlockDirections) do
		if not blockedDirs[dir] then
			anyUnblocked = true
			break
		end
	end
	
	local shouldBlock = anyUnblocked -- Block all if any are unblocked, unblock all if all are blocked
	
	-- Update all solid block directions
	local newBlockedDirs = {}
	-- Start with existing blocked directions (preserve any non-solid-block blocks)
	for dir, _ in pairs(blockedDirs) do
		newBlockedDirs[dir] = true
	end
	
	-- Now set all solid block directions based on shouldBlock
	for _, dir in ipairs(solidBlockDirections) do
		if shouldBlock then
			newBlockedDirs[dir] = true
		else
			newBlockedDirs[dir] = nil
		end
	end
	
	local newBlockedDirsStr = FencePlacement.SerializeBlockedDirections(newBlockedDirs)
	
	if DEBUG_FENCES then
		print(string.format("[FenceHandler] Toggling ALL solid block connections: %s (dirs: %s)",
			shouldBlock and "BLOCKED" or "UNBLOCKED",
			table.concat(solidBlockDirections, ", ")))
	end
	
	-- Store fence info before destroying
	local fenceType = fence:GetAttribute("BlockType")
	local placedBy = fence:GetAttribute("PlacedBy")
	local isFilledFence = fence:GetAttribute("IsFilledFence")
	local oldColor, oldMaterial, oldMaterialVariant
	if fence:IsA("BasePart") then
		oldColor = fence.Color
		oldMaterial = fence.Material
		oldMaterialVariant = fence.MaterialVariant
	end
	
	-- Save fill attributes if this is a filled fence
	local fillAttrs = nil
	if isFilledFence then
		fillAttrs = {
			FrameFillBlockId = fence:GetAttribute("FrameFillBlockId"),
			FrameFillColorR = fence:GetAttribute("FrameFillColorR"),
			FrameFillColorG = fence:GetAttribute("FrameFillColorG"),
			FrameFillColorB = fence:GetAttribute("FrameFillColorB"),
			FrameFillMaterialVariant = fence:GetAttribute("FrameFillMaterialVariant"),
		}
	end
	
	-- Destroy old fence
	fence:Destroy()
	
	-- Recalculate what the fence should be with the new blocked directions
	local tempFence = Instance.new("Part")
	tempFence:SetAttribute("BlockedDirections", newBlockedDirsStr)
	
	local newPlacementInfo = FencePlacement.GetPlacementInfo(
		fenceType,
		fencePos,
		blocksFolder,
		DEBUG_FENCES,
		true, -- checkSolidBlocks
		tempFence -- pass temp fence for blocked directions
	)
	
	tempFence:Destroy()
	
	-- Create new fence with updated connections
	local newFence = createFenceBlock(
		newPlacementInfo.templateName,
		fenceType,
		fencePos,
		newPlacementInfo.rotation,
		placedBy,
		newPlacementInfo.connectionType,
		oldColor,
		oldMaterial,
		oldMaterialVariant,
		blocksFolder
	)
	
	if newFence then
		-- Restore blocked directions
		if newBlockedDirsStr and newBlockedDirsStr ~= "" then
			newFence:SetAttribute("BlockedDirections", newBlockedDirsStr)
		end
		
		-- Restore filled fence attributes
		if isFilledFence and fillAttrs then
			newFence:SetAttribute("IsFilledFence", true)
			for attrName, attrValue in pairs(fillAttrs) do
				newFence:SetAttribute(attrName, attrValue)
			end
		end
		
		print(string.format("[FenceHandler] Updated fence to %s (solid blocks now %s)",
			newPlacementInfo.connectionType,
			shouldBlock and "blocked" or "unblocked"))
	end
end)

print("FenceHandler initialized")
