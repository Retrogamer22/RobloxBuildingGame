--[[
	CoinManager.luau (Server Module)
	Core economy module — manages Build Coins via DataStore
	
	DataStore key: "coins_" .. UserId
	Stores: {
		coins: number,
		totalEarned: number,
		totalSpent: number,
		
		-- Daily rewards
		dailyStreak: number (1-7, current streak day),
		dailyLastClaim: number (os.time of last claim),
		dailyWeeksCompleted: number (total full weeks completed),
		dailyCoinStreak: number (consecutive coin-roll days this week, resets on set drop or week end),
		unlockedRewardSets: { [setName] = true } (sets the player has already won),
		unlockedBlocks: { [blockId] = true } (block IDs unlocked from any reward set),
		
		-- Achievement progress
		achievements: { [achievementId] = { progress: number, claimedTier: number } },
		
		-- Stats
		totalLogins: number,
		totalBlocksPlaced: number,
		firstJoin: number (os.time),
		lastLogin: number (os.time),
	}
]]

local DataStoreService = game:GetService("DataStoreService")

-- Persistent global streak leaderboard. Written to on each successful daily claim.
local StreakLeaderboardOrdered = DataStoreService:GetOrderedDataStore("StreakLeaderboard_v1")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CoinConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("CoinConfig"))
local ModConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("ModConfig"))
local LootConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("DailyRewardLootConfig"))
local RewardSetPicker = require(ReplicatedStorage:WaitForChild("RewardSetPicker"))

-- Lazy handle to PlusManager (sibling module). We require it on first use rather
-- than at the top so module load order between the two never matters and we
-- avoid any circular-require risk. Cached after the first successful require.
local _PlusManager = nil
local function getPlusManager()
	if _PlusManager then return _PlusManager end
	local sibling = script.Parent:FindFirstChild("PlusManager")
	if not sibling then return nil end
	local ok, mod = pcall(require, sibling)
	if ok then
		_PlusManager = mod
		return _PlusManager
	end
	warn("[CoinManager] Failed to require PlusManager:", mod)
	return nil
end

-- Returns true if the player currently has Roblox Plus, false otherwise.
-- Safe if PlusManager is missing/unloaded — defaults to false (no bonus) so a
-- missing module can never accidentally hand everyone the full Plus payout.
local function playerHasPlus(userId: number): boolean
	local pm = getPlusManager()
	if not pm then return false end
	local ok, result = pcall(pm.HasPlus, userId)
	return ok and result == true
end

-- ============================================
-- ANALYTICS (coin faucet / sink logging)
-- ============================================
-- Lazy handle to AnalyticsEvents (sibling module). Required on first use so
-- module load order never matters; cached after first success. Fully optional —
-- if the module is missing or HTTP is disabled, coin logging silently no-ops.
local _AnalyticsEvents = nil
local _analyticsTried = false
local function getAnalyticsEvents()
	if _AnalyticsEvents then return _AnalyticsEvents end
	if _analyticsTried then return nil end
	_analyticsTried = true
	local sibling = script.Parent:FindFirstChild("AnalyticsEvents")
	if not sibling then return nil end
	local ok, mod = pcall(require, sibling)
	if ok then
		_AnalyticsEvents = mod
		return _AnalyticsEvents
	end
	warn("[CoinManager] Failed to require AnalyticsEvents:", mod)
	return nil
end

-- Collapse a detailed coin `reason` into a coarse source bucket so the analytics
-- dashboard groups cleanly (e.g. "daily_reward_w2_d5" -> "daily_reward").
local function coarseCoinSource(reason: string?): string
	if type(reason) ~= "string" or reason == "" then return "unknown" end
	if reason:find("^daily_reward") then return "daily_reward" end
	if reason:find("^achievement") then return "achievement" end
	if reason:find("^community") then return "community" end
	if reason:find("^vote_from") then return "likes" end
	return reason
end

-- Fire a coin faucet/sink event (fire-and-forget). Resolves a username because
-- the Worker requires a non-empty one even though we key analytics on userId.
local function logCoinFlow(userId: number, direction: string, amount: number, reason: string?)
	local ae = getAnalyticsEvents()
	if not ae then return end
	local player = Players:GetPlayerByUserId(userId)
	local username = player and player.Name or ("User" .. tostring(userId))
	ae.Post("coin_" .. direction, {
		userId = userId,
		username = username,
		amount = amount,
		source = coarseCoinSource(reason),
	})
end

local CoinManager = {}

-- ============================================
-- CONFIGURATION
-- ============================================
local DATASTORE_NAME = "BuildCoins_v1"
local SAVE_RETRY_ATTEMPTS = 3
local SAVE_RETRY_DELAY = 2

-- ============================================
-- STATE
-- ============================================
local DataStore = nil
local PlayerData = {} -- userId -> data table (in-memory cache)
local DataLoaded = {} -- userId -> boolean (true once initial load completes)
local DataDirty = {} -- userId -> boolean (true if unsaved changes exist)

-- Callbacks for when coins change (so CoinService can fire remotes)
local OnCoinsChangedCallbacks = {} -- array of functions(userId, newBalance, delta, reason)
local OnDailyClaimCallbacks = {} -- array of functions(userId, day, coinsAwarded)
local OnAchievementClaimedCallbacks = {} -- array of functions(userId, achievementId, tier, coinsAwarded)

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
		warn("[CoinManager] Failed to get DataStore:", result)
		return nil
	end
end

-- ============================================
-- DEFAULT DATA
-- ============================================
local function createDefaultData()
	return {
		coins = 0,
		totalEarned = 0,
		totalSpent = 0,
		
		-- Daily rewards
		dailyStreak = 0,
		dailyLastClaim = 0,
		dailyWeeksCompleted = 0,
		dailyCoinStreak = 0,
		unlockedRewardSets = {},
		unlockedBlocks = {},

		-- Coin-purchased mods (id -> true). Buying a mod also grants its blocks
		-- into unlockedBlocks, so the inventory un-gating reuses the reward path.
		ownedMods = {},

		-- Achievement progress
		achievements = {},
		
		-- Stats
		totalLogins = 0,
		totalBlocksPlaced = 0,
		firstJoin = os.time(),
		lastLogin = os.time(),

		-- One-time rewards
		communityJoinRewardClaimed = false,
	}
end

-- Migrate / validate data structure (add missing fields)
local function migrateData(data)
	local defaults = createDefaultData()
	for key, defaultValue in pairs(defaults) do
		if data[key] == nil then
			data[key] = defaultValue
		end
	end
	if type(data.achievements) ~= "table" then
		data.achievements = {}
	end
	return data
end

-- ============================================
-- LOAD / SAVE
-- ============================================
function CoinManager.LoadPlayerData(userId: number): boolean
	if DataLoaded[userId] then return true end
	
	local ds = getDataStore()
	if not ds then
		-- Fallback: use defaults so the player can still play
		PlayerData[userId] = createDefaultData()
		DataLoaded[userId] = true
		warn("[CoinManager] DataStore unavailable, using defaults for", userId)
		return false
	end
	
	local key = "coins_" .. tostring(userId)
	local success, result = pcall(function()
		return ds:GetAsync(key)
	end)
	
	if success then
		if result then
			PlayerData[userId] = migrateData(result)
		else
			-- Brand new player
			PlayerData[userId] = createDefaultData()
			PlayerData[userId].coins = CoinConfig.StarterCoins
			PlayerData[userId].totalEarned = CoinConfig.StarterCoins
			DataDirty[userId] = true
		end
		DataLoaded[userId] = true
		
		-- Increment login count + update lastLogin
		PlayerData[userId].totalLogins = (PlayerData[userId].totalLogins or 0) + 1
		PlayerData[userId].lastLogin = os.time()
		DataDirty[userId] = true
		
		print("[CoinManager] Loaded data for", userId, "| Coins:", PlayerData[userId].coins)
		return true
	else
		warn("[CoinManager] Failed to load data for", userId, ":", result)
		PlayerData[userId] = createDefaultData()
		DataLoaded[userId] = true
		return false
	end
end

function CoinManager.SavePlayerData(userId: number): boolean
	if not DataLoaded[userId] or not PlayerData[userId] then return false end
	if not DataDirty[userId] then return true end -- Nothing to save
	
	local ds = getDataStore()
	if not ds then return false end
	
	local key = "coins_" .. tostring(userId)
	local data = PlayerData[userId]
	
	for attempt = 1, SAVE_RETRY_ATTEMPTS do
		local success, err = pcall(function()
			ds:SetAsync(key, data)
		end)
		
		if success then
			DataDirty[userId] = false
			return true
		else
			warn("[CoinManager] Save attempt", attempt, "failed for", userId, ":", err)
			if attempt < SAVE_RETRY_ATTEMPTS then
				task.wait(SAVE_RETRY_DELAY)
			end
		end
	end
	
	return false
end

function CoinManager.CleanupPlayer(userId: number)
	-- Save before removing from memory
	CoinManager.SavePlayerData(userId)
	
	-- Delay cleanup in case of quick rejoin
	task.delay(30, function()
		if not Players:GetPlayerByUserId(userId) then
			PlayerData[userId] = nil
			DataLoaded[userId] = nil
			DataDirty[userId] = nil
		end
	end)
end

-- ============================================
-- COIN OPERATIONS
-- ============================================
function CoinManager.GetCoins(userId: number): number
	if not PlayerData[userId] then return 0 end
	return PlayerData[userId].coins
end

function CoinManager.GetPlayerData(userId: number)
	return PlayerData[userId]
end

function CoinManager.IsDataLoaded(userId: number): boolean
	return DataLoaded[userId] == true
end

-- Add coins (from rewards, votes, achievements, purchases)
function CoinManager.AddCoins(userId: number, amount: number, reason: string?): boolean
	if not PlayerData[userId] then return false end
	if amount <= 0 then return false end
	
	local data = PlayerData[userId]
	data.coins = data.coins + amount
	data.totalEarned = data.totalEarned + amount
	DataDirty[userId] = true
	
	print(string.format("[CoinManager] +%d coins for %d (%s) | New balance: %d", amount, userId, reason or "unknown", data.coins))
	
	-- Fire callbacks
	for _, callback in ipairs(OnCoinsChangedCallbacks) do
		task.spawn(callback, userId, data.coins, amount, reason or "unknown")
	end

	-- Analytics: coin faucet (earn)
	logCoinFlow(userId, "earn", amount, reason)
	
	return true
end

-- Spend coins (for shop purchases)
function CoinManager.SpendCoins(userId: number, amount: number, reason: string?): boolean
	if not PlayerData[userId] then return false end
	if amount <= 0 then return false end
	
	local data = PlayerData[userId]
	if data.coins < amount then
		return false -- Not enough coins
	end
	
	data.coins = data.coins - amount
	data.totalSpent = data.totalSpent + amount
	DataDirty[userId] = true
	
	print(string.format("[CoinManager] -%d coins for %d (%s) | New balance: %d", amount, userId, reason or "unknown", data.coins))
	
	-- Fire callbacks (negative delta)
	for _, callback in ipairs(OnCoinsChangedCallbacks) do
		task.spawn(callback, userId, data.coins, -amount, reason or "purchase")
	end

	-- Analytics: coin sink (spend)
	logCoinFlow(userId, "spend", amount, reason)
	
	return true
end

-- Check if player can afford something
function CoinManager.CanAfford(userId: number, amount: number): boolean
	if not PlayerData[userId] then return false end
	return PlayerData[userId].coins >= amount
end

-- ============================================
-- MODS (coin-purchased content bundles)
-- See ModConfig for definitions. A mod is bought once; buying it marks the mod
-- owned and grants every block Id in mod.grants into unlockedBlocks (reusing the
-- exact reward-block unlock path, including Unlocked_<BlockId> attributes and the
-- NotifyNewBlocks badge push).
-- ============================================

-- Does the player own this mod?
function CoinManager.OwnsMod(userId: number, modId: string): boolean
	local data = PlayerData[userId]
	if not data or not data.ownedMods then return false end
	return data.ownedMods[modId] == true
end

-- Return a shallow copy of the player's owned-mods set { [modId] = true }.
function CoinManager.GetOwnedMods(userId: number): { [string]: boolean }
	local data = PlayerData[userId]
	if not data or not data.ownedMods then return {} end
	local out = {}
	for modId, owned in pairs(data.ownedMods) do
		if owned then out[modId] = true end
	end
	return out
end

-- Grant a mod to a player WITHOUT charging coins (used by PurchaseMod after a
-- successful spend, and available for admin gifts). Marks the mod owned, unlocks
-- its grant blocks, applies runtime attributes + NEW badges, and persists.
-- Returns (ok, message, grantedBlockIds, alreadyOwned).
function CoinManager.GrantMod(userId: number, modId: string): (boolean, string, {string}?, boolean?)
	local data = PlayerData[userId]
	if not data then
		return false, "player data not loaded", nil, nil
	end
	local mod = ModConfig.GetById(modId)
	if not mod then
		return false, "unknown mod: " .. tostring(modId), nil, nil
	end

	data.ownedMods = data.ownedMods or {}
	data.unlockedBlocks = data.unlockedBlocks or {}

	local alreadyOwned = data.ownedMods[modId] == true
	data.ownedMods[modId] = true

	-- Grant each block the mod unlocks (skip ones already owned)
	local grantedBlockIds = {}
	for _, blockId in ipairs(mod.grants or {}) do
		if not data.unlockedBlocks[blockId] then
			data.unlockedBlocks[blockId] = true
			table.insert(grantedBlockIds, blockId)
		end
	end

	-- Apply runtime attributes + push NEW badges if the player is online
	local player = Players:GetPlayerByUserId(userId)
	if player then
		for _, blockId in ipairs(grantedBlockIds) do
			player:SetAttribute("Unlocked_" .. blockId, true)
		end
		if #grantedBlockIds > 0 then
			local remotes = ReplicatedStorage:FindFirstChild("Remotes")
			local notify = remotes and remotes:FindFirstChild("NotifyNewBlocks")
			if notify then
				notify:Fire(player, grantedBlockIds)
			end
		end
	end

	DataDirty[userId] = true
	-- Persist immediately so the grant survives a crash before the next save
	CoinManager.SavePlayerData(userId)

	local message = string.format("'%s' granted to userId=%d (+%d blocks, alreadyOwned=%s)",
		mod.name or modId, userId, #grantedBlockIds, tostring(alreadyOwned))
	print("[CoinManager] mod grant: " .. message)
	return true, message, grantedBlockIds, alreadyOwned
end

-- Attempt to buy a mod with coins. Validates availability + ownership, applies
-- the Roblox Plus coin discount, spends, then grants. Returns (ok, message, newBalance).
function CoinManager.PurchaseMod(userId: number, modId: string): (boolean, string, number)
	local data = PlayerData[userId]
	if not data then
		return false, "Data not loaded", 0
	end
	local mod = ModConfig.GetById(modId)
	if not mod then
		return false, "Unknown mod", data.coins
	end
	if mod.available ~= true then
		return false, "Not available yet", data.coins
	end

	data.ownedMods = data.ownedMods or {}
	if data.ownedMods[modId] then
		return false, "Already owned", data.coins
	end

	-- Apply the Plus coin discount (rounds down, same as the rest of the economy).
	local basePrice = tonumber(mod.coinPrice) or 0
	local finalPrice = basePrice
	local pm = getPlusManager()
	if pm then
		local ok, discounted = pcall(pm.GetDiscountedPrice, userId, basePrice)
		if ok and type(discounted) == "number" then
			finalPrice = discounted
		end
	end

	if finalPrice > 0 and data.coins < finalPrice then
		return false, "Not enough coins", data.coins
	end

	if finalPrice > 0 then
		local spent = CoinManager.SpendCoins(userId, finalPrice, "mod_" .. modId)
		if not spent then
			return false, "Purchase failed", data.coins
		end
	end

	CoinManager.GrantMod(userId, modId)
	print(string.format("[CoinManager] mod purchase: userId=%d bought '%s' for %d coins (base %d)",
		userId, mod.name or modId, finalPrice, basePrice))
	return true, "Purchased!", data.coins
end

-- ============================================
-- COMMUNITY JOIN REWARD (one-time flag)
-- ============================================
function CoinManager.IsCommunityRewardClaimed(userId: number): boolean
	if not PlayerData[userId] then return false end
	return PlayerData[userId].communityJoinRewardClaimed == true
end

function CoinManager.MarkCommunityRewardClaimed(userId: number)
	if not PlayerData[userId] then return end
	PlayerData[userId].communityJoinRewardClaimed = true
	DataDirty[userId] = true
end

-- Dev-only: reset the flag so the reward can be re-claimed for testing.
function CoinManager.ResetCommunityRewardClaim(userId: number)
	if not PlayerData[userId] then return end
	PlayerData[userId].communityJoinRewardClaimed = false
	DataDirty[userId] = true
end

-- ============================================
-- UNLOCK ATTRIBUTES (Reward Block gating)
-- ============================================
-- Replay every previously-unlocked block as an "Unlocked_<BlockId>" attribute on
-- the player so the inventory's reward-block gating works the moment they join.
-- Should be called right after LoadPlayerData succeeds for that player.
function CoinManager.ApplyUnlockAttributesToPlayer(player: Player)
	if not player then return end
	local data = PlayerData[player.UserId]
	if not data or not data.unlockedBlocks then return end
	
	local count = 0
	for blockId, owned in pairs(data.unlockedBlocks) do
		if owned then
			player:SetAttribute("Unlocked_" .. blockId, true)
			count = count + 1
		end
	end
	
	if count > 0 then
		print(string.format("[CoinManager] Applied %d unlock attribute(s) to %s", count, player.Name))
	end
end

-- ============================================
-- ADMIN GIFTS / GRANTS
-- ============================================
-- Grant an entire RewardSet (and all of its blocks) to a player. Designed for
-- the owner gift commands in BetaAdminCommands. The recipient must be on this
-- server so we can apply Unlocked_<BlockId> attributes and refresh their
-- inventory immediately; granting to a player whose data is held by another
-- server would race with that server's writes.
--
-- Returns: (ok, message, grantedBlockIds, alreadyOwnedSet)
--   ok               : true on success (set is now marked owned)
--   message          : human-readable summary for logs / UI
--   grantedBlockIds  : list of NEW block IDs added this call (may be empty)
--   alreadyOwnedSet  : true if the set was already marked owned before this call
function CoinManager.GrantRewardSet(userId: number, setName: string): (boolean, string, {string}?, boolean?)
	if type(userId) ~= "number" or type(setName) ~= "string" or setName == "" then
		return false, "invalid args", nil, nil
	end
	
	local data = PlayerData[userId]
	if not data then
		return false, "player data not loaded (recipient must be on this server)", nil, nil
	end
	
	-- Resolve set from ReplicatedStorage.RewardSets (case-insensitive match on folder name)
	local target = nil
	for _, info in ipairs(RewardSetPicker.GetAllSets()) do
		if string.lower(info.name) == string.lower(setName) then
			target = info
			break
		end
	end
	if not target then
		return false, "unknown reward set: " .. setName, nil, nil
	end
	
	data.unlockedRewardSets = data.unlockedRewardSets or {}
	data.unlockedBlocks = data.unlockedBlocks or {}
	
	local alreadyOwnedSet = data.unlockedRewardSets[target.name] == true
	data.unlockedRewardSets[target.name] = true
	
	-- Grant each block in the set (skip ones already owned)
	local grantedBlockIds = {}
	for _, blockId in ipairs(target.grants) do
		if not data.unlockedBlocks[blockId] then
			data.unlockedBlocks[blockId] = true
			table.insert(grantedBlockIds, blockId)
		end
	end
	
	-- Apply runtime attributes + push NEW badges if player is online
	local player = Players:GetPlayerByUserId(userId)
	if player then
		for _, blockId in ipairs(grantedBlockIds) do
			player:SetAttribute("Unlocked_" .. blockId, true)
		end
		if #grantedBlockIds > 0 then
			local remotes = ReplicatedStorage:FindFirstChild("Remotes")
			local notify = remotes and remotes:FindFirstChild("NotifyNewBlocks")
			if notify then
				notify:Fire(player, grantedBlockIds)
			end
		end
	end
	
	-- Persist immediately so the grant survives a crash before the next normal save
	CoinManager.SavePlayerData(userId)
	
	local message
	if alreadyOwnedSet and #grantedBlockIds == 0 then
		message = string.format("'%s' already fully owned by userId=%d", target.name, userId)
	elseif alreadyOwnedSet then
		message = string.format("'%s' re-granted to userId=%d (+%d new blocks)", target.name, userId, #grantedBlockIds)
	else
		message = string.format("'%s' (%s) granted to userId=%d (+%d blocks)",
			target.name, target.rarity or "Common", userId, #grantedBlockIds)
	end
	
	print("[CoinManager] gift: " .. message)
	return true, message, grantedBlockIds, alreadyOwnedSet
end

-- ============================================
-- DAILY REWARDS
-- ============================================
-- ============================================
-- DAILY RESET TIMEZONE
-- The "day" used for daily-reward eligibility resets at midnight in this
-- timezone rather than at UTC midnight. Illinois is UTC-6 (CST) / UTC-5 (CDT).
-- This is a FIXED offset and does NOT auto-adjust for daylight saving — during
-- CDT (roughly mid-March to early November) the reset lands at 1 AM local; set
-- to -5 if you'd rather it be exactly midnight during summer instead of winter.
-- One number, one place: change DAILY_RESET_UTC_OFFSET_HOURS to shift the reset.
-- ============================================
local DAILY_RESET_UTC_OFFSET_HOURS = -6
local DAILY_RESET_OFFSET_SECS = DAILY_RESET_UTC_OFFSET_HOURS * 3600

-- Helper: get the local-day number from a unix timestamp (offset-adjusted)
local function getUTCDay(timestamp: number): number
	return math.floor((timestamp + DAILY_RESET_OFFSET_SECS) / 86400)
end

-- Helper: get seconds until the next local midnight from now
local function secondsUntilMidnightUTC(): number
	local now = os.time() + DAILY_RESET_OFFSET_SECS
	local secondsIntoDay = now % 86400
	return 86400 - secondsIntoDay
end

-- ============================================
function CoinManager.GetDailyRewardStatus(userId: number)
	if not PlayerData[userId] then
		return { canClaim = false, currentDay = 0, streak = 0, currentWeek = 0, dayInWeek = 0 }
	end
	
	local data = PlayerData[userId]
	local now = os.time()
	local lastClaim = data.dailyLastClaim or 0
	local streak = data.dailyStreak or 0
	
	local todayUTC = getUTCDay(now)
	local lastClaimDayUTC = getUTCDay(lastClaim)
	local daysSinceLastClaim = todayUTC - lastClaimDayUTC
	
	-- Check if streak is broken (missed too many calendar days)
	local streakExpiryDays = CoinConfig.DailyRewards.StreakExpiryDays or 2
	if lastClaim > 0 and daysSinceLastClaim >= streakExpiryDays then
		-- Streak broken - will reset when they claim
		streak = 0
	end
	
	-- Can claim if never claimed, or if last claim was on a previous UTC day
	local canClaim = (lastClaim == 0) or (daysSinceLastClaim >= 1)
	
	-- Streak no longer resets on week complete - it keeps growing.
	-- Compute the day-in-week (1-7) and week number for the NEXT-up day.
	local nextStreak = streak + 1
	local dayInWeek = ((nextStreak - 1) % 7) + 1
	local currentWeek = math.ceil(nextStreak / 7)
	
	-- Time until next midnight UTC (in hours)
	local secsUntilReset = secondsUntilMidnightUTC()
	local hoursUntilNextClaim = canClaim and 0 or (secsUntilReset / 3600)
	
	return {
		canClaim = canClaim,
		currentDay = dayInWeek,    -- 1-7 within the current week (kept name for UI compat)
		dayInWeek = dayInWeek,     -- explicit alias
		currentWeek = currentWeek, -- 1, 2, 3, ...
		streak = streak,            -- raw streak counter (can exceed 7)
		lastClaim = lastClaim,
		weeksCompleted = data.dailyWeeksCompleted or 0,
		daysSinceLastClaim = daysSinceLastClaim,
		hoursUntilNextClaim = hoursUntilNextClaim,
	}
end

function CoinManager.ClaimDailyReward(userId: number): (boolean, string?, number?, {[string]: any}?)
	if not PlayerData[userId] then
		return false, "Data not loaded", 0, nil
	end
	
	local status = CoinManager.GetDailyRewardStatus(userId)
	if not status.canClaim then
		local hoursLeft = math.ceil(status.hoursUntilNextClaim * 10) / 10
		return false, string.format("Come back in %.1f hours!", hoursLeft), 0, nil
	end
	
	local data = PlayerData[userId]
	local now = os.time()
	local lastClaim = data.dailyLastClaim or 0
	local daysSinceLastClaim = getUTCDay(now) - getUTCDay(lastClaim)
	
	-- Determine streak state
	local streak = data.dailyStreak or 0
	
	-- Reset streak if expired (missed too many calendar days)
	local streakExpiryDays = CoinConfig.DailyRewards.StreakExpiryDays or 2
	if lastClaim > 0 and daysSinceLastClaim >= streakExpiryDays then
		streak = 0
	end
	-- Note: streak no longer resets at 7 - it keeps counting up through weeks 2, 3, ...
	
	-- Advance streak
	streak = streak + 1
	
	-- Compute day-in-week and week number for this claim
	local dayInWeek = ((streak - 1) % 7) + 1
	local currentWeek = math.ceil(streak / 7)
	
	-- ============================================
	-- ROLL: coins vs reward set
	-- Set chance is per-week, per-day-in-week (see DailyRewardLootConfig).
	-- Plus players get a small set-chance bonus AND a higher coin payout, so we
	-- resolve their Plus status once here and reuse it for both rolls.
	-- ============================================
	local hasPlus = playerHasPlus(userId)
	local setChance = LootConfig.GetSetChance(dayInWeek, currentWeek, hasPlus)
	local roll = math.random()
	local gotSet = roll < setChance
	
	local rewardSetInfo = nil -- payload returned to client/caller
	local grantedBlockIds = nil -- block IDs added to inventory this claim
	
	if gotSet then
		-- Try to pick a set from ReplicatedStorage.RewardSets, excluding already-owned
		data.unlockedRewardSets = data.unlockedRewardSets or {}
		local picked = RewardSetPicker.PickRandom(nil, data.unlockedRewardSets)
		
		if picked then
			-- Mark set as owned
			data.unlockedRewardSets[picked.name] = true
			
			-- Grant each block in the set
			data.unlockedBlocks = data.unlockedBlocks or {}
			grantedBlockIds = {}
			for _, blockId in ipairs(picked.grants) do
				if not data.unlockedBlocks[blockId] then
					data.unlockedBlocks[blockId] = true
					table.insert(grantedBlockIds, blockId)
				end
			end
			
			rewardSetInfo = {
				setName = picked.name,
				rarity = picked.rarity,
				grants = picked.grants, -- full list for client display
				newlyGranted = grantedBlockIds, -- only the ones not previously owned
			}
			
			print(string.format("[CoinManager] Daily SET drop: %d -> '%s' (%s) | grants=%d, newly granted=%d",
				userId, picked.name, picked.rarity, #picked.grants, #grantedBlockIds))
		else
			-- Folder missing or all sets owned -> fall back to coins
			gotSet = false
			if RewardSetPicker.GetTotalSetCount() > 0 then
				print(string.format("[CoinManager] Daily claim: %d has all reward sets, falling back to coins", userId))
			end
		end
	end
	
	-- Calculate coin reward (only awarded if we ended up on the coin branch)
	local totalReward = 0
	local isWeekComplete = false
	
	if not gotSet then
		-- Randomized roll per day, scaled by current week's multiplier.
		-- Plus players get the full payout; non-Plus players get NonPlusDailyMultiplier
		-- of it (see CoinConfig). hasPlus was resolved above for the set roll.
		totalReward = CoinConfig.RollDailyReward(dayInWeek, currentWeek, nil, hasPlus)
		if not hasPlus then
			print(string.format("[BB-PLUS] Daily reward for %d reduced (no Plus): W%d D%d -> %d coins (x%.2f)",
				userId, currentWeek, dayInWeek, totalReward, CoinConfig.GetNonPlusDailyMultiplier()))
		end
		if dayInWeek == 7 then
			isWeekComplete = true
			data.dailyWeeksCompleted = (data.dailyWeeksCompleted or 0) + 1
			
			-- Update achievement progress for completed weeks
			CoinManager.UpdateAchievementProgress(userId, "daily_streak", data.dailyWeeksCompleted)
		end
	end
	
	-- Update streak/timing data
	data.dailyStreak = streak
	data.dailyLastClaim = now
	DataDirty[userId] = true
	
	-- Update persistent global streak leaderboard. Wrapped in pcall — a write
	-- failure here must never break the claim itself.
	pcall(function()
		StreakLeaderboardOrdered:SetAsync(tostring(userId), streak)
	end)
	
	-- Award coins (only if coin branch)
	if not gotSet and totalReward > 0 then
		CoinManager.AddCoins(userId, totalReward, string.format("daily_reward_w%d_d%d", currentWeek, dayInWeek))
	end
	
	-- Fire NotifyNewBlocks BindableEvent so inventory NEW-badges update mid-session
	if grantedBlockIds and #grantedBlockIds > 0 then
		local player = Players:GetPlayerByUserId(userId)
		if player then
			-- Set Unlocked_<BlockId> attribute on the player so the inventory un-gates immediately
			for _, blockId in ipairs(grantedBlockIds) do
				player:SetAttribute("Unlocked_" .. blockId, true)
			end
			
			local remotes = ReplicatedStorage:FindFirstChild("Remotes")
			local notify = remotes and remotes:FindFirstChild("NotifyNewBlocks")
			if notify then
				notify:Fire(player, grantedBlockIds)
			end
		end
	end
	
	-- Fire daily claim callbacks
	for _, callback in ipairs(OnDailyClaimCallbacks) do
		task.spawn(callback, userId, streak, totalReward, rewardSetInfo)
	end
	
	-- Build message
	local message
	if rewardSetInfo then
		message = string.format("Week %d Day %d: %s unlocked!", currentWeek, dayInWeek, rewardSetInfo.setName)
	elseif isWeekComplete then
		message = string.format("Week %d complete! %d coins. Keep the streak going!", currentWeek, totalReward)
	else
		message = string.format("Week %d Day %d: %d coins!", currentWeek, dayInWeek, totalReward)
	end
	
	print(string.format("[CoinManager] Daily claim: %d streak=%d (W%d D%d) = %s (week complete: %s)",
		userId, streak, currentWeek, dayInWeek,
		rewardSetInfo and ("set '" .. rewardSetInfo.setName .. "'") or (totalReward .. " coins"),
		tostring(isWeekComplete)))
	
	return true, message, totalReward, rewardSetInfo
end

-- ============================================
-- ACHIEVEMENTS
-- ============================================
function CoinManager.GetAchievementProgress(userId: number, achievementId: string): (number, number)
	if not PlayerData[userId] then return 0, 0 end
	local achData = PlayerData[userId].achievements[achievementId]
	if not achData then return 0, 0 end
	return achData.progress or 0, achData.claimedTier or 0
end

function CoinManager.UpdateAchievementProgress(userId: number, achievementId: string, newProgress: number)
	if not PlayerData[userId] then return end
	
	if not PlayerData[userId].achievements[achievementId] then
		PlayerData[userId].achievements[achievementId] = { progress = 0, claimedTier = 0 }
	end
	
	local achData = PlayerData[userId].achievements[achievementId]
	if newProgress > achData.progress then
		achData.progress = newProgress
		DataDirty[userId] = true
	end
end

function CoinManager.IncrementAchievementProgress(userId: number, achievementId: string, amount: number?)
	if not PlayerData[userId] then return end
	
	if not PlayerData[userId].achievements[achievementId] then
		PlayerData[userId].achievements[achievementId] = { progress = 0, claimedTier = 0 }
	end
	
	local achData = PlayerData[userId].achievements[achievementId]
	achData.progress = achData.progress + (amount or 1)
	DataDirty[userId] = true
end

-- Claim an achievement tier reward (called from client via remote)
function CoinManager.ClaimAchievementReward(userId: number, achievementId: string, tierIndex: number): (boolean, string?, number?)
	if not PlayerData[userId] then
		return false, "Data not loaded", 0
	end
	
	-- Find the achievement definition
	local achDef = nil
	for _, def in ipairs(CoinConfig.Achievements) do
		if def.id == achievementId then
			achDef = def
			break
		end
	end
	
	if not achDef then
		return false, "Achievement not found", 0
	end
	
	if tierIndex < 1 or tierIndex > #achDef.tiers then
		return false, "Invalid tier", 0
	end
	
	local tier = achDef.tiers[tierIndex]
	local achData = PlayerData[userId].achievements[achievementId]
	if not achData then
		achData = { progress = 0, claimedTier = 0 }
		PlayerData[userId].achievements[achievementId] = achData
	end
	
	-- Check: must claim tiers in order
	if tierIndex ~= achData.claimedTier + 1 then
		return false, "Claim previous tiers first", 0
	end
	
	-- Check: must have enough progress
	if achData.progress < tier.threshold then
		return false, string.format("Need %d (have %d)", tier.threshold, achData.progress), 0
	end
	
	-- Claim!
	achData.claimedTier = tierIndex
	DataDirty[userId] = true
	
	CoinManager.AddCoins(userId, tier.reward, "achievement_" .. achievementId .. "_t" .. tierIndex)
	
	-- Fire callbacks
	for _, callback in ipairs(OnAchievementClaimedCallbacks) do
		task.spawn(callback, userId, achievementId, tierIndex, tier.reward)
	end
	
	print(string.format("[CoinManager] Achievement claimed: %d %s tier %d = %d coins", userId, achievementId, tierIndex, tier.reward))
	
	return true, "+" .. tier.reward .. " coins!", tier.reward
end

-- Get all achievement data for a player (for UI)
function CoinManager.GetAllAchievements(userId: number)
	if not PlayerData[userId] then return {} end
	
	local result = {}
	for _, def in ipairs(CoinConfig.Achievements) do
		local achData = PlayerData[userId].achievements[def.id] or { progress = 0, claimedTier = 0 }
		table.insert(result, {
			id = def.id,
			title = def.title,
			description = def.description,
			icon = def.icon,
			progress = achData.progress,
			claimedTier = achData.claimedTier,
			tiers = def.tiers,
		})
	end
	return result
end

-- ============================================
-- STAT HELPERS (for other scripts to call)
-- ============================================
function CoinManager.IncrementBlocksPlaced(userId: number, amount: number?)
	if not PlayerData[userId] then return end
	local inc = amount or 1
	PlayerData[userId].totalBlocksPlaced = (PlayerData[userId].totalBlocksPlaced or 0) + inc
	DataDirty[userId] = true
	
	-- Update achievement
	CoinManager.IncrementAchievementProgress(userId, "blocks_placed", inc)
end

function CoinManager.GetTotalBlocksPlaced(userId: number): number
	if not PlayerData[userId] then return 0 end
	return PlayerData[userId].totalBlocksPlaced or 0
end

-- ============================================
-- CALLBACKS (for CoinService to hook into)
-- ============================================
function CoinManager.OnCoinsChanged(callback)
	table.insert(OnCoinsChangedCallbacks, callback)
end

function CoinManager.OnDailyClaim(callback)
	table.insert(OnDailyClaimCallbacks, callback)
end

function CoinManager.OnAchievementClaimed(callback)
	table.insert(OnAchievementClaimedCallbacks, callback)
end

-- Returns up to `limit` entries from the persistent global streak leaderboard:
-- { { userId = number, streak = number }, ... }, sorted descending.
-- Includes offline players. Username resolution is left to the caller.
function CoinManager.GetTopStreaks(limit: number?)
	limit = math.clamp(tonumber(limit) or 10, 1, 100)
	local ok, pages = pcall(function()
		return StreakLeaderboardOrdered:GetSortedAsync(false, limit)
	end)
	if not ok or not pages then return {} end
	local entries = pages:GetCurrentPage()
	local result = {}
	for _, e in ipairs(entries) do
		local uid = tonumber(e.key)
		if uid then
			table.insert(result, { userId = uid, streak = e.value })
		end
	end
	return result
end

-- ============================================
-- PERIODIC SAVE
-- ============================================
task.spawn(function()
	while true do
		task.wait(120) -- Save dirty data every 2 minutes
		for userId, isDirty in pairs(DataDirty) do
			if isDirty and Players:GetPlayerByUserId(userId) then
				task.spawn(function()
					CoinManager.SavePlayerData(userId)
				end)
			end
		end
	end
end)

print("[CoinManager] Module loaded")

return CoinManager
