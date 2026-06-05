--[[
	LavaHandler
	Server-side lava flow management for BuildBlox.
	
	Mirrors WaterHandler — see WaterHandler.server.luau for architectural notes.
	Key differences:
		- Drives LavaSystem instead of WaterSystem
		- Slower wave delay (LAVA_WAVE_DELAY) so flow visually creeps
		- No infinite-source rule (handled inside LavaSystem)
		- No water/lava interaction yet (deferred)
		- Source blocks get a PointLight for ambient glow
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")

local LavaSystem = require(ReplicatedStorage:WaitForChild("LavaSystem", 10))
local BlockSpatialIndex = require(ReplicatedStorage:WaitForChild("BlockSpatialIndex", 10))
local BulkOperationFlags = require(ReplicatedStorage:WaitForChild("BulkOperationFlags", 10))
local GridConfig = require(ReplicatedStorage:WaitForChild("Config", 10):WaitForChild("GridConfig", 10))

-- TerrainGenerator wiring: tell LavaSystem how to ask "is this terrain cell
-- dug?" so isSolid() correctly treats excavations as passable. Without this,
-- digging under lava wouldn't cause it to pour into the hole, because
-- LavaSystem's terrain-surface check would still think the original dirt is
-- there. Lazy require since TerrainGenerator is in ServerScriptService.
task.spawn(function()
	local modulesFolder = ServerScriptService:WaitForChild("Modules", 10)
	if not modulesFolder then return end
	local tgModule = modulesFolder:WaitForChild("TerrainGenerator", 10)
	if not tgModule then return end
	local TerrainGenerator = require(tgModule)
	local function plotNumberLookup(buildArea)
		if not buildArea then return nil end
		local name = buildArea.Name
		local n = tonumber(name:match(GridConfig.BUILD_AREA_PREFIX .. "(%d+)$"))
		return n
	end
	LavaSystem.SetTerrainHooks(TerrainGenerator, plotNumberLookup)
	print("[LavaHandler] Wired TerrainGenerator hooks (dug-position awareness)")
end)

local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)

local PlaceLava = Remotes:FindFirstChild("PlaceLava")
if not PlaceLava then
	PlaceLava = Instance.new("RemoteEvent")
	PlaceLava.Name = "PlaceLava"
	PlaceLava.Parent = Remotes
end

local PickupLava = Remotes:FindFirstChild("PickupLava")
if not PickupLava then
	PickupLava = Instance.new("RemoteEvent")
	PickupLava.Name = "PickupLava"
	PickupLava.Parent = Remotes
end

local LavaFlowUpdate = Remotes:FindFirstChild("LavaFlowUpdate")
if not LavaFlowUpdate then
	LavaFlowUpdate = Instance.new("RemoteEvent")
	LavaFlowUpdate.Name = "LavaFlowUpdate"
	LavaFlowUpdate.Parent = Remotes
end

local BuildRejected = Remotes:WaitForChild("BuildRejected", 5)

local BLOCK_SIZE = GridConfig.BLOCK_SIZE
local DEBUG_LAVA = false
local DEBUG_LAVA_FLOW = false  -- toggle for terrain-dig flow propagation logs
LavaSystem.SetDebugFlow(DEBUG_LAVA_FLOW)

-- Forward declaration so PlaceLava.OnServerEvent (defined earlier in the file)
-- can call watchBuildArea() in its self-heal path. Real definition lives in
-- the MONITOR BLOCK CHANGES section near the bottom.
local watchBuildArea

-- ============================================
-- PERMISSION CHECK
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
-- LAVA BLOCK CREATION
-- ============================================

local function createLavaBlock(position, level, isFalling, blocksFolder, placedBy)
	local visual = LavaSystem.GetLavaVisualProperties(level, isFalling)
	
	local lavaPart = Instance.new("Part")
	lavaPart.Name = "Lava"
	lavaPart.Anchored = true
	lavaPart.CanCollide = false
	lavaPart.CanQuery = true
	lavaPart.CastShadow = false
	lavaPart.Size = visual.Size
	lavaPart.Color = visual.Color
	lavaPart.Transparency = visual.Transparency
	lavaPart.Material = visual.Material
	lavaPart.TopSurface = Enum.SurfaceType.Smooth
	lavaPart.BottomSurface = Enum.SurfaceType.Smooth
	
	lavaPart.CFrame = CFrame.new(position.X, position.Y + visual.YOffset, position.Z)
	
	lavaPart:SetAttribute("BlockType", "Lava")
	lavaPart:SetAttribute("LavaLevel", level)
	lavaPart:SetAttribute("IsLava", true)
	lavaPart:SetAttribute("IsFalling", isFalling)
	lavaPart:SetAttribute("PlacedBy", placedBy or 0)
	
	lavaPart:SetAttribute("BlockPosX", position.X)
	lavaPart:SetAttribute("BlockPosY", position.Y)
	lavaPart:SetAttribute("BlockPosZ", position.Z)
	
	-- Ambient glow: only sources get a real PointLight (perf). Flowing lava
	-- relies on Neon material brightness alone.
	if level == LavaSystem.SOURCE_LEVEL then
		local light = Instance.new("PointLight")
		light.Brightness = 1.5
		light.Range = 12
		light.Color = Color3.fromRGB(255, 140, 60)
		light.Shadows = false
		light.Parent = lavaPart
	end
	
	lavaPart.Parent = blocksFolder
	
	if DEBUG_LAVA then
		print(string.format("[Lava] Created level=%d falling=%s at (%.1f, %.1f, %.1f)",
			level, tostring(isFalling), position.X, position.Y, position.Z))
	end
	
	return lavaPart
end

-- ============================================
-- FLOW UPDATE
-- ============================================

local flowUpdateDebounce = {}
local flowUpdateQueued = {}

-- Minecraft lava ticks every ~30 game ticks (1.5s in the Nether, slower in
-- the overworld). 1.5s per wave matches Nether feel — every block of spread
-- visibly takes a moment, so a 4-block flow takes ~6s end-to-end.
local LAVA_WAVE_DELAY = 1.5

local function updateFlow(buildArea)
	if not buildArea then return end
	
	if flowUpdateDebounce[buildArea] then
		flowUpdateQueued[buildArea] = true
		if DEBUG_LAVA_FLOW then
			print(string.format("[BB-LAVA] updateFlow: %s already running -> queued", buildArea.Name))
		end
		return
	end
	
	if DEBUG_LAVA_FLOW then
		print(string.format("[BB-LAVA] updateFlow: starting for %s", buildArea.Name))
	end
	flowUpdateDebounce[buildArea] = true
	
	task.defer(function()
		local blocksFolder = buildArea:FindFirstChild("Blocks")
		if not blocksFolder then
			flowUpdateDebounce[buildArea] = nil
			return
		end
		
		local spatialIndex = BlockSpatialIndex.GetOrCreate(blocksFolder)
		
		BulkOperationFlags.StartBulkOperation(buildArea, "LavaFlow")
		
		local flowMap = LavaSystem.CalculateFlow(blocksFolder, buildArea, spatialIndex)
		
		local existingLava = {}
		
		for _, block in ipairs(blocksFolder:GetChildren()) do
			if block:GetAttribute("IsLava") then
				local bx = block:GetAttribute("BlockPosX")
				local by = block:GetAttribute("BlockPosY")
				local bz = block:GetAttribute("BlockPosZ")
				if bx and by and bz then
					local pos = Vector3.new(bx, by, bz)
					local key = LavaSystem.PosKey(pos)
					existingLava[key] = block
				end
			end
		end
		
		local waves = {}
		local toUpdate = {}
		
		for key, flowData in pairs(flowMap) do
			local existing = existingLava[key]
			
			if existing then
				local currentLevel = existing:GetAttribute("LavaLevel") or 0
				local currentFalling = existing:GetAttribute("IsFalling") or false
				
				if currentLevel ~= flowData.level or currentFalling ~= flowData.isFalling then
					table.insert(toUpdate, { existing = existing, flowData = flowData })
				end
				
				existingLava[key] = nil
			else
				local waveDist = flowData.distance or 0
				
				if not waves[waveDist] then
					waves[waveDist] = {}
				end
				table.insert(waves[waveDist], { key = key, flowData = flowData })
			end
		end
		
		-- Phase 1: Update existing blocks that changed level
		local updated = 0
		for _, entry in ipairs(toUpdate) do
			local visual = LavaSystem.GetLavaVisualProperties(entry.flowData.level, entry.flowData.isFalling)
			entry.existing.Size = visual.Size
			entry.existing.CFrame = CFrame.new(
				entry.flowData.position.X,
				entry.flowData.position.Y + visual.YOffset,
				entry.flowData.position.Z
			)
			entry.existing:SetAttribute("LavaLevel", entry.flowData.level)
			entry.existing:SetAttribute("IsFalling", entry.flowData.isFalling)
			updated += 1
		end
		
		-- Phase 2: Drain lava that shouldn't exist anymore (shrink-out animation)
		local removed = 0
		local toRemoveCount = 0
		for _ in pairs(existingLava) do
			toRemoveCount += 1
		end
		
		while toRemoveCount > 0 do
			local skipDelay = flowUpdateQueued[buildArea]
			
			local stillAlive = 0
			for key, lavaBlock in pairs(existingLava) do
				if not lavaBlock.Parent then
					existingLava[key] = nil
					continue
				end
				
				if skipDelay then
					lavaBlock:Destroy()
					existingLava[key] = nil
					removed += 1
				else
					local level = lavaBlock:GetAttribute("LavaLevel") or 0
					local newLevel = level + 1
					
					if newLevel > LavaSystem.MAX_LEVEL then
						lavaBlock:Destroy()
						existingLava[key] = nil
						removed += 1
					else
						local isFalling = lavaBlock:GetAttribute("IsFalling") or false
						local bx = lavaBlock:GetAttribute("BlockPosX") or 0
						local by = lavaBlock:GetAttribute("BlockPosY") or 0
						local bz = lavaBlock:GetAttribute("BlockPosZ") or 0
						local visual = LavaSystem.GetLavaVisualProperties(newLevel, isFalling)
						lavaBlock.Size = visual.Size
						lavaBlock.CFrame = CFrame.new(bx, by + visual.YOffset, bz)
						lavaBlock:SetAttribute("LavaLevel", newLevel)
						stillAlive += 1
					end
				end
			end
			
			toRemoveCount = stillAlive
			if toRemoveCount > 0 and not skipDelay then
				task.wait(LAVA_WAVE_DELAY)
			end
		end
		
		-- Phase 3: Create new lava in waves
		local created = 0
		
		local sortedLevels = {}
		for level, _ in pairs(waves) do
			table.insert(sortedLevels, level)
		end
		table.sort(sortedLevels)
		
		for _, waveDist in ipairs(sortedLevels) do
			local waveEntries = waves[waveDist]
			
			for _, entry in ipairs(waveEntries) do
				createLavaBlock(
					entry.flowData.position,
					entry.flowData.level,
					entry.flowData.isFalling,
					blocksFolder,
					0
				)
				created += 1
			end
			
			if waveDist > 0 and not flowUpdateQueued[buildArea] then
				task.wait(LAVA_WAVE_DELAY)
			end
		end
		
		BulkOperationFlags.EndBulkOperation(buildArea)
		
		if DEBUG_LAVA or (created + updated + removed) > 0 then
			print(string.format("[Lava] Flow update: created=%d updated=%d removed=%d total=%d",
				created, updated, removed, created + updated + removed))
		end
		
		flowUpdateDebounce[buildArea] = nil
		
		if flowUpdateQueued[buildArea] then
			flowUpdateQueued[buildArea] = nil
			updateFlow(buildArea)
		end
	end)
end

-- ============================================
-- PUBLIC: Trigger flow update near a position
-- ============================================

local function hasLavaNearby(position, blocksFolder, spatialIndex, radius)
	radius = radius or 2
	
	for dx = -radius, radius do
		for dy = -radius, radius do
			for dz = -radius, radius do
				local checkPos = position + Vector3.new(dx * BLOCK_SIZE, dy * BLOCK_SIZE, dz * BLOCK_SIZE)
				local blocks = spatialIndex:GetBlocksAt(checkPos)
				for _, block in ipairs(blocks) do
					if block:GetAttribute("IsLava") then
						return true
					end
				end
			end
		end
	end
	return false
end

_G.LavaHandler = {}

function _G.LavaHandler.OnBlockChanged(position, buildArea)
	if not buildArea then
		buildArea = getBuildAreaAtPosition(position)
	end
	if not buildArea then return end
	
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder then return end
	
	local spatialIndex = BlockSpatialIndex.GetOrCreate(blocksFolder)
	if hasLavaNearby(position, blocksFolder, spatialIndex, 8) then
		updateFlow(buildArea)
	end
end

function _G.LavaHandler.ForceUpdate(buildArea)
	updateFlow(buildArea)
end

-- ============================================
-- PLACE LAVA SOURCE
-- ============================================

PlaceLava.OnServerEvent:Connect(function(player, data)
	if type(data) ~= "table" then return end
	if not data.Position then return end
	
	local position = data.Position
	if typeof(position) ~= "Vector3" then return end
	local convertFlowing = data.ConvertFlowing == true
	
	local canBuild, buildArea = canPlayerBuildAtPosition(player, position)
	
	position = LavaSystem.SnapToGrid(position, buildArea)
	
	print(string.format("[Lava] PlaceLava from %s at (%.1f, %.1f, %.1f) convert=%s", player.Name, position.X, position.Y, position.Z, tostring(convertFlowing)))
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
	
	local spatialIndex = BlockSpatialIndex.GetOrCreate(blocksFolder)
	local blocksAtPos = spatialIndex:GetBlocksAt(position)
	for _, block in ipairs(blocksAtPos) do
		local blockType = block:GetAttribute("BlockType")
		if blockType
			and not LavaSystem.IsLava(blockType)
			and blockType ~= "Water"
			and blockType ~= "WaterSource"
			and blockType ~= "WaterFlowing"
			and not block:GetAttribute("IsWater")
			and not block:GetAttribute("IsDecoration") then
			print("[Lava] BLOCKED - solid block at position")
			return
		end
	end
	
	local existingLava = nil
	local existingLevel = nil
	for _, block in ipairs(blocksAtPos) do
		if block:GetAttribute("IsLava") then
			existingLava = block
			existingLevel = block:GetAttribute("LavaLevel") or 0
			break
		end
	end
	
	if existingLava then
		if existingLevel == LavaSystem.SOURCE_LEVEL then
			print("[Lava] BLOCKED - source lava already at position")
			return
		end
		
		if convertFlowing and existingLevel > 0 then
			existingLava:Destroy()
			createLavaBlock(position, LavaSystem.SOURCE_LEVEL, false, blocksFolder, player.UserId)
			print(string.format("[Lava] Converted flowing (level %d) to source at (%.1f, %.1f, %.1f) by %s", existingLevel, position.X, position.Y, position.Z, player.Name))
			updateFlow(buildArea)
			return
		end
		
		print("[Lava] BLOCKED - lava already at position")
		return
	end
	
	createLavaBlock(position, LavaSystem.SOURCE_LEVEL, false, blocksFolder, player.UserId)
	
	print(string.format("[Lava] Source placed at (%.1f, %.1f, %.1f) by %s", position.X, position.Y, position.Z, player.Name))
	
	-- Self-heal: make sure this build area is being watched for dig events.
	-- If it was created after script init (terrain generated on-demand when
	-- the player claimed the plot) the initial loop missed it.
	watchBuildArea(buildArea)
	
	updateFlow(buildArea)
end)

-- ============================================
-- PICKUP LAVA SOURCE
-- ============================================

PickupLava.OnServerEvent:Connect(function(player, data)
	if type(data) ~= "table" then return end
	if not data.Position then return end
	
	local position = data.Position
	if typeof(position) ~= "Vector3" then return end
	
	local canBuild, buildArea = canPlayerBuildAtPosition(player, position)
	if not canBuild or not buildArea then return end
	
	position = LavaSystem.SnapToGrid(position, buildArea)
	
	print(string.format("[Lava] PickupLava from %s at (%.1f, %.1f, %.1f)", player.Name, position.X, position.Y, position.Z))
	
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder then return end
	
	local spatialIndex = BlockSpatialIndex.GetOrCreate(blocksFolder)
	local blocksAtPos = spatialIndex:GetBlocksAt(position)
	local sourceFound = false
	
	for _, block in ipairs(blocksAtPos) do
		if block:GetAttribute("IsLava") and block:GetAttribute("LavaLevel") == LavaSystem.SOURCE_LEVEL then
			block:Destroy()
			sourceFound = true
			print(string.format("[Lava] Source picked up at (%.1f, %.1f, %.1f) by %s", position.X, position.Y, position.Z, player.Name))
			break
		end
	end
	
	if sourceFound then
		updateFlow(buildArea)
		-- TODO: Give player a Lava Bucket item (swap Empty Bucket -> Lava Bucket in inventory)
	else
		print("[Lava] No lava source found at position to pick up")
	end
end)

-- ============================================
-- MONITOR BLOCK CHANGES FOR FLOW UPDATES
-- ============================================

local watchedAreas = {}

watchBuildArea = function(buildArea)
	if watchedAreas[buildArea] then
		if DEBUG_LAVA_FLOW then
			print(string.format("[BB-LAVA] watchBuildArea: %s already watched", buildArea.Name))
		end
		return
	end
	watchedAreas[buildArea] = true
	
	if DEBUG_LAVA_FLOW then
		print(string.format("[BB-LAVA] watchBuildArea: installing watcher on %s", buildArea.Name))
		-- Diagnostic: list all child folders so we can see whether terrain
		-- actually lives in Blocks/ or in some sibling folder we're not watching.
		local childNames = {}
		for _, child in ipairs(buildArea:GetChildren()) do
			local n = #child:GetChildren()
			table.insert(childNames, string.format("%s(%s, %d children)", child.Name, child.ClassName, n))
		end
		print(string.format("[BB-LAVA]   %s contains: %s", buildArea.Name, table.concat(childNames, ", ")))
	end
	
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder then
		if DEBUG_LAVA_FLOW then
			print(string.format("[BB-LAVA] watchBuildArea: %s has no Blocks folder yet, waiting...", buildArea.Name))
		end
		buildArea.ChildAdded:Connect(function(child)
			if child.Name == "Blocks" and child:IsA("Folder") then
				watchedAreas[buildArea] = nil -- allow re-install with the folder
				watchBuildArea(buildArea)
			end
		end)
		return
	end
	
	-- Coalesced "something changed near lava" signal. The actual hasLavaNearby
	-- check is deferred and runs ONCE per build area per frame, not per event.
	-- This is the difference between a 30-block dig cascade running
	-- hasLavaNearby 30 times (each doing a 17³17³17=4913 cell scan = 150k
	-- lookups) and running it ONCE.
	local pendingFlowCheck = false
	local function queueFlowCheck()
		if pendingFlowCheck then return end
		pendingFlowCheck = true
		task.defer(function()
			pendingFlowCheck = false
			-- Only run a flow update if there's actually lava in this build area
			-- (avoids walking the full flow algo on plots with no lava).
			local hasAnyLava = false
			for _, child in ipairs(blocksFolder:GetChildren()) do
				if child:GetAttribute("IsLava") then
					hasAnyLava = true
					break
				end
			end
			if hasAnyLava then
				updateFlow(buildArea)
			end
		end)
	end
	
	blocksFolder.ChildAdded:Connect(function(block)
		if BulkOperationFlags.GetOperationType(buildArea) == "LavaFlow" then return end
		if block:GetAttribute("IsLava") then return end
		if block:GetAttribute("IsDecoration") then return end
		queueFlowCheck()
	end)
	
	blocksFolder.ChildRemoved:Connect(function(block)
		if DEBUG_LAVA_FLOW then
			print(string.format("[BB-LAVA-WATCH] ChildRemoved fired on %s for %s",
				blocksFolder:GetFullName(), tostring(block.Name)))
		end
		if BulkOperationFlags.GetOperationType(buildArea) == "LavaFlow" then return end
		
		-- Skip ALL lava-on-lava removals. Source-pickup is handled directly
		-- by PickupLava.OnServerEvent calling updateFlow(buildArea). Flowing
		-- lava being destroyed during a drain wave is suppressed by the
		-- LavaFlow bulk-op flag above. Re-queueing here would cause a second
		-- updateFlow to schedule mid-drain, which sets flowUpdateQueued=true,
		-- and the drain loop then sees skipDelay=true and destroys EVERYTHING
		-- in one frame instead of in waves.
		if block:GetAttribute("IsLava") then return end
		if block:GetAttribute("IsDecoration") then return end
		
		queueFlowCheck()
	end)
	
	-- Watch for the Blocks folder itself getting destroyed/recreated, which
	-- could orphan our watchers. If that happens, re-install.
	blocksFolder.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			if DEBUG_LAVA_FLOW then
				print(string.format("[BB-LAVA] Blocks folder for %s was DESTROYED/UNPARENTED -- re-installing watcher", buildArea.Name))
			end
			watchedAreas[buildArea] = nil
			task.defer(function()
				watchBuildArea(buildArea)
			end)
		end
	end)
	
	if DEBUG_LAVA then
		print(string.format("[Lava] Watching %s for block changes", buildArea.Name))
	end
end

for i = 1, GridConfig.TOTAL_PLOTS do
	local buildArea = workspace:FindFirstChild(GridConfig.BUILD_AREA_PREFIX .. i)
	if buildArea then
		watchBuildArea(buildArea)
	end
end

task.spawn(function()
	local megaPlotRoom = workspace:FindFirstChild("MegaPlotRoom")
	if megaPlotRoom then
		local megaPlotBuildArea = megaPlotRoom:FindFirstChild("MegaPlotBuildArea")
		if megaPlotBuildArea then
			watchBuildArea(megaPlotBuildArea)
		end
	end
end)

workspace.ChildAdded:Connect(function(child)
	if child.Name:match("^" .. GridConfig.BUILD_AREA_PREFIX .. "%d+$") then
		watchBuildArea(child)
	end
end)

-- ============================================
-- LAVA -> FIRE IGNITION TICK
-- ============================================
-- Periodically scans every lava block and tries to ignite flammable neighbors.
-- Mirrors Minecraft: lava ignites flammable blocks within a small radius. We
-- check each of the 6 axis-neighbors of every lava cell; if the neighbor block
-- is flammable (per FireHandler's IsFlammable rules), a probabilistic ignite
-- roll places a Fire on the face nearest the lava. FireHandler then owns the
-- usual spread/char/cool/collapse for that fire.
--
-- We DEFER to _G.FireHandler.IgniteBlock so we don't duplicate FireHandler's
-- flammability lists, fire-cell occupancy checks, or model placement logic.
-- If FireHandler isn't loaded yet (rare race at server boot), this tick simply
-- no-ops until it appears.

local LAVA_IGNITE_TICK_INTERVAL = 2.0    -- how often to check (seconds)
local LAVA_IGNITE_CHANCE = 0.30           -- per-neighbor per-tick ignition roll (0-1)
local LAVA_IGNITE_MAX_PER_TICK = 6        -- cap new fires per plot per tick (perf + pacing)
local DEBUG_LAVA_IGNITE = false

-- Neighbor offsets to check around each lava block. For each direction we'd
-- LIKE to ignite on the face of the neighbor pointing back toward the lava
-- (so the flame visually appears on the lava-facing side), but for SIDE faces
-- that fire cell IS the lava's own cell — fire can't be placed inside lava.
-- So we always try the neighbor's TOP face FIRST (cell above the wood is
-- normally empty, matches Minecraft "fire on top, smoke rising" visual), then
-- fall back to the back-facing face. The back-facing face works for the
-- vertical cases (lava above the wood = neighbor's Bottom face, fire hangs
-- under; lava below the wood = neighbor's Top face, already covered by primary).
local IGNITE_OFFSETS = {
	{ offset = Vector3.new( BLOCK_SIZE, 0, 0), fallbackFace = "NegX"   },
	{ offset = Vector3.new(-BLOCK_SIZE, 0, 0), fallbackFace = "PosX"   },
	{ offset = Vector3.new( 0, 0,  BLOCK_SIZE), fallbackFace = "NegZ"  },
	{ offset = Vector3.new( 0, 0, -BLOCK_SIZE), fallbackFace = "PosZ"  },
	{ offset = Vector3.new( 0,  BLOCK_SIZE, 0), fallbackFace = "Bottom"}, -- lava above; try wood's bottom face
	{ offset = Vector3.new( 0, -BLOCK_SIZE, 0), fallbackFace = "Top"   }, -- lava below; primary already covers
}

local function processLavaIgnitions(buildArea)
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder then return end
	
	-- Skip if a flow update is currently running on this plot (avoid racing
	-- with lava placements/drains).
	if BulkOperationFlags.GetOperationType(buildArea) == "LavaFlow" then
		if DEBUG_LAVA_IGNITE then
			print(string.format("[BB-LAVA-FIRE] skip %s: LavaFlow bulk op in progress", buildArea.Name))
		end
		return
	end
	
	-- Don't bother if FireHandler hasn't published its API yet.
	if not _G.FireHandler or not _G.FireHandler.IgniteBlock then
		if DEBUG_LAVA_IGNITE then
			print(string.format("[BB-LAVA-FIRE] skip %s: _G.FireHandler not loaded yet (FireHandler=%s IgniteBlock=%s)",
				buildArea.Name, tostring(_G.FireHandler ~= nil),
				tostring(_G.FireHandler and _G.FireHandler.IgniteBlock ~= nil)))
		end
		return
	end
	
	local spatialIndex = BlockSpatialIndex.GetOrCreate(blocksFolder)
	if not spatialIndex then return end
	
	-- Snapshot lava blocks so we don't iterate a folder that may be mutated by
	-- IgniteBlock's side effects (fire ChildAdded events).
	local lavaBlocks = {}
	for _, child in ipairs(blocksFolder:GetChildren()) do
		if child:GetAttribute("IsLava") then
			table.insert(lavaBlocks, child)
		end
	end
	if #lavaBlocks == 0 then return end
	
	if DEBUG_LAVA_IGNITE then
		print(string.format("[BB-LAVA-FIRE] tick on %s: %d lava blocks", buildArea.Name, #lavaBlocks))
	end
	
	local ignites = 0
	local flammablesSeen = 0
	for _, lava in ipairs(lavaBlocks) do
		if ignites >= LAVA_IGNITE_MAX_PER_TICK then break end
		if not lava.Parent then continue end
		
		local lx = lava:GetAttribute("BlockPosX")
		local ly = lava:GetAttribute("BlockPosY")
		local lz = lava:GetAttribute("BlockPosZ")
		if not (lx and ly and lz) then continue end
		local lavaCenter = Vector3.new(lx, ly, lz)
		
		for _, dir in ipairs(IGNITE_OFFSETS) do
			if ignites >= LAVA_IGNITE_MAX_PER_TICK then break end
			local neighborPos = lavaCenter + dir.offset
			local blocksAt = spatialIndex:GetBlocksAt(neighborPos)
			if DEBUG_LAVA_IGNITE and #blocksAt > 0 then
				local blockDescs = {}
				for _, b in ipairs(blocksAt) do
					table.insert(blockDescs, string.format("%s(%s)",
						b.Name, tostring(b:GetAttribute("BlockType") or "?")))
				end
				print(string.format("[BB-LAVA-FIRE]   lava(%.1f,%.1f,%.1f) -> neighbor(%.1f,%.1f,%.1f) blocks: %s",
					lx, ly, lz, neighborPos.X, neighborPos.Y, neighborPos.Z,
					table.concat(blockDescs, ",")))
			end
			for _, neighbor in ipairs(blocksAt) do
				local nType = neighbor:GetAttribute("BlockType") or neighbor.Name
				local flammable = _G.FireHandler.IsFlammable(nType)
				if DEBUG_LAVA_IGNITE then
					print(string.format("[BB-LAVA-FIRE]     check %s: flammable=%s isLava=%s charred=%s",
						tostring(nType), tostring(flammable),
						tostring(neighbor:GetAttribute("IsLava")),
						tostring(neighbor:GetAttribute("FullyCharred"))))
				end
				if flammable
					and not neighbor:GetAttribute("IsLava")
					and not neighbor:GetAttribute("FullyCharred") then
					flammablesSeen += 1
					if math.random() <= LAVA_IGNITE_CHANCE then
						-- Try faces in priority order: Top first (natural Minecraft
						-- look + cell above is usually empty), then the back-facing
						-- face (which only works for vertical cases since side faces
						-- would put the fire IN the lava's cell).
						local fire = _G.FireHandler.IgniteBlock(neighbor, "Top", 0)
							or _G.FireHandler.IgniteBlock(neighbor, dir.fallbackFace, 0)
						if fire then
							ignites += 1
							if DEBUG_LAVA_IGNITE then
								local lit = fire:GetAttribute("FireFace") or "?"
								print(string.format("[BB-LAVA-FIRE] ✓ Ignited %s on face=%s at (%.1f,%.1f,%.1f)",
									tostring(nType), lit,
									neighborPos.X, neighborPos.Y, neighborPos.Z))
							end
							break -- one fire per neighbor cell per tick
						else
							if DEBUG_LAVA_IGNITE then
								print(string.format("[BB-LAVA-FIRE]     IgniteBlock returned nil for %s (Top + %s both blocked)",
									tostring(nType), dir.fallbackFace))
							end
						end
					elseif DEBUG_LAVA_IGNITE then
						print(string.format("[BB-LAVA-FIRE]     roll failed for %s", tostring(nType)))
					end
				end
			end
		end
	end
	
	if DEBUG_LAVA_IGNITE then
		print(string.format("[BB-LAVA-FIRE] %s tick done: %d flammables seen, %d ignited",
			buildArea.Name, flammablesSeen, ignites))
	end
end

local lavaIgniteLastTick = 0
RunService.Heartbeat:Connect(function()
	local now = tick()
	if now - lavaIgniteLastTick < LAVA_IGNITE_TICK_INTERVAL then return end
	lavaIgniteLastTick = now
	
	for buildArea in pairs(watchedAreas) do
		if buildArea and buildArea.Parent then
			processLavaIgnitions(buildArea)
		end
	end
end)

print("[LavaHandler] Initialized - Minecraft-style lava flow system ready!")
