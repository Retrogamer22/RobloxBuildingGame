--[[
	SurvivalInventoryHandler
	Server-side persistent personal inventory
	- 36 slots (4 rows x 9 cols, Minecraft-style)
	- Persists across sessions via DataStore
	- Each slot: {p = "PresetId", c = {R,G,B}, n = count} or nil
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BlockPresets = require(ReplicatedStorage:WaitForChild("BlockPresets", 10))

local DATASTORE_NAME = "SurvivalInventory_v1"
local TOTAL_SLOTS = 36
local MAX_STACK = 64
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)

-- Create remotes
local function getOrCreateRemote(name)
	local remote = Remotes:FindFirstChild(name)
	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = Remotes
	end
	return remote
end

local RequestSurvivalInventory = getOrCreateRemote("RequestSurvivalInventory")
local SurvivalInventoryResponse = getOrCreateRemote("SurvivalInventoryResponse")
local UpdateSurvivalSlot = getOrCreateRemote("UpdateSurvivalSlot")

-- ============================================
-- DATASTORE
-- ============================================
local SurvivalDataStore = nil

local function getDataStore()
	if SurvivalDataStore then return SurvivalDataStore end
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(DATASTORE_NAME)
	end)
	if ok then
		SurvivalDataStore = result
		return SurvivalDataStore
	else
		warn("[SurvivalInventory] Failed to get DataStore: " .. tostring(result))
		return nil
	end
end

-- ============================================
-- IN-MEMORY CACHE
-- ============================================
-- [userId] = { [slotIndex] = {p, c, n} or nil }
local PlayerInventories = {}
local PlayerDirty = {} -- [userId] = true if needs saving

local function getKey(userId)
	return "player_" .. tostring(userId)
end

-- Load inventory from DataStore
local function loadInventory(userId)
	if PlayerInventories[userId] then return PlayerInventories[userId] end
	
	local inventory = {}
	local ds = getDataStore()
	if ds then
		local ok, data = pcall(function()
			return ds:GetAsync(getKey(userId))
		end)
		if ok and data and type(data) == "string" then
			local decodeOk, decoded = pcall(function()
				return HttpService:JSONDecode(data)
			end)
			if decodeOk and type(decoded) == "table" then
				for i, item in pairs(decoded) do
					local idx = tonumber(i)
					if idx and idx >= 1 and idx <= TOTAL_SLOTS and type(item) == "table" and item.p then
						inventory[idx] = item
					end
				end
			end
		end
	end
	
	PlayerInventories[userId] = inventory
	return inventory
end

-- Save inventory to DataStore
local function saveInventory(userId)
	local inventory = PlayerInventories[userId]
	if not inventory then return end
	
	local ds = getDataStore()
	if not ds then return end
	
	-- Check if empty
	local hasItems = false
	for _ in pairs(inventory) do
		hasItems = true
		break
	end
	
	local json
	if hasItems then
		local data = {}
		for idx, item in pairs(inventory) do
			data[tostring(idx)] = item
		end
		local ok, result = pcall(function()
			return HttpService:JSONEncode(data)
		end)
		if ok then
			json = result
		end
	end
	
	local ok, err = pcall(function()
		if json then
			ds:SetAsync(getKey(userId), json)
		else
			ds:RemoveAsync(getKey(userId))
		end
	end)
	
	if ok then
		PlayerDirty[userId] = nil
	else
		warn("[SurvivalInventory] Failed to save for " .. tostring(userId) .. ": " .. tostring(err))
	end
end

-- Serialize for client
local function serializeForClient(userId)
	local inventory = loadInventory(userId)
	local result = {}
	for i = 1, TOTAL_SLOTS do
		result[i] = inventory[i] or false
	end
	return result
end

-- ============================================
-- REMOTES
-- ============================================

RequestSurvivalInventory.OnServerEvent:Connect(function(player)
	local contents = serializeForClient(player.UserId)
	SurvivalInventoryResponse:FireClient(player, contents)
end)

UpdateSurvivalSlot.OnServerEvent:Connect(function(player, slotIndex, itemData)
	-- Validate slot index
	if type(slotIndex) ~= "number" or slotIndex < 1 or slotIndex > TOTAL_SLOTS then
		warn(string.format("[SurvivalInventory] Invalid slot %s from %s", tostring(slotIndex), player.Name))
		return
	end
	slotIndex = math.floor(slotIndex)
	
	local inventory = loadInventory(player.UserId)
	
	if itemData == nil or itemData == false then
		-- Clear slot
		inventory[slotIndex] = nil
	else
		-- Validate
		if type(itemData) ~= "table" or type(itemData.p) ~= "string" then
			warn(string.format("[SurvivalInventory] Invalid item data from %s", player.Name))
			return
		end
		
		local preset = BlockPresets.GetPreset(itemData.p)
		if not preset then
			warn(string.format("[SurvivalInventory] Unknown preset '%s' from %s", itemData.p, player.Name))
			return
		end
		
		inventory[slotIndex] = {
			p = itemData.p,
			c = itemData.c or nil,
			n = (type(itemData.n) == "number" and itemData.n > 1) and math.min(math.floor(itemData.n), MAX_STACK) or nil,
		}
	end
	
	PlayerDirty[player.UserId] = true
end)

-- ============================================
-- AUTO-SAVE
-- ============================================

-- Save on player leaving
Players.PlayerRemoving:Connect(function(player)
	if PlayerDirty[player.UserId] then
		saveInventory(player.UserId)
	end
	-- Clean up cache
	PlayerInventories[player.UserId] = nil
	PlayerDirty[player.UserId] = nil
end)

-- Periodic auto-save every 60 seconds for dirty inventories
task.spawn(function()
	while true do
		task.wait(60)
		for userId, dirty in pairs(PlayerDirty) do
			if dirty then
				saveInventory(userId)
			end
		end
	end
end)

-- Save all on server shutdown
game:BindToClose(function()
	for userId, dirty in pairs(PlayerDirty) do
		if dirty then
			saveInventory(userId)
		end
	end
end)

-- Pre-load for players already in game (studio restart)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(function()
		loadInventory(player.UserId)
	end)
end

print("[SurvivalInventoryHandler] Initialized (36 slots, DataStore-backed)")
