--[[
	MobileSignHandler
	Handles sign interaction requests from mobile clients
	
	On desktop, ClickDetectors handle RightMouseClick directly.
	On mobile, the client sends a request and we handle it here.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local DataStoreService = game:GetService("DataStoreService")

local GridConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GridConfig"))

-- Create the remote
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)

local RequestSignInteraction = Instance.new("RemoteEvent")
RequestSignInteraction.Name = "RequestSignInteraction"
RequestSignInteraction.Parent = Remotes

-- Wait for other remotes that signs use
local OpenBiomeUI = Remotes:WaitForChild("OpenBiomeUI", 10)
local OpenSaveLoadUI = Remotes:WaitForChild("OpenSaveLoadUI", 10)
local LikeResult = Remotes:WaitForChild("LikeResult", 10)

-- Wait for LikesHandler data functions (we'll use a different approach)
local DATASTORE_NAME = "LikesData_v1"
local LikesDataStore = nil

local function getDataStore()
	if LikesDataStore then return LikesDataStore end
	
	local success, result = pcall(function()
		return DataStoreService:GetDataStore(DATASTORE_NAME)
	end)
	
	if success then
		LikesDataStore = result
		return LikesDataStore
	end
	return nil
end

-- Wait for SaveManager data store functions
local SAVE_DATASTORE_NAME = "PlotSaves_v1"
local SaveDataStore = nil

local function getSaveDataStore()
	if SaveDataStore then return SaveDataStore end
	
	local success, result = pcall(function()
		return DataStoreService:GetDataStore(SAVE_DATASTORE_NAME)
	end)
	
	if success then
		SaveDataStore = result
		return SaveDataStore
	end
	return nil
end

-- ============================================
-- HELPER FUNCTIONS
-- ============================================

local function playerOwnsBuildArea(player, buildArea)
	local ownerUserId = buildArea:GetAttribute("OwnerUserId")
	return ownerUserId == player.UserId
end

local function plotHasBlocks(buildArea)
	local blocksFolder = buildArea:FindFirstChild("Blocks")
	if not blocksFolder then return false end
	return #blocksFolder:GetChildren() > 0
end

local function hasSaveData(player)
	local dataStore = getSaveDataStore()
	if not dataStore then return false end
	
	local key = "plot_" .. tostring(player.UserId)
	local success, result = pcall(function()
		return dataStore:GetAsync(key)
	end)
	
	return success and result ~= nil
end

local function getPlotNumber(buildArea)
	local areaName = buildArea.Name
	local numStr = string.match(areaName, "%d+")
	if numStr then
		return tonumber(numStr) or 0
	end
	return 0
end

-- ============================================
-- LIKE SYSTEM HELPERS (duplicated from LikesHandler to avoid circular deps)
-- ============================================

local function getTotalLikes(userId)
	local dataStore = getDataStore()
	if not dataStore then return 0 end
	
	local key = "totalLikes_" .. tostring(userId)
	local success, result = pcall(function()
		return dataStore:GetAsync(key)
	end)
	
	return success and result or 0
end

local function getGivenLikes(userId)
	local dataStore = getDataStore()
	if not dataStore then return {} end
	
	local key = "givenLikes_" .. tostring(userId)
	local success, result = pcall(function()
		return dataStore:GetAsync(key)
	end)
	
	return success and result or {}
end

local function hasLiked(likerUserId, targetUserId)
	local givenLikes = getGivenLikes(likerUserId)
	return givenLikes[tostring(targetUserId)] == true
end

local function addLike(likerUserId, targetUserId)
	local dataStore = getDataStore()
	if not dataStore then
		return false, "DataStore not available"
	end
	
	-- Add to liker's given likes
	local givenLikesKey = "givenLikes_" .. tostring(likerUserId)
	local success1 = pcall(function()
		dataStore:UpdateAsync(givenLikesKey, function(oldData)
			local data = oldData or {}
			data[tostring(targetUserId)] = true
			return data
		end)
	end)
	
	if not success1 then
		return false, "Failed to record like"
	end
	
	-- Increment target's total likes
	local totalLikesKey = "totalLikes_" .. tostring(targetUserId)
	local newTotal = 0
	local success2 = pcall(function()
		newTotal = dataStore:IncrementAsync(totalLikesKey, 1)
	end)
	
	if not success2 then
		return false, "Failed to add like"
	end
	
	return true, newTotal
end

-- ============================================
-- SIGN INTERACTION HANDLER
-- ============================================

RequestSignInteraction.OnServerEvent:Connect(function(player, signType, buildArea)
	-- Validate buildArea
	if not buildArea or not buildArea:IsA("Model") then
		warn("[MobileSignHandler] Invalid buildArea from", player.Name)
		return
	end
	
	-- Validate it's actually a build area
	if not string.match(buildArea.Name, GridConfig.BUILD_AREA_PREFIX) then
		warn("[MobileSignHandler] Not a valid build area:", buildArea.Name)
		return
	end
	
	-- Handle each sign type
	if signType == "BiomeSign" then
		-- Only owner can use BiomeSign
		if not playerOwnsBuildArea(player, buildArea) then
			return
		end
		
		local plotNumber = getPlotNumber(buildArea)
		local currentBiome = buildArea:GetAttribute("CurrentBiome") or "None"
		local hasBlocks = plotHasBlocks(buildArea)
		local currentWeather = buildArea:GetAttribute("CurrentWeather") or "Clear"
		local currentSeason = buildArea:GetAttribute("CurrentSeason") or "Summer"
		
		-- Fire the UI open event (same as desktop RightMouseClick)
		OpenBiomeUI:FireClient(player, plotNumber, currentBiome, hasBlocks, currentWeather, currentSeason)
		print("[MobileSignHandler] Opened BiomeUI for", player.Name)
		
	elseif signType == "SaveLoadSign" then
		-- Only owner can use SaveLoadSign
		if not playerOwnsBuildArea(player, buildArea) then
			return
		end
		
		local hasSave = hasSaveData(player)
		
		-- Fire the UI open event (same as desktop RightMouseClick)
		OpenSaveLoadUI:FireClient(player, hasSave)
		print("[MobileSignHandler] Opened SaveLoadUI for", player.Name)
		
	elseif signType == "LikeSign" then
		-- Anyone can use LikeSign (we validate ownership here)
		local ownerUserId = buildArea:GetAttribute("OwnerUserId")
		local ownerName = buildArea:GetAttribute("OwnerName")
		
		-- Check if plot is owned
		if not ownerUserId then
			LikeResult:FireClient(player, false, "This plot has no owner")
			return
		end
		
		-- Can't like your own plot
		if ownerUserId == player.UserId then
			LikeResult:FireClient(player, false, "You can't like your own build!")
			return
		end
		
		-- Check if already liked
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
			local likeSign = buildArea:FindFirstChild("LikeSign")
			if likeSign then
				local textPart = likeSign:FindFirstChild("Text")
				if textPart then
					local surfaceGui = textPart:FindFirstChild("LikeCountGui")
					if surfaceGui then
						local textLabel = surfaceGui:FindFirstChild("LikeCount")
						if textLabel then
							textLabel.Text = tostring(result) .. " ❤"
						end
					end
				end
			end
			
			-- Notify the owner if online
			local owner = Players:GetPlayerByUserId(ownerUserId)
			if owner then
				LikeResult:FireClient(owner, true, player.Name .. " liked your build! (" .. result .. " total likes)")
			end
			
			print("[MobileSignHandler]", player.Name, "liked plot of user", ownerUserId)
		else
			LikeResult:FireClient(player, false, result or "Failed to like")
		end
		
	else
		warn("[MobileSignHandler] Unknown sign type:", signType)
	end
end)

print("[MobileSignHandler] Initialized")
