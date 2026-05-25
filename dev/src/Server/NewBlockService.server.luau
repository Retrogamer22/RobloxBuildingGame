--[[
	NewBlockService.server.luau
	Server script that manages "New" block badge detection
	
	Remotes created:
	- GetNewBlocks (RemoteFunction) — client requests list of new block IDs on join
	- MarkTabSeen (RemoteEvent) — client fires when they view a tab (sends block IDs)
	- NewBlocksAvailable (RemoteEvent) — server → client push for mid-session new blocks
	
	BindableEvent created:
	- NotifyNewBlocks (BindableEvent) — other server scripts fire this to push new blocks
	  Usage: NotifyNewBlocks:Fire(player, { "BlockId1", "BlockId2" })
	  Example: When shop purchase completes, fire with the purchased block IDs
	
	[BB-NEW] log prefix for filtering
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

-- Wait for modules
local Modules = ServerScriptService:WaitForChild("Modules", 10)
local NewBlockTracker = require(Modules:WaitForChild("NewBlockTracker", 10))

local LOG_PREFIX = "[BB-NEW]"

-- ============================================
-- CREATE REMOTES
-- ============================================
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)

local GetNewBlocks = Instance.new("RemoteFunction")
GetNewBlocks.Name = "GetNewBlocks"
GetNewBlocks.Parent = Remotes

local MarkTabSeen = Instance.new("RemoteEvent")
MarkTabSeen.Name = "MarkTabSeen"
MarkTabSeen.Parent = Remotes

-- Server → Client: push new block IDs mid-session (shop purchase, daily reward, etc.)
local NewBlocksAvailable = Instance.new("RemoteEvent")
NewBlocksAvailable.Name = "NewBlocksAvailable"
NewBlocksAvailable.Parent = Remotes

-- Server → Server: other scripts fire this to trigger mid-session "NEW" badges
-- Usage from any server script:
--   local Remotes = ReplicatedStorage:WaitForChild("Remotes")
--   local NotifyNewBlocks = Remotes:WaitForChild("NotifyNewBlocks")
--   NotifyNewBlocks:Fire(player, { "BlockId1", "BlockId2" })
local NotifyNewBlocks = Instance.new("BindableEvent")
NotifyNewBlocks.Name = "NotifyNewBlocks"
NotifyNewBlocks.Parent = Remotes

-- ============================================
-- PLAYER JOIN / LEAVE
-- ============================================
Players.PlayerAdded:Connect(function(player)
	task.spawn(function()
		local success = NewBlockTracker.LoadPlayerData(player.UserId)
		if success then
			local newBlocks = NewBlockTracker.GetNewBlockIds(player.UserId)
			if #newBlocks > 0 then
				print(LOG_PREFIX, player.Name, "has", #newBlocks, "new blocks")
			end
		end
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	NewBlockTracker.CleanupPlayer(player.UserId)
end)

-- ============================================
-- REMOTE HANDLERS
-- ============================================

-- Client requests their new blocks on join
GetNewBlocks.OnServerInvoke = function(player)
	-- Wait for data to load if not ready yet
	local attempts = 0
	while not NewBlockTracker.IsDataLoaded(player.UserId) and attempts < 50 do
		task.wait(0.1)
		attempts += 1
	end
	
	if not NewBlockTracker.IsDataLoaded(player.UserId) then
		warn(LOG_PREFIX, "Data not loaded in time for", player.Name)
		return {}
	end
	
	return NewBlockTracker.GetNewBlockIds(player.UserId)
end

-- Client reports that they viewed a tab (mark those blocks as seen)
MarkTabSeen.OnServerEvent:Connect(function(player, blockIds)
	-- Validate input
	if type(blockIds) ~= "table" then return end
	if #blockIds > 500 then return end -- Sanity check
	
	-- Validate all entries are strings
	local validIds = {}
	for _, id in ipairs(blockIds) do
		if type(id) == "string" and #id > 0 and #id < 100 then
			table.insert(validIds, id)
		end
	end
	
	if #validIds > 0 then
		NewBlockTracker.MarkBlocksSeen(player.UserId, validIds)
	end
end)

-- ============================================
-- MID-SESSION NEW BLOCK PUSH
-- Other server scripts fire NotifyNewBlocks BindableEvent
-- to push "NEW" badges to a player during their session
-- ============================================
NotifyNewBlocks.Event:Connect(function(player, blockIds)
	-- Validate
	if not player or not player:IsA("Player") then
		warn(LOG_PREFIX, "NotifyNewBlocks: invalid player")
		return
	end
	if type(blockIds) ~= "table" or #blockIds == 0 then
		warn(LOG_PREFIX, "NotifyNewBlocks: invalid or empty blockIds")
		return
	end
	if #blockIds > 500 then return end
	
	-- Filter to only valid string IDs
	local validIds = {}
	for _, id in ipairs(blockIds) do
		if type(id) == "string" and #id > 0 and #id < 100 then
			table.insert(validIds, id)
		end
	end
	
	if #validIds == 0 then return end
	
	-- Push to client
	NewBlocksAvailable:FireClient(player, validIds)
	print(LOG_PREFIX, "Pushed", #validIds, "new blocks to", player.Name, "mid-session")
end)

-- ============================================
-- GAME CLOSE (save all)
-- ============================================
game:BindToClose(function()
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(function()
			NewBlockTracker.SavePlayerData(player.UserId)
		end)
	end
	task.wait(3) -- Give saves time to complete
end)

print(LOG_PREFIX, "NewBlockService initialized")
