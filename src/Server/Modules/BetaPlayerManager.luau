--[[
	BetaPlayerManager
	Tracks and persists beta testers
	
	Features:
	- Registers players as beta testers when they place enough blocks (threshold-based)
	- Stores beta status permanently in DataStore
	- Provides API to check if a player is a beta tester
	- Caches beta status for quick lookups
	
	Usage:
		local BetaPlayerManager = require(path.to.BetaPlayerManager)
		
		-- Check if player has premium (either beta tester, gamepass owner, or during beta)
		if BetaPlayerManager.HasPremiumAccess(player) then
			-- Allow premium features
		end
		
		-- Call this when a player saves (from SaveManager)
		BetaPlayerManager.CheckAndRegisterIfQualified(player, blockCount)
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BetaConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("BetaConfig"))

local BetaPlayerManager = {}

-- ============================================
-- DATASTORE SETUP
-- ============================================
local BetaDataStore = nil

local function getDataStore()
	if BetaDataStore then return BetaDataStore end
	
	local success, result = pcall(function()
		return DataStoreService:GetDataStore(BetaConfig.BETA_PLAYERS_DATASTORE)
	end)
	
	if success then
		BetaDataStore = result
		return BetaDataStore
	else
		warn("[BetaPlayerManager] Failed to get DataStore:", result)
		return nil
	end
end

-- ============================================
-- IN-MEMORY CACHE
-- ============================================
-- Cache of odile -> true for quick lookups (confirmed beta testers)
local BetaPlayerCache = {}

-- Pending players (joined during beta but haven't met threshold yet)
-- UserId -> true
local PendingPlayers = {}

-- Full list of beta players registered this session (for admin viewing)
local BetaPlayerList = {}  -- Array of {UserId, Name, JoinDate, BlockCount}

-- ============================================
-- CORE FUNCTIONS
-- ============================================

-- Check if a player is the owner (excluded from beta tracking)
function BetaPlayerManager.IsOwner(player)
	-- Always check game creator
	if player.UserId == game.CreatorId then
		return true
	end
	
	-- Check configured owner (if set, 0 means not configured)
	if BetaConfig.OWNER_USER_ID ~= 0 and player.UserId == BetaConfig.OWNER_USER_ID then
		return true
	end
	
	return false
end

-- Check if a player owns the premium gamepass
local function ownsGamepass(player)
	if BetaConfig.PREMIUM_GAMEPASS_ID == 0 then
		return false
	end
	
	local success, owns = pcall(function()
		return MarketplaceService:UserOwnsGamePassAsync(player.UserId, BetaConfig.PREMIUM_GAMEPASS_ID)
	end)
	
	return success and owns
end

-- Check if player is a registered beta tester (from cache or DataStore)
function BetaPlayerManager.IsBetaPlayer(player)
	-- Check cache first
	if BetaPlayerCache[player.UserId] then
		return true
	end
	
	-- Check DataStore
	local dataStore = getDataStore()
	if not dataStore then return false end
	
	local key = BetaConfig.PLAYER_STATUS_PREFIX .. tostring(player.UserId)
	local success, result = pcall(function()
		return dataStore:GetAsync(key)
	end)
	
	if success and result then
		-- Cache the result
		BetaPlayerCache[player.UserId] = true
		return true
	end
	
	return false
end

-- Register a player as a beta tester (internal function)
function BetaPlayerManager.RegisterBetaPlayer(player, blockCount)
	-- Don't register the owner
	if BetaPlayerManager.IsOwner(player) then
		print("[BetaPlayerManager] Skipping owner:", player.Name)
		return false
	end
	
	-- Check if already registered
	if BetaPlayerCache[player.UserId] then
		print("[BetaPlayerManager] Already registered:", player.Name)
		return true
	end
	
	local dataStore = getDataStore()
	if not dataStore then 
		warn("[BetaPlayerManager] DataStore unavailable, can't register:", player.Name)
		return false 
	end
	
	-- Store individual player status
	local key = BetaConfig.PLAYER_STATUS_PREFIX .. tostring(player.UserId)
	local playerData = {
		UserId = player.UserId,
		Name = player.Name,
		JoinDate = os.date("%Y-%m-%d %H:%M:%S"),
		Timestamp = os.time(),
		BlockCount = blockCount or 0  -- Store how many blocks they had when qualified
	}
	
	local success, err = pcall(function()
		dataStore:SetAsync(key, playerData)
	end)
	
	if success then
		BetaPlayerCache[player.UserId] = true
		PendingPlayers[player.UserId] = nil  -- Remove from pending
		table.insert(BetaPlayerList, playerData)
		print(string.format("[BetaPlayerManager] ✓ Registered beta tester: %s (UserId: %d, Blocks: %d)", 
			player.Name, player.UserId, blockCount or 0))
		return true
	else
		warn("[BetaPlayerManager] Failed to register", player.Name, ":", err)
		return false
	end
end

-- Check if player meets threshold and register them if so
-- Called by SaveManager when a player saves their plot
function BetaPlayerManager.CheckAndRegisterIfQualified(player, blockCount)
	-- Only register during beta
	if not BetaConfig.IS_BETA then
		return false
	end
	
	-- Skip if not pending (already registered or not tracked)
	if not PendingPlayers[player.UserId] then
		-- Check if they're already a beta tester
		if BetaPlayerCache[player.UserId] then
			return true  -- Already registered
		end
		return false
	end
	
	-- Check threshold
	local threshold = BetaConfig.MINIMUM_BLOCKS_FOR_BETA or 10
	if blockCount >= threshold then
		print(string.format("[BetaPlayerManager] Player %s qualified with %d blocks (threshold: %d)", 
			player.Name, blockCount, threshold))
		return BetaPlayerManager.RegisterBetaPlayer(player, blockCount)
	else
		print(string.format("[BetaPlayerManager] Player %s has %d blocks (need %d to qualify)", 
			player.Name, blockCount, threshold))
		return false
	end
end

-- Main function: Check if player has premium access
-- Returns true if:
--   1. Player is the owner, OR
--   2. Currently in beta mode (everyone gets free premium), OR
--   3. Player is a registered beta tester, OR
--   4. Player owns the gamepass
function BetaPlayerManager.HasPremiumAccess(player)
	-- Owner always has access
	if BetaPlayerManager.IsOwner(player) then
		return true
	end
	
	-- During beta, everyone has access
	if BetaConfig.IS_BETA then
		return true
	end
	
	-- After beta, check if they're a beta tester
	if BetaPlayerManager.IsBetaPlayer(player) then
		return true
	end
	
	-- Finally, check gamepass
	return ownsGamepass(player)
end

-- Check if a player is pending (joined but hasn't met threshold yet)
function BetaPlayerManager.IsPendingPlayer(player)
	return PendingPlayers[player.UserId] == true
end

-- Get all beta players (for admin purposes)
-- Note: This loads from memory cache, not DataStore
function BetaPlayerManager.GetBetaPlayerList()
	return BetaPlayerList
end

-- Get count of beta players registered this session
function BetaPlayerManager.GetBetaPlayerCount()
	return #BetaPlayerList
end

-- Get count of pending players
function BetaPlayerManager.GetPendingPlayerCount()
	local count = 0
	for _ in pairs(PendingPlayers) do
		count = count + 1
	end
	return count
end

-- Check if beta mode is active
function BetaPlayerManager.IsBetaActive()
	return BetaConfig.IS_BETA
end

-- ============================================
-- AUTOMATIC TRACKING ON JOIN
-- ============================================

local function onPlayerAdded(player)
	print(string.format("[BetaPlayerManager] Player joined: %s (UserId: %d)", player.Name, player.UserId))
	
	-- Skip owner
	if BetaPlayerManager.IsOwner(player) then
		print("[BetaPlayerManager] Owner detected, skipping tracking")
		return
	end
	
	if BetaConfig.IS_BETA then
		-- Check if they're already a registered beta tester
		if BetaPlayerManager.IsBetaPlayer(player) then
			print("[BetaPlayerManager] Returning beta tester:", player.Name)
			return
		end
		
		-- Mark as pending - they'll be registered when they save with enough blocks
		PendingPlayers[player.UserId] = true
		print(string.format("[BetaPlayerManager] Player pending beta qualification: %s (need %d blocks)", 
			player.Name, BetaConfig.MINIMUM_BLOCKS_FOR_BETA or 10))
	else
		-- Beta is over - just check/cache their existing beta status
		local isBeta = BetaPlayerManager.IsBetaPlayer(player)
		if isBeta then
			print("[BetaPlayerManager] Returning beta tester:", player.Name)
		end
	end
end

local function onPlayerRemoving(player)
	-- Clean up pending status when they leave
	if PendingPlayers[player.UserId] then
		print(string.format("[BetaPlayerManager] Pending player left without qualifying: %s", player.Name))
		PendingPlayers[player.UserId] = nil
	end
end

-- Connect to player events
Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

-- Handle players already in game (for late script load)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(function()
		onPlayerAdded(player)
	end)
end

-- ============================================
-- STATUS REPORTING
-- ============================================

print("[BetaPlayerManager] Initialized")
print("[BetaPlayerManager] Beta mode:", BetaConfig.IS_BETA and "ACTIVE" or "INACTIVE")
print("[BetaPlayerManager] Block threshold:", BetaConfig.MINIMUM_BLOCKS_FOR_BETA or 10)
local ownerDisplay = BetaConfig.OWNER_USER_ID ~= 0 and BetaConfig.OWNER_USER_ID or ("game.CreatorId = " .. tostring(game.CreatorId))
print("[BetaPlayerManager] Owner UserId:", ownerDisplay)
print("[BetaPlayerManager] Gamepass ID:", BetaConfig.PREMIUM_GAMEPASS_ID)

return BetaPlayerManager
