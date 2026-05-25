--[[
	UpdateChecker
	Polls a DataStore to check for game updates and notifies players when a new version is available.
	
	How to trigger an update notification:
	1. Use the /update chat command in-game (owner only)
	2. Or manually set the "CurrentVersion" key in the "GameVersion" DataStore to a higher number
	
	The server compares its SERVER_VERSION against the DataStore value.
	When the DataStore value is higher, all players get notified.
]]

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Configuration
local SERVER_VERSION = 20  -- INCREMENT THIS EACH TIME YOU PUBLISH A NEW VERSION
local CHECK_INTERVAL = 60 -- Check every 60 seconds
local DATASTORE_NAME = "GameVersion"
local VERSION_KEY = "CurrentVersion"

-- Create RemoteEvent for client notification
local UpdateNotify = Instance.new("RemoteEvent")
UpdateNotify.Name = "UpdateNotify"
UpdateNotify.Parent = ReplicatedStorage

-- Track if we've already notified (don't spam players)
local hasNotified = false

-- DataStore reference
local VersionStore = DataStoreService:GetDataStore(DATASTORE_NAME)

-- Function to check for updates
local function checkForUpdate()
	local success, latestVersion = pcall(function()
		return VersionStore:GetAsync(VERSION_KEY)
	end)
	
	if success and latestVersion then
		if latestVersion > SERVER_VERSION and not hasNotified then
			hasNotified = true
			print("[UpdateChecker] New version detected! Server:", SERVER_VERSION, "Latest:", latestVersion)
			
			-- Notify all connected players
			UpdateNotify:FireAllClients({
				currentVersion = SERVER_VERSION,
				newVersion = latestVersion
			})
		end
	elseif not success then
		warn("[UpdateChecker] Failed to check version:", latestVersion)
	end
end

-- Function to set the new version (called by admin command)
local function setNewVersion(newVersion)
	local success, err = pcall(function()
		VersionStore:SetAsync(VERSION_KEY, newVersion)
	end)
	
	if success then
		print("[UpdateChecker] Version updated to:", newVersion)
		return true
	else
		warn("[UpdateChecker] Failed to set version:", err)
		return false
	end
end

-- Function to get current stored version
local function getCurrentStoredVersion()
	local success, version = pcall(function()
		return VersionStore:GetAsync(VERSION_KEY)
	end)
	
	if success then
		return version or 0
	end
	return nil
end

-- Expose functions for admin commands
local UpdateChecker = {}
UpdateChecker.SetNewVersion = setNewVersion
UpdateChecker.GetCurrentStoredVersion = getCurrentStoredVersion
UpdateChecker.GetServerVersion = function() return SERVER_VERSION end

-- Store module in ServerScriptService for access by admin commands
local modulesFolder = game:GetService("ServerScriptService"):FindFirstChild("Modules")
if not modulesFolder then
	modulesFolder = Instance.new("Folder")
	modulesFolder.Name = "Modules"
	modulesFolder.Parent = game:GetService("ServerScriptService")
end

-- Create a BindableFunction to allow other scripts to trigger updates
local TriggerUpdate = Instance.new("BindableFunction")
TriggerUpdate.Name = "TriggerUpdate"
TriggerUpdate.Parent = ReplicatedStorage

TriggerUpdate.OnInvoke = function(newVersion)
	if typeof(newVersion) == "number" and newVersion > 0 then
		return setNewVersion(newVersion)
	end
	return false
end

-- Create a BindableFunction to get version info
local GetVersionInfo = Instance.new("BindableFunction")
GetVersionInfo.Name = "GetVersionInfo"
GetVersionInfo.Parent = ReplicatedStorage

GetVersionInfo.OnInvoke = function()
	return {
		serverVersion = SERVER_VERSION,
		storedVersion = getCurrentStoredVersion()
	}
end

-- Start the polling loop
task.spawn(function()
	-- Initial delay to let the game settle
	task.wait(5)
	
	print("[UpdateChecker] Started - Server Version:", SERVER_VERSION)
	print("[UpdateChecker] Checking for updates every", CHECK_INTERVAL, "seconds")
	
	while true do
		checkForUpdate()
		task.wait(CHECK_INTERVAL)
	end
end)

-- Also check immediately when a new player joins (so they see the notification if one is pending)
Players.PlayerAdded:Connect(function(player)
	if hasNotified then
		-- Small delay to let client scripts initialize
		task.wait(2)
		UpdateNotify:FireClient(player, {
			currentVersion = SERVER_VERSION,
			newVersion = getCurrentStoredVersion() or SERVER_VERSION + 1
		})
	end
end)