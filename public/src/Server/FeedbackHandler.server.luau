--[[
	FeedbackHandler
	Stores player feedback and allows the owner to view it.
]]

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TextService = game:GetService("TextService")

local BetaConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("BetaConfig"))

local FeedbackStore = DataStoreService:GetDataStore("PlayerFeedback")

-- Create RemoteEvents
local SubmitFeedback = Instance.new("RemoteEvent")
SubmitFeedback.Name = "SubmitFeedback"
SubmitFeedback.Parent = ReplicatedStorage

local FeedbackResult = Instance.new("RemoteEvent")
FeedbackResult.Name = "FeedbackResult"
FeedbackResult.Parent = ReplicatedStorage

local RequestFeedbackList = Instance.new("RemoteFunction")
RequestFeedbackList.Name = "RequestFeedbackList"
RequestFeedbackList.Parent = ReplicatedStorage

local MarkFeedbackRead = Instance.new("RemoteEvent")
MarkFeedbackRead.Name = "MarkFeedbackRead"
MarkFeedbackRead.Parent = ReplicatedStorage

local GetUnreadCount = Instance.new("RemoteFunction")
GetUnreadCount.Name = "GetUnreadCount"
GetUnreadCount.Parent = ReplicatedStorage

local DeleteFeedback = Instance.new("RemoteFunction")
DeleteFeedback.Name = "DeleteFeedback"
DeleteFeedback.Parent = ReplicatedStorage

-- Rate limiting: track last submission time per player
local lastSubmission = {}
local COOLDOWN_SECONDS = 30

-- Maximum feedback entries to store
local MAX_FEEDBACK_ENTRIES = 100

-- Filter text using Roblox's TextService
local function filterText(text, player)
	local success, result = pcall(function()
		local textObject = TextService:FilterStringAsync(text, player.UserId)
		return textObject:GetNonChatStringForBroadcastAsync()
	end)
	
	if success then
		return true, result
	else
		warn("[FeedbackHandler] Text filter failed:", result)
		return false, nil
	end
end

local function isOwner(player)
	if player.UserId == game.CreatorId then
		return true
	end
	if BetaConfig.OWNER_USER_ID ~= 0 and player.UserId == BetaConfig.OWNER_USER_ID then
		return true
	end
	return false
end

local function getFeedbackList()
	local success, data = pcall(function()
		return FeedbackStore:GetAsync("FeedbackList")
	end)
	
	if success and data then
		return data
	end
	return {}
end

local function saveFeedbackList(list)
	local success, err = pcall(function()
		FeedbackStore:SetAsync("FeedbackList", list)
	end)
	
	if not success then
		warn("[FeedbackHandler] Failed to save feedback:", err)
	end
	return success
end

local function getLastReadTimestamp()
	local success, timestamp = pcall(function()
		return FeedbackStore:GetAsync("LastReadTimestamp")
	end)
	
	if success and timestamp then
		return timestamp
	end
	return 0
end

local function setLastReadTimestamp(timestamp)
	pcall(function()
		FeedbackStore:SetAsync("LastReadTimestamp", timestamp)
	end)
end

-- Handle feedback submission
SubmitFeedback.OnServerEvent:Connect(function(player, feedbackText)
	-- Owners can't submit feedback to themselves
	if isOwner(player) then
		FeedbackResult:FireClient(player, false, "You're the owner!")
		return
	end
	
	-- Validate input
	if typeof(feedbackText) ~= "string" then
		FeedbackResult:FireClient(player, false, "Invalid feedback format")
		return
	end
	
	-- Trim and check length
	feedbackText = string.sub(feedbackText, 1, 500) -- Max 500 characters
	feedbackText = string.gsub(feedbackText, "^%s*(.-)%s*$", "%1") -- Trim whitespace
	
	if #feedbackText < 5 then
		FeedbackResult:FireClient(player, false, "Feedback too short (min 5 characters)")
		return
	end
	
	-- Filter text through Roblox's filter
	local filterSuccess, filteredText = filterText(feedbackText, player)
	if not filterSuccess then
		FeedbackResult:FireClient(player, false, "Failed to process feedback. Please try again.")
		return
	end
	
	-- Use the filtered text for storage
	feedbackText = filteredText
	
	-- Check cooldown
	local now = os.time()
	if lastSubmission[player.UserId] and (now - lastSubmission[player.UserId]) < COOLDOWN_SECONDS then
		local remaining = COOLDOWN_SECONDS - (now - lastSubmission[player.UserId])
		FeedbackResult:FireClient(player, false, "Please wait " .. remaining .. " seconds before submitting again")
		return
	end
	
	-- Get current feedback list
	local feedbackList = getFeedbackList()
	
	-- Create feedback entry
	local entry = {
		id = now .. "_" .. player.UserId,
		userId = player.UserId,
		username = player.Name,
		displayName = player.DisplayName,
		feedback = feedbackText,
		timestamp = now,
		date = os.date("%Y-%m-%d %H:%M", now),
		placeVersion = game.PlaceVersion,
	}
	
	-- Add to beginning of list (newest first)
	table.insert(feedbackList, 1, entry)
	
	-- Trim list if too long
	while #feedbackList > MAX_FEEDBACK_ENTRIES do
		table.remove(feedbackList)
	end
	
	-- Save
	if saveFeedbackList(feedbackList) then
		lastSubmission[player.UserId] = now
		FeedbackResult:FireClient(player, true, "Thank you for your feedback!")
		print("[FeedbackHandler] New feedback from", player.Name .. ":", feedbackText)
	else
		FeedbackResult:FireClient(player, false, "Failed to save feedback. Please try again.")
	end
end)

-- Handle owner requesting feedback list
RequestFeedbackList.OnServerInvoke = function(player)
	if not isOwner(player) then
		return {}
	end
	
	return getFeedbackList()
end

-- Handle owner marking feedback as read
MarkFeedbackRead.OnServerEvent:Connect(function(player)
	if not isOwner(player) then return end
	
	setLastReadTimestamp(os.time())
end)

-- Handle owner deleting specific feedback
DeleteFeedback.OnServerInvoke = function(player, feedbackId)
	if not isOwner(player) then
		return false, "Not authorized"
	end
	
	if not feedbackId or typeof(feedbackId) ~= "string" then
		return false, "Invalid feedback ID"
	end
	
	local feedbackList = getFeedbackList()
	local foundIndex = nil
	
	for i, entry in ipairs(feedbackList) do
		if entry.id == feedbackId then
			foundIndex = i
			break
		end
	end
	
	if not foundIndex then
		return false, "Feedback not found"
	end
	
	-- Remove the entry
	local removed = table.remove(feedbackList, foundIndex)
	
	-- Save updated list
	if saveFeedbackList(feedbackList) then
		print(string.format("[FeedbackHandler] Deleted feedback from %s: %s", removed.username, removed.feedback))
		return true, "Deleted"
	else
		return false, "Failed to save"
	end
end

-- Get unread count for owner
GetUnreadCount.OnServerInvoke = function(player)
	if not isOwner(player) then
		return 0, false
	end
	
	local lastRead = getLastReadTimestamp()
	local feedbackList = getFeedbackList()
	
	local unreadCount = 0
	for _, entry in ipairs(feedbackList) do
		if entry.timestamp > lastRead then
			unreadCount = unreadCount + 1
		end
	end
	
	return unreadCount, true -- second value indicates this is the owner
end

-- Create BindableFunction for admin to get feedback (for chat commands)
local GetFeedback = Instance.new("BindableFunction")
GetFeedback.Name = "GetFeedback"
GetFeedback.Parent = ReplicatedStorage

GetFeedback.OnInvoke = function(count)
	local feedbackList = getFeedbackList()
	count = count or 10
	
	local result = {}
	for i = 1, math.min(count, #feedbackList) do
		table.insert(result, feedbackList[i])
	end
	
	return result, #feedbackList
end

-- Create BindableFunction to clear feedback
local ClearFeedback = Instance.new("BindableFunction")
ClearFeedback.Name = "ClearFeedback"
ClearFeedback.Parent = ReplicatedStorage

ClearFeedback.OnInvoke = function()
	return saveFeedbackList({})
end

-- Cleanup on player leave
Players.PlayerRemoving:Connect(function(player)
	lastSubmission[player.UserId] = nil
end)

-- print("[FeedbackHandler] Initialized")
