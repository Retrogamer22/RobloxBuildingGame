--[[
	AdminCommandHandler
	Receives commands from the external admin panel via Roblox Open Cloud
	MessagingService API (Cloudflare Worker -> AdminCommands topic).
	
	Message format from Worker (JSON-stringified):
	{
	  "command": "ping" | "softupdate" | "urgentupdate" | "broadcast" | "kick" | "ban" | "giveset" | "givesetall",
	  "payload": { ... },
	  "timestamp": <ms>
	}
	
	IMPORTANT: Open Cloud publishes arrive as JSON STRINGS in message.Data,
	unlike in-engine PublishAsync which sends Lua tables. This handler decodes
	the string before dispatching.
]]

local MessagingService = game:GetService("MessagingService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local TOPIC = "AdminCommands"
local SHUTDOWN_TOPIC = "UrgentGameShutdown"   -- mirrors BetaAdminCommands.server.luau

local LOG = "[BB-ADMIN]"
local jobId = (game.JobId ~= "" and game.JobId:sub(1, 8)) or "studio"

-- Lazy CoinManager require (used by giveset / givesetall). Lazy so we don't
-- block this script's startup if ServerScriptService.Modules isn't ready yet.
local CoinManager = nil
task.spawn(function()
	local modulesFolder = ServerScriptService:WaitForChild("Modules", 10)
	if modulesFolder then
		local coinModule = modulesFolder:WaitForChild("CoinManager", 10)
		if coinModule then
			CoinManager = require(coinModule)
		end
	end
end)

----------------------------------------------------------------
-- Style presets for the shutdown UI
----------------------------------------------------------------

-- Soft update: blue/teal, less alarming title, no pulse
local SOFT_UPDATE_STYLE = {
	title = "UPDATE PUSHED",
	countdownLabel = "RESTART IN",
	accent = {64, 156, 220},      -- BuildBlox sky blue
	accentDark = {38, 100, 150},
	pulse = false,
}

----------------------------------------------------------------
-- Command dispatch table
----------------------------------------------------------------

local commands = {}

-- ping: prints a line to server console. Use for verifying the pipe works.
commands.ping = function(payload)
	local text = (payload and payload.text) or "(no text)"
	print(string.format("%s ping received | server=%s | text=%s",
		LOG, jobId, tostring(text)))
end

-- urgentupdate: red, dramatic. Re-publishes to UrgentGameShutdown (no style).
-- Every server receives, republishes once, BetaAdminCommands.isShuttingDown guard dedupes.
commands.urgentupdate = function(payload)
	local reason = (payload and payload.reason) or "A critical update is being deployed."
	local initiatedBy = (payload and payload.initiatedBy) or "AdminPanel"
	
	print(string.format("%s urgentupdate received | server=%s | forwarding to %s",
		LOG, jobId, SHUTDOWN_TOPIC))
	
	local ok, err = pcall(function()
		MessagingService:PublishAsync(SHUTDOWN_TOPIC, {
			reason = reason,
			initiatedBy = initiatedBy,
		})
	end)
	
	if not ok then
		warn(string.format("%s failed to forward urgentupdate: %s", LOG, tostring(err)))
	end
end

-- softupdate: blue, friendly. Same shutdown flow but with soft style overrides.
commands.softupdate = function(payload)
	local reason = (payload and payload.reason) or "An update has been pushed. The server will restart shortly."
	local initiatedBy = (payload and payload.initiatedBy) or "AdminPanel"
	
	print(string.format("%s softupdate received | server=%s | forwarding to %s",
		LOG, jobId, SHUTDOWN_TOPIC))
	
	local ok, err = pcall(function()
		MessagingService:PublishAsync(SHUTDOWN_TOPIC, {
			reason = reason,
			initiatedBy = initiatedBy,
			style = SOFT_UPDATE_STYLE,
		})
	end)
	
	if not ok then
		warn(string.format("%s failed to forward softupdate: %s", LOG, tostring(err)))
	end
end

-- broadcast: fires the existing BroadcastMessage event to all clients on this server.
-- Every server receives the AdminCommands message and fires its local event independently.
commands.broadcast = function(payload)
	local message = payload and payload.message
	if type(message) ~= "string" or message == "" then
		warn(string.format("%s broadcast missing 'message' field", LOG))
		return
	end
	
	local sender = (payload and payload.sender) or "AdminPanel"
	
	local broadcastEvent = ReplicatedStorage:FindFirstChild("BroadcastMessage")
	if not broadcastEvent then
		warn(string.format("%s BroadcastMessage RemoteEvent not found", LOG))
		return
	end
	
	print(string.format("%s broadcast | server=%s | sender=%s | message=%s",
		LOG, jobId, sender, message))
	
	broadcastEvent:FireAllClients({
		sender = sender,
		message = message,
		timestamp = os.time(),
	})
end

-- kick: looks for the target player on THIS server. If present, kicks them.
-- Other servers will log "not on this server" and do nothing.
-- Payload: { username = "..." or userId = 123, reason = "..." }
commands.kick = function(payload)
	if type(payload) ~= "table" then
		warn(string.format("%s kick missing payload", LOG))
		return
	end
	
	local username = payload.username
	local userId = payload.userId
	local reason = payload.reason or "You have been kicked by an administrator."
	
	-- Find the target player on this server
	local target = nil
	for _, p in ipairs(Players:GetPlayers()) do
		if username and string.lower(p.Name) == string.lower(username) then
			target = p
			break
		elseif userId and p.UserId == userId then
			target = p
			break
		end
	end
	
	if target then
		print(string.format("%s kick | server=%s | target=%s (UserId=%d) | reason=%s",
			LOG, jobId, target.Name, target.UserId, reason))
		target:Kick(reason)
	else
		print(string.format("%s kick | server=%s | target not on this server (username=%s, userId=%s)",
			LOG, jobId, tostring(username), tostring(userId)))
	end
end

-- ban: uses Players:BanAsync — Roblox enforces globally across all servers,
-- so we call it once per server but Roblox dedupes. Requires Players.BanningEnabled
-- to be ON in Game Settings (Studio: Game Settings -> Security -> "Ban Service Allowed").
-- Payload: { username = "..." or userId = 123, reason = "...", duration = seconds (-1 = perma) }
commands.ban = function(payload)
	if type(payload) ~= "table" then
		warn(string.format("%s ban missing payload", LOG))
		return
	end
	
	local username = payload.username
	local userId = payload.userId
	local displayReason = payload.reason or "Banned by an administrator."
	local privateReason = payload.privateReason or displayReason
	local duration = payload.duration or -1  -- -1 = permanent
	local excludeAlts = payload.excludeAltAccounts
	if excludeAlts == nil then excludeAlts = false end
	
	-- Resolve username -> UserId if needed
	if not userId and username then
		local ok, resolvedId = pcall(function()
			return Players:GetUserIdFromNameAsync(username)
		end)
		if ok and resolvedId then
			userId = resolvedId
		else
			warn(string.format("%s ban | server=%s | failed to resolve username '%s'",
				LOG, jobId, tostring(username)))
			return
		end
	end
	
	if not userId then
		warn(string.format("%s ban missing username or userId", LOG))
		return
	end
	
	-- Safety: don't ban the game creator
	if userId == game.CreatorId then
		warn(string.format("%s ban refused | server=%s | refusing to ban game creator (UserId=%d)",
			LOG, jobId, userId))
		return
	end
	
	print(string.format("%s ban | server=%s | userId=%d | duration=%s | reason=%s",
		LOG, jobId, userId, tostring(duration), displayReason))
	
	local ok, err = pcall(function()
		Players:BanAsync({
			UserIds = { userId },
			ApplyToUniverse = true,
			Duration = duration,
			DisplayReason = displayReason,
			PrivateReason = privateReason,
			ExcludeAltAccounts = excludeAlts,
		})
	end)
	
	if not ok then
		warn(string.format("%s ban failed: %s", LOG, tostring(err)))
	else
		print(string.format("%s ban applied | userId=%d", LOG, userId))
	end
end

-- giveset: grant one or more reward sets to a specific user. The Worker broadcasts
-- to every server; only the server holding the target's PlayerData will actually
-- grant (CoinManager.GrantRewardSet returns false otherwise). All other servers
-- silently no-op so we don't spam warnings for the expected case.
-- Payload: { userId = 123, setNames = { "RainbowBlocks", ... }, initiatedBy = "..." }
commands.giveset = function(payload)
	if type(payload) ~= "table" then
		warn(string.format("%s giveset missing payload", LOG))
		return
	end
	local userId = payload.userId
	local setNames = payload.setNames
	local initiatedBy = payload.initiatedBy or "AdminPanel"
	
	if type(userId) ~= "number" then
		warn(string.format("%s giveset: invalid or missing userId", LOG))
		return
	end
	if type(setNames) ~= "table" or #setNames == 0 then
		warn(string.format("%s giveset: setNames must be a non-empty array", LOG))
		return
	end
	
	-- Only the server that has this player processes the gift.
	local target = Players:GetPlayerByUserId(userId)
	if not target then
		return
	end
	
	if not CoinManager then
		warn(string.format("%s giveset: CoinManager not loaded yet on server=%s", LOG, jobId))
		return
	end
	
	print(string.format("%s giveset | server=%s | target=%s (userId=%d) | sets=[%s] | by=%s",
		LOG, jobId, target.Name, userId, table.concat(setNames, ", "), initiatedBy))
	
	for _, setName in ipairs(setNames) do
		if type(setName) == "string" and setName ~= "" then
			local ok, msg = CoinManager.GrantRewardSet(userId, setName)
			if ok then
				print(string.format("%s   - %s: %s", LOG, setName, msg))
			else
				warn(string.format("%s   - %s FAILED: %s", LOG, setName, tostring(msg)))
			end
		end
	end
end

-- givesetall: grant one or more reward sets to EVERY player currently on this
-- server. Each server iterates its own player list, so collectively the
-- broadcast covers every online player across the experience.
-- Payload: { setNames = { "RainbowBlocks", ... }, initiatedBy = "..." }
commands.givesetall = function(payload)
	if type(payload) ~= "table" then
		warn(string.format("%s givesetall missing payload", LOG))
		return
	end
	local setNames = payload.setNames
	local initiatedBy = payload.initiatedBy or "AdminPanel"
	
	if type(setNames) ~= "table" or #setNames == 0 then
		warn(string.format("%s givesetall: setNames must be a non-empty array", LOG))
		return
	end
	
	if not CoinManager then
		warn(string.format("%s givesetall: CoinManager not loaded yet on server=%s", LOG, jobId))
		return
	end
	
	local targets = Players:GetPlayers()
	print(string.format("%s givesetall | server=%s | targets=%d | sets=[%s] | by=%s",
		LOG, jobId, #targets, table.concat(setNames, ", "), initiatedBy))
	
	for _, p in ipairs(targets) do
		for _, setName in ipairs(setNames) do
			if type(setName) == "string" and setName ~= "" then
				local ok, msg = CoinManager.GrantRewardSet(p.UserId, setName)
				if ok then
					print(string.format("%s   - %s/%s: %s", LOG, p.Name, setName, msg))
				else
					print(string.format("%s   - %s/%s FAILED: %s", LOG, p.Name, setName, tostring(msg)))
				end
			end
		end
	end
end

----------------------------------------------------------------
-- Subscriber
----------------------------------------------------------------

local function handleMessage(message)
	local rawData = message.Data
	
	-- Open Cloud sends strings, in-engine sends tables. Decode if needed.
	local decoded
	if type(rawData) == "string" then
		local ok, result = pcall(function()
			return HttpService:JSONDecode(rawData)
		end)
		if not ok then
			warn(string.format("%s failed to JSON-decode message: %s", LOG, tostring(result)))
			return
		end
		decoded = result
	elseif type(rawData) == "table" then
		decoded = rawData
	else
		warn(string.format("%s unexpected message.Data type: %s", LOG, typeof(rawData)))
		return
	end
	
	if type(decoded) ~= "table" then
		warn(string.format("%s decoded message is not a table", LOG))
		return
	end
	
	local command = decoded.command
	local payload = decoded.payload
	
	if type(command) ~= "string" then
		warn(string.format("%s message missing 'command' field", LOG))
		return
	end
	
	local handler = commands[command]
	if not handler then
		warn(string.format("%s unknown command: %s", LOG, command))
		return
	end
	
	print(string.format("%s dispatching '%s' on server %s", LOG, command, jobId))
	local handlerOk, handlerErr = pcall(handler, payload)
	if not handlerOk then
		warn(string.format("%s command '%s' failed: %s", LOG, command, tostring(handlerErr)))
	end
end

local subOk, subErr = pcall(function()
	MessagingService:SubscribeAsync(TOPIC, handleMessage)
end)

if subOk then
	print(string.format("%s Subscribed to '%s' on server %s", LOG, TOPIC, jobId))
else
	warn(string.format("%s Failed to subscribe to '%s': %s", LOG, TOPIC, tostring(subErr)))
end

local cmdNames = {}
for name in pairs(commands) do
	table.insert(cmdNames, name)
end
table.sort(cmdNames)
print(string.format("%s AdminCommandHandler initialized | commands: %s",
	LOG, table.concat(cmdNames, ", ")))
