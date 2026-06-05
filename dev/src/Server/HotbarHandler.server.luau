--[[
	HotbarHandler
	Server-side persistent creative hotbar (the on-screen quick-slot row)
	- 10 slots
	- Persists across sessions (between games) via DataStore
	- Each slot is one of:
	    block: {p = "PresetId", c = {R,G,B}, n = count}
	    tool:  {t = "ToolName"}
	    empty: nil

	Mirrors SurvivalInventoryHandler's structure/auto-save behaviour. The hotbar
	is independent from the 36-slot survival inventory and uses its own DataStore.
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BlockPresets = require(ReplicatedStorage:WaitForChild("BlockPresets", 10))

local DATASTORE_NAME = "PlayerHotbar_v1"
local TOTAL_SLOTS = 10
local MAX_STACK = 64
local MAX_TOOL_NAME = 64
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

local RequestHotbar = getOrCreateRemote("RequestHotbar")
local HotbarResponse = getOrCreateRemote("HotbarResponse")
local UpdateHotbarSlot = getOrCreateRemote("UpdateHotbarSlot")

-- ============================================
-- DATASTORE
-- ============================================
local HotbarDataStore = nil

local function getDataStore()
	if HotbarDataStore then return HotbarDataStore end
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(DATASTORE_NAME)
	end)
	if ok then
		HotbarDataStore = result
		return HotbarDataStore
	else
		warn("[Hotbar] Failed to get DataStore: " .. tostring(result))
		return nil
	end
end

-- ============================================
-- IN-MEMORY CACHE
-- ============================================
-- [userId] = { [slotIndex] = {p,c,n} | {t} | nil }
local PlayerHotbars = {}
local PlayerDirty = {} -- [userId] = true if needs saving

local function getKey(userId)
	return "player_" .. tostring(userId)
end

-- Validate + normalize one slot's data coming from disk or a client.
-- Returns a clean entry table, or nil if it should be treated as empty/invalid.
local function sanitizeEntry(item)
	if type(item) ~= "table" then return nil end

	-- Tool entry
	if type(item.t) == "string" then
		local name = item.t
		if #name == 0 or #name > MAX_TOOL_NAME then return nil end
		return { t = name }
	end

	-- Block entry
	if type(item.p) == "string" then
		local preset = BlockPresets.GetPreset(item.p)
		if not preset then return nil end
		local entry = { p = item.p }
		if type(item.c) == "table" then
			local r = tonumber(item.c[1])
			local g = tonumber(item.c[2])
			local b = tonumber(item.c[3])
			if r and g and b then
				entry.c = {
					math.clamp(math.floor(r), 0, 255),
					math.clamp(math.floor(g), 0, 255),
					math.clamp(math.floor(b), 0, 255),
				}
			end
		end
		if type(item.n) == "number" and item.n > 1 then
			entry.n = math.min(math.floor(item.n), MAX_STACK)
		end
		return entry
	end

	return nil
end

-- Load hotbar from DataStore
local function loadHotbar(userId)
	if PlayerHotbars[userId] then return PlayerHotbars[userId] end

	local hotbar = {}
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
					if idx and idx >= 1 and idx <= TOTAL_SLOTS then
						local clean = sanitizeEntry(item)
						if clean then
							hotbar[idx] = clean
						end
					end
				end
			end
		end
	end

	PlayerHotbars[userId] = hotbar
	return hotbar
end

-- Save hotbar to DataStore
local function saveHotbar(userId)
	local hotbar = PlayerHotbars[userId]
	if not hotbar then return end

	local ds = getDataStore()
	if not ds then return end

	-- Check if empty
	local hasItems = false
	for _ in pairs(hotbar) do
		hasItems = true
		break
	end

	local json
	if hasItems then
		local data = {}
		for idx, item in pairs(hotbar) do
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
		warn("[Hotbar] Failed to save for " .. tostring(userId) .. ": " .. tostring(err))
	end
end

-- Serialize for client (1..TOTAL_SLOTS, empty slots = false)
local function serializeForClient(userId)
	local hotbar = loadHotbar(userId)
	local result = {}
	for i = 1, TOTAL_SLOTS do
		result[i] = hotbar[i] or false
	end
	return result
end

-- ============================================
-- REMOTES
-- ============================================

RequestHotbar.OnServerEvent:Connect(function(player)
	local contents = serializeForClient(player.UserId)
	HotbarResponse:FireClient(player, contents)
end)

UpdateHotbarSlot.OnServerEvent:Connect(function(player, slotIndex, itemData)
	-- Validate slot index
	if type(slotIndex) ~= "number" or slotIndex < 1 or slotIndex > TOTAL_SLOTS then
		warn(string.format("[Hotbar] Invalid slot %s from %s", tostring(slotIndex), player.Name))
		return
	end
	slotIndex = math.floor(slotIndex)

	local hotbar = loadHotbar(player.UserId)

	if itemData == nil or itemData == false then
		-- Clear slot
		hotbar[slotIndex] = nil
	else
		local clean = sanitizeEntry(itemData)
		if not clean then
			warn(string.format("[Hotbar] Invalid item data for slot %d from %s", slotIndex, player.Name))
			return
		end
		hotbar[slotIndex] = clean
	end

	PlayerDirty[player.UserId] = true
end)

-- ============================================
-- AUTO-SAVE
-- ============================================

-- Save on player leaving
Players.PlayerRemoving:Connect(function(player)
	if PlayerDirty[player.UserId] then
		saveHotbar(player.UserId)
	end
	-- Clean up cache
	PlayerHotbars[player.UserId] = nil
	PlayerDirty[player.UserId] = nil
end)

-- Periodic auto-save every 60 seconds for dirty hotbars
task.spawn(function()
	while true do
		task.wait(60)
		for userId, dirty in pairs(PlayerDirty) do
			if dirty then
				saveHotbar(userId)
			end
		end
	end
end)

-- Save all on server shutdown
game:BindToClose(function()
	for userId, dirty in pairs(PlayerDirty) do
		if dirty then
			saveHotbar(userId)
		end
	end
end)

-- Pre-load for players already in game (studio restart)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(function()
		loadHotbar(player.UserId)
	end)
end

print("[HotbarHandler] Initialized (10 slots, DataStore-backed)")
