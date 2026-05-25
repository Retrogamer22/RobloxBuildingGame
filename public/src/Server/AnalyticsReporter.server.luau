--[[
	AnalyticsReporter
	
	Posts join/leave events and periodic heartbeats with the current player
	list to the BuildBlox Cloudflare Worker.
	
	Events posted:
	- join: when a player connects (fire-and-forget, response carries isNew)
	- leave: when a player disconnects (fire-and-forget)
	- heartbeat: every HEARTBEAT_INTERVAL with current connected players
	
	IMPORTANT: HttpService:RequestAsync must be enabled in Game Settings ->
	Security -> "Allow HTTP Requests". Without this, all calls below silently
	fail (we pcall everything to avoid breaking gameplay).
	
	Log prefix: [BB-ANALYTICS] — filter Studio output to see only analytics events.
]]

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local AnalyticsConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("AnalyticsConfig"))

-- AnalyticsManager lives in Server/Modules/. It tracks total playtime per
-- player (cumulative across sessions). We require it lazily so we don't
-- block on its load order.
local AnalyticsManager = nil
local CoinManager = nil
task.spawn(function()
	local modulesFolder = ServerScriptService:WaitForChild("Modules", 10)
	if modulesFolder then
		local mod = modulesFolder:WaitForChild("AnalyticsManager", 10)
		if mod then
			local ok, result = pcall(require, mod)
			if ok then
				AnalyticsManager = result
			end
		end
		local coinMod = modulesFolder:WaitForChild("CoinManager", 10)
		if coinMod then
			local ok, result = pcall(require, coinMod)
			if ok then
				CoinManager = result
			end
		end
	end
end)

local LOG = "[BB-ANALYTICS]"
local HEARTBEAT_INTERVAL = 30  -- seconds
local TOP_BLOCKS_INTERVAL = 300 -- seconds (5 min; data changes slowly)
local LEADERBOARDS_INTERVAL = 300 -- seconds (5 min; leaderboards are stable)

-- Detect prod vs dev from game.GameId, with config fallback
local function resolveTarget()
	local target = AnalyticsConfig.UniverseTargets[game.GameId]
	if target then return target end
	return AnalyticsConfig.DefaultTarget
end

local TARGET = resolveTarget()
local SERVER_ID = game.JobId ~= "" and game.JobId or "studio-" .. tostring(os.time())
local SERVER_START_TIME = os.time()

print(string.format("%s Initialized | target=%s | serverId=%s", LOG, TARGET, SERVER_ID:sub(1, 8)))

-- Tracks isNew status for each player (returned by /events on join)
local PlayerIsNew = {}

----------------------------------------------------------------
-- HTTP helpers
----------------------------------------------------------------

local function postJson(path, body)
	local url = AnalyticsConfig.WorkerUrl .. path
	local payload
	local encodeOk, encodeErr = pcall(function()
		payload = HttpService:JSONEncode(body)
	end)
	if not encodeOk then
		warn(string.format("%s JSON encode failed: %s", LOG, tostring(encodeErr)))
		return false, "encode failed"
	end
	
	local requestOk, response = pcall(function()
		return HttpService:RequestAsync({
			Url = url,
			Method = "POST",
			Headers = {
				["Content-Type"] = "application/json",
				["X-Ingest-Token"] = AnalyticsConfig.IngestToken,
			},
			Body = payload,
		})
	end)
	
	if not requestOk then
		warn(string.format("%s POST %s failed: %s", LOG, path, tostring(response)))
		return false, tostring(response)
	end
	
	if not response.Success then
		warn(string.format("%s POST %s -> HTTP %d: %s",
			LOG, path, response.StatusCode, tostring(response.Body):sub(1, 200)))
		return false, response.StatusCode
	end
	
	if AnalyticsConfig.Debug then
		print(string.format("%s POST %s OK (%d) %s",
			LOG, path, response.StatusCode, tostring(response.Body):sub(1, 100)))
	end
	
	return true, response.Body
end

----------------------------------------------------------------
-- Event posting
----------------------------------------------------------------

local function postJoin(player)
	local userId = player.UserId
	local username = player.Name
	PlayerIsNew[userId] = false  -- default until response says otherwise
	
	task.spawn(function()
		local ok, responseBody = postJson("/events", {
			type = "join",
			userId = userId,
			username = username,
			serverId = SERVER_ID,
			target = TARGET,
			timestamp = os.time(),
		})
		
		if ok and responseBody then
			local decodeOk, decoded = pcall(function()
				return HttpService:JSONDecode(responseBody)
			end)
			if decodeOk and decoded and decoded.isNew ~= nil then
				PlayerIsNew[userId] = decoded.isNew
				print(string.format("%s Join: %s (UserId=%d) | isNew=%s",
					LOG, username, userId, tostring(decoded.isNew)))
				return
			end
		end
		print(string.format("%s Join: %s (UserId=%d) | isNew=unknown", LOG, username, userId))
	end)
end

local function postLeave(player)
	local userId = player.UserId
	local username = player.Name
	PlayerIsNew[userId] = nil
	
	task.spawn(function()
		postJson("/events", {
			type = "leave",
			userId = userId,
			username = username,
			serverId = SERVER_ID,
			target = TARGET,
			timestamp = os.time(),
		})
		print(string.format("%s Leave: %s (UserId=%d)", LOG, username, userId))
	end)
end

----------------------------------------------------------------
-- Heartbeat loop
----------------------------------------------------------------

local function sendHeartbeat(excludeUserId)
	local players = {}
	for _, p in ipairs(Players:GetPlayers()) do
		local userId = p.UserId
		-- During a PlayerRemoving event, the leaving player is still in
		-- Players:GetPlayers() momentarily. Skip them so the heartbeat
		-- reflects post-leave state.
		if excludeUserId and userId == excludeUserId then
			continue
		end
		
		-- Total likes received (via _G.LikesHandler exposed by LikesHandler.server.luau).
		-- This is cached server-side, so it's a cheap lookup.
		local totalLikes = 0
		if _G.LikesHandler and _G.LikesHandler.GetTotalLikes then
			local ok, result = pcall(_G.LikesHandler.GetTotalLikes, userId)
			if ok and type(result) == "number" then
				totalLikes = result
			end
		end
		
		-- Total playtime in seconds (cumulative including current session).
		local totalPlaytime = 0
		if AnalyticsManager and AnalyticsManager.GetPlayerStats then
			local ok, stats = pcall(AnalyticsManager.GetPlayerStats, p)
			if ok and stats and type(stats.totalPlaytime) == "number" then
				totalPlaytime = stats.totalPlaytime
			end
		end
		
		-- BloxCoin balance (current live balance from in-memory PlayerData).
		local coins = 0
		local streak = 0
		if CoinManager then
			if CoinManager.GetCoins then
				local ok, result = pcall(CoinManager.GetCoins, userId)
				if ok and type(result) == "number" then
					coins = result
				end
			end
			-- Streak (current daily reward streak; 0 if not yet claimed today)
			if CoinManager.GetDailyRewardStatus then
				local ok, status = pcall(CoinManager.GetDailyRewardStatus, userId)
				if ok and type(status) == "table" and type(status.streak) == "number" then
					streak = status.streak
				end
			end
		end
		
		table.insert(players, {
			userId = userId,
			username = p.Name,
			isNew = PlayerIsNew[userId] == true,
			playTime = totalPlaytime,
			likes = totalLikes,
			coins = coins,
			streak = streak,
		})
	end
	
	local body = {
		serverId = SERVER_ID,
		target = TARGET,
		uptimeSeconds = os.time() - SERVER_START_TIME,
		players = players,
	}
	
	task.spawn(function()
		local ok = postJson("/heartbeat", body)
		if ok and AnalyticsConfig.Debug then
			print(string.format("%s Heartbeat sent | %d players%s",
				LOG, #players, excludeUserId and " (excluding leaver)" or ""))
		end
	end)
end

-- Send an initial heartbeat ~3s after script start (let things settle), then
-- continue every HEARTBEAT_INTERVAL seconds.
task.spawn(function()
	task.wait(3)
	while true do
		sendHeartbeat()
		task.wait(HEARTBEAT_INTERVAL)
	end
end)

----------------------------------------------------------------
-- Top blocks reporter
----------------------------------------------------------------
--
-- AnalyticsManager.GetTopBlocks(10) returns the top 10 globally-placed blocks
-- from this server's loaded DataStore. Since DataStore is shared across all
-- BuildBlox servers in this universe, every server returns the same data
-- modulo last-saved time. We POST every 5 minutes; the Worker upserts into
-- top_blocks and last write wins.
local function sendTopBlocks()
	if not AnalyticsManager then
		print(string.format("%s top_blocks SKIPPED: AnalyticsManager module is nil (require failed)", LOG))
		return
	end
	if not AnalyticsManager.GetTopBlocks then
		print(string.format("%s top_blocks SKIPPED: GetTopBlocks function not found", LOG))
		return
	end
	
	local ok, top = pcall(AnalyticsManager.GetTopBlocks, 10)
	if not ok then
		warn(string.format("%s top_blocks GetTopBlocks errored: %s", LOG, tostring(top)))
		return
	end
	if type(top) ~= "table" then
		print(string.format("%s top_blocks SKIPPED: GetTopBlocks returned %s, not table", LOG, typeof(top)))
		return
	end
	if #top == 0 then
		print(string.format("%s top_blocks SKIPPED: globalBlockStats is empty (no placements tracked yet on this server)", LOG))
		return
	end
	
	-- Normalize to the wire shape the Worker expects
	local blocks = {}
	for _, entry in ipairs(top) do
		table.insert(blocks, { name = entry.name, count = entry.count })
	end
	
	task.spawn(function()
		local sent = postJson("/blocks/top", {
			serverId = SERVER_ID,
			target = TARGET,
			blocks = blocks,
			timestamp = os.time(),
		})
		if sent and AnalyticsConfig.Debug then
			print(string.format("%s top_blocks sent | %d entries", LOG, #blocks))
		end
	end)
end

-- Send top blocks ~30s after start (give AnalyticsManager time to LoadGlobalStats),
-- then every TOP_BLOCKS_INTERVAL.
task.spawn(function()
	task.wait(30)
	while true do
		sendTopBlocks()
		task.wait(TOP_BLOCKS_INTERVAL)
	end
end)

----------------------------------------------------------------
-- Persistent leaderboards (offline-inclusive)
----------------------------------------------------------------
--
-- Posts the top 10 globally-ranked players by streak, likes, and playtime to
-- the Worker. Uses OrderedDataStores under the hood so offline players are
-- included. Username resolution is done here (one GetNameFromUserIdAsync per
-- new userId) and cached in-process.

local usernameCache = {}

local function resolveUsername(userId)
	if usernameCache[userId] then return usernameCache[userId] end
	-- Check online players first (free + most up to date)
	for _, p in ipairs(Players:GetPlayers()) do
		if p.UserId == userId then
			usernameCache[userId] = p.Name
			return p.Name
		end
	end
	local ok, name = pcall(Players.GetNameFromUserIdAsync, Players, userId)
	if ok and name then
		usernameCache[userId] = name
		return name
	end
	return "User" .. tostring(userId)
end

local CoinManagerModule = nil  -- captured below

local function sendLeaderboards()
	local streakEntries = {}
	local likesEntries = {}
	local playtimeEntries = {}
	
	-- Streak leaderboard (from CoinManager OrderedDataStore)
	if CoinManager and CoinManager.GetTopStreaks then
		local ok, list = pcall(CoinManager.GetTopStreaks, 10)
		if ok and type(list) == "table" then
			for _, entry in ipairs(list) do
				table.insert(streakEntries, {
					userId = entry.userId,
					username = resolveUsername(entry.userId),
					value = entry.streak,
				})
			end
		end
	end
	
	-- Likes leaderboard (from LikesHandler OrderedDataStore via _G)
	if _G.LikesHandler and _G.LikesHandler.GetTopLikes then
		local ok, list = pcall(_G.LikesHandler.GetTopLikes, 10)
		if ok and type(list) == "table" then
			for _, entry in ipairs(list) do
				table.insert(likesEntries, {
					userId = entry.userId,
					username = resolveUsername(entry.userId),
					value = entry.likes,
				})
			end
		end
	end
	
	-- Playtime leaderboard (from AnalyticsManager's existing PlaytimeLeaderboard)
	if AnalyticsManager and AnalyticsManager.GetTopPlaytime then
		local ok, list = pcall(AnalyticsManager.GetTopPlaytime, 10)
		if ok and type(list) == "table" then
			for _, entry in ipairs(list) do
				-- AnalyticsManager returns { userId, username, playtime, ... }
				table.insert(playtimeEntries, {
					userId = entry.userId,
					username = entry.username or resolveUsername(entry.userId),
					value = entry.playtime,
				})
			end
		end
	end
	
	-- Skip POST entirely if all three are empty
	if #streakEntries == 0 and #likesEntries == 0 and #playtimeEntries == 0 then
		if AnalyticsConfig.Debug then
			print(string.format("%s leaderboards: no data yet", LOG))
		end
		return
	end
	
	task.spawn(function()
		local sent = postJson("/leaderboards", {
			serverId = SERVER_ID,
			target = TARGET,
			timestamp = os.time(),
			streak = streakEntries,
			likes = likesEntries,
			playtime = playtimeEntries,
		})
		if sent and AnalyticsConfig.Debug then
			print(string.format("%s leaderboards sent | streak=%d likes=%d playtime=%d",
				LOG, #streakEntries, #likesEntries, #playtimeEntries))
		end
	end)
end

-- Send leaderboards ~45s after start (after CoinManager/LikesHandler load),
-- then every LEADERBOARDS_INTERVAL.
task.spawn(function()
	task.wait(45)
	while true do
		sendLeaderboards()
		task.wait(LEADERBOARDS_INTERVAL)
	end
end)

----------------------------------------------------------------
-- Hook player lifecycle
----------------------------------------------------------------

Players.PlayerAdded:Connect(function(player)
	postJoin(player)
	-- Immediate heartbeat once the join's /events response has had a moment to
	-- resolve isNew. 1.5s is generous; even slow networks should be back by then.
	task.delay(1.5, sendHeartbeat)
end)

Players.PlayerRemoving:Connect(function(player)
	postLeave(player)
	-- Immediate heartbeat that explicitly excludes the leaving player (they're
	-- still in Players:GetPlayers() at this point in the event).
	sendHeartbeat(player.UserId)
end)

-- Handle players already connected when this script starts (e.g. Studio test runs)
for _, p in ipairs(Players:GetPlayers()) do
	postJoin(p)
end

print(string.format("%s Ready | heartbeat every %ds", LOG, HEARTBEAT_INTERVAL))
