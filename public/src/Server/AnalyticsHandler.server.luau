--[[
	AnalyticsHandler
	Server-side handler for analytics tracking (Admin-only access)
	
	Connects to player events and block placement to track:
	- Block usage statistics
	- Session duration
	- New vs returning players
	- Top 10 playtime leaderboard
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

-- Load BetaConfig for owner check
local BetaConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("BetaConfig"))

-- Wait for modules
local AnalyticsManager = nil
task.spawn(function()
	local modulesFolder = script.Parent:WaitForChild("Modules", 10)
	if modulesFolder then
		local analyticsModule = modulesFolder:WaitForChild("AnalyticsManager", 10)
		if analyticsModule then
			AnalyticsManager = require(analyticsModule) 
			AnalyticsManager.Initialize()
			
			-- Exclude owner UserIds from the top-playtime leaderboard. Their
			-- playtime is still tracked for the per-player dashboard; they just
			-- don't rank against real players. game.CreatorId covers group/user
			-- ownership of the place itself; BetaConfig.OWNER_USER_ID is the
			-- manually-configured override.
			if game.CreatorId and game.CreatorId > 0 then
				AnalyticsManager.AddLeaderboardBlacklist(game.CreatorId)
			end
			if BetaConfig.OWNER_USER_ID and BetaConfig.OWNER_USER_ID ~= 0 then
				AnalyticsManager.AddLeaderboardBlacklist(BetaConfig.OWNER_USER_ID)
			end
		else
			warn("[AnalyticsHandler] AnalyticsManager module not found!")
		end
	end
end)

-- Wait for AdminRemotes folder (created by AdminPanelHandler). If it doesn't
-- exist, we still proceed (just skip the admin-only remotes). The block
-- tracking and player session tracking are independent of AdminRemotes.
local AdminRemotes = ReplicatedStorage:WaitForChild("AdminRemotes", 10)
if not AdminRemotes then
	warn("[AnalyticsHandler] AdminRemotes folder not found - analytics RemoteFunctions skipped, but tracking will continue")
end

-- ============================================
-- ADMIN CHECK (same as AdminPanelHandler)
-- ============================================
-- Declared early so the OnServerInvoke handlers below can capture it.
local function isOwner(player)
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

-- DEV experience tracks owner block placements too (for testing the analytics pipeline).
-- On PROD we keep owner placements out of globalBlockStats to avoid polluting
-- "what blocks real players use". This now controls block-stat tracking ONLY;
-- session/playtime tracking always runs for everyone (owner exclusion from the
-- top-playtime leaderboard is handled by AnalyticsManager.AddLeaderboardBlacklist).
-- 9675756310 = BuildBlox DEV experience GameId.
local DEV_GAME_ID = 9675756310
local function shouldSkipFromBlockStats(player)
	if game.GameId == DEV_GAME_ID then
		return false  -- never skip on DEV — owner placements count for testing
	end
	return isOwner(player)
end

-- Create analytics-specific remotes inside AdminRemotes (admin-only).
-- Skip if AdminRemotes didn't exist — the dashboard reads analytics via the
-- Cloudflare Worker, not these Roblox remotes, so it's not actually needed.
if AdminRemotes then
	local GetTopPlayers = Instance.new("RemoteFunction")
	GetTopPlayers.Name = "GetTopPlayers"
	GetTopPlayers.Parent = AdminRemotes
	
	local GetTopBlocks = Instance.new("RemoteFunction")
	GetTopBlocks.Name = "GetTopBlocks"
	GetTopBlocks.Parent = AdminRemotes
	
	local GetServerStats = Instance.new("RemoteFunction")
	GetServerStats.Name = "GetServerStats"
	GetServerStats.Parent = AdminRemotes
	
	-- Admin-only remote function handlers
	GetTopPlayers.OnServerInvoke = function(player, limit)
		if not isOwner(player) then return {} end
		if not AnalyticsManager then return {} end
		return AnalyticsManager.GetTopPlayers(limit or 10)
	end
	
	GetTopBlocks.OnServerInvoke = function(player, limit)
		if not isOwner(player) then return {} end
		if not AnalyticsManager then return {} end
		return AnalyticsManager.GetTopBlocks(limit or 10)
	end
	
	GetServerStats.OnServerInvoke = function(player)
		if not isOwner(player) then return nil end
		if not AnalyticsManager then return nil end
		return AnalyticsManager.GetServerStats()
	end
	
	print("[AnalyticsHandler] Analytics remotes created in AdminRemotes (admin-only)")
end

-- Wait for Remotes folder for block tracking
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 30)

-- ============================================
-- PLAYER CONNECTION HANDLING
-- ============================================

local function onPlayerAdded(player)
	-- Wait for AnalyticsManager to be ready
	while not AnalyticsManager do
		task.wait(0.1)
	end
	
	-- Load player data and start session for EVERYONE, including owner.
	-- Owner playtime needs to accrue so it shows up in the per-player dashboard.
	-- They're already blacklisted from the top-playtime leaderboard at init.
	AnalyticsManager.LoadPlayerData(player)
end

local function onPlayerRemoving(player)
	if not AnalyticsManager then return end
	
	-- Save player data (owner included — SavePlayerData itself skips the
	-- PlaytimeLeaderboard write for blacklisted userIds).
	AnalyticsManager.SavePlayerData(player)
	AnalyticsManager.CleanupPlayer(player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

-- Handle players already in game (for late script load)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end

-- ============================================
-- BLOCK TRACKING INTEGRATION
-- ============================================

-- Listen to PlaceBlock remote to track block placements
local PlaceBlock = Remotes:WaitForChild("PlaceBlock", 10)
if PlaceBlock then
	PlaceBlock.OnServerEvent:Connect(function(player, blockData, position, lookVector, hitNormal, cursorY)
		if not AnalyticsManager then
			print("[AnalyticsHandler] PlaceBlock: SKIP (AnalyticsManager nil)")
			return
		end
		
		-- Skip block-stat tracking for owner on PROD (keeps globalBlockStats clean)
		if shouldSkipFromBlockStats(player) then
			print("[AnalyticsHandler] PlaceBlock: SKIP owner " .. player.Name .. " (gameId=" .. tostring(game.GameId) .. ")")
			return
		end
		
		-- Handle both string and table block data
		local blockName
		if type(blockData) == "string" then
			blockName = blockData
		elseif type(blockData) == "table" and blockData.Id then
			blockName = blockData.Id
		elseif type(blockData) == "table" and blockData.Name then
			blockName = blockData.Name
		else
			-- Can't determine block name, skip tracking
			return
		end
		
		-- Extract base block name (remove shape suffixes for cleaner stats)
		local baseBlockName = blockName
		if string.match(blockName, "Stair$") then
			baseBlockName = string.gsub(blockName, "Stair$", "")
		elseif string.match(blockName, "Slab$") then
			baseBlockName = string.gsub(blockName, "Slab$", "")
		end
		
		-- Track the placement
		print("[AnalyticsHandler] PlaceBlock: tracking " .. baseBlockName .. " by " .. player.Name)
		AnalyticsManager.TrackBlockPlaced(player, baseBlockName)
	end)
	
	print("[AnalyticsHandler] Hooked into PlaceBlock for tracking")
end

-- Listen to RemoveBlock remote to track block removals
local RemoveBlock = Remotes:WaitForChild("RemoveBlock", 10)
if RemoveBlock then
	RemoveBlock.OnServerEvent:Connect(function(player, position)
		if not AnalyticsManager then return end
		
		-- Skip block-stat tracking for owner on PROD (keeps globalBlockStats clean)
		if shouldSkipFromBlockStats(player) then return end
		
		AnalyticsManager.TrackBlockBroken(player, "Unknown")
	end)
	
	print("[AnalyticsHandler] Hooked into RemoveBlock for tracking")
end

-- ============================================
-- GAME CLOSE HANDLING
-- ============================================

game:BindToClose(function()
	print("[AnalyticsHandler] Server shutting down - saving all data...")
	
	if not AnalyticsManager then return end
	
	-- Save all player data
	for _, player in ipairs(Players:GetPlayers()) do
		AnalyticsManager.SavePlayerData(player)
	end
	
	-- Save global stats
	AnalyticsManager.SaveGlobalStats()
	
	-- Wait a bit to ensure saves complete
	task.wait(2)
	
	print("[AnalyticsHandler] All analytics data saved!")
end)

print("[AnalyticsHandler] Analytics system initialized (admin-only)!")
