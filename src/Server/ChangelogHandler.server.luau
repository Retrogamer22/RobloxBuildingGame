--[[
	ChangelogHandler
	Tracks which changelog version players have seen and notifies them of new ones.
]]

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local ChangelogConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("ChangelogConfig"))

local ChangelogStore = DataStoreService:GetDataStore("PlayerChangelog")

-- Create RemoteEvent for showing changelog
local ShowChangelog = Instance.new("RemoteEvent")
ShowChangelog.Name = "ShowChangelog"
ShowChangelog.Parent = ReplicatedStorage

-- Create RemoteEvent for marking changelog as seen
local ChangelogSeen = Instance.new("RemoteEvent")
ChangelogSeen.Name = "ChangelogSeen"
ChangelogSeen.Parent = ReplicatedStorage

local function getPlayerSeenVersion(player)
	local success, version = pcall(function()
		return ChangelogStore:GetAsync("seen_" .. player.UserId)
	end)
	
	if success then
		return version or 0
	end
	return 0
end

local function setPlayerSeenVersion(player, version)
	local success, err = pcall(function()
		ChangelogStore:SetAsync("seen_" .. player.UserId, version)
	end)
	
	if not success then
		warn("[ChangelogHandler] Failed to save seen version for", player.Name, ":", err)
	end
end

-- When a player joins, check if they need to see the changelog
Players.PlayerAdded:Connect(function(player)
	-- Small delay to let client scripts initialize
	task.wait(3)
	
	local seenVersion = getPlayerSeenVersion(player)
	local currentVersion = ChangelogConfig.VERSION
	
	if seenVersion < currentVersion then
		-- Player hasn't seen this version's changelog
		ShowChangelog:FireClient(player, {
			version = currentVersion,
			versionName = ChangelogConfig.VERSION_NAME,
			title = ChangelogConfig.TITLE,
			subtitle = ChangelogConfig.SUBTITLE,
			changes = ChangelogConfig.CHANGES,
			footer = ChangelogConfig.FOOTER,
			notes = ChangelogConfig.NOTES,
			notesStyle = ChangelogConfig.NOTES_STYLE,
		})
	end
end)

-- When player marks changelog as seen
ChangelogSeen.OnServerEvent:Connect(function(player, version)
	if typeof(version) == "number" and version > 0 then
		setPlayerSeenVersion(player, version)
		-- print("[ChangelogHandler]", player.Name, "marked changelog v" .. version .. " as seen")
	end
end)

-- print("[ChangelogHandler] Initialized - Current version:", ChangelogConfig.VERSION_NAME)
