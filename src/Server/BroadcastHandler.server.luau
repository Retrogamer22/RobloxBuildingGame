--[[
	BroadcastHandler.server.luau
	Allows the owner to broadcast messages to all players in the server
	
	Commands:
	/broadcast <message> - Send a message to everyone
	/bc <message> - Short version
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BetaConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("BetaConfig"))

-- Create RemoteEvent for broadcasting
local BroadcastEvent = Instance.new("RemoteEvent")
BroadcastEvent.Name = "BroadcastMessage"
BroadcastEvent.Parent = ReplicatedStorage

-- Function to check if player is owner (same logic as ChatMonitor)
local function isOwner(player: Player): boolean
	if player.UserId == game.CreatorId then
		return true
	end
	if BetaConfig.OWNER_USER_ID ~= 0 and player.UserId == BetaConfig.OWNER_USER_ID then
		return true
	end
	return false
end

-- Function to broadcast message to all players
local function broadcastToAll(sender: Player, message: string)
	print("[Broadcast] " .. sender.Name .. ": " .. message)
	
	-- Fire to all clients
	BroadcastEvent:FireAllClients({
		sender = sender.Name,
		message = message,
		timestamp = os.time()
	})
end

-- Listen for chat commands
Players.PlayerAdded:Connect(function(player)
	player.Chatted:Connect(function(message)
		-- Check for broadcast command
		local command, content = message:match("^/(%w+)%s*(.*)")
		
		if command and (command:lower() == "broadcast" or command:lower() == "bc") then
			if not isOwner(player) then
				-- Not owner, ignore silently or you could notify them
				warn("[Broadcast] " .. player.Name .. " tried to broadcast but is not owner")
				return
			end
			
			if content and content ~= "" then
				broadcastToAll(player, content)
			else
				-- No message provided
				warn("[Broadcast] No message provided")
			end
		end
	end)
end)

print("[BroadcastHandler] Initialized")
