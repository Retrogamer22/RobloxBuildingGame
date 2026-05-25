--[[
	AnalyticsManager
	Tracks in-game analytics including:
	- Block usage statistics (which blocks are placed most)
	- Session duration tracking
	- New vs returning player metrics
	- Top players by total playtime
	
	Data is stored in DataStore and updated periodically
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local AnalyticsManager = {}

-- DataStores
local PlayerAnalyticsStore = DataStoreService:GetDataStore("PlayerAnalytics_v1")
local GlobalAnalyticsStore = DataStoreService:GetDataStore("GlobalAnalytics_v1")

-- In-memory caches
local playerSessions = {} -- [userId] = { joinTime, blocksPlacedThisSession }
local playerData = {} -- [userId] = { totalPlaytime, totalBlocksPlaced, isReturning, firstJoin, lastJoin }
local globalBlockStats = {} -- [blockName] = count
local topPlayersCache = {} -- Cached leaderboard
local lastLeaderboardUpdate = 0
local LEADERBOARD_CACHE_TIME = 60 -- Update leaderboard cache every 60 seconds

-- userIds that should never appear in the playtime leaderboard.
-- Populated by AnalyticsHandler at init (e.g. game owner / dev account).
-- Their playtime is still tracked locally for the per-player dashboard, but
-- we never write their total to PlaytimeLeaderboard and we defensively filter
-- them out when reading it back.
local leaderboardBlacklist = {} -- [userId] = true

-- Ordered DataStore for leaderboard
local PlaytimeLeaderboard = DataStoreService:GetOrderedDataStore("PlaytimeLeaderboard_v1")

-- ============================================
-- PLAYER DATA MANAGEMENT
-- ============================================

function AnalyticsManager.LoadPlayerData(player)
	local userId = player.UserId
	local success, data = pcall(function()
		return PlayerAnalyticsStore:GetAsync("player_" .. userId)
	end)
	
	if success and data then
		playerData[userId] = {
			totalPlaytime = data.totalPlaytime or 0,
			totalBlocksPlaced = data.totalBlocksPlaced or 0,
			totalBlocksBroken = data.totalBlocksBroken or 0,
			blockUsage = data.blockUsage or {},
			isReturning = true,
			firstJoin = data.firstJoin or os.time(),
			lastJoin = os.time(),
			sessionCount = (data.sessionCount or 0) + 1
		}
		print("[Analytics] Loaded returning player data for " .. player.Name)
	else
		-- New player
		playerData[userId] = {
			totalPlaytime = 0,
			totalBlocksPlaced = 0,
			totalBlocksBroken = 0,
			blockUsage = {},
			isReturning = false,
			firstJoin = os.time(),
			lastJoin = os.time(),
			sessionCount = 1
		}
		print("[Analytics] New player detected: " .. player.Name)
	end
	
	-- Start session tracking
	playerSessions[userId] = {
		joinTime = os.time(),
		blocksPlacedThisSession = 0,
		blocksBrokenThisSession = 0
	}
	
	return playerData[userId]
end

function AnalyticsManager.SavePlayerData(player)
	local userId = player.UserId
	local data = playerData[userId]
	local session = playerSessions[userId]
	
	if not data or not session then
		warn("[Analytics] No data to save for " .. player.Name)
		return false
	end
	
	-- Calculate session duration
	local sessionDuration = os.time() - session.joinTime
	data.totalPlaytime = data.totalPlaytime + sessionDuration
	data.lastJoin = os.time()
	
	-- Save to DataStore
	local saveData = {
		totalPlaytime = data.totalPlaytime,
		totalBlocksPlaced = data.totalBlocksPlaced,
		totalBlocksBroken = data.totalBlocksBroken,
		blockUsage = data.blockUsage,
		firstJoin = data.firstJoin,
		lastJoin = data.lastJoin,
		sessionCount = data.sessionCount
	}
	
	local success, err = pcall(function()
		PlayerAnalyticsStore:SetAsync("player_" .. userId, saveData)
	end)
	
	if success then
		print("[Analytics] Saved data for " .. player.Name .. " (Session: " .. sessionDuration .. "s, Total: " .. data.totalPlaytime .. "s)")
		
		-- Update playtime leaderboard, unless this player is blacklisted
		-- (e.g. game owner). Their totalPlaytime is still saved to
		-- PlayerAnalyticsStore above so the per-player dashboard still works.
		if not leaderboardBlacklist[userId] then
			pcall(function()
				PlaytimeLeaderboard:SetAsync(tostring(userId), data.totalPlaytime)
			end)
		end
	else
		warn("[Analytics] Failed to save data for " .. player.Name .. ": " .. tostring(err))
	end
	
	return success
end

function AnalyticsManager.CleanupPlayer(player)
	local userId = player.UserId
	playerData[userId] = nil
	playerSessions[userId] = nil
end

-- ============================================
-- BLOCK TRACKING
-- ============================================

function AnalyticsManager.TrackBlockPlaced(player, blockName)
	local userId = player.UserId
	local data = playerData[userId]
	local session = playerSessions[userId]
	
	if not data or not session then return end
	
	-- Update player stats
	data.totalBlocksPlaced = data.totalBlocksPlaced + 1
	data.blockUsage[blockName] = (data.blockUsage[blockName] or 0) + 1
	session.blocksPlacedThisSession = session.blocksPlacedThisSession + 1
	
	-- Update global stats
	globalBlockStats[blockName] = (globalBlockStats[blockName] or 0) + 1
end

function AnalyticsManager.TrackBlockBroken(player, blockName)
	local userId = player.UserId
	local data = playerData[userId]
	local session = playerSessions[userId]
	
	if not data or not session then return end
	
	-- Update player stats
	data.totalBlocksBroken = data.totalBlocksBroken + 1
	session.blocksBrokenThisSession = session.blocksBrokenThisSession + 1
end

-- ============================================
-- LEADERBOARD BLACKLIST
-- ============================================

-- Exclude a userId from the playtime leaderboard. Called by AnalyticsHandler
-- at init for the game owner / dev account so their dev playtime doesn't
-- dominate top-N rankings. Idempotent.
function AnalyticsManager.AddLeaderboardBlacklist(userId)
	if type(userId) ~= "number" or userId <= 0 then return end
	if leaderboardBlacklist[userId] then return end
	leaderboardBlacklist[userId] = true
	-- Invalidate any cached top-N so the next read filters them out
	topPlayersCache = {}
	lastLeaderboardUpdate = 0
	print("[Analytics] Playtime leaderboard blacklist += " .. userId)
end

function AnalyticsManager.IsLeaderboardBlacklisted(userId)
	return leaderboardBlacklist[userId] == true
end

-- ============================================
-- ANALYTICS RETRIEVAL
-- ============================================

function AnalyticsManager.GetTopBlocks(limit)
	limit = limit or 10
	
	-- Convert to sorted array
	local sorted = {}
	for blockName, count in pairs(globalBlockStats) do
		table.insert(sorted, { name = blockName, count = count })
	end
	
	table.sort(sorted, function(a, b)
		return a.count > b.count
	end)
	
	-- Return top N
	local result = {}
	for i = 1, math.min(limit, #sorted) do
		result[i] = sorted[i]
	end
	
	return result
end

function AnalyticsManager.GetTopPlayers(limit)
	limit = limit or 10
	
	-- Use cache if recent. Cache is populated post-filter below, and is
	-- invalidated by AddLeaderboardBlacklist, so we don't need to re-filter here.
	if os.time() - lastLeaderboardUpdate < LEADERBOARD_CACHE_TIME and #topPlayersCache > 0 then
		local result = {}
		for i = 1, math.min(limit, #topPlayersCache) do
			result[i] = topPlayersCache[i]
		end
		return result
	end
	-- Fetch from OrderedDataStore
	local success, pages = pcall(function()
		return PlaytimeLeaderboard:GetSortedAsync(false, limit)
	end)
	
	if not success or not pages then
		warn("[Analytics] Failed to fetch leaderboard")
		return topPlayersCache
	end
	
	local result = {}
	local currentPage = pages:GetCurrentPage()
	
	for rank, entry in ipairs(currentPage) do
		local userId = tonumber(entry.key)
		local playtime = entry.value
		
		-- Defensive filter: skip any blacklisted userIds that might already
		-- have entries in PlaytimeLeaderboard from before the blacklist existed.
		if userId and not leaderboardBlacklist[userId] then
			-- Try to get player name
			local playerName = "Unknown"
			local success2, name = pcall(function()
				return Players:GetNameFromUserIdAsync(userId)
			end)
			if success2 then
				playerName = name
			end
			
			table.insert(result, {
				rank = #result + 1,
				userId = userId,
				name = playerName,
				username = playerName,  -- alias so AnalyticsReporter.sendLeaderboards doesn't re-resolve
				playtime = playtime
			})
		end
	end
	
	-- Update cache
	topPlayersCache = result
	lastLeaderboardUpdate = os.time()
	
	return result
end

function AnalyticsManager.GetPlayerStats(player)
	local userId = player.UserId
	local data = playerData[userId]
	local session = playerSessions[userId]
	
	if not data then return nil end
	
	local currentSessionTime = 0
	if session then
		currentSessionTime = os.time() - session.joinTime
	end
	
	return {
		totalPlaytime = data.totalPlaytime + currentSessionTime,
		totalBlocksPlaced = data.totalBlocksPlaced,
		totalBlocksBroken = data.totalBlocksBroken,
		isReturning = data.isReturning,
		firstJoin = data.firstJoin,
		sessionCount = data.sessionCount,
		currentSessionTime = currentSessionTime,
		blocksPlacedThisSession = session and session.blocksPlacedThisSession or 0
	}
end

function AnalyticsManager.GetServerStats()
	local totalPlayers = 0
	local newPlayers = 0
	local returningPlayers = 0
	local totalSessionTime = 0
	
	for userId, data in pairs(playerData) do
		totalPlayers = totalPlayers + 1
		if data.isReturning then
			returningPlayers = returningPlayers + 1
		else
			newPlayers = newPlayers + 1
		end
		
		local session = playerSessions[userId]
		if session then
			totalSessionTime = totalSessionTime + (os.time() - session.joinTime)
		end
	end
	
	local avgSessionTime = totalPlayers > 0 and (totalSessionTime / totalPlayers) or 0
	
	return {
		currentPlayers = totalPlayers,
		newPlayers = newPlayers,
		returningPlayers = returningPlayers,
		averageSessionTime = avgSessionTime,
		topBlocks = AnalyticsManager.GetTopBlocks(10)
	}
end

-- ============================================
-- GLOBAL STATS PERSISTENCE
-- ============================================

function AnalyticsManager.LoadGlobalStats()
	local success, data = pcall(function()
		return GlobalAnalyticsStore:GetAsync("blockStats")
	end)
	
	if success and data then
		globalBlockStats = data
		print("[Analytics] Loaded global block stats")
	else
		print("[Analytics] Starting with fresh global stats")
	end
end

function AnalyticsManager.SaveGlobalStats()
	local success, err = pcall(function()
		GlobalAnalyticsStore:SetAsync("blockStats", globalBlockStats)
	end)
	
	if success then
		print("[Analytics] Saved global block stats")
	else
		warn("[Analytics] Failed to save global stats: " .. tostring(err))
	end
end

-- ============================================
-- UTILITY FUNCTIONS
-- ============================================

function AnalyticsManager.FormatTime(seconds)
	seconds = math.floor(seconds)
	
	if seconds < 60 then
		return seconds .. "s"
	elseif seconds < 3600 then
		local mins = math.floor(seconds / 60)
		local secs = seconds % 60
		return mins .. "m " .. secs .. "s"
	else
		local hours = math.floor(seconds / 3600)
		local mins = math.floor((seconds % 3600) / 60)
		return hours .. "h " .. mins .. "m"
	end
end

function AnalyticsManager.FormatNumber(num)
	if num >= 1000000 then
		return string.format("%.1fM", num / 1000000)
	elseif num >= 1000 then
		return string.format("%.1fK", num / 1000)
	else
		return tostring(num)
	end
end

-- ============================================
-- INITIALIZATION
-- ============================================

function AnalyticsManager.Initialize()
	-- Load global stats on server start
	AnalyticsManager.LoadGlobalStats()
	
	-- Auto-save global stats every 5 minutes
	task.spawn(function()
		while true do
			task.wait(300) -- 5 minutes
			AnalyticsManager.SaveGlobalStats()
		end
	end)
	
	print("[Analytics] AnalyticsManager initialized!")
end

-- Alias: AnalyticsReporter.sendLeaderboards calls GetTopPlaytime. Same shape
-- as GetTopPlayers (the OrderedDataStore is keyed by playtime), so this is
-- just a naming convenience.
AnalyticsManager.GetTopPlaytime = AnalyticsManager.GetTopPlayers

return AnalyticsManager
