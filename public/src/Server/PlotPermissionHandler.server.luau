--[[
	PlotPermissionHandler
	Server script that handles RemoteEvent communication for plot permissions
	
	Manages:
	- Sharing/unsharing plot access
	- Blocking/unblocking players
	- Kicking players from plot
	- Getting player information for UI
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

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

-- Wait for Remotes folder
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
if not Remotes then
	Remotes = Instance.new("Folder")
	Remotes.Name = "Remotes"
	Remotes.Parent = ReplicatedStorage
end

-- Wait for and require PlotPermissionManager
local PlotPermissionManager = nil
task.spawn(function()
	local modulesFolder = script.Parent:WaitForChild("Modules", 10)
	if modulesFolder then
		local permModule = modulesFolder:WaitForChild("PlotPermissionManager", 10)
		if permModule then
			PlotPermissionManager = require(permModule)
			PlotPermissionManager.Initialize()
			print("[PlotPermissionHandler] PlotPermissionManager loaded and initialized")
		else
			warn("[PlotPermissionHandler] PlotPermissionManager module not found!")
		end
	end
end)

-- ============================================
-- CREATE REMOTES
-- ============================================

local function getOrCreateRemote(name, className)
	className = className or "RemoteEvent"
	local existing = Remotes:FindFirstChild(name)
	if existing then
		return existing
	end
	
	local remote
	if className == "RemoteFunction" then
		remote = Instance.new("RemoteFunction")
	else
		remote = Instance.new("RemoteEvent")
	end
	remote.Name = name
	remote.Parent = Remotes
	return remote
end

-- RemoteEvents for actions
local SharePlotAccess = getOrCreateRemote("SharePlotAccess")
local RevokePlotAccess = getOrCreateRemote("RevokePlotAccess")
local BlockFromPlot = getOrCreateRemote("BlockFromPlot")
local UnblockFromPlot = getOrCreateRemote("UnblockFromPlot")
local KickFromPlot = getOrCreateRemote("KickFromPlot")

-- RemoteFunction for getting player info
local GetPlayerInteractionInfo = getOrCreateRemote("GetPlayerInteractionInfo", "RemoteFunction")

-- RemoteEvent for sending results back to client
local PlotPermissionResult = getOrCreateRemote("PlotPermissionResult")

-- RemoteFunction for getting shared/blocked lists
local GetPermissionLists = getOrCreateRemote("GetPermissionLists", "RemoteFunction")

-- Plot barrier system: tells clients which plots they're blocked from
local GetBlockedPlotBoundaries = getOrCreateRemote("GetBlockedPlotBoundaries", "RemoteFunction")
local BlockedPlotsChanged = getOrCreateRemote("BlockedPlotsChanged")

-- Shared access tracking: tells clients which plots they can build on
local GetMySharedAccessList = getOrCreateRemote("GetMySharedAccessList", "RemoteFunction")
local SharedAccessChanged = getOrCreateRemote("SharedAccessChanged")

-- ============================================
-- PLOT BARRIER SYSTEM
-- ============================================

local GridConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GridConfig"))

-- Build list of plot boundaries the player is blocked from
local function getBlockedPlotBoundariesForPlayer(targetPlayer)
	-- PlotPermissionManager may not be loaded yet; caller should guard
	if not PlotPermissionManager then return {} end

	local blockedPlots = {}

	for i = 1, GridConfig.TOTAL_PLOTS do
		local buildArea = workspace:FindFirstChild(GridConfig.BUILD_AREA_PREFIX .. i)
		if not buildArea then continue end

		local ownerUserId = buildArea:GetAttribute("OwnerUserId")
		if not ownerUserId then continue end
		if ownerUserId == targetPlayer.UserId then continue end

		if PlotPermissionManager.IsBlocked(ownerUserId, targetPlayer.UserId) then
			local posX = buildArea:GetAttribute("BasePlatePositionX")
			local posY = buildArea:GetAttribute("BasePlatePositionY")
			local posZ = buildArea:GetAttribute("BasePlatePositionZ")
			local sizeX = buildArea:GetAttribute("BasePlateSizeX")
			local sizeZ = buildArea:GetAttribute("BasePlateSizeZ")

			if posX and posZ and sizeX and sizeZ then
				table.insert(blockedPlots, {
					plotNumber = i,
					centerX = posX,
					centerZ = posZ,
					halfX = sizeX / 2,
					halfZ = sizeZ / 2,
					baseY = posY or 0,
				})
			end
		end
	end

	return blockedPlots
end

-- Send updated blocked plots to a specific player
local function notifyBlockedPlotsChanged(targetPlayer)
	local boundaries = getBlockedPlotBoundariesForPlayer(targetPlayer)
	BlockedPlotsChanged:FireClient(targetPlayer, boundaries)
end

-- ============================================
-- HELPER: Find player by userId (for when target is offline or we only have userId)
-- ============================================

local function getPlayerByUserId(userId)
	return Players:GetPlayerByUserId(userId)
end

-- ============================================
-- EVENT HANDLERS
-- ============================================

-- Share plot access with another player
SharePlotAccess.OnServerEvent:Connect(function(requestingPlayer, targetUserId)
	if not PlotPermissionManager then
		PlotPermissionResult:FireClient(requestingPlayer, "share", false, "System not ready")
		return
	end
	
	local targetPlayer = getPlayerByUserId(targetUserId)
	if not targetPlayer then
		PlotPermissionResult:FireClient(requestingPlayer, "share", false, "Player not found")
		return
	end
	
	-- Check if they're Roblox friends (or Studio test friends)
	local isFriend = areStudioTestFriends(requestingPlayer, targetPlayer)
	if not isFriend then
		local success, result = pcall(function()
			return requestingPlayer:IsFriendsWith(targetUserId)
		end)
		if success then
			isFriend = result
		end
	end
	
	if not isFriend then
		PlotPermissionResult:FireClient(requestingPlayer, "share", false, "You can only share your plot with Roblox friends")
		return
	end
	
	local shareSuccess, message = PlotPermissionManager.SharePlot(requestingPlayer, targetPlayer)
	PlotPermissionResult:FireClient(requestingPlayer, "share", shareSuccess, message)
	
	-- Notify the target player
	if shareSuccess then
		PlotPermissionResult:FireClient(targetPlayer, "shareNotify", true, 
			requestingPlayer.DisplayName .. " shared their plot with you! You can now build there.")
		-- Tell target client they now have build access on this owner's plot
		SharedAccessChanged:FireClient(targetPlayer, requestingPlayer.UserId, true)
	end
end)

-- Revoke plot access
RevokePlotAccess.OnServerEvent:Connect(function(requestingPlayer, targetUserId)
	if not PlotPermissionManager then
		PlotPermissionResult:FireClient(requestingPlayer, "revoke", false, "System not ready")
		return
	end
	
	local targetPlayer = getPlayerByUserId(targetUserId)
	if not targetPlayer then
		-- For offline players, we still want to be able to revoke
		-- But PlotPermissionManager needs the player object, so we need to handle this differently
		PlotPermissionResult:FireClient(requestingPlayer, "revoke", false, "Player not found (must be online to revoke)")
		return
	end
	
	local revokeSuccess, message = PlotPermissionManager.UnsharePlot(requestingPlayer, targetPlayer)
	PlotPermissionResult:FireClient(requestingPlayer, "revoke", revokeSuccess, message)
	
	-- Notify the target player
	if revokeSuccess then
		PlotPermissionResult:FireClient(targetPlayer, "revokeNotify", true, 
			requestingPlayer.DisplayName .. " revoked your access to their plot.")
		-- Tell target client they no longer have build access on this owner's plot
		SharedAccessChanged:FireClient(targetPlayer, requestingPlayer.UserId, false)
	end
end)

-- Block player from plot
BlockFromPlot.OnServerEvent:Connect(function(requestingPlayer, targetUserId)
	if not PlotPermissionManager then
		PlotPermissionResult:FireClient(requestingPlayer, "block", false, "System not ready")
		return
	end
	
	local targetPlayer = getPlayerByUserId(targetUserId)
	if not targetPlayer then
		PlotPermissionResult:FireClient(requestingPlayer, "block", false, "Player not found")
		return
	end
	
	local blockSuccess, message = PlotPermissionManager.BlockPlayer(requestingPlayer, targetPlayer)
	PlotPermissionResult:FireClient(requestingPlayer, "block", blockSuccess, message)

	-- Notify the blocked player so their client enforces the barrier
	if blockSuccess then
		notifyBlockedPlotsChanged(targetPlayer)
		-- Also remove build access (blocking auto-unshares)
		SharedAccessChanged:FireClient(targetPlayer, requestingPlayer.UserId, false)
	end
end)

-- Unblock player
UnblockFromPlot.OnServerEvent:Connect(function(requestingPlayer, targetUserId)
	if not PlotPermissionManager then
		PlotPermissionResult:FireClient(requestingPlayer, "unblock", false, "System not ready")
		return
	end
	
	local targetPlayer = getPlayerByUserId(targetUserId)
	if not targetPlayer then
		PlotPermissionResult:FireClient(requestingPlayer, "unblock", false, "Player not found")
		return
	end
	
	local unblockSuccess, message = PlotPermissionManager.UnblockPlayer(requestingPlayer, targetPlayer)
	PlotPermissionResult:FireClient(requestingPlayer, "unblock", unblockSuccess, message)

	-- Notify the unblocked player so their client removes the barrier
	if unblockSuccess then
		notifyBlockedPlotsChanged(targetPlayer)
	end
end)

-- Kick player from plot
KickFromPlot.OnServerEvent:Connect(function(requestingPlayer, targetUserId)
	if not PlotPermissionManager then
		PlotPermissionResult:FireClient(requestingPlayer, "kick", false, "System not ready")
		return
	end
	
	local targetPlayer = getPlayerByUserId(targetUserId)
	if not targetPlayer then
		PlotPermissionResult:FireClient(requestingPlayer, "kick", false, "Player not found")
		return
	end
	
	local kickSuccess, message = PlotPermissionManager.KickFromPlot(requestingPlayer, targetPlayer)
	PlotPermissionResult:FireClient(requestingPlayer, "kick", kickSuccess, message)
end)

-- Get player interaction info (RemoteFunction)
GetPlayerInteractionInfo.OnServerInvoke = function(requestingPlayer, targetUserId)
	if not PlotPermissionManager then
		return nil
	end
	
	local targetPlayer = getPlayerByUserId(targetUserId)
	if not targetPlayer then
		return nil
	end
	
	return PlotPermissionManager.GetPlayerInfo(requestingPlayer, targetPlayer)
end

-- Get shared/blocked lists (RemoteFunction)
GetPermissionLists.OnServerInvoke = function(requestingPlayer)
	if not PlotPermissionManager then
		return { sharedWith = {}, blockedPlayers = {} }
	end
	
	local sharedUserIds = PlotPermissionManager.GetSharedWith(requestingPlayer.UserId)
	local blockedUserIds = PlotPermissionManager.GetBlockedPlayers(requestingPlayer.UserId)
	
	-- Convert userIds to player info
	local sharedWith = {}
	for _, userId in ipairs(sharedUserIds) do
		local player = getPlayerByUserId(userId)
		if player then
			table.insert(sharedWith, {
				userId = userId,
				name = player.Name,
				displayName = player.DisplayName,
				isOnline = true,
			})
		else
			-- Player is offline, but we can still show the userId
			table.insert(sharedWith, {
				userId = userId,
				name = "User_" .. userId,
				displayName = "User_" .. userId,
				isOnline = false,
			})
		end
	end
	
	local blockedPlayers = {}
	for _, userId in ipairs(blockedUserIds) do
		local player = getPlayerByUserId(userId)
		if player then
			table.insert(blockedPlayers, {
				userId = userId,
				name = player.Name,
				displayName = player.DisplayName,
				isOnline = true,
			})
		else
			table.insert(blockedPlayers, {
				userId = userId,
				name = "User_" .. userId,
				displayName = "User_" .. userId,
				isOnline = false,
			})
		end
	end
	
	return {
		sharedWith = sharedWith,
		blockedPlayers = blockedPlayers,
	}
end

-- Hook up the RemoteFunction for clients to request their blocked boundaries
GetBlockedPlotBoundaries.OnServerInvoke = function(requestingPlayer)
	return getBlockedPlotBoundariesForPlayer(requestingPlayer)
end

-- Hook up the RemoteFunction for clients to request which owners shared with them
GetMySharedAccessList.OnServerInvoke = function(requestingPlayer)
	if not PlotPermissionManager then return {} end
	return PlotPermissionManager.GetOwnersWhoSharedWith(requestingPlayer.UserId)
end

-- ============================================
-- EXPOSE CanBuildOnPlot FOR OTHER SCRIPTS
-- ============================================

-- Create a BindableFunction for other server scripts to check permissions
local CheckBuildPermission = Instance.new("BindableFunction")
CheckBuildPermission.Name = "CheckPlotBuildPermission"
CheckBuildPermission.Parent = ReplicatedStorage

CheckBuildPermission.OnInvoke = function(player, plotNumber)
	if not PlotPermissionManager then
		return false
	end
	return PlotPermissionManager.CanBuildOnPlot(player, plotNumber)
end

print("[PlotPermissionHandler] Initialized")

if IS_STUDIO and STUDIO_TEST_FRIENDS then
	print("[PlotPermissionHandler] Studio testing mode ENABLED - Player1/Player2/Player3/Player4 treated as friends")
end
