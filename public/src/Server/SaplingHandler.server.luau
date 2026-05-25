--[[
	SaplingHandler
	Tracks planted saplings and grows them into trees after a delay
	
	Saplings grow into their corresponding tree type:
	- OakSapling -> Oak tree
	- SpruceSapling -> Spruce tree
	- BirchSapling -> Birch tree
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")

local GridConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GridConfig"))

-- Wait for TreeGenerator module
local TreeGenerator = nil
local LeafDecayManager = nil

task.spawn(function()
	local modulesFolder = ServerScriptService:WaitForChild("Modules", 10)
	if modulesFolder then
		local treeModule = modulesFolder:WaitForChild("TreeGenerator", 10)
		if treeModule then
			TreeGenerator = require(treeModule)
			print("[SaplingHandler] TreeGenerator loaded")
		else
			warn("[SaplingHandler] TreeGenerator module not found!")
		end
		
		-- Also load LeafDecayManager for tree decay support
		local leafDecayModule = modulesFolder:WaitForChild("LeafDecayManager", 10)
		if leafDecayModule then
			LeafDecayManager = require(leafDecayModule)
			print("[SaplingHandler] LeafDecayManager loaded")
		else
			warn("[SaplingHandler] LeafDecayManager module not found!")
		end
	end
end)

local BLOCK_SIZE = GridConfig.BLOCK_SIZE

-- Configuration
local GROWTH_TIME = 10 -- Seconds until sapling grows into tree (reduced from 60 for testing)
local GROWTH_CHECK_INTERVAL = 1 -- How often to check for growth (seconds)

-- Map sapling types to tree types
local SAPLING_TO_TREE = {
	["OakSapling"] = "Oak",
	["SpruceSapling"] = "Spruce",
	["BirchSapling"] = "Birch",
	["AcaciaSapling"] = "Acacia",
	["DarkOakSapling"] = "DarkOak",
	["EbonySapling"] = "Ebony",
	["RedwoodSapling"] = "Redwood",
}

-- Saplings that require 2x2 formation to grow (large trees)
local REQUIRES_2X2 = {
	["RedwoodSapling"] = true,
	["DarkOakSapling"] = true,
}

-- Track all planted saplings: { [sapling] = { plantedTime = tick(), treeType = "Oak", ... } }
local plantedSaplings = {}

-- Debug flag
local DEBUG_SAPLINGS = true

-- ============================================
-- HELPER FUNCTIONS
-- ============================================

local function getSaplingPosition(sapling)
	if sapling:IsA("BasePart") then
		return sapling.Position
	elseif sapling:IsA("Model") then
		local pivot = sapling:GetPivot()
		return pivot.Position
	end
	return nil
end

-- Find a sapling of the same type at a specific world position
local function findSaplingAt(blocksFolder, saplingType, worldX, worldZ, baseY)
	local tolerance = BLOCK_SIZE * 0.7 -- Generous tolerance for position matching
	
	for _, block in ipairs(blocksFolder:GetChildren()) do
		local blockType = block:GetAttribute("BlockType")
		if blockType == saplingType then
			local pos = getSaplingPosition(block)
			if pos then
				if math.abs(pos.X - worldX) < tolerance and 
				   math.abs(pos.Z - worldZ) < tolerance and
				   math.abs(pos.Y - baseY) < BLOCK_SIZE then
					return block
				end
			end
		end
	end
	return nil
end

-- Check if this sapling is part of a complete 2x2 formation
-- Returns: isComplete, allSaplings (array of 4 saplings if complete), centerPosition
local function check2x2Formation(sapling, blocksFolder, buildArea)
	local saplingType = sapling:GetAttribute("BlockType")
	
	-- Use ParentBlock position for accurate grid alignment
	local parentX = sapling:GetAttribute("ParentBlockX")
	local parentY = sapling:GetAttribute("ParentBlockY")
	local parentZ = sapling:GetAttribute("ParentBlockZ")
	
	if not (parentX and parentY and parentZ) then
		-- Fallback to sapling position if no parent block data
		local pos = getSaplingPosition(sapling)
		if not pos then return false, nil, nil end
		parentX, parentY, parentZ = pos.X, pos.Y - BLOCK_SIZE, pos.Z
	end
	
	-- Calculate terrain origin for proper grid snapping
	local originX, originZ = 0, 0
	if buildArea then
		local posX = buildArea:GetAttribute("BasePlatePositionX")
		local posZ = buildArea:GetAttribute("BasePlatePositionZ")
		local sizeX = buildArea:GetAttribute("BasePlateSizeX")
		local sizeZ = buildArea:GetAttribute("BasePlateSizeZ")
		
		if posX and posZ and sizeX and sizeZ then
			originX = posX - sizeX / 2 + BLOCK_SIZE / 2
			originZ = posZ - sizeZ / 2 + BLOCK_SIZE / 2
		end
	end
	
	-- Convert parent block position to grid coordinates relative to terrain origin
	local gridX = math.round((parentX - originX) / BLOCK_SIZE)
	local gridZ = math.round((parentZ - originZ) / BLOCK_SIZE)
	
	print(string.format("[SaplingHandler] 2x2 check: sapling parent at grid (%d, %d), origin (%.1f, %.1f)", 
		gridX, gridZ, originX, originZ))
	
	-- Check all 4 possible 2x2 arrangements this sapling could be part of
	-- (this sapling could be in any corner of the 2x2)
	local offsets = {
		{{0, 0}, {1, 0}, {0, 1}, {1, 1}},   -- This sapling is bottom-left
		{{-1, 0}, {0, 0}, {-1, 1}, {0, 1}}, -- This sapling is bottom-right
		{{0, -1}, {1, -1}, {0, 0}, {1, 0}}, -- This sapling is top-left
		{{-1, -1}, {0, -1}, {-1, 0}, {0, 0}}, -- This sapling is top-right
	}
	
	for arrangementIndex, arrangement in ipairs(offsets) do
		local allFound = true
		local saplings = {}
		local minGridX, minGridZ = math.huge, math.huge
		
		for _, offset in ipairs(arrangement) do
			local checkGridX = gridX + offset[1]
			local checkGridZ = gridZ + offset[2]
			
			-- Track min position for center calculation
			minGridX = math.min(minGridX, checkGridX)
			minGridZ = math.min(minGridZ, checkGridZ)
			
			-- Convert grid position back to world position
			local worldX = originX + checkGridX * BLOCK_SIZE
			local worldZ = originZ + checkGridZ * BLOCK_SIZE
			
			-- Check if this is the original sapling
			if offset[1] == 0 and offset[2] == 0 then
				table.insert(saplings, sapling)
			else
				local foundSapling = findSaplingAt(blocksFolder, saplingType, worldX, worldZ, parentY + BLOCK_SIZE)
				if foundSapling then
					table.insert(saplings, foundSapling)
				else
					allFound = false
					break
				end
			end
		end
		
		if allFound and #saplings == 4 then
			-- Use bottom-left corner position (grid-aligned) as tree base
			-- BUT: The tree structure has its 2x2 trunk at offsets (-3,-3), (0,-3), (-3,0), (0,0)
			-- So we need to offset by +BLOCK_SIZE to align the trunk with the sapling positions
			local cornerX = originX + (minGridX + 1) * BLOCK_SIZE  -- +1 block offset to compensate for structure
			local cornerZ = originZ + (minGridZ + 1) * BLOCK_SIZE  -- +1 block offset to compensate for structure
			-- Y: tree base goes half a block above parent block center (tested value)
			local cornerY = parentY + BLOCK_SIZE / 2
			local cornerPos = Vector3.new(cornerX, cornerY, cornerZ)
			
			print(string.format("[SaplingHandler] 2x2 COMPLETE with arrangement %d! Base: (%.1f, %.1f, %.1f) for grid (%d,%d)",
				arrangementIndex, cornerX, cornerY, cornerZ, minGridX, minGridZ))
			
			return true, saplings, cornerPos
		end
	end
	
	print("[SaplingHandler] 2x2 formation NOT complete")
	return false, nil, nil
end

local function getBlocksFolder(sapling)
	-- Saplings are placed in BuildArea/Blocks folder
	local parent = sapling.Parent
	if parent and parent.Name == "Blocks" then
		return parent
	end
	return nil
end

local function getBuildArea(sapling)
	local blocksFolder = getBlocksFolder(sapling)
	if blocksFolder then
		return blocksFolder.Parent
	end
	return nil
end

-- Build a fast spatial lookup set from all existing blocks in a folder
-- Returns a table where keys are snapped position strings for O(1) lookups
local function buildBlockPositionSet(blocksFolder)
	local posSet = {}
	local snapSize = BLOCK_SIZE * 0.5 -- Snap to half-block grid for reliable matching
	
	for _, block in ipairs(blocksFolder:GetChildren()) do
		local blockPos
		if block:IsA("BasePart") then
			blockPos = block.Position
		elseif block:IsA("Model") then
			local storedX = block:GetAttribute("BlockPosX")
			local storedY = block:GetAttribute("BlockPosY")
			local storedZ = block:GetAttribute("BlockPosZ")
			
			if storedX and storedY and storedZ then
				blockPos = Vector3.new(storedX, storedY, storedZ)
			else
				local primary = block.PrimaryPart or block:FindFirstChildWhichIsA("BasePart")
				if primary then
					blockPos = primary.Position + Vector3.new(0, BLOCK_SIZE / 2, 0)
				end
			end
		end
		
		if blockPos then
			-- Snap to grid for consistent key generation
			local key = string.format("%d,%d,%d",
				math.round(blockPos.X / snapSize),
				math.round(blockPos.Y / snapSize),
				math.round(blockPos.Z / snapSize))
			posSet[key] = true
		end
	end
	
	return posSet
end

-- Check if there's already a block at the given position using a pre-built position set
local function hasBlockAtPositionFast(position, posSet)
	local snapSize = BLOCK_SIZE * 0.5
	local key = string.format("%d,%d,%d",
		math.round(position.X / snapSize),
		math.round(position.Y / snapSize),
		math.round(position.Z / snapSize))
	return posSet[key] == true
end

-- Grow a sapling into a tree
local function growSapling(sapling, data)
	print("[SaplingHandler] ========== GROW SAPLING CALLED ==========")
	
	if not TreeGenerator then
		warn("[SaplingHandler] Cannot grow sapling - TreeGenerator not loaded!")
		warn("[SaplingHandler] Check that ServerScriptService.Modules.TreeGenerator exists")
		return false
	end
	print("[SaplingHandler] TreeGenerator is loaded ✓")
	
	local blocksFolder = getBlocksFolder(sapling)
	if not blocksFolder then
		warn("[SaplingHandler] Cannot find blocks folder for sapling")
		warn("[SaplingHandler] Sapling parent: " .. tostring(sapling.Parent))
		return false
	end
	print("[SaplingHandler] Blocks folder found: " .. blocksFolder:GetFullName())
	
	local buildArea = getBuildArea(sapling)
	local saplingPos = getSaplingPosition(sapling)
	if not saplingPos then
		warn("[SaplingHandler] Could not get sapling position")
		return false
	end
	print(string.format("[SaplingHandler] Sapling position: (%.1f, %.1f, %.1f)", saplingPos.X, saplingPos.Y, saplingPos.Z))
	
	-- Get tree type from sapling
	local treeType = data.treeType
	if not treeType then
		warn("[SaplingHandler] No tree type for sapling")
		return false
	end
	print("[SaplingHandler] Tree type: " .. treeType)
	
	-- Check if this sapling requires 2x2 formation
	local blockType = sapling:GetAttribute("BlockType")
	local saplingsToRemove = {sapling}
	
	-- Get grid-aligned position for tree base
	-- Saplings are decorations - use ParentBlock attributes for accurate grid position
	local parentX = sapling:GetAttribute("ParentBlockX")
	local parentY = sapling:GetAttribute("ParentBlockY")
	local parentZ = sapling:GetAttribute("ParentBlockZ")
	
	local treeBasePos
	
	if parentX and parentY and parentZ then
		-- Use stored parent block position (grid-aligned)
		-- ParentBlock Y is the block CENTER, tree base Y goes one full block above
		treeBasePos = Vector3.new(parentX, parentY + BLOCK_SIZE, parentZ)
		print(string.format("[SaplingHandler] Using ParentBlock position: (%.1f, %.1f, %.1f) -> tree base: (%.1f, %.1f, %.1f)", 
			parentX, parentY, parentZ, treeBasePos.X, treeBasePos.Y, treeBasePos.Z))
	elseif buildArea then
		-- Fallback: snap current position to terrain grid
		local posX = buildArea:GetAttribute("BasePlatePositionX")
		local posZ = buildArea:GetAttribute("BasePlatePositionZ")
		local sizeX = buildArea:GetAttribute("BasePlateSizeX")
		local sizeZ = buildArea:GetAttribute("BasePlateSizeZ")
		
		if posX and posZ and sizeX and sizeZ then
			-- Calculate terrain origin (same as TerrainGenerator/PlotSerializer)
			local originX = posX - sizeX / 2 + BLOCK_SIZE / 2
			local originZ = posZ - sizeZ / 2 + BLOCK_SIZE / 2
			
			-- Snap to nearest grid position relative to terrain origin
			local gridIndexX = math.round((saplingPos.X - originX) / BLOCK_SIZE)
			local gridIndexZ = math.round((saplingPos.Z - originZ) / BLOCK_SIZE)
			
			local snappedX = originX + gridIndexX * BLOCK_SIZE
			local snappedZ = originZ + gridIndexZ * BLOCK_SIZE
			
			treeBasePos = Vector3.new(snappedX, saplingPos.Y, snappedZ)
			print(string.format("[SaplingHandler] Snapped to terrain grid: (%.1f, %.1f, %.1f) from origin (%.1f, %.1f)", 
				treeBasePos.X, treeBasePos.Y, treeBasePos.Z, originX, originZ))
		else
			-- Fallback if no build area attributes
			treeBasePos = Vector3.new(
				math.round(saplingPos.X / BLOCK_SIZE) * BLOCK_SIZE,
				saplingPos.Y,
				math.round(saplingPos.Z / BLOCK_SIZE) * BLOCK_SIZE
			)
			print(string.format("[SaplingHandler] Fallback snap: (%.1f, %.1f, %.1f)", treeBasePos.X, treeBasePos.Y, treeBasePos.Z))
		end
	else
		-- No build area, basic snap
		treeBasePos = Vector3.new(
			math.round(saplingPos.X / BLOCK_SIZE) * BLOCK_SIZE,
			saplingPos.Y,
			math.round(saplingPos.Z / BLOCK_SIZE) * BLOCK_SIZE
		)
		print(string.format("[SaplingHandler] Basic snap (no buildArea): (%.1f, %.1f, %.1f)", treeBasePos.X, treeBasePos.Y, treeBasePos.Z))
	end
	
	if REQUIRES_2X2[blockType] then
		print("[SaplingHandler] This sapling requires 2x2 formation...")
		local isComplete, allSaplings, centerPos = check2x2Formation(sapling, blocksFolder, buildArea)
		
		if not isComplete then
			print("[SaplingHandler] 2x2 formation not complete - need 4 saplings in a square")
			return false -- Will retry later
		end
		
		print(string.format("[SaplingHandler] 2x2 formation complete! Center at (%.1f, %.1f, %.1f)", 
			centerPos.X, centerPos.Y, centerPos.Z))
		
		saplingsToRemove = allSaplings
		treeBasePos = centerPos
	end
	
	print(string.format("[SaplingHandler] Tree base position: (%.1f, %.1f, %.1f)", treeBasePos.X, treeBasePos.Y, treeBasePos.Z))
	
	-- Get biome and season from build area for leaf coloring
	local biomeName = buildArea and buildArea:GetAttribute("CurrentBiome") or nil
	local seasonName = buildArea and buildArea:GetAttribute("CurrentSeason") or nil
	print(string.format("[SaplingHandler] Biome: %s, Season: %s", tostring(biomeName), tostring(seasonName)))
	
	-- Get tree blocks using TreeGenerator
	-- Pass true for skipDistanceCheck since player saplings can grow near other trees
	print("[SaplingHandler] Calling TreeGenerator.GetTreeBlocks...")
	local treeBlocks = TreeGenerator.GetTreeBlocks(treeBasePos, treeType, blocksFolder, biomeName, seasonName, true)
	
	if not treeBlocks then
		warn(string.format("[SaplingHandler] TreeGenerator.GetTreeBlocks RETURNED NIL for %s at (%.1f, %.1f, %.1f)", 
			treeType, treeBasePos.X, treeBasePos.Y, treeBasePos.Z))
		warn("[SaplingHandler] This usually means CanPlaceTree failed (out of plot bounds?)")
		return false
	end
	print(string.format("[SaplingHandler] TreeGenerator returned %d blocks", #treeBlocks))
	
	-- Store who planted the sapling for attribution
	local placedBy = sapling:GetAttribute("PlacedBy")
	
	-- Destroy all saplings (handles both single and 2x2)
	print(string.format("[SaplingHandler] Destroying %d sapling(s)...", #saplingsToRemove))
	for _, sap in ipairs(saplingsToRemove) do
		-- Remove from tracking
		plantedSaplings[sap] = nil
		sap:Destroy()
	end
	
	-- Build a fast spatial lookup of existing blocks ONCE (O(n) instead of O(n) per leaf)
	local existingBlockSet = buildBlockPositionSet(blocksFolder)
	
	-- Build a set of log positions from THIS tree for fast overlap checks
	local logPosSet = {}
	local snapSize = BLOCK_SIZE * 0.5
	for _, blockData in ipairs(treeBlocks) do
		if blockData.blockType == "L" then
			local key = string.format("%d,%d,%d",
				math.round(blockData.position.X / snapSize),
				math.round(blockData.position.Y / snapSize),
				math.round(blockData.position.Z / snapSize))
			logPosSet[key] = true
		end
	end
	
	-- Spawn the tree blocks (logs first, then leaves)
	local blocksCreated = 0
	local YIELD_EVERY = 10 -- Yield every N blocks to prevent frame freezes
	
	-- Create logs
	for _, blockData in ipairs(treeBlocks) do
		if blockData.blockType == "L" then
			local log = TreeGenerator.CreateLog(blockData.position, blocksFolder, blockData.treeType)
			if log then
				log:SetAttribute("PlacedBy", placedBy)
				log:SetAttribute("GrownFromSapling", true)
				blocksCreated = blocksCreated + 1
				if blocksCreated % YIELD_EVERY == 0 then
					task.wait()
				end
			end
		end
	end
	
	-- Create leaves
	for _, blockData in ipairs(treeBlocks) do
		if blockData.blockType == "l" then
			-- Skip if overlaps with logs from this tree (O(1) lookup)
			local key = string.format("%d,%d,%d",
				math.round(blockData.position.X / snapSize),
				math.round(blockData.position.Y / snapSize),
				math.round(blockData.position.Z / snapSize))
			if logPosSet[key] then
				continue
			end
			
			-- Skip if there's already a block at this position (O(1) lookup)
			if hasBlockAtPositionFast(blockData.position, existingBlockSet) then
				continue
			end
			
			local leaves = TreeGenerator.CreateLeaves(
				blockData.position, 
				blocksFolder, 
				blockData.treeType, 
				true, -- isGenerated = true, allows decay
				blockData.biomeName,
				blockData.seasonName
			)
			if leaves then
				leaves:SetAttribute("PlacedBy", placedBy)
				leaves:SetAttribute("GrownFromSapling", true)
				blocksCreated = blocksCreated + 1
				if blocksCreated % YIELD_EVERY == 0 then
					task.wait()
				end
			end
		end
	end
	
	print(string.format("[SaplingHandler] SUCCESS! Grew %s tree with %d blocks at (%.1f, %.1f, %.1f)", 
		treeType, blocksCreated, treeBasePos.X, treeBasePos.Y, treeBasePos.Z))
	print("[SaplingHandler] ========================================")
	
	-- Initialize leaf decay for this build area so leaves can decay when logs are broken
	if LeafDecayManager and buildArea then
		LeafDecayManager.Initialize(buildArea)
	end
	
	return true
end

-- ============================================
-- PUBLIC API
-- ============================================

local SaplingHandler = {}

-- Scan a build area for existing saplings and register them
-- Called after plot is loaded from save
function SaplingHandler.ScanBuildAreaForSaplings(buildArea, restartTimers)
	if not buildArea then 
		warn("[SaplingHandler] ScanBuildAreaForSaplings: buildArea is nil")
		return 0 
	end
	
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder then 
		print("[SaplingHandler] ScanBuildAreaForSaplings: No Blocks folder in " .. buildArea.Name)
		return 0 
	end
	
	local registered = 0
	local totalBlocks = #blocksFolder:GetChildren()
	
	print(string.format("[SaplingHandler] Scanning %s for saplings (%d total blocks)...", buildArea.Name, totalBlocks))
	
	for _, block in ipairs(blocksFolder:GetChildren()) do
		local blockType = block:GetAttribute("BlockType")
		
		-- Check if it's a sapling by BlockType (primary method)
		local treeType = SAPLING_TO_TREE[blockType]
		
		-- Also check IsSapling attribute as fallback
		if not treeType and block:GetAttribute("IsSapling") then
			treeType = block:GetAttribute("TreeType")
		end
		
		if treeType then
			-- Skip if already tracked
			if plantedSaplings[block] then 
				print(string.format("[SaplingHandler] Skipping already-tracked sapling: %s", blockType or "unknown"))
				continue 
			end
			
			-- Mark as sapling if not already
			block:SetAttribute("IsSapling", true)
			block:SetAttribute("TreeType", treeType)
			
			local startTime
			
			if restartTimers then
				-- Restart timer from scratch
				block:SetAttribute("PlantedTime", os.time())
				startTime = tick()
				
				print(string.format("[SaplingHandler] Registered loaded %s sapling, timer restarted (grows in %d seconds)", 
					blockType or "unknown", GROWTH_TIME))
			else
				-- Try to restore remaining time
				local plantedTime = block:GetAttribute("PlantedTime")
				if plantedTime then
					local age = os.time() - plantedTime
					local remainingTime = math.max(0, GROWTH_TIME - age)
					startTime = tick() - (GROWTH_TIME - remainingTime)
					
					print(string.format("[SaplingHandler] Restored sapling timer (grows in %.1f seconds)", remainingTime))
				else
					-- No planted time saved, restart timer
					block:SetAttribute("PlantedTime", os.time())
					startTime = tick()
					
					print(string.format("[SaplingHandler] Registered loaded sapling, no saved time (grows in %d seconds)", GROWTH_TIME))
				end
			end
			
			plantedSaplings[block] = {
				plantedTime = startTime,
				treeType = treeType,
			}
			
			registered = registered + 1
		end
	end
	
	if registered > 0 then
		print(string.format("[SaplingHandler] Scanned %s - found and registered %d saplings", buildArea.Name, registered))
	else
		print(string.format("[SaplingHandler] Scanned %s - no saplings found", buildArea.Name))
	end
	
	return registered
end

-- Register a newly planted sapling
function SaplingHandler.RegisterSapling(sapling)
	if not sapling then
		warn("[SaplingHandler] RegisterSapling called with nil sapling!")
		return
	end
	
	-- Check if already tracked
	if plantedSaplings[sapling] then
		if DEBUG_SAPLINGS then
			print("[SaplingHandler] Sapling already registered, skipping")
		end
		return
	end
	
	local blockType = sapling:GetAttribute("BlockType")
	local treeType = SAPLING_TO_TREE[blockType]
	
	if DEBUG_SAPLINGS then
		print(string.format("[SaplingHandler] RegisterSapling called - BlockType: %s, TreeType: %s", 
			tostring(blockType), tostring(treeType)))
	end
	
	if not treeType then
		if DEBUG_SAPLINGS then
			print("[SaplingHandler] Unknown sapling type: " .. tostring(blockType))
			print("[SaplingHandler] Valid types are: OakSapling, SpruceSapling, BirchSapling, AcaciaSapling, DarkOakSapling, EbonySapling, RedwoodSapling")
		end
		return
	end
	
	-- Mark as sapling
	sapling:SetAttribute("IsSapling", true)
	sapling:SetAttribute("TreeType", treeType)
	sapling:SetAttribute("PlantedTime", os.time())
	
	-- Track the sapling
	plantedSaplings[sapling] = {
		plantedTime = tick(),
		treeType = treeType,
	}
	
	-- Count total tracked
	local count = 0
	for _ in pairs(plantedSaplings) do
		count = count + 1
	end
	
	if DEBUG_SAPLINGS then
		local pos = getSaplingPosition(sapling)
		print(string.format("[SaplingHandler] SUCCESS! Registered %s sapling (grows %s tree) at (%.1f, %.1f, %.1f)", 
			blockType, treeType, pos and pos.X or 0, pos and pos.Y or 0, pos and pos.Z or 0))
		print(string.format("[SaplingHandler] Now tracking %d saplings total. Will grow in %d seconds.", 
			count, GROWTH_TIME))
	end
end

-- Unregister a sapling (when broken)
function SaplingHandler.UnregisterSapling(sapling)
	if plantedSaplings[sapling] then
		plantedSaplings[sapling] = nil
		if DEBUG_SAPLINGS then
			print("[SaplingHandler] Unregistered sapling")
		end
	end
end

-- Check if a block type is a sapling
function SaplingHandler.IsSapling(blockType)
	return SAPLING_TO_TREE[blockType] ~= nil
end

-- Get tree type for a sapling type
function SaplingHandler.GetTreeType(saplingType)
	return SAPLING_TO_TREE[saplingType]
end

-- ============================================
-- GROWTH LOOP
-- ============================================

local lastCheckTime = tick()
local lastDebugTime = tick()

RunService.Heartbeat:Connect(function()
	local currentTime = tick()
	
	-- Only check every GROWTH_CHECK_INTERVAL seconds
	if currentTime - lastCheckTime < GROWTH_CHECK_INTERVAL then
		return
	end
	lastCheckTime = currentTime
	
	-- Count tracked saplings for debug
	local saplingCount = 0
	for _ in pairs(plantedSaplings) do
		saplingCount = saplingCount + 1
	end
	
	-- Print debug status every 5 seconds (reduced for debugging)
	if DEBUG_SAPLINGS and currentTime - lastDebugTime >= 5 then
		lastDebugTime = currentTime
		print(string.format("[SaplingHandler] Tracking %d saplings", saplingCount))
		-- Also print details about tracked saplings
		for sap, sapData in pairs(plantedSaplings) do
			local age = currentTime - sapData.plantedTime
			local parentName = sap.Parent and sap.Parent.Name or "nil"
			print(string.format("[SaplingHandler]   - %s: age=%.1f/%d, parent=%s", sapData.treeType, age, GROWTH_TIME, parentName))
		end
	end
	
	-- Check each sapling for growth
	for sapling, data in pairs(plantedSaplings) do
		-- Check if sapling still exists
		if not sapling or not sapling.Parent then
			if DEBUG_SAPLINGS then
				print("[SaplingHandler] Removing destroyed sapling from tracking")
			end
			plantedSaplings[sapling] = nil
			continue
		end
		
		-- Check if enough time has passed
		local age = currentTime - data.plantedTime
		
		if DEBUG_SAPLINGS and saplingCount > 0 then
			-- Only print once per sapling per 10 seconds
			if currentTime - lastDebugTime < 1 then
				local pos = getSaplingPosition(sapling)
				print(string.format("[SaplingHandler] Sapling %s age: %.1f / %d seconds", 
					data.treeType, age, GROWTH_TIME))
			end
		end
		
		if age >= GROWTH_TIME then
			if DEBUG_SAPLINGS then
				print(string.format("[SaplingHandler] Sapling ready to grow! Type: %s, Age: %.1f", 
					data.treeType, age))
			end
			
			-- Try to grow the sapling
			local success = growSapling(sapling, data)
			
			if success then
				-- Remove from tracking (sapling was destroyed)
				plantedSaplings[sapling] = nil
			else
				-- Couldn't grow (no space?), reset timer to try again later
				if DEBUG_SAPLINGS then
					print("[SaplingHandler] Growth failed, will retry in 10 seconds")
				end
				data.plantedTime = currentTime - (GROWTH_TIME - 10) -- Try again in 10 seconds
			end
		end
	end
end)

-- ============================================
-- LISTEN FOR EXISTING SAPLINGS (on server restart)
-- ============================================

-- Scan all build areas for existing saplings
-- This runs on server restart to pick up any saplings that weren't tracked
-- NOTE: We wait longer to ensure saves have fully loaded
task.spawn(function()
	task.wait(10) -- Wait 10 seconds for game and saves to fully load
	
	print("[SaplingHandler] Running startup scan for existing saplings...")
	local totalFound = 0
	
	for i = 1, GridConfig.TOTAL_PLOTS do
		local buildArea = workspace:FindFirstChild(GridConfig.BUILD_AREA_PREFIX .. i)
		if buildArea then
			local blocksFolder = buildArea:FindFirstChild("Blocks")
			if blocksFolder then
				local blockCount = #blocksFolder:GetChildren()
				print(string.format("[SaplingHandler] Startup scan: Plot %d has %d blocks", i, blockCount))
				
				for _, block in ipairs(blocksFolder:GetChildren()) do
					local blockType = block:GetAttribute("BlockType")
					local treeType = SAPLING_TO_TREE[blockType]
					
					-- Also check IsSapling attribute
					if not treeType and block:GetAttribute("IsSapling") then
						treeType = block:GetAttribute("TreeType")
					end
					
					if treeType then
						-- Skip if already tracked
						if plantedSaplings[block] then continue end
						
						local plantedTime = block:GetAttribute("PlantedTime")
						
						-- Calculate how much time has passed since planted
						local age = plantedTime and (os.time() - plantedTime) or 0
						local remainingTime = math.max(0, GROWTH_TIME - age)
						
						-- Mark attributes
						block:SetAttribute("IsSapling", true)
						block:SetAttribute("TreeType", treeType)
						if not plantedTime then
							block:SetAttribute("PlantedTime", os.time())
							remainingTime = GROWTH_TIME
						end
						
						plantedSaplings[block] = {
							plantedTime = tick() - (GROWTH_TIME - remainingTime),
							treeType = treeType,
						}
						
						totalFound = totalFound + 1
						print(string.format("[SaplingHandler] Startup: Found %s sapling in plot %d (grows in %.1f seconds)", 
							blockType, i, remainingTime))
					end
				end
			end
		end
	end
	
	-- Also scan MegaPlot build area (for private server MegaPlot mode)
	local megaPlotRoom = workspace:FindFirstChild("MegaPlotRoom")
	if megaPlotRoom then
		local megaBuildArea = megaPlotRoom:FindFirstChild("MegaPlotBuildArea")
		if megaBuildArea then
			local blocksFolder = megaBuildArea:FindFirstChild("Blocks")
			if blocksFolder then
				for _, block in ipairs(blocksFolder:GetChildren()) do
					local blockType = block:GetAttribute("BlockType")
					local treeType = SAPLING_TO_TREE[blockType]
					if not treeType and block:GetAttribute("IsSapling") then
						treeType = block:GetAttribute("TreeType")
					end
					if treeType and not plantedSaplings[block] then
						local plantedTime = block:GetAttribute("PlantedTime")
						local age = plantedTime and (os.time() - plantedTime) or 0
						local remainingTime = math.max(0, GROWTH_TIME - age)
						block:SetAttribute("IsSapling", true)
						block:SetAttribute("TreeType", treeType)
						if not plantedTime then
							block:SetAttribute("PlantedTime", os.time())
							remainingTime = GROWTH_TIME
						end
						plantedSaplings[block] = {
							plantedTime = tick() - (GROWTH_TIME - remainingTime),
							treeType = treeType,
						}
						totalFound = totalFound + 1
						print(string.format("[SaplingHandler] Startup: Found %s sapling in MegaPlot (grows in %.1f seconds)", blockType, remainingTime))
					end
				end
			end
		end
	end
	
	print(string.format("[SaplingHandler] Startup scan complete - found %d saplings total", totalFound))
end)

-- Make module accessible via _G and BindableFunction
_G.SaplingHandler = SaplingHandler

-- Create BindableFunction for reliable registration from other scripts
local RegisterSaplingBindable = Instance.new("BindableFunction")
RegisterSaplingBindable.Name = "RegisterSapling"
RegisterSaplingBindable.Parent = ReplicatedStorage
RegisterSaplingBindable.OnInvoke = function(sapling)
	if DEBUG_SAPLINGS then
		print("[SaplingHandler] RegisterSapling called via BindableFunction")
	end
	SaplingHandler.RegisterSapling(sapling)
	return true
end

print("[SaplingHandler] Initialized - Saplings grow after " .. GROWTH_TIME .. " seconds")
print("[SaplingHandler] _G.SaplingHandler set:", _G.SaplingHandler ~= nil)
print("[SaplingHandler] RegisterSapling BindableFunction created:", ReplicatedStorage:FindFirstChild("RegisterSapling") ~= nil)

return SaplingHandler
