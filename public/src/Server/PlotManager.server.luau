--[[
	PlotManager
	Handles plot assignment, ownership, spawn management, and terrain generation
	
	On server start: generates terrain for all plots and removes baseplates
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GridConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GridConfig"))

-- Helper to check if MegaPlot mode is active
local function isMegaPlotMode()
	local modeValue = ReplicatedStorage:FindFirstChild("PrivateServerMode")
	return modeValue and modeValue.Value == "MegaPlot"
end

-- Wait for modules folder and require modules
local TerrainGenerator = nil
local GrassSpreadManager = nil
local SnowyGrassManager = nil
local WeatherManager = nil
do
	local modulesFolder = script.Parent:WaitForChild("Modules", 10)
	if modulesFolder then
		local terrainModule = modulesFolder:WaitForChild("TerrainGenerator", 10)
		if terrainModule then
			TerrainGenerator = require(terrainModule)
			print("[PlotManager] TerrainGenerator loaded")
		end
		
		local grassModule = modulesFolder:WaitForChild("GrassSpreadManager", 10)
		if grassModule then
			GrassSpreadManager = require(grassModule)
			GrassSpreadManager.Initialize()
			print("[PlotManager] GrassSpreadManager loaded")
		end
		
		local snowyGrassModule = modulesFolder:WaitForChild("SnowyGrassManager", 10)
		if snowyGrassModule then
			SnowyGrassManager = require(snowyGrassModule)
			SnowyGrassManager.Initialize()
			print("[PlotManager] SnowyGrassManager loaded")
		end
		
		local weatherModule = modulesFolder:WaitForChild("WeatherManager", 10)
		if weatherModule then
			WeatherManager = require(weatherModule)
			print("[PlotManager] WeatherManager loaded")
		end
	end
end

-- Create Remotes folder at runtime
local Remotes = Instance.new("Folder")
Remotes.Name = "Remotes"
Remotes.Parent = ReplicatedStorage

local PlotAssigned = Instance.new("RemoteEvent")
PlotAssigned.Name = "PlotAssigned"
PlotAssigned.Parent = Remotes

local PlotsReady = Instance.new("RemoteEvent")
PlotsReady.Name = "PlotsReady"
PlotsReady.Parent = Remotes

local PlaceBlock = Instance.new("RemoteEvent")
PlaceBlock.Name = "PlaceBlock"
PlaceBlock.Parent = Remotes

local RemoveBlock = Instance.new("RemoteEvent")
RemoveBlock.Name = "RemoveBlock"
RemoveBlock.Parent = Remotes

local GetPlotInfo = Instance.new("RemoteFunction")
GetPlotInfo.Name = "GetPlotInfo"
GetPlotInfo.Parent = Remotes

local PlotOwners = {}
local PlayerPlots = {}
local PlotTerrainReady = {} -- Track which plots have terrain generated

for i = 1, GridConfig.TOTAL_PLOTS do
	PlotOwners[i] = nil
	PlotTerrainReady[i] = false
end

local function getBuildArea(plotNumber)
	return workspace:FindFirstChild(GridConfig.BUILD_AREA_PREFIX .. plotNumber)
end

local function areAllPlotsReady()
	for i = 1, GridConfig.TOTAL_PLOTS do
		if not PlotTerrainReady[i] then return false end
	end
	return true
end

local function findAvailablePlot()
	for i = 1, GridConfig.TOTAL_PLOTS do
		if PlotOwners[i] == nil then
			return i
		end
	end
	return nil
end

local function assignPlot(player, plotNumber)
	if PlotOwners[plotNumber] ~= nil then return false end
	if PlayerPlots[player] then return false end
	
	PlotOwners[plotNumber] = player
	PlayerPlots[player] = plotNumber
	
	local buildArea = getBuildArea(plotNumber)
	if buildArea then
		-- Create blocks folder if it doesn't exist
		local blocksFolder = buildArea:FindFirstChild("Blocks")
		if not blocksFolder then
			blocksFolder = Instance.new("Folder")
			blocksFolder.Name = "Blocks"
			blocksFolder.Parent = buildArea
		end
		
		buildArea:SetAttribute("OwnerUserId", player.UserId)
		buildArea:SetAttribute("OwnerName", player.Name)
		
		-- With StreamingEnabled: keep this player's plot always loaded on their client
		if buildArea:IsA("Model") then
			pcall(function()
				buildArea:AddPersistentPlayer(player)
			end)
		end
		
		-- Generate terrain on-demand (only when a player claims the plot)
		if not PlotTerrainReady[plotNumber] and TerrainGenerator then
			local BiomeConfig = nil
			pcall(function()
				BiomeConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("BiomeConfig"))
			end)
			local defaultBiome = BiomeConfig and BiomeConfig.DefaultBiome or "Plains"
			local defaultTerrainStyle = "Flat"
			
			print("[PlotManager] Generating terrain on-demand for plot " .. plotNumber)
			TerrainGenerator.GenerateFlatTerrainWithBiome(buildArea, plotNumber, defaultBiome, defaultTerrainStyle)
			
			buildArea:SetAttribute("TerrainStyle", defaultTerrainStyle)
			buildArea:SetAttribute("CurrentBiome", defaultBiome)
			PlotTerrainReady[plotNumber] = true
			print("[PlotManager] Plot " .. plotNumber .. " terrain ready for " .. player.Name)
		end
	end
	
	print(player.Name .. " assigned to plot " .. plotNumber)
	PlotAssigned:FireClient(player, plotNumber, buildArea)
	
	-- Register plot for grass spreading
	if GrassSpreadManager and buildArea then
		GrassSpreadManager.RegisterPlot(buildArea, plotNumber)
	end
	
	-- In MegaPlot mode, also register the MegaPlotBuildArea (plot 0)
	if GrassSpreadManager and isMegaPlotMode() then
		local megaPlotRoom = workspace:FindFirstChild("MegaPlotRoom")
		if megaPlotRoom then
			local megaBuildArea = megaPlotRoom:FindFirstChild("MegaPlotBuildArea")
			if megaBuildArea then
				GrassSpreadManager.RegisterPlot(megaBuildArea, 0)
			end
		end
	end
	
	-- Try to auto-load saved plot data
	task.spawn(function()
		-- Wait for SaveManager to create the AutoLoadPlot BindableFunction (up to 10 seconds)
		local AutoLoadPlot = ReplicatedStorage:WaitForChild("AutoLoadPlot", 10)
		if AutoLoadPlot then
			local success, result = AutoLoadPlot:Invoke(player, buildArea, plotNumber)
			if success then
				print("[PlotManager] Auto-loaded save for " .. player.Name)
			else
				print("[PlotManager] No save to load for " .. player.Name .. " (" .. tostring(result) .. ")")
			end
		else
			warn("[PlotManager] AutoLoadPlot not found after 10s timeout - SaveManager may have failed to initialize")
		end
	end)
	
	return true
end

local function releasePlot(player)
	local plotNumber = PlayerPlots[player]
	if not plotNumber then return end
	
	-- Unregister from grass spreading before clearing
	if GrassSpreadManager then
		GrassSpreadManager.UnregisterPlot(plotNumber)
		
		-- In MegaPlot mode, unregister MegaPlot (plot 0) if no players remain
		if isMegaPlotMode() then
			local remainingPlayers = 0
			for p, _ in pairs(PlayerPlots) do
				if p ~= player then
					remainingPlayers = remainingPlayers + 1
				end
			end
			if remainingPlayers == 0 then
				GrassSpreadManager.UnregisterPlot(0)
			end
		end
	end
	
	local buildArea = getBuildArea(plotNumber)
	if buildArea then
		-- Clear weather effects (stops lightning loops, destroys fog emitters, resets state)
		if WeatherManager then
			WeatherManager.ClearPlot(plotNumber)
		end
		-- Remove any leftover weather effects folder from the build area
		local weatherEffectsFolder = buildArea:FindFirstChild("WeatherEffects")
		if weatherEffectsFolder then
			weatherEffectsFolder:Destroy()
		end
		-- Reset weather attributes so next player gets clean state
		buildArea:SetAttribute("CurrentWeather", nil)
		buildArea:SetAttribute("WeatherIntensity", nil)
		
		-- Use TerrainGenerator's optimized clear function to avoid listener cascade
		if TerrainGenerator then
			TerrainGenerator.ClearAllBlocks(buildArea, plotNumber)
		else
			-- Fallback: manual clear with bulk removal flag
			local blocksFolder = buildArea:FindFirstChild("Blocks")
			if blocksFolder then
				blocksFolder:SetAttribute("BulkRemoving", true)
				blocksFolder.Parent = nil
				task.defer(function()
					blocksFolder:Destroy()
				end)
				-- Create fresh folder
				local newFolder = Instance.new("Folder")
				newFolder.Name = "Blocks"
				newFolder.Parent = buildArea
			end
		end
		
		buildArea:SetAttribute("OwnerUserId", nil)
		buildArea:SetAttribute("OwnerName", nil)
		
		-- Remove persistent player streaming (player no longer needs this plot)
		if buildArea:IsA("Model") then
			pcall(function()
				buildArea:RemovePersistentPlayer(player)
			end)
		end
		
		-- Reset and regenerate terrain so the plot doesn't stay empty
		if TerrainGenerator then
			TerrainGenerator.ResetPlot(plotNumber)
			
			-- Regenerate default terrain in a separate thread to not block
			task.spawn(function()
				task.wait(0.1)  -- Small delay to let cleanup complete
				
				local BiomeConfig = nil
				pcall(function()
					BiomeConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("BiomeConfig"))
				end)
				local defaultBiome = BiomeConfig and BiomeConfig.DefaultBiome or "Plains"
				local defaultTerrainStyle = "Flat"
				
				print("[PlotManager] Regenerating terrain for released plot " .. plotNumber)
				TerrainGenerator.GenerateFlatTerrainWithBiome(buildArea, plotNumber, defaultBiome, defaultTerrainStyle)
				
				buildArea:SetAttribute("TerrainStyle", defaultTerrainStyle)
				buildArea:SetAttribute("CurrentBiome", defaultBiome)
				PlotTerrainReady[plotNumber] = true
				print("[PlotManager] Plot " .. plotNumber .. " terrain regenerated")
			end)
		else
			PlotTerrainReady[plotNumber] = false
		end
	end
	
	PlotOwners[plotNumber] = nil
	PlayerPlots[player] = nil
	print(player.Name .. " released plot " .. plotNumber)
end

local function teleportToPlot(player)
	-- Skip teleport if MegaPlot mode is active - MegaPlotVisibility handles spawning
	if isMegaPlotMode() then
		print("[PlotManager] Skipping teleport for", player.Name, "- MegaPlot mode active")
		return
	end
	
	local plotNumber = PlayerPlots[player]
	if not plotNumber then return end
	
	local buildArea = getBuildArea(plotNumber)
	if not buildArea then return end
	
	local character = player.Character
	if not character then return end
	
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end
	
	local humanoid = character:FindFirstChild("Humanoid")
	
	-- Calculate spawn position
	local spawnPos
	local spawnPoint = buildArea:FindFirstChild("PlayerSpawn")
	if spawnPoint and spawnPoint:IsA("BasePart") then
		spawnPos = spawnPoint.Position + Vector3.new(0, 3, 0)
	else
		-- Fallback: use stored baseplate position
		local posX = buildArea:GetAttribute("BasePlatePositionX")
		local posY = buildArea:GetAttribute("BasePlatePositionY")
		local posZ = buildArea:GetAttribute("BasePlatePositionZ")
		local sizeY = buildArea:GetAttribute("BasePlateSizeY")
		
		if posX and posY and posZ and sizeY then
			local plateTop = posY + sizeY / 2
			spawnPos = Vector3.new(posX, plateTop + 5, posZ)
		else
			warn("[PlotManager] No spawn position available for", player.Name)
			return
		end
	end
	
	-- Unseat player if seated
	if humanoid and humanoid.Sit then
		humanoid.Sit = false
		task.wait(0.1)
	end
	
	-- Add protection during teleport
	hrp.Anchored = true
	local forceField = character:FindFirstChild("TeleportProtection")
	if not forceField then
		forceField = Instance.new("ForceField")
		forceField.Name = "TeleportProtection"
		forceField.Visible = false
		forceField.Parent = character
	end
	
	-- Teleport
	character:PivotTo(CFrame.new(spawnPos))
	print("[PlotManager] Teleported", player.Name, "to plot", plotNumber)
	
	-- Wait a moment for terrain to register, then unanchor
	task.delay(0.3, function()
		if hrp and hrp.Parent then
			hrp.Anchored = false
		end
		if forceField and forceField.Parent then
			task.delay(0.5, function()
				if forceField and forceField.Parent then
					forceField:Destroy()
				end
			end)
		end
	end)
end

local function getPlotFromPosition(position)
	for i = 1, GridConfig.TOTAL_PLOTS do
		local buildArea = getBuildArea(i)
		if buildArea then
			-- Try stored baseplate info first (after terrain generation)
			local posX = buildArea:GetAttribute("BasePlatePositionX")
			local posZ = buildArea:GetAttribute("BasePlatePositionZ")
			local sizeX = buildArea:GetAttribute("BasePlateSizeX")
			local sizeZ = buildArea:GetAttribute("BasePlateSizeZ")
			
			if posX and posZ and sizeX and sizeZ then
				local halfX, halfZ = sizeX / 2, sizeZ / 2
				if position.X >= posX - halfX and position.X <= posX + halfX and
				   position.Z >= posZ - halfZ and position.Z <= posZ + halfZ then
					return i
				end
			else
				-- Fallback to baseplate if it still exists
				local basePlate = buildArea:FindFirstChild("BasePlate")
				if basePlate and basePlate:IsA("BasePart") then
					local pos = basePlate.Position
					local size = basePlate.Size
					local halfX, halfZ = size.X / 2, size.Z / 2
					
					if position.X >= pos.X - halfX and position.X <= pos.X + halfX and
					   position.Z >= pos.Z - halfZ and position.Z <= pos.Z + halfZ then
						return i
					end
				end
			end
		end
	end
	return nil
end

local function doesPlayerOwnPosition(player, position)
	local plotNumber = getPlotFromPosition(position)
	if not plotNumber then return false end
	return PlayerPlots[player] == plotNumber
end

Players.PlayerAdded:Connect(function(player)
	local plotNumber = findAvailablePlot()
	
	if plotNumber then
		assignPlot(player, plotNumber)
		
		player.CharacterAdded:Connect(function(character)
			-- In MegaPlot mode, MegaPlotVisibility handles all spawning/protection
			if isMegaPlotMode() then return end
			
			-- Wait briefly for character to fully load, then teleport with protection
			local hrp = character:WaitForChild("HumanoidRootPart", 3)
			if hrp then
				-- Anchor immediately to prevent falling
				hrp.Anchored = true
				task.wait(0.1)  -- Minimal delay
				teleportToPlot(player)
			end
		end)
		
		if player.Character then
			if not isMegaPlotMode() then
				local hrp = player.Character:FindFirstChild("HumanoidRootPart")
				if hrp then
					hrp.Anchored = true
				end
				task.wait(0.1)
				teleportToPlot(player)
			end
		end
	else
		warn("No plots available for " .. player.Name)
	end
end)

Players.PlayerRemoving:Connect(function(player)
	print("[PlotManager] Player leaving: " .. player.Name .. " - starting save-before-release")
	
	-- IMPORTANT: Wait for SaveManager to finish auto-save BEFORE clearing the plot
	-- Otherwise the save happens while blocks are being destroyed, corrupting dug detection
	local SavePlotSync = ReplicatedStorage:FindFirstChild("SavePlotSync")
	if SavePlotSync then
		local saveStart = tick()
		local success, err = pcall(function()
			SavePlotSync:Invoke(player)
		end)
		local saveTime = tick() - saveStart
		if success then
			print(string.format("[PlotManager] SavePlotSync completed for %s in %.2fs", player.Name, saveTime))
		else
			warn(string.format("[PlotManager] SavePlotSync FAILED for %s after %.2fs: %s", player.Name, saveTime, tostring(err)))
		end
	else
		warn("[PlotManager] SavePlotSync BindableFunction NOT FOUND - player data will NOT be saved!")
	end
	
	releasePlot(player)
	print("[PlotManager] Plot released for " .. player.Name)
end)

GetPlotInfo.OnServerInvoke = function(player)
	local plotNumber = PlayerPlots[player]
	if not plotNumber then return nil end
	local buildArea = getBuildArea(plotNumber)
	if not buildArea then return nil end
	
	-- Return stored baseplate info since baseplate is destroyed
	return {
		PlotNumber = plotNumber,
		BuildArea = buildArea,
		BasePlatePosition = Vector3.new(
			buildArea:GetAttribute("BasePlatePositionX") or 0,
			buildArea:GetAttribute("BasePlatePositionY") or 0,
			buildArea:GetAttribute("BasePlatePositionZ") or 0
		),
		BasePlateSize = Vector3.new(
			buildArea:GetAttribute("BasePlateSizeX") or 0,
			buildArea:GetAttribute("BasePlateSizeY") or 0,
			buildArea:GetAttribute("BasePlateSizeZ") or 0
		),
	}
end

local CheckOwnership = Instance.new("BindableFunction")
CheckOwnership.Name = "CheckPlotOwnership"
CheckOwnership.Parent = ReplicatedStorage
CheckOwnership.OnInvoke = doesPlayerOwnPosition

-- ============================================
-- SERVER STARTUP: Generate terrain for all plots
-- ============================================

local function initializeAllPlots()
	print("[PlotManager] Preparing " .. GridConfig.TOTAL_PLOTS .. " plots (terrain deferred until player joins)...")
	
	for i = 1, GridConfig.TOTAL_PLOTS do
		local buildArea = getBuildArea(i)
		if buildArea then
			-- Set streaming mode: Atomic means the entire BuildArea streams in/out as one unit
			-- This prevents partial loading where some blocks appear but others don't
			if buildArea:IsA("Model") then
				buildArea.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
			end
			
			local basePlate = buildArea:FindFirstChild("BasePlate")
			if basePlate then
				-- Store baseplate info as attributes (needed for grid alignment, teleporting, etc.)
				buildArea:SetAttribute("BasePlatePositionX", basePlate.Position.X)
				buildArea:SetAttribute("BasePlatePositionY", basePlate.Position.Y)
				buildArea:SetAttribute("BasePlatePositionZ", basePlate.Position.Z)
				buildArea:SetAttribute("BasePlateSizeX", basePlate.Size.X)
				buildArea:SetAttribute("BasePlateSizeY", basePlate.Size.Y)
				buildArea:SetAttribute("BasePlateSizeZ", basePlate.Size.Z)
				buildArea:SetAttribute("BasePlateTop", basePlate.Position.Y + basePlate.Size.Y / 2)
				
				-- Delete the baseplate — terrain will generate when a player claims this plot
				basePlate:Destroy()
			end
			
			-- Create blocks folder so it exists even before terrain gen
			local blocksFolder = buildArea:FindFirstChild("Blocks")
			if not blocksFolder then
				blocksFolder = Instance.new("Folder")
				blocksFolder.Name = "Blocks"
				blocksFolder.Parent = buildArea
			end
			
			print("[PlotManager] Plot " .. i .. " prepared (no terrain yet)")
		end
	end
	
	print("[PlotManager] All plots prepared! Terrain will generate on-demand when players join.")
end

-- Shared state: clients can check this on join to know if loading screen is needed
local allPlotsReadyValue = Instance.new("BoolValue")
allPlotsReadyValue.Name = "AllPlotsReady"
allPlotsReadyValue.Value = false
allPlotsReadyValue.Parent = ReplicatedStorage

-- Run plot preparation (fast — no terrain generation)
initializeAllPlots()

-- ============================================
-- BACKGROUND TERRAIN GENERATION
-- Generates terrain for unclaimed plots gradually after the first player joins
-- This prevents empty plots being visible while avoiding the startup replication spike
-- ============================================

local backgroundGenStarted = false

local function startBackgroundTerrainGen()
	if backgroundGenStarted then return end
	backgroundGenStarted = true
	
	task.spawn(function()
		-- Small delay to let the first player's plot finish generating and replicating
		task.wait(3)
		
		local BiomeConfig = nil
		pcall(function()
			BiomeConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("BiomeConfig"))
		end)
		local defaultBiome = BiomeConfig and BiomeConfig.DefaultBiome or "Plains"
		local defaultTerrainStyle = "Flat"
		
		print("[PlotManager] Starting background terrain generation for unclaimed plots...")
		
		for i = 1, GridConfig.TOTAL_PLOTS do
			-- Skip plots that already have terrain (claimed by a player)
			if not PlotTerrainReady[i] then
				local buildArea = getBuildArea(i)
				if buildArea and TerrainGenerator then
					print("[PlotManager] Background generating terrain for plot " .. i)
					TerrainGenerator.GenerateFlatTerrainWithBiome(buildArea, i, defaultBiome, defaultTerrainStyle)
					buildArea:SetAttribute("TerrainStyle", defaultTerrainStyle)
					buildArea:SetAttribute("CurrentBiome", defaultBiome)
					PlotTerrainReady[i] = true
					print("[PlotManager] Plot " .. i .. " background terrain ready")
					
					-- Send progress to all clients showing loading screen
					local readyCount = 0
					for j = 1, GridConfig.TOTAL_PLOTS do
						if PlotTerrainReady[j] then readyCount = readyCount + 1 end
					end
					PlotsReady:FireAllClients("progress", readyCount, GridConfig.TOTAL_PLOTS)
					
					-- Wait between plots to spread out replication load
					task.wait(1)
				end
			end
		end
		
		-- Signal all clients that plots are ready
		allPlotsReadyValue.Value = true
		PlotsReady:FireAllClients("ready")
		print("[PlotManager] Background terrain generation complete!")
	end)
end

-- Hook into PlayerAdded to trigger background gen on first player join
local backgroundGenConnection
backgroundGenConnection = Players.PlayerAdded:Connect(function()
	-- First player joined — start generating the remaining plots in the background
	startBackgroundTerrainGen()
	-- Only need to trigger once
	if backgroundGenConnection then
		backgroundGenConnection:Disconnect()
		backgroundGenConnection = nil
	end
end)

print("PlotManager initialized with " .. GridConfig.TOTAL_PLOTS .. " plots")
