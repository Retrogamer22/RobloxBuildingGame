--[[
	MegaPlotSaveManager (Server)
	Handles saving and loading mega plot data per private server.
	
	Each private server's PrivateServerId is used as the DataStore key,
	so every private server has its own persistent mega plot.
	
	Features:
	- Auto-save when last player leaves
	- Auto-save on server shutdown (BindToClose)
	- Periodic auto-save (every 5 minutes if dirty)
	- Auto-load on server start if saved data exists
	- Manual save via remote (owner only)
	- Uses PlotSerializer for compact block data
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

print("[MegaPlotSaveManager] Script starting...")

-- ============================================
-- WAIT FOR PRIVATE SERVER SYSTEM
-- ============================================

local isPrivateServerValue = ReplicatedStorage:WaitForChild("IsPrivateServer", 15)
if not isPrivateServerValue then
	print("[MegaPlotSaveManager] IsPrivateServer not found, disabling")
	return
end

-- Wait for the value to become true
if not isPrivateServerValue.Value then
	local waitStart = tick()
	while not isPrivateServerValue.Value and (tick() - waitStart) < 10 do
		task.wait(0.1)
	end
	if not isPrivateServerValue.Value then
		print("[MegaPlotSaveManager] Not a private server, disabling")
		return
	end
end

print("[MegaPlotSaveManager] Private server confirmed, initializing...")

-- ============================================
-- DEPENDENCIES
-- ============================================

local GridConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GridConfig"))
local PlotSerializer = require(ReplicatedStorage:WaitForChild("PlotSerializer", 10))
local BlockPresets = require(ReplicatedStorage:WaitForChild("BlockPresets", 10))
local PaintCanVisual = require(ReplicatedStorage:WaitForChild("PaintCanVisual", 10)) -- Paint Mod
local SlabPlacement = require(ReplicatedStorage:WaitForChild("SlabPlacement", 10))
local StairPlacement = require(ReplicatedStorage:WaitForChild("StairPlacement", 10))
local FencePlacement = require(ReplicatedStorage:WaitForChild("FencePlacement", 10))
local GlassPlacement = require(ReplicatedStorage:WaitForChild("GlassPlacement", 10))

-- Resolve a glass-style block's template Model from its type + generic shape name.
-- Mirrors the helper in SaveManager/BlockHandler. Standard glass -> Decorations/Glass;
-- glass-style reward sets (CandyLattice) -> their RewardSets folder. Returns Instance or nil.
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
local ColumnPlacement = require(ReplicatedStorage:WaitForChild("ColumnPlacement", 10))
local VinePlacement = require(ReplicatedStorage:WaitForChild("VinePlacement", 10))
local BlockSpatialIndex = require(ReplicatedStorage:WaitForChild("BlockSpatialIndex", 10))
local ColorPalette = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("ColorPalette"))
local BulkOperationFlags = require(ReplicatedStorage:WaitForChild("BulkOperationFlags", 10))
local PrivateServerConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("PrivateServerConfig"))

local BLOCK_SIZE = GridConfig.BLOCK_SIZE

-- ============================================
-- LOAD PERFORMANCE OPTIMIZATION
-- ============================================
local LOAD_FRAME_BUDGET = 0.008 -- 8ms per frame

local function budgetYield(lastYieldTime)
	if os.clock() - lastYieldTime >= LOAD_FRAME_BUDGET then
		task.wait()
		return os.clock()
	end
	return lastYieldTime
end

-- Server modules (loaded async)
local Modules = ServerScriptService:WaitForChild("Modules", 10)
local PrivateServerManager = require(Modules:WaitForChild("PrivateServerManager"))
local TerrainGenerator = require(Modules:WaitForChild("TerrainGenerator"))

local BiomeConfig = nil
local WeatherManager = nil
local SaplingHandler = nil

task.spawn(function()
	pcall(function()
		BiomeConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("BiomeConfig"))
	end)
	pcall(function()
		WeatherManager = require(Modules:WaitForChild("WeatherManager", 5))
	end)
	-- Wait for SaplingHandler
	for i = 1, 10 do
		task.wait(0.5)
		if _G.SaplingHandler then
			SaplingHandler = _G.SaplingHandler
			break
		end
	end
end)

-- ============================================
-- CONFIGURATION
-- ============================================

local DATASTORE_NAME = "MegaPlotSaves_v1"
local SLOT_DATASTORE_NAME = "MegaPlotSlots_v1" -- Must match MegaPlotSlotHandler
local AUTO_SAVE_INTERVAL = 60 -- 1 minute (mega plots are large, save often)
local SAVE_COOLDOWN = 10

-- ============================================
-- STATE
-- ============================================

local isDirty = false
local lastSaveTime = 0
local isSaving = false
local isLoading = false
local hasSavedData = false -- tracks whether this server has a save
local dataStore = nil
local slotDataStore = nil
local activeSlotNumber = nil -- which slot is currently being played

-- Track whether THIS server's mega plot has been successfully loaded. SAVING IS
-- REFUSED if this flag is not true. Prevents the "transient load failure ->
-- autosave wipes the good save" bug.
local megaPlotLoadSucceeded = false

-- ============================================
-- DATASTORE RETRY HELPER
-- ============================================
-- Wraps a DataStore op in retry-with-backoff. Returns (success, result).
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
			warn(string.format("[MegaPlotSaveManager] DataStore %s failed (attempt %d/%d): %s. Retrying in %.1fs...",
				label, attempt, maxAttempts, tostring(result), backoff))
			task.wait(backoff)
		end
	end
	return false, lastErr
end

-- Track removed terrain-generated blocks (decorations, trees, etc.)
-- These are blocks the terrain generator creates but the player later breaks.
-- We record their positions so they stay removed across save/load cycles.
local removedGeneratedBlocks = {} -- {["gx,gy,gz"] = true}
local childRemovedConnection = nil
local isRegeneratingTerrain = false -- suppress tracking during terrain regen/load

-- ============================================
-- DATASTORE
-- ============================================

local function getDataStore()
	if dataStore then return dataStore end
	local success, result = pcall(function()
		return DataStoreService:GetDataStore(DATASTORE_NAME)
	end)
	if success then
		dataStore = result
		return dataStore
	else
		warn("[MegaPlotSaveManager] Failed to get DataStore:", result)
		return nil
	end
end

local function getDataStoreKey()
	local serverId = PrivateServerManager.GetServerId()
	if not serverId or serverId == "" then
		return nil
	end
	return "mega_" .. serverId
end

-- Build the backup key. The backup is a parallel companion to the primary key,
-- written after every successful primary save.
local function getBackupDataStoreKey()
	local primary = getDataStoreKey()
	if not primary then return nil end
	return primary .. "_backup"
end

local function getSlotDataStore()
	if slotDataStore then return slotDataStore end
	local success, result = pcall(function()
		return DataStoreService:GetDataStore(SLOT_DATASTORE_NAME)
	end)
	if success then
		slotDataStore = result
		return slotDataStore
	else
		warn("[MegaPlotSaveManager] Failed to get slot DataStore:", result)
		return nil
	end
end

local function getSlotKey(slotNumber)
	local serverId = PrivateServerManager.GetServerId()
	if not serverId or serverId == "" then return nil end
	return serverId .. "_slot_" .. tostring(slotNumber)
end

local function getSlotMetaKey()
	local serverId = PrivateServerManager.GetServerId()
	if not serverId or serverId == "" then return nil end
	return serverId .. "_slotmeta"
end

-- Sync save data to the active slot so slot UI stays up to date
local function syncToActiveSlot(saveData)
	if not activeSlotNumber then return end
	
	local slotDS = getSlotDataStore()
	local slotKey = getSlotKey(activeSlotNumber)
	local metaKey = getSlotMetaKey()
	if not slotDS or not slotKey or not metaKey then return end
	
	-- Save block data to the slot
	local success, err = pcall(function()
		slotDS:SetAsync(slotKey, {
			data = saveData,
			savedAt = os.time(),
		})
	end)
	
	if not success then
		warn("[MegaPlotSaveManager] Failed to sync to slot", activeSlotNumber, ":", err)
		return
	end
	
	-- Update slot metadata (block count, timestamp, terrain info)
	local buildArea = nil
	local megaPlotVisibility = _G.MegaPlotVisibility
	if megaPlotVisibility and megaPlotVisibility.GetMegaPlotBuildArea then
		buildArea = megaPlotVisibility.GetMegaPlotBuildArea()
	end
	if not buildArea then
		local megaPlotRoom = Workspace:FindFirstChild("MegaPlotRoom")
		if megaPlotRoom then buildArea = megaPlotRoom:FindFirstChild("MegaPlotBuildArea") end
	end
	
	local terrainStyle = buildArea and buildArea:GetAttribute("TerrainStyle") or "Flat"
	local biome = buildArea and buildArea:GetAttribute("CurrentBiome") or "Plains"
	
	pcall(function()
		local metadata = slotDS:GetAsync(metaKey) or {}
		local existing = metadata[tostring(activeSlotNumber)] or {}
		existing.blockCount = #(saveData.blocks or {})
		existing.savedAt = os.time()
		existing.terrainStyle = terrainStyle
		existing.biome = biome
		-- Keep existing name if set
		existing.name = existing.name or ("Mega Plot " .. activeSlotNumber)
		metadata[tostring(activeSlotNumber)] = existing
		metadata.lastPlayedSlot = activeSlotNumber
		slotDS:SetAsync(metaKey, metadata)
	end)
	
	print("[MegaPlotSaveManager] Synced save to active slot", activeSlotNumber)
end

-- ============================================
-- BIOME COLOR HELPERS (same as SaveManager)
-- ============================================

local function applyBiomeGrassColor(block, biomeName, seasonName)
	if not BiomeConfig or not biomeName then return end
	local biomeColors = BiomeConfig.GetBiomeColors(biomeName)
	if not biomeColors or not biomeColors.GrassColor then return end
	local grassColor = BiomeConfig.GetRandomizedGrassColor(biomeColors.GrassColor, seasonName)
	if block:IsA("Model") then
		local grassPart = block:FindFirstChild("Grass")
		if grassPart and grassPart:IsA("BasePart") then
			grassPart.Color = grassColor
		end
	elseif block:IsA("BasePart") then
		block.Color = grassColor
	end
end

local function applyBiomeDecorationColor(decoration, decorationType, biomeName, seasonName)
	if not BiomeConfig or not biomeName then return end
	if decorationType ~= "ShortGrass" and decorationType ~= "TallGrass" then return end
	local biomeColors = BiomeConfig.GetBiomeColors(biomeName)
	if not biomeColors or not biomeColors.GrassColor then return end
	local baseColor = biomeColors.GrassColor
	local decorationColor = BiomeConfig.GetSeasonalDecorationColor(baseColor, seasonName)
	local h, s, v = Color3.toHSV(decorationColor)
	local valVariation = (math.random() - 0.5) * 0.03
	local finalColor = Color3.fromHSV(h, s, math.clamp(v + valVariation, 0.3, 1))
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
-- BLOCK CREATION FROM SAVE DATA
-- (Mirrors SaveManager's createBlockFromSave)
-- ============================================

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

local function getBlockTemplates()
	return ReplicatedStorage:FindFirstChild("BlockTemplates")
end

local function getBlocksFolder()
	return ReplicatedStorage:FindFirstChild("Blocks")
end

local function getDecorationsFolder()
	return ReplicatedStorage:FindFirstChild("Decorations")
end

local function createBlockFromSave(blockData, blocksFolder, originOffset, templateCtx)
	-- Use cached template references to avoid repeated FindFirstChild calls
	local BlockTemplates = templateCtx and templateCtx.BlockTemplates or getBlockTemplates()
	local BlocksSourceFolder = templateCtx and templateCtx.BlocksSourceFolder or getBlocksFolder()
	local DecorationsSourceFolder = templateCtx and templateCtx.DecorationsSourceFolder or getDecorationsFolder()

	-- LEGACY-SAVE ALIAS: the single "Leaves" block was split into per-type leaf
	-- blocks (OakLeaves/BirchLeaves/SpruceLeaves). Old saves still store "Leaves";
	-- map them to OakLeaves so they resolve to a real preset/template and load.
	if blockData.blockType == "Leaves" then
		blockData.blockType = "OakLeaves"
	end

	local preset = BlockPresets.GetPreset(blockData.blockType)
	if not preset then
		-- FilledFence has no inventory preset - use a minimal fallback
		if blockData.blockType == "FilledFence" and blockData.attributes.FenceConnectionType then
			preset = { Shape = "Block", DefaultColor = Color3.fromRGB(128,128,128), Material = Enum.Material.Plastic, IsFence = true }
		else
			warn("[MegaPlotSaveManager] Unknown block type:", blockData.blockType)
			return nil
		end
	end

	local shapeData = BlockPresets.GetShape(preset.Shape)
	if not shapeData then
		warn("[MegaPlotSaveManager] Unknown shape:", preset.Shape)
		return nil
	end

	local offset = originOffset or Vector3.zero
	local worldPos = Vector3.new(
		blockData.gridX * BLOCK_SIZE + offset.X,
		blockData.gridY * BLOCK_SIZE + offset.Y,
		blockData.gridZ * BLOCK_SIZE + offset.Z
	)

	-- Determine template
	local templateName = shapeData.TemplateName
	local template = nil
	local usedBlockModel = false

	local cornerType = blockData.attributes.CornerType
	local isArchBlock = blockData.attributes.IsArch or StairPlacement.IsArchType(blockData.blockType)
	if cornerType == "inner" then
		if isArchBlock then
			templateName = StairPlacement.GetArchTemplateNames(blockData.blockType).Inner
		else
			templateName = "StairInnerCorner"
		end
	elseif cornerType == "outer" then
		if isArchBlock then
			templateName = StairPlacement.GetArchTemplateNames(blockData.blockType).Outer
		else
			templateName = "StairOuterCorner"
		end
	end

	local fenceType = blockData.attributes.FenceConnectionType
	if fenceType then
		local fenceTemplateMap = {
			["post"] = "FencePost", ["end"] = "FenceEnd", ["middle"] = "FenceMiddle",
			["corner"] = "FenceCorner", ["tee"] = "FenceMiddleCorner", ["cross"] = "FenceMiddleFour",
		}
		templateName = fenceTemplateMap[fenceType] or "FencePost"
	end

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

	local isColumn = blockData.attributes.IsColumn or (BlockPresets.IsColumn and BlockPresets.IsColumn(blockData.blockType))
	local columnModelName = blockData.attributes.ColumnModelName or "ColumnSingle"
	
	-- Check for chest type (needed early for template selection)
	local isChest = BlockPresets.IsChest and BlockPresets.IsChest(blockData.blockType)
	
	-- Check for bed type
	local isBed = BlockPresets.IsBed and BlockPresets.IsBed(blockData.blockType)
	
	-- Check for crafting table type
	local isCraftingTable = BlockPresets.IsCraftingTable and BlockPresets.IsCraftingTable(blockData.blockType)

	-- Check for furnace type
	local isFurnace = BlockPresets.IsFurnace and BlockPresets.IsFurnace(blockData.blockType)

	-- Architrave detection - use saved model name directly (like columns)
	local isArchitrave = blockData.attributes.IsArchitrave or (BlockPresets.IsArchitrave and BlockPresets.IsArchitrave(blockData.blockType))
	local architraveModelName = blockData.attributes.ArchitraveModelName or "ArchitraveSingle"

	local isTorch = blockData.attributes.IsTorch or TorchPlacement.IsTorch(blockData.blockType)
	local torchModelName = blockData.attributes.TorchModelName or "TorchStraight"

	local isSignStanding = blockData.attributes.IsSignStanding or (BlockPresets.IsSignStanding and BlockPresets.IsSignStanding(blockData.blockType))
	local isWallSign = blockData.attributes.IsWallSign or (BlockPresets.IsWallSign and BlockPresets.IsWallSign(blockData.blockType))
	local isSign = isSignStanding or isWallSign
	local signModelName = blockData.attributes.SignModelName

	if preset.IsDecoration then
		if DecorationsSourceFolder then
			template = DecorationsSourceFolder:FindFirstChild(preset.DecorationName or blockData.blockType)
		end
	elseif fenceType then
		-- Check if this is an unfilled frame fence (needs FrameBlocks folder)
		local isUnfilledFrameFence = (blockData.blockType == "FrameFence") and not blockData.attributes.FrameFillBlockId
		if isUnfilledFrameFence then
			local frameBlocksFolder = ReplicatedStorage:FindFirstChild("FrameBlocks")
			local frameFenceTemplates = {
				["post"] = "FencePostFrame", ["end"] = "FenceEndFrame", ["middle"] = "FenceMiddleFrame",
				["corner"] = "FenceCornerFrame", ["tee"] = "FenceMiddleCornerFrame", ["cross"] = "FenceMiddleFourFrame",
			}
			local frameTemplateName = frameFenceTemplates[fenceType] or "FencePostFrame"
			if frameBlocksFolder then template = frameBlocksFolder:FindFirstChild(frameTemplateName) end
		else
			if BlockTemplates then template = BlockTemplates:FindFirstChild(templateName) end
		end
	elseif isGlass then
		template = resolveGlassTemplate(blockData.blockType, templateName)
	elseif isColumn then
		if BlocksSourceFolder then
			template = BlocksSourceFolder:FindFirstChild(columnModelName)
			usedBlockModel = true
		end
	elseif isArchitrave then
		local archFolder = ReplicatedStorage:FindFirstChild("Architraves")
		if archFolder then
			template = archFolder:FindFirstChild(architraveModelName)
			usedBlockModel = true
		end
	elseif isTorch then
		local lightsFolder = ReplicatedStorage:FindFirstChild("Lights")
		if lightsFolder then template = lightsFolder:FindFirstChild(torchModelName); usedBlockModel = true end
	elseif isSign then
		if BlockTemplates and signModelName then template = BlockTemplates:FindFirstChild(signModelName) end
	elseif isChest then
		if BlockTemplates then
			local chestModelName = "SingleChest"
			if blockData.attributes.IsDoubleChest then
				chestModelName = "DoubleChest"
			end
			template = BlockTemplates:FindFirstChild(chestModelName)
		end
	elseif isBed then
		if BlockTemplates then
			template = BlockTemplates:FindFirstChild("Bed")
		end
	elseif isCraftingTable then
		if BlockTemplates then
			template = BlockTemplates:FindFirstChild("CraftingTable")
		end
	elseif isFurnace then
		if BlockTemplates then
			template = BlockTemplates:FindFirstChild("Furnace")
		end
	else
		if BlocksSourceFolder then
			template = BlocksSourceFolder:FindFirstChild(blockData.blockType)
			if template then usedBlockModel = true end
		end
		if not template and preset.BlockModelName and BlocksSourceFolder then
			template = BlocksSourceFolder:FindFirstChild(preset.BlockModelName)
			if template then usedBlockModel = true end
		end
	end

	if not template and preset.BlockModelFolder then
		local folder
		if string.find(preset.BlockModelFolder, "/") then
			local parts = string.split(preset.BlockModelFolder, "/")
			folder = ReplicatedStorage:FindFirstChild(parts[1])
			for i = 2, #parts do
				if folder then folder = folder:FindFirstChild(parts[i]) end
			end
		else
			folder = ReplicatedStorage:FindFirstChild(preset.BlockModelFolder)
		end
		if folder then
			template = folder:FindFirstChild(preset.BlockModelName or templateName)
			if template then usedBlockModel = preset.UseBlockModel end
		end
	end

	-- Filled frame blocks: use solid template instead of frame model
	local isFrameBlock = blockData.attributes.IsFrameBlock or BlockPresets.IsFrameBlock(blockData.blockType)
	local FrameToSolidTemplate = {
		["FrameBlock"] = "Block", ["FrameSlab"] = "Slab", ["FrameStairs"] = "Stair",
		["FrameStairsCornerInner"] = "StairInnerCorner", ["FrameStairsCornerOuter"] = "StairOuterCorner",
		["FrameDoor"] = "FramedDoorFilled",
		["WallpaperFrame"] = "WallpaperTemplate",
		["SignStandingFrame"] = "SignStanding",
		["SignFrame"] = "Sign",
		["CarpetFrame"] = "Block",
		["ArchFrame"] = "Arch", ["ArchInnerFrame"] = "ArchInner", ["ArchOuterFrame"] = "ArchOuter",
		["ArchLargeFrame"] = "ArchLarge", ["ArchLargeInnerFrame"] = "ArchLargeInner", ["ArchLargeOuterFrame"] = "ArchLargeOuter",
	}
	if blockData.attributes.FrameFillBlockId and isFrameBlock then
		local solidName = FrameToSolidTemplate[blockData.blockType]
		if blockData.blockType == "FrameStairs" and cornerType then
			solidName = cornerType == "inner" and "StairInnerCorner" or "StairOuterCorner"
		end
		if (blockData.blockType == "ArchFrame" or blockData.blockType == "ArchLargeFrame") and cornerType then
			local archTemplates = StairPlacement.GetArchTemplateNames(blockData.blockType)
			solidName = cornerType == "inner" and archTemplates.Inner or archTemplates.Outer
		end
		if solidName and BlockTemplates then
			template = BlockTemplates:FindFirstChild(solidName)
			usedBlockModel = false
		end
	end
	
	-- Unfilled frame stair/arch corners: use FrameBlocks corner model
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
			if template then usedBlockModel = true end
		end
	end

	if not template and BlockTemplates then
		template = BlockTemplates:FindFirstChild(templateName)
	end

	if not template then
		warn("[MegaPlotSaveManager] No template for:", blockData.blockType)
		return nil
	end

	local block = template:Clone()
	block.Name = blockData.blockType

	local isDecorationForCollide = preset.IsDecoration or blockData.attributes.IsDecoration

	if block:IsA("BasePart") then
		block.Anchored = true
		if isDecorationForCollide then block.CanCollide = false end
	elseif block:IsA("Model") then
		for _, part in ipairs(block:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Anchored = true
				if isDecorationForCollide then part.CanCollide = false end
			end
		end
	end

	-- Calculate CFrame based on block type
	local rotation = blockData.attributes.Rotation or 0
	local cframe
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
			cframe = CFrame.new(topOfBlock + Vector3.new(0, block.Size.Y / 2, 0)) * rotation45
		elseif block:IsA("Model") then
			-- SugarCaneTrimmed renders half a block high relative to its pivot; lower it
			-- to line up with regular sugar cane (matches the ToolHandler trim).
			local yFix = (blockData.blockType == "SugarCaneTrimmed") and -BLOCK_SIZE / 2 or 0
			cframe = CFrame.new(topOfBlock + Vector3.new(0, yFix, 0)) * rotation45
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
		cframe = DoorPlacementModule.GetDoorCFrame(worldPos,
			blockData.attributes.DoorDirection or 0,
			blockData.attributes.DoorDepth or "middle",
			blockData.attributes.DoorHingeSide or "left")
	elseif isFence then
		local fenceRotation = blockData.attributes.Rotation or 0
		local isFrameFence = blockData.attributes.IsFrameBlock or FencePlacement.IsFrameFence(blockData.blockType)
		-- Filled fence corners: frame corner has different base orientation than solid (+90°)
		if blockData.blockType == "FilledFence" and blockData.attributes.FenceConnectionType == "corner" then
			fenceRotation = (fenceRotation + 90) % 360
		end
		cframe = FencePlacement.GetFenceCFrame(worldPos, fenceRotation, isFrameFence)
	elseif isGlassBlock then
		local glassOrientation = blockData.attributes.GlassOrientation or "NS"
		local rotationCFrame
		if glassOrientation == "corner" or glassOrientation == "tee" or glassOrientation == "4way" then
			local rotationDegrees = blockData.attributes.GlassRotationDegrees or 0
			rotationCFrame = CFrame.Angles(0, math.rad(rotationDegrees), 0)
		else
			rotationCFrame = GlassPlacement.GetGlassRotation(glassOrientation)
		end
		cframe = GlassPlacement.GetGlassCFrame(worldPos, rotationCFrame)
		block:SetAttribute("BlockPosX", worldPos.X)
		block:SetAttribute("BlockPosY", worldPos.Y)
		block:SetAttribute("BlockPosZ", worldPos.Z)
	elseif isLadder then
		cframe = LadderPlacement.GetLadderCFrame(worldPos, blockData.attributes.LadderFace or "North")
	elseif isVine then
		cframe = VinePlacement.GetVineCFrame(worldPos, blockData.attributes.VineFace or "North", blockData.attributes.VineTrimmedFlipped == true)
	elseif isTorchBlock then
		cframe = TorchPlacement.GetTorchCFrame(worldPos, blockData.attributes.TorchFace or "Top")
	elseif isLanternBlock then
		cframe = CFrame.new(worldPos + Vector3.new(0, BLOCK_SIZE / 2, 0))
	elseif isArchitrave then
		local archRotation = blockData.attributes.Rotation or 0
		cframe = CFrame.new(worldPos) * CFrame.Angles(0, math.rad(archRotation), 0)
	elseif isSignStanding then
		cframe = SignPlacement.GetStandingSignCFrame(worldPos, blockData.attributes.SignRotation or 0)
	elseif isWallSign then
		local isOnFencePost = blockData.attributes.IsOnFencePost or false
		cframe = SignPlacement.GetWallSignCFrame(worldPos, blockData.attributes.SignFace or "North", isOnFencePost)
		block:SetAttribute("GridPosX", worldPos.X)
		block:SetAttribute("GridPosY", worldPos.Y)
		block:SetAttribute("GridPosZ", worldPos.Z)
	elseif isWallpaperFrame then
		-- Wallpaper frame: use worldPos (correct grid center) and face to calculate CFrame
		-- worldPos is reconstructed from grid coords and is always the correct grid center,
		-- even if saved HostBlock attributes were rounded to integers (old saves)
		local wallpaperFace = blockData.attributes.WallpaperFace or "Top"
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
		local snowLayers = blockData.attributes.SnowLayers or 1
		local layerHeight = BLOCK_SIZE / 8
		local totalHeight = layerHeight * snowLayers
		if block:IsA("BasePart") then
			block.Size = Vector3.new(BLOCK_SIZE, totalHeight, BLOCK_SIZE)
			block.PivotOffset = CFrame.new(0, -totalHeight / 2, 0)
			block.CanCollide = snowLayers >= 4
		end
		local bottomOfCell = worldPos.Y - BLOCK_SIZE / 2
		local centerY = bottomOfCell + totalHeight / 2
		cframe = CFrame.new(worldPos.X, centerY, worldPos.Z)
		block:SetAttribute("BlockPosX", worldPos.X)
		block:SetAttribute("BlockPosY", worldPos.Y)
		block:SetAttribute("BlockPosZ", worldPos.Z)
	elseif isCarpet then
		-- CarpetFrame: position at bottom of grid cell
		local carpetHeight = CarpetPlacement.CARPET_HEIGHT
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
		-- Apply the same -BLOCK_SIZE/2 pivot offset that the shovel uses (ToolHandler)
		local raisedPos = worldPos + Vector3.new(0, blockData.attributes.PathYOffset, 0)
		cframe = CFrame.new(raisedPos - Vector3.new(0, BLOCK_SIZE / 2, 0)) * CFrame.Angles(0, math.rad(rotation), 0)
		blockData._skipModelOffset = true
		block:SetAttribute("BlockPosX", raisedPos.X)
		block:SetAttribute("BlockPosY", raisedPos.Y)
		block:SetAttribute("BlockPosZ", raisedPos.Z)
		block:SetAttribute("PathBaseX", worldPos.X)
		block:SetAttribute("PathBaseY", worldPos.Y)
		block:SetAttribute("PathBaseZ", worldPos.Z)
		block:SetAttribute("IsTerrainBlock", true)
		block:SetAttribute("IsLazyLoaded", true)
	elseif isChest then
		local chestRotation = blockData.attributes.Rotation or 0
		local chestCenter = worldPos
		if blockData.attributes.IsDoubleChest and blockData.attributes.ChestSecondaryX then
			local secX = blockData.attributes.ChestSecondaryX
			local secY = blockData.attributes.ChestSecondaryY
			local secZ = blockData.attributes.ChestSecondaryZ
			local secondaryWorldPos = Vector3.new(secX, secY, secZ)
			chestCenter = (worldPos + secondaryWorldPos) / 2
		end
		cframe = CFrame.new(chestCenter) * CFrame.Angles(0, math.rad(chestRotation), 0) * CFrame.new(0, 0, 0.15)
		-- Store clean grid position so next save cycle doesn't drift
		block:SetAttribute("BlockPosX", worldPos.X)
		block:SetAttribute("BlockPosY", worldPos.Y)
		block:SetAttribute("BlockPosZ", worldPos.Z)
	elseif isBed then
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
		local randomRotationBlocks = {
			["Dirt"] = true, ["GrassBlock"] = true,
			["SnowGrassBlock"] = true, ["TaigaGrassBlock"] = true,
		}
		if randomRotationBlocks[blockData.blockType] then
			local randomYRotation = math.rad(math.random(0, 3) * 90)
			cframe = CFrame.new(worldPos) * CFrame.Angles(0, randomYRotation, 0)
			rotation = math.deg(randomYRotation)
		elseif blockData.attributes.ColorMode == "Rainbow" then
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
		if isFence or isGlassBlock or isLadder or isTorchBlock or isLanternBlock or isSign or isWallpaperFrame or isCarpet or isArchitrave then
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
				local pivotIsCenter = false
				local bbCFrame = block:GetBoundingBox()
				local pivotOffsetY = block.WorldPivot.Position.Y - bbCFrame.Position.Y
				pivotIsCenter = math.abs(pivotOffsetY) < 0.1
				if not isSurfaceBlock and not isFence and not isGlassBlock and not isLadder and not isTorchBlock and not isLanternBlock and not isSign and not isWallpaperFrame and not isCarpet and not isArchitrave and not isDecoration and not pivotIsCenter then
					block:PivotTo(cframe * CFrame.new(0, -BLOCK_SIZE / 2, 0))
				else
					block:PivotTo(cframe)
				end
			end
		end
	end

	-- Texture-mode coloring (candy canes, etc.): the stripe pattern lives in
	-- grayscale Texture/Decal children, so tinting them to the variant color
	-- produces the colored block. Mirrors BlockHandler's Texture branch. Runs
	-- independently of shouldApplyColor because these presets carry no Material
	-- (which would gate that path off) and must NOT tint the white Bark part.
	if preset.StripeColorMode == "Texture" and preset.ApplyColor ~= false and preset.DefaultColor then
		local tint = preset.DefaultColor
		for _, desc in ipairs(block:GetDescendants()) do
			if desc:IsA("Texture") or desc:IsA("Decal") then
				desc.Color3 = tint
			elseif desc:IsA("BasePart") and desc.Name == "Core" then
				desc.Color = tint
			end
		end
		if block:IsA("BasePart") then
			for _, child in ipairs(block:GetChildren()) do
				if child:IsA("Texture") or child:IsA("Decal") then
					child.Color3 = tint
				end
			end
		end
	end

	-- Apply color/material
	local shouldApplyColor = (not usedBlockModel or isLadder or isFence or preset.ApplyColor) and preset.DefaultColor and preset.Material and not isDecoration and not isBed and preset.StripeColorMode ~= "Texture"
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
			block.Color = color; block.Material = material
			block.MaterialVariant = materialVariant
		elseif block:IsA("Model") then
			-- Crafting table: tint leather Texture/Decal on Side/Top parts before BasePart loop
			if isCraftingTable then
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
			for _, part in ipairs(block:GetDescendants()) do
				if part:IsA("BasePart") then
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
					part.Color = color; part.Material = material
					part.MaterialVariant = materialVariant
				end
			end
		end
	end
	
	-- Glass: never restore with the refractive Glass material.
	if GlassPlacement.IsAnyGlass(blockData.blockType) then
		GlassPlacement.NormalizeGlassMaterial(block)
	end

	-- Colored glass: recolor face textures + 70% transparency to match how it was
	-- placed. Uses the saved custom color when present, else the preset tint.
	if GlassPlacement.IsColoredGlass(blockData.blockType) and preset.DefaultColor then
		local gColor = preset.DefaultColor
		local cr, cg, cb = blockData.attributes.CustomColorR, blockData.attributes.CustomColorG, blockData.attributes.CustomColorB
		if cr and cg and cb then gColor = Color3.fromRGB(cr, cg, cb) end
		GlassPlacement.StyleColoredGlass(block, gColor)
	end

	-- Paint Mod: brush-painted blocks carry a blended color (CustomColorR/G/B), a coat count
	-- (PaintCoats) and a primer-coat count (PaintPrimerCoats). shouldApplyColor above only covers
	-- template/ApplyColor blocks, so restore the paint here for ANY block type. Snapshot the
	-- default look first (so the sponge can fully revert post-reload), then ApplyCoats re-tints
	-- the block and rebuilds the concrete cover textures from the primer-coat count. All paint
	-- attributes round-trip via the generic attribute loop below, so this survives save/load.
	if blockData.attributes.IsPainted then
		local pr = blockData.attributes.CustomColorR
		local pg = blockData.attributes.CustomColorG
		local pb = blockData.attributes.CustomColorB
		if pr and pg and pb then
			local paintColor = Color3.fromRGB(pr, pg, pb)
			local primerCoats = blockData.attributes.PaintPrimerCoats or 0
			PaintCanVisual.CaptureOriginal(block)
			PaintCanVisual.ApplyCoats(block, paintColor, primerCoats)
		end
	end
	
	-- Paint Mod: restore a placed paint can's PaintColor union. Preset cans derive color from
	-- the preset; custom (mixer) cans carry cr/cg/cb; empty cans set IsEmptyCan.
	if BlockPresets.IsPaintCan and BlockPresets.IsPaintCan(blockData.blockType) then
		local canColor = preset and preset.DefaultColor
		local ccr = blockData.attributes.CustomColorR
		local ccg = blockData.attributes.CustomColorG
		local ccb = blockData.attributes.CustomColorB
		if ccr and ccg and ccb then canColor = Color3.fromRGB(ccr, ccg, ccb) end
		PaintCanVisual.ApplyCan(block, canColor, blockData.attributes.IsEmptyCan == true)
	end
	
	-- Restore frame block fill color/material
	local frameFillId = blockData.attributes.FrameFillBlockId
	-- LEGACY-SAVE ALIAS: pre-split saves stored the single "Leaves" fill id; map it to
	-- OakLeaves so it resolves to a real preset/model (mirrors the blockType alias above).
	if frameFillId == "Leaves" then frameFillId = "OakLeaves" end
	if frameFillId and (isFrameBlock or blockData.blockType == "FilledFence") then
		local fillPreset = BlockPresets.GetPreset(frameFillId)
		if fillPreset then
			local fillColor = fillPreset.DefaultColor or Color3.fromRGB(128, 128, 128)
			local fillMaterial = fillPreset.Material or Enum.Material.Plastic
			local fillMaterialVariant = fillPreset.MaterialVariant or ""
			local savedR = blockData.attributes.FrameFillColorR
			local savedG = blockData.attributes.FrameFillColorG
			local savedB = blockData.attributes.FrameFillColorB
			if savedR and savedG and savedB then fillColor = Color3.fromRGB(savedR, savedG, savedB) end
			local savedVariant = blockData.attributes.FrameFillMaterialVariant
			if savedVariant then fillMaterialVariant = savedVariant end
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
				block.Color = fillColor; block.Material = fillMaterial
				block.MaterialVariant = fillMaterialVariant ~= "" and fillMaterialVariant or ""
			elseif block:IsA("Model") then
				for _, part in ipairs(block:GetDescendants()) do
					if part:IsA("BasePart") then
						part.Color = fillColor; part.Material = fillMaterial
						part.MaterialVariant = fillMaterialVariant ~= "" and fillMaterialVariant or ""
					end
				end
			end
			-- Texture-mode fill (candy canes, etc.): stripes live in Texture/Decal
			-- objects on the source model, not a MaterialVariant. Copy them onto the
			-- filled block and tint to the fill color; keep the part white as the
			-- stripe background.
			if fillPreset.StripeColorMode == "Texture" then
				local srcFolder = ReplicatedStorage
				for _, n in ipairs(string.split(fillPreset.BlockModelFolder or "", "/")) do
					srcFolder = srcFolder and srcFolder:FindFirstChild(n)
				end
				local srcModel = srcFolder and srcFolder:FindFirstChild(fillPreset.BlockModelName or frameFillId)
				if srcModel then
					local stripes = {}
					local srcMaterial, srcMatVariant
					local scanRoot = srcModel:IsA("BasePart") and srcModel:GetChildren() or srcModel:GetDescendants()
					for _, c in ipairs(scanRoot) do
						if c:IsA("Texture") or c:IsA("Decal") then table.insert(stripes, c) end
					end
					-- Filled candy frames always use the PixelCandyCaneAlt material variant.
					-- Look it up in MaterialService so we set the matching BaseMaterial — a
					-- MaterialVariant only renders when part.Material == its BaseMaterial.
					-- Fall back to the source block's authored material if the variant is missing.
					local altMV = game:GetService("MaterialService"):FindFirstChild("PixelCandyCaneAlt", true)
					if altMV and altMV:IsA("MaterialVariant") then
						srcMaterial = altMV.BaseMaterial
						srcMatVariant = "PixelCandyCaneAlt"
					elseif srcModel:IsA("BasePart") then
						srcMaterial = srcModel.Material
						srcMatVariant = srcModel.MaterialVariant
					else
						local body = srcModel.PrimaryPart or srcModel:FindFirstChild("Bark") or srcModel:FindFirstChildWhichIsA("BasePart")
						if body then
							srcMaterial = body.Material
							srcMatVariant = body.MaterialVariant
						end
					end
					local function applyStripes(part)
						part.Color = Color3.new(1, 1, 1)
						if srcMaterial then
							part.Material = srcMaterial
							part.MaterialVariant = srcMatVariant or ""
						end
						for _, tex in ipairs(stripes) do
							local copy = tex:Clone()
							copy.Color3 = fillColor
							copy.Parent = part
						end
					end
					if block:IsA("BasePart") then
						applyStripes(block)
					else
						for _, part in ipairs(block:GetDescendants()) do
							if part:IsA("BasePart") then applyStripes(part) end
						end
					end
				end
			end
			-- Leaf-mode fill (mirror of BlockHandler): leaf blocks show their colour on the
			-- Part with a face Texture on top. Recompute the randomized biome/season leaf
			-- colour from the fill id (same as a placed leaf block on load), then copy the
			-- leaf Part's transparency/material + face textures. Recomputing means old saves
			-- (stored flat, pre-texture) auto-upgrade to the textured + randomized look.
			if string.find(frameFillId, "Leaves") and BiomeConfig then
				local leafType = (string.find(frameFillId, "Birch") and "Birch")
					or (string.find(frameFillId, "Spruce") and "Spruce") or "Oak"
				local fbiome = blockData.attributes.Biome
				local fseason = blockData.attributes.Season or "Summer"
				local leafColor
				if fbiome then
					leafColor = BiomeConfig.GetRandomizedTintedLeafColor(leafType, fbiome, fseason)
				else
					local leafConfig = BiomeConfig.LeafTypes[leafType] or BiomeConfig.LeafTypes.Oak
					leafColor = BiomeConfig.GetRandomizedLeafColor(leafConfig.Color)
				end
				leafColor = leafColor or fillColor
				local blocksFolder = ReplicatedStorage:FindFirstChild("Blocks")
				local leafModel = blocksFolder and blocksFolder:FindFirstChild(frameFillId)
				local leafPart = leafModel and (leafModel:IsA("BasePart") and leafModel or leafModel:FindFirstChildWhichIsA("BasePart"))
				if leafPart then
					local faces = {}
					for _, c in ipairs(leafPart:GetChildren()) do
						if c:IsA("Texture") or c:IsA("Decal") or c:IsA("SurfaceAppearance") then
							table.insert(faces, c)
						end
					end
					local function applyLeaf(part)
						part.Transparency = leafPart.Transparency
						part.Material = leafPart.Material
						part.MaterialVariant = leafPart.MaterialVariant or ""
						part.Color = leafColor
						for _, ex in ipairs(part:GetChildren()) do
							if ex:IsA("Texture") or ex:IsA("Decal") or ex:IsA("SurfaceAppearance") then
								ex:Destroy()
							end
						end
						for _, f in ipairs(faces) do
							local c = f:Clone()
							-- Leaves show their colour on the texture (see visibleBlockColor), not
							-- the part, so tint each copied face or every fill is the same shade.
							if c:IsA("Texture") or c:IsA("Decal") then
								c.Color3 = leafColor
							end
							c.Parent = part
						end
					end
					if block:IsA("BasePart") then
						applyLeaf(block)
					else
						for _, part in ipairs(block:GetDescendants()) do
							if part:IsA("BasePart") then applyLeaf(part) end
						end
					end
				end
			end
		end
	end

	-- Apply attributes
	block:SetAttribute("BlockType", blockData.blockType)
	block:SetAttribute("PlacedBy", 0) -- Shared plot, no single owner

	local wireConnections = nil
	for attrName, attrValue in pairs(blockData.attributes) do
		if string.sub(attrName, 1, 1) == "_" then
			if attrName == "_WireConnections" then wireConnections = attrValue end
		else
			block:SetAttribute(attrName, attrValue)
		end
	end

	if wireConnections and type(wireConnections) == "table" then
		for i, targetBlockId in ipairs(wireConnections) do
			block:SetAttribute("WireConn_" .. tostring(i), targetBlockId)
		end
	end

	if blockData.attributes.IsLazyLoaded then
		block:SetAttribute("IsTerrainBlock", true)
		block:SetAttribute("BlockPosX", worldPos.X)
		block:SetAttribute("BlockPosY", worldPos.Y)
		block:SetAttribute("BlockPosZ", worldPos.Z)
	end

	if isDecorationForCollide then
		block:SetAttribute("IsDecoration", true)
		block:SetAttribute("ParentBlockX", math.round(worldPos.X))
		block:SetAttribute("ParentBlockY", math.round(worldPos.Y))
		block:SetAttribute("ParentBlockZ", math.round(worldPos.Z))
	end

	-- Handle special block types
	local isLamp = string.find(blockData.blockType, "Lamp") ~= nil
	if isLamp then
		local isPowered = blockData.attributes.IsPowered or false
		block:SetAttribute("IsPowered", isPowered)
		block:SetAttribute("IsControllable", true)
		for _, desc in ipairs(block:GetDescendants()) do
			if desc:IsA("PointLight") or desc:IsA("SpotLight") or desc:IsA("SurfaceLight") then
				desc.Enabled = isPowered
			end
		end
	end

	local isGlowstoneBlock = blockData.attributes.IsGlowstone or (BlockPresets.IsGlowstone and BlockPresets.IsGlowstone(blockData.blockType))
	if isGlowstoneBlock then
		local glowColor = nil
		local glowstoneColorName = blockData.attributes.GlowstoneColor
		if glowstoneColorName and ColorPalette then glowColor = ColorPalette.getColor(glowstoneColorName) end
		if not glowColor and preset.DefaultColor then glowColor = preset.DefaultColor end
		if glowColor then
			if block:IsA("BasePart") then block.Color = glowColor
			elseif block:IsA("Model") then
				for _, part in ipairs(block:GetDescendants()) do
					if part:IsA("BasePart") then part.Color = glowColor end
				end
			end
			-- Boost saturation for emitted light color (more vivid than block surface)
			local h, s, v = glowColor:ToHSV()
			local boostedLightColor = Color3.fromHSV(h, math.clamp(s * 1.5, 0, 1), math.clamp(v * 1.15, 0, 1))
			for _, desc in ipairs(block:GetDescendants()) do
				if desc:IsA("PointLight") or desc:IsA("SpotLight") or desc:IsA("SurfaceLight") then
					desc.Color = boostedLightColor
				end
			end
		end
	end

	if isDoor then
		block:SetAttribute("IsDoor", true)
		block:SetAttribute("IsOpen", blockData.attributes.IsOpen or false)
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
		if block:IsA("BasePart") then block.CanCollide = false
		elseif block:IsA("Model") then
			for _, part in ipairs(block:GetDescendants()) do
				if part:IsA("BasePart") then part.CanCollide = false end
			end
		end
	end

	-- Vines: full server-side parity with VineHandler.createVine so Shears, cascade-break,
	-- climbing, and the spread system all work on loaded vines. Mirrors SaveManager logic.
	if isVine then
		if block:IsA("BasePart") then
			block.CanCollide = false
		elseif block:IsA("Model") then
			for _, part in ipairs(block:GetDescendants()) do
				if part:IsA("BasePart") then part.CanCollide = false end
			end
		end
		
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

	if isSign then
		if block:IsA("BasePart") then block.CanCollide = false
		elseif block:IsA("Model") then
			for _, part in ipairs(block:GetDescendants()) do
				if part:IsA("BasePart") then part.CanCollide = false end
			end
		end
		-- Apply wood color - skip for filled frame signs (their color comes from fill restoration)
		if preset.DefaultColor and preset.Material and not blockData.attributes.FrameFillBlockId then
			local wc, wm, wmv = preset.DefaultColor, preset.Material, preset.MaterialVariant or ""
			if block:IsA("BasePart") then
				block.Color = wc; block.Material = wm
				if wmv ~= "" then block.MaterialVariant = wmv end
			elseif block:IsA("Model") then
				for _, part in ipairs(block:GetDescendants()) do
					if part:IsA("BasePart") then
						part.Color = wc; part.Material = wm
						if wmv ~= "" then part.MaterialVariant = wmv end
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
				local cs = pistonArm.Size
				pistonArm.Size = Vector3.new(cs.X, cs.Y + ARM_SCALE_AMOUNT, cs.Z)
				pistonArm.Position = pistonArm.Position + (moveDirection * (ARM_SCALE_AMOUNT / 2))
			end
			if pistonTop:IsA("Model") then
				for _, part in ipairs(pistonTop:GetDescendants()) do
					if part:IsA("BasePart") and part.Name ~= "PistonArm" then
						part.CFrame = part.CFrame + moveOffset
					end
				end
			end
		end
	end

	-- Restore biome colors
	local savedBiome = blockData.attributes.Biome
	local savedSeason = blockData.attributes.Season or "Summer"
	local isGrassBlockType = blockData.blockType == "GrassBlock" or blockData.blockType == "SnowGrassBlock" or blockData.blockType == "TaigaGrassBlock"
	if isGrassBlockType and savedBiome then
		applyBiomeGrassColor(block, savedBiome, savedSeason)
	end
	if (blockData.blockType == "ShortGrass" or blockData.blockType == "TallGrass") then
		if savedBiome then
			applyBiomeDecorationColor(block, blockData.blockType, savedBiome, savedSeason)
		end
		block:SetAttribute("NeedsBiomeColor", savedBiome == nil)
	end
	if blockData.blockType and blockData.blockType:find("Leaves") ~= nil and BiomeConfig then
		local treeType = blockData.attributes.TreeType or "Oak"
		local leafColor
		if savedBiome then
			leafColor = BiomeConfig.GetRandomizedTintedLeafColor(treeType, savedBiome, savedSeason)
		else
			local leafConfig = BiomeConfig.LeafTypes[treeType] or BiomeConfig.LeafTypes.Oak
			leafColor = BiomeConfig.GetRandomizedLeafColor(leafConfig.Color)
		end
		if leafColor then
			if block:IsA("BasePart") then block.Color = leafColor
			elseif block:IsA("Model") then
				for _, part in ipairs(block:GetDescendants()) do
					if part:IsA("BasePart") then part.Color = leafColor end
				end
			end
			-- Leaves show their colour on the face Texture/Decal, not the part .Color
			-- (see TreeGenerator.CreateLeaves / visibleBlockColor), so tint those too or
			-- saved trees reload to a flat, uniform shade.
			for _, d in ipairs(block:GetDescendants()) do
				if d:IsA("Decal") then  -- Texture is a subclass of Decal
					d.Color3 = leafColor
				end
			end
		end
	end

	-- NOTE: Parent is NOT set here for batch-parenting optimization.
	-- The caller is responsible for setting block.Parent = blocksFolder after creation.

	-- Add hitbox for non-full blocks
	local isSurfaceBlock = blockData.attributes.SurfaceFace ~= nil
	local isSnowLayerPartial = blockData.blockType == "SnowLayer" and (blockData.attributes.SnowLayers or 1) < 8
	if isFence or isGlassBlock or isLadder or isTorchBlock or isLanternBlock or isSign or isSurfaceBlock or isDoor or isSnowLayerPartial or isWallpaperFrame or isCarpet or isFrameBlock or isColumn or isArchitrave or isChest or isCraftingTable or isFurnace or isBed then
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
			local bedSpatialIndex = BlockSpatialIndex.GetOrCreate(blocksFolder)
			if bedSpatialIndex then
				local footPos = Vector3.new(blockData.attributes.BedSecondaryX, blockData.attributes.BedSecondaryY, blockData.attributes.BedSecondaryZ)
				bedSpatialIndex:RegisterSecondaryPosition(block, footPos)
			end
		end
		-- DoubleChest: resize hitbox to span both cells
		if blockData.attributes.IsDoubleChest and blockData.attributes.ChestSecondaryX then
			local hitbox = block:FindFirstChild("Hitbox")
			if hitbox then
				local chestRot = (blockData.attributes.Rotation or 0) % 360
				local secPos = Vector3.new(blockData.attributes.ChestSecondaryX, blockData.attributes.ChestSecondaryY, blockData.attributes.ChestSecondaryZ)
				local midpoint = (worldPos + secPos) / 2
				hitbox.Size = Vector3.new(
					(chestRot == 0 or chestRot == 180) and BLOCK_SIZE * 2 or BLOCK_SIZE,
					BLOCK_SIZE,
					(chestRot == 90 or chestRot == 270) and BLOCK_SIZE * 2 or BLOCK_SIZE
				)
				hitbox.CFrame = CFrame.new(midpoint)
			end
		end
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
	if preset.MaterialVariant and preset.MaterialVariant ~= "" and (preset.ApplyColor or not usedBlockModel) then
		local mv = preset.MaterialVariant
		if block:IsA("BasePart") then
			block.MaterialVariant = mv
		elseif block:IsA("Model") then
			for _, part in ipairs(block:GetDescendants()) do
				if part:IsA("BasePart") and part.Name ~= "Hitbox" then
					-- Skip chest Latch/Darkness/Edge (keep their own template MaterialVariant)
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
					-- Skip crafting table non-Block parts
					if isCraftingTable and part.Name ~= "Block" then continue end
					part.MaterialVariant = mv
				end
			end
		end
	end

	return block
end

-- ============================================
-- GLASS RECONNECTION (post-load)
-- ============================================

local function reconnectGlass(blocksFolder)
	local function snapToGrid(pos)
		return Vector3.new(
			math.round(pos.X / BLOCK_SIZE) * BLOCK_SIZE,
			math.round(pos.Y / BLOCK_SIZE) * BLOCK_SIZE,
			math.round(pos.Z / BLOCK_SIZE) * BLOCK_SIZE
		)
	end

	for pass = 1, 3 do
		local passUpdated = 0
		local glassBlocks = {}
		for _, item in ipairs(blocksFolder:GetChildren()) do
			if item:GetAttribute("IsGlass") then table.insert(glassBlocks, item) end
		end

		for _, glass in ipairs(glassBlocks) do
			local rawPos = glass:GetPivot().Position
			local glassPos = snapToGrid(rawPos)
			local glassOrientation = glass:GetAttribute("GlassOrientation") or "NS"
			local glassType = glass:GetAttribute("BlockType")

			if glassOrientation == "corner" or glassOrientation == "tee" or glassOrientation == "4way" then continue end

			local newInfo = GlassPlacement.GetPlacementInfo(glassType, glassPos, blocksFolder, glassOrientation, false)
			local currentType = glass:GetAttribute("GlassConnectionType") or "isolated"

			if newInfo.connectionType ~= currentType then
				-- Sample the old pane's color first so colored glass keeps its tint after
				-- the connection-type swap (the freshly cloned template is uncolored).
				local sampledColor
				if glass:IsA("BasePart") then
					sampledColor = glass.Color
				elseif glass:IsA("Model") then
					local fp = glass:FindFirstChildWhichIsA("BasePart", true)
					if fp then sampledColor = fp.Color end
				end
				glass:Destroy()
				local newTemplate = resolveGlassTemplate(glassType, newInfo.templateName)
				if newTemplate then
					local newGlass = newTemplate:Clone()
					newGlass.Name = glassType
					newGlass:SetAttribute("BlockType", glassType)
					newGlass:SetAttribute("PlacedBy", 0)
					newGlass:SetAttribute("IsGlass", true)
					newGlass:SetAttribute("GlassConnectionType", newInfo.connectionType)
					newGlass:SetAttribute("GlassPrimaryDir", newInfo.primaryDir)
					newGlass:SetAttribute("GlassSecondaryDir", newInfo.secondaryDir)
					newGlass:SetAttribute("GlassOrientation", glassOrientation)
					if newGlass:IsA("BasePart") then newGlass.Anchored = true; newGlass.CanCollide = true
					elseif newGlass:IsA("Model") then
						for _, p in ipairs(newGlass:GetDescendants()) do
							if p:IsA("BasePart") then p.Anchored = true; p.CanCollide = true end
						end
					end
					newGlass:PivotTo(GlassPlacement.GetGlassCFrame(glassPos, newInfo.rotationCFrame))
					newGlass.Parent = blocksFolder
					GlassPlacement.NormalizeGlassMaterial(newGlass)
					if GlassPlacement.IsColoredGlass(glassType) and sampledColor then
						GlassPlacement.StyleColoredGlass(newGlass, sampledColor)
					end
					passUpdated += 1
				end
			end
		end

		if passUpdated == 0 then break end
	end

	-- Connected-glass texture culling for the freshly loaded mega-plot.
	GlassPlacement.CullAllGlass(blocksFolder)
end

-- ============================================
-- REMOVED GENERATED BLOCKS TRACKING
-- ============================================
-- When players break terrain-generated blocks (decorations, trees, etc.),
-- we record their positions so they stay removed after save/load.

local function getTerrainOrigin(buildArea)
	local posX = buildArea:GetAttribute("BasePlatePositionX")
	local posZ = buildArea:GetAttribute("BasePlatePositionZ")
	local sizeX = buildArea:GetAttribute("BasePlateSizeX")
	local sizeZ = buildArea:GetAttribute("BasePlateSizeZ")
	local terrainSurfaceY = buildArea:GetAttribute("TerrainSurfaceY")
	if posX and posZ and sizeX and sizeZ then
		return Vector3.new(
			posX - sizeX / 2 + BLOCK_SIZE / 2,
			terrainSurfaceY or 0,
			posZ - sizeZ / 2 + BLOCK_SIZE / 2
		)
	end
	return nil
end

local function worldPosToRelGridKey(worldPos, origin)
	if not origin then return nil end
	local gx = math.round((worldPos.X - origin.X) / BLOCK_SIZE)
	local gy = math.round((worldPos.Y - origin.Y) / BLOCK_SIZE)
	local gz = math.round((worldPos.Z - origin.Z) / BLOCK_SIZE)
	return string.format("%d,%d,%d", gx, gy, gz)
end

local function setupRemovedBlockTracking(buildArea)
	-- Disconnect any previous listener
	if childRemovedConnection then
		childRemovedConnection:Disconnect()
		childRemovedConnection = nil
	end

	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder then return end

	childRemovedConnection = blocksFolder.ChildRemoved:Connect(function(block)
		-- Don't track during terrain regen, loading, or save-system removals
		if isRegeneratingTerrain or isLoading then return end
		if block:GetAttribute("BeingRemovedBySaveSystem") then return end

		local isGenerated = false
		local worldPos = nil

		-- Terrain-generated decoration (grass, flowers, cactus, etc.)
		if block:GetAttribute("IsDecoration") and not block:GetAttribute("PlacedBy") then
			isGenerated = true
			-- Use parent block position (on the grid) for decorations
			local px = block:GetAttribute("ParentBlockX")
			local py = block:GetAttribute("ParentBlockY")
			local pz = block:GetAttribute("ParentBlockZ")
			if px and py and pz then
				worldPos = Vector3.new(px, py, pz)
			end
		end

		-- Terrain-generated tree block (logs and leaves)
		if block:GetAttribute("IsTreeBlock") and not block:GetAttribute("PlacedBy") then
			isGenerated = true
			if block:IsA("BasePart") then
				worldPos = block.Position
			elseif block:IsA("Model") then
				local part = block.PrimaryPart or block:FindFirstChildWhichIsA("BasePart")
				if part then worldPos = part.Position end
			end
		end

		-- Leaves without PlacedBy (terrain-generated, but might not have IsTreeBlock)
		local blockType = block:GetAttribute("BlockType")
		if blockType and blockType:find("Leaves") ~= nil and not block:GetAttribute("PlacedBy") and not isGenerated then
			isGenerated = true
			if block:IsA("BasePart") then
				worldPos = block.Position
			elseif block:IsA("Model") then
				local part = block.PrimaryPart or block:FindFirstChildWhichIsA("BasePart")
				if part then worldPos = part.Position end
			end
		end

		if isGenerated and worldPos then
			local origin = getTerrainOrigin(buildArea)
			local key = worldPosToRelGridKey(worldPos, origin)
			if key then
				removedGeneratedBlocks[key] = true
				isDirty = true
			end
		end
	end)

	print("[MegaPlotSaveManager] Removed-block tracking active on", buildArea.Name)
end

-- ============================================
-- SAVE MEGA PLOT
-- ============================================

function saveMegaPlot(options)
	if isSaving then
		print("[MegaPlotSaveManager] Save already in progress, skipping")
		return false, "Save in progress"
	end

	-- GUARD: Refuse to save if the mega plot was never successfully loaded.
	-- Without this, a transient GetAsync failure at server startup followed by
	-- an autosave would clobber the real save with the post-failure empty terrain.
	if not megaPlotLoadSucceeded then
		warn("[MegaPlotSaveManager] CORRUPTION GUARD: Refusing save -- mega plot was never successfully loaded this session. Previous save preserved.")
		return false, "Save refused: mega plot data was not loaded this session. Previous save is safe."
	end

	local mode = PrivateServerManager.GetMode()
	if mode ~= PrivateServerConfig.MODES.MEGAPLOT then
		return false, "Not in MegaPlot mode"
	end

	local ds = getDataStore()
	local key = getDataStoreKey()
	if not ds or not key then
		return false, "DataStore unavailable"
	end

	-- Find the MegaPlotBuildArea (try multiple methods for reliability during shutdown)
	local buildArea = nil
	
	-- Method 1: Via MegaPlotVisibility global
	local megaPlotVisibility = _G.MegaPlotVisibility
	if megaPlotVisibility and megaPlotVisibility.GetMegaPlotBuildArea then
		buildArea = megaPlotVisibility.GetMegaPlotBuildArea()
	end
	
	-- Method 2: Direct workspace lookup (fallback for shutdown/timing issues)
	if not buildArea then
		local megaPlotRoom = Workspace:FindFirstChild("MegaPlotRoom")
		if megaPlotRoom then
			buildArea = megaPlotRoom:FindFirstChild("MegaPlotBuildArea")
		end
	end
	
	if not buildArea then
		warn("[MegaPlotSaveManager] Cannot find MegaPlotBuildArea for save!")
		return false, "MegaPlotBuildArea not found"
	end

	isSaving = true
	print("[MegaPlotSaveManager] Saving mega plot...")

	-- Serialize the build area (pass noYield for shutdown saves)
	local saveData, serializeError = PlotSerializer.SerializePlot(buildArea, BLOCK_SIZE, options)
	if not saveData then
		isSaving = false
		return false, "Serialize failed: " .. tostring(serializeError)
	end

	-- Inject removed generated blocks (decorations, trees broken by players)
	local removedList = {}
	for key, _ in pairs(removedGeneratedBlocks) do
		local parts = string.split(key, ",")
		table.insert(removedList, {tonumber(parts[1]), tonumber(parts[2]), tonumber(parts[3])})
	end
	saveData.removedGenerated = removedList

	-- Check size
	local size = PlotSerializer.EstimateSize(saveData)
	print(string.format("[MegaPlotSaveManager] Save data: %d blocks, %d dug, %d removed gen, %.1fKB",
		#saveData.blocks, #(saveData.dug or {}), #removedList, size / 1000))

	if size > PlotSerializer.MAX_SIZE then
		isSaving = false
		return false, "Save data too large: " .. math.floor(size / 1000) .. "KB"
	end

	-- CORRUPTION GUARD: Refuse to save if the serializer returned 0 blocks but the
	-- build area has player-placed blocks. Saving the empty payload would wipe work.
	if #saveData.blocks == 0 then
		local blocksFolder = buildArea:FindFirstChild("Blocks")
		local playerPlaced = 0
		if blocksFolder then
			for _, child in ipairs(blocksFolder:GetChildren()) do
				if child:GetAttribute("PlacedBy") and not child:GetAttribute("IsTerrainBlock") then
					playerPlaced = playerPlaced + 1
				end
			end
		end
		if playerPlaced > 0 then
			isSaving = false
			warn(string.format("[MegaPlotSaveManager] CORRUPTION GUARD: Refusing save -- serializer returned 0 blocks but folder has %d player-placed blocks. Previous save preserved.",
				playerPlaced))
			return false, "Save refused: serializer produced 0 blocks for a non-empty plot. Previous save is safe."
		end
	end

	-- Save to DataStore (with retry on transient failures)
	local success, err = retryDataStore(function()
		ds:SetAsync(key, saveData)
	end, 3, "SetAsync(primary mega)")

	isSaving = false
	lastSaveTime = tick()
	isDirty = false

	if success then
		hasSavedData = true
		print(string.format("[MegaPlotSaveManager] Saved! (%d blocks, %.1fKB)", #saveData.blocks, size / 1000))
		
		-- Best-effort backup write. Failure here does NOT fail the save.
		local backupKey = getBackupDataStoreKey()
		if backupKey then
			local backupSuccess, backupErr = retryDataStore(function()
				ds:SetAsync(backupKey, saveData)
			end, 2, "SetAsync(backup mega)")
			if not backupSuccess then
				warn("[MegaPlotSaveManager] Backup write failed (primary OK): " .. tostring(backupErr))
			end
		end
		
		-- Sync to the active slot so slot UI stays current
		task.spawn(function()
			syncToActiveSlot(saveData)
		end)
		
		return true, #saveData.blocks
	else
		warn("[MegaPlotSaveManager] Save failed:", err)
		return false, tostring(err)
	end
end

-- ============================================
-- LOAD MEGA PLOT
-- ============================================

-- Core loading logic: takes raw save data and loads it into the build area
local function loadFromSaveData(saveData, buildArea)
	if not saveData then
		return false, "No save data"
	end

	if not buildArea then
		-- Try to get build area from MegaPlotVisibility
		local megaPlotVisibility = _G.MegaPlotVisibility
		if megaPlotVisibility and megaPlotVisibility.GetMegaPlotBuildArea then
			buildArea = megaPlotVisibility.GetMegaPlotBuildArea()
		end
		if not buildArea then
			return false, "Build area not found"
		end
	end

	isLoading = true
	hasSavedData = true
	
	-- Reset progress bar for loading
	local progressValueInit = ReplicatedStorage:FindFirstChild("MegaPlotTerrainProgress")
	if progressValueInit then
		progressValueInit.Value = 0
	end
	
	print(string.format("[MegaPlotSaveManager] Loading save data: %d blocks, %d dug, %d removed gen",
		#(saveData.blocks or {}), #(saveData.dug or {}), #(saveData.removedGenerated or {})))

	-- Deserialize
	local plotData, deserializeError = PlotSerializer.DeserializePlot(saveData)
	if not plotData then
		isLoading = false
		return false, "Deserialize failed: " .. tostring(deserializeError)
	end

	-- Restore removed generated blocks table from save data
	removedGeneratedBlocks = {}
	for _, pos in ipairs(saveData.removedGenerated or {}) do
		local key = string.format("%d,%d,%d", pos[1], pos[2], pos[3])
		removedGeneratedBlocks[key] = true
	end

	-- Corruption detection (same as SaveManager)
	local lazyLoadedCount = 0
	local lazyLoadedByColumn = {}
	for _, blockData in ipairs(plotData.blocks) do
		if blockData.attributes.IsLazyLoaded then
			lazyLoadedCount += 1
			local colKey = string.format("%d,%d", blockData.gridX, blockData.gridZ)
			if not lazyLoadedByColumn[colKey] then lazyLoadedByColumn[colKey] = {} end
			table.insert(lazyLoadedByColumn[colKey], blockData.gridY)
		end
	end
	local dugPositionCount = #(plotData.dugPositions or {})
	if lazyLoadedCount > 0 and dugPositionCount == 0 then
		warn(string.format("[MegaPlotSaveManager] CORRUPTION: %d lazy-loaded blocks, 0 dug positions - reconstructing!", lazyLoadedCount))
		local reconstructedDug = {}
		for colKey, _ in pairs(lazyLoadedByColumn) do
			local parts = string.split(colKey, ",")
			table.insert(reconstructedDug, { gridX = tonumber(parts[1]), gridY = 0, gridZ = tonumber(parts[2]) })
		end
		plotData.dugPositions = reconstructedDug
	end

	-- Set biome/terrain attributes on the build area
	buildArea:SetAttribute("CurrentBiome", plotData.biome or "Plains")
	buildArea:SetAttribute("CurrentSeason", plotData.season or "Summer")
	buildArea:SetAttribute("TerrainStyle", plotData.terrainStyle or "Flat")
	buildArea:SetAttribute("LifetimeBlocksPlaced", plotData.lifetimeBlocksPlaced or 0)

	-- Suppress removal tracking during terrain regen/load
	isRegeneratingTerrain = true

	-- Clear existing blocks and regenerate terrain base
	TerrainGenerator.ClearAllBlocks(buildArea, 0)
	TerrainGenerator.ResetPlot(0)

	-- Disable animations and layer delay for mega plot loading (way too many blocks)
	local originalSettings = TerrainGenerator.GetGenerationSettings()
	TerrainGenerator.SetGenerationSettings({ 
		LAYER_DELAY = 0,
		ANIMATION_ENABLED = false 
	})
	-- Route to correct generator based on terrain style
	local progressVal = ReplicatedStorage:FindFirstChild("MegaPlotTerrainProgress")
	if progressVal then progressVal.Value = 0.05 end -- Terrain generation starting
	
	if plotData.terrainStyle == "Default" then
		-- Multi-biome world generation (desert + forest, etc.)
		TerrainGenerator.GenerateDefaultTerrain(buildArea, 0, plotData.terrainSeed)
	else
		-- Single-biome: Flat or Natural terrain
		TerrainGenerator.GenerateFlatTerrainWithBiome(buildArea, 0, plotData.biome or "Plains", plotData.terrainStyle or "Flat", plotData.terrainSeed)
	end
	
	if progressVal then progressVal.Value = 0.25 end -- Terrain generation done
	
	TerrainGenerator.SetGenerationSettings({ 
		LAYER_DELAY = originalSettings.LAYER_DELAY,
		ANIMATION_ENABLED = originalSettings.ANIMATION_ENABLED 
	})
	task.wait()

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

	-- Remove dug terrain blocks (optimized with budget-based yielding)
	local dugRemoved = 0
	local lastYield = os.clock()
	if progressVal then progressVal.Value = 0.3 end -- Starting dug removal
	if plotData.dugPositions and #plotData.dugPositions > 0 then
		local terrainBlocksByPos = {}
		local decorationsByParentPos = {}
		local function posToKey(x, y, z)
			return string.format("%d,%d,%d", math.round(x/BLOCK_SIZE), math.round(y/BLOCK_SIZE), math.round(z/BLOCK_SIZE))
		end
		for i, item in ipairs(blocksFolder:GetChildren()) do
			if item:GetAttribute("IsTerrainBlock") then
				local sx, sy, sz = item:GetAttribute("BlockPosX"), item:GetAttribute("BlockPosY"), item:GetAttribute("BlockPosZ")
				local blockPos
				if sx and sy and sz then blockPos = Vector3.new(sx, sy, sz)
				elseif item:IsA("BasePart") then blockPos = item.Position
				elseif item:IsA("Model") then
					local part = item.PrimaryPart or item:FindFirstChildWhichIsA("BasePart")
					if part then blockPos = part.Position end
				end
				if blockPos then terrainBlocksByPos[posToKey(blockPos.X, blockPos.Y, blockPos.Z)] = item end
			elseif item:GetAttribute("IsDecoration") then
				local px, py, pz = item:GetAttribute("ParentBlockX"), item:GetAttribute("ParentBlockY"), item:GetAttribute("ParentBlockZ")
				if px and py and pz then
					local key = posToKey(px, py, pz)
					if not decorationsByParentPos[key] then decorationsByParentPos[key] = {} end
					table.insert(decorationsByParentPos[key], item)
				end
			end
			lastYield = budgetYield(lastYield)
		end

		local blocksToRemove, decosToRemove = {}, {}
		for i, dugPos in ipairs(plotData.dugPositions) do
			local wx = dugPos.gridX * BLOCK_SIZE + originOffset.X
			local wy = dugPos.gridY * BLOCK_SIZE + originOffset.Y
			local wz = dugPos.gridZ * BLOCK_SIZE + originOffset.Z
			local key = posToKey(wx, wy, wz)
			if terrainBlocksByPos[key] then table.insert(blocksToRemove, terrainBlocksByPos[key]) end
			if decorationsByParentPos[key] then
				for _, d in ipairs(decorationsByParentPos[key]) do table.insert(decosToRemove, d) end
			end
			lastYield = budgetYield(lastYield)
		end

		for i, block in ipairs(blocksToRemove) do
			if block and block.Parent then
				block:SetAttribute("BeingRemovedBySaveSystem", true)
				block:Destroy(); dugRemoved += 1
			end
			lastYield = budgetYield(lastYield)
		end
		for i, deco in ipairs(decosToRemove) do
			if deco and deco.Parent then
				deco:SetAttribute("BeingRemovedBySaveSystem", true); deco:Destroy()
			end
			lastYield = budgetYield(lastYield)
		end

		-- Mark dug positions in terrain generator
		if TerrainGenerator.MarkPositionsAsDug then
			local deepestBlockAtColumn = {}
			for _, bd in ipairs(plotData.blocks) do
				if bd.attributes.IsLazyLoaded then
					local ck = string.format("%d,%d", bd.gridX, bd.gridZ)
					if not deepestBlockAtColumn[ck] or bd.gridY < deepestBlockAtColumn[ck] then
						deepestBlockAtColumn[ck] = bd.gridY
					end
				end
			end
			local dugWorldPositions = {}
			for _, dp in ipairs(plotData.dugPositions) do
				local wx = dp.gridX * BLOCK_SIZE + originOffset.X
				local wy = dp.gridY * BLOCK_SIZE + originOffset.Y
				local wz = dp.gridZ * BLOCK_SIZE + originOffset.Z
				table.insert(dugWorldPositions, Vector3.new(wx, wy, wz))
				local ck = string.format("%d,%d", dp.gridX, dp.gridZ)
				local deepestY = deepestBlockAtColumn[ck]
				for depth = 1, 7 do
					local y = dp.gridY - depth
					if not deepestY or y > deepestY then
						table.insert(dugWorldPositions, Vector3.new(wx, y * BLOCK_SIZE + originOffset.Y, wz))
					end
				end
			end
			TerrainGenerator.MarkPositionsAsDug(dugWorldPositions, 0)
		end
	end

	-- Mark lazy-loaded positions
	if TerrainGenerator.MarkPositionsAsDug then
		local allDugPositions = {}
		local surfaceY = buildArea:GetAttribute("TerrainSurfaceY") or 0
		local surfaceGridY = math.round(surfaceY / BLOCK_SIZE)
		for _, bd in ipairs(plotData.blocks) do
			if bd.attributes.IsLazyLoaded then
				local wx = bd.gridX * BLOCK_SIZE + originOffset.X
				local wy = bd.gridY * BLOCK_SIZE + originOffset.Y
				local wz = bd.gridZ * BLOCK_SIZE + originOffset.Z
				table.insert(allDugPositions, Vector3.new(wx, wy, wz))
				for aboveGridY = bd.gridY + 1, surfaceGridY - 1 do
					table.insert(allDugPositions, Vector3.new(wx, aboveGridY * BLOCK_SIZE + originOffset.Y, wz))
				end
			end
		end
		if #allDugPositions > 0 then
			TerrainGenerator.MarkPositionsAsDug(allDugPositions, 0)
		end
	end

	-- Remove terrain-generated blocks that players previously broke (decorations, trees, etc.)
	local removedGenCount = 0
	if next(removedGeneratedBlocks) then
		local origin = getTerrainOrigin(buildArea)
		if origin then
			local toRemove = {}
			for i, item in ipairs(blocksFolder:GetChildren()) do
				local isGenerated = false
				local worldPos = nil

				-- Terrain-generated decoration
				if item:GetAttribute("IsDecoration") and not item:GetAttribute("PlacedBy") then
					isGenerated = true
					local px = item:GetAttribute("ParentBlockX")
					local py = item:GetAttribute("ParentBlockY")
					local pz = item:GetAttribute("ParentBlockZ")
					if px and py and pz then worldPos = Vector3.new(px, py, pz) end
				end

				-- Terrain-generated tree block
				if item:GetAttribute("IsTreeBlock") and not item:GetAttribute("PlacedBy") then
					isGenerated = true
					if item:IsA("BasePart") then
						worldPos = item.Position
					elseif item:IsA("Model") then
						local part = item.PrimaryPart or item:FindFirstChildWhichIsA("BasePart")
						if part then worldPos = part.Position end
					end
				end

				-- Leaves without PlacedBy
				local blockType = item:GetAttribute("BlockType")
				if blockType and blockType:find("Leaves") ~= nil and not item:GetAttribute("PlacedBy") and not isGenerated then
					isGenerated = true
					if item:IsA("BasePart") then
						worldPos = item.Position
					elseif item:IsA("Model") then
						local part = item.PrimaryPart or item:FindFirstChildWhichIsA("BasePart")
						if part then worldPos = part.Position end
					end
				end

				if isGenerated and worldPos then
					local key = worldPosToRelGridKey(worldPos, origin)
					if key and removedGeneratedBlocks[key] then
						table.insert(toRemove, item)
					end
				end

				lastYield = budgetYield(lastYield)
			end

			for i, item in ipairs(toRemove) do
				if item and item.Parent then
					item:SetAttribute("BeingRemovedBySaveSystem", true)
					item:Destroy()
					removedGenCount += 1
				end
				lastYield = budgetYield(lastYield)
			end
		end
		print(string.format("[MegaPlotSaveManager] Removed %d previously-broken generated blocks", removedGenCount))
	end
	
	if progressVal then progressVal.Value = 0.45 end -- Cleanup done, starting block creation

	-- Done with terrain regen phase, enable tracking
	isRegeneratingTerrain = false

	-- Create blocks from save data
	BulkOperationFlags.StartBulkOperation(buildArea, "load")
	
	-- Cache template references once before the loop (avoids hundreds of FindFirstChild calls)
	local templateCtx = {
		BlockTemplates = getBlockTemplates(),
		BlocksSourceFolder = getBlocksFolder(),
		DecorationsSourceFolder = getDecorationsFolder(),
	}
	
	local created, failed = 0, 0
	local totalBlocks = #plotData.blocks
	local createdBlocks = {} -- Collect blocks for batch parenting
	local progressValue = ReplicatedStorage:FindFirstChild("MegaPlotTerrainProgress")
	
	-- Reset progress for block loading phase (terrain gen was ~50%, blocks are the other ~50%)
	if progressValue then
		progressValue.Value = 0.5 -- Terrain is done, block loading starts at 50%
	end
	
	local lastYield = os.clock()
	for i, blockData in ipairs(plotData.blocks) do
		local block = createBlockFromSave(blockData, blocksFolder, originOffset, templateCtx)
		if block then
			created += 1
			table.insert(createdBlocks, block)
		else
			failed += 1
		end
		
		-- Update progress every 100 blocks (cheaper than every 25)
		if i % 100 == 0 and progressValue and totalBlocks > 0 then
			progressValue.Value = 0.5 + (i / totalBlocks) * 0.4
		end
		lastYield = budgetYield(lastYield)
	end
	
	-- Batch-parent all created blocks at once (avoids per-block replication overhead)
	for i, block in ipairs(createdBlocks) do
		block.Parent = blocksFolder
		lastYield = budgetYield(lastYield)
	end
	createdBlocks = nil -- Free for GC
	templateCtx = nil
	
	BulkOperationFlags.EndBulkOperation(buildArea, "load")

	print(string.format("[MegaPlotSaveManager] Loaded %d blocks (%d failed, %d dug removed)", created, failed, dugRemoved))

	-- Scan for terrain positions that should have blocks but don't (broken lazy-loaded blocks from previous sessions)
	if TerrainGenerator and TerrainGenerator.ScanAndMarkMissingTerrainAsDug then
		TerrainGenerator.ScanAndMarkMissingTerrainAsDug(buildArea, 0)
	end

	-- Post-load glass reconnection
	reconnectGlass(blocksFolder)

	-- Apply biome colors to decorations
	local currentBiome = buildArea:GetAttribute("CurrentBiome")
	local currentSeason = buildArea:GetAttribute("CurrentSeason") or "Summer"
	if currentBiome then
		for _, item in ipairs(blocksFolder:GetChildren()) do
			if item:GetAttribute("NeedsBiomeColor") then
				local bt = item:GetAttribute("BlockType")
				if bt == "ShortGrass" or bt == "TallGrass" then
					applyBiomeDecorationColor(item, bt, currentBiome, currentSeason)
					item:SetAttribute("Biome", currentBiome); item:SetAttribute("Season", currentSeason)
				end
				item:SetAttribute("NeedsBiomeColor", nil)
			end
		end
	end

	-- Restore weather
	if WeatherManager and plotData.weather and plotData.weather ~= "Clear" then
		WeatherManager.SetWeather(buildArea, 0, plotData.weather, plotData.weatherIntensity)
	end

	-- Scan for saplings
	local scanHandler = SaplingHandler or _G.SaplingHandler
	if scanHandler then
		scanHandler.ScanBuildAreaForSaplings(buildArea, true)
	end

	-- Auto-repair missing terrain strips (fixes edge strip bug from save/load)
	if TerrainGenerator and TerrainGenerator.RepairMissingTerrain then
		local repaired = TerrainGenerator.RepairMissingTerrain(buildArea, 0)
		if repaired > 0 then
			print(string.format("[MegaPlotSaveManager] Auto-repaired %d missing terrain blocks", repaired))
		end
	end
	
	isLoading = false
	isDirty = false
	megaPlotLoadSucceeded = true -- Plot loaded successfully; saving is now safe.
	print("[MegaPlotSaveManager] Load complete!")
	return true, created
end

-- Wrapper that loads from the server's own DataStore key
function loadMegaPlot(buildArea)
	if isLoading then
		print("[MegaPlotSaveManager] Load already in progress, skipping")
		return false, "Load in progress"
	end

	local ds = getDataStore()
	local key = getDataStoreKey()
	if not ds or not key then
		return false, "DataStore unavailable"
	end

	print("[MegaPlotSaveManager] Loading mega plot for key:", key)

	local saveData = nil
	local recoveredFromBackup = false
	
	local success, err = retryDataStore(function()
		saveData = ds:GetAsync(key)
	end, 3, "GetAsync(primary mega)")

	if not success then
		-- Primary errored. Try the backup before giving up.
		warn("[MegaPlotSaveManager] Primary load failed:", err, "-- trying backup...")
		local backupKey = getBackupDataStoreKey()
		if backupKey then
			local backupSaveData = nil
			local backupSuccess, backupErr = retryDataStore(function()
				backupSaveData = ds:GetAsync(backupKey)
			end, 3, "GetAsync(backup mega)")
			if backupSuccess and backupSaveData then
				warn(string.format("[MegaPlotSaveManager] RECOVERED from backup (%d blocks)",
					backupSaveData.blocks and #backupSaveData.blocks or 0))
				saveData = backupSaveData
				recoveredFromBackup = true
			else
				return false, "DataStore error: " .. tostring(err) .. " (backup also unavailable)"
			end
		else
			return false, "DataStore error: " .. tostring(err)
		end
	end

	if not saveData then
		print("[MegaPlotSaveManager] No saved data found for this server")
		-- Legitimate "no save yet" -- this server has never been saved.
		-- Mark load as succeeded so the first build session can be saved.
		megaPlotLoadSucceeded = true
		return false, "No save data"
	end

	local loadResult, loadInfo = loadFromSaveData(saveData, buildArea)
	if loadResult then
		megaPlotLoadSucceeded = true
	end
	return loadResult, loadInfo
end

-- ============================================
-- CHECK IF SAVED DATA EXISTS
-- ============================================

local function checkForSavedData()
	local ds = getDataStore()
	local key = getDataStoreKey()
	if not ds or not key then return false end

	local success, data = pcall(function()
		return ds:GetAsync(key)
	end)

	if success and data and data.blocks and #data.blocks > 0 then
		hasSavedData = true
		print("[MegaPlotSaveManager] Found existing save data:", #data.blocks, "blocks")
		return true
	end
	return false
end

-- ============================================
-- DIRTY TRACKING
-- ============================================

local function setupDirtyTracking()
	local Remotes = ReplicatedStorage:FindFirstChild("Remotes")
	if not Remotes then return end

	local function markDirtyIfMegaPlot()
		if PrivateServerManager.GetMode() == PrivateServerConfig.MODES.MEGAPLOT then
			isDirty = true
		end
	end

	-- Track all remotes that modify the build area
	local trackedRemotes = {
		"PlaceBlock", "RemoveBlock",           -- Core building
		"UpdateSignText",                       -- Sign editing
		"ShovelAction",                         -- Shovel tool
		"PlaceWire", "RemoveWire",              -- Wiring
		"SelectBiome", "ApplyBiomeColors",      -- Terrain/biome changes
		"UpdatePlotEnvironment",                -- Weather/season
	}

	for _, remoteName in ipairs(trackedRemotes) do
		local remote = Remotes:FindFirstChild(remoteName)
		if remote and remote:IsA("RemoteEvent") then
			remote.OnServerEvent:Connect(markDirtyIfMegaPlot)
		end
	end
	
	-- Also watch for new remotes that might be created later
	Remotes.ChildAdded:Connect(function(child)
		if child:IsA("RemoteEvent") then
			for _, remoteName in ipairs(trackedRemotes) do
				if child.Name == remoteName then
					child.OnServerEvent:Connect(markDirtyIfMegaPlot)
					break
				end
			end
		end
	end)
end

-- ============================================
-- AUTO-SAVE SYSTEM
-- ============================================

local shutdownInProgress = false

local function autoSaveLoop()
	while true do
		task.wait(AUTO_SAVE_INTERVAL)

		-- Don't start new saves during shutdown
		if shutdownInProgress then
			break
		end

		if PrivateServerManager.GetMode() ~= PrivateServerConfig.MODES.MEGAPLOT then
			continue
		end

		if not isDirty then
			continue
		end

		if #Players:GetPlayers() == 0 then
			continue -- No one online, will save when someone leaves
		end

		print("[MegaPlotSaveManager] Auto-saving (periodic)...")
		local success, result = saveMegaPlot()
		if success then
			print("[MegaPlotSaveManager] Auto-save complete:", result, "blocks")
		else
			warn("[MegaPlotSaveManager] Auto-save failed:", result)
		end
	end
end

-- Save when last player leaves
local shutdownSaveCompleted = false

local function onPlayerRemoving(player)
	if PrivateServerManager.GetMode() ~= PrivateServerConfig.MODES.MEGAPLOT then
		return
	end

	-- Check if this is the last player
	local remaining = #Players:GetPlayers() - 1 -- -1 because removing player still counts
	if remaining <= 0 then
		shutdownInProgress = true -- Stop auto-save loop from starting new saves
		print("[MegaPlotSaveManager] Last player leaving, saving mega plot...")
		
		-- If a save is already in progress (e.g. periodic auto-save), wait for it
		if isSaving then
			print("[MegaPlotSaveManager] Save already in progress, waiting for it to finish...")
			local waitStart = tick()
			while isSaving and (tick() - waitStart) < 25 do
				task.wait(0.1)
			end
			if not isSaving then
				print("[MegaPlotSaveManager] In-progress save completed, doing a fresh noYield save for safety...")
				-- Do a fresh noYield save - the previous yielding save may have been
				-- interrupted or missed recent changes
			else
				warn("[MegaPlotSaveManager] In-progress save timed out after 25s, forcing new save...")
				isSaving = false
			end
		end
		
		local success, result = saveMegaPlot({ noYield = true })
		if success then
			print("[MegaPlotSaveManager] Shutdown save completed:", result, "blocks")
			shutdownSaveCompleted = true
		else
			warn("[MegaPlotSaveManager] Shutdown save failed:", result)
		end
	end
end

-- ============================================
-- REMOTES (manual save for owner)
-- ============================================

local function setupRemotes()
	local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)

	local SaveMegaPlotRemote = Remotes:FindFirstChild("SaveMegaPlot")
	if not SaveMegaPlotRemote then
		SaveMegaPlotRemote = Instance.new("RemoteEvent")
		SaveMegaPlotRemote.Name = "SaveMegaPlot"
		SaveMegaPlotRemote.Parent = Remotes
	end

	local SaveLoadResult = Remotes:FindFirstChild("SaveLoadResult")

	SaveMegaPlotRemote.OnServerEvent:Connect(function(player)
		-- Only owner can manually save
		if not PrivateServerManager.IsOwner(player) then
			if SaveLoadResult then
				SaveLoadResult:FireClient(player, "save", false, "Only the server owner can save the mega plot")
			end
			return
		end

		-- Cooldown check
		local now = tick()
		if now - lastSaveTime < SAVE_COOLDOWN then
			local remaining = math.ceil(SAVE_COOLDOWN - (now - lastSaveTime))
			if SaveLoadResult then
				SaveLoadResult:FireClient(player, "save", false, "Please wait " .. remaining .. " seconds")
			end
			return
		end

		local success, result = saveMegaPlot()
		if SaveLoadResult then
			if success then
				SaveLoadResult:FireClient(player, "save", true, "Mega plot saved! (" .. result .. " blocks)")
			else
				SaveLoadResult:FireClient(player, "save", false, "Save failed: " .. tostring(result))
			end
		end
	end)
end

-- ============================================
-- BIND TO CLOSE
-- ============================================

game:BindToClose(function()
	shutdownInProgress = true -- Stop auto-save loop
	
	if PrivateServerManager.GetMode() ~= PrivateServerConfig.MODES.MEGAPLOT then
		return
	end

	-- If onPlayerRemoving already completed a save, we're done
	if shutdownSaveCompleted then
		print("[MegaPlotSaveManager] BindToClose: onPlayerRemoving already saved, skipping.")
		return
	end
	
	-- Wait for any in-progress save (from onPlayerRemoving or auto-save) to finish
	if isSaving then
		print("[MegaPlotSaveManager] BindToClose: Waiting for in-progress save...")
		local waitStart = tick()
		while isSaving and (tick() - waitStart) < 25 do
			task.wait(0.1)
		end
		
		-- Check again if onPlayerRemoving finished while we waited
		if shutdownSaveCompleted then
			print("[MegaPlotSaveManager] BindToClose: Save completed while waiting, done.")
			return
		end
		
		if not isSaving then
			print("[MegaPlotSaveManager] BindToClose: Previous save completed, doing fresh noYield save...")
		else
			warn("[MegaPlotSaveManager] BindToClose: Previous save timed out, forcing save...")
			isSaving = false
		end
	end
	
	print("[MegaPlotSaveManager] BindToClose: Saving mega plot...")
	local success, result = saveMegaPlot({ noYield = true })
	if success then
		print("[MegaPlotSaveManager] BindToClose: Save completed:", result, "blocks")
	else
		warn("[MegaPlotSaveManager] BindToClose: Save failed:", result)
	end
end)

-- ============================================
-- PUBLIC API (via _G)
-- ============================================

local MegaPlotSaveManager = {}

MegaPlotSaveManager.Save = saveMegaPlot
MegaPlotSaveManager.Load = loadMegaPlot
MegaPlotSaveManager.LoadFromData = loadFromSaveData
MegaPlotSaveManager.HasSavedData = function()
	return hasSavedData
end
MegaPlotSaveManager.CheckForSavedData = checkForSavedData
MegaPlotSaveManager.MarkDirty = function()
	isDirty = true
end
MegaPlotSaveManager.IsLoading = function()
	return isLoading
end
MegaPlotSaveManager.IsSaving = function()
	return isSaving
end
MegaPlotSaveManager.SetActiveSlot = function(slotNumber)
	activeSlotNumber = slotNumber
	print("[MegaPlotSaveManager] Active slot set to:", slotNumber or "none")
end
MegaPlotSaveManager.GetActiveSlot = function()
	return activeSlotNumber
end

_G.MegaPlotSaveManager = MegaPlotSaveManager

-- ============================================
-- INITIALIZATION
-- ============================================

setupDirtyTracking()
setupRemotes()

Players.PlayerRemoving:Connect(onPlayerRemoving)

-- Start auto-save loop
task.spawn(autoSaveLoop)

print("[MegaPlotSaveManager] Initialized! DataStore key:", getDataStoreKey() or "N/A")
