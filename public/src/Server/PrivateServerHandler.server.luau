--[[
	PrivateServerHandler
	Initializes private server features and handles remote events
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Wait for modules
local PrivateServerManager = nil
do
	local modulesFolder = script.Parent:WaitForChild("Modules", 10)
	if modulesFolder then
		local psModule = modulesFolder:WaitForChild("PrivateServerManager", 10)
		if psModule then
			PrivateServerManager = require(psModule)
		end
	end
end

if not PrivateServerManager then
	warn("[PrivateServerHandler] Failed to load PrivateServerManager!")
	return
end

-- Initialize the manager
PrivateServerManager.Initialize()

-- Wait for Remotes folder (created by PlotManager)
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
if not Remotes then
	Remotes = Instance.new("Folder")
	Remotes.Name = "Remotes"
	Remotes.Parent = ReplicatedStorage
end

-- ============================================
-- CREATE REMOTES
-- ============================================

local GetPrivateServerInfo = Instance.new("RemoteFunction")
GetPrivateServerInfo.Name = "GetPrivateServerInfo"
GetPrivateServerInfo.Parent = Remotes

local SetPrivateServerMode = Instance.new("RemoteFunction")
SetPrivateServerMode.Name = "SetPrivateServerMode"
SetPrivateServerMode.Parent = Remotes

local PrivateServerModeChanged = Instance.new("RemoteEvent")
PrivateServerModeChanged.Name = "PrivateServerModeChanged"
PrivateServerModeChanged.Parent = Remotes

local CompletePrivateServerSetup = Instance.new("RemoteEvent")
CompletePrivateServerSetup.Name = "CompletePrivateServerSetup"
CompletePrivateServerSetup.Parent = Remotes

-- ============================================
-- REMOTE HANDLERS
-- ============================================

GetPrivateServerInfo.OnServerInvoke = function(player)
	return {
		isPrivateServer = PrivateServerManager.IsPrivateServer(),
		ownerId = PrivateServerManager.GetOwnerId(),
		mode = PrivateServerManager.GetMode(),
		isOwner = PrivateServerManager.IsOwner(player),
		canChangeSettings = PrivateServerManager.CanChangeSettings(player),
	}
end

SetPrivateServerMode.OnServerInvoke = function(player, newMode, confirmationText)
	-- Only owner can change mode
	if not PrivateServerManager.CanChangeSettings(player) then
		return false, "Only the server owner can change modes"
	end
	
	-- Require confirmation text for safety
	if confirmationText ~= "RESET" then
		return false, "Please type RESET to confirm mode change"
	end
	
	local success, err = PrivateServerManager.SetMode(newMode, player)
	
	if success then
		-- Notify all clients of mode change
		PrivateServerModeChanged:FireAllClients(newMode)
		
		-- TODO: In Phase 3, this will trigger terrain regeneration
		print("[PrivateServerHandler] Mode changed to", newMode, "by", player.Name)
	end
	
	return success, err
end

-- ============================================
-- SETUP COMPLETION (Individual mode auto-complete)
-- ============================================

CompletePrivateServerSetup.OnServerEvent:Connect(function(player)
	if not PrivateServerManager.IsOwner(player) then
		warn("[PrivateServerHandler] Non-owner tried to complete setup:", player.Name)
		return
	end
	
	if PrivateServerManager.IsFirstTimeSetup() then
		PrivateServerManager.MarkSetupComplete()
		print("[PrivateServerHandler] Setup auto-completed by", player.Name, "(Individual mode)")
	end
end)

-- ============================================
-- PLAYER CONNECTION LOGGING
-- ============================================

if PrivateServerManager.IsPrivateServer() then
	Players.PlayerAdded:Connect(function(player)
		local isOwner = PrivateServerManager.IsOwner(player)
		print("[PrivateServerHandler]", player.Name, "joined private server", isOwner and "(OWNER)" or "")
	end)
end

print("[PrivateServerHandler] Initialized -", 
	PrivateServerManager.IsPrivateServer() 
		and ("Private Server, Mode: " .. PrivateServerManager.GetMode())
		or "Public Server"
)
