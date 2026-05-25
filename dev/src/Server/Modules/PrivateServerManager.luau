--[[
	PrivateServerManager
	Handles private server detection, configuration, and permissions
	
	API:
	- PrivateServerManager.IsPrivateServer() -> boolean
	- PrivateServerManager.GetOwnerId() -> number | nil
	- PrivateServerManager.GetServerId() -> string | nil
	- PrivateServerManager.GetMode() -> string
	- PrivateServerManager.SetMode(mode: string) -> boolean, string?
	- PrivateServerManager.IsOwner(player: Player) -> boolean
	- PrivateServerManager.CanBuildOnPlot(player: Player, plotNumber: number) -> boolean
	- PrivateServerManager.GetConfig() -> table
	- PrivateServerManager.SaveConfig() -> boolean
]]

local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PrivateServerConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("PrivateServerConfig"))

local PrivateServerManager = {}

-- ============================================
-- DEBUG / TESTING MODE
-- ============================================
-- Set DEBUG_SIMULATE_PRIVATE_SERVER to true to simulate a private server in Studio
-- IMPORTANT: Set back to false before publishing!

local DEBUG_SIMULATE_PRIVATE_SERVER = false  -- <<< SET TO false BEFORE PUBLISHING!
local DEBUG_OWNER_USER_ID = nil  -- nil = first player to join becomes owner, or set a specific UserId
local DEBUG_SERVER_ID = "debug-private-server-12345"

-- Only allow debug mode in Studio (safety check)
local isStudio = RunService:IsStudio()
if not isStudio then
	DEBUG_SIMULATE_PRIVATE_SERVER = false
end

-- Track if we need to assign owner on first player join
local debugOwnerAssigned = false
local debugOwnerConnection = nil  -- Track the PlayerAdded connection

-- ============================================

-- Cache values
local isPrivateServer = nil
local ownerId = nil
local serverId = nil
local serverConfig = nil
local configLoaded = false
local isFirstTimeSetup = false -- True if no saved config existed in DataStore

-- DataStore reference (lazy loaded)
local dataStore = nil

-- ============================================
-- PRIVATE SERVER DETECTION
-- ============================================

--[[
	Detects if the current server is a private/VIP server
	
	In Roblox:
	- game.PrivateServerId is empty string "" for public servers
	- game.PrivateServerId is a unique string for private servers
	- game.PrivateServerOwnerId is 0 for public servers
	- game.PrivateServerOwnerId is the owner's UserId for private servers
]]
function PrivateServerManager.Initialize()
	-- Check if we're in a private server
	serverId = game.PrivateServerId
	ownerId = game.PrivateServerOwnerId
	
	-- Empty string means public server
	-- Also require ownerId > 0 because Studio team test sets PrivateServerId to a non-empty
	-- GUID but leaves PrivateServerOwnerId at 0, which would falsely trigger private server mode
	isPrivateServer = (serverId ~= nil and serverId ~= "" and ownerId ~= nil and ownerId > 0)
	
	-- DEBUG MODE: Simulate private server in Studio for testing
	if DEBUG_SIMULATE_PRIVATE_SERVER and isStudio then
		isPrivateServer = true
		serverId = DEBUG_SERVER_ID
		
		-- If no owner specified, will be assigned when player joins
		if DEBUG_OWNER_USER_ID then
			ownerId = DEBUG_OWNER_USER_ID
			debugOwnerAssigned = true
		else
			-- Check if player already exists
			local Players = game:GetService("Players")
			local existingPlayer = Players:GetPlayers()[1]
			if existingPlayer then
				ownerId = existingPlayer.UserId
				debugOwnerAssigned = true
				print("[PrivateServerManager] 🎮 DEBUG: Assigned", existingPlayer.Name, "as private server owner (immediate)")
			else
				-- Start with 0, will be assigned when player joins
				ownerId = 0
			end
		end
		
		print("[PrivateServerManager] ⚠️ DEBUG MODE - Simulating private server in Studio!")
		print("[PrivateServerManager] Debug Server ID:", serverId)
		print("[PrivateServerManager] Debug Owner ID:", ownerId)
	end
	
	if isPrivateServer then
		print("[PrivateServerManager] Private server detected!")
		print("[PrivateServerManager] Server ID:", serverId)
		print("[PrivateServerManager] Owner ID:", ownerId)
		
		-- Load configuration from DataStore
		PrivateServerManager.LoadConfig()
	else
		print("[PrivateServerManager] Public server - private server features disabled")
		
		-- Set default config for public servers
		serverConfig = {
			mode = PrivateServerConfig.DEFAULT_MODE,
			schemaVersion = PrivateServerConfig.SCHEMA_VERSION,
		}
		configLoaded = true
	end
	
	-- Create shared values so clients can check private server status
	-- Use FindFirstChild to avoid creating duplicates if Initialize is called multiple times
	
	-- Track if this is a first-time setup (no saved config found)
	local firstSetupValue = ReplicatedStorage:FindFirstChild("PrivateServerFirstSetup")
	if not firstSetupValue then
		firstSetupValue = Instance.new("BoolValue")
		firstSetupValue.Name = "PrivateServerFirstSetup"
		firstSetupValue.Parent = ReplicatedStorage
	end
	firstSetupValue.Value = isPrivateServer and isFirstTimeSetup
	
	local privateServerValue = ReplicatedStorage:FindFirstChild("IsPrivateServer")
	if not privateServerValue then
		privateServerValue = Instance.new("BoolValue")
		privateServerValue.Name = "IsPrivateServer"
		privateServerValue.Parent = ReplicatedStorage
	end
	privateServerValue.Value = isPrivateServer
	
	local ownerIdValue = ReplicatedStorage:FindFirstChild("PrivateServerOwnerId")
	if not ownerIdValue then
		ownerIdValue = Instance.new("IntValue")
		ownerIdValue.Name = "PrivateServerOwnerId"
		ownerIdValue.Parent = ReplicatedStorage
	end
	ownerIdValue.Value = ownerId or 0
	
	local modeValue = ReplicatedStorage:FindFirstChild("PrivateServerMode")
	if not modeValue then
		modeValue = Instance.new("StringValue")
		modeValue.Name = "PrivateServerMode"
		modeValue.Parent = ReplicatedStorage
	end
	modeValue.Value = serverConfig and serverConfig.mode or PrivateServerConfig.DEFAULT_MODE
	
	-- DEBUG MODE: Set up late owner assignment if needed (player joins after server starts)
	if DEBUG_SIMULATE_PRIVATE_SERVER and isStudio and not debugOwnerAssigned and not debugOwnerConnection then
		local Players = game:GetService("Players")
		
		local function assignOwner(player)
			if debugOwnerAssigned then 
				print("[PrivateServerManager] DEBUG: Owner already assigned, skipping")
				return 
			end
			
			print("[PrivateServerManager] DEBUG: Player joined:", player.Name, "UserId:", player.UserId)
			
			ownerId = player.UserId
			debugOwnerAssigned = true
			
			-- Update the shared value immediately
			local ownerValue = ReplicatedStorage:FindFirstChild("PrivateServerOwnerId")
			if ownerValue then
				ownerValue.Value = ownerId
				print("[PrivateServerManager] 🎮 DEBUG: Assigned", player.Name, "as private server owner")
				print("[PrivateServerManager] DEBUG: PrivateServerOwnerId value set to:", ownerValue.Value)
			else
				warn("[PrivateServerManager] DEBUG: PrivateServerOwnerId not found in ReplicatedStorage!")
			end
			
			-- Disconnect the listener
			if debugOwnerConnection then
				debugOwnerConnection:Disconnect()
				debugOwnerConnection = nil
			end
		end
		
		-- Check if player already exists (in case they joined before this runs)
		local existingPlayers = Players:GetPlayers()
		if #existingPlayers > 0 then
			print("[PrivateServerManager] DEBUG: Found existing player, assigning immediately")
			assignOwner(existingPlayers[1])
		else
			-- Set up listener for when player joins
			print("[PrivateServerManager] DEBUG: Waiting for player to join...")
			debugOwnerConnection = Players.PlayerAdded:Connect(assignOwner)
		end
	end
	
	return isPrivateServer
end

-- ============================================
-- GETTERS
-- ============================================

function PrivateServerManager.IsPrivateServer()
	if isPrivateServer == nil then
		PrivateServerManager.Initialize()
	end
	return isPrivateServer
end

function PrivateServerManager.GetOwnerId()
	if isPrivateServer == nil then
		PrivateServerManager.Initialize()
	end
	return ownerId
end

function PrivateServerManager.GetServerId()
	if isPrivateServer == nil then
		PrivateServerManager.Initialize()
	end
	return serverId
end

function PrivateServerManager.IsFirstTimeSetup()
	return isFirstTimeSetup
end

function PrivateServerManager.MarkSetupComplete()
	isFirstTimeSetup = false
	local firstSetupValue = ReplicatedStorage:FindFirstChild("PrivateServerFirstSetup")
	if firstSetupValue then
		firstSetupValue.Value = false
	end
	-- Now save the config
	PrivateServerManager.SaveConfig()
	print("[PrivateServerManager] Setup marked as complete, config saved")
end

function PrivateServerManager.GetMode()
	if not configLoaded then
		PrivateServerManager.Initialize()
	end
	return serverConfig and serverConfig.mode or PrivateServerConfig.DEFAULT_MODE
end

function PrivateServerManager.GetConfig()
	if not configLoaded then
		PrivateServerManager.Initialize()
	end
	return serverConfig
end

-- ============================================
-- PERMISSION CHECKS
-- ============================================

function PrivateServerManager.IsOwner(player)
	if not PrivateServerManager.IsPrivateServer() then
		return false
	end
	return player.UserId == ownerId
end

--[[
	Checks if a player can build on a specific plot
	
	In public servers: Normal rules (must own the plot)
	In private servers (Individual mode): Anyone can build on any plot
	In private servers (MegaPlot mode): Everyone shares the mega-plot
]]
function PrivateServerManager.CanBuildOnPlot(player, plotNumber)
	-- Public server - defer to normal plot ownership
	if not PrivateServerManager.IsPrivateServer() then
		return nil -- nil means "check normal rules"
	end
	
	-- Private server - everyone can build anywhere
	return true
end

--[[
	Checks if a player can change server settings
	Only the owner can change settings
]]
function PrivateServerManager.CanChangeSettings(player)
	return PrivateServerManager.IsOwner(player)
end

-- ============================================
-- CONFIGURATION MANAGEMENT
-- ============================================

local function getDataStore()
	if not dataStore then
		local success, result = pcall(function()
			return DataStoreService:GetDataStore(PrivateServerConfig.DATASTORE_NAME)
		end)
		
		if success then
			dataStore = result
		else
			warn("[PrivateServerManager] Failed to get DataStore:", result)
		end
	end
	return dataStore
end

function PrivateServerManager.LoadConfig()
	if not isPrivateServer then
		configLoaded = true
		return false
	end
	
	local ds = getDataStore()
	if not ds then
		-- Use defaults if DataStore unavailable
		serverConfig = {
			mode = PrivateServerConfig.DEFAULT_MODE,
			schemaVersion = PrivateServerConfig.SCHEMA_VERSION,
			createdAt = os.time(),
		}
		configLoaded = true
		return false
	end
	
	local success, data = pcall(function()
		return ds:GetAsync(serverId)
	end)
	
	if success and data then
		serverConfig = data
		print("[PrivateServerManager] Loaded config:", serverConfig.mode)
		
		-- Run migrations if needed
		if (serverConfig.schemaVersion or 0) < PrivateServerConfig.SCHEMA_VERSION then
			PrivateServerManager.MigrateConfig()
		end
	else
		-- First time setup - create default config
		isFirstTimeSetup = true
		serverConfig = {
			mode = PrivateServerConfig.DEFAULT_MODE,
			schemaVersion = PrivateServerConfig.SCHEMA_VERSION,
			createdAt = os.time(),
			ownerId = ownerId,
		}
		print("[PrivateServerManager] First time setup! Created new config with default mode")
		-- Don't save yet - let the owner configure first
	end
	
	configLoaded = true
	return true
end

function PrivateServerManager.SaveConfig()
	if not isPrivateServer then
		return false
	end
	
	local ds = getDataStore()
	if not ds then
		warn("[PrivateServerManager] Cannot save - DataStore unavailable")
		return false
	end
	
	-- Update timestamp
	serverConfig.lastModified = os.time()
	
	local success, err = pcall(function()
		ds:SetAsync(serverId, serverConfig)
	end)
	
	if success then
		print("[PrivateServerManager] Config saved successfully")
		return true
	else
		warn("[PrivateServerManager] Failed to save config:", err)
		return false
	end
end

function PrivateServerManager.MigrateConfig()
	-- Handle future schema migrations here
	serverConfig.schemaVersion = PrivateServerConfig.SCHEMA_VERSION
	print("[PrivateServerManager] Migrated config to schema version", PrivateServerConfig.SCHEMA_VERSION)
end

-- ============================================
-- MODE MANAGEMENT
-- ============================================

--[[
	Changes the server mode
	Only callable by the server owner
	Returns: success (boolean), errorMessage (string?)
]]
function PrivateServerManager.SetMode(newMode, player)
	if not isPrivateServer then
		return false, "Not a private server"
	end
	
	if player and not PrivateServerManager.IsOwner(player) then
		return false, "Only the server owner can change modes"
	end
	
	-- Validate mode
	local validModes = {
		[PrivateServerConfig.MODES.INDIVIDUAL] = true,
		[PrivateServerConfig.MODES.MEGAPLOT] = true,
	}
	
	if not validModes[newMode] then
		return false, "Invalid mode: " .. tostring(newMode)
	end
	
	local oldMode = serverConfig.mode
	serverConfig.mode = newMode
	
	-- Update the shared value for clients
	local modeValue = ReplicatedStorage:FindFirstChild("PrivateServerMode")
	if modeValue then
		modeValue.Value = newMode
	end
	
	-- Save to DataStore
	local saved = PrivateServerManager.SaveConfig()
	if not saved then
		return false, "Failed to save configuration"
	end
	
	print("[PrivateServerManager] Mode changed from", oldMode, "to", newMode)
	return true
end

-- ============================================
-- MEGA-PLOT DATA MANAGEMENT
-- ============================================

--[[
	Saves mega-plot build data
	This is separate from mode config - it stores the actual blocks
]]
function PrivateServerManager.SaveMegaPlotData(plotData)
	if not isPrivateServer then
		return false, "Not a private server"
	end
	
	local ds = getDataStore()
	if not ds then
		return false, "DataStore unavailable"
	end
	
	local key = serverId .. "_megaplot"
	
	local success, err = pcall(function()
		ds:SetAsync(key, {
			data = plotData,
			savedAt = os.time(),
			schemaVersion = PrivateServerConfig.SCHEMA_VERSION,
		})
	end)
	
	if success then
		print("[PrivateServerManager] Mega-plot data saved")
		return true
	else
		warn("[PrivateServerManager] Failed to save mega-plot data:", err)
		return false, tostring(err)
	end
end

function PrivateServerManager.LoadMegaPlotData()
	if not isPrivateServer then
		return nil, "Not a private server"
	end
	
	local ds = getDataStore()
	if not ds then
		return nil, "DataStore unavailable"
	end
	
	local key = serverId .. "_megaplot"
	
	local success, data = pcall(function()
		return ds:GetAsync(key)
	end)
	
	if success and data then
		print("[PrivateServerManager] Mega-plot data loaded")
		return data.data
	elseif success then
		-- No data exists yet
		return nil
	else
		warn("[PrivateServerManager] Failed to load mega-plot data:", data)
		return nil, tostring(data)
	end
end

return PrivateServerManager
