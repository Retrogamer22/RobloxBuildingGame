--[[
	NewBlockTracker.luau (Server Module)
	Tracks which block preset IDs each player has "seen" in their inventory.
	
	On first join: seeds seen set with ALL current preset IDs (nothing shows as "new").
	On subsequent joins: any preset IDs not in the seen set are flagged as "new".
	When a player views a tab, those block IDs are added to their seen set.
	Seen set is saved on player leave.
	
	DataStore key: "seen_" .. UserId
	Stores: { seenBlockIds = { "OakPlanks", "GrassBlock", ... } }
	
	[BB-NEW] log prefix for filtering
]]

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local BlockPresets = require(ReplicatedStorage:WaitForChild("BlockPresets", 10))

local NewBlockTracker = {}

-- ============================================
-- CONFIGURATION
-- ============================================
local DATASTORE_NAME = "SeenBlocks_v1"
local SAVE_RETRY_ATTEMPTS = 3
local SAVE_RETRY_DELAY = 2
local LOG_PREFIX = "[BB-NEW]"

-- ============================================
-- STATE
-- ============================================
local DataStore = nil
local PlayerSeenSets = {} -- userId -> { ["OakPlanks"] = true, ... } (in-memory set)
local DataLoaded = {}     -- userId -> boolean
local DataDirty = {}      -- userId -> boolean
local PlayerNewBlocks = {} -- userId -> { "BlockId1", "BlockId2", ... } (computed on load)

-- ============================================
-- DATASTORE INIT
-- ============================================
local function getDataStore()
	if DataStore then return DataStore end
	local success, result = pcall(function()
		return DataStoreService:GetDataStore(DATASTORE_NAME)
	end)
	if success then
		DataStore = result
		return DataStore
	else
		warn(LOG_PREFIX, "Failed to get DataStore:", result)
		return nil
	end
end

-- ============================================
-- HELPERS
-- ============================================

-- Get all visible preset IDs from BlockPresets (excludes HideFromInventory)
local function getAllVisiblePresetIds(): { string }
	local ids = {}
	local allPresets = BlockPresets.GetAllPresets()
	for _, preset in ipairs(allPresets) do
		if not preset.HideFromInventory then
			table.insert(ids, preset.Id)
		end
	end
	return ids
end

-- Convert array to set (table with true values)
local function arrayToSet(arr: { string }): { [string]: boolean }
	local set = {}
	for _, id in ipairs(arr) do
		set[id] = true
	end
	return set
end

-- Convert set to array
local function setToArray(set: { [string]: boolean }): { string }
	local arr = {}
	for id, _ in pairs(set) do
		table.insert(arr, id)
	end
	return arr
end

-- ============================================
-- LOAD / SAVE
-- ============================================
function NewBlockTracker.LoadPlayerData(userId: number): boolean
	if DataLoaded[userId] then return true end
	
	local ds = getDataStore()
	local allVisibleIds = getAllVisiblePresetIds()
	local allVisibleSet = arrayToSet(allVisibleIds)
	
	if not ds then
		-- No DataStore: treat as first join, seed everything, no "new" blocks
		PlayerSeenSets[userId] = allVisibleSet
		PlayerNewBlocks[userId] = {}
		DataLoaded[userId] = true
		warn(LOG_PREFIX, "DataStore unavailable, seeding all blocks as seen for", userId)
		return false
	end
	
	local key = "seen_" .. tostring(userId)
	local success, result = pcall(function()
		return ds:GetAsync(key)
	end)
	
	if success then
		if result and result.seenBlockIds then
			-- Returning player: load their seen set
			local seenSet = arrayToSet(result.seenBlockIds)
			PlayerSeenSets[userId] = seenSet
			
			-- Compute new blocks: anything visible that isn't in their seen set
			local newBlocks = {}
			for _, id in ipairs(allVisibleIds) do
				if not seenSet[id] then
					table.insert(newBlocks, id)
				end
			end
			PlayerNewBlocks[userId] = newBlocks
			
			if #newBlocks > 0 then
				print(LOG_PREFIX, "Player", userId, "has", #newBlocks, "new blocks to discover")
			else
				print(LOG_PREFIX, "Player", userId, "is up to date (no new blocks)")
			end
		else
			-- Brand new player: seed with ALL current blocks so nothing is "new"
			PlayerSeenSets[userId] = allVisibleSet
			PlayerNewBlocks[userId] = {}
			DataDirty[userId] = true
			print(LOG_PREFIX, "New player", userId, "— seeded", #allVisibleIds, "blocks as seen")
		end
		
		DataLoaded[userId] = true
		return true
	else
		warn(LOG_PREFIX, "Failed to load data for", userId, ":", result)
		-- Fallback: seed everything as seen
		PlayerSeenSets[userId] = allVisibleSet
		PlayerNewBlocks[userId] = {}
		DataLoaded[userId] = true
		return false
	end
end

function NewBlockTracker.SavePlayerData(userId: number): boolean
	if not DataLoaded[userId] or not PlayerSeenSets[userId] then return false end
	if not DataDirty[userId] then return true end
	
	local ds = getDataStore()
	if not ds then return false end
	
	local key = "seen_" .. tostring(userId)
	local data = {
		seenBlockIds = setToArray(PlayerSeenSets[userId])
	}
	
	for attempt = 1, SAVE_RETRY_ATTEMPTS do
		local success, err = pcall(function()
			ds:SetAsync(key, data)
		end)
		
		if success then
			DataDirty[userId] = false
			print(LOG_PREFIX, "Saved seen blocks for", userId, "(", #data.seenBlockIds, "blocks)")
			return true
		else
			warn(LOG_PREFIX, "Save attempt", attempt, "failed for", userId, ":", err)
			if attempt < SAVE_RETRY_ATTEMPTS then
				task.wait(SAVE_RETRY_DELAY)
			end
		end
	end
	
	return false
end

function NewBlockTracker.CleanupPlayer(userId: number)
	NewBlockTracker.SavePlayerData(userId)
	
	task.delay(30, function()
		if not Players:GetPlayerByUserId(userId) then
			PlayerSeenSets[userId] = nil
			PlayerNewBlocks[userId] = nil
			DataLoaded[userId] = nil
			DataDirty[userId] = nil
		end
	end)
end

-- ============================================
-- API
-- ============================================

-- Get the list of new (unseen) block IDs for this player's session
function NewBlockTracker.GetNewBlockIds(userId: number): { string }
	return PlayerNewBlocks[userId] or {}
end

-- Mark specific block IDs as seen (called when player views a tab)
function NewBlockTracker.MarkBlocksSeen(userId: number, blockIds: { string })
	if not DataLoaded[userId] or not PlayerSeenSets[userId] then return end
	
	local seenSet = PlayerSeenSets[userId]
	local marked = 0
	
	for _, id in ipairs(blockIds) do
		if not seenSet[id] then
			seenSet[id] = true
			marked += 1
		end
	end
	
	if marked > 0 then
		DataDirty[userId] = true
		print(LOG_PREFIX, "Marked", marked, "blocks as seen for", userId)
	end
end

-- Check if data is loaded for a player
function NewBlockTracker.IsDataLoaded(userId: number): boolean
	return DataLoaded[userId] == true
end

return NewBlockTracker
