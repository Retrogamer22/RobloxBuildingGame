--[[
	PlotPermissionManager
	Server module for managing plot sharing, blocking, and access control
	
	Features:
	- Share plot with Roblox friends (grant build access)
	- Revoke sharing
	- Block players from entering plot (persisted in DataStore)
	- Kick players from plot
	- Access control checks for building and entering
]]

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- Configuration
local PlotPermissionConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("PlotPermissionConfig"))
local GridConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GridConfig"))

-- Studio testing mode: treat Player1 and Player2 as friends
local IS_STUDIO = RunService:IsStudio()
local STUDIO_TEST_FRIENDS = true -- Set to false to disable friend bypass in Studio

local function areStudioTestFriends(player1, player2)
	if not IS_STUDIO or not STUDIO_TEST_FRIENDS then
		return false
	end
	
	-- Check if both players have test player names
	local testNames = { ["Player1"] = true, ["Player2"] = true, ["Player3"] = true, ["Player4"] = true }
	return testNames[player1.Name] and testNames[player2.Name]
end

local PlotPermissionManager = {}

-- Runtime caches (per owner userId)
local SharedWith = {}      -- { [ownerUserId] = { targetUserId1 = true, ... } }
local BlockedPlayers = {}  -- { [ownerUserId] = { targetUserId1 = true, ... } }
local KickCooldowns = {}   -- { [ownerUserId] = { [targetUserId] = lastKickTime } }

-- DataStore (wrapped in pcall for Studio testing)
local PermissionsDataStore = nil

local function getDataStore()
	if PermissionsDataStore then return PermissionsDataStore end
	
	local success, result = pcall(function()
		return DataStoreService:GetDataStore(PlotPermissionConfig.DATASTORE_NAME)
	end)
	
	if success then
		PermissionsDataStore = result
		return PermissionsDataStore
	else
		warn("[PlotPermissionManager] Failed to get DataStore: " .. tostring(result))
		return nil
	end
end

-- ============================================
-- DATA PERSISTENCE
-- ============================================

local function getDataKey(userId)
	return "perms_" .. tostring(userId)
end

-- Load permissions from DataStore
function PlotPermissionManager.LoadPlayerPermissions(userId)
	local dataStore = getDataStore()
	if not dataStore then
		-- Initialize empty caches
		SharedWith[userId] = {}
		BlockedPlayers[userId] = {}
		return
	end
	
	local key = getDataKey(userId)
	local data = nil
	
	local success, err = pcall(function()
		data = dataStore:GetAsync(key)
	end)
	
	if success and data then
		-- Convert arrays to lookup tables for O(1) access
		SharedWith[userId] = {}
		if data.sharedWith then
			for _, targetId in ipairs(data.sharedWith) do
				SharedWith[userId][targetId] = true
			end
		end
		
		BlockedPlayers[userId] = {}
		if data.blockedPlayers then
			for _, targetId in ipairs(data.blockedPlayers) do
				BlockedPlayers[userId][targetId] = true
			end
		end
		
		print("[PlotPermissionManager] Loaded permissions for userId " .. userId)
	else
		-- Initialize empty
		SharedWith[userId] = {}
		BlockedPlayers[userId] = {}
		if not success then
			warn("[PlotPermissionManager] Failed to load permissions: " .. tostring(err))
		end
	end
end

-- Save permissions to DataStore
function PlotPermissionManager.SavePlayerPermissions(userId)
	local dataStore = getDataStore()
	if not dataStore then return false end
	
	-- Convert lookup tables back to arrays for storage
	local sharedArray = {}
	local blockedArray = {}
	
	if SharedWith[userId] then
		for targetId, _ in pairs(SharedWith[userId]) do
			table.insert(sharedArray, targetId)
		end
	end
	
	if BlockedPlayers[userId] then
		for targetId, _ in pairs(BlockedPlayers[userId]) do
			table.insert(blockedArray, targetId)
		end
	end
	
	local data = {
		sharedWith = sharedArray,
		blockedPlayers = blockedArray,
		lastUpdated = os.time(),
	}
	
	local key = getDataKey(userId)
	local success, err = pcall(function()
		dataStore:SetAsync(key, data)
	end)
	
	if not success then
		warn("[PlotPermissionManager] Failed to save permissions: " .. tostring(err))
	end
	
	return success
end

-- ============================================
-- PLOT HELPERS
-- ============================================

local function getBuildArea(plotNumber)
	return workspace:FindFirstChild(GridConfig.BUILD_AREA_PREFIX .. plotNumber)
end

local function getPlotOwner(plotNumber)
	local buildArea = getBuildArea(plotNumber)
	if not buildArea then return nil end
	return buildArea:GetAttribute("OwnerUserId")
end

local function getPlayerPlotNumber(player)
	for i = 1, GridConfig.TOTAL_PLOTS do
		local buildArea = getBuildArea(i)
		if buildArea and buildArea:GetAttribute("OwnerUserId") == player.UserId then
			return i
		end
	end
	return nil
end

-- Check if a position is within a plot's boundaries
local function isPositionOnPlot(position, plotNumber)
	local buildArea = getBuildArea(plotNumber)
	if not buildArea then return false end
	
	local posX = buildArea:GetAttribute("BasePlatePositionX")
	local posZ = buildArea:GetAttribute("BasePlatePositionZ")
	local sizeX = buildArea:GetAttribute("BasePlateSizeX")
	local sizeZ = buildArea:GetAttribute("BasePlateSizeZ")
	
	if posX and posZ and sizeX and sizeZ then
		local halfX, halfZ = sizeX / 2, sizeZ / 2
		return position.X >= posX - halfX and position.X <= posX + halfX and
			   position.Z >= posZ - halfZ and position.Z <= posZ + halfZ
	end
	
	-- Fallback: use default radius from center
	local center = buildArea:GetPivot().Position
	local distance = (Vector3.new(position.X, 0, position.Z) - Vector3.new(center.X, 0, center.Z)).Magnitude
	return distance <= PlotPermissionConfig.DEFAULT_PLOT_RADIUS
end

-- Check if player is physically on a specific plot
local function isPlayerOnPlot(player, plotNumber)
	local character = player.Character
	if not character then return false end
	
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then return false end
	
	return isPositionOnPlot(hrp.Position, plotNumber)
end

-- Get which plot a player is currently on (returns nil if not on any plot)
function PlotPermissionManager.GetPlayerCurrentPlot(player)
	local character = player.Character
	if not character then return nil end
	
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then return nil end
	
	for i = 1, GridConfig.TOTAL_PLOTS do
		if isPositionOnPlot(hrp.Position, i) then
			return i
		end
	end
	
	return nil
end

-- ============================================
-- SHARING MANAGEMENT
-- ============================================

function PlotPermissionManager.SharePlot(ownerPlayer, targetPlayer)
	local ownerUserId = ownerPlayer.UserId
	local targetUserId = targetPlayer.UserId
	
	print(string.format("[SharePlot] %s (id:%d) wants to share with %s (id:%d)",
		ownerPlayer.Name, ownerUserId, targetPlayer.Name, targetUserId))
	
	-- Can't share with yourself
	if ownerUserId == targetUserId then
		return false, "Cannot share with yourself"
	end
	
	-- Initialize cache if needed
	if not SharedWith[ownerUserId] then
		SharedWith[ownerUserId] = {}
	end
	
	-- Check max shared limit
	local count = 0
	for _, _ in pairs(SharedWith[ownerUserId]) do
		count = count + 1
	end
	if count >= PlotPermissionConfig.MAX_SHARED_PLAYERS then
		return false, "Maximum shared players reached (" .. PlotPermissionConfig.MAX_SHARED_PLAYERS .. ")"
	end
	
	-- Already shared?
	if SharedWith[ownerUserId][targetUserId] then
		return false, "Already shared with this player"
	end
	
	-- Add to shared list
	SharedWith[ownerUserId][targetUserId] = true
	
	print(string.format("[SharePlot] SUCCESS! SharedWith[%d][%d] = true", ownerUserId, targetUserId))
	
	-- Save to DataStore
	task.spawn(function()
		PlotPermissionManager.SavePlayerPermissions(ownerUserId)
	end)
	
	print("[PlotPermissionManager] " .. ownerPlayer.Name .. " shared plot with " .. targetPlayer.Name)
	return true, "Plot shared successfully"
end

function PlotPermissionManager.UnsharePlot(ownerPlayer, targetPlayer)
	local ownerUserId = ownerPlayer.UserId
	local targetUserId = targetPlayer.UserId
	
	if not SharedWith[ownerUserId] or not SharedWith[ownerUserId][targetUserId] then
		return false, "Not currently shared with this player"
	end
	
	-- Remove from shared list
	SharedWith[ownerUserId][targetUserId] = nil
	
	-- Save to DataStore
	task.spawn(function()
		PlotPermissionManager.SavePlayerPermissions(ownerUserId)
	end)
	
	print("[PlotPermissionManager] " .. ownerPlayer.Name .. " revoked access from " .. targetPlayer.Name)
	return true, "Access revoked"
end

function PlotPermissionManager.IsSharedWith(ownerUserId, targetUserId)
	return SharedWith[ownerUserId] and SharedWith[ownerUserId][targetUserId] == true
end

function PlotPermissionManager.GetSharedWith(ownerUserId)
	local result = {}
	if SharedWith[ownerUserId] then
		for targetUserId, _ in pairs(SharedWith[ownerUserId]) do
			table.insert(result, targetUserId)
		end
	end
	return result
end

-- Get all owners who have shared with a specific target player
-- (Reverse lookup: instead of "who did I share with", this is "who shared with me")
function PlotPermissionManager.GetOwnersWhoSharedWith(targetUserId)
	local result = {}
	for ownerUserId, sharedTable in pairs(SharedWith) do
		if sharedTable[targetUserId] then
			table.insert(result, ownerUserId)
		end
	end
	return result
end

-- ============================================
-- BLOCKING MANAGEMENT
-- ============================================

function PlotPermissionManager.BlockPlayer(ownerPlayer, targetPlayer)
	local ownerUserId = ownerPlayer.UserId
	local targetUserId = targetPlayer.UserId
	
	-- Can't block yourself
	if ownerUserId == targetUserId then
		return false, "Cannot block yourself"
	end
	
	-- Initialize cache if needed
	if not BlockedPlayers[ownerUserId] then
		BlockedPlayers[ownerUserId] = {}
	end
	
	-- Check max blocked limit
	local count = 0
	for _, _ in pairs(BlockedPlayers[ownerUserId]) do
		count = count + 1
	end
	if count >= PlotPermissionConfig.MAX_BLOCKED_PLAYERS then
		return false, "Maximum blocked players reached (" .. PlotPermissionConfig.MAX_BLOCKED_PLAYERS .. ")"
	end
	
	-- Already blocked?
	if BlockedPlayers[ownerUserId][targetUserId] then
		return false, "Already blocked"
	end
	
	-- Add to blocked list
	BlockedPlayers[ownerUserId][targetUserId] = true
	
	-- Also remove from shared list if they were shared
	if SharedWith[ownerUserId] then
		SharedWith[ownerUserId][targetUserId] = nil
	end
	
	-- Save to DataStore
	task.spawn(function()
		PlotPermissionManager.SavePlayerPermissions(ownerUserId)
	end)
	
	-- Kick them if they're currently on the plot
	local ownerPlotNumber = getPlayerPlotNumber(ownerPlayer)
	if ownerPlotNumber and isPlayerOnPlot(targetPlayer, ownerPlotNumber) then
		PlotPermissionManager.KickFromPlot(ownerPlayer, targetPlayer, true)  -- Force kick (no cooldown)
	end
	
	print("[PlotPermissionManager] " .. ownerPlayer.Name .. " blocked " .. targetPlayer.Name)
	return true, "Player blocked"
end

function PlotPermissionManager.UnblockPlayer(ownerPlayer, targetPlayer)
	local ownerUserId = ownerPlayer.UserId
	local targetUserId = targetPlayer.UserId
	
	if not BlockedPlayers[ownerUserId] or not BlockedPlayers[ownerUserId][targetUserId] then
		return false, "Player is not blocked"
	end
	
	-- Remove from blocked list
	BlockedPlayers[ownerUserId][targetUserId] = nil
	
	-- Save to DataStore
	task.spawn(function()
		PlotPermissionManager.SavePlayerPermissions(ownerUserId)
	end)
	
	print("[PlotPermissionManager] " .. ownerPlayer.Name .. " unblocked " .. targetPlayer.Name)
	return true, "Player unblocked"
end

function PlotPermissionManager.IsBlocked(ownerUserId, targetUserId)
	return BlockedPlayers[ownerUserId] and BlockedPlayers[ownerUserId][targetUserId] == true
end

function PlotPermissionManager.GetBlockedPlayers(ownerUserId)
	local result = {}
	if BlockedPlayers[ownerUserId] then
		for targetUserId, _ in pairs(BlockedPlayers[ownerUserId]) do
			table.insert(result, targetUserId)
		end
	end
	return result
end

-- ============================================
-- KICKING
-- ============================================

function PlotPermissionManager.KickFromPlot(ownerPlayer, targetPlayer, forceKick)
	local ownerUserId = ownerPlayer.UserId
	local targetUserId = targetPlayer.UserId
	
	-- Can't kick yourself
	if ownerUserId == targetUserId then
		return false, "Cannot kick yourself"
	end
	
	-- Get owner's plot
	local plotNumber = getPlayerPlotNumber(ownerPlayer)
	if not plotNumber then
		return false, "You don't own a plot"
	end
	
	-- Check if target is on the plot
	if not isPlayerOnPlot(targetPlayer, plotNumber) then
		return false, "Player is not on your plot"
	end
	
	-- Check cooldown (unless force kick from blocking)
	if not forceKick then
		if not KickCooldowns[ownerUserId] then
			KickCooldowns[ownerUserId] = {}
		end
		
		local lastKick = KickCooldowns[ownerUserId][targetUserId] or 0
		local now = tick()
		if now - lastKick < PlotPermissionConfig.KICK_COOLDOWN then
			local remaining = math.ceil(PlotPermissionConfig.KICK_COOLDOWN - (now - lastKick))
			return false, "Please wait " .. remaining .. " seconds before kicking this player again"
		end
		
		KickCooldowns[ownerUserId][targetUserId] = now
	end
	
	-- Teleport target off the plot
	local character = targetPlayer.Character
	if not character then
		return false, "Cannot find player's character"
	end
	
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return false, "Cannot find player's HumanoidRootPart"
	end
	
	-- Find teleport destination (outside plot boundary)
	local buildArea = getBuildArea(plotNumber)
	if buildArea then
		local posX = buildArea:GetAttribute("BasePlatePositionX")
		local posY = buildArea:GetAttribute("BasePlatePositionY")
		local posZ = buildArea:GetAttribute("BasePlatePositionZ")
		local sizeX = buildArea:GetAttribute("BasePlateSizeX")
		local sizeZ = buildArea:GetAttribute("BasePlateSizeZ")
		
		if posX and posY and posZ and sizeX and sizeZ then
			-- Teleport to edge of plot + offset
			local playerPos = hrp.Position
			local plotCenter = Vector3.new(posX, 0, posZ)
			local playerPosFlat = Vector3.new(playerPos.X, 0, playerPos.Z)
			
			local direction = (playerPosFlat - plotCenter)
			if direction.Magnitude < 1 then
				direction = Vector3.new(1, 0, 0)  -- Default direction if at center
			end
			direction = direction.Unit
			
			-- Calculate edge position
			local halfX, halfZ = sizeX / 2, sizeZ / 2
			local edgeX = posX + direction.X * (halfX + PlotPermissionConfig.KICK_TELEPORT_DISTANCE)
			local edgeZ = posZ + direction.Z * (halfZ + PlotPermissionConfig.KICK_TELEPORT_DISTANCE)
			local edgeY = posY + 5  -- Above baseplate level
			
			hrp.CFrame = CFrame.new(edgeX, edgeY, edgeZ)
			
			print("[PlotPermissionManager] " .. ownerPlayer.Name .. " kicked " .. targetPlayer.Name .. " from plot")
			return true, "Player kicked from plot"
		end
	end
	
	return false, "Could not determine teleport location"
end

-- ============================================
-- ACCESS CONTROL
-- ============================================

-- Check if a player can build on a specific plot
function PlotPermissionManager.CanBuildOnPlot(player, plotNumber)
	local ownerUserId = getPlotOwner(plotNumber)
	if not ownerUserId then
		print(string.format("[CanBuildOnPlot] Plot %d has no owner", plotNumber))
		return false  -- No owner
	end
	
	-- Owner can always build
	if player.UserId == ownerUserId then
		return true
	end
	
	-- Check if player is blocked
	if PlotPermissionManager.IsBlocked(ownerUserId, player.UserId) then
		print(string.format("[CanBuildOnPlot] %s is blocked from plot %d", player.Name, plotNumber))
		return false
	end
	
	-- Check if player has shared access
	local isShared = PlotPermissionManager.IsSharedWith(ownerUserId, player.UserId)
	print(string.format("[CanBuildOnPlot] %s on plot %d (owner %d): isShared=%s, SharedWith cache: %s", 
		player.Name, plotNumber, ownerUserId, tostring(isShared),
		SharedWith[ownerUserId] and "exists" or "nil"))
	
	if isShared then
		return true
	end
	
	return false
end

-- Check if a player can enter a specific plot
function PlotPermissionManager.CanEnterPlot(player, plotNumber)
	local ownerUserId = getPlotOwner(plotNumber)
	if not ownerUserId then
		return true  -- No owner, anyone can enter
	end
	
	-- Owner can always enter
	if player.UserId == ownerUserId then
		return true
	end
	
	-- Check if player is blocked
	if PlotPermissionManager.IsBlocked(ownerUserId, player.UserId) then
		return false
	end
	
	-- Everyone else can enter (but not build)
	return true
end

-- ============================================
-- PLAYER INFO FOR UI
-- ============================================

-- Get information about a target player relative to the requesting player
function PlotPermissionManager.GetPlayerInfo(requestingPlayer, targetPlayer)
	local requestingUserId = requestingPlayer.UserId
	local targetUserId = targetPlayer.UserId
	
	if requestingUserId == targetUserId then
		return nil  -- Can't get info about yourself
	end
	
	local requestingPlotNumber = getPlayerPlotNumber(requestingPlayer)
	local targetOnRequestingPlot = requestingPlotNumber and isPlayerOnPlot(targetPlayer, requestingPlotNumber)
	
	-- Check Roblox friend status (or Studio test friends)
	local isFriend = areStudioTestFriends(requestingPlayer, targetPlayer)
	if not isFriend then
		local success, result = pcall(function()
			return requestingPlayer:IsFriendsWith(targetUserId)
		end)
		if success then
			isFriend = result
		end
	end
	
	return {
		targetUserId = targetUserId,
		targetName = targetPlayer.Name,
		targetDisplayName = targetPlayer.DisplayName,
		isFriend = isFriend,
		isShared = PlotPermissionManager.IsSharedWith(requestingUserId, targetUserId),
		isBlocked = PlotPermissionManager.IsBlocked(requestingUserId, targetUserId),
		isBlockedByTarget = PlotPermissionManager.IsBlocked(targetUserId, requestingUserId),
		isOnYourPlot = targetOnRequestingPlot,
		requestingPlayerOnOwnPlot = requestingPlotNumber ~= nil and isPlayerOnPlot(requestingPlayer, requestingPlotNumber),
	}
end

-- ============================================
-- INITIALIZATION
-- ============================================

function PlotPermissionManager.Initialize()
	-- Load permissions for all current players
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(function()
			PlotPermissionManager.LoadPlayerPermissions(player.UserId)
		end)
	end
	
	-- Load permissions when new players join
	Players.PlayerAdded:Connect(function(player)
		task.spawn(function()
			PlotPermissionManager.LoadPlayerPermissions(player.UserId)
		end)
	end)
	
	-- Save and cleanup when players leave
	Players.PlayerRemoving:Connect(function(player)
		task.spawn(function()
			PlotPermissionManager.SavePlayerPermissions(player.UserId)
		end)
		
		-- Clear runtime caches after save
		task.delay(5, function()
			SharedWith[player.UserId] = nil
			BlockedPlayers[player.UserId] = nil
			KickCooldowns[player.UserId] = nil
		end)
	end)
	
	-- Periodic check to teleport blocked players off plots
	task.spawn(function()
		while true do
			task.wait(PlotPermissionConfig.BLOCK_CHECK_INTERVAL)
			
			for i = 1, GridConfig.TOTAL_PLOTS do
				local ownerUserId = getPlotOwner(i)
				if ownerUserId and BlockedPlayers[ownerUserId] then
					for blockedUserId, _ in pairs(BlockedPlayers[ownerUserId]) do
						local blockedPlayer = Players:GetPlayerByUserId(blockedUserId)
						if blockedPlayer and isPlayerOnPlot(blockedPlayer, i) then
							-- Find owner player to use kick function
							local ownerPlayer = Players:GetPlayerByUserId(ownerUserId)
							if ownerPlayer then
								PlotPermissionManager.KickFromPlot(ownerPlayer, blockedPlayer, true)
							end
						end
					end
				end
			end
		end
	end)
	
	print("[PlotPermissionManager] Initialized")
	
	if IS_STUDIO and STUDIO_TEST_FRIENDS then
		print("[PlotPermissionManager] Studio testing mode ENABLED - Player1/Player2/Player3/Player4 treated as friends")
	end
end

return PlotPermissionManager
