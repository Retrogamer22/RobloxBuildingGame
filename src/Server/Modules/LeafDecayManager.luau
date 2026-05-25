--[[
	LeafDecayManager
	Handles decay of generated tree leaves when they're no longer connected to logs.
	
	Only affects leaves with CanDecay = true (terrain-generated leaves).
	Player-placed leaves will NOT decay.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GridConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GridConfig"))
local BulkOperationFlags = require(ReplicatedStorage:WaitForChild("BulkOperationFlags", 10))

local LeafDecayManager = {}

local BLOCK_SIZE = GridConfig.BLOCK_SIZE

-- Decay settings
local DECAY_SETTINGS = {
	-- Maximum distance (in blocks) a leaf can be from a log to stay alive
	MAX_LOG_DISTANCE = 4,
	
	-- Delay range before a leaf decays (random between min and max)
	DECAY_DELAY_MIN = 0.5,
	DECAY_DELAY_MAX = 3.0,
	
	-- How often to check for decaying leaves after a log is broken (seconds)
	CHECK_RADIUS = 6,  -- Blocks radius to check around broken log
}

-- Track leaves scheduled for decay to prevent duplicate scheduling
local ScheduledForDecay = {}

-- Get position from a block (handles both BasePart and Model)
local function getBlockPosition(block)
	if block:IsA("BasePart") then
		return block.Position
	elseif block:IsA("Model") then
		-- Try PrimaryPart first
		local primary = block.PrimaryPart
		if primary then
			return primary.Position
		end
		-- Try GetPivot (more reliable for models without PrimaryPart)
		local success, pivot = pcall(function()
			return block:GetPivot()
		end)
		if success and pivot then
			-- Model pivot is at bottom, add half block to get center
			return pivot.Position + Vector3.new(0, BLOCK_SIZE / 2, 0)
		end
		-- Fallback: find first BasePart
		local firstPart = block:FindFirstChildWhichIsA("BasePart")
		if firstPart then
			return firstPart.Position
		end
	end
	return nil
end

-- Check if a block is a log
local function isLog(block)
	local blockType = block:GetAttribute("BlockType")
	if not blockType then return false end
	return blockType:find("Log") ~= nil
end

-- Check if a block is a decayable leaf
local function isDecayableLeaf(block)
	return block:GetAttribute("BlockType") == "Leaves" and block:GetAttribute("CanDecay") == true
end

-- Spatial query helper: find parts near a position using Roblox's spatial indexing
-- Much faster than iterating all children (O(nearby) vs O(total))
local function getBlocksInRadius(position, radiusStuds, blocksFolder)
	local size = Vector3.new(radiusStuds * 2, radiusStuds * 2, radiusStuds * 2)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = {blocksFolder}
	
	local parts = workspace:GetPartBoundsInBox(CFrame.new(position), size, params)
	
	-- Deduplicate: for Models, multiple parts belong to same block
	local seen = {}
	local blocks = {}
	for _, part in ipairs(parts) do
		-- Get the actual block (could be the part itself or its parent Model)
		local block = part
		if part.Parent and part.Parent:IsA("Model") and part.Parent.Parent == blocksFolder then
			block = part.Parent
		elseif part.Parent ~= blocksFolder then
			continue -- Not a direct child of blocksFolder
		end
		
		if not seen[block] then
			seen[block] = true
			table.insert(blocks, block)
		end
	end
	
	return blocks
end

-- Find all logs within a certain distance of a position
local function findNearbyLogs(position, blocksFolder, maxDistance)
	local logs = {}
	local maxDistStuds = maxDistance * BLOCK_SIZE
	
	local nearbyBlocks = getBlocksInRadius(position, maxDistStuds, blocksFolder)
	for _, block in ipairs(nearbyBlocks) do
		if isLog(block) then
			table.insert(logs, block)
		end
	end
	
	return logs
end

-- Check if a leaf is connected to any log within MAX_LOG_DISTANCE
local function isLeafConnectedToLog(leafPosition, blocksFolder)
	local nearbyLogs = findNearbyLogs(leafPosition, blocksFolder, DECAY_SETTINGS.MAX_LOG_DISTANCE)
	return #nearbyLogs > 0
end

-- Decay a single leaf with optional effects
local function decayLeaf(leaf)
	if not leaf or not leaf.Parent then return end
	
	-- Remove from scheduled list
	ScheduledForDecay[leaf] = nil
	
	-- Get position for potential effects
	local pos = getBlockPosition(leaf)
	
	-- TODO: Add particle effects here if desired
	-- Could spawn leaf particles falling down
	
	-- Destroy the leaf
	leaf:Destroy()
end

-- Schedule a leaf for decay with random delay
local function scheduleLeafDecay(leaf)
	if not leaf or not leaf.Parent then return end
	if ScheduledForDecay[leaf] then return end  -- Already scheduled
	
	ScheduledForDecay[leaf] = true
	
	local delay = DECAY_SETTINGS.DECAY_DELAY_MIN + 
		math.random() * (DECAY_SETTINGS.DECAY_DELAY_MAX - DECAY_SETTINGS.DECAY_DELAY_MIN)
	
	task.delay(delay, function()
		decayLeaf(leaf)
	end)
end

-- Check all leaves near a position and schedule decay for disconnected ones
local function checkLeavesNearPosition(position, blocksFolder)
	local checkRadiusStuds = DECAY_SETTINGS.CHECK_RADIUS * BLOCK_SIZE
	
	local nearbyBlocks = getBlocksInRadius(position, checkRadiusStuds, blocksFolder)
	for _, block in ipairs(nearbyBlocks) do
		if isDecayableLeaf(block) then
			local blockPos = getBlockPosition(block)
			if blockPos then
				-- Check if this leaf is still connected to a log
				if not isLeafConnectedToLog(blockPos, blocksFolder) then
					scheduleLeafDecay(block)
				end
			end
		end
	end
end

-- Called when a log is broken - triggers decay check for nearby leaves
function LeafDecayManager.OnLogBroken(logPosition, blocksFolder)
	-- Small delay to let the log actually be removed first
	task.defer(function()
		checkLeavesNearPosition(logPosition, blocksFolder)
	end)
end

-- Called when any block is broken - checks if it's a log and triggers decay
function LeafDecayManager.OnBlockBroken(block, blocksFolder)
	if not block then return end
	
	-- Check if it was a log
	if isLog(block) then
		local position = getBlockPosition(block)
		if position then
			LeafDecayManager.OnLogBroken(position, blocksFolder)
		end
	end
end

-- Initialize decay manager for a build area (sets up monitoring)
function LeafDecayManager.Initialize(buildArea)
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder then return end
	
	-- Check if already initialized to prevent duplicate listeners
	if blocksFolder:GetAttribute("LeafDecayInitialized") then return end
	blocksFolder:SetAttribute("LeafDecayInitialized", true)
	
	-- Monitor for removed children (broken blocks)
	blocksFolder.ChildRemoved:Connect(function(child)
		-- Skip during bulk operations (terrain gen, save loading)
		if BulkOperationFlags.IsBulkOperation(buildArea) then return end
		if blocksFolder:GetAttribute("BulkOperationInProgress") then return end
		
		-- Skip during bulk removal (folder being cleared)
		if blocksFolder:GetAttribute("BulkRemoving") then return end
		
		-- Skip if folder is no longer parented (being destroyed)
		if not blocksFolder.Parent then return end
		
		-- Skip if being removed by save system (batch removal)
		if child:GetAttribute("BeingRemovedBySaveSystem") then return end
		
		-- When a log is removed, check nearby leaves
		if isLog(child) then
			local position = getBlockPosition(child)
			if position then
				-- Delay slightly to ensure block is fully gone
				task.defer(function()
					-- Double-check folder still exists and not being cleared
					if blocksFolder.Parent and not blocksFolder:GetAttribute("BulkRemoving") then
						checkLeavesNearPosition(position, blocksFolder)
					end
				end)
			end
		end
	end)
	
	print("[LeafDecayManager] Initialized for " .. buildArea.Name)
end

-- Manually trigger decay check for all leaves in a blocks folder
function LeafDecayManager.CheckAllLeaves(blocksFolder)
	for _, block in ipairs(blocksFolder:GetChildren()) do
		if isDecayableLeaf(block) then
			local blockPos = getBlockPosition(block)
			if blockPos and not isLeafConnectedToLog(blockPos, blocksFolder) then
				scheduleLeafDecay(block)
			end
		end
	end
end

-- Update decay settings
function LeafDecayManager.SetSettings(settings)
	for key, value in pairs(settings) do
		if DECAY_SETTINGS[key] ~= nil then
			DECAY_SETTINGS[key] = value
		end
	end
end

-- Get current settings
function LeafDecayManager.GetSettings()
	return DECAY_SETTINGS
end

return LeafDecayManager
