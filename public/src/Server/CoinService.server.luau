--[[
	CoinService.server.luau
	Server script that wires up Build Coins remotes and integrates with other systems
	
	Remotes created:
	- GetCoinData (RemoteFunction) — client requests full coin state
	- CoinBalanceUpdate (RemoteEvent) — server → client balance push
	- ClaimDailyReward (RemoteEvent) — client → server daily claim request
	- DailyRewardResult (RemoteEvent) — server → client claim result
	- ClaimAchievement (RemoteEvent) — client → server achievement claim
	- AchievementResult (RemoteEvent) — server → client achievement result
	- CoinNotification (RemoteEvent) — server → client popup notifications (+coins)
	- ClaimCommunityReward (RemoteEvent) — client → server one-time group-join reward claim
	- CommunityRewardResult (RemoteEvent) — server → client claim result (success/reason)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local GroupService = game:GetService("GroupService")

-- Wait for modules
local Modules = ServerScriptService:WaitForChild("Modules", 10)
local CoinManager = require(Modules:WaitForChild("CoinManager", 10))
local CoinConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("CoinConfig"))
local AnalyticsEvents = require(Modules:WaitForChild("AnalyticsEvents", 10))

-- ============================================
-- CREATE REMOTES
-- ============================================
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)

local GetCoinData = Instance.new("RemoteFunction")
GetCoinData.Name = "GetCoinData"
GetCoinData.Parent = Remotes

local CoinBalanceUpdate = Instance.new("RemoteEvent")
CoinBalanceUpdate.Name = "CoinBalanceUpdate"
CoinBalanceUpdate.Parent = Remotes

-- Client fires this whenever the shop UI is opened (any source). Server logs a
-- `shop_open` analytics event, throttled per player so a looping client can't
-- inflate the funnel's top number. Mirrors PlusService's PlusUIOpened pattern.
local ShopOpened = Instance.new("RemoteEvent")
ShopOpened.Name = "ShopOpened"
ShopOpened.Parent = Remotes

local ShopOpenThrottle = {}
local SHOP_OPEN_MIN_GAP = 2

ShopOpened.OnServerEvent:Connect(function(player)
	if not player or not player.Parent then return end
	local now = os.clock()
	local last = ShopOpenThrottle[player.UserId]
	if last and (now - last) < SHOP_OPEN_MIN_GAP then return end
	ShopOpenThrottle[player.UserId] = now

	AnalyticsEvents.Post("shop_open", {
		userId = player.UserId,
		username = player.Name,
	})
end)

Players.PlayerRemoving:Connect(function(player)
	ShopOpenThrottle[player.UserId] = nil
end)

local ClaimDailyReward = Instance.new("RemoteEvent")
ClaimDailyReward.Name = "ClaimDailyReward"
ClaimDailyReward.Parent = Remotes

local DailyRewardResult = Instance.new("RemoteEvent")
DailyRewardResult.Name = "DailyRewardResult"
DailyRewardResult.Parent = Remotes

local ClaimAchievement = Instance.new("RemoteEvent")
ClaimAchievement.Name = "ClaimAchievement"
ClaimAchievement.Parent = Remotes

local AchievementResult = Instance.new("RemoteEvent")
AchievementResult.Name = "AchievementResult"
AchievementResult.Parent = Remotes

local CoinNotification = Instance.new("RemoteEvent")
CoinNotification.Name = "CoinNotification"
CoinNotification.Parent = Remotes

local ClaimCommunityReward = Instance.new("RemoteEvent")
ClaimCommunityReward.Name = "ClaimCommunityReward"
ClaimCommunityReward.Parent = Remotes

local CommunityRewardResult = Instance.new("RemoteEvent")
CommunityRewardResult.Name = "CommunityRewardResult"
CommunityRewardResult.Parent = Remotes

-- Mod shop: client invokes BuyMod(modId) to purchase a mod with coins. Server
-- validates + charges + grants, then returns a result table. GetOwnedMods lets
-- the shop UI ask which mods the player already owns.
local BuyMod = Instance.new("RemoteFunction")
BuyMod.Name = "BuyMod"
BuyMod.Parent = Remotes

local GetOwnedMods = Instance.new("RemoteFunction")
GetOwnedMods.Name = "GetOwnedMods"
GetOwnedMods.Parent = Remotes

-- Track vote coins earned this session (for cap)
local VoteCoinsThisSession = {} -- userId -> coins earned from votes this session

-- ============================================
-- PLAYER JOIN / LEAVE
-- ============================================
Players.PlayerAdded:Connect(function(player)
	task.spawn(function()
		local success = CoinManager.LoadPlayerData(player.UserId)
		if success then
			-- Push initial balance to client
			CoinBalanceUpdate:FireClient(player, CoinManager.GetCoins(player.UserId))
			
			-- Replay reward-block unlock attributes so the inventory un-gates on first frame
			CoinManager.ApplyUnlockAttributesToPlayer(player)
			
			-- Update login achievement
			local data = CoinManager.GetPlayerData(player.UserId)
			if data then
				CoinManager.UpdateAchievementProgress(player.UserId, "logins", data.totalLogins)
			end
		end
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	VoteCoinsThisSession[player.UserId] = nil
	CoinManager.CleanupPlayer(player.UserId)
end)

-- Save all on shutdown
game:BindToClose(function()
	local threads = {}
	for _, player in ipairs(Players:GetPlayers()) do
		table.insert(threads, task.spawn(function()
			CoinManager.SavePlayerData(player.UserId)
		end))
	end
	task.wait(5) -- Give DataStore time to flush
end)

-- ============================================
-- REMOTE HANDLERS
-- ============================================

-- Client requests full coin data (on UI open, etc.)
GetCoinData.OnServerInvoke = function(player)
	if not CoinManager.IsDataLoaded(player.UserId) then
		-- Try to wait for load
		local waitStart = tick()
		while not CoinManager.IsDataLoaded(player.UserId) and (tick() - waitStart) < 10 do
			task.wait(0.5)
		end
	end
	
	local data = CoinManager.GetPlayerData(player.UserId)
	if not data then
		return nil
	end
	
	return {
		coins = data.coins,
		totalEarned = data.totalEarned,
		totalSpent = data.totalSpent,
		dailyStatus = CoinManager.GetDailyRewardStatus(player.UserId),
		achievements = CoinManager.GetAllAchievements(player.UserId),
		ownedMods = CoinManager.GetOwnedMods(player.UserId),
	}
end

-- Client requests which mods it owns (shop UI open / refresh).
GetOwnedMods.OnServerInvoke = function(player)
	return CoinManager.GetOwnedMods(player.UserId)
end

-- Client buys a mod with coins. Returns { ok, message, balance, owned }.
BuyMod.OnServerInvoke = function(player, modId)
	if type(modId) ~= "string" then
		return { ok = false, message = "Bad request", balance = CoinManager.GetCoins(player.UserId), owned = CoinManager.GetOwnedMods(player.UserId) }
	end

	local ok, message = CoinManager.PurchaseMod(player.UserId, modId)
	if ok then
		-- Push updated balance so every coin display refreshes
		CoinBalanceUpdate:FireClient(player, CoinManager.GetCoins(player.UserId))
		-- Analytics: coin sink already logged by SpendCoins; add a mod-specific event
		pcall(function()
			AnalyticsEvents.Post("mod_purchase", {
				userId = player.UserId,
				username = player.Name,
				modId = modId,
			})
		end)
	end

	return {
		ok = ok,
		message = message,
		balance = CoinManager.GetCoins(player.UserId),
		owned = CoinManager.GetOwnedMods(player.UserId),
	}
end

-- Client claims daily reward
ClaimDailyReward.OnServerEvent:Connect(function(player)
	local success, message, coinsAwarded, rewardSetInfo = CoinManager.ClaimDailyReward(player.UserId)
	DailyRewardResult:FireClient(player, success, message, coinsAwarded, rewardSetInfo)
	
	if success then
		-- Also push updated balance
		CoinBalanceUpdate:FireClient(player, CoinManager.GetCoins(player.UserId))
	end
end)

-- Daily-reward claim analytics. One `daily_claim` event per successful claim,
-- with streak + whether it was a coin roll or a reward-set drop (and which set).
CoinManager.OnDailyClaim(function(userId, streak, coinsAwarded, rewardSetInfo)
	local player = Players:GetPlayerByUserId(userId)
	AnalyticsEvents.Post("daily_claim", {
		userId = userId,
		username = (player and player.Name) or ("User" .. tostring(userId)),
		streak = streak,
		rewardType = rewardSetInfo and "block_set" or "coins",
		setName = rewardSetInfo and rewardSetInfo.setName or nil,
		coinAmount = coinsAwarded or 0,
	})
end)

-- Client claims achievement reward
ClaimAchievement.OnServerEvent:Connect(function(player, achievementId, tierIndex)
	if type(achievementId) ~= "string" or type(tierIndex) ~= "number" then return end
	
	local success, message, coinsAwarded = CoinManager.ClaimAchievementReward(player.UserId, achievementId, tierIndex)
	AchievementResult:FireClient(player, success, message, achievementId, tierIndex, coinsAwarded)
	
	if success then
		CoinBalanceUpdate:FireClient(player, CoinManager.GetCoins(player.UserId))
	end
end)

-- ============================================
-- COMMUNITY JOIN REWARD
-- Client fires this once it detects the player has joined the group
-- (via player:IsInGroup polling). Server re-verifies membership and the
-- one-time flag before awarding coins, so the client check can't be spoofed.
-- ============================================
local ClaimCommunityCooldown = {} -- userId -> os.clock() of last attempt (anti-spam)
local CLAIM_COOLDOWN = 2 -- seconds between attempts per player

ClaimCommunityReward.OnServerEvent:Connect(function(player)
	if not player or not player.Parent then return end
	local userId = player.UserId

	-- Anti-spam: the client polls every few seconds, so a couple of duplicate
	-- fires can race. Reject anything inside the cooldown window.
	local now = os.clock()
	local last = ClaimCommunityCooldown[userId]
	if last and (now - last) < CLAIM_COOLDOWN then
		return
	end
	ClaimCommunityCooldown[userId] = now

	-- Make sure coin data is loaded (it should be, but be defensive on early claims)
	if not CoinManager.IsDataLoaded(userId) then
		CommunityRewardResult:FireClient(player, false, "not_ready", 0)
		return
	end

	-- Already claimed? Tell the client so it can hide the button.
	if CoinManager.IsCommunityRewardClaimed(userId) then
		CommunityRewardResult:FireClient(player, false, "already_claimed", 0)
		return
	end

	-- Server-side group membership re-check (do not trust client).
	--
	-- IsInGroup is cached server-side for ~60 seconds, so a player who joined
	-- the community 2 seconds ago via PromptJoinAsync will still register as
	-- a non-member here. To handle that, if the fast cached check says false,
	-- we re-verify against GroupService:GetGroupsAsync (uncached) before
	-- rejecting the claim. Reference: Roblox "Prompt players to join Communities
	-- from in-experience" announcement, Dec 2025.
	local okFast, isMemberFast = pcall(function()
		return player:IsInGroup(CoinConfig.CommunityGroupId)
	end)
	if not okFast then
		warn("[CoinService] IsInGroup check failed for", userId, ":", isMemberFast)
		CommunityRewardResult:FireClient(player, false, "check_failed", 0)
		return
	end

	local isMember = isMemberFast
	if not isMember then
		-- Fall through to the uncached check before giving up.
		local okSlow, groups = pcall(function()
			return GroupService:GetGroupsAsync(userId)
		end)
		if okSlow and type(groups) == "table" then
			for _, info in ipairs(groups) do
				if info.Id == CoinConfig.CommunityGroupId then
					isMember = true
					break
				end
			end
		else
			warn("[CoinService] GetGroupsAsync check failed for", userId, ":", groups)
		end
	end

	if not isMember then
		CommunityRewardResult:FireClient(player, false, "not_in_group", 0)
		return
	end

	-- All checks passed — award coins and persist the flag
	local reward = CoinConfig.CommunityJoinReward
	local awarded = CoinManager.AddCoins(userId, reward, "community_join")
	if not awarded then
		CommunityRewardResult:FireClient(player, false, "award_failed", 0)
		return
	end

	CoinManager.MarkCommunityRewardClaimed(userId)
	print(string.format("[CoinService] Community join reward granted to %d (+%d coins)", userId, reward))
	CommunityRewardResult:FireClient(player, true, "granted", reward)
end)

-- Clean up cooldown entry on leave
Players.PlayerRemoving:Connect(function(player)
	ClaimCommunityCooldown[player.UserId] = nil
end)

-- ============================================
-- COIN CHANGE → CLIENT PUSH
-- ============================================
CoinManager.OnCoinsChanged(function(userId, newBalance, delta, reason)
	local player = Players:GetPlayerByUserId(userId)
	if player then
		CoinBalanceUpdate:FireClient(player, newBalance)
		
		-- Send popup notification for gains
		if delta > 0 then
			CoinNotification:FireClient(player, delta, reason)
		end
	end
end)

-- ============================================
-- LIKES / VOTE INTEGRATION
-- Award coins when a player's build gets liked
-- ============================================
local LikeResult = Remotes:WaitForChild("LikeResult", 10)

-- We need to hook into the LikesHandler's successful like flow.
-- The cleanest way: listen for LikeResult events being fired to the *owner*
-- with a success message containing "liked your build"
-- Instead, we'll create a dedicated remote that LikesHandler can fire.

local LikeCoinsAward = Instance.new("BindableEvent")
LikeCoinsAward.Name = "LikeCoinsAward"
LikeCoinsAward.Parent = ServerScriptService

-- This will be connected from LikesHandler (we'll add a hook there)
LikeCoinsAward.Event:Connect(function(ownerUserId, likerName)
	if not CoinManager.IsDataLoaded(ownerUserId) then return end
	
	-- Check session cap
	local earned = VoteCoinsThisSession[ownerUserId] or 0
	local cap = CoinConfig.VoteSessionCap or 30
	if earned >= cap then
		-- Silently skip — player hit vote coin cap this session
		return
	end
	
	local reward = math.min(CoinConfig.VoteReward, cap - earned)
	VoteCoinsThisSession[ownerUserId] = earned + reward
	CoinManager.AddCoins(ownerUserId, reward, "vote_from_" .. (likerName or "unknown"))
end)

-- Also expose a function other server scripts can call directly
local CoinManagerAccess = Instance.new("BindableFunction")
CoinManagerAccess.Name = "CoinManagerAccess"
CoinManagerAccess.Parent = ServerScriptService

CoinManagerAccess.OnInvoke = function(action, ...)
	if action == "AddCoins" then
		return CoinManager.AddCoins(...)
	elseif action == "GetCoins" then
		return CoinManager.GetCoins(...)
	elseif action == "UpdateAchievement" then
		return CoinManager.UpdateAchievementProgress(...)
	elseif action == "IncrementBlocks" then
		return CoinManager.IncrementBlocksPlaced(...)
	end
	return nil
end

-- ============================================
-- BLOCK PLACEMENT INTEGRATION
-- Increment blocks placed stat when player builds
-- ============================================
local BuildBlock = Remotes:FindFirstChild("BuildBlock")
-- Note: BlockHandler fires "BuildComplete" or similar. We hook into the 
-- block placed count differently — we'll add a hook in BlockHandler.
-- For now, expose the IncrementBlocksPlaced via the BindableFunction above.

-- ============================================
-- DEV CHAT COMMAND: /resetcommunityreward
-- Resets the one-time community-join reward flag so the developer can
-- re-test the full claim flow without rolling a new account.
-- Gated to game.CreatorId only.
-- ============================================
Players.PlayerAdded:Connect(function(player)
	if player.UserId ~= game.CreatorId then return end
	player.Chatted:Connect(function(message)
		if string.lower(message) ~= "/resetcommunityreward" then return end
		CoinManager.ResetCommunityRewardClaim(player.UserId)
		print(string.format("[CoinService] [DEV] Community-join reward flag cleared for %s", player.Name))
	end)
end)

-- ============================================
-- ROBUX COIN PACK RECEIPT HANDLER
-- Registers each configured coin pack with SaveManager's dispatcher so a
-- player who buys a pack via MarketplaceService:PromptProductPurchase has
-- the coins credited and persisted server-side. Packs with productId == 0
-- are skipped (those are the "Soon!" entries that haven't been wired to a
-- real Developer Product yet).
-- ============================================
local function grantCoinPack(receiptInfo, pack)
	local userId = receiptInfo.PlayerId
	local packCoins = pack.coins

	-- Make sure the player's coin data is loaded. PlayerAdded above kicks off
	-- a LoadPlayerData task, but a receipt that arrives on first-join can race
	-- ahead of it. If data isn't ready, defer the receipt — Roblox will retry
	-- and the next attempt will find data loaded.
	if not CoinManager.IsDataLoaded(userId) then
		warn("[CoinService] Receipt arrived before coin data loaded for", userId, "— deferring")
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local added = CoinManager.AddCoins(userId, packCoins, "robux_pack")
	if not added then
		warn("[CoinService] AddCoins refused for", userId, "pack=", packCoins)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- CRITICAL: persist immediately. Returning PurchaseGranted is a promise to
	-- Roblox that the coins were delivered; if we relied on the periodic save
	-- and the server crashed before the next flush, the player would lose what
	-- they paid for and Roblox wouldn't retry (the receipt is marked done).
	local saved = CoinManager.SavePlayerData(userId)
	if not saved then
		warn("[CoinService] Failed to persist coin pack purchase for", userId, "— deferring receipt")
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	print(string.format("[CoinService] Granted %d-coin pack to userId=%d (productId=%d)",
		packCoins, userId, receiptInfo.ProductId))
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

-- Wait for SaveManager to expose the dispatcher hook. SaveManager and
-- CoinService both initialize at game start, and load order isn't guaranteed.
task.spawn(function()
	local waited = 0
	while not _G.RegisterReceiptHandler and waited < 10 do
		task.wait(0.5)
		waited = waited + 0.5
	end
	if not _G.RegisterReceiptHandler then
		warn("[CoinService] _G.RegisterReceiptHandler never appeared — coin pack purchases won't be processed")
		return
	end

	local registered = 0
	for _, pack in ipairs(CoinConfig.CoinPacks) do
		if pack.productId and pack.productId > 0 then
			local coinsForThisPack = pack.coins
			_G.RegisterReceiptHandler(pack.productId, function(receiptInfo)
				return grantCoinPack(receiptInfo, coinsForThisPack)
			end)
			registered = registered + 1
		end
	end
	print(string.format("[CoinService] Registered %d coin pack receipt handler(s)", registered))
end)

print("[CoinService] Initialized — Build Coins system active")
