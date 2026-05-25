--[[
	MegaPlotSlotHandler (Server)
	Manages mega plot save slots for private servers
	
	Each private server gets 3 free save slots for mega plots
	Owner can save current mega plot to a slot and load from slots
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local ServerScriptService = game:GetService("ServerScriptService")

-- Wait for private server check
local isPrivateServerValue = ReplicatedStorage:WaitForChild("IsPrivateServer", 15)
if not isPrivateServerValue or not isPrivateServerValue.Value then
	-- Wait for value to become true (debug mode)
	if isPrivateServerValue then
		local waited = 0
		while not isPrivateServerValue.Value and waited < 10 do
			task.wait(0.1)
			waited = waited + 0.1
		end
	end
	if not isPrivateServerValue or not isPrivateServerValue.Value then
		print("[MegaPlotSlotHandler] Not a private server, disabled")
		return
	end
end

local ownerIdValue = ReplicatedStorage:WaitForChild("PrivateServerOwnerId", 10)
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)

-- Load PrivateServerManager for server ID
local Modules = ServerScriptService:WaitForChild("Modules", 10)
local PrivateServerManager = require(Modules:WaitForChild("PrivateServerManager"))

-- For direct serialization (bypasses MegaPlotSaveManager lock)
local GridConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GridConfig"))
local PlotSerializer = require(ReplicatedStorage:WaitForChild("PlotSerializer", 10))
local BLOCK_SIZE = GridConfig.BLOCK_SIZE

local MAX_SLOTS = 3
local DATASTORE_NAME = "MegaPlotSlots_v1"

-- ============================================
-- DATASTORE
-- ============================================
local dataStore = nil
local function getDataStore()
	if not dataStore then
		local success, result = pcall(function()
			return DataStoreService:GetDataStore(DATASTORE_NAME)
		end)
		if success then dataStore = result end
	end
	return dataStore
end

local function getSlotKey(slotNumber)
	local serverId = PrivateServerManager.GetServerId()
	return serverId .. "_slot_" .. tostring(slotNumber)
end

local function getSlotMetaKey()
	local serverId = PrivateServerManager.GetServerId()
	return serverId .. "_slotmeta"
end

-- ============================================
-- PERMISSION CHECK
-- ============================================
local function isOwner(player)
	return ownerIdValue and ownerIdValue.Value == player.UserId
end

-- ============================================
-- CREATE REMOTES
-- ============================================
local GetMegaPlotSlots = Instance.new("RemoteFunction")
GetMegaPlotSlots.Name = "GetMegaPlotSlots"
GetMegaPlotSlots.Parent = Remotes

local SaveMegaPlotToSlot = Instance.new("RemoteEvent")
SaveMegaPlotToSlot.Name = "SaveMegaPlotToSlot"
SaveMegaPlotToSlot.Parent = Remotes

local LoadMegaPlotFromSlot = Instance.new("RemoteEvent")
LoadMegaPlotFromSlot.Name = "LoadMegaPlotFromSlot"
LoadMegaPlotFromSlot.Parent = Remotes

local DeleteMegaPlotSlot = Instance.new("RemoteEvent")
DeleteMegaPlotSlot.Name = "DeleteMegaPlotSlot"
DeleteMegaPlotSlot.Parent = Remotes

-- Result event to notify client
local MegaPlotSlotResult = Instance.new("RemoteEvent")
MegaPlotSlotResult.Name = "MegaPlotSlotResult"
MegaPlotSlotResult.Parent = Remotes

-- ============================================
-- GET SLOT METADATA
-- ============================================
local function getSlotMetadata()
	local ds = getDataStore()
	if not ds then return {} end
	
	local success, data = pcall(function()
		return ds:GetAsync(getSlotMetaKey())
	end)
	
	if success and data then
		return data
	end
	return {}
end

local function saveSlotMetadata(metadata)
	local ds = getDataStore()
	if not ds then return false end
	
	local success = pcall(function()
		ds:SetAsync(getSlotMetaKey(), metadata)
	end)
	
	return success
end

-- ============================================
-- REMOTE HANDLERS
-- ============================================

-- Get all slot info (metadata only, not full block data)
GetMegaPlotSlots.OnServerInvoke = function(player)
	if not isOwner(player) then
		return {}
	end
	
	local metadata = getSlotMetadata()
	local result = {}
	
	for i = 1, MAX_SLOTS do
		local slotMeta = metadata[tostring(i)]
		if slotMeta then
			result[i] = {
				hasData = true,
				name = slotMeta.name or ("Mega Plot " .. i),
				blockCount = slotMeta.blockCount or 0,
				savedAt = slotMeta.savedAt or 0,
				terrainStyle = slotMeta.terrainStyle or "Flat",
				biome = slotMeta.biome or "Plains",
			}
		else
			result[i] = { hasData = false }
		end
	end
	
	-- Include last played slot number
	result.lastPlayedSlot = metadata.lastPlayedSlot
	
	return result
end

-- Save current mega plot to a slot
SaveMegaPlotToSlot.OnServerEvent:Connect(function(player, slotNumber, worldName)
	if not isOwner(player) then
		MegaPlotSlotResult:FireClient(player, "save", false, "Only the server owner can save")
		return
	end
	
	slotNumber = tonumber(slotNumber)
	if not slotNumber or slotNumber < 1 or slotNumber > MAX_SLOTS then
		MegaPlotSlotResult:FireClient(player, "save", false, "Invalid slot number")
		return
	end
	
	-- Sanitize optional world name
	if worldName and type(worldName) == "string" then
		worldName = worldName:sub(1, 50):gsub("^%s+", ""):gsub("%s+$", "")
		if worldName == "" then worldName = nil end
	end
	
	print("[MegaPlotSlotHandler] Saving to slot", slotNumber, "for", player.Name, "worldName:", worldName or "(none)")
	
	-- Get the build area directly
	local megaPlotVisibility = _G.MegaPlotVisibility
	if not megaPlotVisibility then
		warn("[MegaPlotSlotHandler] FAILED: _G.MegaPlotVisibility not found")
		MegaPlotSlotResult:FireClient(player, "save", false, "Build system not ready")
		return
	end
	
	local buildArea = megaPlotVisibility.GetMegaPlotBuildArea and megaPlotVisibility.GetMegaPlotBuildArea()
	if not buildArea then
		warn("[MegaPlotSlotHandler] FAILED: MegaPlotBuildArea not found")
		MegaPlotSlotResult:FireClient(player, "save", false, "Build area not found")
		return
	end
	
	-- Serialize directly (bypasses MegaPlotSaveManager lock)
	print("[MegaPlotSlotHandler] Serializing build area directly...")
	local saveData, serializeError = PlotSerializer.SerializePlot(buildArea, BLOCK_SIZE)
	if not saveData then
		warn("[MegaPlotSlotHandler] FAILED: Serialize error:", serializeError)
		MegaPlotSlotResult:FireClient(player, "save", false, "Serialize failed: " .. tostring(serializeError))
		return
	end
	
	local dataSize = PlotSerializer.EstimateSize and PlotSerializer.EstimateSize(saveData) or 0
	print(string.format("[MegaPlotSlotHandler] Serialized: %d blocks, %.1fKB", #saveData.blocks, dataSize / 1000))
	
	print("[MegaPlotSlotHandler] Collecting terrain info...")
	
	-- Get terrain info from build area
	local megaPlotVisibility = _G.MegaPlotVisibility
	local terrainStyle = "Flat"
	local biome = "Plains"
	local blockCount = 0
	
	if megaPlotVisibility then
		local buildArea = megaPlotVisibility.GetMegaPlotBuildArea and megaPlotVisibility.GetMegaPlotBuildArea()
		if buildArea then
			terrainStyle = buildArea:GetAttribute("TerrainStyle") or "Flat"
			biome = buildArea:GetAttribute("CurrentBiome") or "Plains"
			-- Count blocks
			for _, child in buildArea:GetDescendants() do
				if child:IsA("BasePart") and child:GetAttribute("BlockType") then
					blockCount = blockCount + 1
				elseif child:IsA("Model") and child:GetAttribute("BlockType") then
					blockCount = blockCount + 1
				end
			end
		end
	end
	
	-- Save block data to slot
	local ds = getDataStore()
	if not ds then
		warn("[MegaPlotSlotHandler] FAILED: DataStore unavailable")
		MegaPlotSlotResult:FireClient(player, "save", false, "DataStore unavailable")
		return
	end
	
	local key = getSlotKey(slotNumber)
	print("[MegaPlotSlotHandler] Writing to DataStore key:", key, "blocks:", blockCount)
	local success, err = pcall(function()
		ds:SetAsync(key, {
			data = saveData,
			savedAt = os.time(),
		})
	end)
	
	if not success then
		warn("[MegaPlotSlotHandler] FAILED: DataStore SetAsync error:", err)
		MegaPlotSlotResult:FireClient(player, "save", false, "Save failed: " .. tostring(err))
		return
	end
	
	-- Update metadata
	local metadata = getSlotMetadata()
	local displayName = (worldName and worldName ~= "") and worldName or ("Mega Plot " .. slotNumber)
	metadata[tostring(slotNumber)] = {
		name = displayName,
		blockCount = blockCount,
		savedAt = os.time(),
		terrainStyle = terrainStyle,
		biome = biome,
	}
	metadata.lastPlayedSlot = slotNumber
	saveSlotMetadata(metadata)
	
	-- Tell MegaPlotSaveManager this is the active slot
	if _G.MegaPlotSaveManager and _G.MegaPlotSaveManager.SetActiveSlot then
		_G.MegaPlotSaveManager.SetActiveSlot(slotNumber)
	end
	
	print("[MegaPlotSlotHandler] Saved", blockCount, "blocks to slot", slotNumber)
	MegaPlotSlotResult:FireClient(player, "save", true, "Saved " .. blockCount .. " blocks to slot " .. slotNumber)
end)

-- Load mega plot from a slot
LoadMegaPlotFromSlot.OnServerEvent:Connect(function(player, slotNumber)
	if not isOwner(player) then
		MegaPlotSlotResult:FireClient(player, "load", false, "Only the server owner can load")
		return
	end
	
	slotNumber = tonumber(slotNumber)
	if not slotNumber or slotNumber < 1 or slotNumber > MAX_SLOTS then
		MegaPlotSlotResult:FireClient(player, "load", false, "Invalid slot number")
		return
	end
	
	print("[MegaPlotSlotHandler] Loading slot", slotNumber, "for", player.Name)
	
	-- Save the current world BEFORE loading the new one
	if _G.MegaPlotSaveManager then
		local currentSlot = _G.MegaPlotSaveManager.GetActiveSlot and _G.MegaPlotSaveManager.GetActiveSlot()
		if currentSlot and currentSlot ~= slotNumber then
			print("[MegaPlotSlotHandler] Auto-saving current world (slot", currentSlot, ") before switching...")
			local saveOk, saveResult = _G.MegaPlotSaveManager.Save()
			if saveOk then
				print("[MegaPlotSlotHandler] Current world saved:", saveResult, "blocks")
			else
				warn("[MegaPlotSlotHandler] Current world save failed:", saveResult)
			end
		elseif not currentSlot then
			-- No active slot but there's a world loaded - still save to main key
			print("[MegaPlotSlotHandler] No active slot, saving to main key before switch...")
			_G.MegaPlotSaveManager.Save()
		end
	end
	
	local ds = getDataStore()
	if not ds then
		MegaPlotSlotResult:FireClient(player, "load", false, "DataStore unavailable")
		return
	end
	
	local key = getSlotKey(slotNumber)
	local success, slotData = pcall(function()
		return ds:GetAsync(key)
	end)
	
	if not success or not slotData or not slotData.data then
		MegaPlotSlotResult:FireClient(player, "load", false, "No data in slot " .. slotNumber)
		return
	end
	
	-- Mark terrain as NOT ready so loading screen stays visible
	local terrainReadyVal = ReplicatedStorage:FindFirstChild("MegaPlotTerrainReady")
	if terrainReadyVal then
		terrainReadyVal.Value = false
	end
	
	-- Show loading screen to all clients
	local megaPlotVisibility = _G.MegaPlotVisibility
	if megaPlotVisibility and megaPlotVisibility.ShowLoadingScreenToAllClients then
		megaPlotVisibility.ShowLoadingScreenToAllClients("Loading world...")
	end
	
	-- Load the data via MegaPlotSaveManager
	if _G.MegaPlotSaveManager and _G.MegaPlotSaveManager.LoadFromData then
		local loadSuccess, result = _G.MegaPlotSaveManager.LoadFromData(slotData.data)
		
		-- Mark terrain as ready so loading screen hides
		local terrainReadyValue = ReplicatedStorage:FindFirstChild("MegaPlotTerrainReady")
		if terrainReadyValue then
			terrainReadyValue.Value = true
		end
		
		if loadSuccess then
			-- Update last played slot and tell MegaPlotSaveManager
			if _G.MegaPlotSaveManager and _G.MegaPlotSaveManager.SetActiveSlot then
				_G.MegaPlotSaveManager.SetActiveSlot(slotNumber)
			end
			task.spawn(function()
				local md = getSlotMetadata()
				md.lastPlayedSlot = slotNumber
				saveSlotMetadata(md)
			end)
			MegaPlotSlotResult:FireClient(player, "load", true, "Loaded slot " .. slotNumber)
		else
			MegaPlotSlotResult:FireClient(player, "load", false, "Load failed: " .. tostring(result))
		end
	else
		-- Still mark terrain ready so loading screen doesn't get stuck
		local terrainReadyValue = ReplicatedStorage:FindFirstChild("MegaPlotTerrainReady")
		if terrainReadyValue then
			terrainReadyValue.Value = true
		end
		MegaPlotSlotResult:FireClient(player, "load", false, "Save/Load system not ready")
	end
end)

-- Delete a slot
DeleteMegaPlotSlot.OnServerEvent:Connect(function(player, slotNumber)
	if not isOwner(player) then return end
	
	slotNumber = tonumber(slotNumber)
	if not slotNumber or slotNumber < 1 or slotNumber > MAX_SLOTS then return end
	
	local ds = getDataStore()
	if not ds then return end
	
	pcall(function()
		ds:RemoveAsync(getSlotKey(slotNumber))
	end)
	
	local metadata = getSlotMetadata()
	metadata[tostring(slotNumber)] = nil
	if metadata.lastPlayedSlot == slotNumber then
		metadata.lastPlayedSlot = nil
	end
	saveSlotMetadata(metadata)
	
	-- Clear active slot if it was deleted
	if _G.MegaPlotSaveManager and _G.MegaPlotSaveManager.GetActiveSlot then
		if _G.MegaPlotSaveManager.GetActiveSlot() == slotNumber then
			_G.MegaPlotSaveManager.SetActiveSlot(nil)
		end
	end
	
	print("[MegaPlotSlotHandler] Deleted slot", slotNumber)
	MegaPlotSlotResult:FireClient(player, "delete", true, "Slot " .. slotNumber .. " deleted")
end)

-- Auto-detect active slot from metadata on startup
task.spawn(function()
	-- Wait for MegaPlotSaveManager to be available
	local waited = 0
	while not _G.MegaPlotSaveManager and waited < 15 do
		task.wait(0.5)
		waited = waited + 0.5
	end
	
	if _G.MegaPlotSaveManager and _G.MegaPlotSaveManager.SetActiveSlot then
		local metadata = getSlotMetadata()
		if metadata.lastPlayedSlot then
			_G.MegaPlotSaveManager.SetActiveSlot(metadata.lastPlayedSlot)
			print("[MegaPlotSlotHandler] Restored active slot from metadata:", metadata.lastPlayedSlot)
		end
	end
end)

print("[MegaPlotSlotHandler] Initialized with", MAX_SLOTS, "slots")
