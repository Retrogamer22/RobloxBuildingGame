--[[
	LikesHandler
	Handles the likes system for player builds
	
	Features:
	- Players can like other players' builds (not their own)
	- Each player can only like another player ONCE (persistent)
	- Leaderboard shows total likes for all players
	- Likes are tied to the player, not the specific buildplate
	
	DataStore structure:
	- Key: "totalLikes_{UserId}" -> number (total likes received)
	- Key: "givenLikes_{UserId}" -> table of UserIds they've liked
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local GridConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GridConfig"))

-- Configuration
local DATASTORE_NAME = "LikesData_v1"
local LEADERBOARD_UPDATE_INTERVAL = 30 -- How often to refresh leaderboard data
local MAX_LEADERBOARD_ENTRIES = 50 -- Max entries to show on leaderboard

-- Get DataStore
local LikesDataStore = nil
-- Ordered DataStore for the persistent global likes leaderboard (offline-inclusive)
local LikesLeaderboardOrdered = DataStoreService:GetOrderedDataStore("LikesLeaderboard_v1")
local function getDataStore()
	if LikesDataStore then return LikesDataStore end
	
	local success, result = pcall(function()
		return DataStoreService:GetDataStore(DATASTORE_NAME)
	end)
	
	if success then
		LikesDataStore = result
		return LikesDataStore
	else
		warn("[LikesHandler] Failed to get DataStore: " .. tostring(result))
		return nil
	end
end

-- Create Remotes
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)

local LikePlayer = Instance.new("RemoteEvent")
LikePlayer.Name = "LikePlayer"
LikePlayer.Parent = Remotes

local LikeResult = Instance.new("RemoteEvent")
LikeResult.Name = "LikeResult"
LikeResult.Parent = Remotes

local RequestLeaderboard = Instance.new("RemoteEvent")
RequestLeaderboard.Name = "RequestLeaderboard"
RequestLeaderboard.Parent = Remotes

local UpdateLeaderboard = Instance.new("RemoteEvent")
UpdateLeaderboard.Name = "UpdateLeaderboard"
UpdateLeaderboard.Parent = Remotes

-- Cache for player data (reduces DataStore calls)
local PlayerLikesCache = {} -- userId -> { totalLikes, givenLikes, lastFetch }
local LeaderboardCache = {} -- Array of { userId, username, totalLikes }
local LeaderboardLastUpdate = 0

local CACHE_DURATION = 60 -- Cache duration in seconds

-- ============================================
-- DATA FUNCTIONS
-- ============================================

local function getTotalLikesKey(userId)
	return "totalLikes_" .. tostring(userId)
end

local function getGivenLikesKey(userId)
	return "givenLikes_" .. tostring(userId)
end

-- Get player's total likes received
local function getTotalLikes(userId)
	local dataStore = getDataStore()
	if not dataStore then return 0 end
	
	-- Check cache first
	local cached = PlayerLikesCache[userId]
	if cached and (tick() - cached.lastFetch) < CACHE_DURATION then
		return cached.totalLikes
	end
	
	local key = getTotalLikesKey(userId)
	local success, result = pcall(function()
		return dataStore:GetAsync(key)
	end)
	
	if success then
		local totalLikes = result or 0
		-- Update cache
		if not PlayerLikesCache[userId] then
			PlayerLikesCache[userId] = { totalLikes = 0, givenLikes = {}, lastFetch = 0 }
		end
		PlayerLikesCache[userId].totalLikes = totalLikes
		PlayerLikesCache[userId].lastFetch = tick()
		return totalLikes
	else
		warn("[LikesHandler] Failed to get total likes for " .. userId .. ": " .. tostring(result))
		return 0
	end
end

-- Get list of players this user has liked
local function getGivenLikes(userId)
	local dataStore = getDataStore()
	if not dataStore then return {} end
	
	-- Check cache first
	local cached = PlayerLikesCache[userId]
	if cached and cached.givenLikes and (tick() - cached.lastFetch) < CACHE_DURATION then
		return cached.givenLikes
	end
	
	local key = getGivenLikesKey(userId)
	local success, result = pcall(function()
		return dataStore:GetAsync(key)
	end)
	
	if success then
		local givenLikes = result or {}
		-- Update cache
		if not PlayerLikesCache[userId] then
			PlayerLikesCache[userId] = { totalLikes = 0, givenLikes = {}, lastFetch = 0 }
		end
		PlayerLikesCache[userId].givenLikes = givenLikes
		PlayerLikesCache[userId].lastFetch = tick()
		return givenLikes
	else
		warn("[LikesHandler] Failed to get given likes for " .. userId .. ": " .. tostring(result))
		return {}
	end
end

-- Check if player has already liked target
local function hasLiked(likerUserId, targetUserId)
	local givenLikes = getGivenLikes(likerUserId)
	return givenLikes[tostring(targetUserId)] == true
end

-- Add a like from liker to target
local function addLike(likerUserId, targetUserId)
	local dataStore = getDataStore()
	if not dataStore then
		return false, "DataStore not available"
	end
	
	-- First, add to the liker's "given likes" list
	local givenLikesKey = getGivenLikesKey(likerUserId)
	local success1, err1 = pcall(function()
		dataStore:UpdateAsync(givenLikesKey, function(oldData)
			local data = oldData or {}
			data[tostring(targetUserId)] = true
			return data
		end)
	end)
	
	if not success1 then
		warn("[LikesHandler] Failed to update given likes: " .. tostring(err1))
		return false, "Failed to record like"
	end
	
	-- Then, increment the target's total likes
	local totalLikesKey = getTotalLikesKey(targetUserId)
	local newTotal = 0
	local success2, err2 = pcall(function()
		newTotal = dataStore:IncrementAsync(totalLikesKey, 1)
	end)
	
	if not success2 then
		warn("[LikesHandler] Failed to increment total likes: " .. tostring(err2))
		-- Rollback the given like
		pcall(function()
			dataStore:UpdateAsync(givenLikesKey, function(oldData)
				local data = oldData or {}
				data[tostring(targetUserId)] = nil
				return data
			end)
		end)
		return false, "Failed to add like"
	end
	
	-- Update caches
	if PlayerLikesCache[likerUserId] then
		PlayerLikesCache[likerUserId].givenLikes[tostring(targetUserId)] = true
	end
	if PlayerLikesCache[targetUserId] then
		PlayerLikesCache[targetUserId].totalLikes = newTotal
	end
	
	-- Update persistent global leaderboard so offline players still appear in
	-- the analytics dashboard's top-likes list. Wrapped in pcall — a leaderboard
	-- write failure should never break the like itself.
	pcall(function()
		LikesLeaderboardOrdered:SetAsync(tostring(targetUserId), newTotal)
	end)
	
	-- Invalidate leaderboard cache
	LeaderboardLastUpdate = 0
	
	print(string.format("[LikesHandler] %d liked %d (new total: %d)", likerUserId, targetUserId, newTotal))
	return true, newTotal
end

-- ============================================
-- LEADERBOARD FUNCTIONS
-- ============================================

-- Build leaderboard from current online players + cached data
local function buildLeaderboard()
	-- Check if we need to refresh
	if (tick() - LeaderboardLastUpdate) < LEADERBOARD_UPDATE_INTERVAL and #LeaderboardCache > 0 then
		return LeaderboardCache
	end
	
	local leaderboard = {}
	local processedUsers = {}
	
	-- First, add all online players
	for _, player in ipairs(Players:GetPlayers()) do
		local userId = player.UserId
		local totalLikes = getTotalLikes(userId)
		
		table.insert(leaderboard, {
			userId = userId,
			username = player.Name,
			displayName = player.DisplayName,
			totalLikes = totalLikes,
			isOnline = true
		})
		processedUsers[userId] = true
	end
	
	-- Sort by likes (descending)
	table.sort(leaderboard, function(a, b)
		return a.totalLikes > b.totalLikes
	end)
	
	-- Trim to max entries
	if #leaderboard > MAX_LEADERBOARD_ENTRIES then
		for i = MAX_LEADERBOARD_ENTRIES + 1, #leaderboard do
			leaderboard[i] = nil
		end
	end
	
	LeaderboardCache = leaderboard
	LeaderboardLastUpdate = tick()
	
	return leaderboard
end

-- Broadcast leaderboard to all players
local function broadcastLeaderboard()
	local leaderboard = buildLeaderboard()
	UpdateLeaderboard:FireAllClients(leaderboard)
end

-- ============================================
-- SIGN FUNCTIONS
-- ============================================

local function getPlotOwner(buildArea)
	local ownerUserId = buildArea:GetAttribute("OwnerUserId")
	local ownerName = buildArea:GetAttribute("OwnerName")
	return ownerUserId, ownerName
end

-- Update the sign text to show like count
local function updateSignText(buildArea, likeCount)
	local likeSign = buildArea:FindFirstChild("LikeSign")
	if not likeSign then return end
	
	local textPart = likeSign:FindFirstChild("Text")
	if not textPart then return end
	
	-- Look for our custom SurfaceGui (created below) or create one
	local surfaceGui = textPart:FindFirstChild("LikeCountGui")
	
	if not surfaceGui then
		-- Create a new SurfaceGui to overlay the like count
		surfaceGui = Instance.new("SurfaceGui")
		surfaceGui.Name = "LikeCountGui"
		surfaceGui.Face = Enum.NormalId.Front
		surfaceGui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		surfaceGui.PixelsPerStud = 50
		surfaceGui.LightInfluence = 0
		surfaceGui.Brightness = 1
		surfaceGui.ZOffset = 0.1 -- Slightly in front of texture
		
		-- Create the text label
		local textLabel = Instance.new("TextLabel")
		textLabel.Name = "LikeCount"
		textLabel.Size = UDim2.new(1, 0, 1, 0)
		textLabel.BackgroundTransparency = 1
		textLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		textLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
		textLabel.TextStrokeTransparency = 0.3
		textLabel.Font = Enum.Font.GothamBold
		textLabel.TextScaled = true
		textLabel.Text = ""
		textLabel.Parent = surfaceGui
		
		surfaceGui.Parent = textPart
	end
	
	-- Update the text
	local textLabel = surfaceGui:FindFirstChild("LikeCount")
	if textLabel then
		if likeCount > 0 then
			textLabel.Text = tostring(likeCount) .. " \226\157\164" -- Heart emoji
		else
			textLabel.Text = "Like"
		end
	end
end

-- Update all signs when plot owners change
local function updateAllSigns()
	for i = 1, GridConfig.TOTAL_PLOTS do
		local buildArea = workspace:FindFirstChild(GridConfig.BUILD_AREA_PREFIX .. i)
		if buildArea then
			local ownerUserId = buildArea:GetAttribute("OwnerUserId")
			if ownerUserId then
				local totalLikes = getTotalLikes(ownerUserId)
				updateSignText(buildArea, totalLikes)
			else
				updateSignText(buildArea, 0)
			end
		end
	end
end

local function setupLikeSigns()
	for i = 1, GridConfig.TOTAL_PLOTS do
		local buildArea = workspace:FindFirstChild(GridConfig.BUILD_AREA_PREFIX .. i)
		if buildArea then
			local likeSign = buildArea:FindFirstChild("LikeSign")
			if likeSign then
				local clickPart = likeSign:FindFirstChild("ClickPart")
				if clickPart then
					-- Create or get ClickDetector
					local detector = clickPart:FindFirstChild("ClickDetector")
					if not detector then
						detector = Instance.new("ClickDetector")
						detector.MaxActivationDistance = 10
						detector.Parent = clickPart
					end
					
					-- Handle click
					detector.RightMouseClick:Connect(function(player)
						local ownerUserId, ownerName = getPlotOwner(buildArea)
						
						-- Check if plot is owned
						if not ownerUserId then
							LikeResult:FireClient(player, false, "This plot has no owner")
							return
						end
						
						-- Check if trying to like own plot
						if ownerUserId == player.UserId then
							LikeResult:FireClient(player, false, "You can't like your own build!")
							return
						end
						
						-- Check if already liked this player
						if hasLiked(player.UserId, ownerUserId) then
							local totalLikes = getTotalLikes(ownerUserId)
							LikeResult:FireClient(player, false, "You already liked " .. (ownerName or "this player") .. "'s build! (" .. totalLikes .. " total likes)")
							return
						end
						
						-- Add the like
						local success, result = addLike(player.UserId, ownerUserId)
						if success then
							LikeResult:FireClient(player, true, "Liked " .. (ownerName or "this player") .. "'s build! (" .. result .. " total likes)")
							
							-- Update the sign text
							updateSignText(buildArea, result)
							
							-- Notify the owner if they're online
							local owner = Players:GetPlayerByUserId(ownerUserId)
							if owner then
								LikeResult:FireClient(owner, true, player.Name .. " liked your build! (" .. result .. " total likes)")
							end
							
							-- Award Build Coins to the plot owner
							task.spawn(function()
							local likeCoinsAward = ServerScriptService:FindFirstChild("LikeCoinsAward")
							if likeCoinsAward then
								likeCoinsAward:Fire(ownerUserId, player.Name)
							end
							
							-- Update likes_received achievement via CoinManager
							local coinAccess = ServerScriptService:FindFirstChild("CoinManagerAccess")
							if coinAccess then
								pcall(function()
									coinAccess:Invoke("UpdateAchievement", ownerUserId, "likes_received", result)
								end)
							end
						end)
						
						-- Update leaderboard for everyone
						broadcastLeaderboard()
						else
							LikeResult:FireClient(player, false, result or "Failed to like")
						end
					end)
					
					print("[LikesHandler] Like sign setup for plot " .. i)
				end
			end
		end
	end
end

-- ============================================
-- EVENT HANDLERS
-- ============================================

-- Client requests leaderboard data
RequestLeaderboard.OnServerEvent:Connect(function(player)
	local leaderboard = buildLeaderboard()
	UpdateLeaderboard:FireClient(player, leaderboard)
end)

-- When a player joins, load their cache and broadcast to everyone
Players.PlayerAdded:Connect(function(player)
	-- Pre-load their data into cache
	task.spawn(function()
		getTotalLikes(player.UserId)
		getGivenLikes(player.UserId)
		
		-- Invalidate cache so new player appears, then broadcast to ALL clients
		LeaderboardLastUpdate = 0
		broadcastLeaderboard()
	end)
end)

-- When a player leaves, clear their cache and update everyone
Players.PlayerRemoving:Connect(function(player)
	-- Keep cache for a bit in case they rejoin quickly
	task.delay(300, function()
		if not Players:GetPlayerByUserId(player.UserId) then
			PlayerLikesCache[player.UserId] = nil
		end
	end)
	
	-- Broadcast immediately (player will be gone from Players:GetPlayers())
	LeaderboardLastUpdate = 0
	-- Small delay to ensure player is fully removed from Players list
	task.defer(function()
		broadcastLeaderboard()
	end)
end)

-- ============================================
-- INITIALIZATION
-- ============================================

-- Setup signs after a delay to ensure plots are loaded
task.spawn(function()
	task.wait(3)
	setupLikeSigns()
	
	-- Initial sign text update
	task.wait(1)
	updateAllSigns()
end)

-- Update signs when plot ownership changes
task.spawn(function()
	while true do
		task.wait(10)
		updateAllSigns()
	end
end)

-- Periodic leaderboard updates
task.spawn(function()
	while true do
		task.wait(LEADERBOARD_UPDATE_INTERVAL)
		broadcastLeaderboard()
	end
end)

-- Expose read-only API for other server scripts (e.g. AnalyticsReporter heartbeats)
_G.LikesHandler = {
	GetTotalLikes = getTotalLikes,
	-- Returns up to `limit` entries from the global persistent leaderboard:
	-- { { userId = number, likes = number }, ... }, sorted descending.
	-- Username resolution is left to the caller (slower, often needs cache).
	GetTopLikes = function(limit)
		limit = math.clamp(tonumber(limit) or 10, 1, 100)
		local ok, pages = pcall(function()
			return LikesLeaderboardOrdered:GetSortedAsync(false, limit)
		end)
		if not ok or not pages then return {} end
		local entries = pages:GetCurrentPage()
		local result = {}
		for _, e in ipairs(entries) do
			local uid = tonumber(e.key)
			if uid then
				table.insert(result, { userId = uid, likes = e.value })
			end
		end
		return result
	end,
}

print("[LikesHandler] Initialized")
