--[[
	FallingBlockHandler
	Handles physics for falling blocks like Sand and Gravel
	- Blocks fall when placed with no support below
	- Blocks fall when the block beneath them is removed
	- Queue system prevents lag from mass block falls
	- Also supports Stair and Slab variants of falling blocks
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")

local GridConfig = require(ReplicatedStorage:WaitForChild("Config", 10):WaitForChild("GridConfig", 10))
local BulkOperationFlags = require(ReplicatedStorage:WaitForChild("BulkOperationFlags", 10))
local BlockSpatialIndex = require(ReplicatedStorage:WaitForChild("BlockSpatialIndex", 10))

local BLOCK_SIZE = GridConfig.BLOCK_SIZE
local FALL_SPEED = 0.12 -- Time per block fallen (seconds)
local MAX_CONCURRENT_FALLS = 10 -- Max blocks animating at once
local FALLS_PER_FRAME = 3 -- Max new falls to start per frame
local INSTANT_FALL_THRESHOLD = 50 -- If more than this queued, use instant positioning

local DEBUG = false -- Enable debug logging

-- Block types that should fall (base types)
local FALLING_BLOCK_TYPES = {
	["Sand"] = true,
	["RedSand"] = true,
	["Gravel"] = true,
}

-- ============================================
-- HELPER FUNCTIONS
-- ============================================

local function isFallingBlockType(blockType: string): boolean
	if not blockType then return false end
	
	-- Direct match
	if FALLING_BLOCK_TYPES[blockType] == true then
		return true
	end
	
	-- Check for stair/slab variants (e.g., "SandStair", "GravelSlab")
	for baseType, _ in pairs(FALLING_BLOCK_TYPES) do
		if blockType == baseType .. "Stair" or blockType == baseType .. "Slab" then
			return true
		end
	end
	
	return false
end

local function getBlockPosition(block: Instance): Vector3?
	if block:IsA("BasePart") then
		return block.Position
	elseif block:IsA("Model") then
		local primary = block.PrimaryPart or block:FindFirstChildWhichIsA("BasePart")
		if primary then
			return primary.Position
		end
	end
	return nil
end

-- Snap a position to the block grid
local function snapToGrid(position: Vector3): Vector3
	local x = math.round(position.X / BLOCK_SIZE) * BLOCK_SIZE
	local y = math.round(position.Y / BLOCK_SIZE) * BLOCK_SIZE + (BLOCK_SIZE / 2)
	local z = math.round(position.Z / BLOCK_SIZE) * BLOCK_SIZE
	return Vector3.new(x, y, z)
end

local function getBlockAt(position: Vector3, blocksFolder: Folder, excludeBlock: Instance?): Instance?
	if DEBUG then
		print(string.format("[FallingBlock] getBlockAt checking position Y=%.2f", position.Y))
	end
	
	-- Use spatial index for O(1) lookup instead of scanning all children
	if BlockSpatialIndex then
		local index = BlockSpatialIndex.GetOrCreate(blocksFolder)
		if index then
			local blocks = index:GetBlocksAt(position)
			for _, block in ipairs(blocks) do
				if block ~= excludeBlock and block:GetAttribute("BlockType") and not block:GetAttribute("IsDecoration") then
					return block
				end
			end
			return nil
		end
	end
	
	-- Fallback: scan all blocks
	for _, block in ipairs(blocksFolder:GetChildren()) do
		if block ~= excludeBlock and block:GetAttribute("BlockType") then
			if block:GetAttribute("IsDecoration") then
				continue
			end
			local blockPos = getBlockPosition(block)
			if blockPos then
				if (blockPos - position).Magnitude < BLOCK_SIZE * 0.75 then
					return block
				end
			end
		end
	end
	return nil
end

-- Check if an instance is a decoration
local function isDecoration(instance: Instance): boolean
	if instance:GetAttribute("IsDecoration") then
		return true
	end
	if instance.Parent and instance.Parent:GetAttribute("IsDecoration") then
		return true
	end
	return false
end

-- Check if there's solid support below a grid position using raycast
local function hasSolidBelow(gridPosition: Vector3, excludeBlock: Instance?): boolean
	-- Ray starts at bottom of the grid cell, goes down far to find ground
	local rayOrigin = gridPosition - Vector3.new(0, BLOCK_SIZE / 2 - 0.1, 0) -- Just above bottom of current cell
	local rayDirection = Vector3.new(0, -200, 0) -- Go down far to find ground
	
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	
	local excludeList = {}
	if excludeBlock then
		table.insert(excludeList, excludeBlock)
	end
	rayParams.FilterDescendantsInstances = excludeList
	
	local result = workspace:Raycast(rayOrigin, rayDirection, rayParams)
	
	if result and result.Instance and result.Instance.CanCollide then
		if isDecoration(result.Instance) then
			return false
		end
		-- Check if hit is within one block below (direct support)
		local distDown = rayOrigin.Y - result.Position.Y
		if distDown < BLOCK_SIZE then
			if DEBUG then
				print(string.format("[FallingBlock] hasSolidBelow at Y=%.2f: HIT %s at Y=%.2f (dist=%.2f, SUPPORTED)", 
					gridPosition.Y, result.Instance.Name, result.Position.Y, distDown))
			end
			return true
		end
		if DEBUG then
			print(string.format("[FallingBlock] hasSolidBelow at Y=%.2f: HIT %s at Y=%.2f (dist=%.2f, TOO FAR)", 
				gridPosition.Y, result.Instance.Name, result.Position.Y, distDown))
		end
		return false
	end
	
	if DEBUG then
		print(string.format("[FallingBlock] hasSolidBelow at Y=%.2f: NO HIT", gridPosition.Y))
	end
	return false
end

local function hasSupport(block: Instance, blocksFolder: Folder): boolean
	local blockPos = getBlockPosition(block)
	if not blockPos then return true end
	
	-- Snap to grid for consistent checking
	local snappedPos = snapToGrid(blockPos)
	local belowPos = snappedPos - Vector3.new(0, BLOCK_SIZE, 0)
	
	if DEBUG then
		print(string.format("[FallingBlock] hasSupport: blockY=%.2f, snappedY=%.2f, checkingBelowY=%.2f", 
			blockPos.Y, snappedPos.Y, belowPos.Y))
	end
	
	-- Check player-placed blocks first
	local blockBelow = getBlockAt(belowPos, blocksFolder, block)
	if blockBelow then
		local belowBlockPos = getBlockPosition(blockBelow)
		if DEBUG then
			print(string.format("[FallingBlock] hasSupport: Found PLAYER BLOCK below: %s at Y=%.2f", 
				blockBelow:GetAttribute("BlockType") or blockBelow.Name, 
				belowBlockPos and belowBlockPos.Y or -999))
		end
		return true
	end
	
	-- Check for solid terrain/ground below using raycast from snapped position
	local solidBelow = hasSolidBelow(snappedPos, block)
	if DEBUG then
		print(string.format("[FallingBlock] hasSupport: hasSolidBelow returned %s", tostring(solidBelow)))
	end
	return solidBelow
end

-- Find where the block should land using direct raycast
local function findLandingPosition(startPos: Vector3, blocksFolder: Folder, fallingBlock: Instance): Vector3?
	local snappedStart = snapToGrid(startPos)
	
	-- Cast ray from bottom of current position down to find ground
	local rayOrigin = snappedStart - Vector3.new(0, BLOCK_SIZE / 2 - 0.1, 0)
	local rayDirection = Vector3.new(0, -200, 0)
	
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	
	local excludeList = {fallingBlock}
	rayParams.FilterDescendantsInstances = excludeList
	
	local result = workspace:Raycast(rayOrigin, rayDirection, rayParams)
	
	if DEBUG then
		print(string.format("[FallingBlock] findLandingPosition: startY=%.2f, snappedY=%.2f, rayFrom=%.2f", 
			startPos.Y, snappedStart.Y, rayOrigin.Y))
	end
	
	if result and result.Instance and result.Instance.CanCollide then
		if isDecoration(result.Instance) then
			-- Hit a decoration, ignore it and continue (would need to raycast again, but for simplicity return nil)
			if DEBUG then
				print("[FallingBlock] Hit decoration, ignoring")
			end
			return nil
		end
		
		-- We hit something! Land on top of it
		-- The hit position is the TOP surface of what we hit
		local hitY = result.Position.Y
		
		-- Calculate the block's height to position center correctly
		local blockHeight = BLOCK_SIZE -- Default full block height
		
		-- Check if this is a horizontal slab (half height)
		local blockType = fallingBlock:GetAttribute("BlockType")
		if blockType and string.find(blockType, "Slab") then
			-- Check if it's a horizontal slab (Top or Bottom orientation)
			local orientation = fallingBlock:GetAttribute("SlabOrientation") or fallingBlock:GetAttribute("Orientation")
			if DEBUG then
				print(string.format("[FallingBlock] Slab detected, SlabOrientation=%s", tostring(orientation)))
				-- List all attributes
				for name, value in pairs(fallingBlock:GetAttributes()) do
					print(string.format("  Attr: %s = %s", name, tostring(value)))
				end
			end
			if orientation == "Top" or orientation == "Bottom" or orientation == "top" or orientation == "bottom" then
				blockHeight = BLOCK_SIZE / 2 -- Horizontal slabs are half height
				if DEBUG then
					print(string.format("[FallingBlock] Horizontal slab detected, using half height"))
				end
			end
		end
		
		-- Block center should be at hit surface + half block height
		local landingY = hitY + (blockHeight / 2)
		
		if DEBUG then
			print(string.format("[FallingBlock] Raycast hit %s at Y=%.2f, landing at Y=%.2f", 
				result.Instance.Name, hitY, landingY))
		end
		
		return Vector3.new(startPos.X, landingY, startPos.Z)
	end
	
	if DEBUG then
		print("[FallingBlock] No ground found, falling to void")
	end
	return nil -- Void
end

-- ============================================
-- QUEUE SYSTEM
-- ============================================

local fallQueue = {}
local activelyFalling = {}
local activeFallCount = 0
local trackedBlockPositions = {}
local queuedBlocks = {}

local checkColumnAbove

local function destroyDecorationsAt(position: Vector3)
	local overlapParams = OverlapParams.new()
	local checkPos = position - Vector3.new(0, BLOCK_SIZE * 0.25, 0)
	local parts = workspace:GetPartBoundsInBox(
		CFrame.new(checkPos),
		Vector3.new(BLOCK_SIZE * 0.8, BLOCK_SIZE * 0.5, BLOCK_SIZE * 0.8),
		overlapParams
	)
	
	for _, part in ipairs(parts) do
		if part:GetAttribute("IsDecoration") then
			part:Destroy()
		elseif part.Parent and part.Parent:GetAttribute("IsDecoration") then
			part.Parent:Destroy()
		end
	end
end

local function setBlockPosition(block: Instance, position: Vector3)
	if block:IsA("BasePart") then
		block.Position = position
	elseif block:IsA("Model") then
		local currentPivot = block:GetPivot()
		local offset = currentPivot.Position - position
		block:PivotTo(currentPivot - offset)
	end
end

local function processFall(block: Instance, blocksFolder: Folder, useInstant: boolean)
	if not block or not block.Parent then
		queuedBlocks[block] = nil
		return
	end
	
	local startPos = getBlockPosition(block)
	if not startPos then
		queuedBlocks[block] = nil
		return
	end
	
	local blockType = block:GetAttribute("BlockType")
	if DEBUG then
		print(string.format("[FallingBlock] ===== processFall: %s at Y=%.2f =====", blockType or "unknown", startPos.Y))
	end
	
	local originalPos = startPos
	
	-- Re-check support
	if hasSupport(block, blocksFolder) then
		if DEBUG then
			print("[FallingBlock] Block has support, not falling")
		end
		queuedBlocks[block] = nil
		return
	end
	
	local targetPos = findLandingPosition(startPos, blocksFolder, block)
	
	if not targetPos then
		if DEBUG then
			print("[FallingBlock] No landing position, destroying")
		end
		block:Destroy()
		queuedBlocks[block] = nil
		trackedBlockPositions[block] = nil
		return
	end
	
	local fallDistanceStuds = startPos.Y - targetPos.Y
	
	if DEBUG then
		print(string.format("[FallingBlock] Fall: Y=%.2f -> Y=%.2f (%.2f studs)", 
			startPos.Y, targetPos.Y, fallDistanceStuds))
	end
	
	if fallDistanceStuds < 0.2 then
		if DEBUG then
			print("[FallingBlock] Fall distance too small")
		end
		queuedBlocks[block] = nil
		return
	end
	
	if useInstant then
		destroyDecorationsAt(targetPos)
		setBlockPosition(block, targetPos)
		trackedBlockPositions[block] = targetPos
		queuedBlocks[block] = nil
		
		task.defer(function()
			checkColumnAbove(originalPos, blocksFolder)
		end)
		return
	end
	
	activelyFalling[block] = true
	activeFallCount += 1
	
	local fallBlocks = math.max(1, math.ceil(fallDistanceStuds / BLOCK_SIZE))
	local fallTime = fallBlocks * FALL_SPEED
	
	task.spawn(function()
		local tweenInfo = TweenInfo.new(fallTime, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		
		if block:IsA("BasePart") then
			local tween = TweenService:Create(block, tweenInfo, {Position = targetPos})
			tween:Play()
			tween.Completed:Wait()
		elseif block:IsA("Model") then
			local primary = block.PrimaryPart or block:FindFirstChildWhichIsA("BasePart")
			if primary then
				local startCFrame = block:GetPivot()
				local offset = startCFrame.Position - targetPos
				local targetCFrame = startCFrame - offset
				
				local elapsed = 0
				while elapsed < fallTime and block and block.Parent do
					local dt = task.wait()
					elapsed += dt
					local alpha = math.min(elapsed / fallTime, 1)
					alpha = alpha * alpha
					block:PivotTo(startCFrame:Lerp(targetCFrame, alpha))
				end
				
				if block and block.Parent then
					block:PivotTo(targetCFrame)
				end
			end
		end
		
		activelyFalling[block] = nil
		activeFallCount -= 1
		queuedBlocks[block] = nil
		
		if block and block.Parent then
			destroyDecorationsAt(targetPos)
			trackedBlockPositions[block] = targetPos
			if DEBUG then
				local finalPos = getBlockPosition(block)
				print(string.format("[FallingBlock] Complete, final Y=%.2f", finalPos and finalPos.Y or -999))
			end
		end
		
		task.defer(function()
			checkColumnAbove(originalPos, blocksFolder)
		end)
	end)
end

local function processQueue()
	if BulkOperationFlags and BulkOperationFlags.IsShuttingDown() then return end
	if #fallQueue == 0 then return end
	
	local useInstant = #fallQueue > INSTANT_FALL_THRESHOLD
	
	if useInstant then
		local toProcess = fallQueue
		fallQueue = {}
		for _, data in ipairs(toProcess) do
			processFall(data.block, data.blocksFolder, true)
		end
		return
	end
	
	local processed = 0
	while #fallQueue > 0 and processed < FALLS_PER_FRAME and activeFallCount < MAX_CONCURRENT_FALLS do
		local data = table.remove(fallQueue, 1)
		if data.block and data.block.Parent and not activelyFalling[data.block] then
			processFall(data.block, data.blocksFolder, false)
			processed += 1
		else
			queuedBlocks[data.block] = nil
		end
	end
end

local function queueBlockFall(block: Instance, blocksFolder: Folder)
	if not block or not block.Parent then return end
	if queuedBlocks[block] then return end
	if activelyFalling[block] then return end
	
	queuedBlocks[block] = true
	table.insert(fallQueue, {block = block, blocksFolder = blocksFolder})
end

checkColumnAbove = function(removedPosition: Vector3, blocksFolder: Folder)
	local snappedPos = snapToGrid(removedPosition)
	local checkPos = snappedPos + Vector3.new(0, BLOCK_SIZE, 0)
	local maxChecks = 50
	
	if DEBUG then
		print(string.format("[FallingBlock] checkColumnAbove: removed at Y=%.2f, checking Y=%.2f", snappedPos.Y, checkPos.Y))
	end
	
	for i = 1, maxChecks do
		local blockAbove = getBlockAt(checkPos, blocksFolder, nil)
		
		if not blockAbove then
			if DEBUG then
				print(string.format("[FallingBlock] No block found at Y=%.2f, stopping", checkPos.Y))
			end
			break
		end
		
		local blockType = blockAbove:GetAttribute("BlockType")
		if DEBUG then
			print(string.format("[FallingBlock] Found %s at Y=%.2f", blockType or "unknown", checkPos.Y))
		end
		
		if isFallingBlockType(blockType) then
			if DEBUG then
				print(string.format("[FallingBlock] Queuing %s to fall", blockType))
			end
			queueBlockFall(blockAbove, blocksFolder)
		else
			if DEBUG then
				print(string.format("[FallingBlock] %s is not a falling block type, stopping", blockType or "unknown"))
			end
			break
		end
		
		checkPos = checkPos + Vector3.new(0, BLOCK_SIZE, 0)
	end
end

-- ============================================
-- MONITORING
-- ============================================

local function trackBlock(block: Instance)
	local pos = getBlockPosition(block)
	if pos then
		trackedBlockPositions[block] = pos
	end
end

local function onBlockAdded(block: Instance, blocksFolder: Folder)
	-- Skip during bulk operations (terrain gen, save loading)
	local buildArea = blocksFolder.Parent
	if buildArea and BulkOperationFlags.IsBulkOperation(buildArea) then return end
	if blocksFolder:GetAttribute("BulkOperationInProgress") then return end
	
	task.wait()
	trackBlock(block)
	
	local blockType = block:GetAttribute("BlockType")
	if not isFallingBlockType(blockType) then return end
	
	if DEBUG then
		print(string.format("[FallingBlock] Block added: %s", blockType))
	end
	
	task.wait(0.1)
	
	if not hasSupport(block, blocksFolder) then
		if DEBUG then
			print("[FallingBlock] No support, queuing fall")
		end
		queueBlockFall(block, blocksFolder)
	else
		if DEBUG then
			print("[FallingBlock] Has support, not falling")
		end
	end
end

local function onBlockRemoved(block: Instance, blocksFolder: Folder)
	-- Skip during bulk operations (terrain gen, save loading)
	local buildArea = blocksFolder.Parent
	if buildArea and BulkOperationFlags.IsBulkOperation(buildArea) then
		-- Still clean up tracking but don't check column
		trackedBlockPositions[block] = nil
		activelyFalling[block] = nil
		queuedBlocks[block] = nil
		return
	end
	if blocksFolder:GetAttribute("BulkOperationInProgress") then
		trackedBlockPositions[block] = nil
		activelyFalling[block] = nil
		queuedBlocks[block] = nil
		return
	end
	
	local blockPos = trackedBlockPositions[block]
	trackedBlockPositions[block] = nil
	activelyFalling[block] = nil
	queuedBlocks[block] = nil
	
	if not blockPos then return end
	
	task.defer(function()
		checkColumnAbove(blockPos, blocksFolder)
	end)
end

local monitoredAreas = {}

local function monitorBuildArea(buildArea: Instance)
	if DEBUG then
		print(string.format("[FallingBlock] monitorBuildArea called for %s", buildArea.Name))
	end
	
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	
	if not blocksFolder then
		if DEBUG then
			print(string.format("[FallingBlock] %s has no Blocks folder yet, waiting...", buildArea.Name))
		end
		-- Don't mark as monitored yet - wait for Blocks folder
		if monitoredAreas[buildArea] == "waiting" then return end
		monitoredAreas[buildArea] = "waiting"
		
		local connection
		connection = buildArea.ChildAdded:Connect(function(child)
			if child.Name == "Blocks" and child:IsA("Folder") then
				if DEBUG then
					print(string.format("[FallingBlock] Blocks folder created in %s!", buildArea.Name))
				end
				connection:Disconnect()
				monitoredAreas[buildArea] = nil -- Reset so we can actually monitor
				monitorBuildArea(buildArea)
			end
		end)
		return
	end
	
	-- Already fully monitored
	if monitoredAreas[buildArea] == true then return end
	monitoredAreas[buildArea] = true
	
	if DEBUG then
		print(string.format("[FallingBlock] Now monitoring %s (Blocks folder exists)", buildArea.Name))
	end
	
	for _, block in ipairs(blocksFolder:GetChildren()) do
		trackBlock(block)
	end
	
	blocksFolder.ChildAdded:Connect(function(block)
		if BulkOperationFlags.IsShuttingDown() then return end
		onBlockAdded(block, blocksFolder)
	end)
	
	blocksFolder.ChildRemoved:Connect(function(block)
		if BulkOperationFlags.IsShuttingDown() then return end
		onBlockRemoved(block, blocksFolder)
	end)
end

local initialized = false

local function initialize()
	if initialized then return end
	initialized = true
	
	RunService.Heartbeat:Connect(processQueue)
	
	if DEBUG then
		print("[FallingBlock] Looking for build areas...")
	end
	
	for i = 1, GridConfig.TOTAL_PLOTS do
		local areaName = GridConfig.BUILD_AREA_PREFIX .. i
		local buildArea = workspace:FindFirstChild(areaName)
		if buildArea then
			if DEBUG then
				print(string.format("[FallingBlock] Found %s", areaName))
				-- List all children
				print(string.format("[FallingBlock] Children of %s:", areaName))
				for _, child in ipairs(buildArea:GetChildren()) do
					print(string.format("  - %s (%s)", child.Name, child.ClassName))
				end
			end
			monitorBuildArea(buildArea)
		else
			if DEBUG then
				print(string.format("[FallingBlock] %s not found yet", areaName))
			end
		end
	end
	
	workspace.ChildAdded:Connect(function(child)
		if string.find(child.Name, GridConfig.BUILD_AREA_PREFIX) then
			monitorBuildArea(child)
		end
	end)
	
	-- Also monitor MegaPlot build area (for private server MegaPlot mode)
	local function setupMegaPlotMonitoring(megaPlotRoom)
		local megaBuildArea = megaPlotRoom:FindFirstChild("MegaPlotBuildArea")
		if megaBuildArea then
			monitorBuildArea(megaBuildArea)
		end
		megaPlotRoom.ChildAdded:Connect(function(child)
			if child.Name == "MegaPlotBuildArea" then
				task.wait(0.5)
				monitorBuildArea(child)
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
	
	-- NOTE: Removed workspace.DescendantAdded listener as it causes performance issues.
	-- The polling fallback below handles the same case more efficiently.
	
	-- Polling fallback: check every 2 seconds for unmonitored Blocks folders
	task.spawn(function()
		while true do
			task.wait(2)
			for i = 1, GridConfig.TOTAL_PLOTS do
				local areaName = GridConfig.BUILD_AREA_PREFIX .. i
				local buildArea = workspace:FindFirstChild(areaName)
				if buildArea and monitoredAreas[buildArea] ~= true then
					local blocksFolder = buildArea:FindFirstChild("Blocks")
					if blocksFolder then
						if DEBUG then
							print(string.format("[FallingBlock] Polling found Blocks folder in %s", areaName))
						end
						monitoredAreas[buildArea] = nil -- Reset
						monitorBuildArea(buildArea)
					end
				end
			end
		end
	end)
	
	print("FallingBlockHandler initialized - Sand, Gravel, and their variants will now fall!")
end

initialize()
