--[[
	WaterHandler
	Server-side water flow management for BuildBlox.
	
	Responsibilities:
	- Creates/destroys water Part instances based on WaterSystem flow calculations
	- Hooks into block placement and removal to trigger flow recalculation
	- Manages Water Bucket placement (creates source) and Empty Bucket pickup
	- Uses BulkOperationFlags to prevent cascading events during flow updates
	- Uses BlockSpatialIndex for O(1) neighbor lookups
	
	Water blocks are stored as BaseParts in the Blocks folder with attributes:
	- BlockType = "Water"
	- WaterLevel = 0 (source) or 1-7 (flowing)
	- IsWater = true
	- IsFalling = true/false
	- BlockPosX/Y/Z = grid position (for spatial index)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

-- Wait for dependencies
local WaterSystem = require(ReplicatedStorage:WaitForChild("WaterSystem", 10))
local BlockSpatialIndex = require(ReplicatedStorage:WaitForChild("BlockSpatialIndex", 10))
local BulkOperationFlags = require(ReplicatedStorage:WaitForChild("BulkOperationFlags", 10))
local GridConfig = require(ReplicatedStorage:WaitForChild("Config", 10):WaitForChild("GridConfig", 10))

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)

-- Create water-specific remotes
local PlaceWater = Remotes:FindFirstChild("PlaceWater")
if not PlaceWater then
	PlaceWater = Instance.new("RemoteEvent")
	PlaceWater.Name = "PlaceWater"
	PlaceWater.Parent = Remotes
end

local PickupWater = Remotes:FindFirstChild("PickupWater")
if not PickupWater then
	PickupWater = Instance.new("RemoteEvent")
	PickupWater.Name = "PickupWater"
	PickupWater.Parent = Remotes
end

-- Water flow update remote (notifies clients of flow changes for effects)
local WaterFlowUpdate = Remotes:FindFirstChild("WaterFlowUpdate")
if not WaterFlowUpdate then
	WaterFlowUpdate = Instance.new("RemoteEvent")
	WaterFlowUpdate.Name = "WaterFlowUpdate"
	WaterFlowUpdate.Parent = Remotes
end

-- Create BuildRejected reference
local BuildRejected = Remotes:WaitForChild("BuildRejected", 5)

local BLOCK_SIZE = GridConfig.BLOCK_SIZE
local DEBUG_WATER = false

-- ============================================
-- PERMISSION CHECK (shared with BlockHandler)
-- ============================================

local CheckPlotBuildPermission = nil
task.spawn(function()
	CheckPlotBuildPermission = ReplicatedStorage:WaitForChild("CheckPlotBuildPermission", 10)
end)

local PrivateServerManager = nil
task.spawn(function()
	local modulesFolder = ServerScriptService:WaitForChild("Modules", 10)
	if modulesFolder then
		local psModule = modulesFolder:WaitForChild("PrivateServerManager", 5)
		if psModule then
			PrivateServerManager = require(psModule)
		end
	end
end)

local function getBuildAreaAtPosition(position)
	-- Check MegaPlot first
	if PrivateServerManager and PrivateServerManager.IsPrivateServer() then
		local mode = PrivateServerManager.GetMode()
		if mode == "MegaPlot" and _G.MegaPlotVisibility then
			local megaPlotBuildArea = _G.MegaPlotVisibility.GetMegaPlotBuildArea()
			if megaPlotBuildArea then
				local posX = megaPlotBuildArea:GetAttribute("BasePlatePositionX")
				local posZ = megaPlotBuildArea:GetAttribute("BasePlatePositionZ")
				local sizeX = megaPlotBuildArea:GetAttribute("BasePlateSizeX")
				local sizeZ = megaPlotBuildArea:GetAttribute("BasePlateSizeZ")
				local plateTop = megaPlotBuildArea:GetAttribute("BasePlateTop")
				
				if posX and posZ and sizeX and sizeZ and plateTop then
					local halfX = sizeX / 2
					local halfZ = sizeZ / 2
					if position.X >= posX - halfX and position.X <= posX + halfX and
					   position.Z >= posZ - halfZ and position.Z <= posZ + halfZ then
						return megaPlotBuildArea, 0
					end
				end
			end
		end
	end
	
	for i = 1, GridConfig.TOTAL_PLOTS do
		local buildArea = workspace:FindFirstChild(GridConfig.BUILD_AREA_PREFIX .. i)
		if buildArea then
			local posX = buildArea:GetAttribute("BasePlatePositionX")
			local posY = buildArea:GetAttribute("BasePlatePositionY")
			local posZ = buildArea:GetAttribute("BasePlatePositionZ")
			local sizeX = buildArea:GetAttribute("BasePlateSizeX")
			local sizeY = buildArea:GetAttribute("BasePlateSizeY")
			local sizeZ = buildArea:GetAttribute("BasePlateSizeZ")
			
			if posX and posY and posZ and sizeX and sizeY and sizeZ then
				local halfX = sizeX / 2
				local halfZ = sizeZ / 2
				if position.X >= posX - halfX and position.X <= posX + halfX and
				   position.Z >= posZ - halfZ and position.Z <= posZ + halfZ then
					local plateTop = posY + sizeY / 2
					local minY = plateTop - (GridConfig.TERRAIN.MAX_DEPTH * BLOCK_SIZE) - BLOCK_SIZE
					local maxY = plateTop + GridConfig.PLOT_HEIGHT
					if position.Y >= minY and position.Y <= maxY then
						return buildArea, i
					end
				end
			end
		end
	end
	return nil, nil
end

local function canPlayerBuildAtPosition(player, position)
	local buildArea, plotNumber = getBuildAreaAtPosition(position)
	if not buildArea or plotNumber == nil then return false, nil end
	
	if plotNumber == 0 then
		if PrivateServerManager and PrivateServerManager.IsPrivateServer() then
			return true, buildArea
		end
		return false, nil
	end
	
	if PrivateServerManager and PrivateServerManager.IsPrivateServer() then
		local canBuild = PrivateServerManager.CanBuildOnPlot(player, plotNumber)
		if canBuild then return true, buildArea end
	end
	
	local ownerUserId = buildArea:GetAttribute("OwnerUserId")
	if ownerUserId == player.UserId then return true, buildArea end
	
	if CheckPlotBuildPermission then
		local hasPermission = CheckPlotBuildPermission:Invoke(player, plotNumber)
		if hasPermission then return true, buildArea end
	end
	
	return false, nil
end

-- ============================================
-- WATER BLOCK CREATION
-- ============================================

local function createWaterBlock(position, level, isFalling, blocksFolder, placedBy)
	local visual = WaterSystem.GetWaterVisualProperties(level, isFalling)
	
	local waterPart = Instance.new("Part")
	waterPart.Name = "Water"
	waterPart.Anchored = true
	waterPart.CanCollide = false
	waterPart.CanQuery = true
	waterPart.CastShadow = false
	waterPart.Size = visual.Size
	waterPart.Color = visual.Color
	waterPart.Transparency = visual.Transparency
	waterPart.Material = visual.Material
	waterPart.TopSurface = Enum.SurfaceType.Smooth
	waterPart.BottomSurface = Enum.SurfaceType.Smooth
	
	-- Position: bottom-aligned in grid cell
	waterPart.CFrame = CFrame.new(position.X, position.Y + visual.YOffset, position.Z)
	
	-- Attributes for system identification
	waterPart:SetAttribute("BlockType", "Water")
	waterPart:SetAttribute("WaterLevel", level)
	waterPart:SetAttribute("IsWater", true)
	waterPart:SetAttribute("IsFalling", isFalling)
	waterPart:SetAttribute("PlacedBy", placedBy or 0)
	
	-- Store grid position for spatial index
	waterPart:SetAttribute("BlockPosX", position.X)
	waterPart:SetAttribute("BlockPosY", position.Y)
	waterPart:SetAttribute("BlockPosZ", position.Z)
	
	waterPart.Parent = blocksFolder
	
	if DEBUG_WATER then
		print(string.format("[Water] Created level=%d falling=%s at (%.1f, %.1f, %.1f)",
			level, tostring(isFalling), position.X, position.Y, position.Z))
	end
	
	return waterPart
end

-- ============================================
-- FLOW UPDATE (recalculate and sync water blocks)
-- ============================================

-- Debounce per build area to prevent multiple simultaneous recalculations
local flowUpdateDebounce = {} -- buildArea -> true/false
local flowUpdateQueued = {}   -- buildArea -> true/false

-- How long to wait between each wave of water spreading (in seconds)
local WAVE_DELAY = 0.12 -- ~7-8 fps feel, fast but visible spreading

local function updateFlow(buildArea)
	if not buildArea then return end
	
	-- Debounce: if already updating, queue another update for after
	if flowUpdateDebounce[buildArea] then
		flowUpdateQueued[buildArea] = true
		return
	end
	
	flowUpdateDebounce[buildArea] = true
	
	-- Defer to next frame to batch rapid changes
	task.defer(function()
		local blocksFolder = buildArea:FindFirstChild("Blocks")
		if not blocksFolder then
			flowUpdateDebounce[buildArea] = nil
			return
		end
		
		local spatialIndex = BlockSpatialIndex.GetOrCreate(blocksFolder)
		
		-- Start bulk operation to prevent cascading events
		BulkOperationFlags.StartBulkOperation(buildArea, "WaterFlow")
		
		-- Calculate desired flow state
		local flowMap = WaterSystem.CalculateFlow(blocksFolder, buildArea, spatialIndex)
		
		-- Collect existing water blocks
		local existingWater = {} -- posKey -> waterBlock
		
		for _, block in ipairs(blocksFolder:GetChildren()) do
			if block:GetAttribute("IsWater") then
				local bx = block:GetAttribute("BlockPosX")
				local by = block:GetAttribute("BlockPosY")
				local bz = block:GetAttribute("BlockPosZ")
				if bx and by and bz then
					local pos = Vector3.new(bx, by, bz)
					local key = WaterSystem.PosKey(pos)
					existingWater[key] = block
				end
			end
		end
		
		-- Sort flow entries into waves by BFS distance for gradual spreading.
		-- Distance tracks total hops from source, so water that travels 3
		-- blocks then falls appears AFTER the 3 horizontal blocks, not at
		-- the same time.
		local waves = {} -- distance -> { { key, flowData }, ... }
		local toUpdate = {} -- existing blocks that need updating (instant)
		
		for key, flowData in pairs(flowMap) do
			local existing = existingWater[key]
			
			if existing then
				-- Water already exists here - check if it needs updating
				local currentLevel = existing:GetAttribute("WaterLevel") or 0
				local currentFalling = existing:GetAttribute("IsFalling") or false
				
				if currentLevel ~= flowData.level or currentFalling ~= flowData.isFalling then
					table.insert(toUpdate, { existing = existing, flowData = flowData })
				end
				
				-- Mark as processed (don't remove later)
				existingWater[key] = nil
			else
				-- New water - group by BFS distance for wave spawning
				local waveDist = flowData.distance or 0
				
				if not waves[waveDist] then
					waves[waveDist] = {}
				end
				table.insert(waves[waveDist], { key = key, flowData = flowData })
			end
		end
		
		-- Phase 1: Instantly update existing blocks that changed level
		local updated = 0
		for _, entry in ipairs(toUpdate) do
			local visual = WaterSystem.GetWaterVisualProperties(entry.flowData.level, entry.flowData.isFalling)
			entry.existing.Size = visual.Size
			entry.existing.CFrame = CFrame.new(
				entry.flowData.position.X,
				entry.flowData.position.Y + visual.YOffset,
				entry.flowData.position.Z
			)
			entry.existing:SetAttribute("WaterLevel", entry.flowData.level)
			entry.existing:SetAttribute("IsFalling", entry.flowData.isFalling)
			updated += 1
		end
		
		-- Phase 2: Drain water that shouldn't exist anymore
		-- Each tick, all remaining water levels increase by 1 (blocks get shorter).
		-- Blocks past MAX_LEVEL (7) are destroyed. Center blocks (low levels) take
		-- longest to drain, creating a natural shrinking-inward effect.
		local removed = 0
		local toRemoveCount = 0
		for _ in pairs(existingWater) do
			toRemoveCount += 1
		end
		
		while toRemoveCount > 0 do
			local skipDelay = flowUpdateQueued[buildArea]
			
			local stillAlive = 0
			for key, waterBlock in pairs(existingWater) do
				if not waterBlock.Parent then
					existingWater[key] = nil
					continue
				end
				
				if skipDelay then
					-- Another update is waiting: destroy immediately to avoid
					-- leaving blocks in partially-drained states
					waterBlock:Destroy()
					existingWater[key] = nil
					removed += 1
				else
					local level = waterBlock:GetAttribute("WaterLevel") or 0
					local newLevel = level + 1
					
					if newLevel > 7 then
						-- Past max level - destroy
						waterBlock:Destroy()
						existingWater[key] = nil
						removed += 1
					else
						-- Shrink the block
						local isFalling = waterBlock:GetAttribute("IsFalling") or false
						local bx = waterBlock:GetAttribute("BlockPosX") or 0
						local by = waterBlock:GetAttribute("BlockPosY") or 0
						local bz = waterBlock:GetAttribute("BlockPosZ") or 0
						local visual = WaterSystem.GetWaterVisualProperties(newLevel, isFalling)
						waterBlock.Size = visual.Size
						waterBlock.CFrame = CFrame.new(bx, by + visual.YOffset, bz)
						waterBlock:SetAttribute("WaterLevel", newLevel)
						stillAlive += 1
					end
				end
			end
			
			toRemoveCount = stillAlive
			if toRemoveCount > 0 and not skipDelay then
				task.wait(WAVE_DELAY)
			end
		end
		
		-- Phase 3: Create new water in waves (gradual spreading)
		local created = 0
		
		-- Get sorted wave levels (0, 1, 2, 3, ... 7)
		local sortedLevels = {}
		for level, _ in pairs(waves) do
			table.insert(sortedLevels, level)
		end
		table.sort(sortedLevels)
		
		for _, waveDist in ipairs(sortedLevels) do
			local waveEntries = waves[waveDist]
			
			-- Create all blocks in this wave
			for _, entry in ipairs(waveEntries) do
				createWaterBlock(
					entry.flowData.position,
					entry.flowData.level,
					entry.flowData.isFalling,
					blocksFolder,
					0 -- System-generated
				)
				created += 1
			end
			
			-- Wait between waves (skip delay for source/distance-0 blocks,
			-- and skip all delays if another update is queued)
			if waveDist > 0 and not flowUpdateQueued[buildArea] then
				task.wait(WAVE_DELAY)
			end
		end
		
		BulkOperationFlags.EndBulkOperation(buildArea)
		
		if DEBUG_WATER or (created + updated + removed) > 0 then
			print(string.format("[Water] Flow update: created=%d updated=%d removed=%d total=%d",
				created, updated, removed, created + updated + removed))
		end
		
		flowUpdateDebounce[buildArea] = nil
		
		-- If another update was queued during this one, run it
		if flowUpdateQueued[buildArea] then
			flowUpdateQueued[buildArea] = nil
			updateFlow(buildArea)
		end
	end)
end

-- ============================================
-- PUBLIC: Trigger flow update near a position
-- Called by BlockHandler when blocks are placed/removed near water
-- ============================================

-- Check if there's any water nearby (within a few blocks) that might need updating
local function hasWaterNearby(position, blocksFolder, spatialIndex, radius)
	radius = radius or 2
	
	for dx = -radius, radius do
		for dy = -radius, radius do
			for dz = -radius, radius do
				local checkPos = position + Vector3.new(dx * BLOCK_SIZE, dy * BLOCK_SIZE, dz * BLOCK_SIZE)
				local blocks = spatialIndex:GetBlocksAt(checkPos)
				for _, block in ipairs(blocks) do
					if block:GetAttribute("IsWater") then
						return true
					end
				end
			end
		end
	end
	return false
end

-- Expose for BlockHandler to call when blocks change
_G.WaterHandler = {}

function _G.WaterHandler.OnBlockChanged(position, buildArea)
	if not buildArea then
		buildArea = getBuildAreaAtPosition(position)
	end
	if not buildArea then return end
	
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder then return end
	
	-- Only recalculate if there's water nearby
	local spatialIndex = BlockSpatialIndex.GetOrCreate(blocksFolder)
	if hasWaterNearby(position, blocksFolder, spatialIndex, 8) then
		updateFlow(buildArea)
	end
end

function _G.WaterHandler.ForceUpdate(buildArea)
	updateFlow(buildArea)
end

-- ============================================
-- PLACE WATER SOURCE (Water Bucket)
-- ============================================

PlaceWater.OnServerEvent:Connect(function(player, data)
	if type(data) ~= "table" then return end
	if not data.Position then return end
	
	local position = data.Position
	if typeof(position) ~= "Vector3" then return end
	local convertFlowing = data.ConvertFlowing == true
	
	-- Permission check (need buildArea first for grid snapping)
	local canBuild, buildArea = canPlayerBuildAtPosition(player, position)
	
	-- Snap to terrain grid (must happen after we know the buildArea)
	position = WaterSystem.SnapToGrid(position, buildArea)
	
	print(string.format("[Water] PlaceWater from %s at (%.1f, %.1f, %.1f) convert=%s", player.Name, position.X, position.Y, position.Z, tostring(convertFlowing)))
	if not canBuild or not buildArea then
		if BuildRejected then
			BuildRejected:FireClient(player, "place", position)
		end
		return
	end
	
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder then
		blocksFolder = Instance.new("Folder")
		blocksFolder.Name = "Blocks"
		blocksFolder.Parent = buildArea
	end
	
	-- Check if position is already occupied by a solid block
	local spatialIndex = BlockSpatialIndex.GetOrCreate(blocksFolder)
	local blocksAtPos = spatialIndex:GetBlocksAt(position)
	for _, block in ipairs(blocksAtPos) do
		local blockType = block:GetAttribute("BlockType")
		if blockType and not WaterSystem.IsWater(blockType) and not block:GetAttribute("IsDecoration") then
			print("[Water] BLOCKED - solid block at position")
			return
		end
	end
	
	-- Check for existing water at this position
	local existingWater = nil
	local existingLevel = nil
	for _, block in ipairs(blocksAtPos) do
		if block:GetAttribute("IsWater") then
			existingWater = block
			existingLevel = block:GetAttribute("WaterLevel") or 0
			break
		end
	end
	
	if existingWater then
		if existingLevel == WaterSystem.SOURCE_LEVEL then
			-- Already a source block here, can't place another
			print("[Water] BLOCKED - source water already at position")
			return
		end
		
		if convertFlowing and existingLevel > 0 then
			-- Convert flowing water to source block:
			-- Destroy the flowing water and create a source in its place
			existingWater:Destroy()
			createWaterBlock(position, WaterSystem.SOURCE_LEVEL, false, blocksFolder, player.UserId)
			print(string.format("[Water] Converted flowing (level %d) to source at (%.1f, %.1f, %.1f) by %s", existingLevel, position.X, position.Y, position.Z, player.Name))
			updateFlow(buildArea)
			return
		end
		
		-- Water bucket used on water but not converting - reject
		print("[Water] BLOCKED - water already at position")
		return
	end
	
	-- No water here - create a new source block
	createWaterBlock(position, WaterSystem.SOURCE_LEVEL, false, blocksFolder, player.UserId)
	
	print(string.format("[Water] Source placed at (%.1f, %.1f, %.1f) by %s", position.X, position.Y, position.Z, player.Name))
	
	-- Trigger flow recalculation
	updateFlow(buildArea)
end)

-- ============================================
-- PICKUP WATER SOURCE (Empty Bucket)
-- ============================================

PickupWater.OnServerEvent:Connect(function(player, data)
	if type(data) ~= "table" then return end
	if not data.Position then return end
	
	local position = data.Position
	if typeof(position) ~= "Vector3" then return end
	
	-- Permission check first (need buildArea for grid snapping)
	local canBuild, buildArea = canPlayerBuildAtPosition(player, position)
	if not canBuild or not buildArea then return end
	
	position = WaterSystem.SnapToGrid(position, buildArea)
	
	print(string.format("[Water] PickupWater from %s at (%.1f, %.1f, %.1f)", player.Name, position.X, position.Y, position.Z))
	
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder then return end
	
	-- Find water source at position
	local spatialIndex = BlockSpatialIndex.GetOrCreate(blocksFolder)
	local blocksAtPos = spatialIndex:GetBlocksAt(position)
	local sourceFound = false
	
	for _, block in ipairs(blocksAtPos) do
		if block:GetAttribute("IsWater") and block:GetAttribute("WaterLevel") == WaterSystem.SOURCE_LEVEL then
			block:Destroy()
			sourceFound = true
			print(string.format("[Water] Source picked up at (%.1f, %.1f, %.1f) by %s", position.X, position.Y, position.Z, player.Name))
			break
		end
	end
	
	if sourceFound then
		-- Trigger flow recalculation (water should recede)
		updateFlow(buildArea)
		
		-- TODO: Give player a Water Bucket item (swap Empty Bucket -> Water Bucket in inventory)
		-- For now just remove the source
	else
		print("[Water] No water source found at position to pick up")
	end
end)

-- ============================================
-- MONITOR BLOCK CHANGES FOR FLOW UPDATES
-- Listen for block additions/removals near water
-- ============================================

-- Watch each build area's Blocks folder for changes
local function watchBuildArea(buildArea)
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder then
		-- Wait for it to be created
		buildArea.ChildAdded:Connect(function(child)
			if child.Name == "Blocks" and child:IsA("Folder") then
				watchBuildArea(buildArea)
			end
		end)
		return
	end
	
	-- When a non-water block is added or removed, check if water flow needs updating
	blocksFolder.ChildAdded:Connect(function(block)
		if BulkOperationFlags.IsShuttingDown() then return end
		-- Skip during bulk operations
		if BulkOperationFlags.IsBulkOperation(buildArea) then return end
		
		-- Skip water blocks (we manage those ourselves)
		if block:GetAttribute("IsWater") then return end
		if block:GetAttribute("IsDecoration") then return end
		
		-- Check if this block was placed near water
		local pos
		local bx = block:GetAttribute("BlockPosX")
		local by = block:GetAttribute("BlockPosY")
		local bz = block:GetAttribute("BlockPosZ")
		if bx and by and bz then
			pos = Vector3.new(bx, by, bz)
		elseif block:IsA("BasePart") then
			pos = WaterSystem.SnapToGrid(block.Position)
		elseif block:IsA("Model") then
			pos = WaterSystem.SnapToGrid(block:GetPivot().Position)
		end
		
		if pos then
			local spatialIndex = BlockSpatialIndex.GetOrCreate(blocksFolder)
			if hasWaterNearby(pos, blocksFolder, spatialIndex, 8) then
				task.defer(function()
					updateFlow(buildArea)
				end)
			end
		end
	end)
	
	blocksFolder.ChildRemoved:Connect(function(block)
		if BulkOperationFlags.IsShuttingDown() then return end
		-- Skip during bulk operations
		if BulkOperationFlags.IsBulkOperation(buildArea) then return end
		
		-- If a water source was removed externally (e.g., by admin), recalculate
		if block:GetAttribute("IsWater") and block:GetAttribute("WaterLevel") == WaterSystem.SOURCE_LEVEL then
			task.defer(function()
				updateFlow(buildArea)
			end)
			return
		end
		
		-- Skip water flow blocks being removed (we manage those)
		if block:GetAttribute("IsWater") then return end
		if block:GetAttribute("IsDecoration") then return end
		
		-- A solid block was removed - water might flow into the gap
		local pos
		local bx = block:GetAttribute("BlockPosX")
		local by = block:GetAttribute("BlockPosY")
		local bz = block:GetAttribute("BlockPosZ")
		if bx and by and bz then
			pos = Vector3.new(bx, by, bz)
		end
		
		-- For removed blocks, we might not have position - try to estimate
		-- The ChildRemoved fires after the block is removed, so spatial index won't have it
		-- Use the stored attributes if available
		if pos then
			-- Check if there was water nearby before the block was removed
			local spatialIndex = BlockSpatialIndex.GetOrCreate(blocksFolder)
			if hasWaterNearby(pos, blocksFolder, spatialIndex, 8) then
				task.defer(function()
					updateFlow(buildArea)
				end)
			end
		end
	end)
	
	if DEBUG_WATER then
		print(string.format("[Water] Watching %s for block changes", buildArea.Name))
	end
end

-- Watch all existing and future build areas
for i = 1, GridConfig.TOTAL_PLOTS do
	local buildArea = workspace:FindFirstChild(GridConfig.BUILD_AREA_PREFIX .. i)
	if buildArea then
		watchBuildArea(buildArea)
	end
end

-- Watch for MegaPlot
task.spawn(function()
	local megaPlotRoom = workspace:FindFirstChild("MegaPlotRoom")
	if megaPlotRoom then
		local megaPlotBuildArea = megaPlotRoom:FindFirstChild("MegaPlotBuildArea")
		if megaPlotBuildArea then
			watchBuildArea(megaPlotBuildArea)
		end
	end
end)

-- Watch for new build areas being created
workspace.ChildAdded:Connect(function(child)
	if child.Name:match("^" .. GridConfig.BUILD_AREA_PREFIX .. "%d+$") then
		watchBuildArea(child)
	end
end)

print("[WaterHandler] Initialized - Minecraft-style water flow system ready!")
