--[[
	ChatMonitor
	Forwards chat messages to the game owner for observation purposes.
	One-way only - owner can see but not respond through this system.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local BetaConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("BetaConfig"))

-- Create remote for forwarding messages to owner
local ChatMonitorRemote = Instance.new("RemoteEvent")
ChatMonitorRemote.Name = "ChatMonitorRemote"
ChatMonitorRemote.Parent = ReplicatedStorage

-- Track the owner player
local ownerPlayer = nil

local function isOwner(player)
	if player.UserId == game.CreatorId then
		return true
	end
	if BetaConfig.OWNER_USER_ID ~= 0 and player.UserId == BetaConfig.OWNER_USER_ID then
		return true
	end
	return false
end

-- Find owner when they join
local function onPlayerAdded(player)
	if isOwner(player) then
		ownerPlayer = player
		print("[ChatMonitor] Owner joined - chat monitoring active")
	end
end

local function onPlayerRemoving(player)
	if player == ownerPlayer then
		ownerPlayer = nil
		print("[ChatMonitor] Owner left - chat monitoring paused")
	end
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

-- Check existing players
for _, player in ipairs(Players:GetPlayers()) do
	onPlayerAdded(player)
end

-- Hook into TextChatService (new chat system)
local function setupTextChatHook()
	local textChannels = TextChatService:WaitForChild("TextChannels", 10)
	if not textChannels then
		warn("[ChatMonitor] TextChannels not found")
		return
	end
	
	-- Wait for the general channel
	local generalChannel = textChannels:WaitForChild("RBXGeneral", 10)
	if not generalChannel then
		warn("[ChatMonitor] RBXGeneral channel not found")
		return
	end
	
	-- Listen to messages on the general channel
	generalChannel.MessageReceived:Connect(function(textChatMessage)
		if not ownerPlayer then return end
		
		local sender = textChatMessage.TextSource
		if not sender then return end
		
		local senderPlayer = Players:GetPlayerByUserId(sender.UserId)
		if not senderPlayer then return end
		
		-- Don't show owner's own messages back to them
		if senderPlayer == ownerPlayer then return end
		
		-- Forward to owner
		ChatMonitorRemote:FireClient(ownerPlayer, {
			username = senderPlayer.Name,
			displayName = senderPlayer.DisplayName,
			message = textChatMessage.Text,
			timestamp = os.time(),
			userId = senderPlayer.UserId,
		})
	end)
	
	print("[ChatMonitor] Hooked into TextChatService")
end

-- Try to set up the hook
task.spawn(function()
	-- Wait a moment for chat to initialize
	task.wait(3)
	setupTextChatHook()
end)

-- Also try legacy chat system as fallback
local function setupLegacyChatHook()
	local Chat = game:GetService("Chat")
	
	Players.PlayerAdded:Connect(function(player)
		player.Chatted:Connect(function(message)
			if not ownerPlayer then return end
			if player == ownerPlayer then return end
			
			-- Forward to owner
			ChatMonitorRemote:FireClient(ownerPlayer, {
				username = player.Name,
				displayName = player.DisplayName,
				message = message,
				timestamp = os.time(),
				userId = player.UserId,
			})
		end)
	end)
	
	-- Hook existing players
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= ownerPlayer then
			player.Chatted:Connect(function(message)
				if not ownerPlayer then return end
				
				ChatMonitorRemote:FireClient(ownerPlayer, {
					username = player.Name,
					displayName = player.DisplayName,
					message = message,
					timestamp = os.time(),
					userId = player.UserId,
				})
			end)
		end
	end
	
	print("[ChatMonitor] Hooked into legacy Chat system")
end

-- Set up legacy hook as backup
task.spawn(function()
	task.wait(2)
	setupLegacyChatHook()
end)

print("[ChatMonitor] Initialized")
