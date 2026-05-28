--[[
	SaveManager
	Handles saving and loading plot data to/from DataStore
	
	DataStore structure (Multi-Slot System):
	- Key: "meta_" .. UserId -> Player metadata (maxSlots, slot info)
	- Key: "slot_" .. UserId .. "_" .. slotNumber -> Individual plot data
	
	Features:
	- Multiple save slots (3 free, purchasable extras at 100R each)
	- Auto-save on player leaving
	- Manual save/load via remotes
	- Slot management (create, overwrite, delete)
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local MarketplaceService = game:GetService("MarketplaceService")

-- Coin system for coin-based slot purchases
local Modules = ServerScriptService:WaitForChild("Modules", 10)
local CoinManager = require(Modules:WaitForChild("CoinManager", 10))
local CoinConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("CoinConfig"))
local BetaConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("BetaConfig"))

-- Unique instance ID for debugging duplicate script detection
local INSTANCE_ID = math.random(100000, 999999)

-- Configuration
local DATASTORE_NAME = "PlotSaves_v2"  -- New datastore for multi-slot system
local LEGACY_DATASTORE_NAME = "PlotSaves_v1"  -- For migrating old saves
local AUTO_SAVE_INTERVAL = 300 -- 5 minutes
local SAVE_COOLDOWN = 10 -- Minimum seconds between manual saves

-- Slot configuration
local DEFAULT_MAX_SLOTS = 3
local MAX_PURCHASABLE_SLOTS = 20  -- Maximum total slots a player can have
local SLOT_PURCHASE_PRODUCT_ID = 3526105434  -- Developer Product for extra slot purchase

-- Wait for dependencies
local GridConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GridConfig"))
local PlotSerializer = require(ReplicatedStorage:WaitForChild("PlotSerializer", 10))
local BlockPresets = require(ReplicatedStorage:WaitForChild("BlockPresets", 10))
local SlabPlacement = require(ReplicatedStorage:WaitForChild("SlabPlacement", 10))
local StairPlacement = require(ReplicatedStorage:WaitForChild("StairPlacement", 10))
local FencePlacement = require(ReplicatedStorage:WaitForChild("FencePlacement", 10))
local GlassPlacement = require(ReplicatedStorage:WaitForChild("GlassPlacement", 10))

-- Resolve a glass-style block's template Model from its type + generic shape name.
-- Mirrors the same-named helper in BlockHandler. Standard glass lives in
-- Decorations/Glass; glass-style reward sets (CandyLattice) live in their
-- RewardSets folder. GlassPlacement.ResolveTemplate is the single source of
-- truth for folder + model name per type. Returns the template Instance or nil.
local function resolveGlassTemplate(glassType, genericTemplateName)
	local folderPath, modelName = GlassPlacement.ResolveTemplate(glassType, genericTemplateName)
	local folder = ReplicatedStorage
	for _, folderName in ipairs(string.split(folderPath, "/")) do
		folder = folder and folder:FindFirstChild(folderName)
	end
	if not folder then return nil end
	return folder:FindFirstChild(modelName)
end
local LadderPlacement = require(ReplicatedStorage:WaitForChild("LadderPlacement", 10))
local TorchPlacement = require(ReplicatedStorage:WaitForChild("TorchPlacement", 10))
local LanternPlacement = require(ReplicatedStorage:WaitForChild("LanternPlacement", 10))
local SignPlacement = require(ReplicatedStorage:WaitForChild("SignPlacement", 10))
local WallpaperPlacement = require(ReplicatedStorage:WaitForChild("WallpaperPlacement", 10))
local CarpetPlacement = require(ReplicatedStorage:WaitForChild("CarpetPlacement", 10))
local VinePlacement = require(ReplicatedStorage:WaitForChild("VinePlacement", 10))
local ColumnPlacement = require(ReplicatedStorage:WaitForChild("ColumnPlacement", 10))
local BlockSpatialIndex = require(ReplicatedStorage:WaitForChild("BlockSpatialIndex", 10))
local ColorPalette = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("ColorPalette"))
local BulkOperationFlags = require(ReplicatedStorage:WaitForChild("BulkOperationFlags", 10))

-- Glass debug levels: 0=off, 1=summary, 2=verbose
local DEBUG_GLASS_LEVEL = 0

-- Wait for terrain generator and weather manager
local TerrainGenerator = nil
local BiomeConfig = nil
local WeatherManager = nil
local BetaPlayerManager = nil
local SaplingHandler = nil
task.spawn(function()
	local modulesFolder = ServerScriptService:WaitForChild("Modules", 10)
	if modulesFolder then
		TerrainGenerator = require(modulesFolder:WaitForChild("TerrainGenerator", 10))
		
		-- Load WeatherManager for weather restoration
		pcall(function()
			WeatherManager = require(modulesFolder:WaitForChild("WeatherManager", 5))
		end)
		
		-- Load BetaPlayerManager for beta tester qualification
		pcall(function()
			BetaPlayerManager = require(modulesFolder:WaitForChild("BetaPlayerManager", 5))
		end)
	end
	
	-- Load BiomeConfig for color restoration
	pcall(function()
		BiomeConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("BiomeConfig"))
	end)
	
	-- Load SaplingHandler for sapling timer restoration (via _G since it's a server script)
	-- Wait for it to be available (with shorter retry loop)
	task.spawn(function()
		for i = 1, 10 do -- Try for up to 5 seconds
			task.wait(0.5)
			if _G.SaplingHandler then
				SaplingHandler = _G.SaplingHandler
				return
			end
		end
		warn("[SaveManager] SaplingHandler not found after 5 seconds!")
	end)
end)

-- In-memory cache for player metadata (avoids repeated DataStore reads)
local PlayerMetaCache = {} -- { [userId] = meta }

-- Get DataStore (wrapped in pcall for Studio testing)
local PlotDataStore = nil
local LegacyDataStore = nil

local function getDataStore()
	if PlotDataStore then return PlotDataStore end
	
	local success, result = pcall(function()
		return DataStoreService:GetDataStore(DATASTORE_NAME)
	end)
	
	if success then
		PlotDataStore = result
		return PlotDataStore
	else
		warn("[SaveManager] Failed to get DataStore: " .. tostring(result))
		return nil
	end
end

local function getLegacyDataStore()
	if LegacyDataStore then return LegacyDataStore end
	
	local success, result = pcall(function()
		return DataStoreService:GetDataStore(LEGACY_DATASTORE_NAME)
	end)
	
	if success then
		LegacyDataStore = result
		return LegacyDataStore
	end
	return nil
end

-- Track last save time per player (for cooldown)
local LastSaveTime = {}

-- Track dirty plots (plots that have unsaved changes)
local DirtyPlots = {}

-- Track players who have been saved during shutdown (prevents duplicate saves)
local SavedDuringShutdown = {}

-- Track players who have been saved on leave (prevents cleanup racing with save)
local SavedOnLeave = {}

-- Track current active slot per player
local PlayerActiveSlot = {}

-- Track whether a player's plot has been successfully loaded. SAVING IS REFUSED
-- if this flag is not true. Prevents the "transient load failure -> autosave
-- wipes the good save" bug.
local LoadSucceeded = {}

-- ============================================
-- DATASTORE RETRY HELPER
-- ============================================
-- Wraps a DataStore operation in retry-with-backoff. Returns (success, result).
-- On success, result is whatever the op returned (e.g. GetAsync's value).
-- On failure after all attempts, result is the last error message.
local function retryDataStore(op, maxAttempts, label)
	maxAttempts = maxAttempts or 3
	label = label or "op"
	local lastErr = nil
	for attempt = 1, maxAttempts do
		local success, result = pcall(op)
		if success then
			return true, result
		end
		lastErr = result
		if attempt < maxAttempts then
			local backoff = 0.5 * (2 ^ (attempt - 1))
			warn(string.format("[SaveManager] DataStore %s failed (attempt %d/%d): %s. Retrying in %.1fs...",
				label, attempt, maxAttempts, tostring(result), backoff))
			task.wait(backoff)
		end
	end
	return false, lastErr
end

-- Build the backup key for a slot. Backup is a parallel companion to the
-- primary slot key, written after every successful primary save.
local function getSlotBackupKey(userId, slotNumber)
	return "slot_" .. userId .. "_" .. slotNumber .. "_backup"
end

-- Create remotes (with race condition prevention)
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)

-- Use a single-shot check to prevent race conditions
local function getOrCreateRemote(name, className)
	className = className or "RemoteEvent"
	local existing = Remotes:FindFirstChild(name)
	if existing then
		return existing
	end
	
	-- Small yield to let other scripts finish creating
	task.wait()
	
	-- Check again after yield
	existing = Remotes:FindFirstChild(name)
	if existing then
		return existing
	end
	
	-- Create if still doesn't exist
	local remote
	if className == "RemoteFunction" then
		remote = Instance.new("RemoteFunction")
	else
		remote = Instance.new("RemoteEvent")
	end
	remote.Name = name
	remote.Parent = Remotes
	return remote
end

-- Check for duplicate remotes (debugging)
local function checkForDuplicateRemotes()
	local remoteNames = {"SavePlot", "LoadPlot", "SaveLoadResult", "OpenSaveLoadUI", "GetSlotInfo", "DeleteSlot", "PurchaseSlot", "PurchaseSlotWithCoins"}
	for _, name in ipairs(remoteNames) do
		local count = 0
		for _, child in ipairs(Remotes:GetChildren()) do
			if child.Name == name then
				count = count + 1
			end
		end
		if count > 1 then
			warn("[SaveManager] DUPLICATE REMOTE FOUND: " .. name .. " (count: " .. count .. ")")
			-- Remove duplicates, keep only the first one
			local foundFirst = false
			for _, child in ipairs(Remotes:GetChildren()) do
				if child.Name == name then
					if foundFirst then
						child:Destroy()
					else
						foundFirst = true
					end
				end
			end
		end
	end
end

local SavePlot = getOrCreateRemote("SavePlot")
local LoadPlot = getOrCreateRemote("LoadPlot")
local SaveLoadResult = getOrCreateRemote("SaveLoadResult")
local OpenSaveLoadUI = getOrCreateRemote("OpenSaveLoadUI")
local GetSlotInfo = getOrCreateRemote("GetSlotInfo", "RemoteFunction")
local DeleteSlot = getOrCreateRemote("DeleteSlot")
local PurchaseSlot = getOrCreateRemote("PurchaseSlot")
local PurchaseSlotWithCoins = getOrCreateRemote("PurchaseSlotWithCoins")
local RenameSlot = getOrCreateRemote("RenameSlot")
local ImportLegacy = getOrCreateRemote("ImportLegacy")
local PlotClearing = getOrCreateRemote("PlotClearing")  -- Notify clients when plot is being cleared/loaded
-- Seed the client's dug-position set at load time so its terrain prediction never spawns
-- phantom blocks into saved holes. Same remote the BlockHandler uses for after-the-fact
-- cleanup; ClientPrediction's handler marks each position dug and removes any prediction
-- there. getOrCreateRemote is idempotent: returns BlockHandler's instance if it already
-- made one, otherwise creates the shared remote here (order-independent).
local TerrainDugPositions = getOrCreateRemote("TerrainDugPositions")

-- Check for and remove any duplicate remotes
checkForDuplicateRemotes()

local BLOCK_SIZE = GridConfig.BLOCK_SIZE

-- ============================================
-- LOAD PERFORMANCE OPTIMIZATION
-- ============================================
-- Budget-based yielding: instead of yielding every N items (wastes ~16ms per yield),
-- measure elapsed time and only yield when approaching frame budget limit.
local LOAD_FRAME_BUDGET = 0.008 -- 8ms per frame for normal operations
local LOAD_FRAME_BUDGET_FAST = 0.020 -- 20ms per frame during bulk loading (faster load, brief stutter OK)

local function shouldYield(lastYieldTime)
	return os.clock() - lastYieldTime >= LOAD_FRAME_BUDGET
end

local function budgetYield(lastYieldTime)
	if os.clock() - lastYieldTime >= LOAD_FRAME_BUDGET then
		task.wait()
		return os.clock()
	end
	return lastYieldTime
end

-- Faster budget yield for bulk block loading (allows more work per frame)
local function budgetYieldFast(lastYieldTime)
	if os.clock() - lastYieldTime >= LOAD_FRAME_BUDGET_FAST then
		task.wait()
		return os.clock()
	end
	return lastYieldTime
end

-- ============================================
-- DATASTORE KEY HELPERS
-- ============================================

local function getMetaKey(userId)
	return "meta_" .. tostring(userId)
end

local function getSlotKey(userId, slotNumber)
	return "slot_" .. tostring(userId) .. "_" .. tostring(slotNumber)
end

local function getLegacyKey(userId)
	return "plot_" .. tostring(userId)
end

-- ============================================
-- METADATA MANAGEMENT
-- ============================================

-- Get or create player metadata (cached in memory to avoid repeated DataStore reads)
local function getPlayerMeta(userId)
	-- Return cached version if available
	if PlayerMetaCache[userId] then
		return PlayerMetaCache[userId]
	end
	
	local dataStore = getDataStore()
	if not dataStore then
		return nil, "DataStore not available"
	end
	
	local key = getMetaKey(userId)
	local meta = nil
	
	local success, err = retryDataStore(function()
		meta = dataStore:GetAsync(key)
	end, 3, "GetAsync(meta)")
	
	if not success then
		warn(string.format("[SaveManager] getPlayerMeta failed for userId %s after retries: %s", tostring(userId), tostring(err)))
		return nil, "DataStore error: " .. tostring(err)
	end
	
	-- Create default metadata if none exists
	if not meta then
		meta = {
			version = 1,
			maxSlots = DEFAULT_MAX_SLOTS,
			activeSlot = 1,
			slots = {},  -- Slot info: { [slotNum] = { name, blockCount, lastSaved, biome } }
		}
	end
	
	-- Cache it for future calls
	PlayerMetaCache[userId] = meta
	return meta
end

-- Save player metadata
local function savePlayerMeta(userId, meta)
	-- Always update the cache immediately
	PlayerMetaCache[userId] = meta
	
	local dataStore = getDataStore()
	if not dataStore then
		return false, "DataStore not available"
	end
	
	local key = getMetaKey(userId)
	local success, err = retryDataStore(function()
		dataStore:SetAsync(key, meta)
	end, 3, "SetAsync(meta)")
	
	if not success then
		warn(string.format("[SaveManager] savePlayerMeta FAILED for userId %s: %s -- slot UI may be stale until next successful save", tostring(userId), tostring(err)))
	end
	
	return success, err
end

-- ============================================
-- LEGACY SAVE MIGRATION
-- ============================================

local function migrateLegacySave(player)
	local legacyStore = getLegacyDataStore()
	if not legacyStore then
		return false, "Legacy DataStore not available"
	end
	
	local legacyKey = getLegacyKey(player.UserId)
	local legacyData = nil
	
	local success, err = pcall(function()
		legacyData = legacyStore:GetAsync(legacyKey)
	end)
	
	if not success or not legacyData then
		return false, "No legacy save found"
	end
	
	-- Get or create metadata
	local meta = getPlayerMeta(player.UserId)
	if not meta then
		meta = {
			version = 1,
			maxSlots = DEFAULT_MAX_SLOTS,
			activeSlot = 1,
			slots = {},
		}
	end
	
	-- Save legacy data to slot 1
	local dataStore = getDataStore()
	if not dataStore then
		return false, "DataStore not available"
	end
	
	local slotKey = getSlotKey(player.UserId, 1)
	local saveSuccess, saveErr = pcall(function()
		dataStore:SetAsync(slotKey, legacyData)
	end)
	
	if not saveSuccess then
		return false, "Failed to migrate: " .. tostring(saveErr)
	end
	
	-- Update metadata
	meta.slots[1] = {
		name = "Migrated Save",
		blockCount = legacyData.blocks and #legacyData.blocks or 0,
		lastSaved = os.time(),
		biome = legacyData.biome or "Plains",
	}
	meta.activeSlot = 1
	
	savePlayerMeta(player.UserId, meta)
	
	return true, 1  -- Return success and slot number
end

-- ============================================
-- BIOME COLOR RESTORATION
-- ============================================

-- Apply biome grass color to a grass block (for lazy-loaded blocks on load)
-- seasonName is optional - applies seasonal tint if provided
local function applyBiomeGrassColor(block, biomeName, seasonName)
	if not BiomeConfig then return end
	if not biomeName then return end
	
	local biomeColors = BiomeConfig.GetBiomeColors(biomeName)
	if not biomeColors or not biomeColors.GrassColor then return end
	
	-- Apply random variation for more natural look (with optional season tint)
	local grassColor = BiomeConfig.GetRandomizedGrassColor(biomeColors.GrassColor, seasonName)
	
	-- Find the "Grass" part inside the model and tint it
	if block:IsA("Model") then
		local grassPart = block:FindFirstChild("Grass")
		if grassPart and grassPart:IsA("BasePart") then
			grassPart.Color = grassColor
		end
	elseif block:IsA("BasePart") then
		block.Color = grassColor
	end
end

-- Apply biome color to grass decorations (ShortGrass, TallGrass)
local function applyBiomeDecorationColor(decoration, decorationType, biomeName, seasonName)
	if not BiomeConfig then return end
	if not biomeName then return end
	
	-- Only tint grass-type decorations
	if decorationType ~= "ShortGrass" and decorationType ~= "TallGrass" then return end
	
	local biomeColors = BiomeConfig.GetBiomeColors(biomeName)
	if not biomeColors or not biomeColors.GrassColor then return end
	
	-- Use DecorationMultiplier for grass decorations (matches grass blocks)
	local baseColor = biomeColors.GrassColor
	local decorationColor = BiomeConfig.GetSeasonalDecorationColor(baseColor, seasonName)
	
	-- Apply very slight random brightness variation
	local h, s, v = Color3.toHSV(decorationColor)
	local valVariation = (math.random() - 0.5) * 0.03  -- ±1.5% brightness only
	local finalColor = Color3.fromHSV(h, s, math.clamp(v + valVariation, 0.3, 1))
	
	-- Tint all parts in the decoration
	if decoration:IsA("BasePart") then
		decoration.Color = finalColor
	elseif decoration:IsA("Model") then
		for _, part in ipairs(decoration:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Color = finalColor
			end
		end
	end
end

-- ============================================
-- HELPER FUNCTIONS
-- ============================================

local function getPlayerBuildArea(player)
	for i = 1, GridConfig.TOTAL_PLOTS do
		local buildArea = workspace:FindFirstChild(GridConfig.BUILD_AREA_PREFIX .. i)
		if buildArea and buildArea:GetAttribute("OwnerUserId") == player.UserId then
			return buildArea, i
		end
	end
	return nil, nil
end

-- Get block templates folder
local function getBlockTemplates()
	return ReplicatedStorage:FindFirstChild("BlockTemplates")
end

local function getBlocksFolder()
	return ReplicatedStorage:FindFirstChild("Blocks")
end

local function getDecorationsFolder()
	return ReplicatedStorage:FindFirstChild("Decorations")
end

local function getPlotNumberFromBuildArea(buildArea)
	local name = buildArea.Name
	if name == "MegaPlotBuildArea" then return 0 end
	local num = name:match("%d+")
	return num and tonumber(num) or nil
end

-- ============================================
-- SAVE FUNCTION (with slot support)
-- ============================================

local function savePlotToSlot(player, buildArea, slotNumber)
	-- GUARD: Refuse to save if the plot was never successfully loaded for this player.
	-- This is the primary defense against the "transient load failure -> autosave
	-- wipes the good save" bug. If the GetAsync at join time failed, LoadSucceeded
	-- will be falsy and we MUST NOT proceed -- the build area only contains the
	-- post-failure fresh terrain, and saving it would clobber the real save.
	if not LoadSucceeded[player.UserId] then
		warn(string.format("[SaveManager] CORRUPTION GUARD: Refusing save for %s slot %d -- plot was never successfully loaded this session. Previous save preserved.",
			player.Name, slotNumber))
		return false, "Save refused: plot data was not loaded this session. Your previous save is safe -- please rejoin to reload."
	end

	local dataStore = getDataStore()
	if not dataStore then
		return false, "DataStore not available"
	end
	
	-- Get metadata to validate slot
	local meta = getPlayerMeta(player.UserId)
	if not meta then
		return false, "Could not load player data"
	end
	
	-- Validate slot number
	if slotNumber < 1 or slotNumber > meta.maxSlots then
		return false, "Invalid slot number (max: " .. meta.maxSlots .. ")"
	end
	
	-- Check cooldown
	local lastSave = LastSaveTime[player.UserId] or 0
	local now = tick()
	if now - lastSave < SAVE_COOLDOWN then
		local remaining = math.ceil(SAVE_COOLDOWN - (now - lastSave))
		return false, "Please wait " .. remaining .. " seconds before saving again"
	end
	
	-- Serialize plot
	local saveData, serializeError = PlotSerializer.SerializePlot(buildArea, BLOCK_SIZE)
	if not saveData then
		return false, "Failed to serialize: " .. tostring(serializeError)
	end
	
	-- Include removed terrain-generated blocks (trees, decorations, cactus, fallen logs)
	-- These are tracked in TerrainGenerator when the player breaks non-PlacedBy blocks
	local plotNumber = getPlotNumberFromBuildArea(buildArea)
	if plotNumber and TerrainGenerator then
		local removedRaw = TerrainGenerator.GetRemovedGeneratedBlocks(plotNumber)
		if #removedRaw > 0 and saveData.origin then
			local removedRelative = {}
			local ox, oy, oz = saveData.origin.x, saveData.origin.y, saveData.origin.z
			for _, entry in ipairs(removedRaw) do
				if entry.kind == "deco" and entry.parentX then
					table.insert(removedRelative, {
						k = "d", -- deco
						t = entry.blockType,
						x = math.round((entry.parentX - ox) / BLOCK_SIZE),
						y = math.round((entry.parentY - oy) / BLOCK_SIZE),
						z = math.round((entry.parentZ - oz) / BLOCK_SIZE),
					})
				elseif entry.posX then
					table.insert(removedRelative, {
						k = "t", -- tree/cactus/log
						t = entry.blockType,
						x = math.round((entry.posX - ox) / BLOCK_SIZE),
						y = math.round((entry.posY - oy) / BLOCK_SIZE),
						z = math.round((entry.posZ - oz) / BLOCK_SIZE),
					})
				end
			end
			if #removedRelative > 0 then
				saveData.removedBlocks = removedRelative
			end
		end
	end
	
	-- Check size
	local size = PlotSerializer.EstimateSize(saveData)
	if size > PlotSerializer.MAX_SIZE then
		return false, "Save data too large: " .. math.floor(size / 1000) .. "KB (max 3500KB)"
	end
	
	-- CORRUPTION GUARD: Refuse to save if the serializer returned 0 blocks but the
	-- Blocks folder has player-placed blocks. This indicates a serializer error or
	-- mid-operation race -- saving the empty payload would wipe the player's work.
	if #saveData.blocks == 0 then
		local blocksFolder = buildArea:FindFirstChild("Blocks")
		local totalChildren = blocksFolder and #blocksFolder:GetChildren() or 0
		local playerPlaced = 0
		if blocksFolder then
			for _, child in ipairs(blocksFolder:GetChildren()) do
				if child:GetAttribute("PlacedBy") and not child:GetAttribute("IsTerrainBlock") then
					playerPlaced = playerPlaced + 1
				end
			end
		end
		if playerPlaced > 0 then
			warn(string.format("[SaveManager] CORRUPTION GUARD: Refusing save -- serializer returned 0 blocks but folder has %d player-placed blocks (%d total children). Previous save preserved.",
				playerPlaced, totalChildren))
			return false, "Save refused: serializer produced 0 blocks for a non-empty plot. Your previous save is safe."
		end
	end
	
	-- Save to DataStore (with retry on transient failures)
	local key = getSlotKey(player.UserId, slotNumber)
	local success, err = retryDataStore(function()
		dataStore:SetAsync(key, saveData)
	end, 3, "SetAsync(primary slot " .. slotNumber .. ")")
	
	if success then
		-- Best-effort backup write. Failure here does NOT fail the save -- the
		-- primary save already succeeded. The backup gives us a recovery point
		-- if the primary key gets corrupted by a future bad write.
		local backupKey = getSlotBackupKey(player.UserId, slotNumber)
		local backupSuccess, backupErr = retryDataStore(function()
			dataStore:SetAsync(backupKey, saveData)
		end, 2, "SetAsync(backup slot " .. slotNumber .. ")")
		if not backupSuccess then
			warn(string.format("[SaveManager] Backup write failed for %s slot %d (primary OK): %s",
				player.Name, slotNumber, tostring(backupErr)))
		end
		
		LastSaveTime[player.UserId] = now
		DirtyPlots[player.UserId] = false
		PlayerActiveSlot[player.UserId] = slotNumber
		
		local blockCount = #saveData.blocks
		local lifetimeBlocks = saveData.lifetimeBlocksPlaced or 0
		
		-- Update metadata (preserve existing name if set)
		local existingSlot = meta.slots[slotNumber]
		local slotName = (existingSlot and existingSlot.name) or ("Slot " .. slotNumber)
		meta.slots[slotNumber] = {
			name = slotName,
			blockCount = blockCount,
			lastSaved = os.time(),
			biome = saveData.biome or "Plains",
			terrainStyle = saveData.terrainStyle or "Flat",
		}
		meta.activeSlot = slotNumber
		savePlayerMeta(player.UserId, meta)
		return true, blockCount, lifetimeBlocks
	else
		warn("[SaveManager] Save failed for " .. player.Name .. ": " .. tostring(err))
		return false, "DataStore error: " .. tostring(err)
	end
end

-- Legacy save function for backwards compatibility
local function savePlot(player, buildArea)
	local activeSlot = PlayerActiveSlot[player.UserId] or 1
	return savePlotToSlot(player, buildArea, activeSlot)
end

-- ============================================
-- LOAD FUNCTION (with slot support)
-- ============================================

-- Add invisible hitbox for non-full blocks (so raycasts can select them)
local function addBlockHitbox(block, gridPosition)
	if block:FindFirstChild("Hitbox") then return end
	local hitbox = Instance.new("Part")
	hitbox.Name = "Hitbox"
	hitbox.Anchored = true
	hitbox.CanCollide = false
	hitbox.CanQuery = true
	hitbox.CanTouch = false
	hitbox.CastShadow = false
	hitbox.Transparency = 1
	hitbox.Size = Vector3.new(BLOCK_SIZE, BLOCK_SIZE, BLOCK_SIZE)
	hitbox.CFrame = CFrame.new(gridPosition)
	hitbox.Parent = block
end

-- Create a block from save data
-- originOffset: Vector3 containing the fractional offset to add to grid-aligned positions
local function createBlockFromSave(blockData, blocksFolder, placedByUserId, originOffset, templateCtx)
	-- Use cached template references to avoid repeated FindFirstChild calls
	local BlockTemplates = templateCtx and templateCtx.BlockTemplates or getBlockTemplates()
	local BlocksSourceFolder = templateCtx and templateCtx.BlocksSourceFolder or getBlocksFolder()
	local DecorationsSourceFolder = templateCtx and templateCtx.DecorationsSourceFolder or getDecorationsFolder()
	
	local preset = BlockPresets.GetPreset(blockData.blockType)
	if not preset then
		-- FilledFence has no inventory preset - use a minimal fallback
		if blockData.blockType == "FilledFence" and blockData.attributes.FenceConnectionType then
			preset = { Shape = "Block", DefaultColor = Color3.fromRGB(128,128,128), Material = Enum.Material.Plastic, IsFence = true }
		else
			warn("[SaveManager] Unknown block type: " .. blockData.blockType)
			return nil
		end
	end
	
	local shapeData = BlockPresets.GetShape(preset.Shape)
	if not shapeData then
		warn("[SaveManager] Unknown shape: " .. preset.Shape)
		return nil
	end
	
	-- Calculate world position from grid position
	-- Apply origin offset to account for terrain grid not being aligned to world grid
	local offset = originOffset or Vector3.zero
	local worldPos = Vector3.new(
		blockData.gridX * BLOCK_SIZE + offset.X,
		blockData.gridY * BLOCK_SIZE + offset.Y,
		blockData.gridZ * BLOCK_SIZE + offset.Z
	)
	
	-- Determine template to use
	local templateName = shapeData.TemplateName
	local template = nil
	local usedBlockModel = false
	
	-- Check for special corner types for stairs/arches
	local cornerType = blockData.attributes.CornerType
	local isFrameBlock = blockData.attributes.IsFrameBlock or BlockPresets.IsFrameBlock(blockData.blockType)
	local isArchBlock = blockData.attributes.IsArch or StairPlacement.IsArchType(blockData.blockType)
	if cornerType == "inner" then
		if isArchBlock then
			local archTemplates = StairPlacement.GetArchTemplateNames(blockData.blockType)
			templateName = archTemplates.Inner
		else
			templateName = "StairInnerCorner"
		end
	elseif cornerType == "outer" then
		if isArchBlock then
			local archTemplates = StairPlacement.GetArchTemplateNames(blockData.blockType)
			templateName = archTemplates.Outer
		else
			templateName = "StairOuterCorner"
		end
	end
	
	-- Check for fence connection types
	local fenceType = blockData.attributes.FenceConnectionType
	if fenceType then
		local fenceTemplateMap = {
			["post"] = "FencePost",
			["end"] = "FenceEnd",
			["middle"] = "FenceMiddle",
			["corner"] = "FenceCorner",
			["tee"] = "FenceMiddleCorner",
			["cross"] = "FenceMiddleFour",
		}
		templateName = fenceTemplateMap[fenceType] or "FencePost"
	end
	
	-- Check for glass - simplified system uses Glass_0 for flat panes, but special
	-- connections (corner/tee/4way) use their own templates based on saved orientation.
	local isGlass = blockData.attributes.IsGlass or GlassPlacement.IsGlass(blockData.blockType)
	if isGlass then
		local savedOrient = blockData.attributes.GlassOrientation
		if savedOrient == "corner" then
			templateName = "Glass_Corner"
		elseif savedOrient == "tee" then
			templateName = "Glass_Tee"
		elseif savedOrient == "4way" then
			templateName = "Glass_4_Way"
		else
			templateName = "Glass_0"
		end
	end
	
	-- Check for column - use saved model name (ColumnSingle, ColumnBottom, Column, ColumnTop)
	local isColumn = blockData.attributes.IsColumn or (BlockPresets.IsColumn and BlockPresets.IsColumn(blockData.blockType))
	local columnModelName = blockData.attributes.ColumnModelName or "ColumnSingle"
	
	-- Check for chest type (needed early for template selection)
	local isChest = BlockPresets.IsChest and BlockPresets.IsChest(blockData.blockType)
	
	-- Check for bed type
	local isBed = BlockPresets.IsBed and BlockPresets.IsBed(blockData.blockType)
	
	-- Check for crafting table type
	local isCraftingTable = BlockPresets.IsCraftingTable and BlockPresets.IsCraftingTable(blockData.blockType)
	
	-- Check for architrave - use saved model name directly (like columns)
	local isArchitrave = blockData.attributes.IsArchitrave or (BlockPresets.IsArchitrave and BlockPresets.IsArchitrave(blockData.blockType))
	local architraveModelName = blockData.attributes.ArchitraveModelName or "ArchitraveSingle"
	
	-- Check for torch - use saved model name (TorchStraight or TorchAngled)
	local isTorch = blockData.attributes.IsTorch or TorchPlacement.IsTorch(blockData.blockType)
	local torchModelName = blockData.attributes.TorchModelName or "TorchStraight"
	
	-- Check for signs
	local isSignStanding = blockData.attributes.IsSignStanding or (BlockPresets.IsSignStanding and BlockPresets.IsSignStanding(blockData.blockType))
	local isWallSign = blockData.attributes.IsWallSign or (BlockPresets.IsWallSign and BlockPresets.IsWallSign(blockData.blockType))
	local isSign = isSignStanding or isWallSign
	local signModelName = blockData.attributes.SignModelName
	
	-- Check if decoration
	if preset.IsDecoration then
		if DecorationsSourceFolder then
			template = DecorationsSourceFolder:FindFirstChild(preset.DecorationName or blockData.blockType)
		end
	elseif fenceType then
		-- FENCES: Check if this is an unfilled frame fence (needs FrameBlocks folder)
		local isUnfilledFrameFence = (blockData.blockType == "FrameFence") and not blockData.attributes.FrameFillBlockId
		if isUnfilledFrameFence then
			local frameBlocksFolder = ReplicatedStorage:FindFirstChild("FrameBlocks")
			local frameFenceTemplates = {
				["post"] = "FencePostFrame",
				["end"] = "FenceEndFrame",
				["middle"] = "FenceMiddleFrame",
				["corner"] = "FenceCornerFrame",
				["tee"] = "FenceMiddleCornerFrame",
				["cross"] = "FenceMiddleFourFrame",
			}
			local frameTemplateName = frameFenceTemplates[fenceType] or "FencePostFrame"
			if frameBlocksFolder then
				template = frameBlocksFolder:FindFirstChild(frameTemplateName)
			end
			usedBlockModel = false
		else
			-- Regular fence or filled frame fence: use solid templates from BlockTemplates
			if BlockTemplates then
				template = BlockTemplates:FindFirstChild(templateName)
				usedBlockModel = false
			end
		end
	elseif isGlass then
		-- GLASS: Resolve template from the glass-type registry. Standard glass uses
		-- Decorations/Glass; CandyLattice uses RewardSets/CandyBlocks. templateName is
		-- the generic shape (Glass_0 / Glass_Corner / Glass_Tee / Glass_4_Way).
		template = resolveGlassTemplate(blockData.blockType, templateName)
		if template then
			usedBlockModel = false
		end
	elseif isTorch then
		-- TORCH: Use template from Lights folder based on saved model name
		local lightsFolder = ReplicatedStorage:FindFirstChild("Lights")
		if lightsFolder then
			template = lightsFolder:FindFirstChild(torchModelName)
			usedBlockModel = true
		end
	elseif isColumn then
		-- COLUMN: Use template from Blocks folder based on saved model name
		if BlocksSourceFolder then
			template = BlocksSourceFolder:FindFirstChild(columnModelName)
			usedBlockModel = true
		end
	elseif isArchitrave then
		-- ARCHITRAVE: Use template from Architraves folder based on saved connection type
		local archFolder = ReplicatedStorage:FindFirstChild("Architraves")
		if archFolder then
			template = archFolder:FindFirstChild(architraveModelName)
			usedBlockModel = true
		end
	elseif isSign then
		-- SIGN: Use template from BlockTemplates based on saved model name
		if BlockTemplates and signModelName then
			template = BlockTemplates:FindFirstChild(signModelName)
			usedBlockModel = false
		end
	elseif isChest then
		-- CHEST: Use template from BlockTemplates (SingleChest or DoubleChest)
		if BlockTemplates then
			local chestModelName = "SingleChest"
			if blockData.attributes.IsDoubleChest then
				chestModelName = "DoubleChest"
			end
			template = BlockTemplates:FindFirstChild(chestModelName)
			usedBlockModel = false
		end
	elseif isBed then
		-- BED: Use template from BlockTemplates
		if BlockTemplates then
			template = BlockTemplates:FindFirstChild("Bed")
			usedBlockModel = false
		end
	elseif isCraftingTable then
		-- CRAFTING TABLE: Use template from BlockTemplates
		if BlockTemplates then
			template = BlockTemplates:FindFirstChild("CraftingTable")
			usedBlockModel = false
		end
	elseif isFurnace then
		-- FURNACE: Use template from BlockTemplates
		if BlockTemplates then
			template = BlockTemplates:FindFirstChild("Furnace")
			usedBlockModel = false
		end
	else
		-- IMPORTANT: Match BlockHandler's logic - ALWAYS try Blocks folder first!
		if BlocksSourceFolder then
			template = BlocksSourceFolder:FindFirstChild(blockData.blockType)
			if template then
				usedBlockModel = true
			end
		end
		
		-- Then try blockModelName if specified
		if not template and preset.BlockModelName and BlocksSourceFolder then
			template = BlocksSourceFolder:FindFirstChild(preset.BlockModelName)
			if template then
				usedBlockModel = true
			end
		end
	end
	
	-- If this is a FILLED frame block, use the solid template instead of the frame model
	local FrameToSolidTemplate = {
		["FrameBlock"] = "Block",
		["FrameSlab"] = "Slab",
		["FrameStairs"] = "Stair",
		["FrameStairsCornerInner"] = "StairInnerCorner",
		["FrameStairsCornerOuter"] = "StairOuterCorner",
		["FrameDoor"] = "FramedDoorFilled",
		["WallpaperFrame"] = "WallpaperTemplate",
		["SignStandingFrame"] = "SignStanding",
		["SignFrame"] = "Sign",
		["CarpetFrame"] = "Block",
		["ArchFrame"] = "Arch",
		["ArchInnerFrame"] = "ArchInner",
		["ArchOuterFrame"] = "ArchOuter",
		["ArchLargeFrame"] = "ArchLarge",
		["ArchLargeInnerFrame"] = "ArchLargeInner",
		["ArchLargeOuterFrame"] = "ArchLargeOuter",
	}
	if blockData.attributes.FrameFillBlockId and isFrameBlock then
		local solidName = FrameToSolidTemplate[blockData.blockType]
		-- For frame stairs, check corner type
		if blockData.blockType == "FrameStairs" and cornerType then
			if cornerType == "inner" then
				solidName = "StairInnerCorner"
			elseif cornerType == "outer" then
				solidName = "StairOuterCorner"
			end
		end
		-- For frame arches, check corner type
		if (blockData.blockType == "ArchFrame" or blockData.blockType == "ArchLargeFrame") and cornerType then
			local archTemplates = StairPlacement.GetArchTemplateNames(blockData.blockType)
			if cornerType == "inner" then
				solidName = archTemplates.Inner
			elseif cornerType == "outer" then
				solidName = archTemplates.Outer
			end
		end
		if solidName and BlockTemplates then
			template = BlockTemplates:FindFirstChild(solidName)
			usedBlockModel = false
		end
	end
	
	-- If this is an UNFILLED frame stair/arch corner, use FrameBlocks corner model
	if not template and isFrameBlock and cornerType and not blockData.attributes.FrameFillBlockId then
		local frameBlocksFolder = ReplicatedStorage:FindFirstChild("FrameBlocks")
		if frameBlocksFolder then
			local frameCornerName
			if isArchBlock then
				local isLargeArch = StairPlacement.IsArchLargeType(blockData.blockType)
				if isLargeArch then
					frameCornerName = cornerType == "inner" and "ArchLargeInnerFrame" or "ArchLargeOuterFrame"
				else
					frameCornerName = cornerType == "inner" and "ArchInnerFrame" or "ArchOuterFrame"
				end
			else
				frameCornerName = cornerType == "inner" and "FrameStairsCornerInner" or "FrameStairsCornerOuter"
			end
			template = frameBlocksFolder:FindFirstChild(frameCornerName)
			if template then
				usedBlockModel = true
			end
		end
	end
	
	-- Try specific folder (for tools, templates, etc.)
	if not template and preset.BlockModelFolder then
		local folder
		if string.find(preset.BlockModelFolder, "/") then
			local parts = string.split(preset.BlockModelFolder, "/")
			folder = ReplicatedStorage:FindFirstChild(parts[1])
			for i = 2, #parts do
				if folder then
					folder = folder:FindFirstChild(parts[i])
				end
			end
		else
			folder = ReplicatedStorage:FindFirstChild(preset.BlockModelFolder)
		end
		if folder then
			template = folder:FindFirstChild(preset.BlockModelName or templateName)
			if template then
				usedBlockModel = preset.UseBlockModel
			end
		end
	end
	
	-- Fallback to BlockTemplates
	if not template and BlockTemplates then
		template = BlockTemplates:FindFirstChild(templateName)
		usedBlockModel = false
	end
	
	if not template then
		if isChest then
			warn(string.format("[Chest] LOAD FAILED - no template! type=%s isDouble=%s", blockData.blockType, tostring(blockData.attributes.IsDoubleChest)))
		end
		warn("[SaveManager] No template found for: " .. blockData.blockType .. " (" .. templateName .. ")")
		return nil
	end
	
	-- Clone template
	local block = template:Clone()
	block.Name = blockData.blockType
	if isChest then
	end
	
	-- Check if this is a decoration (need this early for CanCollide)
	local isDecorationForCollide = preset.IsDecoration or blockData.attributes.IsDecoration
	
	-- Cache base parts list once (avoids 12+ redundant GetDescendants calls per block)
	local cachedBaseParts = nil
	if block:IsA("Model") then
		cachedBaseParts = {}
		for _, desc in ipairs(block:GetDescendants()) do
			if desc:IsA("BasePart") then
				table.insert(cachedBaseParts, desc)
			end
		end
	end
	
	-- Anchor all parts and handle decoration collision
	if block:IsA("BasePart") then
		block.Anchored = true
		if isDecorationForCollide then
			block.CanCollide = false
		end
	elseif cachedBaseParts then
		for _, part in ipairs(cachedBaseParts) do
			part.Anchored = true
			if isDecorationForCollide then
				part.CanCollide = false
			end
		end
	end
	
	-- Apply position and rotation based on block type
	local rotation = blockData.attributes.Rotation or 0
	local cframe
	
	-- Determine block type for special positioning
	local isStair = string.find(blockData.blockType, "Stair") ~= nil or (blockData.attributes.IsArch == true) or StairPlacement.IsArchType(blockData.blockType)
	local isUpsideDown = blockData.attributes.IsUpsideDown
	local isSlab = string.find(blockData.blockType, "Slab") ~= nil
	local isDoor = string.find(string.lower(blockData.blockType), "door") ~= nil
	local isChest = BlockPresets.IsChest and BlockPresets.IsChest(blockData.blockType)
	local isCraftingTable = BlockPresets.IsCraftingTable and BlockPresets.IsCraftingTable(blockData.blockType)
	local isFurnace = BlockPresets.IsFurnace and BlockPresets.IsFurnace(blockData.blockType)
	local isFence = preset.IsFence or blockData.attributes.FenceConnectionType ~= nil
	local isGlassBlock = blockData.attributes.IsGlass or GlassPlacement.IsGlass(blockData.blockType)
	local isLadder = blockData.attributes.IsLadder or LadderPlacement.IsLadder(blockData.blockType)
	local isTorchBlock = blockData.attributes.IsTorch or TorchPlacement.IsTorch(blockData.blockType)
	local isLanternBlock = blockData.attributes.IsLantern or LanternPlacement.IsLantern(blockData.blockType)
	local isWallpaperFrame = blockData.attributes.IsWallpaperFrame or WallpaperPlacement.IsWallpaperFrame(blockData.blockType)
	local isCarpet = blockData.attributes.IsCarpet or CarpetPlacement.IsCarpet(blockData.blockType)
	local isVine = blockData.attributes.IsVine or VinePlacement.IsVine(blockData.blockType)
	local isDecoration = isDecorationForCollide
	local logAxis = blockData.attributes.LogAxis
	local slabOrientation = blockData.attributes.SlabOrientation
	
	if isDecoration then
		local topOfBlock = worldPos + Vector3.new(0, BLOCK_SIZE / 2, 0)
		local noRotationDecorations = { ["Cactus"] = true }
		local rotation45 = noRotationDecorations[blockData.blockType] and CFrame.new() or CFrame.Angles(0, math.rad(45), 0)
		
		if block:IsA("BasePart") then
			local centerPos = topOfBlock + Vector3.new(0, block.Size.Y / 2, 0)
			cframe = CFrame.new(centerPos) * rotation45
		elseif block:IsA("Model") then
			cframe = CFrame.new(topOfBlock) * rotation45
		end
	elseif isStair then
		local stairRotation = blockData.attributes.Rotation or 0
		if isArchBlock then
			cframe = StairPlacement.GetStairCFrame(worldPos, stairRotation, isUpsideDown)
			-- Arch orientation fix: unfilled frames and solid/filled have different template orientations
			local isUnfilledFrame = isFrameBlock and not blockData.attributes.FrameFillBlockId
			if isUnfilledFrame then
				-- Unfilled frame templates: only straight pieces need X(180)
				if not cornerType or cornerType == "normal" then
					cframe = cframe * CFrame.Angles(math.rad(180), 0, 0)
				end
			else
				-- Solid/filled arch templates: per-case rotation logic.
				-- MUST stay in sync with BlockHandler.server.luau fill code (isArchFill branch).
				if cornerType == "outer" then
					-- Outer: storedRotation +90 (upright) or -90 (upside-down)
					local adjustedRot = isUpsideDown and ((stairRotation - 90) % 360) or ((stairRotation + 90) % 360)
					cframe = StairPlacement.GetStairCFrame(worldPos, adjustedRot, isUpsideDown)
					if isUpsideDown then
						cframe = cframe
							* CFrame.Angles(math.rad(-90), math.rad(-90), 0)
							* CFrame.Angles(0, 0, math.rad(180))
					else
						cframe = cframe * CFrame.Angles(math.rad(90), math.rad(-90), 0)
					end
				elseif cornerType == "inner" then
					-- Inner: storedRotation -90 (upright) or -270 (upside-down)
					local adjustedRot = isUpsideDown and ((stairRotation - 270) % 360) or ((stairRotation - 90) % 360)
					cframe = StairPlacement.GetStairCFrame(worldPos, adjustedRot, isUpsideDown)
					if isUpsideDown then
						cframe = cframe
							* CFrame.Angles(math.rad(90), math.rad(-90), 0)
							* CFrame.Angles(math.rad(180), math.rad(180), 0)
							* CFrame.Angles(0, math.rad(180), 0)
					else
						cframe = cframe
							* CFrame.Angles(math.rad(-90), math.rad(-90), 0)
							* CFrame.Angles(math.rad(180), math.rad(180), 0)
							* CFrame.Angles(math.rad(90), 0, 0)
							* CFrame.Angles(math.rad(90), 0, 0)
					end
				else
					-- Normal (straight) filled arch
					cframe = cframe * CFrame.Angles(0, math.rad(180), 0)
				end
			end
		else
			cframe = StairPlacement.GetStairCFrame(worldPos, stairRotation, isUpsideDown)
			-- Filled outer corner stairs need extra X/Z rotation to align solid template
			if blockData.attributes.FilledOuterCorner then
				cframe = cframe * CFrame.Angles(math.rad(90), 0, math.rad(90))
			end
		end
	elseif logAxis then
		local axisCFrames = {
			["Y"] = CFrame.new(worldPos),
			["X"] = CFrame.new(worldPos) * CFrame.Angles(0, 0, math.rad(90)),
			["Z"] = CFrame.new(worldPos) * CFrame.Angles(math.rad(90), 0, 0),
		}
		cframe = axisCFrames[logAxis] or CFrame.new(worldPos)
	elseif isSlab then
		if slabOrientation then
			cframe = SlabPlacement.GetSlabCFrame(worldPos, slabOrientation)
		else
			cframe = CFrame.new(worldPos + Vector3.new(0, -BLOCK_SIZE / 4, 0))
		end
	elseif isDoor then
		local DoorPlacementModule = require(ReplicatedStorage:WaitForChild("DoorPlacement"))
		local direction = blockData.attributes.DoorDirection or 0
		local depth = blockData.attributes.DoorDepth or "middle"
		local hingeSide = blockData.attributes.DoorHingeSide or "left"
		cframe = DoorPlacementModule.GetDoorCFrame(worldPos, direction, depth, hingeSide)
	elseif isFence then
		local fenceRotation = blockData.attributes.Rotation or 0
		local isFrameFence = blockData.attributes.IsFrameBlock or FencePlacement.IsFrameFence(blockData.blockType)
		-- Filled fence corners: frame corner template has a different base orientation
		-- than the solid corner template (+90° offset). The fill handler compensates at
		-- fill time but the stored Rotation still has the frame’s original value.
		if blockData.blockType == "FilledFence" and blockData.attributes.FenceConnectionType == "corner" then
			fenceRotation = (fenceRotation + 90) % 360
		end
		cframe = FencePlacement.GetFenceCFrame(worldPos, fenceRotation, isFrameFence)
	elseif isGlassBlock then
		local glassOrientation = blockData.attributes.GlassOrientation or "NS"
		local rotationCFrame
		if glassOrientation == "corner" or glassOrientation == "tee" or glassOrientation == "4way" then
			-- Special connection - use stored rotation degrees
			local rotationDegrees = blockData.attributes.GlassRotationDegrees or 0
			rotationCFrame = CFrame.Angles(0, math.rad(rotationDegrees), 0)
		else
			rotationCFrame = GlassPlacement.GetGlassRotation(glassOrientation)
		end
		cframe = GlassPlacement.GetGlassCFrame(worldPos, rotationCFrame)
		-- Restore grid position attributes so RemoveBlock can locate the cell correctly
		block:SetAttribute("BlockPosX", worldPos.X)
		block:SetAttribute("BlockPosY", worldPos.Y)
		block:SetAttribute("BlockPosZ", worldPos.Z)
	elseif isLadder then
		local ladderFace = blockData.attributes.LadderFace or "North"
		cframe = LadderPlacement.GetLadderCFrame(worldPos, ladderFace)
	elseif isVine then
		local vineFace = blockData.attributes.VineFace or "North"
		local vineFlipped = blockData.attributes.VineTrimmedFlipped == true
		cframe = VinePlacement.GetVineCFrame(worldPos, vineFace, vineFlipped)
	elseif isTorchBlock then
		local torchFace = blockData.attributes.TorchFace or "Top"
		cframe = TorchPlacement.GetTorchCFrame(worldPos, torchFace)
	elseif isLanternBlock then
		local lanternOffset = Vector3.new(0, BLOCK_SIZE / 2, 0)
		cframe = CFrame.new(worldPos + lanternOffset)
	elseif isArchitrave then
		local archRotation = blockData.attributes.Rotation or 0
		cframe = CFrame.new(worldPos) * CFrame.Angles(0, math.rad(archRotation), 0)
	elseif isSignStanding then
		-- Standing sign: use saved rotation
		local signRotation = blockData.attributes.SignRotation or 0
		cframe = SignPlacement.GetStandingSignCFrame(worldPos, signRotation)
	elseif isWallSign then
		-- Wall sign: use saved face and fence post flag for flush positioning
		local signFace = blockData.attributes.SignFace or "North"
		local isOnFencePost = blockData.attributes.IsOnFencePost or false
		cframe = SignPlacement.GetWallSignCFrame(worldPos, signFace, isOnFencePost)
		-- Store grid position so subsequent saves use correct position (not visual offset position)
		block:SetAttribute("GridPosX", worldPos.X)
		block:SetAttribute("GridPosY", worldPos.Y)
		block:SetAttribute("GridPosZ", worldPos.Z)
	elseif isWallpaperFrame then
		-- Wallpaper frame: use host block grid center and face to calculate CFrame
		-- IMPORTANT: Use worldPos (reconstructed from grid coords) as the canonical host position.
		-- The saved HostBlock attributes may be rounded to integers (old saves), but worldPos
		-- is always the correct grid center calculated from gridX * BLOCK_SIZE + offset.
		local wallpaperFace = blockData.attributes.WallpaperFace or "Top"
		local hostX = blockData.attributes.HostBlockX
		local hostY = blockData.attributes.HostBlockY
		local hostZ = blockData.attributes.HostBlockZ
		-- Always use worldPos for CFrame (it's the correct grid center)
		cframe = WallpaperPlacement.GetWallpaperCFrame(worldPos, wallpaperFace)
		if not blockData.attributes.FrameFillBlockId then
			-- Unfilled wallpaper: make non-collidable (0.001 thick)
			if block:IsA("BasePart") then
				block.CanCollide = false
			elseif block:IsA("Model") then
				for _, part in ipairs(block:GetDescendants()) do
					if part:IsA("BasePart") then
						part.CanCollide = false
					end
				end
			end
		end
		-- Store correct grid center for serializer and update HostBlock attributes
		block:SetAttribute("BlockPosX", worldPos.X)
		block:SetAttribute("BlockPosY", worldPos.Y)
		block:SetAttribute("BlockPosZ", worldPos.Z)
		block:SetAttribute("HostBlockX", worldPos.X)
		block:SetAttribute("HostBlockY", worldPos.Y)
		block:SetAttribute("HostBlockZ", worldPos.Z)
	elseif blockData.blockType == "SnowLayer" then
		-- SnowLayer: resize based on saved layer count and position at bottom of grid cell
		local snowLayers = blockData.attributes.SnowLayers or 1
		local layerHeight = BLOCK_SIZE / 8 -- 0.375 per layer
		local totalHeight = layerHeight * snowLayers
		if block:IsA("BasePart") then
			block.Size = Vector3.new(BLOCK_SIZE, totalHeight, BLOCK_SIZE)
			block.PivotOffset = CFrame.new(0, -totalHeight / 2, 0)
			block.CanCollide = snowLayers >= 4
		end
		local bottomOfCell = worldPos.Y - BLOCK_SIZE / 2
		local centerY = bottomOfCell + totalHeight / 2
		cframe = CFrame.new(worldPos.X, centerY, worldPos.Z)
		-- Restore stored grid position for spatial index
		block:SetAttribute("BlockPosX", worldPos.X)
		block:SetAttribute("BlockPosY", worldPos.Y)
		block:SetAttribute("BlockPosZ", worldPos.Z)
	elseif isCarpet then
		-- CarpetFrame: position at bottom of grid cell (thin 0.38 stud carpet)
		local carpetHeight = CarpetPlacement.CARPET_HEIGHT
		-- Resize filled carpets (solid Block template) to carpet height
		-- Reset PivotOffset because Block template has pivot at bottom (-1.5),
		-- which is wrong for the resized thin carpet (PivotTo would offset it)
		if block:IsA("BasePart") and blockData.attributes.FrameFillBlockId then
			block.Size = Vector3.new(BLOCK_SIZE, carpetHeight, BLOCK_SIZE)
			block.PivotOffset = CFrame.new()
		end
		cframe = CarpetPlacement.GetCarpetCFrame(worldPos)
		block:SetAttribute("BlockPosX", worldPos.X)
		block:SetAttribute("BlockPosY", worldPos.Y)
		block:SetAttribute("BlockPosZ", worldPos.Z)
	elseif blockData.blockType == "PathBlock" and blockData.attributes.PathYOffset then
		-- Path blocks have a Y offset when created by shovel
		-- Apply the same -BLOCK_SIZE/2 pivot offset that the shovel uses (ToolHandler)
		local pathYOffset = blockData.attributes.PathYOffset
		local raisedPos = worldPos + Vector3.new(0, pathYOffset, 0)
		cframe = CFrame.new(raisedPos - Vector3.new(0, BLOCK_SIZE / 2, 0)) * CFrame.Angles(0, math.rad(rotation), 0)
		-- Mark so the generic model positioning below doesn't apply a second offset
		blockData._skipModelOffset = true
		
		-- Store the raised position for BlockPosX/Y/Z (used by lazy loading position checks)
		block:SetAttribute("BlockPosX", raisedPos.X)
		block:SetAttribute("BlockPosY", raisedPos.Y)
		block:SetAttribute("BlockPosZ", raisedPos.Z)
		-- Restore PathBase attributes (original position before offset - used for save/lazy loading)
		block:SetAttribute("PathBaseX", worldPos.X)
		block:SetAttribute("PathBaseY", worldPos.Y)
		block:SetAttribute("PathBaseZ", worldPos.Z)
		-- Ensure terrain attributes are set for proper handling
		block:SetAttribute("IsTerrainBlock", true)
		block:SetAttribute("IsLazyLoaded", true)
	elseif isChest then
		-- Chest: saved rotation + visual offsets (sit on cell floor + center behind latch)
		local chestRotation = blockData.attributes.Rotation or 0
		local chestCenter = worldPos
		local isDouble = blockData.attributes.IsDoubleChest
		-- Double chests: position at midpoint between primary and secondary cells.
		-- Secondary is now stored ORIGIN-RELATIVE (csx/csy/csz) and reconstructed with the
		-- same transform as the primary worldPos, so it re-bases correctly at any origin.
		-- Legacy saves only have absolute ChestSecondaryX/Y/Z; for those we recover the
		-- offset direction from the saved rotation (cells are always one block apart along
		-- the facing axis) so the chest still lands inside the plot.
		local secondaryWorldPos = nil
		if isDouble then
			local relSecX = blockData.attributes.csx
			local relSecY = blockData.attributes.csy
			local relSecZ = blockData.attributes.csz
			if relSecX and relSecY and relSecZ then
				-- New relative format: same transform as primary worldPos
				secondaryWorldPos = Vector3.new(
					relSecX * BLOCK_SIZE + offset.X,
					relSecY * BLOCK_SIZE + offset.Y,
					relSecZ * BLOCK_SIZE + offset.Z
				)
			elseif blockData.attributes.ChestSecondaryX then
				-- Legacy absolute format: reconstruct from primary + rotation axis. The two
				-- cells differ by one BLOCK_SIZE along X (rot 0/180) or Z (rot 90/270); recover
				-- the sign from the stale absolute pair (their delta is origin-independent).
				local legSecX = blockData.attributes.ChestSecondaryX
				local legSecZ = blockData.attributes.ChestSecondaryZ
				local legPrimX = blockData.attributes.BlockPosX
				local legPrimZ = blockData.attributes.BlockPosZ
				local rotNorm = chestRotation % 360
				local axisIsX = (rotNorm == 0 or rotNorm == 180)
				local sign = 1
				if legPrimX and legPrimZ then
					if axisIsX then
						sign = (legSecX - legPrimX) >= 0 and 1 or -1
					else
						sign = (legSecZ - legPrimZ) >= 0 and 1 or -1
					end
				end
				local delta = axisIsX and Vector3.new(sign * BLOCK_SIZE, 0, 0) or Vector3.new(0, 0, sign * BLOCK_SIZE)
				secondaryWorldPos = worldPos + delta
			end
		end
		if isDouble and secondaryWorldPos then
			chestCenter = (worldPos + secondaryWorldPos) / 2
		else
		end
		cframe = CFrame.new(chestCenter) * CFrame.Angles(0, math.rad(chestRotation), 0) * CFrame.new(0, 0, 0.15)
		-- Store clean grid position so next save cycle doesn't drift
		block:SetAttribute("BlockPosX", worldPos.X)
		block:SetAttribute("BlockPosY", worldPos.Y)
		block:SetAttribute("BlockPosZ", worldPos.Z)
		-- Re-write the live secondary attributes to the CORRECTED world coords so that
		-- split-on-break and the next save use accurate positions (the generic attribute
		-- loop below would otherwise restore stale/relative values).
		if isDouble and secondaryWorldPos then
			block:SetAttribute("ChestSecondaryX", secondaryWorldPos.X)
			block:SetAttribute("ChestSecondaryY", secondaryWorldPos.Y)
			block:SetAttribute("ChestSecondaryZ", secondaryWorldPos.Z)
		end
	elseif isBed then
		-- Bed: saved rotation, Y offset to sit on cell floor
		local bedRotation = blockData.attributes.Rotation or 0
		cframe = CFrame.new(worldPos) * CFrame.Angles(0, math.rad(bedRotation), 0)
		block:SetAttribute("BlockPosX", worldPos.X)
		block:SetAttribute("BlockPosY", worldPos.Y)
		block:SetAttribute("BlockPosZ", worldPos.Z)
		
		-- Restore sheet color from CustomColorR/G/B
		local cr = blockData.attributes.CustomColorR
		local cg = blockData.attributes.CustomColorG
		local cb = blockData.attributes.CustomColorB
		if cr and cg and cb then
			local sheets = block:FindFirstChild("Sheets")
			if sheets then
				local sa = sheets:FindFirstChildWhichIsA("SurfaceAppearance")
				if sa then
					sa.Color = Color3.fromRGB(cr, cg, cb)
				end
			end
		end
	elseif isCraftingTable then
		-- Crafting table: saved rotation, no Y/Z offset (full-size block with center pivot)
		local ctRotation = blockData.attributes.Rotation or 0
		cframe = CFrame.new(worldPos) * CFrame.Angles(0, math.rad(ctRotation), 0)
		block:SetAttribute("BlockPosX", worldPos.X)
		block:SetAttribute("BlockPosY", worldPos.Y)
		block:SetAttribute("BlockPosZ", worldPos.Z)
	elseif isFurnace then
		-- Furnace: saved rotation, no Y/Z offset (full-size block with center pivot)
		local furnaceRotation = blockData.attributes.Rotation or 0
		cframe = CFrame.new(worldPos) * CFrame.Angles(0, math.rad(furnaceRotation), 0)
		block:SetAttribute("BlockPosX", worldPos.X)
		block:SetAttribute("BlockPosY", worldPos.Y)
		block:SetAttribute("BlockPosZ", worldPos.Z)
	else
		-- Check if this is a block that should get random rotation on load (to break up tiling)
		local randomRotationBlocks = {
			["Dirt"] = true,
			["GrassBlock"] = true,
			["SnowGrassBlock"] = true,
			["TaigaGrassBlock"] = true,
		}
		
		if randomRotationBlocks[blockData.blockType] then
			-- Random Y-axis rotation (0, 90, 180, or 270 degrees) to break up tiling
			local randomYRotation = math.rad(math.random(0, 3) * 90)
			cframe = CFrame.new(worldPos) * CFrame.Angles(0, randomYRotation, 0)
			rotation = math.deg(randomYRotation) -- Update for attribute storage
		elseif blockData.attributes.ColorMode == "Rainbow" then
			-- Rainbow blocks: restore saved all-axis rotation
			local rotX = (blockData.attributes.RainbowRotX or 0) * 90
			local rotY = rotation
			local rotZ = (blockData.attributes.RainbowRotZ or 0) * 90
			cframe = CFrame.new(worldPos) * CFrame.Angles(math.rad(rotX), math.rad(rotY), math.rad(rotZ))
		else
			cframe = CFrame.new(worldPos) * CFrame.Angles(0, math.rad(rotation), 0)
		end
	end
	
	-- Apply CFrame
	if block:IsA("BasePart") then
		if isFence or isGlassBlock or isLadder or isTorchBlock or isLanternBlock or isSign or isWallpaperFrame or isCarpet or isVine or isArchitrave then
			block:PivotTo(cframe)
		else
			block.CFrame = cframe
		end
	elseif block:IsA("Model") then
		if blockData._skipModelOffset then
			-- PathBlock (and similar): offset already baked into cframe, just apply directly
			block:PivotTo(cframe)
		else
			local isSurfaceBlock = blockData.attributes.SurfaceFace ~= nil
			
			-- Unfilled frame doors need special handling: bounding-box pivot offset + 90° rotation
			local isUnfilledFrameDoor = isDoor and isFrameBlock and not blockData.attributes.FrameFillBlockId
			if isUnfilledFrameDoor then
				local _, bbSize = block:GetBoundingBox()
				local pivotY = block.WorldPivot.Position.Y
				local bbCFrameLocal = block:GetBoundingBox()
				local bbBottomY = bbCFrameLocal.Position.Y - bbSize.Y / 2
				local pivotToBottom = pivotY - bbBottomY
				local offsetCFrame = cframe * CFrame.Angles(0, math.rad(90), 0) * CFrame.new(0, -BLOCK_SIZE / 2 + pivotToBottom, 0)
				block:PivotTo(offsetCFrame)
			elseif isChest then
				-- Chest: both Single and Double have center pivots, no Y offset needed
				block:PivotTo(cframe)
			elseif isBed then
				-- Bed: model is 6 studs long with pivot at its center.
				-- Mirrors BlockHandler.setBlockCFrame's bed placement.
				local _, bbSizeBed = block:GetBoundingBox()
				local pivotYBed = block.WorldPivot.Position.Y
				local bbCFrameBed = block:GetBoundingBox()
				local bbBottomYBed = bbCFrameBed.Position.Y - bbSizeBed.Y / 2
				local pivotToBottomBed = pivotYBed - bbBottomYBed
				block:PivotTo(cframe * CFrame.new(0, -BLOCK_SIZE / 2 + pivotToBottomBed, 0))
			else
				-- Check if model pivot is already at center (no offset needed)
				-- Models with bottom-aligned pivots (GrassBlock, doors, etc.) need the -BLOCK_SIZE/2 offset
				-- Models with center pivots (GlassBlock, etc.) don't
				local bbCFrame = block:GetBoundingBox()
				local pivotOffsetY = block.WorldPivot.Position.Y - bbCFrame.Position.Y
				local pivotIsCenter = math.abs(pivotOffsetY) < 0.1
				if not isSurfaceBlock and not isFence and not isGlassBlock and not isLadder and not isTorchBlock and not isLanternBlock and not isSign and not isWallpaperFrame and not isCarpet and not isVine and not isArchitrave and not isDecoration and not pivotIsCenter then
					local offsetCFrame = cframe * CFrame.new(0, -BLOCK_SIZE / 2, 0)
					block:PivotTo(offsetCFrame)
				else
					block:PivotTo(cframe)
				end
			end
		end
	end
	
	-- Apply color/material
	local shouldApplyColor = (not usedBlockModel or isLadder or isFence or preset.ApplyColor) and preset.DefaultColor and preset.Material and not isDecoration and not isBed
	
	if shouldApplyColor then
		local color = preset.DefaultColor
		local customR = blockData.attributes.CustomColorR
		local customG = blockData.attributes.CustomColorG
		local customB = blockData.attributes.CustomColorB
		
		if customR and customG and customB then
			color = Color3.fromRGB(customR, customG, customB)
		end
		
		local material = preset.Material
		local materialVariant = preset.MaterialVariant or ""
		
		if block:IsA("BasePart") then
			block.Color = color
			block.Material = material
			block.MaterialVariant = materialVariant
		elseif cachedBaseParts then
			-- Crafting table: tint leather Texture/Decal on Side/Top parts before BasePart loop
			if isCraftingTable and block:IsA("Model") then
				local ctLeatherTint = BlockPresets.GetCraftingTableLeatherTint and BlockPresets.GetCraftingTableLeatherTint(blockData.blockType)
				if not ctLeatherTint then ctLeatherTint = Color3.fromRGB(160, 110, 60) end
				for _, desc in ipairs(block:GetDescendants()) do
					if (desc:IsA("Texture") or desc:IsA("Decal")) then
						local parentName = desc.Parent and desc.Parent.Name or ""
						if parentName == "Side" or parentName == "Top" then
							desc.Color3 = ctLeatherTint
						end
					end
				end
			end
			for _, part in ipairs(cachedBaseParts) do
				-- Skip door hardware (hinges/knobs keep metallic look)
				if isDoor and (part.Name == "Hinge" or part.Name == "Knob") then
					continue
				end
				-- Crafting table: Block=wood, Edge=darkened, Side/Top keep template
				if isCraftingTable then
					if part.Name == "Block" then
						part.Color = color
						part.Material = material
						part.MaterialVariant = materialVariant
					elseif part.Name == "Edge" then
						-- Edge trim: darkened wood color, keep template material
						local h, s, v = color:ToHSV()
						part.Color = Color3.fromHSV(h, s * 0.75, v * 0.38)
					end
					-- Side/Top and everything else keep default
					continue
				end
				-- Chest: walk parent chain to find group (Edge is a Model with parts inside)
				if isChest then
					local ancestor = part.Parent
					local group = nil
					while ancestor and ancestor ~= block do
						local n = ancestor.Name
						if n == "Body" or n == "Lid" or n == "Edge" or n == "Latch" or n == "Darkness" then
							group = n; break
						end
						ancestor = ancestor.Parent
					end
					if not group then
						local n = part.Name
						if n == "Body" or n == "Lid" or n == "Edge" or n == "Latch" or n == "Darkness" then group = n end
					end
					if group == "Latch" or group == "Darkness" then continue end
					if group == "Body" or group == "Lid" then
						part.Color = color
						part.Material = material
						part.MaterialVariant = materialVariant
					elseif group == "Edge" then
						local h, s, v = color:ToHSV()
						part.Color = Color3.fromHSV(h, s * 0.75, v * 0.38)
						-- Edge: only color, keep template material/texture
					end
					continue
				end
				part.Color = color
				part.Material = material
				part.MaterialVariant = materialVariant
			end
		end
	end
	
	-- Apply attributes
	block:SetAttribute("BlockType", blockData.blockType)
	block:SetAttribute("PlacedBy", placedByUserId)
	
	local wireConnections = nil
	for attrName, attrValue in pairs(blockData.attributes) do
		if string.sub(attrName, 1, 1) == "_" then
			if attrName == "_WireConnections" then
				wireConnections = attrValue
			end
		elseif attrName == "ChestSecondaryX" or attrName == "ChestSecondaryY" or attrName == "ChestSecondaryZ"
			or attrName == "csx" or attrName == "csy" or attrName == "csz" then
			-- Chest secondary position is handled explicitly in the chest CFrame block above
			-- (reconstructed from relative csx/csy/csz or legacy absolutes). Skip here so the
			-- corrected world coords aren't clobbered by stale/relative saved values.
		else
			block:SetAttribute(attrName, attrValue)
		end
	end
	
	-- Restore wire connections
	if wireConnections and type(wireConnections) == "table" then
		for i, targetBlockId in ipairs(wireConnections) do
			local connAttrName = "WireConn_" .. tostring(i)
			block:SetAttribute(connAttrName, targetBlockId)
		end
	end
	
	-- Restore frame block fill: if this frame was filled, we already loaded the solid
	-- template above (see FrameFillBlockId check), so just apply the saved appearance
	local frameFillId = blockData.attributes.FrameFillBlockId
	if frameFillId and (isFrameBlock or blockData.blockType == "FilledFence") then
		local fillPreset = BlockPresets.GetPreset(frameFillId)
		if fillPreset then
			local fillColor = fillPreset.DefaultColor or Color3.fromRGB(128, 128, 128)
			local fillMaterial = fillPreset.Material or Enum.Material.Plastic
			local fillMaterialVariant = fillPreset.MaterialVariant or ""
			
			-- Use saved RGB if available (in case preset colors change)
			local savedR = blockData.attributes.FrameFillColorR
			local savedG = blockData.attributes.FrameFillColorG
			local savedB = blockData.attributes.FrameFillColorB
			if savedR and savedG and savedB then
				fillColor = Color3.fromRGB(savedR, savedG, savedB)
			end
			local savedVariant = blockData.attributes.FrameFillMaterialVariant
			if savedVariant then
				fillMaterialVariant = savedVariant
			end
			
			-- GrassBlock fill: preset material is Ground (dirt), but filled frames use Grass
			local isGrassFill = (frameFillId == "GrassBlock" or frameFillId == "SnowyGrassBlock" or frameFillId == "SnowGrassBlock" or frameFillId == "TaigaGrassBlock")
			if isGrassFill then
				fillMaterial = Enum.Material.Grass
			end
			
			-- Log fill: preset may use end-grain material, but filled frames use bark
			if string.find(frameFillId, "Log") then
				local blocksFolder = ReplicatedStorage:FindFirstChild("Blocks")
				if blocksFolder then
					local logModel = blocksFolder:FindFirstChild(frameFillId)
					if logModel then
						local unionPart = logModel:FindFirstChild("Union")
						if unionPart and unionPart:IsA("BasePart") then
							fillMaterial = unionPart.Material
						end
					end
				end
			end
			
			if block:IsA("BasePart") then
				block.Color = fillColor
				block.Material = fillMaterial
				block.MaterialVariant = fillMaterialVariant ~= "" and fillMaterialVariant or ""
			elseif cachedBaseParts then
				for _, part in ipairs(cachedBaseParts) do
					-- Skip door hardware (hinges/knobs keep metallic look)
					if isDoor and (part.Name == "Hinge" or part.Name == "Knob") then
						continue
					end
					part.Color = fillColor
					part.Material = fillMaterial
					part.MaterialVariant = fillMaterialVariant ~= "" and fillMaterialVariant or ""
				end
			end
		end
	end
	
	-- If lazy-loaded, set terrain attributes
	if blockData.attributes.IsLazyLoaded then
		block:SetAttribute("IsTerrainBlock", true)
		block:SetAttribute("BlockPosX", worldPos.X)
		block:SetAttribute("BlockPosY", worldPos.Y)
		block:SetAttribute("BlockPosZ", worldPos.Z)
	end
	
	-- For decorations
	if isDecorationForCollide then
		block:SetAttribute("IsDecoration", true)
		block:SetAttribute("ParentBlockX", math.round(worldPos.X))
		block:SetAttribute("ParentBlockY", math.round(worldPos.Y))
		block:SetAttribute("ParentBlockZ", math.round(worldPos.Z))
	end
	
	-- Handle special blocks (lamps, glowstone, doors, pistons, etc.)
	local isLamp = string.find(blockData.blockType, "Lamp") ~= nil
	if isLamp then
		local isPowered = blockData.attributes.IsPowered or false
		block:SetAttribute("IsPowered", isPowered)
		block:SetAttribute("IsControllable", true)
		for _, descendant in ipairs(block:GetDescendants()) do
			if descendant:IsA("PointLight") or descendant:IsA("SpotLight") or descendant:IsA("SurfaceLight") then
				descendant.Enabled = isPowered
			end
		end
	end
	
	local isGlowstoneBlock = blockData.attributes.IsGlowstone or (BlockPresets.IsGlowstone and BlockPresets.IsGlowstone(blockData.blockType))
	if isGlowstoneBlock then
		local glowstoneColorName = blockData.attributes.GlowstoneColor
		local glowColor = nil
		if glowstoneColorName and ColorPalette then
			glowColor = ColorPalette.getColor(glowstoneColorName)
		end
		if not glowColor and preset.DefaultColor then
			glowColor = preset.DefaultColor
		end
		if glowColor then
			if block:IsA("BasePart") then
				block.Color = glowColor
			elseif cachedBaseParts then
				for _, part in ipairs(cachedBaseParts) do
					part.Color = glowColor
				end
			end
			-- Boost saturation for emitted light color (more vivid than block surface)
			local h, s, v = glowColor:ToHSV()
			local boostedLightColor = Color3.fromHSV(h, math.clamp(s * 1.5, 0, 1), math.clamp(v * 1.15, 0, 1))
			for _, descendant in ipairs(block:GetDescendants()) do
				if descendant:IsA("PointLight") or descendant:IsA("SpotLight") or descendant:IsA("SurfaceLight") then
					descendant.Color = boostedLightColor
				end
			end
		end
	end
	
	if isDoor then
		block:SetAttribute("IsDoor", true)
		local isOpen = blockData.attributes.IsOpen or false
		block:SetAttribute("IsOpen", isOpen)
		block:SetAttribute("GridPosX", worldPos.X)
		block:SetAttribute("GridPosY", worldPos.Y)
		block:SetAttribute("GridPosZ", worldPos.Z)
	end
	
	if isColumn then
		block:SetAttribute("IsColumn", true)
		block:SetAttribute("ColumnModelName", columnModelName)
		block:SetAttribute("BlockPosX", worldPos.X)
		block:SetAttribute("BlockPosY", worldPos.Y)
		block:SetAttribute("BlockPosZ", worldPos.Z)
	end
	
	if isTorchBlock then
		if block:IsA("BasePart") then
			block.CanCollide = false
		elseif cachedBaseParts then
			for _, part in ipairs(cachedBaseParts) do
				part.CanCollide = false
			end
		end
	end
	
	-- Vines: must be non-collidable so the player can walk through them.
	-- VineHandler.createVine sets this for fresh placements, but loaded vines
	-- would otherwise inherit the template's default (which is collidable) and
	-- the vine would feel "solid" in game until replaced.
	if isVine then
		if block:IsA("BasePart") then
			block.CanCollide = false
		elseif cachedBaseParts then
			for _, part in ipairs(cachedBaseParts) do
				part.CanCollide = false
			end
		end
		
		-- Mirror VineHandler.createVine so the server has full attribute parity for
		-- ToolHandler/Shears, BlockHandler cascade-break, and the vine spread system.
		local vineFace = blockData.attributes.VineFace or "North"
		block:SetAttribute("IsVine", true)
		block:SetAttribute("VineFace", vineFace)
		block:SetAttribute("VineRotation", VinePlacement.GetVineRotation(vineFace))
		block:SetAttribute("BlockPosX", worldPos.X)
		block:SetAttribute("BlockPosY", worldPos.Y)
		block:SetAttribute("BlockPosZ", worldPos.Z)
		if blockData.attributes.IsVineTrimmed then
			block:SetAttribute("IsVineTrimmed", true)
		end
		if blockData.attributes.VineTrimmedFlipped then
			block:SetAttribute("VineTrimmedFlipped", true)
		end
		
		-- VineHandler.createVine adds an invisible Hitbox + ClimbSensor at runtime.
		-- Saved templates don't include these (they live only on placed instances),
		-- so recreate them here. Without the ClimbSensor, loaded vines can't be
		-- climbed; without the Hitbox, raycasts may miss the vine.
		local vineCFrame = cframe or VinePlacement.GetVineCFrame(worldPos, vineFace)
		local function sizeForFace(face, thickness)
			if face == "North" or face == "South" then
				return Vector3.new(BLOCK_SIZE, BLOCK_SIZE, thickness)
			elseif face == "East" or face == "West" then
				return Vector3.new(thickness, BLOCK_SIZE, BLOCK_SIZE)
			end
			return Vector3.new(BLOCK_SIZE, BLOCK_SIZE, BLOCK_SIZE)
		end
		
		if not block:FindFirstChild("Hitbox") then
			local hitbox = Instance.new("Part")
			hitbox.Name = "Hitbox"
			hitbox.Anchored = true
			hitbox.CanCollide = false
			hitbox.CanQuery = true
			hitbox.CanTouch = false
			hitbox.CastShadow = false
			hitbox.Transparency = 1
			hitbox.Size = sizeForFace(vineFace, 1.0)
			hitbox.CFrame = CFrame.new(vineCFrame.Position)
			hitbox.Parent = block
		end
		
		if not block:FindFirstChild("ClimbSensor") then
			local climbSensor = Instance.new("Part")
			climbSensor.Name = "ClimbSensor"
			climbSensor.Anchored = true
			climbSensor.CanCollide = false
			climbSensor.CanQuery = false
			climbSensor.CanTouch = true
			climbSensor.CastShadow = false
			climbSensor.Transparency = 1
			climbSensor.Size = sizeForFace(vineFace, 1.0)
			climbSensor.CFrame = vineCFrame
			climbSensor:AddTag("VineClimbSensor")
			climbSensor.Parent = block
		end
	end
	
	-- Handle signs: no collision + wood color application
	if isSign then
		-- Disable collision
		if block:IsA("BasePart") then
			block.CanCollide = false
		elseif cachedBaseParts then
			for _, part in ipairs(cachedBaseParts) do
				part.CanCollide = false
			end
		end
		
		-- Apply wood color from preset (color ENTIRE sign model uniformly, including post)
		-- Skip for filled frame signs - their color comes from the frame fill restoration above
		if preset.DefaultColor and preset.Material and not blockData.attributes.FrameFillBlockId then
			local woodColor = preset.DefaultColor
			local woodMaterial = preset.Material
			local woodMaterialVariant = preset.MaterialVariant or ""
			
			-- Color the entire sign model (both Sign and Post parts)
			if block:IsA("BasePart") then
				block.Color = woodColor
				block.Material = woodMaterial
				if woodMaterialVariant ~= "" then
					block.MaterialVariant = woodMaterialVariant
				end
			elseif cachedBaseParts then
				for _, part in ipairs(cachedBaseParts) do
					part.Color = woodColor
					part.Material = woodMaterial
					if woodMaterialVariant ~= "" then
						part.MaterialVariant = woodMaterialVariant
					end
				end
			end
		end
	end
	
	local isPiston = string.find(blockData.blockType, "Piston") ~= nil
	if isPiston and blockData.attributes.IsExtended then
		local pistonTop = block:FindFirstChild("PistonTop")
		if pistonTop then
			local pistonArm = pistonTop:FindFirstChild("PistonArm")
			local pistonCFrame = block:GetPivot()
			local moveDirection = pistonCFrame.UpVector
			local EXTENSION_DISTANCE = 3
			local ARM_SCALE_AMOUNT = 3
			local moveOffset = moveDirection * EXTENSION_DISTANCE
			
			if pistonArm and pistonArm:IsA("BasePart") then
				local currentSize = pistonArm.Size
				pistonArm.Size = Vector3.new(currentSize.X, currentSize.Y + ARM_SCALE_AMOUNT, currentSize.Z)
				pistonArm.Position = pistonArm.Position + (moveDirection * (ARM_SCALE_AMOUNT / 2))
			end
			
			if pistonTop:IsA("Model") then
				for _, part in ipairs(pistonTop:GetDescendants()) do
					if part:IsA("BasePart") and part.Name ~= "PistonArm" then
						part.CFrame = part.CFrame + moveOffset
					end
				end
			elseif pistonTop:IsA("BasePart") then
				pistonTop.Position = pistonTop.Position + moveOffset
			end
		end
	end
	
	-- Restore biome colors
	local savedBiome = blockData.attributes.Biome
	local savedSeason = blockData.attributes.Season or "Summer"
	
	local isGrassBlock = blockData.blockType == "GrassBlock" or 
						 blockData.blockType == "SnowGrassBlock" or 
						 blockData.blockType == "TaigaGrassBlock" or
						 blockData.blockType == "GrassSlab"
	if isGrassBlock and savedBiome then
		applyBiomeGrassColor(block, savedBiome, savedSeason)
	end
	
	if blockData.blockType == "ShortGrass" or blockData.blockType == "TallGrass" then
		if savedBiome then
			applyBiomeDecorationColor(block, blockData.blockType, savedBiome, savedSeason)
		end
		block:SetAttribute("NeedsBiomeColor", savedBiome == nil)
	end
	
	if blockData.blockType == "Leaves" and BiomeConfig then
		local treeType = blockData.attributes.TreeType or "Oak"
		local leafColor
		if savedBiome then
			leafColor = BiomeConfig.GetRandomizedTintedLeafColor(treeType, savedBiome, savedSeason)
		else
			local leafConfig = BiomeConfig.LeafTypes[treeType] or BiomeConfig.LeafTypes.Oak
			leafColor = BiomeConfig.GetRandomizedLeafColor(leafConfig.Color)
		end
		
		if leafColor then
			if block:IsA("BasePart") then
				block.Color = leafColor
			elseif cachedBaseParts then
				for _, part in ipairs(cachedBaseParts) do
					part.Color = leafColor
				end
			end
		end
	end
	
	-- NOTE: Parent is NOT set here for batch-parenting optimization.
	-- The caller is responsible for setting block.Parent = blocksFolder after creation.
	
	-- Add invisible hitbox for non-full blocks (so raycasts can select them)
	local isSurfaceBlock = blockData.attributes.SurfaceFace ~= nil
	local isSnowLayerPartial = blockData.blockType == "SnowLayer" and (blockData.attributes.SnowLayers or 1) < 8
	if isFence or isGlassBlock or isLadder or isTorchBlock or isLanternBlock or isSign or isSurfaceBlock or isDoor or isSnowLayerPartial or isWallpaperFrame or isCarpet or isVine or isFrameBlock or isColumn or isArchitrave or isChest or isCraftingTable or isFurnace or isBed then
		addBlockHitbox(block, worldPos)
		-- Bed: resize hitbox to match the visible bed silhouette (computed from actual parts)
		-- and register secondary position.
		if isBed and blockData.attributes.BedSecondaryX then
			local hitbox = block:FindFirstChild("Hitbox")
			if hitbox then
				-- Transform each part's 8 corners through its world CFrame to get a correct
				-- world-axis AABB. Using Position ± Size/2 directly gives a too-small hitbox
				-- when the bed is rotated 90°/270° (see matching BlockHandler comment).
				local minX, minY, minZ = math.huge, math.huge, math.huge
				local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
				for _, descendant in ipairs(block:GetDescendants()) do
					if descendant:IsA("BasePart") and descendant ~= hitbox then
						local cf = descendant.CFrame
						local hx, hy, hz = descendant.Size.X / 2, descendant.Size.Y / 2, descendant.Size.Z / 2
						for _, dx in ipairs({-1, 1}) do
							for _, dy in ipairs({-1, 1}) do
								for _, dz in ipairs({-1, 1}) do
									local corner = cf * Vector3.new(dx * hx, dy * hy, dz * hz)
									minX = math.min(minX, corner.X); maxX = math.max(maxX, corner.X)
									minY = math.min(minY, corner.Y); maxY = math.max(maxY, corner.Y)
									minZ = math.min(minZ, corner.Z); maxZ = math.max(maxZ, corner.Z)
								end
							end
						end
					end
				end
				if minX < math.huge then
					local margin = 0.05
					hitbox.Size = Vector3.new(
						(maxX - minX) + margin * 2,
						(maxY - minY) + margin * 2,
						(maxZ - minZ) + margin * 2
					)
					hitbox.CFrame = CFrame.new((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2)
				else
					-- Fallback: previous cell-spanning sizing
					local bedRot = (blockData.attributes.Rotation or 0) % 360
					local secPos = Vector3.new(blockData.attributes.BedSecondaryX, blockData.attributes.BedSecondaryY, blockData.attributes.BedSecondaryZ)
					local midpoint = (worldPos + secPos) / 2
					local HITBOX_HEIGHT = 1.6
					local hitboxY = (worldPos.Y - BLOCK_SIZE / 2) + HITBOX_HEIGHT / 2
					if bedRot == 0 or bedRot == 180 then
						hitbox.Size = Vector3.new(BLOCK_SIZE, HITBOX_HEIGHT, BLOCK_SIZE * 2)
					else
						hitbox.Size = Vector3.new(BLOCK_SIZE * 2, HITBOX_HEIGHT, BLOCK_SIZE)
					end
					hitbox.CFrame = CFrame.new(midpoint.X, hitboxY, midpoint.Z)
				end
			end
			-- Make visible bed parts non-queryable so only the Hitbox catches raycasts
			for _, descendant in ipairs(block:GetDescendants()) do
				if descendant:IsA("BasePart") and descendant.Name ~= "Hitbox" then
					descendant.CanQuery = false
				end
			end
			-- Register foot cell in spatial index
			local bedSpatialIndex = BlockSpatialIndex.GetOrCreate(blocksFolder)
			if bedSpatialIndex then
				local footPos = Vector3.new(blockData.attributes.BedSecondaryX, blockData.attributes.BedSecondaryY, blockData.attributes.BedSecondaryZ)
				bedSpatialIndex:RegisterSecondaryPosition(block, footPos)
			end
		end
		-- DoubleChest: resize hitbox to span both cells
		if blockData.attributes.IsDoubleChest then
			local hitbox = block:FindFirstChild("Hitbox")
			-- Read the CORRECTED secondary off the block (set in the chest CFrame block above),
			-- not the stale/relative saved attributes.
			local csX = block:GetAttribute("ChestSecondaryX")
			local csY = block:GetAttribute("ChestSecondaryY")
			local csZ = block:GetAttribute("ChestSecondaryZ")
			if hitbox and csX and csY and csZ then
				local chestRot = (blockData.attributes.Rotation or 0) % 360
				local secPos = Vector3.new(csX, csY, csZ)
				local midpoint = (worldPos + secPos) / 2
				hitbox.Size = Vector3.new(
					(chestRot == 0 or chestRot == 180) and BLOCK_SIZE * 2 or BLOCK_SIZE,
					BLOCK_SIZE,
					(chestRot == 90 or chestRot == 270) and BLOCK_SIZE * 2 or BLOCK_SIZE
				)
				hitbox.CFrame = CFrame.new(midpoint)
			end
		end
		-- SnowLayer: resize hitbox to match actual layer height
		if isSnowLayerPartial then
			local hitbox = block:FindFirstChild("Hitbox")
			if hitbox then
				local snowLayers = blockData.attributes.SnowLayers or 1
				local totalHeight = (BLOCK_SIZE / 8) * snowLayers
				hitbox.Size = Vector3.new(BLOCK_SIZE, totalHeight, BLOCK_SIZE)
				local bottomOfCell = worldPos.Y - BLOCK_SIZE / 2
				hitbox.CFrame = CFrame.new(worldPos.X, bottomOfCell + totalHeight / 2, worldPos.Z)
			end
		end
		-- WallpaperFrame: thin face-oriented hitbox instead of full cube
		if isWallpaperFrame and cframe then
			local hitbox = block:FindFirstChild("Hitbox")
			if hitbox then
				local HITBOX_THICKNESS = 0.5
				local wpFace = blockData.attributes.WallpaperFace or "Top"
				if wpFace == "North" or wpFace == "South" then
					hitbox.Size = Vector3.new(BLOCK_SIZE, BLOCK_SIZE, HITBOX_THICKNESS)
				elseif wpFace == "East" or wpFace == "West" then
					hitbox.Size = Vector3.new(HITBOX_THICKNESS, BLOCK_SIZE, BLOCK_SIZE)
				else -- Top or Bottom
					hitbox.Size = Vector3.new(BLOCK_SIZE, HITBOX_THICKNESS, BLOCK_SIZE)
				end
				hitbox.CFrame = CFrame.new(cframe.Position)
			end
		end
		-- Door: thin hitbox matching the door panel orientation and depth
		if isDoor and cframe then
			local hitbox = block:FindFirstChild("Hitbox")
			if hitbox then
				local DOOR_HITBOX_THICKNESS = 1.0
				local doorDir = blockData.attributes.DoorDirection or 0
				if doorDir == 0 or doorDir == 2 then
					hitbox.Size = Vector3.new(BLOCK_SIZE, BLOCK_SIZE, DOOR_HITBOX_THICKNESS)
				else
					hitbox.Size = Vector3.new(DOOR_HITBOX_THICKNESS, BLOCK_SIZE, BLOCK_SIZE)
				end
				hitbox.CFrame = CFrame.new(cframe.Position)
			end
		end
		-- Carpet: thin hitbox matching carpet height, positioned at bottom of cell
		if isCarpet then
			local hitbox = block:FindFirstChild("Hitbox")
			if hitbox then
				local carpetH = CarpetPlacement.CARPET_HEIGHT
				hitbox.Size = Vector3.new(BLOCK_SIZE, carpetH, BLOCK_SIZE)
				local bottomOfCell = worldPos.Y - BLOCK_SIZE / 2
				hitbox.CFrame = CFrame.new(worldPos.X, bottomOfCell + carpetH / 2, worldPos.Z)
			end
		end
		-- Torch: thin hitbox so you can target the block behind/below it
		if isTorchBlock and cframe then
			local hitbox = block:FindFirstChild("Hitbox")
			if hitbox then
				local TORCH_HITBOX = 1.0
				hitbox.Size = Vector3.new(TORCH_HITBOX, BLOCK_SIZE, TORCH_HITBOX)
				hitbox.CFrame = CFrame.new(cframe.Position)
			end
		end
		-- Wall sign: thin hitbox matching face orientation
		-- Skip for fence post signs — they're pushed into the fence's grid cell
		if isWallSign and cframe and not blockData.attributes.IsOnFencePost then
			local hitbox = block:FindFirstChild("Hitbox")
			if hitbox then
				local SIGN_HITBOX_THICKNESS = 0.5
				local sFace = blockData.attributes.SignFace or "North"
				if sFace == "North" or sFace == "South" then
					hitbox.Size = Vector3.new(BLOCK_SIZE, BLOCK_SIZE, SIGN_HITBOX_THICKNESS)
				elseif sFace == "East" or sFace == "West" then
					hitbox.Size = Vector3.new(SIGN_HITBOX_THICKNESS, BLOCK_SIZE, BLOCK_SIZE)
				end
				hitbox.CFrame = CFrame.new(cframe.Position)
			end
		end
		-- Vine: thin face-oriented hitbox
		if isVine and cframe then
			local hitbox = block:FindFirstChild("Hitbox")
			if hitbox then
				local VINE_HITBOX_THICKNESS = 1.0
				local vFace = blockData.attributes.VineFace or "North"
				if vFace == "North" or vFace == "South" then
					hitbox.Size = Vector3.new(BLOCK_SIZE, BLOCK_SIZE, VINE_HITBOX_THICKNESS)
				elseif vFace == "East" or vFace == "West" then
					hitbox.Size = Vector3.new(VINE_HITBOX_THICKNESS, BLOCK_SIZE, BLOCK_SIZE)
				end
				hitbox.CFrame = CFrame.new(cframe.Position)
			end
		end
		-- Standing sign: thinner hitbox (flat panel on a post)
		if isSignStanding and cframe then
			local hitbox = block:FindFirstChild("Hitbox")
			if hitbox then
				local SIGN_HITBOX_THICKNESS = 1.0
				local rot = (blockData.attributes.SignRotation or 0) % 360
				if (rot >= 45 and rot < 135) or (rot >= 225 and rot < 315) then
					hitbox.Size = Vector3.new(SIGN_HITBOX_THICKNESS, BLOCK_SIZE, BLOCK_SIZE)
				else
					hitbox.Size = Vector3.new(BLOCK_SIZE, BLOCK_SIZE, SIGN_HITBOX_THICKNESS)
				end
				hitbox.CFrame = CFrame.new(cframe.Position)
			end
		end
	end
	
	-- Final MaterialVariant safeguard: Roblox can sometimes drop MaterialVariant
	-- when .Material is set to the same value the cloned template already had.
	-- Force re-apply as the very last step before parenting.
	if preset.MaterialVariant and preset.MaterialVariant ~= "" and (preset.ApplyColor or not usedBlockModel) and not frameFillId then
		local mv = preset.MaterialVariant
		if block:IsA("BasePart") then
			block.MaterialVariant = mv
		elseif cachedBaseParts then
			for _, part in ipairs(cachedBaseParts) do
				if part.Name == "Hitbox" then continue end
				-- Skip chest Latch/Darkness (they keep their own template MaterialVariant)
				if isChest then
					local ancestor = part.Parent
					local group = nil
					while ancestor and ancestor ~= block do
						local n = ancestor.Name
						if n == "Latch" or n == "Darkness" or n == "Edge" then group = n; break end
						ancestor = ancestor.Parent
					end
					if not group then
						local n = part.Name
						if n == "Latch" or n == "Darkness" or n == "Edge" then group = n end
					end
					if group == "Latch" or group == "Darkness" or group == "Edge" then continue end
				end
				-- Skip crafting table non-Block parts (WireTool/Wrench keep their template MaterialVariant)
				if isCraftingTable and part.Name ~= "Block" then continue end
				part.MaterialVariant = mv
			end
		end
	end
	
	return block
end

local function loadPlotFromSlot(player, buildArea, plotNumber, slotNumber)
	local dataStore = getDataStore()
	if not dataStore then
		return false, "DataStore not available"
	end
	
	-- Load from DataStore (with retry + backup fallback)
	local key = getSlotKey(player.UserId, slotNumber)
	local saveData = nil
	local recoveredFromBackup = false
	
	local success, err = retryDataStore(function()
		saveData = dataStore:GetAsync(key)
	end, 3, "GetAsync(primary slot " .. slotNumber .. ")")
	
	-- Detect a possible silent wipe: primary returned nil, but metadata says this
	-- slot has blocks. That's the corruption signature -- try the backup before
	-- giving up and resetting to a fresh plot.
	local metaForSlot = nil
	local cachedMeta = getPlayerMeta(player.UserId)
	if cachedMeta and cachedMeta.slots then
		metaForSlot = cachedMeta.slots[slotNumber]
	end
	local primaryLooksWiped = success and not saveData and metaForSlot and (metaForSlot.blockCount or 0) > 0
	
	if not success or primaryLooksWiped then
		local reason = success and "primary returned nil but meta says " .. tostring(metaForSlot and metaForSlot.blockCount) .. " blocks" or tostring(err)
		warn(string.format("[SaveManager] Primary load failed/empty for %s slot %d (%s). Trying backup...",
			player.Name, slotNumber, reason))
		
		local backupKey = getSlotBackupKey(player.UserId, slotNumber)
		local backupSaveData = nil
		local backupSuccess, backupErr = retryDataStore(function()
			backupSaveData = dataStore:GetAsync(backupKey)
		end, 3, "GetAsync(backup slot " .. slotNumber .. ")")
		
		if backupSuccess and backupSaveData then
			warn(string.format("[SaveManager] RECOVERED slot %d from backup for %s (%d blocks)",
				slotNumber, player.Name, backupSaveData.blocks and #backupSaveData.blocks or 0))
			saveData = backupSaveData
			recoveredFromBackup = true
		elseif not success then
			-- Primary errored AND backup didn't bail us out. Hard fail.
			warn("[SaveManager] Load failed for " .. player.Name .. " (primary + backup): " .. tostring(err))
			return false, "DataStore error: " .. tostring(err) .. " (backup also unavailable)"
		end
		-- If primary returned nil and backup also nil, fall through to fresh-plot path below.
	end
	
	-- If no save data, reset to fresh plot
	if not saveData then
		
		-- Notify clients to clear particles before we clear the plot
		PlotClearing:FireClient(player, plotNumber)
		
		-- Clear and regenerate terrain
		if TerrainGenerator then
		TerrainGenerator.ClearAllBlocks(buildArea, plotNumber)
		TerrainGenerator.ResetPlot(plotNumber)
		
		-- Use default biome and terrain style
		local defaultBiome = "Plains"
		local defaultTerrainStyle = "Flat"
		
		buildArea:SetAttribute("CurrentBiome", defaultBiome)
		buildArea:SetAttribute("CurrentSeason", "Summer")
		buildArea:SetAttribute("TerrainStyle", defaultTerrainStyle)
		buildArea:SetAttribute("LifetimeBlocksPlaced", 0)
		
		local originalSettings = TerrainGenerator.GetGenerationSettings()
		TerrainGenerator.SetGenerationSettings({ LAYER_DELAY = 0, ANIMATION_ENABLED = false })
		-- Route to correct generation function based on terrain style
		if defaultTerrainStyle == "Default" and TerrainGenerator.GenerateDefaultTerrain then
		TerrainGenerator.GenerateDefaultTerrain(buildArea, plotNumber, nil, nil)
		else
		 TerrainGenerator.GenerateFlatTerrainWithBiome(buildArea, plotNumber, defaultBiome, defaultTerrainStyle, nil)
		 end
		TerrainGenerator.SetGenerationSettings({ 
			LAYER_DELAY = originalSettings.LAYER_DELAY,
			ANIMATION_ENABLED = originalSettings.ANIMATION_ENABLED 
		})
	end
		
		DirtyPlots[player.UserId] = false
		PlayerActiveSlot[player.UserId] = slotNumber
		LoadSucceeded[player.UserId] = true -- Fresh plot is a legitimate "loaded" state; saving is safe.
		
		-- Update metadata
		local meta = getPlayerMeta(player.UserId)
		if meta then
			meta.activeSlot = slotNumber
			savePlayerMeta(player.UserId, meta)
		end
		
		return true, 0  -- 0 blocks loaded (fresh plot)
	end
	
	-- Debug
	
	-- Deserialize
	local plotData, deserializeError = PlotSerializer.DeserializePlot(saveData)
	if not plotData then
		return false, "Failed to deserialize: " .. tostring(deserializeError)
	end
	
	-- Corruption detection and recovery (same as before)
	local lazyLoadedCount = 0
	local lazyLoadedByColumn = {}
	
	for _, blockData in ipairs(plotData.blocks) do
		if blockData.attributes.IsLazyLoaded then
			lazyLoadedCount = lazyLoadedCount + 1
			local colKey = string.format("%d,%d", blockData.gridX, blockData.gridZ)
			if not lazyLoadedByColumn[colKey] then
				lazyLoadedByColumn[colKey] = {}
			end
			table.insert(lazyLoadedByColumn[colKey], blockData.gridY)
		end
	end
	
	local dugPositionCount = #(plotData.dugPositions or {})
	local isCorrupted = lazyLoadedCount > 0 and dugPositionCount == 0
	
	if isCorrupted then
		warn(string.format("[SaveManager] CORRUPTION DETECTED: %d lazy-loaded blocks but 0 dug positions - reconstructing!", lazyLoadedCount))
		local reconstructedDug = {}
		local surfaceGridY = 0
		
		for colKey, _ in pairs(lazyLoadedByColumn) do
			local parts = string.split(colKey, ",")
			local gridX = tonumber(parts[1])
			local gridZ = tonumber(parts[2])
			table.insert(reconstructedDug, { gridX = gridX, gridY = surfaceGridY, gridZ = gridZ })
		end
		
		plotData.dugPositions = reconstructedDug
	end
	
	-- Notify clients to clear particles before we clear the plot
	PlotClearing:FireClient(player, plotNumber)
	
	-- Clear existing terrain and regenerate
	if TerrainGenerator then
		TerrainGenerator.ClearAllBlocks(buildArea, plotNumber)
		TerrainGenerator.ResetPlot(plotNumber)
		
		buildArea:SetAttribute("CurrentBiome", plotData.biome)
		buildArea:SetAttribute("CurrentSeason", plotData.season)
		buildArea:SetAttribute("TerrainStyle", plotData.terrainStyle)
		buildArea:SetAttribute("LifetimeBlocksPlaced", plotData.lifetimeBlocksPlaced or 0)
		
		-- Restore saved height map BEFORE terrain generation (exact Natural terrain restoration)
		if plotData.terrainHeightMap then
			buildArea:SetAttribute("TerrainHeightMap", plotData.terrainHeightMap)
			if plotData.terrainGridSizeX then buildArea:SetAttribute("TerrainGridSizeX", plotData.terrainGridSizeX) end
			if plotData.terrainGridSizeZ then buildArea:SetAttribute("TerrainGridSizeZ", plotData.terrainGridSizeZ) end
			if plotData.terrainMinHeight then buildArea:SetAttribute("TerrainMinHeight", plotData.terrainMinHeight) end
			if plotData.terrainMaxHeight then buildArea:SetAttribute("TerrainMaxHeight", plotData.terrainMaxHeight) end
			if plotData.terrainStartX then buildArea:SetAttribute("TerrainStartX", plotData.terrainStartX) end
			if plotData.terrainStartZ then buildArea:SetAttribute("TerrainStartZ", plotData.terrainStartZ) end
		end
		
		local originalSettings = TerrainGenerator.GetGenerationSettings()
		TerrainGenerator.SetGenerationSettings({ LAYER_DELAY = 0, ANIMATION_ENABLED = false })
		-- Route to correct generation function based on terrain style
		if plotData.terrainStyle == "Default" and TerrainGenerator.GenerateDefaultTerrain then
			TerrainGenerator.GenerateDefaultTerrain(buildArea, plotNumber, plotData.terrainSeed, nil)
		else
			TerrainGenerator.GenerateFlatTerrainWithBiome(buildArea, plotNumber, plotData.biome, plotData.terrainStyle, plotData.terrainSeed)
		end
		TerrainGenerator.SetGenerationSettings({ 
			LAYER_DELAY = originalSettings.LAYER_DELAY,
			ANIMATION_ENABLED = originalSettings.ANIMATION_ENABLED 
		})
		
		task.wait()
	end
	
	-- Get blocks folder
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder then
		blocksFolder = Instance.new("Folder")
		blocksFolder.Name = "Blocks"
		blocksFolder.Parent = buildArea
	end
	
	-- Calculate origin offset
	local originOffset = Vector3.zero
	local terrainSurfaceY = buildArea:GetAttribute("TerrainSurfaceY")
	local posX = buildArea:GetAttribute("BasePlatePositionX")
	local posZ = buildArea:GetAttribute("BasePlatePositionZ")
	local sizeX = buildArea:GetAttribute("BasePlateSizeX")
	local sizeZ = buildArea:GetAttribute("BasePlateSizeZ")
	
	if posX and posZ and sizeX and sizeZ then
		originOffset = Vector3.new(
			posX - sizeX / 2 + BLOCK_SIZE / 2,
			terrainSurfaceY or 0,
			posZ - sizeZ / 2 + BLOCK_SIZE / 2
		)
	end
	
	-- Accumulates every dug world-position handed to MarkPositionsAsDug below, so we can
	-- seed the owning client's terrain prediction with the same set once the load finishes.
	-- Prevents the "phantom terrain flashes into old holes on first dig" glitch. Consumed by
	-- the TerrainDugPositions:FireClient block at the end of this function.
	local clientDugSeed = {}
	
	-- Remove dug terrain blocks (optimized with budget-based yielding)
	local dugRemoved = 0
	local lastYield = os.clock()
	if plotData.dugPositions and #plotData.dugPositions > 0 then
		local terrainBlocksByPos = {}
		local decorationsByParentPos = {}
		
		local function posToKey(x, y, z)
			return string.format("%d,%d,%d", math.round(x/BLOCK_SIZE), math.round(y/BLOCK_SIZE), math.round(z/BLOCK_SIZE))
		end
		
		local children = blocksFolder:GetChildren()
		for i, item in ipairs(children) do
			if item:GetAttribute("IsTerrainBlock") then
				local storedPosX = item:GetAttribute("BlockPosX")
				local storedPosY = item:GetAttribute("BlockPosY")
				local storedPosZ = item:GetAttribute("BlockPosZ")
				
				local blockPos
				if storedPosX and storedPosY and storedPosZ then
					blockPos = Vector3.new(storedPosX, storedPosY, storedPosZ)
				else
					if item:IsA("BasePart") then
						blockPos = item.Position
					elseif item:IsA("Model") then
						local part = item.PrimaryPart or item:FindFirstChildWhichIsA("BasePart")
						if part then blockPos = part.Position end
					end
				end
				
				if blockPos then
					local key = posToKey(blockPos.X, blockPos.Y, blockPos.Z)
					terrainBlocksByPos[key] = item
				end
			elseif item:GetAttribute("IsDecoration") then
				local parentX = item:GetAttribute("ParentBlockX")
				local parentY = item:GetAttribute("ParentBlockY")
				local parentZ = item:GetAttribute("ParentBlockZ")
				
				if parentX and parentY and parentZ then
					local key = posToKey(parentX, parentY, parentZ)
					if not decorationsByParentPos[key] then
						decorationsByParentPos[key] = {}
					end
					table.insert(decorationsByParentPos[key], item)
				end
			end
			
			lastYield = budgetYieldFast(lastYield)
		end
		
		local blocksToRemove = {}
		local decorationsToRemove = {}
		
		for i, dugPos in ipairs(plotData.dugPositions) do
			local worldX = dugPos.gridX * BLOCK_SIZE + originOffset.X
			local worldY = dugPos.gridY * BLOCK_SIZE + originOffset.Y
			local worldZ = dugPos.gridZ * BLOCK_SIZE + originOffset.Z
			
			local key = posToKey(worldX, worldY, worldZ)
			
			local block = terrainBlocksByPos[key]
			if block then
				table.insert(blocksToRemove, block)
			end
			
			local decos = decorationsByParentPos[key]
			if decos then
				for _, deco in ipairs(decos) do
					table.insert(decorationsToRemove, deco)
				end
			end
			
			lastYield = budgetYieldFast(lastYield)
		end
		
		for i, block in ipairs(blocksToRemove) do
			if block and block.Parent then
				block:SetAttribute("BeingRemovedBySaveSystem", true)
				block:Destroy()
				dugRemoved = dugRemoved + 1
			end
			lastYield = budgetYieldFast(lastYield)
		end
		
		for i, deco in ipairs(decorationsToRemove) do
			if deco and deco.Parent then
				deco:SetAttribute("BeingRemovedBySaveSystem", true)
				deco:Destroy()
			end
			lastYield = budgetYieldFast(lastYield)
		end
		
		-- Mark dug positions
		if TerrainGenerator and TerrainGenerator.MarkPositionsAsDug then
			local deepestBlockAtColumn = {}
			for _, blockData in ipairs(plotData.blocks) do
				if blockData.attributes.IsLazyLoaded then
					local colKey = string.format("%d,%d", blockData.gridX, blockData.gridZ)
					local existing = deepestBlockAtColumn[colKey]
					if not existing or blockData.gridY < existing then
						deepestBlockAtColumn[colKey] = blockData.gridY
					end
				end
			end
			
			local dugWorldPositions = {}
			local maxDepth = 7
			
			for _, dugPos in ipairs(plotData.dugPositions) do
				local worldX = dugPos.gridX * BLOCK_SIZE + originOffset.X
				local worldY = dugPos.gridY * BLOCK_SIZE + originOffset.Y
				local worldZ = dugPos.gridZ * BLOCK_SIZE + originOffset.Z
				
				table.insert(dugWorldPositions, Vector3.new(worldX, worldY, worldZ))
				
				local colKey = string.format("%d,%d", dugPos.gridX, dugPos.gridZ)
				local deepestY = deepestBlockAtColumn[colKey]
				
				if deepestY then
					for depth = 1, maxDepth do
						local y = dugPos.gridY - depth
						if y > deepestY then
							table.insert(dugWorldPositions, Vector3.new(worldX, y * BLOCK_SIZE + originOffset.Y, worldZ))
						end
					end
				else
					for depth = 1, maxDepth do
						table.insert(dugWorldPositions, Vector3.new(worldX, (dugPos.gridY - depth) * BLOCK_SIZE + originOffset.Y, worldZ))
					end
				end
			end
			
			TerrainGenerator.MarkPositionsAsDug(dugWorldPositions, plotNumber)
			-- Mirror into the client seed (see clientDugSeed above)
			for _, p in ipairs(dugWorldPositions) do clientDugSeed[#clientDugSeed + 1] = p end
			
			-- Edge walls DISABLED: floor is deep enough now that edge gaps don't need filling.
			-- This load-time fill was spawning unbreakable (CanQuery=false) dark-tinted dirt
			-- columns around the plot border whenever the player dug near the edge and reloaded.
			-- if TerrainGenerator.SpawnEdgeWallsForDugPositions then
			-- 	TerrainGenerator.SpawnEdgeWallsForDugPositions(buildArea, plotNumber, dugWorldPositions)
			-- end
		end
	end
	
	-- Remove terrain-generated blocks that the player previously broke (trees, decorations, cactus, etc.)
	local removedTerrainCount = 0
	if saveData.removedBlocks and #saveData.removedBlocks > 0 then
		-- Build lookup tables for efficient matching
		local treeBlocksByPos = {} -- posKey -> {block}
		local decosByParentPos = {} -- posKey -> {block}
		
		local function posToKey(x, y, z)
			return string.format("%d,%d,%d", math.round(x/BLOCK_SIZE), math.round(y/BLOCK_SIZE), math.round(z/BLOCK_SIZE))
		end
		
		local children = blocksFolder:GetChildren()
		for i, item in ipairs(children) do
			local hasPlacedBy = item:GetAttribute("PlacedBy") ~= nil
			if not hasPlacedBy then
				local isTreeBlock = item:GetAttribute("IsTreeBlock")
				local isCactus = item:GetAttribute("IsCactus")
				local isFallenLog = item:GetAttribute("IsFallenLog")
				local isDecoration = item:GetAttribute("IsDecoration")
				local blockType = item:GetAttribute("BlockType")
				
				if isDecoration then
					local px = item:GetAttribute("ParentBlockX")
					local py = item:GetAttribute("ParentBlockY")
					local pz = item:GetAttribute("ParentBlockZ")
					if px and py and pz then
						local key = posToKey(px, py, pz)
						if not decosByParentPos[key] then decosByParentPos[key] = {} end
						table.insert(decosByParentPos[key], item)
					end
				elseif isTreeBlock or isCactus or isFallenLog or (blockType == "Leaves") then
					local bx = item:GetAttribute("BlockPosX")
					local by = item:GetAttribute("BlockPosY")
					local bz = item:GetAttribute("BlockPosZ")
					if bx and by and bz then
						local key = posToKey(bx, by, bz)
						if not treeBlocksByPos[key] then treeBlocksByPos[key] = {} end
						table.insert(treeBlocksByPos[key], item)
					end
				end
			end
			lastYield = budgetYieldFast(lastYield)
		end
		
		-- Remove matching blocks
		local blocksToRemove = {}
		for _, entry in ipairs(saveData.removedBlocks) do
			local worldX = entry.x * BLOCK_SIZE + originOffset.X
			local worldY = entry.y * BLOCK_SIZE + originOffset.Y
			local worldZ = entry.z * BLOCK_SIZE + originOffset.Z
			local key = posToKey(worldX, worldY, worldZ)
			
			if entry.k == "d" then
				local decos = decosByParentPos[key]
				if decos then
					for _, deco in ipairs(decos) do
						-- Match by block type if specified
						if not entry.t or deco:GetAttribute("BlockType") == entry.t then
							table.insert(blocksToRemove, deco)
						end
					end
				end
			else
				local trees = treeBlocksByPos[key]
				if trees then
					for _, tree in ipairs(trees) do
						if not entry.t or tree:GetAttribute("BlockType") == entry.t then
							table.insert(blocksToRemove, tree)
						end
					end
				end
			end
		end
		
		for i, block in ipairs(blocksToRemove) do
			if block and block.Parent then
				block:SetAttribute("BeingRemovedBySaveSystem", true)
				block:Destroy()
				removedTerrainCount = removedTerrainCount + 1
			end
			lastYield = budgetYieldFast(lastYield)
		end
		
		-- Restore the in-memory tracking so future saves include these
		if TerrainGenerator and TerrainGenerator.SetRemovedGeneratedBlocks then
			local restoredRemovals = {}
			for _, entry in ipairs(saveData.removedBlocks) do
				local worldX = entry.x * BLOCK_SIZE + originOffset.X
				local worldY = entry.y * BLOCK_SIZE + originOffset.Y
				local worldZ = entry.z * BLOCK_SIZE + originOffset.Z
				if entry.k == "d" then
					table.insert(restoredRemovals, {
						kind = "deco", blockType = entry.t,
						parentX = worldX, parentY = worldY, parentZ = worldZ,
					})
				else
					table.insert(restoredRemovals, {
						kind = "tree", blockType = entry.t,
						posX = worldX, posY = worldY, posZ = worldZ,
					})
				end
			end
			TerrainGenerator.SetRemovedGeneratedBlocks(plotNumber, restoredRemovals)
		end
		
		if removedTerrainCount > 0 then
		end
	end
	
	-- Mark lazy-loaded positions
	if TerrainGenerator and TerrainGenerator.MarkPositionsAsDug then
		local allDugPositions = {}
		local surfaceY = buildArea:GetAttribute("TerrainSurfaceY") or 0
		local surfaceGridY = math.round(surfaceY / BLOCK_SIZE)
		
		for _, blockData in ipairs(plotData.blocks) do
			if blockData.attributes.IsLazyLoaded then
				local worldX = blockData.gridX * BLOCK_SIZE + originOffset.X
				local worldY = blockData.gridY * BLOCK_SIZE + originOffset.Y
				local worldZ = blockData.gridZ * BLOCK_SIZE + originOffset.Z
				
				table.insert(allDugPositions, Vector3.new(worldX, worldY, worldZ))
				
				for aboveGridY = blockData.gridY + 1, surfaceGridY - 1 do
					table.insert(allDugPositions, Vector3.new(worldX, aboveGridY * BLOCK_SIZE + originOffset.Y, worldZ))
				end
			end
		end
		
		if #allDugPositions > 0 then
			TerrainGenerator.MarkPositionsAsDug(allDugPositions, plotNumber)
			-- Mirror into the client seed (see clientDugSeed above)
			for _, p in ipairs(allDugPositions) do clientDugSeed[#clientDugSeed + 1] = p end
		end
	end
	
	-- Create blocks from save data
	-- Mark as bulk operation so LightingManager defers recalculation until all blocks are placed
	BulkOperationFlags.StartBulkOperation(buildArea, "load")
	
	-- Cache template references once before the loop (avoids hundreds of FindFirstChild calls)
	local templateCtx = {
		BlockTemplates = getBlockTemplates(),
		BlocksSourceFolder = getBlocksFolder(),
		DecorationsSourceFolder = getDecorationsFolder(),
	}
	
	local created = 0
	local failed = 0
	local createdBlocks = {} -- Collect blocks for batch parenting
	local playerBlockPositions = {} -- Track positions during creation for decoration cleanup
	
	for i, blockData in ipairs(plotData.blocks) do
		local block = createBlockFromSave(blockData, blocksFolder, player.UserId, originOffset, templateCtx)
		if block then
			created = created + 1
			table.insert(createdBlocks, block)
			
			-- Track player block positions for decoration cleanup (eliminates a full child scan later)
			if not blockData.attributes.IsDecoration then
				local key = string.format("%d,%d,%d", blockData.gridX, blockData.gridY, blockData.gridZ)
				playerBlockPositions[key] = true
				-- Also mark the position below (decorations sit on top of grass)
				local keyBelow = string.format("%d,%d,%d", blockData.gridX, blockData.gridY - 1, blockData.gridZ)
				playerBlockPositions[keyBelow] = true
			end
		else
			failed = failed + 1
		end
		
		lastYield = budgetYieldFast(lastYield)  -- Use fast budget during bulk loading
	end
	
	-- Batch-parent created blocks in chunks (reduces yield overhead vs per-block)
	local PARENT_BATCH_SIZE = 20
	for i, block in ipairs(createdBlocks) do
		block.Parent = blocksFolder
		if i % PARENT_BATCH_SIZE == 0 then
			lastYield = budgetYieldFast(lastYield)
		end
	end
	createdBlocks = nil -- Free for GC
	templateCtx = nil
	
	-- Post-load: Remove decorations that overlap with player-placed blocks
	-- Uses playerBlockPositions tracked during creation (no extra child scan needed)
	local decoCleanupCount = 0
	do
		-- Check each decoration against player block positions
		local decosToRemove = {}
		for _, item in ipairs(blocksFolder:GetChildren()) do
			if item:GetAttribute("IsDecoration") then
				local parentX = item:GetAttribute("ParentBlockX")
				local parentY = item:GetAttribute("ParentBlockY")
				local parentZ = item:GetAttribute("ParentBlockZ")
				if parentX and parentY and parentZ then
					-- Check if a player block exists at the decoration's parent position
					-- OR at the decoration's own position (one block above parent)
					local parentKey = string.format("%d,%d,%d", math.round(parentX/BLOCK_SIZE), math.round(parentY/BLOCK_SIZE), math.round(parentZ/BLOCK_SIZE))
					local decoKey = string.format("%d,%d,%d", math.round(parentX/BLOCK_SIZE), math.round(parentY/BLOCK_SIZE) + 1, math.round(parentZ/BLOCK_SIZE))
					if playerBlockPositions[parentKey] or playerBlockPositions[decoKey] then
						table.insert(decosToRemove, item)
					end
				end
			end
		end
		
		for _, deco in ipairs(decosToRemove) do
			if deco and deco.Parent then
				deco:SetAttribute("BeingRemovedBySaveSystem", true)
				deco:Destroy()
				decoCleanupCount = decoCleanupCount + 1
			end
		end
		playerBlockPositions = nil -- Free for GC
		
		if decoCleanupCount > 0 then
		end
	end
	
	-- Post-load glass reconnection (same as before)
	local glassBlocks = {}
	for _, item in ipairs(blocksFolder:GetChildren()) do
		if item:GetAttribute("IsGlass") then
			table.insert(glassBlocks, item)
		end
	end
	
	if #glassBlocks > 0 then
		do
			local glassUpdated = 0
			
			local function snapToGrid(pos)
				return Vector3.new(
					math.round((pos.X - originOffset.X) / BLOCK_SIZE) * BLOCK_SIZE + originOffset.X,
					math.round((pos.Y - originOffset.Y) / BLOCK_SIZE) * BLOCK_SIZE + originOffset.Y,
					math.round((pos.Z - originOffset.Z) / BLOCK_SIZE) * BLOCK_SIZE + originOffset.Z
				)
			end
			
			local function createGlassBlock(glassTemplateName, glassType, glassPos, glassRotationCF, placedBy, connectionType, primaryDir, secondaryDir, orientation)
				-- Resolve per-block: standard glass -> Decorations/Glass, CandyLattice -> RewardSets/CandyBlocks.
				local template = resolveGlassTemplate(glassType, glassTemplateName)
				if not template then return nil end
				
				local newGlass = template:Clone()
				newGlass.Name = glassType
				
				if newGlass:IsA("BasePart") then
					newGlass.Anchored = true
					newGlass.CanCollide = true
				elseif newGlass:IsA("Model") then
					for _, part in ipairs(newGlass:GetDescendants()) do
						if part:IsA("BasePart") then
							part.Anchored = true
							part.CanCollide = true
						end
					end
				end
				
				local glassCFrame = GlassPlacement.GetGlassCFrame(glassPos, glassRotationCF)
				newGlass:PivotTo(glassCFrame)
				
				newGlass:SetAttribute("BlockType", glassType)
				newGlass:SetAttribute("PlacedBy", placedBy)
				newGlass:SetAttribute("IsGlass", true)
				newGlass:SetAttribute("GlassConnectionType", connectionType)
				newGlass:SetAttribute("GlassPrimaryDir", primaryDir)
				newGlass:SetAttribute("GlassSecondaryDir", secondaryDir)
				newGlass:SetAttribute("GlassOrientation", orientation or "NS")
				
				newGlass.Parent = blocksFolder
				return newGlass
			end
			
			for pass = 1, 3 do
				local passUpdated = 0
				
				glassBlocks = {}
				for _, item in ipairs(blocksFolder:GetChildren()) do
					if item:GetAttribute("IsGlass") then
						table.insert(glassBlocks, item)
					end
				end
				
				for _, glass in ipairs(glassBlocks) do
					local rawPos = glass:GetPivot().Position
					local glassPos = snapToGrid(rawPos)
					local glassOrientation = glass:GetAttribute("GlassOrientation") or "NS"
					local glassType = glass:GetAttribute("BlockType")
					local placedBy = glass:GetAttribute("PlacedBy")
					
					if glassOrientation == "corner" or glassOrientation == "tee" or glassOrientation == "4way" then continue end
					
					local newPlacementInfo = GlassPlacement.GetPlacementInfo(glassType, glassPos, blocksFolder, glassOrientation, false)
					local currentConnectionType = glass:GetAttribute("GlassConnectionType") or "isolated"
					
					if newPlacementInfo.connectionType ~= currentConnectionType then
						glass:Destroy()
						local newGlass = createGlassBlock(
							newPlacementInfo.templateName, glassType, glassPos,
							newPlacementInfo.rotationCFrame, placedBy,
							newPlacementInfo.connectionType, newPlacementInfo.primaryDir,
							newPlacementInfo.secondaryDir, glassOrientation
						)
						if newGlass then passUpdated = passUpdated + 1 end
					end
				end
				
				glassUpdated = glassUpdated + passUpdated
				if passUpdated == 0 then break end
			end
		end
	end
	
	-- Apply biome colors to decorations
	local currentBiome = buildArea:GetAttribute("CurrentBiome")
	local currentSeason = buildArea:GetAttribute("CurrentSeason") or "Summer"
	if currentBiome then
		for _, item in ipairs(blocksFolder:GetChildren()) do
			if item:GetAttribute("NeedsBiomeColor") then
				local blockType = item:GetAttribute("BlockType")
				if blockType == "ShortGrass" or blockType == "TallGrass" then
					applyBiomeDecorationColor(item, blockType, currentBiome, currentSeason)
					item:SetAttribute("Biome", currentBiome)
					item:SetAttribute("Season", currentSeason)
				end
				item:SetAttribute("NeedsBiomeColor", nil)
			end
		end
	end
	
	-- End bulk operation - LightingManager will now rescan and recalculate all lights
	BulkOperationFlags.EndBulkOperation(buildArea)
	
	-- NOTE: ScanAndMarkMissingTerrainAsDug was removed because it marks ALL empty underground
	-- positions as dug, which breaks lazy loading (underground blocks are supposed to be empty
	-- until revealed by digging). The dug positions are already correctly restored above from:
	-- 1. plotData.dugPositions (saved dug list)
	-- 2. IsLazyLoaded block inference (marks positions above lazy-loaded blocks as dug)
	
	-- Restore weather
	if WeatherManager and plotData.weather and plotData.weather ~= "Clear" then
		WeatherManager.SetWeather(buildArea, plotNumber, plotData.weather, plotData.weatherIntensity)
	end
	
	-- Scan for saplings
	local scanHandler = SaplingHandler or _G.SaplingHandler
	if scanHandler then
		scanHandler.ScanBuildAreaForSaplings(buildArea, true)
	else
		task.spawn(function()
			task.wait(3)
			local delayedHandler = _G.SaplingHandler
			if delayedHandler then
				delayedHandler.ScanBuildAreaForSaplings(buildArea, true)
			end
		end)
	end
	
	
	-- Auto-repair missing terrain strips (fixes edge strip bug from save/load)
	if TerrainGenerator and TerrainGenerator.RepairMissingTerrain then
		local repaired = TerrainGenerator.RepairMissingTerrain(buildArea, plotNumber)
		if repaired > 0 then
		end
	end
	
	DirtyPlots[player.UserId] = false
	PlayerActiveSlot[player.UserId] = slotNumber
	LoadSucceeded[player.UserId] = true -- Plot loaded successfully; saving is now safe.
	
	-- Seed the client's terrain prediction with this plot's dug positions BEFORE it can
	-- predict into them. Without this, digging next to a previously-dug-out area makes the
	-- client spawn phantom terrain into the saved hole (it has no session record that those
	-- cells are dug), which then gets cleaned up a round-trip later -- the "blocks flash in,
	-- then vanish" glitch. Chunked so no single remote payload is huge on heavily-mined plots.
	if #clientDugSeed > 0 and TerrainDugPositions then
		local SEED_CHUNK = 600
		for i = 1, #clientDugSeed, SEED_CHUNK do
			local batch = {}
			for j = i, math.min(i + SEED_CHUNK - 1, #clientDugSeed) do
				batch[#batch + 1] = clientDugSeed[j]
			end
			TerrainDugPositions:FireClient(player, batch)
		end
	end
	
	-- Update metadata
	local meta = getPlayerMeta(player.UserId)
	if meta then
		meta.activeSlot = slotNumber
		savePlayerMeta(player.UserId, meta)
	end
	
	return true, created
end

-- Legacy load function
local function loadPlot(player, buildArea, plotNumber)
	local activeSlot = PlayerActiveSlot[player.UserId] or 1
	return loadPlotFromSlot(player, buildArea, plotNumber, activeSlot)
end

-- ============================================
-- DELETE SLOT
-- ============================================

local function deleteSlot(player, slotNumber)
	local dataStore = getDataStore()
	if not dataStore then
		return false, "DataStore not available"
	end
	
	local meta = getPlayerMeta(player.UserId)
	if not meta then
		return false, "Could not load player data"
	end
	
	if slotNumber < 1 or slotNumber > meta.maxSlots then
		return false, "Invalid slot number"
	end
	
	-- Delete the slot data
	local key = getSlotKey(player.UserId, slotNumber)
	local success, err = pcall(function()
		dataStore:RemoveAsync(key)
	end)
	
	if not success then
		return false, "Failed to delete: " .. tostring(err)
	end
	
	-- Update metadata
	meta.slots[slotNumber] = nil
	savePlayerMeta(player.UserId, meta)
	
	return true
end

-- ============================================
-- SLOT PURCHASE HANDLING
-- ============================================

local function purchaseExtraSlot(player)
	local meta = getPlayerMeta(player.UserId)
	if not meta then
		return false, "Could not load player data"
	end
	
	if meta.maxSlots >= MAX_PURCHASABLE_SLOTS then
		return false, "Maximum slots reached (" .. MAX_PURCHASABLE_SLOTS .. ")"
	end
	
	-- Game owner gets free slots. Use the BetaConfig override when set, otherwise
	-- fall back to game.CreatorId. This pattern matches isOwner() across the codebase
	-- and is what makes the system work when game ownership is transferred to a group.
	local ownerUserId = (BetaConfig.OWNER_USER_ID ~= 0) and BetaConfig.OWNER_USER_ID or game.CreatorId
	if player.UserId == ownerUserId then
		meta.maxSlots = meta.maxSlots + 1
		savePlayerMeta(player.UserId, meta)
		return true, meta.maxSlots
	end
	
	-- Check if product ID is configured
	if SLOT_PURCHASE_PRODUCT_ID == 0 then
		-- For testing: grant slot without purchase
		warn("[SaveManager] SLOT_PURCHASE_PRODUCT_ID not configured! Granting slot for free (testing only)")
		meta.maxSlots = meta.maxSlots + 1
		savePlayerMeta(player.UserId, meta)
		return true, meta.maxSlots
	end
	
	-- Prompt the purchase
	local success, err = pcall(function()
		MarketplaceService:PromptProductPurchase(player, SLOT_PURCHASE_PRODUCT_ID)
	end)
	
	if not success then
		return false, "Failed to open purchase: " .. tostring(err)
	end
	
	return true, "Purchase prompted"
end

-- Handle Developer Product purchase receipts.
--
-- This is the single ProcessReceipt for the whole game — Roblox only allows
-- one. SaveManager owns the slot-purchase product directly; everything else
-- (coin packs in CoinService, future paid features) registers itself via
-- _G.RegisterReceiptHandler(productId, fn). The handler runs synchronously
-- and must return an Enum.ProductPurchaseDecision.
local ExtraReceiptHandlers = {} -- [productId] = function(receiptInfo) -> Decision

_G.RegisterReceiptHandler = function(productId, handler)
	if type(productId) ~= "number" or productId <= 0 then
		warn("[SaveManager] RegisterReceiptHandler: invalid productId", productId)
		return
	end
	if type(handler) ~= "function" then
		warn("[SaveManager] RegisterReceiptHandler: handler must be a function for productId", productId)
		return
	end
	ExtraReceiptHandlers[productId] = handler
end

local function processReceipt(receiptInfo)
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then
		-- Player left before we could grant. Roblox will retry next session.
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	
	-- === Slot purchase (handled inline) ===
	if receiptInfo.ProductId == SLOT_PURCHASE_PRODUCT_ID then
		local meta = getPlayerMeta(receiptInfo.PlayerId)
		if not meta then
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		if meta.maxSlots >= MAX_PURCHASABLE_SLOTS then
			-- They're already at the cap — nothing to grant, but we still mark
			-- this as processed to prevent infinite retries on rejoin.
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end
		meta.maxSlots = meta.maxSlots + 1
		local saved, err = savePlayerMeta(receiptInfo.PlayerId, meta)
		if not saved then
			warn("[SaveManager] Slot purchase save failed for", player.Name, ":", err)
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		SaveLoadResult:FireClient(player, "slotPurchased", true, meta.maxSlots)
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	-- === Dispatch to registered handlers (coin packs, etc.) ===
	local handler = ExtraReceiptHandlers[receiptInfo.ProductId]
	if handler then
		local ok, decision = pcall(handler, receiptInfo)
		if not ok then
			warn("[SaveManager] Receipt handler errored for productId", receiptInfo.ProductId, ":", decision)
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		if typeof(decision) ~= "EnumItem" then
			warn("[SaveManager] Receipt handler returned non-Enum for productId", receiptInfo.ProductId, "— treating as NotProcessedYet")
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		return decision
	end

	-- === Unknown productId ===
	-- Return NotProcessedYet so Roblox retries on rejoin in case the handler
	-- script just hadn't loaded yet. After enough retries Roblox auto-refunds.
	warn("[SaveManager] No receipt handler registered for productId", receiptInfo.ProductId)
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

-- Set up receipt processor (only if not already set)
pcall(function()
	MarketplaceService.ProcessReceipt = processReceipt
end)

-- Track if handlers are already connected
local HandlersConnected = false

-- ============================================
-- EVENT HANDLERS
-- ============================================

local function connectEventHandlers()
	if HandlersConnected then
		warn("[SaveManager] Event handlers already connected, skipping")
		return
	end
	HandlersConnected = true
	
	-- Get slot info (RemoteFunction)
	GetSlotInfo.OnServerInvoke = function(player)
		-- Check for legacy save migration first
		local meta = getPlayerMeta(player.UserId)
		if not meta then
			meta = {
				version = 1,
				maxSlots = DEFAULT_MAX_SLOTS,
				activeSlot = 1,
				slots = {},
			}
		end
		
		-- Check if no slots have data but legacy save exists
		local hasAnySlotData = false
		for _, _ in pairs(meta.slots) do
			hasAnySlotData = true
			break
		end
		
		if not hasAnySlotData then
			-- Try to migrate legacy save
			local migrated, result = migrateLegacySave(player)
			if migrated then
				meta = getPlayerMeta(player.UserId)  -- Refresh after migration
			end
		end
		
		return {
			maxSlots = meta.maxSlots,
			activeSlot = PlayerActiveSlot[player.UserId] or meta.activeSlot or 1,
			slots = meta.slots,
		}
	end
	
	-- Save to slot
	SavePlot.OnServerEvent:Connect(function(player, slotNumber)
		slotNumber = slotNumber or PlayerActiveSlot[player.UserId] or 1
		
		local buildArea, plotNumber = getPlayerBuildArea(player)
		if not buildArea then
			SaveLoadResult:FireClient(player, "save", false, "You don't own a plot")
			return
		end
		
		local success, blockCount, lifetimeBlocks = savePlotToSlot(player, buildArea, slotNumber)
		if success then
			SaveLoadResult:FireClient(player, "save", true, "Saved " .. blockCount .. " blocks to Slot " .. slotNumber .. "!")
			
			if BetaPlayerManager then
				BetaPlayerManager.CheckAndRegisterIfQualified(player, lifetimeBlocks)
			end
		else
			SaveLoadResult:FireClient(player, "save", false, blockCount)
		end
	end)
	
	-- Load from slot
	LoadPlot.OnServerEvent:Connect(function(player, slotNumber)
		slotNumber = slotNumber or PlayerActiveSlot[player.UserId] or 1
		
		local buildArea, plotNumber = getPlayerBuildArea(player)
		if not buildArea then
			SaveLoadResult:FireClient(player, "load", false, "You don't own a plot")
			return
		end
		
		local success, result = loadPlotFromSlot(player, buildArea, plotNumber, slotNumber)
		if success then
			SaveLoadResult:FireClient(player, "load", true, "Loaded " .. result .. " blocks from Slot " .. slotNumber .. "!")
		else
			SaveLoadResult:FireClient(player, "load", false, result)
		end
	end)
	
	-- Delete slot
	DeleteSlot.OnServerEvent:Connect(function(player, slotNumber)
		
		local success, err = deleteSlot(player, slotNumber)
		if success then
			SaveLoadResult:FireClient(player, "delete", true, "Slot " .. slotNumber .. " deleted")
		else
			SaveLoadResult:FireClient(player, "delete", false, err)
		end
	end)
	
	-- Rename slot
	RenameSlot.OnServerEvent:Connect(function(player, slotNumber, newName)
		
		local meta = getPlayerMeta(player.UserId)
		if not meta then
			SaveLoadResult:FireClient(player, "rename", false, "Could not load player data")
			return
		end
		
		if slotNumber < 1 or slotNumber > meta.maxSlots then
			SaveLoadResult:FireClient(player, "rename", false, "Invalid slot number")
			return
		end
		
		if not meta.slots[slotNumber] then
			SaveLoadResult:FireClient(player, "rename", false, "Slot is empty")
			return
		end
		
		-- Sanitize name
		newName = tostring(newName):gsub("^%s*(.-)%s*$", "%1")
		if newName == "" then
			newName = "Slot " .. slotNumber
		end
		if #newName > 30 then
			newName = string.sub(newName, 1, 30)
		end
		
		-- Update metadata
		meta.slots[slotNumber].name = newName
		local success, err = savePlayerMeta(player.UserId, meta)
		
		if success then
			SaveLoadResult:FireClient(player, "rename", true, newName)
		else
			SaveLoadResult:FireClient(player, "rename", false, "Failed to save: " .. tostring(err))
		end
	end)
	
	-- Import legacy save to a slot
	ImportLegacy.OnServerEvent:Connect(function(player, targetSlot)
		
		local legacyStore = getLegacyDataStore()
		if not legacyStore then
			SaveLoadResult:FireClient(player, "import", false, "Legacy DataStore not available")
			return
		end
		
		-- Get legacy data
		local legacyKey = getLegacyKey(player.UserId)
		local legacyData = nil
		
		local success, err = pcall(function()
			legacyData = legacyStore:GetAsync(legacyKey)
		end)
		
		if not success or not legacyData then
			SaveLoadResult:FireClient(player, "import", false, "No legacy save found")
			return
		end
		
		-- Get metadata
		local meta = getPlayerMeta(player.UserId)
		if not meta then
			SaveLoadResult:FireClient(player, "import", false, "Could not load player data")
			return
		end
		
		if targetSlot < 1 or targetSlot > meta.maxSlots then
			SaveLoadResult:FireClient(player, "import", false, "Invalid slot number")
			return
		end
		
		-- Save legacy data to target slot
		local dataStore = getDataStore()
		if not dataStore then
			SaveLoadResult:FireClient(player, "import", false, "DataStore not available")
			return
		end
		
		local slotKey = getSlotKey(player.UserId, targetSlot)
		local saveSuccess, saveErr = pcall(function()
			dataStore:SetAsync(slotKey, legacyData)
		end)
		
		if not saveSuccess then
			SaveLoadResult:FireClient(player, "import", false, "Failed to import: " .. tostring(saveErr))
			return
		end
		
		-- Update metadata
		local blockCount = legacyData.blocks and #legacyData.blocks or 0
		meta.slots[targetSlot] = {
			name = "Imported Save",
			blockCount = blockCount,
			lastSaved = os.time(),
			biome = legacyData.biome or "Plains",
			terrainStyle = legacyData.terrainStyle or "Flat",
		}
		savePlayerMeta(player.UserId, meta)
		
		
		SaveLoadResult:FireClient(player, "import", true, blockCount)
	end)
	
	-- Purchase slot
	PurchaseSlot.OnServerEvent:Connect(function(player)
		
		local success, result = purchaseExtraSlot(player)
		if success and type(result) == "number" then
			-- Slot was granted (testing mode or instant)
			SaveLoadResult:FireClient(player, "slotPurchased", true, result)
		elseif not success then
			SaveLoadResult:FireClient(player, "slotPurchased", false, result)
		end
		-- If purchase was prompted, wait for receipt callback
	end)
	
	-- Coin-based slot purchase
	PurchaseSlotWithCoins.OnServerEvent:Connect(function(player)
		
		local meta = getPlayerMeta(player.UserId)
		if not meta then
			SaveLoadResult:FireClient(player, "slotPurchased", false, "Could not load player data")
			return
		end
		
		if meta.maxSlots >= MAX_PURCHASABLE_SLOTS then
			SaveLoadResult:FireClient(player, "slotPurchased", false, "Maximum slots reached (" .. MAX_PURCHASABLE_SLOTS .. ")")
			return
		end
		
		local price = CoinConfig.SaveSlotCoinPrice or 1000
		
		if not CoinManager.CanAfford(player.UserId, price) then
			local balance = CoinManager.GetCoins(player.UserId)
			SaveLoadResult:FireClient(player, "slotPurchased", false, "Not enough coins! Need " .. price .. " (have " .. balance .. ")")
			return
		end
		
		local spent = CoinManager.SpendCoins(player.UserId, price, "Save Slot Purchase")
		if not spent then
			SaveLoadResult:FireClient(player, "slotPurchased", false, "Failed to process coin payment")
			return
		end
		
		-- Grant the slot
		meta.maxSlots = meta.maxSlots + 1
		savePlayerMeta(player.UserId, meta)
		SaveLoadResult:FireClient(player, "slotPurchased", true, meta.maxSlots)
	end)
	
	-- Cleanup on player leaving
	-- IMPORTANT: Do NOT clear PlayerActiveSlot here! PlotManager's PlayerRemoving
	-- calls SavePlotSync which needs the active slot. Cleanup happens AFTER save.
	Players.PlayerRemoving:Connect(function(player)
		-- Wait briefly for PlotManager's SavePlotSync to complete first
		-- PlotManager's handler calls SavePlotSync synchronously, which sets SavedOnLeave
		local waitStart = tick()
		while not SavedOnLeave[player.UserId] and (tick() - waitStart) < 5 do
			task.wait(0.1)
		end
		
		if not SavedOnLeave[player.UserId] then
			warn("[SaveManager] Player " .. player.Name .. " left without SavePlotSync completing - attempting emergency save")
			local buildArea = getPlayerBuildArea(player)
			if buildArea then
				local activeSlot = PlayerActiveSlot[player.UserId]
				if not activeSlot then
					local meta = getPlayerMeta(player.UserId)
					activeSlot = meta and meta.activeSlot or 1
				end
				LastSaveTime[player.UserId] = 0
				local success, blockCount = savePlotToSlot(player, buildArea, activeSlot)
				if success then
					
				else
				end
			end
		end
		
		-- Now safe to clean up
		LastSaveTime[player.UserId] = nil
		DirtyPlots[player.UserId] = nil
		PlayerActiveSlot[player.UserId] = nil
		LoadSucceeded[player.UserId] = nil
		SavedOnLeave[player.UserId] = nil
		PlayerMetaCache[player.UserId] = nil
	end)
	
	-- Mark plot as dirty
	local PlaceBlock = Remotes:FindFirstChild("PlaceBlock")
	local RemoveBlock = Remotes:FindFirstChild("RemoveBlock")
	
	if PlaceBlock then
		PlaceBlock.OnServerEvent:Connect(function(player)
			DirtyPlots[player.UserId] = true
		end)
	end
	
	if RemoveBlock then
		RemoveBlock.OnServerEvent:Connect(function(player)
			DirtyPlots[player.UserId] = true
		end)
	end
	
end

connectEventHandlers()

-- ============================================
-- SIGN CLICK HANDLER
-- ============================================

local function setupSaveLoadSigns()
	for i = 1, GridConfig.TOTAL_PLOTS do
		local buildArea = workspace:FindFirstChild(GridConfig.BUILD_AREA_PREFIX .. i)
		if buildArea then
			local saveLoadSign = buildArea:FindFirstChild("SaveLoadSign")
			if saveLoadSign then
				local clickPart = saveLoadSign:FindFirstChild("ClickPart")
				if clickPart then
					local detector = clickPart:FindFirstChild("ClickDetector")
					if not detector then
						detector = Instance.new("ClickDetector")
						detector.MaxActivationDistance = 10
						detector.Parent = clickPart
					end
					
					detector.RightMouseClick:Connect(function(player)
						local ownerUserId = buildArea:GetAttribute("OwnerUserId")
						if ownerUserId == player.UserId then
							OpenSaveLoadUI:FireClient(player)
						end
					end)
				end
			end
		end
	end
end

-- ============================================
-- AUTO-LOAD SYSTEM
-- ============================================

local AutoLoadPlot = Instance.new("BindableFunction")
AutoLoadPlot.Name = "AutoLoadPlot"
AutoLoadPlot.Parent = ReplicatedStorage

AutoLoadPlot.OnInvoke = function(player, buildArea, plotNumber)
	if not player or not buildArea or not plotNumber then
		return false, "Invalid parameters"
	end
	
	-- Get metadata
	local meta = getPlayerMeta(player.UserId)
	if not meta then
		return false, "No save data"
	end
	
	-- Check if legacy migration needed
	local hasAnySlotData = false
	for _, _ in pairs(meta.slots) do
		hasAnySlotData = true
		break
	end
	
	if not hasAnySlotData then
		local migrated = migrateLegacySave(player)
		if migrated then
			meta = getPlayerMeta(player.UserId)
		end
	end
	
	-- Check if active slot has data
	local activeSlot = meta.activeSlot or 1
	if not meta.slots[activeSlot] then
		-- Find first slot with data
		for slotNum, slotInfo in pairs(meta.slots) do
			if slotInfo then
				activeSlot = slotNum
				break
			end
		end
	end
	
	if not meta.slots[activeSlot] then
		return false, "No save data"
	end
	
	
	local success, result = loadPlotFromSlot(player, buildArea, plotNumber, activeSlot)
	
	if success then
		SaveLoadResult:FireClient(player, "autoload", true, "Welcome back! Loaded " .. result .. " blocks from Slot " .. activeSlot .. ".")
		return true, result
	else
		-- IMPORTANT: Load actually failed (not "no save data" -- that returns true with 0
		-- blocks via the fresh-plot path). Tell the player explicitly so they don't start
		-- building on an empty plot and then hit a confusing "Save refused" later. The
		-- save guard will refuse any save until they rejoin, which is exactly what we want.
		warn(string.format("[SaveManager] Auto-load failed for %s slot %d: %s -- saves will be refused this session",
			player.Name, activeSlot, tostring(result)))
		SaveLoadResult:FireClient(player, "autoload", false,
			"Couldn't load your save right now (" .. tostring(result) .. "). Your save is safe -- please rejoin to try again. Saves are disabled this session to protect your data.")
		return false, result
	end
end

-- Sync save for PlotManager
local SavePlotSync = Instance.new("BindableFunction")
SavePlotSync.Name = "SavePlotSync"
SavePlotSync.Parent = ReplicatedStorage

SavePlotSync.OnInvoke = function(player)
	if not player then
		return false, "No player"
	end
	
	-- CRITICAL: If BindToClose already saved this player, skip to avoid overwriting
	-- BindToClose fires first during Studio stop/server shutdown and may save the correct
	-- build area. SavePlotSync firing afterwards could overwrite with stale/wrong data.
	if SavedDuringShutdown[player.UserId] then
		SavedOnLeave[player.UserId] = true
		return true, 0
	end
	
	local buildArea = getPlayerBuildArea(player)
	if not buildArea then
		warn("[SaveManager] SavePlotSync: No build area found for " .. player.Name)
		SavedOnLeave[player.UserId] = true -- Signal cleanup handler even on failure
		return false, "No build area"
	end
	
	-- Get active slot from memory first, then from metadata (NEVER default to 1 blindly)
	local activeSlot = PlayerActiveSlot[player.UserId]
	if not activeSlot then
		local meta = getPlayerMeta(player.UserId)
		activeSlot = meta and meta.activeSlot or 1
	end
	
	-- Log build area details so we can verify we're saving the right plot
	local sizeX = buildArea:GetAttribute("BasePlateSizeX") or 0
	local sizeZ = buildArea:GetAttribute("BasePlateSizeZ") or 0
	local terrainStyle = buildArea:GetAttribute("TerrainStyle") or "?"
	
	LastSaveTime[player.UserId] = 0
	local success, blockCount, lifetimeBlocks = savePlotToSlot(player, buildArea, activeSlot)
	
	-- Signal that save has completed (for cleanup handler)
	SavedOnLeave[player.UserId] = true
	
	if success then
		SavedDuringShutdown[player.UserId] = true
		
		if BetaPlayerManager then
			BetaPlayerManager.CheckAndRegisterIfQualified(player, lifetimeBlocks)
		end
		return true, blockCount
	else
		warn(string.format("[SaveManager] Sync-save FAILED for %s: %s", player.Name, tostring(blockCount)))
		return false, blockCount
	end
end

-- Initialize
task.spawn(function()
	task.wait(3)
	setupSaveLoadSigns()
end)

-- ============================================
-- BIND TO CLOSE
-- ============================================

game:BindToClose(function()
	
	local saveThreads = {}
	local skippedCount = 0
	
	for _, player in ipairs(Players:GetPlayers()) do
		if SavedDuringShutdown[player.UserId] then
			skippedCount = skippedCount + 1
			continue
		end
		
		local buildArea = getPlayerBuildArea(player)
		if buildArea then
			local thread = task.spawn(function()
				-- Get active slot from memory first, then from metadata (NEVER default to 1 blindly)
				local activeSlot = PlayerActiveSlot[player.UserId]
				if not activeSlot then
					local meta = getPlayerMeta(player.UserId)
					activeSlot = meta and meta.activeSlot or 1
					
				end
				
				LastSaveTime[player.UserId] = 0
				local success, result = savePlotToSlot(player, buildArea, activeSlot)
				if success then
					SavedDuringShutdown[player.UserId] = true
					
				end
			end)
			table.insert(saveThreads, thread)
		end
	end
	
	local startTime = tick()
	local timeout = 25
	
	while #saveThreads > 0 and (tick() - startTime) < timeout do
		for i = #saveThreads, 1, -1 do
			if coroutine.status(saveThreads[i]) == "dead" then
				table.remove(saveThreads, i)
			end
		end
		task.wait(0.1)
	end
	
	
end)

-- ============================================
-- PERIODIC AUTOSAVE LOOP (Individual Plots)
-- ============================================
-- Every AUTO_SAVE_INTERVAL seconds, save every player whose plot is dirty AND
-- whose plot was successfully loaded this session. Mirrors MegaPlot's autoSaveLoop
-- in spirit. Protects against work loss on server crashes between leave events.
task.spawn(function()
	while true do
		task.wait(AUTO_SAVE_INTERVAL)
		
		for _, player in ipairs(Players:GetPlayers()) do
			local userId = player.UserId
			-- Only auto-save when there's actually unsaved work AND the plot was loaded OK.
			if DirtyPlots[userId] and LoadSucceeded[userId] then
				local activeSlot = PlayerActiveSlot[userId]
				if activeSlot then
					local buildArea = getPlayerBuildArea(player)
					if buildArea then
						task.spawn(function()
							LastSaveTime[userId] = 0 -- bypass cooldown for autosave
							local success, result = savePlotToSlot(player, buildArea, activeSlot)
							if success then
							else
								warn(string.format("[SaveManager] Auto-save failed for %s slot %d: %s",
									player.Name, activeSlot, tostring(result)))
							end
						end)
					end
				end
			end
		end
	end
end)

-- ============================================
-- TIPS SEEN PERSISTENCE
-- ============================================

local GetTipsSeen = getOrCreateRemote("GetTipsSeen", "RemoteFunction")
local MarkTipsSeen = getOrCreateRemote("MarkTipsSeen")

GetTipsSeen.OnServerInvoke = function(player)
	local meta = getPlayerMeta(player.UserId)
	if meta then
		return meta.tipsSeen == true
	end
	return false
end

MarkTipsSeen.OnServerEvent:Connect(function(player)
	local meta = getPlayerMeta(player.UserId)
	if meta then
		meta.tipsSeen = true
		savePlayerMeta(player.UserId, meta)
	end
end)
